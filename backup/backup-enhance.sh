#!/bin/bash
# Enhance Backup Server - PBS Backup Script
# Backs up /backups directory with UID/GID metadata for restore to new servers

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

# Enhance-specific settings
# Auto-detect backup directory from Enhance appcd config
ENHANCE_APPCD_CONFIG="/var/local/enhance/appcd/manager.json"
if [[ -f "$ENHANCE_APPCD_CONFIG" ]] && command -v python3 &> /dev/null; then
    DETECTED_BACKUP_DIR=$(python3 -c "import json; print(json.load(open('$ENHANCE_APPCD_CONFIG')).get('backup_targets', ['/backups'])[0])" 2>/dev/null)
    ENHANCE_BACKUP_DIR="${DETECTED_BACKUP_DIR:-/backups}"
else
    ENHANCE_BACKUP_DIR="/backups"
fi
ENHANCE_METADATA_FILE="${ENHANCE_BACKUP_DIR}/.pbs_user_metadata.json"

# Lock file to prevent concurrent runs
LOCKFILE="/var/lock/pbs-backup-enhance.lock"

# Verify prerequisites
check_root
check_pbs_client
check_keyfile

# Acquire lock to prevent concurrent runs
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    die "Another instance of backup-enhance.sh is already running. Exiting."
fi

# Setup logging
LOG_DIR=$(setup_logging)
LOG_FILE="${LOG_DIR}/backup-enhance-$(date '+%Y%m%d-%H%M%S').log"

exec > >(tee -a "$LOG_FILE") 2>&1

log_info "Starting Enhance backup server backup"
log_info "Backup directory: ${ENHANCE_BACKUP_DIR}"
log_info "Repository: ${PBS_REPOSITORY}"
log_info "Log file: ${LOG_FILE}"

# Verify backup directory exists
if [[ ! -d "${ENHANCE_BACKUP_DIR}" ]]; then
    die "Enhance backup directory not found: ${ENHANCE_BACKUP_DIR}"
fi

# Test PBS connection
test_pbs_connection || die "Cannot connect to PBS server"

# Generate UID/GID metadata for all site folders
generate_user_metadata() {
    log_info "Generating user/group metadata for site folders..."

    local metadata_tmp="${ENHANCE_METADATA_FILE}.tmp"

    echo "{" > "$metadata_tmp"
    echo '  "generated": "'"$(date -Iseconds)"'",' >> "$metadata_tmp"
    echo '  "hostname": "'"$(hostname -f)"'",' >> "$metadata_tmp"
    echo '  "sites": {' >> "$metadata_tmp"

    local first=true
    local site_count=0

    for site_path in "${ENHANCE_BACKUP_DIR}"/*; do
        [[ -d "$site_path" ]] || continue

        # Skip hidden directories and metadata file
        local site_id
        site_id="$(basename "$site_path")"
        [[ "$site_id" == .* ]] && continue

        # Get ownership info
        local owner group uid gid home_dir
        owner=$(stat -c %U "$site_path")
        group=$(stat -c %G "$site_path")
        uid=$(stat -c %u "$site_path")
        gid=$(stat -c %g "$site_path")

        # Get home directory from passwd (may not exist for all users)
        home_dir=$(getent passwd "$owner" 2>/dev/null | cut -d: -f6 || echo "")

        if [[ "$first" == true ]]; then
            first=false
        else
            echo "," >> "$metadata_tmp"
        fi

        # Write site metadata (no trailing comma handling done above)
        cat >> "$metadata_tmp" << EOF
    "$site_id": {
      "owner": "$owner",
      "group": "$group",
      "uid": $uid,
      "gid": $gid,
      "home": "$home_dir"
    }
EOF
        ((site_count++))
    done

    echo "" >> "$metadata_tmp"
    echo "  }" >> "$metadata_tmp"
    echo "}" >> "$metadata_tmp"

    # Validate JSON and move to final location
    if command -v jq &> /dev/null; then
        if jq . "$metadata_tmp" > /dev/null 2>&1; then
            mv "$metadata_tmp" "$ENHANCE_METADATA_FILE"
            log_success "Generated metadata for ${site_count} sites"
        else
            log_error "Generated invalid JSON, check ${metadata_tmp}"
            die "Metadata generation failed"
        fi
    else
        # No jq available, just move the file
        mv "$metadata_tmp" "$ENHANCE_METADATA_FILE"
        log_success "Generated metadata for ${site_count} sites (not validated - jq not installed)"
    fi

    # Set secure permissions on metadata file
    chmod 600 "$ENHANCE_METADATA_FILE"
}

# Generate metadata before backup
generate_user_metadata

# Build archive list
# - root.pxar: Full system for complete DR
# - backups.pxar: Just the backups dir for easy selective restore of individual sites
ARCHIVES=(
    "root.pxar:/"
    "backups.pxar:${ENHANCE_BACKUP_DIR}"
)

log_info "Archives to backup:"
log_info "  - root.pxar: Full system backup"
log_info "  - backups.pxar: ${ENHANCE_BACKUP_DIR} (for selective site restore)"

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

log_success "Enhance backup completed for ${PBS_HOSTNAME}"
