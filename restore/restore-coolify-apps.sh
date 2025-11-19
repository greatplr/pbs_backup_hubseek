#!/bin/bash
# Coolify Applications - PBS Restore Script
# Restores Docker volumes, bind mounts, and database dumps for deployed applications

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

Restore Coolify application data from PBS backup.

Arguments:
    snapshot_path       Path to snapshot (e.g., host/coolify-server/2025-01-22T15:19:17Z)

Options:
    -l, --list          List available snapshots
    -m, --metadata-only Extract and display metadata without restoring
    -v, --volume NAME   Restore specific volume only
    -b, --bind PATH     Restore specific bind mount only
    -D, --db NAME       Restore specific database dump only
    -d, --dest PATH     Extract to alternate destination (default: /tmp/coolify-apps-restore-*)
    -h, --help          Show this help message

Examples:
    # List available snapshots
    $0 --list

    # Extract metadata to review containers and credentials
    $0 --metadata-only "host/coolify-server/2025-01-22T15:19:17Z"

    # Full extraction (all volumes, binds, databases)
    $0 "host/coolify-server/2025-01-22T15:19:17Z"

    # Restore specific volume
    $0 --volume "my-app-data" "host/coolify-server/2025-01-22T15:19:17Z"

    # Restore specific database
    $0 --db "postgres-container" "host/coolify-server/2025-01-22T15:19:17Z"

Restore Process:
    1. Extract backup to review metadata and identify needed items
    2. Stop target containers if restoring to same server
    3. Restore volumes using Docker's recommended method
    4. Restore databases using appropriate restore commands
    5. Restart containers
EOF
    exit 1
}

# Parse arguments
METADATA_ONLY=false
SPECIFIC_VOLUME=""
SPECIFIC_BIND=""
SPECIFIC_DB=""
RESTORE_DEST=""
SNAPSHOT_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--list)
            load_config
            list_snapshots
            exit 0
            ;;
        -m|--metadata-only)
            METADATA_ONLY=true
            shift
            ;;
        -v|--volume)
            SPECIFIC_VOLUME="$2"
            shift 2
            ;;
        -b|--bind)
            SPECIFIC_BIND="$2"
            shift 2
            ;;
        -D|--db)
            SPECIFIC_DB="$2"
            shift 2
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
    RESTORE_DEST="/tmp/coolify-apps-restore-$(date '+%Y%m%d-%H%M%S')"
fi

# Verify prerequisites
check_root
check_pbs_client
check_keyfile

# Verify Docker is available
if ! command -v docker &> /dev/null; then
    die "Docker is required but not installed"
fi

# Setup logging
LOG_DIR=$(setup_logging)
LOG_FILE="${LOG_DIR}/restore-coolify-apps-$(date '+%Y%m%d-%H%M%S').log"

exec > >(tee -a "$LOG_FILE") 2>&1

log_info "Starting Coolify applications restore"
log_info "Snapshot: ${SNAPSHOT_PATH}"
log_info "Destination: ${RESTORE_DEST}"
log_info "Repository: ${PBS_REPOSITORY}"
log_info "Log file: ${LOG_FILE}"

# Test PBS connection
test_pbs_connection || die "Cannot connect to PBS server"

# Create restore destination
mkdir -p "${RESTORE_DEST}"

# Extract entire backup
log_info "Extracting backup to ${RESTORE_DEST}..."

if proxmox-backup-client restore \
    "${SNAPSHOT_PATH}" \
    "coolify-apps.pxar" \
    "${RESTORE_DEST}" \
    --repository "${PBS_REPOSITORY}" \
    --keyfile "${PBS_KEYFILE}"; then

    log_success "Backup extracted successfully"
else
    die "Failed to extract backup"
fi

# Find extracted directories
EXTRACTED_DIR=$(find "${RESTORE_DEST}" -maxdepth 1 -type d -name "coolify-apps-backup-*" | head -1)
if [[ -z "$EXTRACTED_DIR" ]]; then
    # Might be directly in restore dest
    EXTRACTED_DIR="${RESTORE_DEST}"
fi

METADATA_FILE="${EXTRACTED_DIR}/metadata.json"
VOLUMES_DIR="${EXTRACTED_DIR}/volumes"
BINDS_DIR="${EXTRACTED_DIR}/binds"
DATABASES_DIR="${EXTRACTED_DIR}/databases"

# Check metadata exists
if [[ ! -f "$METADATA_FILE" ]]; then
    die "Metadata file not found in backup"
fi

# Display metadata
display_metadata() {
    if command -v jq &> /dev/null; then
        echo ""
        echo "=== Backup Metadata ==="
        jq '.' "$METADATA_FILE"
        echo "======================="
        echo ""

        # Summary
        local container_count volume_count bind_count
        container_count=$(jq '.containers | length' "$METADATA_FILE")
        volume_count=$(jq '.backed_up_volumes | length' "$METADATA_FILE")
        bind_count=$(jq '.backed_up_binds | length' "$METADATA_FILE")

        log_info "Backup contains:"
        log_info "  Containers: ${container_count}"
        log_info "  Volumes: ${volume_count}"
        log_info "  Bind mounts: ${bind_count}"

        # List databases
        echo ""
        echo "=== Database Containers ==="
        jq -r '.containers | to_entries[] | select(.value.is_database == true) | "\(.key): \(.value.db_type)"' "$METADATA_FILE"
        echo "==========================="
    else
        echo ""
        echo "=== Backup Metadata (raw) ==="
        cat "$METADATA_FILE"
        echo "============================="
    fi
}

display_metadata

# If metadata-only mode, stop here
if [[ "$METADATA_ONLY" == true ]]; then
    log_info "Metadata-only mode - skipping restore"
    log_info "Extracted files available at: ${RESTORE_DEST}"
    exit 0
