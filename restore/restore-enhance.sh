#!/bin/bash
# Enhance Backup Server - PBS Restore Script
# Restores /backups directory with optional user/group creation for new servers

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

# Usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS] <snapshot_path>

Restore Enhance backup server data from PBS.

Arguments:
    snapshot_path       Path to snapshot (e.g., host/myserver/2025-01-22T15:19:17Z)

Options:
    -l, --list          List available snapshots
    -c, --create-users  Create users/groups from metadata (for new server restore)
    -m, --metadata-only Extract and display metadata without full restore
    -d, --dest PATH     Restore to alternate destination (default: ${ENHANCE_BACKUP_DIR})
    -h, --help          Show this help message

Examples:
    # List available snapshots
    $0 --list

    # Restore to existing server (users already exist)
    $0 "host/enhance-backup/2025-01-22T15:19:17Z"

    # Restore to new server (create users first)
    $0 --create-users "host/enhance-backup/2025-01-22T15:19:17Z"

    # Extract metadata only (to review before restore)
    $0 --metadata-only "host/enhance-backup/2025-01-22T15:19:17Z"
EOF
    exit 1
}

# Parse arguments
CREATE_USERS=false
METADATA_ONLY=false
RESTORE_DEST="${ENHANCE_BACKUP_DIR}"
SNAPSHOT_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--list)
            load_config
            list_snapshots
            exit 0
            ;;
        -c|--create-users)
            CREATE_USERS=true
            shift
            ;;
        -m|--metadata-only)
            METADATA_ONLY=true
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

# Verify prerequisites
check_root
check_pbs_client
check_keyfile

# Setup logging
LOG_DIR=$(setup_logging)
LOG_FILE="${LOG_DIR}/restore-enhance-$(date '+%Y%m%d-%H%M%S').log"

exec > >(tee -a "$LOG_FILE") 2>&1

log_info "Starting Enhance backup server restore"
log_info "Snapshot: ${SNAPSHOT_PATH}"
log_info "Destination: ${RESTORE_DEST}"
log_info "Create users: ${CREATE_USERS}"
log_info "Repository: ${PBS_REPOSITORY}"
log_info "Log file: ${LOG_FILE}"

# Test PBS connection
test_pbs_connection || die "Cannot connect to PBS server"

# Create temporary directory for metadata extraction
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Extract metadata file first
extract_metadata() {
    log_info "Extracting user metadata from backup..."

    # Restore just the metadata file to temp location
    if proxmox-backup-client restore \
        "${SNAPSHOT_PATH}" \
        "backups.pxar" \
        "${TEMP_DIR}" \
        --repository "${PBS_REPOSITORY}" \
        --keyfile "${PBS_KEYFILE}" \
        --include ".pbs_user_metadata.json" 2>/dev/null; then

        if [[ -f "${TEMP_DIR}/.pbs_user_metadata.json" ]]; then
            log_success "Metadata extracted successfully"
            return 0
        fi
    fi

    log_warning "Could not extract metadata file - backup may predate metadata feature"
    return 1
}

