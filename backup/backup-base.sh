#!/bin/bash
# Base backup script for PBS
# This serves as a foundation for server-specific backup scripts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load common functions
# shellcheck source=../lib/common.sh
source "${PROJECT_DIR}/lib/common.sh"

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

# Build archive list based on server type
# This will be extended by server-specific scripts
ARCHIVES=()

# Common archives for all server types
ARCHIVES+=("etc.pxar:/etc")

# Add type-specific archives
# This section will be overridden by server-specific backup scripts

# Perform backup
log_info "Starting PBS backup with ${#ARCHIVES[@]} archives..."

# Build the backup command
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
if "${BACKUP_CMD[@]}"; then
    log_success "Backup completed successfully"
else
    die "Backup failed"
fi

# List snapshots
log_info "Current snapshots:"
list_snapshots

log_success "Backup process completed for ${PBS_HOSTNAME}"
