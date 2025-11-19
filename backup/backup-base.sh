#!/bin/bash
# Base backup script for PBS
# This serves as a foundation for server-specific backup scripts

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

# Verify prerequisites
check_root
check_pbs_client
check_keyfile

# Setup
LOG_DIR=$(setup_logging)
LOG_FILE="${LOG_DIR}/backup-$(date '+%Y%m%d-%H%M%S').log"

# Redirect output to log file while keeping console output
exec > >(tee -a "$LOG_FILE") 2>&1

log_info "Starting backup for ${PBS_HOSTNAME}"
log_info "Repository: ${PBS_REPOSITORY}"
log_info "Log file: ${LOG_FILE}"

# Test connection
test_pbs_connection || die "Cannot connect to PBS server"

# Detect or use configured server type
if [[ "${SERVER_TYPE:-auto}" == "auto" ]]; then
    DETECTED_TYPES=$(detect_server_type)
    log_info "Detected server types: ${DETECTED_TYPES}"
else
    DETECTED_TYPES="${SERVER_TYPE}"
    log_info "Using configured server type: ${DETECTED_TYPES}"
fi

# Full system backup
ARCHIVES=(
    "root.pxar:/"
)

log_info "Performing full system backup"

# Perform backup
log_info "Starting PBS backup..."

# Build the backup command
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
        log_success "Backup completed successfully"
    else
        die "Backup failed"
    fi
fi

# List snapshots
log_info "Current snapshots:"
list_snapshots

log_success "Backup process completed for ${PBS_HOSTNAME}"
