#!/bin/bash
# Common functions for PBS backup/restore operations

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global dry-run flag (set by individual scripts)
DRY_RUN="${DRY_RUN:-false}"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

# Exit with error
die() {
    log_error "$*"
    exit 1
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root"
    fi
}

# Check for required commands
check_command() {
    local cmd="$1"
    if ! command -v "$cmd" &> /dev/null; then
        die "Required command not found: $cmd"
    fi
}

# Verify PBS client is installed
check_pbs_client() {
    check_command "proxmox-backup-client"
}

# Load configuration files
load_config() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local config_dir="${script_dir}/config"

    # Load main config
    if [[ -f "${config_dir}/pbs.conf" ]]; then
        # shellcheck source=/dev/null
        source "${config_dir}/pbs.conf"
    else
        die "Configuration file not found: ${config_dir}/pbs.conf"
    fi

    # Load credentials
    if [[ -f "${config_dir}/credentials.conf" ]]; then
        # shellcheck source=/dev/null
        source "${config_dir}/credentials.conf"
    else
        die "Credentials file not found: ${config_dir}/credentials.conf"
    fi

    # Construct PBS environment variables
    export PBS_PASSWORD="${PBS_TOKEN_SECRET}"
    export PBS_USER_STRING="${PBS_TOKEN_USER}!${PBS_TOKEN_NAME}"
    export PBS_REPOSITORY="${PBS_USER_STRING}@${PBS_SERVER}:${PBS_PORT}:${PBS_DATASTORE}"
    export PBS_HOSTNAME="$(hostname -s)"
}

# Verify encryption key exists
check_keyfile() {
    if [[ ! -f "${PBS_KEYFILE}" ]]; then
        die "Encryption keyfile not found: ${PBS_KEYFILE}"
    fi

    # Check permissions
    local perms
    perms=$(stat -c '%a' "${PBS_KEYFILE}" 2>/dev/null || stat -f '%A' "${PBS_KEYFILE}" 2>/dev/null)
    if [[ "$perms" != "600" && "$perms" != "400" ]]; then
        log_warning "Keyfile permissions should be 600 or 400 (current: $perms)"
    fi
}

# Test PBS connection
test_pbs_connection() {
    log_info "Testing connection to PBS server..."
    # Run with timeout and ensure PBS_PASSWORD is in the command environment
    # Note: Fingerprint must be accepted once manually before running scripts
    if timeout 30 env PBS_PASSWORD="${PBS_PASSWORD}" proxmox-backup-client snapshot list --repository "${PBS_REPOSITORY}" --output-format json &>/dev/null; then
        log_success "Successfully connected to PBS"
        return 0
    else
        log_error "Failed to connect to PBS server"
        return 1
    fi
}

