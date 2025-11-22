#!/bin/bash
# Database Backup Sync Script
# Dumps databases locally and syncs to backup2 storage VPS
# Designed for frequent runs (hourly) with retention management

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load common functions
# shellcheck source=../lib/common.sh
source "${PROJECT_DIR}/lib/common.sh"

# =============================================================================
# Configuration
# =============================================================================

# Remote backup destination
BACKUP_HOST="${BACKUP_HOST:-backup2.hubseek.com}"
BACKUP_USER="${BACKUP_USER:-root}"
BACKUP_BASE_PATH="${BACKUP_BASE_PATH:-/backups/databases}"

# Local temp directory for dumps
LOCAL_DUMP_DIR="/tmp/db-backup-sync-$(date '+%Y%m%d-%H%M%S')"

# Retention settings (on remote)
KEEP_HOURLY="${KEEP_HOURLY:-24}"    # Keep last 24 hourly backups
KEEP_DAILY="${KEEP_DAILY:-7}"       # Keep last 7 daily backups

# Current timestamp
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
HOUR=$(date '+%H')
DAY_OF_WEEK=$(date '+%u')  # 1-7, Monday=1

# =============================================================================
# Parse Arguments
# =============================================================================

DRY_RUN=false
SKIP_SYNC=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --skip-sync)
            SKIP_SYNC=true
            shift
            ;;
        --host)
            BACKUP_HOST="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --dry-run     Show what would be done without executing"
            echo "  --skip-sync   Dump databases but don't sync to remote"
            echo "  --host HOST   Override backup destination host (default: backup2)"
            echo "  -h, --help    Show this help message"
            echo ""
            echo "Environment variables:"
            echo "  BACKUP_HOST       Remote host (default: backup2)"
            echo "  BACKUP_USER       Remote user (default: root)"
            echo "  BACKUP_BASE_PATH  Remote path (default: /backups/databases)"
            echo "  KEEP_HOURLY       Hourly backups to retain (default: 24)"
            echo "  KEEP_DAILY        Daily backups to retain (default: 7)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# Setup
# =============================================================================

check_root

# Setup logging
LOG_DIR=$(setup_logging)
LOG_FILE="${LOG_DIR}/db-backup-sync-$(date '+%Y%m%d-%H%M%S').log"

exec > >(tee -a "$LOG_FILE") 2>&1

HOSTNAME=$(hostname -s)
REMOTE_HOST_PATH="${BACKUP_BASE_PATH}/${HOSTNAME}"
REMOTE_HOURLY_PATH="${REMOTE_HOST_PATH}/hourly"
REMOTE_DAILY_PATH="${REMOTE_HOST_PATH}/daily"

log_info "Starting database backup sync"
log_info "Hostname: ${HOSTNAME}"
log_info "Remote: ${BACKUP_USER}@${BACKUP_HOST}:${REMOTE_HOST_PATH}"
log_info "Log file: ${LOG_FILE}"

# Create local dump directory
mkdir -p "$LOCAL_DUMP_DIR"

# Cleanup function
cleanup() {
    if [[ -d "$LOCAL_DUMP_DIR" ]]; then
        log_info "Cleaning up local dump directory..."
        rm -rf "$LOCAL_DUMP_DIR"
    fi
}
trap cleanup EXIT

# =============================================================================
# Test Remote Connection
# =============================================================================

log_info "Testing connection to ${BACKUP_HOST}..."

if [[ "$DRY_RUN" == true ]]; then
    log_info "DRY RUN: Would test SSH connection to ${BACKUP_USER}@${BACKUP_HOST}"
else
    if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "${BACKUP_USER}@${BACKUP_HOST}" "echo ok" &>/dev/null; then
        die "Cannot connect to ${BACKUP_HOST} - check SSH keys"
    fi
    log_success "Connected to ${BACKUP_HOST}"
fi

# =============================================================================
# Dump Databases
# =============================================================================

log_info "Dumping databases..."

DUMP_COUNT=0

# Dump MySQL/MariaDB
if systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mariadb 2>/dev/null; then
    log_info "Dumping MySQL/MariaDB..."
    mysql_dump="${LOCAL_DUMP_DIR}/mysql-all-databases.sql.gz"

    mysql_auth_args=()
    if [[ -f /etc/mysql/debian.cnf ]]; then
        mysql_auth_args=(--defaults-file=/etc/mysql/debian.cnf)
    else
        mysql_auth_args=(--user=root)
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "DRY RUN: Would dump MySQL/MariaDB"
        ((DUMP_COUNT++))
    else
        if mysqldump "${mysql_auth_args[@]}" --single-transaction --all-databases --routines --triggers --events 2>/dev/null | gzip > "$mysql_dump"; then
            dump_size=$(stat -c %s "$mysql_dump" 2>/dev/null || stat -f %z "$mysql_dump" 2>/dev/null)
            if [[ "$dump_size" -gt 100 ]]; then
                log_success "MySQL dump created: $(format_bytes "$dump_size")"
                ((DUMP_COUNT++))
            else
                log_warning "MySQL dump appears empty, skipping"
                rm -f "$mysql_dump"
            fi
        else
            log_warning "MySQL dump failed"
        fi
    fi
