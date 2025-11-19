# Enhance Control Panel - PBS Backup Guide

This guide covers backing up and restoring the Enhance Control Panel server using PBS for disaster recovery and migration scenarios.

## Overview

The Enhance Control Panel is the central management server for your Enhance cluster. Unlike the backup server (which stores customer site backups), the control panel contains:

- **PostgreSQL databases** (`orchd`, `authd`) - All configuration, users, websites, settings
- **SSL certificates and private keys** - For secure communication between cluster nodes
- **Orchd private keys** - For cluster authentication
- **Control panel assets** - Custom branding, logos

Losing the control panel without a backup can be catastrophic - you'd lose all configuration for your entire hosting cluster.

## What Gets Backed Up

| Component | Path | Purpose |
|-----------|------|---------|
| Full system | `/` | Complete disaster recovery |
| orchd database | PostgreSQL dump | Core configuration |
| authd database | PostgreSQL dump | Authentication |
| SSL certificates | `/etc/ssl/certs/enhance/` | Cluster communication |
| SSL private keys | `/etc/ssl/private/enhance/` | Cluster communication |
| Orchd directory | `/var/local/enhance/orchd/` | Private keys, cloudflare key |
| Control panel assets | `/var/www/control-panel/assets/` | Branding |

## Backup

### Running a Backup

```bash
# Standard backup
sudo /opt/pbs_backup_hubseek/backup/backup-enhance-cp.sh

# With cron (daily at 3 AM)
0 3 * * * /opt/pbs_backup_hubseek/backup/backup-enhance-cp.sh >> /var/log/pbs-backup/cron.log 2>&1
```

### What Happens During Backup

1. Verifies PostgreSQL is running
2. Dumps `orchd` and `authd` databases using `pg_dump -Fc` (custom format)
3. Backs up full system (`root.pxar`)
4. Backs up individual components for selective restore:
   - `enhance-cp-db.pxar` - Database dumps
   - `enhance-cp-ssl-certs.pxar` - SSL certificates
   - `enhance-cp-ssl-keys.pxar` - SSL private keys
   - `enhance-cp-orchd.pxar` - Orchd directory
   - `enhance-cp-assets.pxar` - Control panel assets

## Restore Scenarios

### Scenario 1: Full Disaster Recovery (Same Server)

If the server is recoverable, restore the full system:

```bash
# List available snapshots
sudo /opt/pbs_backup_hubseek/restore/restore-enhance-cp.sh --list

# Restore full system from root.pxar
proxmox-backup-client restore \
    "host/panel/2025-01-22T15:19:17Z" \
    root.pxar \
    / \
    --repository "user@server:datastore" \
    --keyfile /path/to/key.json
```

### Scenario 2: Migration to New Server

For migrating to a fresh Ubuntu server, follow the official Enhance documentation:
https://enhance.com/docs/advanced/control-panel-migration.html

Use our restore script to extract the needed files:

```bash
# Extract all components
sudo /opt/pbs_backup_hubseek/restore/restore-enhance-cp.sh "host/panel/2025-01-22T15:19:17Z"

# Or extract specific components
sudo /opt/pbs_backup_hubseek/restore/restore-enhance-cp.sh --db-only "host/panel/2025-01-22T15:19:17Z"
sudo /opt/pbs_backup_hubseek/restore/restore-enhance-cp.sh --keys-only "host/panel/2025-01-22T15:19:17Z"
```

### Migration Process Summary

1. **Prepare old server** (before disaster if possible):
   - Migrate all customer websites to other cluster servers
   - Delete phpMyAdmin/webmail sites
   - Uninstall unnecessary roles

2. **Set up new server**:
   - Install fresh Ubuntu 24.04 LTS
   - Install Enhance control panel

3. **Extract backup files**:
   ```bash
   sudo /opt/pbs_backup_hubseek/restore/restore-enhance-cp.sh "host/panel/2025-01-22T15:19:17Z"
   ```

4. **Restore databases**:
   ```bash
   sudo -u postgres pg_restore -d orchd /tmp/enhance-cp-restore-*/databases/orchd.dump
   sudo -u postgres pg_restore -d authd /tmp/enhance-cp-restore-*/databases/authd.dump
   ```

5. **Restore certificates and keys**:
   ```bash
   cp -r /tmp/enhance-cp-restore-*/ssl-certs/* /etc/ssl/certs/enhance/
   cp -r /tmp/enhance-cp-restore-*/ssl-keys/* /etc/ssl/private/enhance/
   cp -r /tmp/enhance-cp-restore-*/orchd/private/* /var/local/enhance/orchd/private/
   chown -R orchd:root /var/local/enhance/orchd/private/
   ```

6. **Update DNS** for control panel domain to new server IP

7. **Regenerate proxies**:
   ```bash
   ecp regenerate-control-panel-proxies
   ```

8. **Verify** cluster connectivity and control panel access

## Command Reference

### Backup Script

```bash
/opt/pbs_backup_hubseek/backup/backup-enhance-cp.sh
```

No arguments needed. Reads configuration from `config/pbs.conf`.

### Restore Script

```bash
/opt/pbs_backup_hubseek/restore/restore-enhance-cp.sh [OPTIONS] <snapshot_path>

Options:
    -l, --list          List available snapshots
    -d, --dest PATH     Extract to alternate destination
    --db-only           Extract only database dumps
    --keys-only         Extract only certificates and keys
    -h, --help          Show help
```

## Prerequisites

### For Backup

- Proxmox Backup Client installed
- PBS configuration completed
- Encryption key created
- PostgreSQL running

### For Restore/Migration

- Proxmox Backup Client installed
- Same PBS configuration and encryption key
- Fresh Ubuntu 24.04 LTS for migration target

## Important Notes

- **Test your backups regularly** - Extract and verify database dumps can be read
- **Keep encryption key safe** - Without it, backups are unrecoverable
- **Monitor backup logs** - Check `/var/log/pbs-backup/` for errors
- **Follow official docs** - The Enhance migration documentation should be your primary guide

## Troubleshooting

### "PostgreSQL service is not running"

Start PostgreSQL:
```bash
sudo systemctl start postgresql
```

### Database restore fails with "database does not exist"

Create the database first:
```bash
sudo -u postgres createdb orchd
sudo -u postgres createdb authd
```

### Permission denied on restored files

Fix ownership after copying:
```bash
chown -R orchd:root /var/local/enhance/orchd/private/
chmod 700 /var/local/enhance/orchd/private/
chmod 600 /var/local/enhance/orchd/private/*
```

### Cluster nodes can't connect after migration

1. Verify SSL certificates were copied correctly
2. Check DNS is pointing to new server IP
3. Run `ecp regenerate-control-panel-proxies`
4. Check firewall rules on new server
