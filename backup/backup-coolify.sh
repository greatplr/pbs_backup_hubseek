#!/bin/bash
# Coolify Instance - PBS Backup Script
# Backs up Coolify configuration, SSH keys, and database dump
# Note: This complements the built-in S3 backup by capturing items not included

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

# Coolify-specific settings
COOLIFY_DATA_DIR="/data/coolify"
COOLIFY_ENV_FILE="${COOLIFY_DATA_DIR}/source/.env"
COOLIFY_SSH_DIR="${COOLIFY_DATA_DIR}/ssh/keys"
COOLIFY_DB_CONTAINER="coolify-db"
COOLIFY_DB_USER="coolify"
COOLIFY_DB_NAME="coolify"

# Temporary directory for database dump
DB_DUMP_DIR="/tmp/coolify-db-dump"
DB_DUMP_FILE="${DB_DUMP_DIR}/coolify.dump"

# Verify prerequisites
check_root
check_pbs_client
check_keyfile

# Setup logging
LOG_DIR=$(setup_logging)
LOG_FILE="${LOG_DIR}/backup-coolify-$(date '+%Y%m%d-%H%M%S').log"

exec > >(tee -a "$LOG_FILE") 2>&1

log_info "Starting Coolify instance backup"
log_info "Repository: ${PBS_REPOSITORY}"
log_info "Log file: ${LOG_FILE}"

# Verify Coolify directories exist
if [[ ! -f "${COOLIFY_ENV_FILE}" ]]; then
    die "Coolify .env file not found: ${COOLIFY_ENV_FILE}"
fi

if [[ ! -d "${COOLIFY_SSH_DIR}" ]]; then
    die "Coolify SSH keys directory not found: ${COOLIFY_SSH_DIR}"
fi

# Verify Docker is available
if ! command -v docker &> /dev/null; then
    die "Docker is required but not installed"
fi

# Verify Coolify database container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${COOLIFY_DB_CONTAINER}$"; then
    die "Coolify database container not running: ${COOLIFY_DB_CONTAINER}"
fi

# Test PBS connection
test_pbs_connection || die "Cannot connect to PBS server"

# Create database dump with retry logic
create_db_dump() {
    log_info "Creating PostgreSQL database dump..."

    # Create dump directory
    mkdir -p "${DB_DUMP_DIR}"

    local max_attempts=3
    local retry_delay=5
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        # Dump database using custom format (efficient for pg_restore)
        if docker exec "${COOLIFY_DB_CONTAINER}" \
            pg_dump -U "${COOLIFY_DB_USER}" -Fc "${COOLIFY_DB_NAME}" > "${DB_DUMP_FILE}"; then

            # Validate the dump file
            if validate_dump_file "$DB_DUMP_FILE" 1024 "coolify"; then
                local dump_size
                dump_size=$(stat -c %s "${DB_DUMP_FILE}" 2>/dev/null || stat -f %z "${DB_DUMP_FILE}" 2>/dev/null)
                log_success "Database dump created: $(format_bytes "$dump_size")"

                # Set secure permissions
                chmod 600 "${DB_DUMP_FILE}"
                return 0
            else
                log_warning "Dump validation failed, attempt $attempt/$max_attempts"
            fi
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            log_warning "PostgreSQL dump attempt $attempt/$max_attempts failed, retrying in ${retry_delay}s..."
            sleep "$retry_delay"
            retry_delay=$((retry_delay * 2))
        fi
        ((attempt++))
    done

    die "Failed to create database dump after $max_attempts attempts"
}

# Cleanup function
cleanup() {
    if [[ -d "${DB_DUMP_DIR}" ]]; then
        log_info "Cleaning up temporary database dump..."
        rm -rf "${DB_DUMP_DIR}"
    fi
}

# Set trap to cleanup on exit
trap cleanup EXIT

# Create database dump
create_db_dump

# Build archive list
# Note: This script backs up Coolify instance items only (no full system).
# For Coolify primary: run this script + backup-coolify-apps.sh (which includes root.pxar)
# - coolify-db.pxar: Transaction-safe database dump (safer than filesystem snapshot of running DB)
# - coolify-env.pxar and coolify-ssh.pxar: For easy selective restore of critical items
ARCHIVES=(
    "coolify-env.pxar:${COOLIFY_ENV_FILE}"
    "coolify-ssh.pxar:${COOLIFY_SSH_DIR}"
    "coolify-db.pxar:${DB_DUMP_DIR}"
)

# Display what we're backing up
log_info "Archives to backup:"
log_info "  - coolify-env.pxar: ${COOLIFY_ENV_FILE} (contains APP_KEY)"
log_info "  - coolify-ssh.pxar: ${COOLIFY_SSH_DIR} (SSH private keys)"
log_info "  - coolify-db.pxar: ${DB_DUMP_DIR} (PostgreSQL dump in custom format)"

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

log_success "Coolify instance backup completed for ${PBS_HOSTNAME}"
log_info ""
log_info "Remember: S3 backup handles scheduled database backups."
log_info "This PBS backup captures: APP_KEY (.env), SSH keys, and a database snapshot."
