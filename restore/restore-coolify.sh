#!/bin/bash
# Coolify Instance - PBS Restore Script
# Restores Coolify configuration, SSH keys, and database from PBS backup

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load common functions
# shellcheck source=../lib/common.sh
source "${PROJECT_DIR}/lib/common.sh"

# Load configuration
load_config

# Coolify-specific settings
COOLIFY_DATA_DIR="/data/coolify"
COOLIFY_ENV_FILE="${COOLIFY_DATA_DIR}/source/.env"
COOLIFY_SSH_DIR="${COOLIFY_DATA_DIR}/ssh/keys"
COOLIFY_DB_CONTAINER="coolify-db"
COOLIFY_DB_USER="coolify"
COOLIFY_DB_NAME="coolify"

# Usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS] <snapshot_path>

Restore Coolify instance from PBS backup.

Arguments:
    snapshot_path       Path to snapshot (e.g., host/coolify-server/2025-01-22T15:19:17Z)

Options:
    -l, --list          List available snapshots
    -e, --env-only      Extract only the .env file (to get APP_KEY)
    -s, --ssh-only      Extract only SSH keys
    -b, --db-only       Extract only database dump
    -d, --dest PATH     Restore to alternate destination (default: show current locations)
    -h, --help          Show this help message

Examples:
    # List available snapshots
    $0 --list

    # Extract just the APP_KEY (to get APP_PREVIOUS_KEYS value)
    $0 --env-only "host/coolify-server/2025-01-22T15:19:17Z"

    # Extract just SSH keys
    $0 --ssh-only "host/coolify-server/2025-01-22T15:19:17Z"

    # Extract database dump for manual restore
    $0 --db-only "host/coolify-server/2025-01-22T15:19:17Z"

    # Full guided restore
    $0 "host/coolify-server/2025-01-22T15:19:17Z"

Restore Process (for new server):
    1. Install fresh Coolify instance (matching version)
    2. Stop Coolify services
    3. Use this script to extract components
    4. Restore database with pg_restore
    5. Copy SSH keys to /data/coolify/ssh/keys/
    6. Add APP_PREVIOUS_KEYS to .env
    7. Restart Coolify
EOF
    exit 1
}

# Parse arguments
ENV_ONLY=false
SSH_ONLY=false
DB_ONLY=false
RESTORE_DEST=""
SNAPSHOT_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--list)
            load_config
            list_snapshots
            exit 0
            ;;
        -e|--env-only)
            ENV_ONLY=true
            shift
            ;;
        -s|--ssh-only)
            SSH_ONLY=true
            shift
            ;;
        -b|--db-only)
            DB_ONLY=true
            shift
            ;;
        -d|--dest)
            RESTORE_DEST="$2"
            shift 2
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
    RESTORE_DEST="/tmp/coolify-restore-$(date '+%Y%m%d-%H%M%S')"
fi

# Verify prerequisites
check_root
check_pbs_client
check_keyfile

# Setup logging
LOG_DIR=$(setup_logging)
LOG_FILE="${LOG_DIR}/restore-coolify-$(date '+%Y%m%d-%H%M%S').log"

exec > >(tee -a "$LOG_FILE") 2>&1

log_info "Starting Coolify instance restore"
log_info "Snapshot: ${SNAPSHOT_PATH}"
log_info "Destination: ${RESTORE_DEST}"
log_info "Repository: ${PBS_REPOSITORY}"
log_info "Log file: ${LOG_FILE}"

# Test PBS connection
test_pbs_connection || die "Cannot connect to PBS server"

# Create restore destination
mkdir -p "${RESTORE_DEST}"

# Extract .env file (contains APP_KEY)
extract_env() {
    log_info "Extracting .env file..."

    local env_dest="${RESTORE_DEST}/env"
    mkdir -p "${env_dest}"

    if proxmox-backup-client restore \
        "${SNAPSHOT_PATH}" \
        "coolify-env.pxar" \
        "${env_dest}" \
        --repository "${PBS_REPOSITORY}" \
        --keyfile "${PBS_KEYFILE}"; then

        log_success ".env file extracted to: ${env_dest}"

        # Display APP_KEY for reference
        if [[ -f "${env_dest}/.env" ]]; then
            local app_key
            app_key=$(grep "^APP_KEY=" "${env_dest}/.env" | cut -d'=' -f2-)
            echo ""
            echo "=== APP_KEY Found ==="
            echo "APP_KEY=${app_key}"
            echo ""
            echo "For restoration to a new server, add this to your new .env:"
            echo "APP_PREVIOUS_KEYS=${app_key}"
            echo "====================="
            echo ""
        fi
    else
        die "Failed to extract .env file"
    fi
}

