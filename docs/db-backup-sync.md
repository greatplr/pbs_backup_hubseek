# Database Backup Sync

This script provides frequent database backups to a central storage VPS, complementing the daily PBS backups with more granular point-in-time recovery options.

## Overview

- **Purpose**: Frequent database dumps synced to backup2.hubseek.com
- **Frequency**: Designed for hourly runs (configurable via cron)
- **Retention**: 24 hourly + 7 daily backups by default
- **Compression**: All dumps are gzipped to save space and bandwidth

## When to Use This vs PBS

| Scenario | Use PBS | Use db-backup-sync |
|----------|---------|-------------------|
| Full server disaster recovery | ✅ | |
| "I dropped a table 2 hours ago" | | ✅ |
| Daily backup is enough | ✅ | |
| Need hourly recovery points | | ✅ |
| Restore single database quickly | | ✅ |

**Recommendation**: Use both. PBS for DR, db-backup-sync for granular recovery.

## Prerequisites

1. SSH key access from each server to backup2.hubseek.com as root
2. `/backups/databases` directory on backup2 (script creates subdirectories automatically)

### Setting Up SSH Access

On each server that will run the script:

```bash
# Generate key if needed (as root)
sudo ssh-keygen -t ed25519 -C "db-backup-$(hostname)"

# Copy to backup2
sudo ssh-copy-id root@backup2.hubseek.com

# Test connection
sudo ssh root@backup2.hubseek.com "echo ok"
```

On backup2.hubseek.com:

```bash
# Create the base directory
mkdir -p /backups/databases
```

## Usage

```bash
# Normal run
/opt/pbs_backup_hubseek/backup/db-backup-sync.sh

# Dry run (show what would happen)
/opt/pbs_backup_hubseek/backup/db-backup-sync.sh --dry-run

# Dump only, don't sync (for testing)
/opt/pbs_backup_hubseek/backup/db-backup-sync.sh --skip-sync

# Override destination host
/opt/pbs_backup_hubseek/backup/db-backup-sync.sh --host backup3.example.com
```

## Configuration

Configuration via environment variables (or edit script defaults):

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUP_HOST` | backup2.hubseek.com | Remote backup server |
| `BACKUP_USER` | root | SSH user on remote |
| `BACKUP_BASE_PATH` | /backups/databases | Base path on remote |
| `KEEP_HOURLY` | 24 | Number of hourly backups to retain |
| `KEEP_DAILY` | 7 | Number of daily backups to retain |

## Directory Structure

On backup2.hubseek.com:

```
/backups/databases/
├── app-caddy-01/
│   ├── hourly/
│   │   ├── 2025-11-22_00-00-00/
│   │   │   ├── mysql-all-databases.sql.gz
│   │   │   └── docker-coolify-db-postgres.dump.gz
│   │   ├── 2025-11-22_01-00-00/
│   │   └── ...
│   └── daily/
│       ├── 2025-11-22_00-00-00/
│       └── ...
├── web-server-01/
│   └── ...
└── coolify-01/
    └── ...
```

## Databases Backed Up

### Systemd Services (auto-detected)

| Database | Detection | Dump Format |
|----------|-----------|-------------|
| MySQL/MariaDB | `systemctl is-active mysql/mariadb` | `mysql-all-databases.sql.gz` |
| PostgreSQL | `systemctl is-active postgresql` | `postgresql-all-databases.sql.gz` |

### Docker Containers (auto-detected)

| Database | Detection | Dump Format |
|----------|-----------|-------------|
| PostgreSQL | Image contains "postgres" | `docker-<container>-postgres.dump.gz` |
| MySQL/MariaDB | Image contains "mysql" or "mariadb" | `docker-<container>-mysql.sql.gz` |
| MongoDB | Image contains "mongo" | `docker-<container>-mongo.archive.gz` |

## Scheduling

### Cron (Hourly)

```bash
# Add to root's crontab: sudo crontab -e
0 * * * * /opt/pbs_backup_hubseek/backup/db-backup-sync.sh >> /var/log/pbs-backup/db-sync-cron.log 2>&1
```

### Cron (Every 6 Hours)

```bash
0 */6 * * * /opt/pbs_backup_hubseek/backup/db-backup-sync.sh >> /var/log/pbs-backup/db-sync-cron.log 2>&1
```

### Rundeck

Create a job that runs the script on each server. Stagger start times to avoid overwhelming backup2.

## Restoring from Backup

### List Available Backups

```bash
ssh root@backup2.hubseek.com "ls -la /backups/databases/<hostname>/hourly/"
ssh root@backup2.hubseek.com "ls -la /backups/databases/<hostname>/daily/"
```

### Download a Specific Backup

```bash
# Download entire backup set
scp -r root@backup2.hubseek.com:/backups/databases/app-caddy-01/hourly/2025-11-22_14-00-00/ /tmp/restore/

# Download single file
scp root@backup2.hubseek.com:/backups/databases/app-caddy-01/hourly/2025-11-22_14-00-00/mysql-all-databases.sql.gz /tmp/
```

### Restore MySQL/MariaDB

```bash
# Decompress and restore
gunzip -c /tmp/mysql-all-databases.sql.gz | mysql

# Or restore specific database
gunzip -c /tmp/mysql-all-databases.sql.gz | mysql specific_database
```

### Restore PostgreSQL

```bash
# Decompress and restore
gunzip -c /tmp/postgresql-all-databases.sql.gz | sudo -u postgres psql
```

### Restore Docker PostgreSQL

```bash
# Decompress and restore to container
gunzip -c /tmp/docker-myapp-db-postgres.dump.gz | docker exec -i <container> pg_restore -U postgres -d mydb
```

### Restore Docker MySQL

```bash
gunzip -c /tmp/docker-myapp-db-mysql.sql.gz | docker exec -i <container> mysql -u root -p<password>
```

### Restore Docker MongoDB

```bash
gunzip -c /tmp/docker-myapp-db-mongo.archive.gz | docker exec -i <container> mongorestore --archive
```

## Retention Policy

- **Hourly backups**: Kept for 24 hours (configurable via `KEEP_HOURLY`)
- **Daily backups**: Created at midnight (00:00) or 2am (02:00), kept for 7 days (configurable via `KEEP_DAILY`)
- **Daily snapshots**: Use hard links from hourly, so they don't consume extra space unless hourly is deleted

## Logs

Logs are written to `/var/log/pbs-backup/db-backup-sync-<timestamp>.log`

## Troubleshooting

### SSH Connection Failed

```
Cannot connect to backup2.hubseek.com - check SSH keys
```

Ensure SSH key is set up:
```bash
sudo ssh -v root@backup2.hubseek.com
```

### No Databases Found

```
No databases found to backup
```

The server has no running MySQL, MariaDB, PostgreSQL, or Docker database containers.

### MySQL Dump Failed

Check that `/etc/mysql/debian.cnf` exists or that socket auth is working:
```bash
sudo mysql -e "SELECT 1"
```

### Rsync Failed

Check disk space on backup2:
```bash
ssh root@backup2.hubseek.com "df -h /backups"
```

## Storage Estimates

| Database Size | Compressed Dump | 24 Hourly + 7 Daily |
|---------------|-----------------|---------------------|
| 100 MB | ~20 MB | ~600 MB |
| 1 GB | ~200 MB | ~6 GB |
| 10 GB | ~2 GB | ~60 GB |

Note: Actual compression ratios vary. SQL dumps typically compress 5-10x.