# Detect server type based on installed services
detect_server_type() {
    local types=()

    # Check for web servers
    if systemctl is-active --quiet nginx 2>/dev/null || systemctl is-active --quiet apache2 2>/dev/null; then
        types+=("web")
    fi

    # Check for databases
    if systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mariadb 2>/dev/null; then
        types+=("mysql")
    fi
    if systemctl is-active --quiet postgresql 2>/dev/null; then
        types+=("postgresql")
    fi

    # Check for Docker
    if systemctl is-active --quiet docker 2>/dev/null; then
        types+=("docker")
    fi

    # Check for mail servers
    if systemctl is-active --quiet postfix 2>/dev/null || systemctl is-active --quiet dovecot 2>/dev/null; then
        types+=("mail")
    fi

    # Return detected types or 'basic' if none found
    if [[ ${#types[@]} -eq 0 ]]; then
        echo "basic"
    else
        echo "${types[*]}"
    fi
}

# Create backup log directory
setup_logging() {
    local log_dir="${BACKUP_LOG_DIR:-/var/log/pbs-backup}"
    mkdir -p "$log_dir"
    echo "$log_dir"
}

# Format bytes to human readable
format_bytes() {
    local bytes=$1
    if [[ $bytes -lt 1024 ]]; then
        echo "${bytes}B"
    elif [[ $bytes -lt 1048576 ]]; then
        echo "$(( bytes / 1024 ))KB"
    elif [[ $bytes -lt 1073741824 ]]; then
        echo "$(( bytes / 1048576 ))MB"
    else
        echo "$(( bytes / 1073741824 ))GB"
    fi
}

# List available snapshots
list_snapshots() {
    local filter="${1:-}"
    log_info "Listing snapshots for ${PBS_HOSTNAME}..."

    if [[ -n "$filter" ]]; then
        proxmox-backup-client snapshot list \
            --repository "${PBS_REPOSITORY}" \
            --output-format json | grep -i "$filter"
    else
        proxmox-backup-client snapshot list \
            --repository "${PBS_REPOSITORY}"
    fi
}

# Get standard exclusions for full system backup
# Returns exclusion arguments for proxmox-backup-client
get_system_exclusions() {
    local exclusions=(
        --exclude /proc
        --exclude /sys
        --exclude /dev
        --exclude /tmp
        --exclude /run
        --exclude /var/tmp
        --exclude /var/cache/apt
        --exclude /lost+found
        --exclude /mnt
        --exclude /media
        --exclude /swapfile
        --exclude /swap.img
    )
    echo "${exclusions[@]}"
}

# Retry a command with exponential backoff
# Usage: retry_command <max_attempts> <initial_delay> <command...>
# Example: retry_command 3 5 pg_dump -Fc mydb > dump.sql
retry_command() {
    local max_attempts="$1"
    local delay="$2"
    shift 2

    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        if "$@"; then
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            log_warning "Attempt $attempt/$max_attempts failed, retrying in ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))  # Exponential backoff
        fi
        ((attempt++))
    done

    log_error "All $max_attempts attempts failed"
    return 1
}

# Validate dump file is not empty or suspiciously small
# Usage: validate_dump_file <file_path> <min_size_bytes> [db_name]
# Returns 0 if valid, 1 if invalid
validate_dump_file() {
    local file_path="$1"
    local min_size="${2:-1024}"  # Default minimum 1KB
    local db_name="${3:-database}"

    if [[ ! -f "$file_path" ]]; then
        log_error "Dump file does not exist: $file_path"
        return 1
    fi

    local file_size
    file_size=$(stat -c %s "$file_path" 2>/dev/null || stat -f %z "$file_path" 2>/dev/null)

    if [[ "$file_size" -eq 0 ]]; then
        log_error "Dump file is empty (0 bytes): $db_name"
        return 1
    fi

    if [[ "$file_size" -lt "$min_size" ]]; then
        log_warning "Dump file suspiciously small (${file_size} bytes < ${min_size} bytes): $db_name"
        # Return success but warn - small DBs are valid
        return 0
    fi

    return 0
}

# =============================================================================
# Application-Aware Backup Functions
# =============================================================================

# Dump all detected databases (MySQL/MariaDB/PostgreSQL) to a directory
# Usage: dump_databases <output_dir>
# Returns: 0 if successful (or no DBs found), 1 if any dump failed
dump_databases() {
    local output_dir="$1"
    local had_errors=false

    mkdir -p "$output_dir"

    # Check for MySQL/MariaDB
    if systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mariadb 2>/dev/null; then
        log_info "Detected MySQL/MariaDB - creating dump..."
        local mysql_dump="${output_dir}/mysql-all-databases.sql"

        local max_attempts=3
        local retry_delay=5
        local attempt=1
        local dump_success=false

        while [[ $attempt -le $max_attempts ]]; do
            # Use MYSQL_PWD to avoid password in process list
            # Try socket auth first (common for root), then fall back to no auth
            if mysqldump --single-transaction --all-databases --routines --triggers --events > "$mysql_dump" 2>/dev/null; then
                if validate_dump_file "$mysql_dump" 1024 "mysql-all-databases"; then
                    local dump_size
                    dump_size=$(stat -c %s "$mysql_dump" 2>/dev/null || stat -f %z "$mysql_dump" 2>/dev/null)
                    log_success "MySQL dump created: $(format_bytes "$dump_size")"
                    chmod 600 "$mysql_dump"
                    dump_success=true
                    break
                fi
            fi

            if [[ $attempt -lt $max_attempts ]]; then
                log_warning "MySQL dump attempt $attempt/$max_attempts failed, retrying in ${retry_delay}s..."
                sleep "$retry_delay"
                retry_delay=$((retry_delay * 2))
            fi
            ((attempt++))
        done

        if [[ "$dump_success" != true ]]; then
            log_warning "Failed to dump MySQL/MariaDB databases"
            had_errors=true
        fi
    fi

    # Check for PostgreSQL
    if systemctl is-active --quiet postgresql 2>/dev/null; then
        log_info "Detected PostgreSQL - creating dump..."
        local pg_dump="${output_dir}/postgresql-all-databases.sql"

        local max_attempts=3
        local retry_delay=5
        local attempt=1
        local dump_success=false

        while [[ $attempt -le $max_attempts ]]; do
            if sudo -u postgres pg_dumpall > "$pg_dump" 2>/dev/null; then
                if validate_dump_file "$pg_dump" 1024 "postgresql-all-databases"; then
                    local dump_size
                    dump_size=$(stat -c %s "$pg_dump" 2>/dev/null || stat -f %z "$pg_dump" 2>/dev/null)
                    log_success "PostgreSQL dump created: $(format_bytes "$dump_size")"
                    chmod 600 "$pg_dump"
                    dump_success=true
                    break
                fi
            fi

            if [[ $attempt -lt $max_attempts ]]; then
                log_warning "PostgreSQL dump attempt $attempt/$max_attempts failed, retrying in ${retry_delay}s..."
                sleep "$retry_delay"
                retry_delay=$((retry_delay * 2))
            fi
            ((attempt++))
        done

        if [[ "$dump_success" != true ]]; then
            log_warning "Failed to dump PostgreSQL databases"
            had_errors=true
        fi
    fi

    if [[ "$had_errors" == true ]]; then
        return 1
    fi
    return 0
}

# Trigger Redis persistence save if persistence is enabled
# Usage: dump_redis [host] [port]
# Returns: 0 if successful (or Redis not running/no persistence), 1 on error
dump_redis() {
    local redis_host="${1:-127.0.0.1}"
    local redis_port="${2:-6379}"

    # Check if Redis is running
    if ! systemctl is-active --quiet redis 2>/dev/null && \
       ! systemctl is-active --quiet redis-server 2>/dev/null; then
        # Redis not running as a service, skip
        return 0
    fi

    if ! command -v redis-cli &> /dev/null; then
        log_warning "Redis is running but redis-cli not found - skipping Redis backup"
        return 0
    fi

    log_info "Detected Redis - checking persistence configuration..."

    # Check if persistence is enabled
    local save_config appendonly_config
    save_config=$(redis-cli -h "$redis_host" -p "$redis_port" CONFIG GET save 2>/dev/null | tail -1 || echo "")
    appendonly_config=$(redis-cli -h "$redis_host" -p "$redis_port" CONFIG GET appendonly 2>/dev/null | tail -1 || echo "no")

    local has_rdb=false
    local has_aof=false

    # Check RDB persistence (save config not empty)
    if [[ -n "$save_config" && "$save_config" != '""' && "$save_config" != "''" ]]; then
        has_rdb=true
    fi

    # Check AOF persistence
    if [[ "$appendonly_config" == "yes" ]]; then
        has_aof=true
    fi

    if [[ "$has_rdb" != true && "$has_aof" != true ]]; then
        log_info "Redis persistence not enabled - skipping (ephemeral cache)"
        return 0
    fi

    # Trigger saves based on what's enabled
    if [[ "$has_rdb" == true ]]; then
        log_info "Triggering Redis BGSAVE (RDB snapshot)..."
        if redis-cli -h "$redis_host" -p "$redis_port" BGSAVE &>/dev/null; then
            # Wait for BGSAVE to complete (with timeout)
            local timeout=60
            local waited=0
            while [[ $waited -lt $timeout ]]; do
                local lastsave_status
                lastsave_status=$(redis-cli -h "$redis_host" -p "$redis_port" LASTSAVE 2>/dev/null || echo "")
                local bgsave_in_progress
                bgsave_in_progress=$(redis-cli -h "$redis_host" -p "$redis_port" INFO persistence 2>/dev/null | grep "rdb_bgsave_in_progress:1" || echo "")

                if [[ -z "$bgsave_in_progress" ]]; then
                    log_success "Redis BGSAVE completed"
                    break
                fi

                sleep 1
                ((waited++))
            done

            if [[ $waited -ge $timeout ]]; then
                log_warning "Redis BGSAVE timed out after ${timeout}s - continuing anyway"
            fi
        else
            log_warning "Failed to trigger Redis BGSAVE"
        fi
    fi

    if [[ "$has_aof" == true ]]; then
        log_info "Triggering Redis BGREWRITEAOF..."
        if redis-cli -h "$redis_host" -p "$redis_port" BGREWRITEAOF &>/dev/null; then
            log_success "Redis BGREWRITEAOF triggered"
            # Don't wait for AOF rewrite - it runs in background and AOF is already durable
        else
            log_warning "Failed to trigger Redis BGREWRITEAOF"
        fi
    fi

    return 0
}

# Trigger Redis save in a Docker container
# Usage: dump_redis_container <container_name>
# Returns: 0 if successful, 1 on error
dump_redis_container() {
    local container="$1"

    log_info "Checking Redis persistence in container: $container"

    # Check if persistence is enabled
    local save_config appendonly_config
    save_config=$(docker exec "$container" redis-cli CONFIG GET save 2>/dev/null | tail -1 || echo "")
    appendonly_config=$(docker exec "$container" redis-cli CONFIG GET appendonly 2>/dev/null | tail -1 || echo "no")

    local has_rdb=false
    local has_aof=false

    if [[ -n "$save_config" && "$save_config" != '""' && "$save_config" != "''" ]]; then
        has_rdb=true
    fi

    if [[ "$appendonly_config" == "yes" ]]; then
        has_aof=true
    fi

    if [[ "$has_rdb" != true && "$has_aof" != true ]]; then
        log_info "  Redis persistence not enabled - skipping (ephemeral cache)"
        return 0
    fi

    if [[ "$has_rdb" == true ]]; then
        log_info "  Triggering BGSAVE..."
        if docker exec "$container" redis-cli BGSAVE &>/dev/null; then
            # Wait for completion
            local timeout=60
            local waited=0
            while [[ $waited -lt $timeout ]]; do
                local bgsave_in_progress
                bgsave_in_progress=$(docker exec "$container" redis-cli INFO persistence 2>/dev/null | grep "rdb_bgsave_in_progress:1" || echo "")
                if [[ -z "$bgsave_in_progress" ]]; then
                    log_success "  Redis BGSAVE completed"
                    break
                fi
                sleep 1
                ((waited++))
            done
        fi
    fi

    if [[ "$has_aof" == true ]]; then
        log_info "  Triggering BGREWRITEAOF..."
        docker exec "$container" redis-cli BGREWRITEAOF &>/dev/null || true
        log_success "  Redis BGREWRITEAOF triggered"
    fi

    return 0
}

# Backup SQLite databases from common locations
# Usage: dump_sqlite_databases <output_dir>
# Returns: 0 if successful, 1 if any backup failed
dump_sqlite_databases() {
    local output_dir="$1"
    local found_any=false
    local had_errors=false

    mkdir -p "$output_dir"

    # Common SQLite database locations
    local -a sqlite_paths=(
        # Grafana
        "/var/lib/grafana/grafana.db"
        # Prometheus (if using SQLite for some configs)
        "/var/lib/prometheus/data.db"
        # Home Assistant
        "/var/lib/homeassistant/home-assistant_v2.db"
        # Pi-hole
        "/etc/pihole/pihole-FTL.db"
        "/etc/pihole/gravity.db"
        # Authelia
        "/var/lib/authelia/db.sqlite3"
        # Caddy
        "/var/lib/caddy/.local/share/caddy/autosave.json"
        # Syncthing
        "/var/lib/syncthing/index-v0.14.0.db"
        # Miniflux
        "/var/lib/miniflux/miniflux.db"
        # Vaultwarden/Bitwarden
        "/var/lib/vaultwarden/db.sqlite3"
        "/var/lib/bitwarden_rs/db.sqlite3"
    )

    for db_path in "${sqlite_paths[@]}"; do
        if [[ -f "$db_path" ]]; then
            found_any=true
            local db_name
            db_name=$(basename "$db_path")
            local safe_name
            safe_name=$(echo "$db_path" | tr '/' '_' | sed 's/^_//')
            local backup_file="${output_dir}/${safe_name}"

            log_info "Found SQLite database: $db_path"

            # Use sqlite3 .backup command for safe copy (handles locks properly)
            if command -v sqlite3 &> /dev/null; then
                if sqlite3 "$db_path" ".backup '${backup_file}'" 2>/dev/null; then
                    local backup_size
                    backup_size=$(stat -c %s "$backup_file" 2>/dev/null || stat -f %z "$backup_file" 2>/dev/null)
                    log_success "SQLite backup created: $db_name ($(format_bytes "$backup_size"))"
                    chmod 600 "$backup_file"
                else
                    log_warning "Failed to backup SQLite database: $db_path"
                    had_errors=true
                fi
            else
                # Fallback: copy with file lock check
                if cp "$db_path" "$backup_file" 2>/dev/null; then
                    log_success "SQLite copied (sqlite3 not available for safe backup): $db_name"
                    chmod 600 "$backup_file"
                else
                    log_warning "Failed to copy SQLite database: $db_path"
                    had_errors=true
                fi
            fi
        fi
    done

    if [[ "$found_any" != true ]]; then
        log_info "No SQLite databases found in common locations"
    fi

    if [[ "$had_errors" == true ]]; then
        return 1
    fi
    return 0
}
