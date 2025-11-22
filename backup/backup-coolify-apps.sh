#!/bin/bash
# Coolify Applications - PBS Backup Script
# Backs up Docker volumes, bind mounts, and database dumps for deployed applications
# Safe for running containers - uses Docker's recommended backup method and DB dumps

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

# Temporary directory for all backup artifacts
BACKUP_TEMP_DIR="/tmp/coolify-apps-backup-$(date '+%Y%m%d-%H%M%S')"
VOLUMES_DIR="${BACKUP_TEMP_DIR}/volumes"
BINDS_DIR="${BACKUP_TEMP_DIR}/binds"
DATABASES_DIR="${BACKUP_TEMP_DIR}/databases"
METADATA_FILE="${BACKUP_TEMP_DIR}/metadata.json"

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
LOG_FILE="${LOG_DIR}/backup-coolify-apps-$(date '+%Y%m%d-%H%M%S').log"

exec > >(tee -a "$LOG_FILE") 2>&1

log_info "Starting Coolify applications backup"
log_info "Repository: ${PBS_REPOSITORY}"
log_info "Log file: ${LOG_FILE}"

# Test PBS connection
test_pbs_connection || die "Cannot connect to PBS server"

# Create temporary directories
mkdir -p "${VOLUMES_DIR}" "${BINDS_DIR}" "${DATABASES_DIR}"

# Cleanup function
cleanup() {
    if [[ -d "${BACKUP_TEMP_DIR}" ]]; then
        log_info "Cleaning up temporary backup directory..."
        rm -rf "${BACKUP_TEMP_DIR}"
    fi
}

trap cleanup EXIT

# Detect database type from image name
detect_db_type() {
    local image="$1"

    if [[ "$image" == *"postgres"* ]]; then
        echo "postgres"
    elif [[ "$image" == *"mysql"* ]] || [[ "$image" == *"mariadb"* ]]; then
        echo "mysql"
    elif [[ "$image" == *"mongo"* ]]; then
        echo "mongo"
    elif [[ "$image" == *"redis"* ]]; then
        echo "redis"
    else
        echo ""
    fi
}

# Get container environment variable
get_container_env() {
    local container="$1"
    local var_name="$2"

    docker inspect --format "{{range .Config.Env}}{{println .}}{{end}}" "$container" | \
        grep "^${var_name}=" | cut -d'=' -f2- || echo ""
}

# Get all container environment variables as JSON object
get_container_env_json() {
    local container="$1"

    docker inspect --format "{{range .Config.Env}}{{println .}}{{end}}" "$container" | \
        awk -F'=' 'NF>=2 {
            key=$1
            $1=""
            val=substr($0,2)
            gsub(/"/, "\\\"", val)
            printf "      \"%s\": \"%s\",\n", key, val
        }'
}

# Backup PostgreSQL database with retry logic
backup_postgres() {
    local container="$1"
    local output_file="$2"
    local max_attempts="${3:-3}"
    local retry_delay="${4:-5}"

    local user=$(get_container_env "$container" "POSTGRES_USER")
    local db=$(get_container_env "$container" "POSTGRES_DB")

    # Defaults
    [[ -z "$user" ]] && user="postgres"
    [[ -z "$db" ]] && db="postgres"

    log_info "  Dumping PostgreSQL: user=$user, db=$db"

    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        if docker exec "$container" pg_dump -U "$user" -Fc "$db" > "$output_file" 2>/dev/null; then
            # Validate the dump file
            if validate_dump_file "$output_file" 1024 "$container/$db"; then
                return 0
            else
                log_warning "  Dump validation failed, attempt $attempt/$max_attempts"
            fi
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            log_warning "  PostgreSQL dump attempt $attempt/$max_attempts failed, retrying in ${retry_delay}s..."
            sleep "$retry_delay"
            retry_delay=$((retry_delay * 2))
        fi
        ((attempt++))
    done

    return 1
}

