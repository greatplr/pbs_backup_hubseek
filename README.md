# PBS Backup Suite for HubSeek

A comprehensive backup and restore script suite for Proxmox Backup Server (PBS) designed to handle multiple VPS types and scenarios.

## Features

- **Modular Architecture**: Separate backup/restore modules for different server types
- **Server Type Detection**: Automatically detects installed services (web, database, Docker, mail)
- **Client-Side Encryption**: Full support for PBS encryption key files
- **API Token Authentication**: Secure authentication to PBS without password exposure
- **Configuration Management**: Separated credentials from main configuration

## Project Structure

```
pbs_backup_hubseek/
├── backup/                 # Backup scripts
│   └── backup-base.sh     # Base backup script
├── restore/               # Restore scripts
│   └── restore-base.sh    # Base restore script
├── lib/                   # Shared libraries
│   └── common.sh          # Common functions
├── config/                # Configuration files
│   ├── pbs.conf.example   # Main config template
│   └── credentials.conf.example  # Credentials template
├── docs/                  # Documentation
│   └── reference/         # Reference materials
└── examples/              # Example scripts
```

## Installation

### Prerequisites

- Root access on your VPS
- Proxmox Backup Client installed (`proxmox-backup-client`)
- Git installed
- API token created in PBS
- Encryption key file created

### Installing Proxmox Backup Client

For Debian/Ubuntu systems, add the Proxmox repository:

```bash
# Add Proxmox repository key
wget https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg

# Add repository (adjust for your Debian version)
echo "deb http://download.proxmox.com/debian/pbs-client bookworm main" > /etc/apt/sources.list.d/pbs-client.list

# Install client
apt update
apt install proxmox-backup-client
```

### Install Backup Scripts

```bash
# Clone the repository
cd /opt
git clone https://github.com/greatplr/pbs_backup_hubseek.git
cd pbs_backup_hubseek

# Make scripts executable (should already be set)
chmod +x backup/*.sh restore/*.sh lib/*.sh
```

### Updating

```bash
cd /opt/pbs_backup_hubseek
git pull
```

## Quick Start

### 1. Configuration

```bash
# Copy configuration templates
cp config/pbs.conf.example config/pbs.conf
cp config/credentials.conf.example config/credentials.conf

# Edit configuration
vim config/pbs.conf
vim config/credentials.conf

# Secure credentials file
chmod 600 config/credentials.conf
```

### 3. Create Encryption Key

```bash
proxmox-backup-client key create /root/pbs_encryption_key.json
```

**Important**: Back up this key securely! Without it, you cannot restore encrypted backups.

### 4. Run Backup

```bash
sudo ./backup/backup-base.sh
```

### 5. Restore Files

```bash
# List available snapshots
sudo ./restore/restore-base.sh --list

# Full system restore
sudo ./restore/restore-base.sh "host/myserver/2025-01-22T15:19:17Z" root.pxar /tmp/restore

# Selective restore (e.g., just /etc from full backup)
proxmox-backup-client restore "host/myserver/2025-01-22T15:19:17Z" root.pxar /tmp/restore \
    --repository "backup@pbs!token@server:datastore" \
    --keyfile /root/pbs_encryption_key.json \
    --include "etc/**"
```

## Scheduling Backups

Each server type has its own backup script. **Use only one scheduled job per server** - these are complete wrapper scripts, not components to be combined.

### Option 1: Rundeck (Recommended)

Rundeck provides centralized scheduling, monitoring, and alerting across all servers.

#### Why Rundeck?

- **Central dashboard** - View all backup jobs, schedules, and history in one place
- **Alerting** - Get notified on failures
- **No local cron management** - Schedule controlled from Rundeck server
- **Audit trail** - Full history of job executions

#### Rundeck Job Setup

1. Add your server as a node in Rundeck
2. Create a new job with the following command:

```bash
# Command to execute on remote node
/opt/pbs_backup_hubseek/backup/backup-enhance.sh
```

3. Set the schedule in Rundeck's scheduler (equivalent to cron syntax)
4. Configure notifications for failure alerts

#### Example Rundeck Commands by Server Type

