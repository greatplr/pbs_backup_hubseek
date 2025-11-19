#!/bin/bash
# Enhance Control Panel - PBS Backup Script
# Backs up PostgreSQL databases (orchd, authd), certificates, keys, and assets
# For disaster recovery and control panel migration scenarios

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load common functions
# shellcheck source=../lib/common.sh
source "${PROJECT_DIR}/lib/common.sh"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--dry-run]"
            echo ""
            echo "Options:"
            echo "  --dry-run    Show what would be backed up without actually running backup"
            echo "  -h, --help   Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Load configuration
load_config

# Enhance Control Panel specific paths
ENHANCE_SSL_CERTS="/etc/ssl/certs/enhance"
ENHANCE_SSL_KEYS="/etc/ssl/private/enhance"
ENHANCE_ORCHD_DIR="/var/local/enhance/orchd"
ENHANCE_RCA_PW="/var/local/enhance/rca.pw"
ENHANCE_CP_ASSETS="/var/www/control-panel/assets"

# Temporary directory for database dumps
DB_DUMP_DIR="/tmp/enhance-cp-db-dump-$(date '+%Y%m%d-%H%M%S')"

# Verify prerequisites
check_root
check_pbs_client
check_keyfile

# Setup logging
LOG_DIR=$(setup_logging)
LOG_FILE="${LOG_DIR}/backup-enhance-cp-$(date '+%Y%m%d-%H%M%S').log"

exec > >(tee -a "$LOG_FILE") 2>&1

log_info "Starting Enhance Control Panel backup"
log_info "Repository: ${PBS_REPOSITORY}"
log_info "Log file: ${LOG_FILE}"

# Verify this is a control panel server
if [[ ! -d "${ENHANCE_ORCHD_DIR}" ]]; then
    die "Enhance orchd directory not found: ${ENHANCE_ORCHD_DIR}"
fi

if [[ ! -f "${ENHANCE_RCA_PW}" ]]; then
    die "Enhance RCA password file not found: ${ENHANCE_RCA_PW}"
fi

# Verify PostgreSQL is available
if ! command -v psql &> /dev/null; then
    die "PostgreSQL client (psql) is required but not installed"
fi

# Verify PostgreSQL is running
if ! systemctl is-active --quiet postgresql; then
    die "PostgreSQL service is not running"
fi

# Test PBS connection
test_pbs_connection || die "Cannot connect to PBS server"

# Create temporary directory for database dumps
mkdir -p "${DB_DUMP_DIR}"

# Cleanup function
cleanup() {
    if [[ -d "${DB_DUMP_DIR}" ]]; then
        log_info "Cleaning up temporary database dumps..."
        rm -rf "${DB_DUMP_DIR}"
    fi
}

trap cleanup EXIT

# Dump PostgreSQL databases
dump_postgres_db() {
    local db_name="$1"
    local dump_file="${DB_DUMP_DIR}/${db_name}.dump"

    log_info "Dumping PostgreSQL database: ${db_name}"

    if sudo -u postgres pg_dump -Fc "${db_name}" > "${dump_file}" 2>/dev/null; then
        local dump_size
        dump_size=$(stat -c %s "${dump_file}" 2>/dev/null || stat -f %z "${dump_file}" 2>/dev/null)
        log_success "Database dump created: ${db_name} ($(format_bytes "$dump_size"))"
        chmod 600 "${dump_file}"
        return 0
    else
        log_error "Failed to dump database: ${db_name}"
        return 1
    fi
}

# Dump the Enhance databases
log_info "Dumping Enhance databases..."

DUMP_FAILED=false

if ! dump_postgres_db "orchd"; then
    DUMP_FAILED=true
fi

if ! dump_postgres_db "authd"; then
    DUMP_FAILED=true
fi

if [[ "$DUMP_FAILED" == true ]]; then
    die "One or more database dumps failed"
fi

# Verify critical directories exist
log_info "Verifying critical paths..."

MISSING_PATHS=()

if [[ ! -d "${ENHANCE_SSL_CERTS}" ]]; then
    MISSING_PATHS+=("${ENHANCE_SSL_CERTS}")
