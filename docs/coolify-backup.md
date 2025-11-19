# Coolify Instance - PBS Backup Guide

This guide covers backing up and restoring Coolify instances using PBS.

## Overview

Coolify has a built-in S3 backup feature that backs up its PostgreSQL database on a schedule. However, this S3 backup does **not** include:

- **APP_KEY** (in `/data/coolify/source/.env`) - Required for decryption
- **SSH Keys** (in `/data/coolify/ssh/keys/`) - Required for server connectivity

Without these items, a restore will fail with 500 errors or "Permission denied" on server connections.

**Solution**: This PBS backup script captures the items missing from S3 backup, plus creates an additional database dump for redundancy.

## What Gets Backed Up

| Archive | Source | Purpose |
|---------|--------|---------|
| `coolify-env.pxar` | `/data/coolify/source/.env` | APP_KEY for decryption |
| `coolify-ssh.pxar` | `/data/coolify/ssh/keys/` | SSH private keys |
| `coolify-db.pxar` | PostgreSQL dump | Database snapshot (custom format) |

## Backup

### Running a Backup

```bash
# Standard backup
sudo /opt/pbs_backup_hubseek/backup/backup-coolify.sh

# With Rundeck or cron (daily at 3 AM)
0 3 * * * /opt/pbs_backup_hubseek/backup/backup-coolify.sh >> /var/log/pbs-backup/cron.log 2>&1
```

### What Happens During Backup

1. Verifies Coolify directories and Docker container exist
2. Creates PostgreSQL dump using `pg_dump -Fc` (custom format)
3. Backs up .env file, SSH keys, and database dump to PBS
4. Cleans up temporary dump file

## Restore Scenarios

### Scenario 1: Get APP_KEY for New Server

When setting up a new Coolify instance and you need the APP_KEY:

```bash
# Extract just the .env file
sudo /opt/pbs_backup_hubseek/restore/restore-coolify.sh --env-only "host/coolify-server/2025-01-22T15:19:17Z"
```

This displays the APP_KEY value to add as `APP_PREVIOUS_KEYS` in your new server's .env.

### Scenario 2: Restore SSH Keys

When migrating and servers show "Permission denied":

```bash
# Extract just SSH keys
sudo /opt/pbs_backup_hubseek/restore/restore-coolify.sh --ssh-only "host/coolify-server/2025-01-22T15:19:17Z"
```

Then copy the keys to `/data/coolify/ssh/keys/` on the new server.

### Scenario 3: Restore Database

When the S3 backup failed or you need a point-in-time recovery:

```bash
# Extract just database dump
sudo /opt/pbs_backup_hubseek/restore/restore-coolify.sh --db-only "host/coolify-server/2025-01-22T15:19:17Z"
```

### Scenario 4: Full Restore to New Server

Complete migration or disaster recovery:

```bash
# List available snapshots
sudo /opt/pbs_backup_hubseek/restore/restore-coolify.sh --list

# Extract all components
sudo /opt/pbs_backup_hubseek/restore/restore-coolify.sh "host/coolify-server/2025-01-22T15:19:17Z"
```

Then follow the restoration guide printed by the script.

## Full Restoration Process

### Step 1: Install Fresh Coolify

On the new server, run the Coolify installation script with the matching version number.

### Step 2: Stop Coolify Services

```bash
docker stop coolify coolify-redis coolify-realtime coolify-proxy
```

### Step 3: Restore Database

```bash
cat /path/to/coolify.dump | docker exec -i coolify-db \
  pg_restore --verbose --clean --no-acl --no-owner \
  -U coolify -d coolify
```

> **Note**: Warnings about existing foreign keys or sequences can usually be ignored.

### Step 4: Restore SSH Keys

```bash
# Remove auto-generated keys
rm -rf /data/coolify/ssh/keys/*

# Copy restored keys
cp /path/to/restored/keys/* /data/coolify/ssh/keys/

# Set permissions
chmod 600 /data/coolify/ssh/keys/*
```

### Step 5: Update .env with Previous APP_KEY

Edit `/data/coolify/source/.env`:

```bash
nano /data/coolify/source/.env
```

Add the line:
```
APP_PREVIOUS_KEYS=base64:your-previous-app-key-here
```

### Step 6: Fix Permissions (if needed)

```bash
sudo chown -R root:root /data/coolify
```

### Step 7: Restart Coolify

Re-run the Coolify installation script with the version number.

### Step 8: Verify

- Web UI loads without 500 errors
- All servers are reachable
- Test application deployments work

## Command Reference

### Backup Script

```bash
/opt/pbs_backup_hubseek/backup/backup-coolify.sh
```

