# Proxmox Backup Server Setup Guide

This guide documents the PBS server setup for use with this backup suite.

## Server Information

| Setting | Value |
|---------|-------|
| Hostname | `kata.hubseek.com` |
| IP Address | `158.69.224.88` |
| Port | `8007` |
| Datastore | `backups` |

## Initial PBS Installation

### 1. Install PBS

Follow the official Proxmox Backup Server installation guide:
https://pbs.proxmox.com/docs/installation.html

For Debian-based systems:
```bash
# Add Proxmox repository
wget https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg
echo "deb http://download.proxmox.com/debian/pbs bookworm pbs-no-subscription" > /etc/apt/sources.list.d/pbs.list

apt update
apt install proxmox-backup-server
```

### 2. Access Web Interface

Navigate to: `https://your-pbs-server:8007`

Default login: `root@pam` with your system root password

## Datastore Setup

### Create Datastore

1. **Web UI**: Datastore → Create
2. **Settings**:
   - Name: `backups`
   - Backing Path: `/path/to/storage` (e.g., `/mnt/backups`)
   - Comment: `VPS backups`

### Configure Retention Policy

1. **Web UI**: Datastore → `backups` → Prune & GC → Prune Jobs
2. **Recommended retention**:
   ```
   Keep Last: 7
   Keep Daily: 14
   Keep Weekly: 8
   Keep Monthly: 6
   Keep Yearly: 1
   ```

This keeps:
- Last 7 backups (regardless of age)
- 14 daily backups
- 8 weekly backups
- 6 monthly backups
- 1 yearly backup

### Configure Garbage Collection

1. **Web UI**: Datastore → `backups` → Prune & GC → GC Jobs
2. **Schedule**: Weekly (e.g., Sunday 3:00 AM)

GC removes unreferenced chunks after pruning.

### Configure Verification Jobs

1. **Web UI**: Datastore → `backups` → Verify Jobs
2. **Create verification job**:
   - Schedule: Weekly (e.g., Saturday 2:00 AM)
   - Outdated After: 30 days

This verifies backup integrity on the server side.

## User and API Token Setup

### Create Backup User

1. **Web UI**: Configuration → Access Control → User Management → Add
2. **Settings**:
   - User ID: `backup@pbs`
   - Password: (set a strong password, though we'll use token auth)
   - Enable: Yes

### Create API Token

1. **Web UI**: Configuration → Access Control → API Token → Add
2. **Settings**:
   - User: `backup@pbs`
   - Token ID: `backup-token`
   - Privilege Separation: No (uncheck)
3. **Save the token secret** - it's only shown once!

Token format: `backup@pbs!backup-token`

### Set Permissions

1. **Web UI**: Configuration → Access Control → Permissions → Add
2. **Settings**:
   - Path: `/datastore/backups`
   - User/Token: `backup@pbs!backup-token`
   - Role: `DatastoreBackup`

The `DatastoreBackup` role allows:
- Creating backups
- Listing snapshots
- Reading/restoring backups

## Encryption Key

### Generate Key (on any client)

```bash
proxmox-backup-client key create /root/pbs_encryption_key.json
```

You'll be prompted for a password to protect the key file.

### Secure the Key

```bash
chmod 600 /root/pbs_encryption_key.json
```

### Backup the Key!

**Critical**: Store this key securely outside PBS. Without it, encrypted backups are unrecoverable.

Options:
- Password manager
- Ansible Vault
- Secure offline storage

## Network/Firewall

### Required Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 8007 | TCP | Web UI and API |

### Firewall Rules (on PBS server)

```bash
# UFW
ufw allow 8007/tcp comment "PBS API"

# iptables
iptables -A INPUT -p tcp --dport 8007 -j ACCEPT
```

### Client Connectivity Test

From a backup client:
```bash
proxmox-backup-client list --repository backup@pbs!backup-token@kata.hubseek.com:8007:backups
```

## Monitoring and Alerts

### Email Notifications

1. **Web UI**: Configuration → Notifications
2. Configure SMTP settings
3. Set notification targets for:
   - Backup verification failures
   - GC failures
   - Sync failures

### Monitoring Endpoints

PBS exposes metrics at:
- `/api2/json/status`
- `/api2/json/nodes/{node}/status`

## Backup Client Installation

On each VPS that will be backed up:

### Debian/Ubuntu

```bash
# Add repository
wget https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg
echo "deb http://download.proxmox.com/debian/pbs-client bookworm main" > /etc/apt/sources.list.d/pbs-client.list

# Install
apt update
apt install proxmox-backup-client
```

### Verify Installation

```bash
proxmox-backup-client version
```

## Configuration for This Backup Suite

### Files to Create on Each Client

1. **`/opt/pbs_backup_hubseek/config/pbs.conf`**:
   ```bash
   PBS_SERVER="kata.hubseek.com"
   PBS_PORT="8007"
   PBS_DATASTORE="backups"
   PBS_TOKEN_USER="backup@pbs"
   PBS_TOKEN_NAME="backup-token"
   PBS_KEYFILE="/root/pbs_encryption_key.json"
   BACKUP_SKIP_LOST_AND_FOUND="true"
   BACKUP_LOG_DIR="/var/log/pbs-backup"
   SERVER_TYPE="auto"
   ```

2. **`/opt/pbs_backup_hubseek/config/credentials.conf`**:
   ```bash
   PBS_TOKEN_SECRET="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
   ```

   **Secure this file**:
   ```bash
   chmod 600 /opt/pbs_backup_hubseek/config/credentials.conf
   ```

3. **Encryption key**: Copy `/root/pbs_encryption_key.json` from secure storage

## Ansible Deployment Notes

For Ansible deployment, store secrets in Ansible Vault:

```yaml
# group_vars/all/vault.yml (encrypted)
pbs_token_secret: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
pbs_encryption_key: |
  {
    "kdf": "scrypt",
    ...
  }
```

Template the config files:
```yaml
- name: Create credentials.conf
  template:
    src: credentials.conf.j2
    dest: /opt/pbs_backup_hubseek/config/credentials.conf
    mode: '0600'
```

## Troubleshooting

### "Authentication failed"

- Verify token secret is correct
- Check token has permissions on datastore
- Ensure user is enabled

### "Connection refused"

- Verify PBS service is running: `systemctl status proxmox-backup`
- Check firewall allows port 8007
- Verify hostname/IP is correct

### "Encryption key required"

- Ensure keyfile path is correct in config
- Verify keyfile permissions (600 or 400)
- Check keyfile password if prompted

### Datastore full

- Check retention policy is pruning old backups
- Run GC manually: Datastore → GC Jobs → Run Now
- Consider adding storage or adjusting retention

## Maintenance Tasks

### Regular Tasks

| Task | Frequency | How |
|------|-----------|-----|
| Verify backups | Weekly | Automatic (verify job) |
| Prune old backups | Daily | Automatic (prune job) |
| Garbage collection | Weekly | Automatic (GC job) |
| Check disk space | Weekly | Manual / monitoring |
| Review logs | Weekly | Web UI → Logs |

### Updates

```bash
apt update
apt upgrade proxmox-backup-server
```

## Quick Reference

```bash
# Test connection from client
proxmox-backup-client list --repository backup@pbs!backup-token@kata.hubseek.com:8007:backups

# List all snapshots
proxmox-backup-client snapshot list --repository ...

# Check datastore status (on PBS server)
proxmox-backup-manager datastore show backups

# Manual GC (on PBS server)
proxmox-backup-manager garbage-collect backups

# Verify specific backup
proxmox-backup-client verify "host/myserver/2025-01-22T15:19:17Z" --repository ...
```