# Backup MySQL/MariaDB database with retry logic
backup_mysql() {
    local container="$1"
    local output_file="$2"
    local max_attempts="${3:-3}"
    local retry_delay="${4:-5}"

    local user=$(get_container_env "$container" "MYSQL_USER")
    local pass=$(get_container_env "$container" "MYSQL_PASSWORD")
    local db=$(get_container_env "$container" "MYSQL_DATABASE")
    local root_pass=$(get_container_env "$container" "MYSQL_ROOT_PASSWORD")

    # Try root if no user specified
    if [[ -z "$user" ]] || [[ -z "$pass" ]]; then
        user="root"
        pass="$root_pass"
    fi

    # Default database
    [[ -z "$db" ]] && db="--all-databases"

    log_info "  Dumping MySQL: user=$user, db=$db"

    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        local dump_success=false

        if [[ "$db" == "--all-databases" ]]; then
            if docker exec -e MYSQL_PWD="$pass" "$container" mysqldump --single-transaction -u "$user" --all-databases > "$output_file" 2>/dev/null; then
                dump_success=true
            fi
        else
            if docker exec -e MYSQL_PWD="$pass" "$container" mysqldump --single-transaction -u "$user" "$db" > "$output_file" 2>/dev/null; then
                dump_success=true
            fi
        fi

        if [[ "$dump_success" == true ]]; then
            # Validate the dump file
            if validate_dump_file "$output_file" 1024 "$container/$db"; then
                return 0
            else
                log_warning "  Dump validation failed, attempt $attempt/$max_attempts"
            fi
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            log_warning "  MySQL dump attempt $attempt/$max_attempts failed, retrying in ${retry_delay}s..."
            sleep "$retry_delay"
            retry_delay=$((retry_delay * 2))
        fi
        ((attempt++))
    done

    return 1
}

# Backup MongoDB with retry logic
backup_mongo() {
    local container="$1"
    local output_file="$2"
    local max_attempts="${3:-3}"
    local retry_delay="${4:-5}"

    local user=$(get_container_env "$container" "MONGO_INITDB_ROOT_USERNAME")
    local pass=$(get_container_env "$container" "MONGO_INITDB_ROOT_PASSWORD")

    log_info "  Dumping MongoDB"

    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        local dump_success=false

        if [[ -n "$user" ]] && [[ -n "$pass" ]]; then
            if docker exec "$container" mongodump --archive -u "$user" -p "$pass" --authenticationDatabase admin > "$output_file" 2>/dev/null; then
                dump_success=true
            fi
        else
            if docker exec "$container" mongodump --archive > "$output_file" 2>/dev/null; then
                dump_success=true
            fi
        fi

        if [[ "$dump_success" == true ]]; then
            # Validate the dump file
            if validate_dump_file "$output_file" 512 "$container/mongodb"; then
                return 0
            else
                log_warning "  Dump validation failed, attempt $attempt/$max_attempts"
            fi
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            log_warning "  MongoDB dump attempt $attempt/$max_attempts failed, retrying in ${retry_delay}s..."
            sleep "$retry_delay"
            retry_delay=$((retry_delay * 2))
        fi
        ((attempt++))
    done

    return 1
}

