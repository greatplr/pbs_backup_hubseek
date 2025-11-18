#!/bin/bash
# Enhance Backup Server - PBS Backup Script
# Backs up /backups directory with UID/GID metadata for restore to new servers

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load common functions
# shellcheck source=../lib/common.sh
source "${PROJECT_DIR}/lib/common.sh"

# Load configuration
load_config

# Enhance-specific settings
ENHANCE_BACKUP_DIR="/backups"
ENHANCE_METADATA_FILE="${ENHANCE_BACKUP_DIR}/.pbs_user_metadata.json"

# Verify prerequisites
check_root
check_pbs_client
check_keyfile

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
ARCHIVES=(
    "backups.pxar:${ENHANCE_BACKUP_DIR}"
)

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

if "${BACKUP_CMD[@]}"; then
    log_success "PBS backup completed successfully"
else
    die "PBS backup failed"
fi

# List recent snapshots
log_info "Recent snapshots:"
list_snapshots

log_success "Enhance backup completed for ${PBS_HOSTNAME}"
