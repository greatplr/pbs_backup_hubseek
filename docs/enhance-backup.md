# Enhance Backup Server - PBS Backup Guide

This guide covers backing up and restoring Enhance v12 backup servers using PBS.

## Overview

The Enhance backup scripts handle the unique requirement of preserving user/group ownership across restores to new servers. PBS natively preserves all file permissions and numeric UID/GID, but when restoring to a new server, the users must be created first.

**Solution**: The backup script generates a metadata file containing UID/GID mappings for all site folders. On restore to a new server, this metadata is used to create matching users before the files are restored.

## Backup

### What Gets Backed Up

- `/backups` directory (all site folders)
- `.pbs_user_metadata.json` - auto-generated UID/GID mappings
- All file permissions, ownership, timestamps, ACLs
- Hard links and symlinks preserved

### Running a Backup

```bash
# Standard backup
sudo /opt/pbs_backup_hubseek/backup/backup-enhance.sh

# With cron (daily at 2 AM)
0 2 * * * /opt/pbs_backup_hubseek/backup/backup-enhance.sh >> /var/log/pbs-backup/cron.log 2>&1
```

### Metadata File

The backup script automatically generates `.pbs_user_metadata.json` in `/backups`:

```json
{
  "generated": "2025-01-22T15:19:17+00:00",
  "hostname": "enhance-backup.example.com",
  "sites": {
    "123e4567-e89b-12d3-a456-426614174000": {
      "owner": "site_abc123",
      "group": "site_abc123",
      "uid": 1001,
      "gid": 1001,
      "home": "/home/site_abc123"
    },
    "234e5678-f90c-23d4-b567-526715175111": {
      "owner": "site_def456",
      "group": "site_def456",
      "uid": 1002,
      "gid": 1002,
      "home": "/home/site_def456"
    }
  }
}
```

## Restore Scenarios

### Scenario 1: Restore to Same Server

For disaster recovery where the server still has the original users:

```bash
# List available snapshots
sudo /opt/pbs_backup_hubseek/restore/restore-enhance.sh --list

# Restore (users already exist)
sudo /opt/pbs_backup_hubseek/restore/restore-enhance.sh "host/enhance-backup/2025-01-22T15:19:17Z"
```

### Scenario 2: Restore to New Server

For migration or building a replacement server:

```bash
# 1. First, review the metadata to see what users will be created
sudo /opt/pbs_backup_hubseek/restore/restore-enhance.sh --metadata-only "host/enhance-backup/2025-01-22T15:19:17Z"

# 2. Restore with user creation
sudo /opt/pbs_backup_hubseek/restore/restore-enhance.sh --create-users "host/enhance-backup/2025-01-22T15:19:17Z"
```

The `--create-users` flag will:
- Create groups with matching GIDs
- Create users with matching UIDs, GIDs, and home directories
- Set shell to `/usr/sbin/nologin` for security
- Then restore all files with correct ownership

### Scenario 3: Restore to Alternate Location

For testing or selective restore:

```bash
# Restore to different directory
sudo /opt/pbs_backup_hubseek/restore/restore-enhance.sh --dest /tmp/restore-test "host/enhance-backup/2025-01-22T15:19:17Z"
```

## Command Reference

### Backup Script

```bash
/opt/pbs_backup_hubseek/backup/backup-enhance.sh
```

No arguments needed. Reads configuration from `config/pbs.conf`.

### Restore Script

```bash
/opt/pbs_backup_hubseek/restore/restore-enhance.sh [OPTIONS] <snapshot_path>

Options:
    -l, --list          List available snapshots
    -c, --create-users  Create users/groups from metadata
    -m, --metadata-only Extract metadata without full restore
    -d, --dest PATH     Restore to alternate destination
    -h, --help          Show help
```

## Prerequisites

### For Backup Server

- Proxmox Backup Client installed
- PBS configuration completed (`config/pbs.conf`, `config/credentials.conf`)
- Encryption key created and stored

### For New Server Restore

- Proxmox Backup Client installed
- Same PBS configuration (server, datastore, credentials, encryption key)
- `jq` installed for user creation: `apt install jq`

## Troubleshooting

### "Metadata file not found in backup"

Backups created before the metadata feature won't have this file. Options:
1. Run a new backup on the source server
2. Manually create users on the target server before restore

### "User exists with different UID/GID"

The script will modify existing users to match the backup metadata. This is usually safe but review the warnings in the log.

### Permission denied after restore

Verify users were created correctly:
```bash
# Check a site folder's ownership
ls -la /backups/

# Verify user exists with correct UID
id site_abc123
```

## Security Notes

- Metadata file permissions are set to 600 (root only)
- Created users have `/usr/sbin/nologin` shell
- No passwords are set for created users
- Encryption key must be securely transferred to new servers