# Create users and groups from metadata
create_users_from_metadata() {
    local metadata_file="$1"

    if [[ ! -f "$metadata_file" ]]; then
        die "Metadata file not found: $metadata_file"
    fi

    if ! command -v jq &> /dev/null; then
        die "jq is required for user creation. Install with: apt install jq"
    fi

    log_info "Creating users and groups from metadata..."

    local site_count=0
    local created_groups=()
    local created_users=()

    # Read all sites from metadata
    local sites
    sites=$(jq -r '.sites | keys[]' "$metadata_file")

    for site_id in $sites; do
        local owner group uid gid home_dir
        owner=$(jq -r ".sites[\"$site_id\"].owner" "$metadata_file")
        group=$(jq -r ".sites[\"$site_id\"].group" "$metadata_file")
        uid=$(jq -r ".sites[\"$site_id\"].uid" "$metadata_file")
        gid=$(jq -r ".sites[\"$site_id\"].gid" "$metadata_file")
        home_dir=$(jq -r ".sites[\"$site_id\"].home" "$metadata_file")

        # Set default home if empty
        if [[ -z "$home_dir" || "$home_dir" == "null" ]]; then
            home_dir="/home/$owner"
        fi

        log_info "Processing site $site_id: user=$owner($uid) group=$group($gid)"

        # Create group if it doesn't exist
        if ! getent group "$group" >/dev/null 2>&1; then
            log_info "Creating group: $group (gid=$gid)"
            groupadd --gid "$gid" "$group"
            created_groups+=("$group")
        else
            local existing_gid
            existing_gid=$(getent group "$group" | cut -d: -f3)
            if [[ "$existing_gid" != "$gid" ]]; then
                log_warning "Group $group exists with different GID ($existing_gid vs $gid)"
                log_info "Modifying group $group to GID $gid"
                groupmod -g "$gid" "$group"
            fi
        fi

        # Create user if it doesn't exist
        if ! id "$owner" >/dev/null 2>&1; then
            log_info "Creating user: $owner (uid=$uid, gid=$gid, home=$home_dir)"
            useradd \
                --uid "$uid" \
                --gid "$gid" \
                --home-dir "$home_dir" \
                --shell /usr/sbin/nologin \
                --no-create-home \
                "$owner"
            created_users+=("$owner")
        else
            local existing_uid existing_gid
            existing_uid=$(id -u "$owner")
            existing_gid=$(id -g "$owner")
            if [[ "$existing_uid" != "$uid" || "$existing_gid" != "$gid" ]]; then
                log_warning "User $owner exists with different UID/GID ($existing_uid/$existing_gid vs $uid/$gid)"
                log_info "Modifying user $owner to UID $uid, GID $gid"
                usermod -u "$uid" -g "$gid" "$owner"
            fi
        fi

        ((site_count++))
    done

    log_success "Processed $site_count sites"
    if [[ ${#created_groups[@]} -gt 0 ]]; then
        log_info "Created groups: ${created_groups[*]}"
    fi
    if [[ ${#created_users[@]} -gt 0 ]]; then
        log_info "Created users: ${created_users[*]}"
    fi
}

# Display metadata
display_metadata() {
    local metadata_file="$1"

    if command -v jq &> /dev/null; then
        echo ""
        echo "=== Backup Metadata ==="
        jq '.' "$metadata_file"
        echo "======================="
        echo ""

        local site_count
        site_count=$(jq '.sites | length' "$metadata_file")
        log_info "Backup contains $site_count sites"
    else
        echo ""
        echo "=== Backup Metadata (raw) ==="
        cat "$metadata_file"
        echo ""
        echo "============================="
    fi
}

# Extract metadata
if extract_metadata; then
    METADATA_EXTRACTED="${TEMP_DIR}/.pbs_user_metadata.json"

    # Display metadata
    display_metadata "$METADATA_EXTRACTED"

    # If metadata-only mode, stop here
    if [[ "$METADATA_ONLY" == true ]]; then
        log_info "Metadata-only mode - skipping full restore"
        exit 0
    fi

    # Create users if requested
    if [[ "$CREATE_USERS" == true ]]; then
        create_users_from_metadata "$METADATA_EXTRACTED"
    fi
else
    if [[ "$METADATA_ONLY" == true ]]; then
        die "Cannot extract metadata from this backup"
    fi

    if [[ "$CREATE_USERS" == true ]]; then
        die "Cannot create users - metadata file not found in backup"
    fi

    log_warning "Proceeding with restore without metadata"
fi

# Confirm before full restore
if [[ -t 0 ]]; then
    echo ""
    echo "=== Restore Summary ==="
    echo "Snapshot:    ${SNAPSHOT_PATH}"
    echo "Destination: ${RESTORE_DEST}"
    echo "Archive:     backups.pxar"
    if [[ "$CREATE_USERS" == true ]]; then
        echo "Users:       Created from metadata"
    fi
    echo "======================="
    echo ""
    echo "WARNING: This will overwrite existing files in ${RESTORE_DEST}"
    read -p "Proceed with restore? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Restore cancelled by user"
        exit 0
    fi
fi

# Create destination directory
mkdir -p "$RESTORE_DEST"

# Perform full restore
log_info "Starting full restore to ${RESTORE_DEST}..."

if proxmox-backup-client restore \
    "${SNAPSHOT_PATH}" \
    "backups.pxar" \
    "${RESTORE_DEST}" \
    --repository "${PBS_REPOSITORY}" \
    --keyfile "${PBS_KEYFILE}"; then

    log_success "Restore completed successfully"

    # Show summary
    local site_count
    site_count=$(find "$RESTORE_DEST" -mindepth 1 -maxdepth 1 -type d ! -name ".*" | wc -l)
    log_info "Restored ${site_count} site directories to ${RESTORE_DEST}"
else
    die "Restore failed"
fi

log_success "Enhance restore completed"