No arguments needed. Reads configuration from `config/pbs.conf`.

### Restore Script

```bash
/opt/pbs_backup_hubseek/restore/restore-coolify.sh [OPTIONS] <snapshot_path>

Options:
    -l, --list          List available snapshots
    -e, --env-only      Extract only .env file
    -s, --ssh-only      Extract only SSH keys
    -b, --db-only       Extract only database dump
    -d, --dest PATH     Restore to alternate destination
    -h, --help          Show help
```

## Prerequisites

### For Backup

- Coolify installed at `/data/coolify`
- Docker running with `coolify-db` container
- Proxmox Backup Client installed
- PBS configuration completed (`config/pbs.conf`, `config/credentials.conf`)
- Encryption key created and stored

### For Restore

- Proxmox Backup Client installed
- Same PBS configuration (server, datastore, credentials, encryption key)
- Docker installed (for database restore)

## Integration with S3 Backup

This PBS backup **complements** the built-in S3 backup:

| Feature | S3 Backup | PBS Backup |
|---------|-----------|------------|
| Database | ✅ Scheduled | ✅ On-demand |
| APP_KEY | ❌ | ✅ |
| SSH Keys | ❌ | ✅ |
| Application Data | ❌ | ❌ (use coolify-apps backup) |

**Recommendation**: Keep both backups running:
- S3 backup: Frequent database snapshots
- PBS backup: Daily capture of credentials + redundant database dump

## Troubleshooting

### "Coolify database container not running"

Ensure Coolify is running:
```bash
docker ps | grep coolify
```

If the container is stopped, start Coolify first before running backup.

### 500 Errors After Restore

The APP_KEY is missing or incorrect. Verify:
```bash
grep APP_PREVIOUS_KEYS /data/coolify/source/.env
```

The value must match the APP_KEY from the backup.

### "Server is not reachable (Permission denied)"

SSH keys weren't restored or have wrong permissions:
```bash
ls -la /data/coolify/ssh/keys/
```

All key files should be owned by root with 600 permissions.

### Database Restore Warnings

Warnings like these can be ignored:
- "role 'coolify' already exists"
- "constraint already exists"
- "sequence already exists"

These occur because `--clean` drops objects before recreating them.

## Security Notes

- Database dump has 600 permissions (root only)
- .env file contains sensitive APP_KEY
- SSH keys must be kept secure - they provide server access
- Encryption key must be securely transferred to new servers

---

# Coolify Applications - PBS Backup Guide

This section covers backing up deployed application data (Docker volumes, bind mounts, databases).

## Overview

The `backup-coolify-apps.sh` script automatically discovers and backs up:
- All Docker volumes
- All bind mounts from running containers
- Database dumps from PostgreSQL, MySQL/MariaDB, and MongoDB containers
- Container metadata including environment variables (credentials)

This script runs **without stopping containers** - it uses Docker's recommended backup method and transaction-consistent database dumps.

## Server Deployment

| Server Type | Scripts to Run |
|-------------|----------------|
| Primary Coolify | `backup-coolify.sh` + `backup-coolify-apps.sh` |
| Secondary (apps only) | `backup-coolify-apps.sh` |

## What Gets Backed Up

All artifacts are collected into a single PBS archive `coolify-apps.pxar`:

| Directory | Contents |
|-----------|----------|
| `volumes/` | Docker volume archives (`.tar.gz`) |
| `binds/` | Bind mount archives (`.tar.gz`) |
| `databases/` | Database dumps (`.dump`, `.sql`, `.archive`) |
| `metadata.json` | Container mappings, env vars, credentials |

### Database Detection

The script automatically detects and dumps databases:

| Image Pattern | Dump Method | Output |
|--------------|-------------|--------|
| `postgres*` | `pg_dump -Fc` | `container.dump` |
| `mysql*` / `mariadb*` | `mysqldump --single-transaction` | `container.sql` |
| `mongo*` | `mongodump --archive` | `container.archive` |
| `redis*` | Skipped (ephemeral cache) | - |

Credentials are extracted from container environment variables.

## Backup

### Running a Backup

```bash
# Standard backup
sudo /opt/pbs_backup_hubseek/backup/backup-coolify-apps.sh

# With Rundeck or cron (daily at 4 AM)
0 4 * * * /opt/pbs_backup_hubseek/backup/backup-coolify-apps.sh >> /var/log/pbs-backup/cron.log 2>&1
```

### What Happens During Backup

1. Discovers all running Docker containers
2. For each container:
   - Extracts environment variables (credentials)
   - Identifies volume and bind mounts
   - Detects if it's a database container