fi

if [[ ! -d "${ENHANCE_SSL_KEYS}" ]]; then
    MISSING_PATHS+=("${ENHANCE_SSL_KEYS}")
fi

if [[ ! -d "${ENHANCE_ORCHD_DIR}/private" ]]; then
    MISSING_PATHS+=("${ENHANCE_ORCHD_DIR}/private")
fi

if [[ ${#MISSING_PATHS[@]} -gt 0 ]]; then
    log_warning "Some expected paths are missing:"
    for path in "${MISSING_PATHS[@]}"; do
        log_warning "  - ${path}"
    done
    log_warning "Backup will continue but may be incomplete"
fi

# Build archive list
# - root.pxar: Full system for complete DR
# - Individual archives for selective restore during migration
ARCHIVES=(
    "root.pxar:/"
    "enhance-cp-db.pxar:${DB_DUMP_DIR}"
)

# Add optional archives if paths exist
if [[ -d "${ENHANCE_SSL_CERTS}" ]]; then
    ARCHIVES+=("enhance-cp-ssl-certs.pxar:${ENHANCE_SSL_CERTS}")
fi

if [[ -d "${ENHANCE_SSL_KEYS}" ]]; then
    ARCHIVES+=("enhance-cp-ssl-keys.pxar:${ENHANCE_SSL_KEYS}")
fi

# Always backup the orchd directory (contains private keys, cloudflare key, etc)
ARCHIVES+=("enhance-cp-orchd.pxar:${ENHANCE_ORCHD_DIR}")

if [[ -d "${ENHANCE_CP_ASSETS}" ]]; then
    ARCHIVES+=("enhance-cp-assets.pxar:${ENHANCE_CP_ASSETS}")
fi

# Display what we're backing up
log_info "Archives to backup:"
log_info "  - root.pxar: Full system backup"
log_info "  - enhance-cp-db.pxar: PostgreSQL dumps (orchd, authd)"
if [[ -d "${ENHANCE_SSL_CERTS}" ]]; then
    log_info "  - enhance-cp-ssl-certs.pxar: ${ENHANCE_SSL_CERTS}"
fi
if [[ -d "${ENHANCE_SSL_KEYS}" ]]; then
    log_info "  - enhance-cp-ssl-keys.pxar: ${ENHANCE_SSL_KEYS}"
fi
log_info "  - enhance-cp-orchd.pxar: ${ENHANCE_ORCHD_DIR} (private keys, cloudflare key)"
if [[ -d "${ENHANCE_CP_ASSETS}" ]]; then
    log_info "  - enhance-cp-assets.pxar: ${ENHANCE_CP_ASSETS}"
fi

# Perform PBS backup
log_info "Starting PBS backup..."

BACKUP_CMD=(proxmox-backup-client backup)

for archive in "${ARCHIVES[@]}"; do
    BACKUP_CMD+=("$archive")
done

BACKUP_CMD+=(
    --keyfile "${PBS_KEYFILE}"
    --repository "${PBS_REPOSITORY}"
)

# Add standard exclusions for system backup
# shellcheck disable=SC2046
BACKUP_CMD+=($(get_system_exclusions))

if [[ "${BACKUP_SKIP_LOST_AND_FOUND:-true}" == "true" ]]; then
    BACKUP_CMD+=(--skip-lost-and-found)
fi

# Execute backup
log_info "Executing: ${BACKUP_CMD[*]}"

if [[ "$DRY_RUN" == true ]]; then
    log_info "DRY RUN: Backup command would be executed (no actual backup performed)"
    log_success "Dry run completed successfully"
else
    if "${BACKUP_CMD[@]}"; then
        log_success "PBS backup completed successfully"
    else
        die "PBS backup failed"
    fi
fi

# List recent snapshots
log_info "Recent snapshots:"
list_snapshots

log_success "Enhance Control Panel backup completed for ${PBS_HOSTNAME}"
log_info ""
log_info "For migration instructions, see:"
log_info "  https://enhance.com/docs/advanced/control-panel-migration.html"