fi

# Dump PostgreSQL
if systemctl is-active --quiet postgresql 2>/dev/null; then
    log_info "Dumping PostgreSQL..."
    pg_dump="${LOCAL_DUMP_DIR}/postgresql-all-databases.sql.gz"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "DRY RUN: Would dump PostgreSQL"
        ((DUMP_COUNT++))
    else
        if sudo -u postgres pg_dumpall 2>/dev/null | gzip > "$pg_dump"; then
            dump_size=$(stat -c %s "$pg_dump" 2>/dev/null || stat -f %z "$pg_dump" 2>/dev/null)
            if [[ "$dump_size" -gt 100 ]]; then
                log_success "PostgreSQL dump created: $(format_bytes "$dump_size")"
                ((DUMP_COUNT++))
            else
                log_warning "PostgreSQL dump appears empty, skipping"
                rm -f "$pg_dump"
            fi
        else
            log_warning "PostgreSQL dump failed"
        fi
    fi
fi

# Dump Docker databases (if Docker is running)
if systemctl is-active --quiet docker 2>/dev/null; then
    log_info "Checking for Docker database containers..."

    for container in $(docker ps --format '{{.Names}}' 2>/dev/null); do
        image=$(docker inspect --format '{{.Config.Image}}' "$container" 2>/dev/null || echo "")

        # PostgreSQL containers
        if [[ "$image" == *"postgres"* ]]; then
            log_info "Dumping PostgreSQL container: $container"
            safe_name=$(echo "$container" | tr '/:' '_')
            dump_file="${LOCAL_DUMP_DIR}/docker-${safe_name}-postgres.dump.gz"

            user=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" | grep "^POSTGRES_USER=" | cut -d'=' -f2- || echo "postgres")
            db=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" | grep "^POSTGRES_DB=" | cut -d'=' -f2- || echo "postgres")
            [[ -z "$user" ]] && user="postgres"
            [[ -z "$db" ]] && db="postgres"

            if [[ "$DRY_RUN" == true ]]; then
                log_info "DRY RUN: Would dump PostgreSQL container $container"
                ((DUMP_COUNT++))
            else
                if docker exec "$container" pg_dump -U "$user" -Fc "$db" 2>/dev/null | gzip > "$dump_file"; then
                    dump_size=$(stat -c %s "$dump_file" 2>/dev/null || stat -f %z "$dump_file" 2>/dev/null)
                    if [[ "$dump_size" -gt 100 ]]; then
                        log_success "  Container dump created: $(format_bytes "$dump_size")"
                        ((DUMP_COUNT++))
                    else
                        rm -f "$dump_file"
                    fi
                else
                    log_warning "  Failed to dump container: $container"
                fi
            fi
        fi

        # MySQL/MariaDB containers
        if [[ "$image" == *"mysql"* ]] || [[ "$image" == *"mariadb"* ]]; then
            log_info "Dumping MySQL container: $container"
            safe_name=$(echo "$container" | tr '/:' '_')
            dump_file="${LOCAL_DUMP_DIR}/docker-${safe_name}-mysql.sql.gz"

            pass=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" | grep "^MYSQL_ROOT_PASSWORD=" | cut -d'=' -f2- || echo "")

            if [[ -n "$pass" ]]; then
                if [[ "$DRY_RUN" == true ]]; then
                    log_info "DRY RUN: Would dump MySQL container $container"
                    ((DUMP_COUNT++))
                else
                    if docker exec -e MYSQL_PWD="$pass" "$container" mysqldump --single-transaction -u root --all-databases 2>/dev/null | gzip > "$dump_file"; then
                        dump_size=$(stat -c %s "$dump_file" 2>/dev/null || stat -f %z "$dump_file" 2>/dev/null)
                        if [[ "$dump_size" -gt 100 ]]; then
                            log_success "  Container dump created: $(format_bytes "$dump_size")"
                            ((DUMP_COUNT++))
                        else
                            rm -f "$dump_file"
                        fi
                    else
                        log_warning "  Failed to dump container: $container"
                    fi
                fi
            else
                log_warning "  No root password found for MySQL container: $container"
            fi
        fi

        # MongoDB containers
        if [[ "$image" == *"mongo"* ]]; then
            log_info "Dumping MongoDB container: $container"
            safe_name=$(echo "$container" | tr '/:' '_')
            dump_file="${LOCAL_DUMP_DIR}/docker-${safe_name}-mongo.archive.gz"

            user=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" | grep "^MONGO_INITDB_ROOT_USERNAME=" | cut -d'=' -f2- || echo "")
            pass=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" | grep "^MONGO_INITDB_ROOT_PASSWORD=" | cut -d'=' -f2- || echo "")

            if [[ "$DRY_RUN" == true ]]; then
                log_info "DRY RUN: Would dump MongoDB container $container"
                ((DUMP_COUNT++))
            else
                if [[ -n "$user" ]] && [[ -n "$pass" ]]; then
                    docker exec "$container" mongodump --archive -u "$user" -p "$pass" --authenticationDatabase admin 2>/dev/null | gzip > "$dump_file"
                else
                    docker exec "$container" mongodump --archive 2>/dev/null | gzip > "$dump_file"
                fi

                dump_size=$(stat -c %s "$dump_file" 2>/dev/null || stat -f %z "$dump_file" 2>/dev/null)
                if [[ "$dump_size" -gt 100 ]]; then
                    log_success "  Container dump created: $(format_bytes "$dump_size")"
                    ((DUMP_COUNT++))
                else
                    rm -f "$dump_file"
                fi
            fi
        fi
    done
