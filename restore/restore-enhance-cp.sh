#!/bin/bash
# Enhance Control Panel - PBS Restore Script
# Extracts databases, certificates, and keys for control panel migration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load common functions
# shellcheck source=../lib/common.sh
source "${PROJECT_DIR}/lib/common.sh"

# Load configuration
load_config

# Usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS] <snapshot_path>

Extract Enhance Control Panel backup for migration or recovery.

Arguments:
    snapshot_path       Path to snapshot (e.g., host/panel/2025-01-22T15:19:17Z)

Options:
    -l, --list          List available snapshots
    -d, --dest PATH     Extract to alternate destination (default: /tmp/enhance-cp-restore-<timestamp>)
    --db-only           Extract only database dumps
    --keys-only         Extract only certificates and keys
    -h, --help          Show this help message

Examples:
    # List available snapshots
    $0 --list

    # Full extraction (all components)
    $0 "host/panel/2025-01-22T15:19:17Z"

    # Extract just databases
    $0 --db-only "host/panel/2025-01-22T15:19:17Z"

    # Extract just certificates and keys
    $0 --keys-only "host/panel/2025-01-22T15:19:17Z"

Migration Documentation:
    https://enhance.com/docs/advanced/control-panel-migration.html
EOF
    exit 1
}

# Parse arguments
DB_ONLY=false
KEYS_ONLY=false
RESTORE_DEST=""
SNAPSHOT_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--list)
            load_config
            list_snapshots
            exit 0
            ;;
        -d|--dest)
            RESTORE_DEST="$2"
            shift 2
            ;;
        --db-only)
            DB_ONLY=true
            shift
            ;;
        --keys-only)
            KEYS_ONLY=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "Unknown option: $1"
            usage
            ;;
        *)
            SNAPSHOT_PATH="$1"
            shift
            ;;
    esac
done

if [[ -z "$SNAPSHOT_PATH" ]]; then
    echo "Error: snapshot_path is required"
    usage
fi

# Set default restore destination
if [[ -z "$RESTORE_DEST" ]]; then
    RESTORE_DEST="/tmp/enhance-cp-restore-$(date '+%Y%m%d-%H%M%S')"
fi

# Verify prerequisites
check_root
check_pbs_client
check_keyfile

# Setup logging
LOG_DIR=$(setup_logging)
LOG_FILE="${LOG_DIR}/restore-enhance-cp-$(date '+%Y%m%d-%H%M%S').log"

exec > >(tee -a "$LOG_FILE") 2>&1

log_info "Starting Enhance Control Panel restore"
log_info "Snapshot: ${SNAPSHOT_PATH}"
log_info "Destination: ${RESTORE_DEST}"
log_info "Repository: ${PBS_REPOSITORY}"
log_info "Log file: ${LOG_FILE}"

# Test PBS connection
test_pbs_connection || die "Cannot connect to PBS server"

# Create restore destination
mkdir -p "${RESTORE_DEST}"

# Extract database dumps
extract_databases() {
    log_info "Extracting database dumps..."

    local db_dest="${RESTORE_DEST}/databases"
    mkdir -p "${db_dest}"

    if proxmox-backup-client restore \
        "${SNAPSHOT_PATH}" \
        "enhance-cp-db.pxar" \
        "${db_dest}" \
        --repository "${PBS_REPOSITORY}" \
        --keyfile "${PBS_KEYFILE}"; then

        log_success "Database dumps extracted to: ${db_dest}"

        # List extracted dumps
        echo ""
        echo "=== Extracted Database Dumps ==="
        ls -lh "${db_dest}/"
        echo "================================"
        echo ""
    else
        die "Failed to extract database dumps"
    fi
}

# Extract certificates and keys
extract_keys() {
    log_info "Extracting certificates and keys..."

    # SSL certificates
    local certs_dest="${RESTORE_DEST}/ssl-certs"
    mkdir -p "${certs_dest}"

    if proxmox-backup-client restore \
        "${SNAPSHOT_PATH}" \
        "enhance-cp-ssl-certs.pxar" \
        "${certs_dest}" \
        --repository "${PBS_REPOSITORY}" \
        --keyfile "${PBS_KEYFILE}" 2>/dev/null; then

        log_success "SSL certificates extracted to: ${certs_dest}"
    else
        log_warning "Could not extract SSL certificates (archive may not exist)"
    fi

    # SSL private keys
    local keys_dest="${RESTORE_DEST}/ssl-keys"
    mkdir -p "${keys_dest}"

    if proxmox-backup-client restore \
        "${SNAPSHOT_PATH}" \
        "enhance-cp-ssl-keys.pxar" \
        "${keys_dest}" \
        --repository "${PBS_REPOSITORY}" \
        --keyfile "${PBS_KEYFILE}" 2>/dev/null; then

        log_success "SSL private keys extracted to: ${keys_dest}"
    else
        log_warning "Could not extract SSL private keys (archive may not exist)"
    fi

    # Orchd directory (contains private keys, cloudflare key, rca.pw)
    local orchd_dest="${RESTORE_DEST}/orchd"
    mkdir -p "${orchd_dest}"

    if proxmox-backup-client restore \
        "${SNAPSHOT_PATH}" \
        "enhance-cp-orchd.pxar" \
        "${orchd_dest}" \
        --repository "${PBS_REPOSITORY}" \
        --keyfile "${PBS_KEYFILE}"; then

        log_success "Orchd directory extracted to: ${orchd_dest}"

        echo ""
        echo "=== Extracted Keys and Configs ==="
        echo "Orchd private key: ${orchd_dest}/private/orchd.key"
        if [[ -f "${orchd_dest}/cloudflare.key" ]]; then
            echo "Cloudflare key: ${orchd_dest}/cloudflare.key"
        fi
        echo "==================================="
        echo ""
    else
        die "Failed to extract orchd directory"
    fi
}

