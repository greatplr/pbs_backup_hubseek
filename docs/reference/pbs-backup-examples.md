# PBS Backup/Restore Reference Examples

Source: https://merox.dev/blog/3-2-1-backup-strategy/

## Overview

This document contains reference examples for Proxmox Backup Server (PBS) client operations including backup, restore, and configuration patterns.

## Environment Variables

The PBS client uses these environment variables for authentication:

| Variable | Description |
|----------|-------------|
| `PBS_PASSWORD` | API token secret from PBS |
| `PBS_USER_STRING` | API token ID from PBS |
| `PBS_SERVER` | PBS server IP/hostname |
| `PBS_DATASTORE` | Target datastore name |
| `PBS_REPOSITORY` | Full repository path (constructed) |
| `PBS_KEYFILE` | Path to encryption key file |

## Backup Script Pattern

```bash
#!/bin/bash
export PBS_PASSWORD='token-secret-from-PBS'
export PBS_USER_STRING='token-id-from-PBS'
export PBS_SERVER='PBS-IP'
export PBS_DATASTORE='DATASTORE_PBS'
export PBS_REPOSITORY="${PBS_USER_STRING}@${PBS_SERVER}:${PBS_DATASTORE}"
export PBS_HOSTNAME="$(hostname -s)"
export PBS_KEYFILE='/root/pbscloud_key.json'

echo "Run pbs backup for $PBS_HOSTNAME ..."
proxmox-backup-client backup \
  srv.pxar:/srv \
  volumes.pxar:/var/lib/docker/volumes \
  netw.pxar:/var/lib/docker/network \
  etc.pxar:/etc \
  scripts.pxar:/usr/local/bin \
  --keyfile /root/pbscloud_key.json \
  --skip-lost-and-found \
  --repository "$PBS_REPOSITORY"

proxmox-backup-client list --repository "${PBS_REPOSITORY}"
echo "Done."
```

### Key Features

- Multiple archive formats (`.pxar`) for different content types
- Encryption via keyfile parameter
- Lost-and-found file skipping
- Repository constructed from components

## Restore Script Pattern

```bash
#!/bin/bash
export PBS_PASSWORD='token-secret-from-PBS'
export PBS_USER_STRING='token-id-from-PBS'
export PBS_SERVER='PBS_IP'
export PBS_DATASTORE='DATASTORE_FROM_PBS'
export PBS_KEYFILE='/root/pbscloud_key.json'
export PBS_REPOSITORY="${PBS_USER_STRING}@${PBS_SERVER}:${PBS_DATASTORE}"

SNAPSHOT_PATH="$1"
ARCHIVE_NAME="$2"
RESTORE_DEST="$3"

if [[ -z "$SNAPSHOT_PATH" || -z "$ARCHIVE_NAME" || -z "$RESTORE_DEST" ]]; then
  echo "Usage: $0 <snapshot_path> <archive_name> <destination>"
  echo "Example: $0 \"host/cloud/2025-01-22T15:19:17Z\" srv.pxar /root/restore-srv"
  exit 1
fi

mkdir -p "$RESTORE_DEST"

echo "=== PBS Restore ==="
echo "Snapshot:      $SNAPSHOT_PATH"
echo "Archive:       $ARCHIVE_NAME"
echo "Destination:   $RESTORE_DEST"
echo "Repository:    $PBS_REPOSITORY"
echo "Encryption key $PBS_KEYFILE"
echo "====================="

proxmox-backup-client restore \
  "$SNAPSHOT_PATH" \
  "$ARCHIVE_NAME" \
  "$RESTORE_DEST" \
  --repository "$PBS_REPOSITORY" \
  --keyfile "$PBS_KEYFILE"

EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then
  echo "=== Restore completed successfully! ==="
else
  echo "Restore error (code $EXIT_CODE)."
fi

exit $EXIT_CODE
```

### Usage

```bash
./backup-pbs-restore.sh "host/cloud/2025-01-22T15:19:17Z" srv.pxar /root/restore-srv
```

## Crontab Scheduling

Daily backup at 2 AM:
```bash
0 2 * * * /usr/local/bin/backup-pbs.sh >> /var/log/backup-cloud.log 2>&1
```

## PBS Client Installation

For non-Proxmox systems (Ubuntu/Debian), the `proxmox-backup-client` package needs to be installed from the Proxmox repository.

## Encryption Key Management

- Keys are stored as JSON files (e.g., `/root/pbscloud_key.json`)
- Keys should be securely backed up separately from the PBS server
- Each client can have its own encryption key

## Common proxmox-backup-client Commands

| Command | Description |
|---------|-------------|
| `backup` | Create a new backup |
| `restore` | Restore from backup |
| `list` | List available snapshots |
| `snapshot list` | List snapshots with details |
| `key create` | Create new encryption key |

## Archive Naming Convention

Archives use the `.pxar` format (Proxmox Archive):
- `srv.pxar:/srv` - Service data
- `etc.pxar:/etc` - System configuration
- `volumes.pxar:/var/lib/docker/volumes` - Docker volumes

The format is: `archive-name.pxar:/source/path`
