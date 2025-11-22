# Database Backups

This document covers the application-aware backup features that ensure databases are safely backed up while running in production.

## Overview

The backup scripts automatically detect and dump databases before performing filesystem backups. This ensures consistent, restorable database snapshots without stopping services or locking tables.

## How It Works

1. **Detection**: Scripts auto-detect running databases (MySQL/MariaDB, PostgreSQL, Redis, SQLite)
2. **Dump**: Transaction-safe dumps are created in a temporary directory
3. **Archive**: Dumps are included as a separate `.pxar` archive in PBS
4. **Cleanup**: Temporary dump files are removed after backup completes

## Archives Created

| Script | Archive Name | Contents |
|--------|--------------|----------|
| `backup-base.sh` | `app-dumps.pxar` | MySQL dump, PostgreSQL dump, SQLite backups |
| `backup-enhance-cp.sh` | `enhance-cp-db.pxar` | PostgreSQL (orchd, authd) + any additional MySQL/SQLite |
| `backup-coolify.sh` | `coolify-db.pxar` | Coolify PostgreSQL dump |
| `backup-coolify-apps.sh` | `coolify-apps.pxar` | All container DB dumps + volumes + metadata |

## Databases Auto-Detected

### MySQL/MariaDB (systemd service)

- **Detection**: `systemctl is-active mysql` or `systemctl is-active mariadb`
- **Dump command**: `mysqldump --defaults-file=/etc/mysql/debian.cnf --single-transaction --all-databases --routines --triggers --events`
- **Output file**: `mysql-all-databases.sql`
- **Auth method**: Debian/Ubuntu socket authentication via `/etc/mysql/debian.cnf`

### PostgreSQL (systemd service)

- **Detection**: `systemctl is-active postgresql`
- **Dump command**: `sudo -u postgres pg_dumpall`
- **Output file**: `postgresql-all-databases.sql`
- **Auth method**: Peer authentication as postgres user

### Redis (systemd service)

- **Detection**: `systemctl is-active redis` or `systemctl is-active redis-server`
- **Action**: Triggers `BGSAVE` (RDB) and/or `BGREWRITEAOF` if persistence is enabled
- **Output**: No separate file - ensures Redis persistence files are flushed before filesystem backup
- **Note**: Skipped if Redis has no persistence configured (ephemeral cache)

### SQLite

- **Detection**: Checks common paths for SQLite database files
- **Dump command**: `sqlite3 <db> ".backup '<output>'"`
- **Paths checked**:
  - `/var/lib/grafana/grafana.db`
  - `/var/lib/homeassistant/home-assistant_v2.db`
  - `/etc/pihole/pihole-FTL.db`
  - `/etc/pihole/gravity.db`
  - `/var/lib/authelia/db.sqlite3`
  - `/var/lib/vaultwarden/db.sqlite3`
  - `/var/lib/bitwarden_rs/db.sqlite3`
  - And others (see `dump_sqlite_databases()` in `lib/common.sh`)

### Docker Containers (coolify-apps.sh only)

| Database | Detection | Dump Command |
|----------|-----------|--------------|
| PostgreSQL | Image contains "postgres" | `docker exec <container> pg_dump -U <user> -Fc <db>` |
| MySQL/MariaDB | Image contains "mysql" or "mariadb" | `docker exec -e MYSQL_PWD=<pass> <container> mysqldump --single-transaction` |
| MongoDB | Image contains "mongo" | `docker exec <container> mongodump --archive` |
| Redis | Image contains "redis" | Triggers `BGSAVE`/`BGREWRITEAOF` if persistence enabled |

## Restoring Database Dumps

### List Available Snapshots

```bash
proxmox-backup-client snapshot list \
    --repository "${PBS_USER}@${PBS_SERVER}:${PBS_PORT}:${PBS_DATASTORE}"
```

### Restore Database Dump Archive