3. Dumps databases using appropriate commands
4. Archives volumes using Docker temporary container method
5. Archives bind mounts directly
6. Generates metadata JSON with all mappings
7. Backs up everything to PBS

## Restore

### List Available Snapshots

```bash
sudo /opt/pbs_backup_hubseek/restore/restore-coolify-apps.sh --list
```

### Extract and Review Metadata

Before restoring, review what's in the backup:

```bash
sudo /opt/pbs_backup_hubseek/restore/restore-coolify-apps.sh --metadata-only "host/server/2025-01-22T15:19:17Z"
```

This shows:
- All containers and their configurations
- Environment variables (including passwords)
- Volume and bind mount mappings
- Database types and credentials

### Full Extraction

```bash
sudo /opt/pbs_backup_hubseek/restore/restore-coolify-apps.sh "host/server/2025-01-22T15:19:17Z"
```

This extracts all artifacts and prints a restoration guide.

## Restoration Process

### Restoring a Docker Volume

```bash
# 1. Create the volume if needed
docker volume create my-app-data

# 2. Restore from archive
docker run --rm \
  -v my-app-data:/volume \
  -v /path/to/extracted/volumes:/backup \
  busybox sh -c 'cd /volume && tar xzf /backup/my-app-data.tar.gz'
```

### Restoring a PostgreSQL Database

```bash
# Get credentials from metadata
jq '.containers["postgres-container"].env' /path/to/metadata.json

# Restore
cat /path/to/databases/postgres-container.dump | docker exec -i <container> \
  pg_restore --verbose --clean --no-acl --no-owner \
  -U <user> -d <database>
```

### Restoring a MySQL Database

```bash
cat /path/to/databases/mysql-container.sql | docker exec -i <container> \
  mysql -u <user> -p<password> <database>
```

### Restoring a Bind Mount

```bash
tar xzf /path/to/binds/_host_path.tar.gz -C /host/path
```

## Command Reference

### Backup Script

```bash
/opt/pbs_backup_hubseek/backup/backup-coolify-apps.sh
```

No arguments needed. Automatically discovers all containers.

### Restore Script

```bash
/opt/pbs_backup_hubseek/restore/restore-coolify-apps.sh [OPTIONS] <snapshot_path>

Options:
    -l, --list          List available snapshots
    -m, --metadata-only Extract and display metadata only
    -v, --volume NAME   Restore specific volume only
    -b, --bind PATH     Restore specific bind mount only
    -D, --db NAME       Restore specific database dump only
    -d, --dest PATH     Extract to alternate destination
    -h, --help          Show help
```

## Metadata File

The `metadata.json` file contains everything needed for restore:

```json
{
  "generated": "2025-01-22T15:19:17+00:00",
  "hostname": "coolify-server",
  "containers": {
    "my-postgres": {
      "image": "postgres:15",
      "volumes": ["my-app-data"],
      "binds": [],
      "env": {
        "POSTGRES_USER": "app",
        "POSTGRES_PASSWORD": "secret123",
        "POSTGRES_DB": "myapp"
      },
      "is_database": true,
      "db_type": "postgres"
    }
  },
  "backed_up_volumes": ["my-app-data"],
  "backed_up_binds": []
}
```

## Prerequisites

- Docker installed and running
- Proxmox Backup Client installed
- PBS configuration completed
- `jq` recommended for viewing metadata
- `busybox` image available (for volume restore)

## Troubleshooting

### "Failed to dump PostgreSQL for container"

Check that credentials are set via environment variables:
```bash
docker inspect <container> | jq '.[0].Config.Env'
```

Look for `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`.

### Volume archive is empty

The volume may not have any data, or the container may have it mounted read-only. Check:
```bash
docker volume inspect <volume-name>
docker inspect <container> | jq '.[0].Mounts'
```

### Database dump is inconsistent

For heavily-written databases, consider briefly pausing writes or using replication for backup. The dump commands are transaction-consistent but represent a point-in-time snapshot.

## Security Notes

- Metadata file contains plaintext credentials (600 permissions)
- PBS backup is encrypted, protecting credentials at rest
- Review metadata before sharing or storing extracted files
- Database dumps may contain sensitive application data

## Scheduling Recommendations

Stagger backups to avoid overlap:

| Time | Server | Script |
|------|--------|--------|
| 2:00 | Primary Coolify | `backup-coolify.sh` |
| 2:30 | Primary Coolify | `backup-coolify-apps.sh` |
| 3:00 | Secondary Server 1 | `backup-coolify-apps.sh` |
| 3:30 | Secondary Server 2 | `backup-coolify-apps.sh` |

This ensures sequential backups and clear log separation.