| Server Type | Command |
|-------------|---------|
| Enhance Control Panel | `/opt/pbs_backup_hubseek/backup/backup-enhance-cp.sh` |
| Enhance Backup Server | `/opt/pbs_backup_hubseek/backup/backup-enhance.sh` |
| Coolify Primary | `/opt/pbs_backup_hubseek/backup/backup-coolify.sh` |
| Coolify App Server | `/opt/pbs_backup_hubseek/backup/backup-coolify-apps.sh` |
| Generic | `/opt/pbs_backup_hubseek/backup/backup-base.sh` |

#### Scheduling Considerations

- **Stagger backups** by 30 minutes to avoid overloading PBS
- **Off-peak hours** (1-6 AM) for application servers
- **Peak hours OK** for backup servers (they're busy during off-hours)

### Option 2: Cron (Fallback/Standalone)

Use local cron when Rundeck is unavailable or for standalone servers not yet added to Rundeck.

#### Server-Specific Cron Entries

Add to root's crontab (`sudo crontab -e`):

```bash
# Enhance Control Panel - Daily at 2:30 AM
30 2 * * * /opt/pbs_backup_hubseek/backup/backup-enhance-cp.sh >> /var/log/pbs-backup/cron.log 2>&1

# Enhance Backup Server - Daily at 10 AM (peak OK - busy during off-hours)
0 10 * * * /opt/pbs_backup_hubseek/backup/backup-enhance.sh >> /var/log/pbs-backup/cron.log 2>&1

# Coolify Primary - Daily at 3 AM
0 3 * * * /opt/pbs_backup_hubseek/backup/backup-coolify.sh >> /var/log/pbs-backup/cron.log 2>&1

# Coolify App Server - Daily at 3:30 AM
30 3 * * * /opt/pbs_backup_hubseek/backup/backup-coolify-apps.sh >> /var/log/pbs-backup/cron.log 2>&1

# Generic/Other Server - Daily at 4 AM
0 4 * * * /opt/pbs_backup_hubseek/backup/backup-base.sh >> /var/log/pbs-backup/cron.log 2>&1
```

**Note**: Each script is self-contained. For example, `backup-enhance.sh` handles metadata generation AND the PBS backup - you don't need separate cron entries for each step.

#### Common Schedule Patterns

Adjust the time (first two fields) based on your needs:

```bash
# Every 6 hours
0 */6 * * * /opt/pbs_backup_hubseek/backup/backup-enhance.sh >> /var/log/pbs-backup/cron.log 2>&1

# Twice daily (2 AM and 2 PM)
0 2,14 * * * /opt/pbs_backup_hubseek/backup/backup-enhance.sh >> /var/log/pbs-backup/cron.log 2>&1

# Weekly on Sunday at 1 AM
0 1 * * 0 /opt/pbs_backup_hubseek/backup/backup-enhance.sh >> /var/log/pbs-backup/cron.log 2>&1
```

### Verify Backups are Working

```bash
# Check local logs
tail -f /var/log/pbs-backup/cron.log

# List scheduled cron jobs (if using cron)
crontab -l

# Check last backup in PBS
/opt/pbs_backup_hubseek/restore/restore-base.sh --list
```

For Rundeck, check the job history in the Rundeck web interface.

## PBS Server Details

- **Server**: kata.hubseek.com (158.69.224.88)
- **Datastore**: backups
- **Authentication**: API token based
- **Encryption**: Client-side with key files

## Creating API Token

1. Log in to PBS web interface
2. Navigate to: Configuration > Access Control > API Tokens
3. Add new token
4. Copy Token ID and Secret to configuration

## Documentation

- [PBS Server Setup Guide](docs/pbs-setup.md) - Setting up Proxmox Backup Server
- [Full System Restore Guide](docs/full-system-restore.md) - Restoring entire VPS from root.pxar
- [PBS Backup Examples](docs/reference/pbs-backup-examples.md) - Reference scripts and patterns
- [Enhance Control Panel Guide](docs/enhance-cp-backup.md) - Backup/restore for Enhance control panel
- [Enhance Backup Server Guide](docs/enhance-backup.md) - Backup/restore for Enhance v12 backup servers
- [Coolify Backup Guide](docs/coolify-backup.md) - Backup/restore for Coolify instances and applications

## Security Notes

- Never commit `credentials.conf` or encryption keys
- Store encryption keys in a secure, separate location
- Use minimal permissions for API tokens
- Regularly rotate API tokens

## License

MIT License