# Backup a Docker volume using temporary container
backup_volume() {
    local volume_name="$1"
    local output_file="$2"

    if docker run --rm \
        -v "${volume_name}":/volume:ro \
        -v "${VOLUMES_DIR}":/backup \
        busybox tar czf "/backup/$(basename "$output_file")" -C /volume . 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Backup a bind mount directory
backup_bind() {
    local host_path="$1"
    local output_file="$2"

    if [[ -d "$host_path" ]]; then
        if tar czf "$output_file" -C "$host_path" . 2>/dev/null; then
            return 0
        fi
    elif [[ -f "$host_path" ]]; then
        if tar czf "$output_file" -C "$(dirname "$host_path")" "$(basename "$host_path")" 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# Main backup logic
log_info "Discovering Docker containers and volumes..."

# Get all running containers
CONTAINERS=$(docker ps --format '{{.Names}}')
CONTAINER_COUNT=$(echo "$CONTAINERS" | grep -c . || echo 0)

log_info "Found ${CONTAINER_COUNT} running containers"

# Initialize metadata
echo "{" > "$METADATA_FILE"
echo '  "generated": "'"$(date -Iseconds)"'",' >> "$METADATA_FILE"
echo '  "hostname": "'"$(hostname -f)"'",' >> "$METADATA_FILE"
echo '  "containers": {' >> "$METADATA_FILE"

# Track what we've backed up to avoid duplicates
declare -A BACKED_UP_VOLUMES
declare -A BACKED_UP_BINDS
FIRST_CONTAINER=true

# Process each container
for container in $CONTAINERS; do
    [[ -z "$container" ]] && continue

    log_info "Processing container: $container"

    # Get container details
    INSPECT=$(docker inspect "$container" 2>/dev/null)
    IMAGE=$(echo "$INSPECT" | jq -r '.[0].Config.Image')

    # Detect if this is a database container
    DB_TYPE=$(detect_db_type "$IMAGE")

    # Get mounts
    VOLUME_MOUNTS=$(echo "$INSPECT" | jq -r '.[0].Mounts[] | select(.Type=="volume") | .Name' 2>/dev/null || echo "")
    BIND_MOUNTS=$(echo "$INSPECT" | jq -r '.[0].Mounts[] | select(.Type=="bind") | .Source' 2>/dev/null || echo "")

    # Write container metadata
    if [[ "$FIRST_CONTAINER" == true ]]; then
        FIRST_CONTAINER=false
    else
        echo "," >> "$METADATA_FILE"
    fi

    echo "    \"$container\": {" >> "$METADATA_FILE"
    echo "      \"image\": \"$IMAGE\"," >> "$METADATA_FILE"

    # Write volumes array
    echo -n '      "volumes": [' >> "$METADATA_FILE"
    FIRST_VOL=true
    for vol in $VOLUME_MOUNTS; do
        [[ -z "$vol" ]] && continue
        if [[ "$FIRST_VOL" == true ]]; then
            FIRST_VOL=false
        else
            echo -n ", " >> "$METADATA_FILE"
        fi
        echo -n "\"$vol\"" >> "$METADATA_FILE"
    done
    echo "]," >> "$METADATA_FILE"

    # Write binds array
    echo -n '      "binds": [' >> "$METADATA_FILE"
    FIRST_BIND=true
    for bind in $BIND_MOUNTS; do
        [[ -z "$bind" ]] && continue
        if [[ "$FIRST_BIND" == true ]]; then
            FIRST_BIND=false
        else
            echo -n ", " >> "$METADATA_FILE"
        fi
        echo -n "\"$bind\"" >> "$METADATA_FILE"
    done
    echo "]," >> "$METADATA_FILE"

    # Write environment variables
    echo '      "env": {' >> "$METADATA_FILE"
    ENV_JSON=$(get_container_env_json "$container")
    # Remove trailing comma from last env var
    ENV_JSON=$(echo "$ENV_JSON" | sed '$ s/,$//')
    echo "$ENV_JSON" >> "$METADATA_FILE"
    echo "      }," >> "$METADATA_FILE"

    # Write database info
    if [[ -n "$DB_TYPE" ]]; then
        echo "      \"is_database\": true," >> "$METADATA_FILE"
        echo "      \"db_type\": \"$DB_TYPE\"" >> "$METADATA_FILE"
    else
        echo "      \"is_database\": false," >> "$METADATA_FILE"
        echo "      \"db_type\": null" >> "$METADATA_FILE"
    fi

    echo -n "    }" >> "$METADATA_FILE"

    # Backup database if applicable
    if [[ -n "$DB_TYPE" ]]; then
        log_info "  Database detected: $DB_TYPE"

        # Sanitize container name for filename
        SAFE_NAME=$(echo "$container" | tr '/:' '_')

        case "$DB_TYPE" in
            postgres)
                DUMP_FILE="${DATABASES_DIR}/${SAFE_NAME}.dump"
                if backup_postgres "$container" "$DUMP_FILE"; then
                    DUMP_SIZE=$(stat -c %s "$DUMP_FILE" 2>/dev/null || stat -f %z "$DUMP_FILE" 2>/dev/null)
                    log_success "  PostgreSQL dump: $(format_bytes "$DUMP_SIZE")"
                else
                    die "Failed to dump PostgreSQL for $container"
                fi
                ;;
            mysql)
                DUMP_FILE="${DATABASES_DIR}/${SAFE_NAME}.sql"
                if backup_mysql "$container" "$DUMP_FILE"; then
                    DUMP_SIZE=$(stat -c %s "$DUMP_FILE" 2>/dev/null || stat -f %z "$DUMP_FILE" 2>/dev/null)
                    log_success "  MySQL dump: $(format_bytes "$DUMP_SIZE")"
                else
                    die "Failed to dump MySQL for $container"
                fi
                ;;
            mongo)
                DUMP_FILE="${DATABASES_DIR}/${SAFE_NAME}.archive"
                if backup_mongo "$container" "$DUMP_FILE"; then
                    DUMP_SIZE=$(stat -c %s "$DUMP_FILE" 2>/dev/null || stat -f %z "$DUMP_FILE" 2>/dev/null)
                    log_success "  MongoDB dump: $(format_bytes "$DUMP_SIZE")"
                else
                    die "Failed to dump MongoDB for $container"
                fi
                ;;
            redis)
                log_info "  Redis detected - skipping dump (ephemeral cache)"
                ;;
        esac
    fi

    # Backup volumes (if not already backed up)
    for vol in $VOLUME_MOUNTS; do
        [[ -z "$vol" ]] && continue

        if [[ -z "${BACKED_UP_VOLUMES[$vol]:-}" ]]; then
            SAFE_NAME=$(echo "$vol" | tr '/:' '_')
            ARCHIVE_FILE="${VOLUMES_DIR}/${SAFE_NAME}.tar.gz"

            log_info "  Backing up volume: $vol"
            if backup_volume "$vol" "$ARCHIVE_FILE"; then
                ARCHIVE_SIZE=$(stat -c %s "$ARCHIVE_FILE" 2>/dev/null || stat -f %z "$ARCHIVE_FILE" 2>/dev/null)
                log_success "  Volume archived: $(format_bytes "$ARCHIVE_SIZE")"
                BACKED_UP_VOLUMES[$vol]=1
            else
                log_warning "  Failed to backup volume: $vol"
            fi
        else
            log_info "  Volume already backed up: $vol"
        fi
    done

    # Backup bind mounts (if not already backed up)
    for bind in $BIND_MOUNTS; do
        [[ -z "$bind" ]] && continue

        # Skip system directories that shouldn't be backed up here
        if [[ "$bind" == "/var/run"* ]] || [[ "$bind" == "/proc"* ]] || [[ "$bind" == "/sys"* ]]; then
            log_info "  Skipping system bind: $bind"
            continue
        fi

        if [[ -z "${BACKED_UP_BINDS[$bind]:-}" ]]; then
            SAFE_NAME=$(echo "$bind" | tr '/:' '_')
            ARCHIVE_FILE="${BINDS_DIR}/${SAFE_NAME}.tar.gz"

            log_info "  Backing up bind mount: $bind"
            if backup_bind "$bind" "$ARCHIVE_FILE"; then
                ARCHIVE_SIZE=$(stat -c %s "$ARCHIVE_FILE" 2>/dev/null || stat -f %z "$ARCHIVE_FILE" 2>/dev/null)
                log_success "  Bind mount archived: $(format_bytes "$ARCHIVE_SIZE")"
                BACKED_UP_BINDS[$bind]=1
            else
                log_warning "  Failed to backup bind mount: $bind"
            fi
        else
            log_info "  Bind mount already backed up: $bind"
        fi
    done