```bash
# For backup-base.sh backups
proxmox-backup-client restore \
    "host/HOSTNAME/2025-11-22T00:11:31Z" \
    app-dumps.pxar \
    /tmp/restore-dumps/ \
    --repository "user@pbs.example.com:8007:datastore" \
    --keyfile /root/pbs_encryption_key.json

# For enhance-cp backups
proxmox-backup-client restore \
    "host/HOSTNAME/2025-11-22T00:11:31Z" \
    enhance-cp-db.pxar \
    /tmp/restore-dumps/ \
    --repository "user@pbs.example.com:8007:datastore" \
    --keyfile /root/pbs_encryption_key.json
```

### Restore MySQL/MariaDB

```bash
# Restore the dump file
cd /tmp/restore-dumps

# Import all databases
mysql < mysql-all-databases.sql

# Or import specific database (extract from dump first)
# Use mysql client to source the file
```

### Restore PostgreSQL

```bash
# Restore the dump file
cd /tmp/restore-dumps

# Import all databases (as postgres user)
sudo -u postgres psql < postgresql-all-databases.sql

# Or for custom format dumps (.dump files)
sudo -u postgres pg_restore -d <database> <file.dump>
```

### Restore SQLite

```bash
# SQLite backups are direct copies of the database file
# Simply copy back to original location
cp /tmp/restore-dumps/var_lib_grafana_grafana.db /var/lib/grafana/grafana.db
chown grafana:grafana /var/lib/grafana/grafana.db
```

### Restore Docker Container Databases (Coolify)

```bash
# Restore the coolify-apps archive
proxmox-backup-client restore \
    "host/HOSTNAME/2025-11-22T00:11:31Z" \
    coolify-apps.pxar \
    /tmp/restore-apps/ \
    --repository "user@pbs.example.com:8007:datastore" \
    --keyfile /root/pbs_encryption_key.json

# Database dumps are in /tmp/restore-apps/databases/
# PostgreSQL: <container_name>.dump (custom format)
# MySQL: <container_name>.sql
# MongoDB: <container_name>.archive

# Restore PostgreSQL container
cat /tmp/restore-apps/databases/myapp-db.dump | \
    docker exec -i <new_container> pg_restore -U postgres -d mydb

# Restore MySQL container
cat /tmp/restore-apps/databases/myapp-db.sql | \
    docker exec -i <new_container> mysql -u root -p<password>

# Restore MongoDB container
cat /tmp/restore-apps/databases/myapp-db.archive | \
    docker exec -i <new_container> mongorestore --archive
```

## Production Safety

All dump methods are designed to be safe for production:

| Database | Method | Locks Tables? | Blocks Writes? |
|----------|--------|---------------|----------------|
| MySQL/MariaDB | `--single-transaction` | No | No |
| PostgreSQL | `pg_dump` / `pg_dumpall` | No | No |
| MongoDB | `mongodump` | No | No |
| Redis | `BGSAVE` | No | No |
| SQLite | `.backup` command | Handles WAL correctly | Brief lock only |

## Retry Logic

All database dumps include retry logic with exponential backoff:

- **Attempts**: 3
- **Initial delay**: 5 seconds
- **Backoff**: Doubles each retry (5s, 10s, 20s)

If a dump fails after all retries, the script logs a warning and continues with the backup (dumps are not required for backup to succeed).

## Validation

Dump files are validated after creation:

- **Empty file check**: 0-byte dumps are rejected
- **Minimum size warning**: Files under 1KB trigger a warning (but are accepted)

## Troubleshooting

### MySQL dump fails with authentication error

Ensure `/etc/mysql/debian.cnf` exists and is readable by root. On modern Debian/Ubuntu with MariaDB, this file enables socket authentication.

If using a non-standard MySQL setup, create `/root/.my.cnf`:

```ini
[client]
user=root
password=yourpassword
```

```bash
chmod 600 /root/.my.cnf
```

### PostgreSQL dump fails

Ensure the `postgres` user can run `pg_dumpall`. The script uses `sudo -u postgres` which requires root access (scripts already check for root).

### Redis BGSAVE times out

BGSAVE has a 60-second timeout. If your Redis dataset is very large, it may take longer. The backup will continue anyway - this is just a warning.

### SQLite database not detected

Only common paths are checked. To add custom paths, edit the `sqlite_paths` array in `lib/common.sh` function `dump_sqlite_databases()`.