fi

# Print available files
echo ""
echo "=== Extracted Files ==="

if [[ -d "$VOLUMES_DIR" ]]; then
    echo "Volumes:"
    ls -lh "$VOLUMES_DIR"/ 2>/dev/null || echo "  (none)"
fi

echo ""
if [[ -d "$DATABASES_DIR" ]]; then
    echo "Database dumps:"
    ls -lh "$DATABASES_DIR"/ 2>/dev/null || echo "  (none)"
fi

echo ""
if [[ -d "$BINDS_DIR" ]]; then
    echo "Bind mounts:"
    ls -lh "$BINDS_DIR"/ 2>/dev/null || echo "  (none)"
fi

echo "========================"
echo ""

# Print restoration guide
echo "=============================================="
echo "     APPLICATION RESTORATION GUIDE"
echo "=============================================="
echo ""
echo "All backup artifacts extracted to: ${EXTRACTED_DIR}"
echo ""
echo "RESTORING VOLUMES"
echo "-----------------"
echo "To restore a Docker volume:"
echo ""
echo "  1. Create the volume if it doesn't exist:"
echo "     docker volume create <volume-name>"
echo ""
echo "  2. Restore from archive:"
echo "     docker run --rm \\"
echo "       -v <volume-name>:/volume \\"
echo "       -v ${VOLUMES_DIR}:/backup \\"
echo "       busybox sh -c 'cd /volume && tar xzf /backup/<archive>.tar.gz'"
echo ""

if [[ -d "$VOLUMES_DIR" ]] && [[ -n "$(ls -A "$VOLUMES_DIR" 2>/dev/null)" ]]; then
    echo "Available volume archives:"
    for archive in "$VOLUMES_DIR"/*.tar.gz; do
        [[ -f "$archive" ]] || continue
        basename "$archive" .tar.gz
    done
    echo ""
fi

echo "RESTORING DATABASES"
echo "-------------------"
echo ""

# Get database info from metadata
if command -v jq &> /dev/null; then
    jq -r '.containers | to_entries[] | select(.value.is_database == true) | "\(.key)|\(.value.db_type)"' "$METADATA_FILE" | \
    while IFS='|' read -r container db_type; do
        SAFE_NAME=$(echo "$container" | tr '/:' '_')

        case "$db_type" in
            postgres)
                DUMP_FILE="${DATABASES_DIR}/${SAFE_NAME}.dump"
                if [[ -f "$DUMP_FILE" ]]; then
                    echo "PostgreSQL ($container):"
                    echo "  cat $DUMP_FILE | docker exec -i <container> \\"
                    echo "    pg_restore --verbose --clean --no-acl --no-owner \\"
                    echo "    -U <user> -d <database>"
                    echo ""

                    # Show credentials from metadata
                    USER=$(jq -r ".containers[\"$container\"].env.POSTGRES_USER // \"postgres\"" "$METADATA_FILE")
                    DB=$(jq -r ".containers[\"$container\"].env.POSTGRES_DB // \"postgres\"" "$METADATA_FILE")
                    echo "  Credentials from backup: user=$USER, db=$DB"
                    echo ""
                fi
                ;;
            mysql)
                DUMP_FILE="${DATABASES_DIR}/${SAFE_NAME}.sql"
                if [[ -f "$DUMP_FILE" ]]; then
                    echo "MySQL/MariaDB ($container):"
                    echo "  cat $DUMP_FILE | docker exec -i <container> \\"
                    echo "    mysql -u <user> -p<password> <database>"
                    echo ""

                    # Show credentials from metadata
                    USER=$(jq -r ".containers[\"$container\"].env.MYSQL_USER // .containers[\"$container\"].env.MYSQL_ROOT_USER // \"root\"" "$METADATA_FILE")
                    DB=$(jq -r ".containers[\"$container\"].env.MYSQL_DATABASE // \"(all databases)\"" "$METADATA_FILE")
                    echo "  Credentials from backup: user=$USER, db=$DB"
                    echo ""
                fi
                ;;
            mongo)
                DUMP_FILE="${DATABASES_DIR}/${SAFE_NAME}.archive"
                if [[ -f "$DUMP_FILE" ]]; then
                    echo "MongoDB ($container):"
                    echo "  cat $DUMP_FILE | docker exec -i <container> \\"
                    echo "    mongorestore --archive"
                    echo ""
                fi
                ;;
        esac
    done
fi

echo "RESTORING BIND MOUNTS"
echo "---------------------"
echo "Bind mounts are archived as tar.gz files."
echo "Extract to original location:"
echo ""
echo "  tar xzf ${BINDS_DIR}/<archive>.tar.gz -C <original-path>"
echo ""

if [[ -d "$BINDS_DIR" ]] && [[ -n "$(ls -A "$BINDS_DIR" 2>/dev/null)" ]]; then
    echo "Available bind mount archives:"
    for archive in "$BINDS_DIR"/*.tar.gz; do
        [[ -f "$archive" ]] || continue
        # Convert filename back to path hint
        name=$(basename "$archive" .tar.gz)
        echo "  $name"
    done
    echo ""
fi

echo "CONTAINER ENVIRONMENT VARIABLES"
echo "--------------------------------"
echo "All container environment variables (including credentials)"
echo "are stored in the metadata file:"
echo ""
echo "  ${METADATA_FILE}"
echo ""
echo "View with: jq '.containers[\"container-name\"].env' ${METADATA_FILE}"
echo ""
echo "=============================================="

log_success "Coolify applications restore extraction completed"
log_info "Follow the restoration guide above to restore specific items"
log_info ""
log_info "Extracted files location: ${EXTRACTED_DIR}"
