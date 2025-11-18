#!/bin/bash
# Base restore script for PBS
# Usage: ./restore-base.sh <snapshot> <archive> <destination>

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
Usage: $0 <snapshot_path> <archive_name> <destination>

Arguments:
    snapshot_path   Path to snapshot (e.g., host/myserver/2025-01-22T15:19:17Z)
    archive_name    Name of archive to restore (e.g., etc.pxar)
    destination     Local path to restore to

Options:
    -l, --list      List available snapshots
    -h, --help      Show this help message

Examples:
    $0 "host/myserver/2025-01-22T15:19:17Z" etc.pxar /tmp/restore-etc
    $0 --list
EOF
    exit 1
}

# Parse arguments
if [[ $# -eq 0 ]]; then
    usage
fi

case "${1:-}" in
    -l|--list)
        load_config
        list_snapshots
        exit 0
        ;;
    -h|--help)
        usage
        ;;
esac

# Require all arguments for restore
if [[ $# -lt 3 ]]; then
    usage
fi

SNAPSHOT_PATH="$1"
ARCHIVE_NAME="$2"
RESTORE_DEST="$3"

# Verify prerequisites
check_root
check_pbs_client
check_keyfile

# Setup logging
LOG_DIR=$(setup_logging)
LOG_FILE="${LOG_DIR}/restore-$(date '+%Y%m%d-%H%M%S').log"

exec > >(tee -a "$LOG_FILE") 2>&1

log_info "Starting restore operation"
log_info "Repository: ${PBS_REPOSITORY}"
log_info "Snapshot: ${SNAPSHOT_PATH}"
log_info "Archive: ${ARCHIVE_NAME}"
log_info "Destination: ${RESTORE_DEST}"
log_info "Log file: ${LOG_FILE}"

# Test connection
test_pbs_connection || die "Cannot connect to PBS server"

# Create destination directory
mkdir -p "$RESTORE_DEST"

# Confirm with user (if interactive)
if [[ -t 0 ]]; then
    echo ""
    echo "=== Restore Summary ==="
    echo "Snapshot:    ${SNAPSHOT_PATH}"
    echo "Archive:     ${ARCHIVE_NAME}"
    echo "Destination: ${RESTORE_DEST}"
    echo "======================="
    echo ""
    read -p "Proceed with restore? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Restore cancelled by user"
        exit 0
    fi
fi

# Perform restore
log_info "Executing restore..."

if proxmox-backup-client restore \
    "${SNAPSHOT_PATH}" \
    "${ARCHIVE_NAME}" \
    "${RESTORE_DEST}" \
    --repository "${PBS_REPOSITORY}" \
    --keyfile "${PBS_KEYFILE}"; then

    log_success "Restore completed successfully"
    log_info "Files restored to: ${RESTORE_DEST}"

    # Show restored files
    if command -v tree &> /dev/null; then
        log_info "Restored structure:"
        tree -L 2 "$RESTORE_DEST" 2>/dev/null || ls -la "$RESTORE_DEST"
    else
        ls -la "$RESTORE_DEST"
    fi
else
    die "Restore failed"
fi

log_success "Restore process completed"