# Extract control panel assets
extract_assets() {
    log_info "Extracting control panel assets..."

    local assets_dest="${RESTORE_DEST}/assets"
    mkdir -p "${assets_dest}"

    if proxmox-backup-client restore \
        "${SNAPSHOT_PATH}" \
        "enhance-cp-assets.pxar" \
        "${assets_dest}" \
        --repository "${PBS_REPOSITORY}" \
        --keyfile "${PBS_KEYFILE}" 2>/dev/null; then

        log_success "Control panel assets extracted to: ${assets_dest}"
    else
        log_warning "Could not extract assets (archive may not exist)"
    fi
}

# Perform selective or full extraction
if [[ "$DB_ONLY" == true ]]; then
    extract_databases
    log_success "Database extraction completed"
    exit 0
fi

if [[ "$KEYS_ONLY" == true ]]; then
    extract_keys
    log_success "Keys extraction completed"
    exit 0
fi

# Full extraction
log_info "Performing full extraction of all components..."

# Confirm before proceeding
if [[ -t 0 ]]; then
    echo ""
    echo "=== Restore Summary ==="
    echo "Snapshot:    ${SNAPSHOT_PATH}"
    echo "Destination: ${RESTORE_DEST}"
    echo ""
    echo "This will extract:"
    echo "  - Database dumps (orchd, authd)"
    echo "  - SSL certificates and private keys"
    echo "  - Orchd directory (private keys, cloudflare key)"
    echo "  - Control panel assets"
    echo "======================="
    echo ""
    read -p "Proceed with extraction? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Restore cancelled by user"
        exit 0
    fi
fi

# Extract all components
extract_databases
extract_keys
extract_assets

# Print migration guide
echo ""
echo "=============================================="
echo "  ENHANCE CONTROL PANEL MIGRATION GUIDE"
echo "=============================================="
echo ""
echo "All components extracted to: ${RESTORE_DEST}"
echo ""
echo "IMPORTANT: Follow the official migration documentation:"
echo "  https://enhance.com/docs/advanced/control-panel-migration.html"
echo ""
echo "EXTRACTED FILES:"
echo ""
echo "1. Database Dumps (PostgreSQL custom format):"
echo "   ${RESTORE_DEST}/databases/orchd.dump"
echo "   ${RESTORE_DEST}/databases/authd.dump"
echo ""
echo "2. SSL Certificates:"
echo "   ${RESTORE_DEST}/ssl-certs/ → /etc/ssl/certs/enhance/"
echo ""
echo "3. SSL Private Keys:"
echo "   ${RESTORE_DEST}/ssl-keys/ → /etc/ssl/private/enhance/"
echo ""
echo "4. Orchd Private Keys:"
echo "   ${RESTORE_DEST}/orchd/private/ → /var/local/enhance/orchd/private/"
echo ""
echo "5. Control Panel Assets:"
echo "   ${RESTORE_DEST}/assets/ → /var/www/control-panel/assets/"
echo ""
echo "RESTORE COMMANDS (run on new server after fresh Enhance install):"
echo ""
echo "# Restore databases:"
echo "sudo -u postgres pg_restore -d orchd ${RESTORE_DEST}/databases/orchd.dump"
echo "sudo -u postgres pg_restore -d authd ${RESTORE_DEST}/databases/authd.dump"
echo ""
echo "# Copy SSL certificates:"
echo "cp -r ${RESTORE_DEST}/ssl-certs/* /etc/ssl/certs/enhance/"
echo "cp -r ${RESTORE_DEST}/ssl-keys/* /etc/ssl/private/enhance/"
echo ""
echo "# Copy orchd private keys:"
echo "cp -r ${RESTORE_DEST}/orchd/private/* /var/local/enhance/orchd/private/"
echo "chown -R orchd:root /var/local/enhance/orchd/private/"
echo "chmod 700 /var/local/enhance/orchd/private/"
echo ""
echo "# If using Cloudflare:"
echo "cp ${RESTORE_DEST}/orchd/cloudflare.key /var/local/enhance/orchd/"
echo ""
echo "# Copy assets (if customized):"
echo "cp -r ${RESTORE_DEST}/assets/* /var/www/control-panel/assets/"
echo ""
echo "# Regenerate control panel proxies:"
echo "ecp regenerate-control-panel-proxies"
echo ""
echo "=============================================="

log_success "Enhance Control Panel restore extraction completed"
log_info "Follow the migration guide above to complete the process"
