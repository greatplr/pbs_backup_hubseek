#!/bin/bash
# Common functions for PBS backup/restore operations

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
    export PBS_REPOSITORY="${PBS_USER_STRING}@${PBS_SERVER}:${PBS_DATASTORE}"
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
    if proxmox-backup-client list --repository "${PBS_REPOSITORY}" &>/dev/null; then
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