done

# Close metadata JSON
echo "" >> "$METADATA_FILE"
echo "  }," >> "$METADATA_FILE"

# Add summary arrays to metadata
echo '  "backed_up_volumes": [' >> "$METADATA_FILE"
FIRST=true
for vol in "${!BACKED_UP_VOLUMES[@]}"; do
    if [[ "$FIRST" == true ]]; then
        FIRST=false
    else
        echo "," >> "$METADATA_FILE"
    fi
    echo -n "    \"$vol\"" >> "$METADATA_FILE"
done
echo "" >> "$METADATA_FILE"
echo "  ]," >> "$METADATA_FILE"

echo '  "backed_up_binds": [' >> "$METADATA_FILE"
FIRST=true
for bind in "${!BACKED_UP_BINDS[@]}"; do
    if [[ "$FIRST" == true ]]; then
        FIRST=false
    else
        echo "," >> "$METADATA_FILE"
    fi
    echo -n "    \"$bind\"" >> "$METADATA_FILE"
done
echo "" >> "$METADATA_FILE"
echo "  ]" >> "$METADATA_FILE"

echo "}" >> "$METADATA_FILE"

# Set secure permissions on metadata (contains credentials)
chmod 600 "$METADATA_FILE"

# Validate JSON if jq available
if command -v jq &> /dev/null; then
    if ! jq . "$METADATA_FILE" > /dev/null 2>&1; then
        log_warning "Generated metadata JSON may be invalid"
    fi
fi

# Summary
VOLUME_COUNT=${#BACKED_UP_VOLUMES[@]}
BIND_COUNT=${#BACKED_UP_BINDS[@]}
DB_COUNT=$(find "$DATABASES_DIR" -type f | wc -l)

log_info "Backup summary:"
log_info "  Containers processed: ${CONTAINER_COUNT}"
log_info "  Volumes backed up: ${VOLUME_COUNT}"
log_info "  Bind mounts backed up: ${BIND_COUNT}"
log_info "  Database dumps: ${DB_COUNT}"

# Build archive for PBS
# - root.pxar: Full system for complete DR
# - coolify-apps.pxar: App data (volumes, binds, DB dumps) for selective restore
ARCHIVES=(
    "root.pxar:/"
    "coolify-apps.pxar:${BACKUP_TEMP_DIR}"
)

log_info "Archives to backup:"
log_info "  - root.pxar: Full system backup"
log_info "  - coolify-apps.pxar: Application data (for selective app restore)"

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

log_success "Coolify applications backup completed for ${PBS_HOSTNAME}"
log_info ""
log_info "Backed up: ${VOLUME_COUNT} volumes, ${BIND_COUNT} bind mounts, ${DB_COUNT} database dumps"
log_info "Metadata file included with container env vars and mount mappings"