# Extract SSH keys
extract_ssh() {
    log_info "Extracting SSH keys..."

    local ssh_dest="${RESTORE_DEST}/ssh"
    mkdir -p "${ssh_dest}"

    if proxmox-backup-client restore \
        "${SNAPSHOT_PATH}" \
        "coolify-ssh.pxar" \
        "${ssh_dest}" \
        --repository "${PBS_REPOSITORY}" \
        --keyfile "${PBS_KEYFILE}"; then

        log_success "SSH keys extracted to: ${ssh_dest}"

        # List extracted keys
        echo ""
        echo "=== Extracted SSH Keys ==="
        ls -la "${ssh_dest}/"
        echo "=========================="
        echo ""
        echo "To restore SSH keys to new server:"
        echo "  1. Remove auto-generated keys: rm -rf ${COOLIFY_SSH_DIR}/*"
        echo "  2. Copy these keys: cp -r ${ssh_dest}/* ${COOLIFY_SSH_DIR}/"
        echo "  3. Set permissions: chmod 600 ${COOLIFY_SSH_DIR}/*"
        echo ""
    else
        die "Failed to extract SSH keys"
    fi
}

# Extract database dump
extract_db() {
    log_info "Extracting database dump..."

    local db_dest="${RESTORE_DEST}/db"
    mkdir -p "${db_dest}"

    if proxmox-backup-client restore \
        "${SNAPSHOT_PATH}" \
        "coolify-db.pxar" \
        "${db_dest}" \
        --repository "${PBS_REPOSITORY}" \
        --keyfile "${PBS_KEYFILE}"; then

        log_success "Database dump extracted to: ${db_dest}"

        # Find the dump file
        local dump_file
        dump_file=$(find "${db_dest}" -name "*.dump" -type f | head -1)

        if [[ -n "$dump_file" ]]; then
            local dump_size
            dump_size=$(stat -c %s "${dump_file}" 2>/dev/null || stat -f %z "${dump_file}" 2>/dev/null)

            echo ""
            echo "=== Database Dump ==="
            echo "File: ${dump_file}"
            echo "Size: $(format_bytes "$dump_size")"
            echo ""
            echo "To restore the database:"
            echo "  1. Stop Coolify services:"
            echo "     docker stop coolify coolify-redis coolify-realtime coolify-proxy"
            echo ""
            echo "  2. Restore the database:"
            echo "     cat ${dump_file} | docker exec -i ${COOLIFY_DB_CONTAINER} \\"
            echo "       pg_restore --verbose --clean --no-acl --no-owner \\"
            echo "       -U ${COOLIFY_DB_USER} -d ${COOLIFY_DB_NAME}"
            echo ""
            echo "  Note: Warnings about foreign keys or sequences can usually be ignored."
            echo "====================="
            echo ""
        fi
    else
        die "Failed to extract database dump"
    fi
}

# Perform selective or full extraction
if [[ "$ENV_ONLY" == true ]]; then
    extract_env
    log_success "ENV extraction completed"
    exit 0
fi

if [[ "$SSH_ONLY" == true ]]; then
    extract_ssh
    log_success "SSH keys extraction completed"
    exit 0
fi

if [[ "$DB_ONLY" == true ]]; then
    extract_db
    log_success "Database dump extraction completed"
    exit 0
fi

# Full restore - extract all components
log_info "Performing full extraction of all Coolify components..."

# Confirm before proceeding
if [[ -t 0 ]]; then
    echo ""
    echo "=== Restore Summary ==="
    echo "Snapshot:    ${SNAPSHOT_PATH}"
    echo "Destination: ${RESTORE_DEST}"
    echo ""
    echo "This will extract:"
    echo "  - .env file (contains APP_KEY)"
    echo "  - SSH keys"
    echo "  - Database dump (PostgreSQL custom format)"
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
extract_env
extract_ssh
extract_db

# Print full restoration guide
echo ""
echo "=============================================="
echo "     COOLIFY RESTORATION GUIDE"
echo "=============================================="
echo ""
echo "All components extracted to: ${RESTORE_DEST}"
echo ""
echo "STEP 1: Install Fresh Coolify"
echo "  Run the Coolify installation script with matching version"
echo ""
echo "STEP 2: Stop Coolify Services"
echo "  docker stop coolify coolify-redis coolify-realtime coolify-proxy"
echo ""
echo "STEP 3: Restore Database"
echo "  cat ${RESTORE_DEST}/db/coolify-db-dump/coolify.dump | docker exec -i ${COOLIFY_DB_CONTAINER} \\"
echo "    pg_restore --verbose --clean --no-acl --no-owner -U ${COOLIFY_DB_USER} -d ${COOLIFY_DB_NAME}"
echo ""
echo "STEP 4: Restore SSH Keys"
echo "  rm -rf ${COOLIFY_SSH_DIR}/*"
echo "  cp ${RESTORE_DEST}/ssh/keys/* ${COOLIFY_SSH_DIR}/"
echo "  chmod 600 ${COOLIFY_SSH_DIR}/*"
echo ""
echo "STEP 5: Update .env with Previous APP_KEY"
echo "  Edit ${COOLIFY_ENV_FILE}"
echo "  Add: APP_PREVIOUS_KEYS=<value from extracted .env>"
echo ""
echo "STEP 6: Fix Permissions (if needed)"
echo "  sudo chown -R root:root /data/coolify"
echo ""
echo "STEP 7: Restart Coolify"
echo "  Re-run the Coolify installation script with the version number"
echo ""
echo "STEP 8: Verify"
echo "  - Check web UI loads without 500 errors"
echo "  - Verify servers are reachable"
echo "  - Test application deployments"
echo ""
echo "=============================================="

log_success "Coolify restore extraction completed"
log_info "Follow the restoration guide above to complete the process"