fi

# Check if we have anything to sync
if [[ "$DUMP_COUNT" -eq 0 ]]; then
    log_info "No databases found to backup"
    exit 0
fi

log_info "Created $DUMP_COUNT database dump(s)"

# =============================================================================
# Sync to Remote
# =============================================================================

if [[ "$SKIP_SYNC" == true ]]; then
    log_info "Skipping sync (--skip-sync specified)"
    log_info "Dumps available in: $LOCAL_DUMP_DIR"
    trap - EXIT  # Don't cleanup
    exit 0
fi

log_info "Syncing to ${BACKUP_HOST}..."

# Create remote directories
if [[ "$DRY_RUN" == true ]]; then
    log_info "DRY RUN: Would create remote directories"
else
    ssh "${BACKUP_USER}@${BACKUP_HOST}" "mkdir -p '${REMOTE_HOURLY_PATH}' '${REMOTE_DAILY_PATH}'"
fi

# Sync to hourly directory with timestamp
HOURLY_DEST="${REMOTE_HOURLY_PATH}/${TIMESTAMP}"

if [[ "$DRY_RUN" == true ]]; then
    log_info "DRY RUN: Would rsync to ${HOURLY_DEST}"
else
    if rsync -az --info=progress2 \
        "${LOCAL_DUMP_DIR}/" \
        "${BACKUP_USER}@${BACKUP_HOST}:${HOURLY_DEST}/"; then
        log_success "Synced to hourly: ${HOURLY_DEST}"
    else
        die "Failed to sync to remote"
    fi
fi

# Create daily snapshot (first run of the day or specific hour)
if [[ "$HOUR" == "00" ]] || [[ "$HOUR" == "02" ]]; then
    DAILY_DEST="${REMOTE_DAILY_PATH}/${TIMESTAMP}"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "DRY RUN: Would create daily snapshot at ${DAILY_DEST}"
    else
        # Hard link copy from hourly to daily (space efficient)
        ssh "${BACKUP_USER}@${BACKUP_HOST}" "cp -al '${HOURLY_DEST}' '${DAILY_DEST}'"
        log_success "Created daily snapshot: ${DAILY_DEST}"
    fi
fi

# =============================================================================
# Retention Cleanup
# =============================================================================

log_info "Applying retention policy..."

if [[ "$DRY_RUN" == true ]]; then
    log_info "DRY RUN: Would clean up old hourly backups (keep ${KEEP_HOURLY})"
    log_info "DRY RUN: Would clean up old daily backups (keep ${KEEP_DAILY})"
else
    # Clean up hourly backups
    ssh "${BACKUP_USER}@${BACKUP_HOST}" "cd '${REMOTE_HOURLY_PATH}' && ls -1t | tail -n +$((KEEP_HOURLY + 1)) | xargs -r rm -rf"

    # Clean up daily backups
    ssh "${BACKUP_USER}@${BACKUP_HOST}" "cd '${REMOTE_DAILY_PATH}' && ls -1t | tail -n +$((KEEP_DAILY + 1)) | xargs -r rm -rf"

    log_success "Retention policy applied"
fi

# =============================================================================
# Summary
# =============================================================================

log_success "Database backup sync completed"
log_info "  Dumps created: ${DUMP_COUNT}"
log_info "  Remote location: ${BACKUP_USER}@${BACKUP_HOST}:${REMOTE_HOST_PATH}"
log_info "  Retention: ${KEEP_HOURLY} hourly, ${KEEP_DAILY} daily"
