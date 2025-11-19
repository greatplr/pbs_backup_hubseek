# Script Selection Guide

This guide documents which backup scripts to run on each server type.

## Quick Reference

| Server Type | Scripts to Run | Full System? |
|-------------|----------------|--------------|
| Enhance Control Panel | `backup-enhance-cp.sh` | ✅ Yes |
| Enhance Backup Server | `backup-enhance.sh` | ✅ Yes |
| Coolify Primary | `backup-coolify.sh` + `backup-coolify-apps.sh` | ✅ Yes (via apps) |
| Coolify App-Only Server | `backup-coolify-apps.sh` | ✅ Yes |
| Standard VPS (email, etc.) | `backup-base.sh` | ✅ Yes |

## Detailed Breakdown

### Enhance Control Panel

**Script:** `backup-enhance-cp.sh`

**Archives created:**
- `root.pxar` - Full system
- `enhance-cp-db.pxar` - PostgreSQL dumps (orchd, authd)
- `enhance-cp-ssl-certs.pxar` - SSL certificates
- `enhance-cp-ssl-keys.pxar` - SSL private keys
- `enhance-cp-orchd.pxar` - Orchd directory (private keys)
- `enhance-cp-assets.pxar` - Control panel assets

**One script handles everything.**

---

### Enhance Backup Server

**Script:** `backup-enhance.sh`

**Archives created:**
- `root.pxar` - Full system
- `backups.pxar` - /backups directory with UID/GID metadata

**One script handles everything.**

---

### Coolify Primary Server

**Scripts:** `backup-coolify.sh` AND `backup-coolify-apps.sh`

**Why two scripts?**
The Coolify primary server runs both:
1. The Coolify management instance (database, SSH keys, APP_KEY)
2. Deployed applications (containers, volumes, databases)

**backup-coolify.sh creates:**
- `coolify-env.pxar` - .env file with APP_KEY
- `coolify-ssh.pxar` - SSH private keys
- `coolify-db.pxar` - Coolify PostgreSQL dump

**backup-coolify-apps.sh creates:**
- `root.pxar` - Full system
- `coolify-apps.pxar` - All app volumes, bind mounts, database dumps

**Schedule example (stagger by 15-30 minutes):**
```bash
# Coolify instance backup - 3:00 AM
0 3 * * * /opt/pbs_backup_hubseek/backup/backup-coolify.sh

# Coolify apps backup - 3:30 AM
30 3 * * * /opt/pbs_backup_hubseek/backup/backup-coolify-apps.sh
```

---

### Coolify App-Only Server

**Script:** `backup-coolify-apps.sh`

Servers that only run Coolify-deployed applications (not the management instance).

**Archives created:**
- `root.pxar` - Full system
- `coolify-apps.pxar` - All app volumes, bind mounts, database dumps

**One script handles everything.**

---

### Standard VPS

**Script:** `backup-base.sh`

For any server without special requirements: email servers, API servers, standard web apps.

**Archives created:**
- `root.pxar` - Full system

**One script handles everything.**

---

## Rundeck/Cron Configuration

### Recommended Schedule

Stagger backups to avoid overloading PBS:

| Time | Server Type | Script |
|------|-------------|--------|
| 2:00 AM | Standard VPS | `backup-base.sh` |
| 2:30 AM | Enhance Control Panel | `backup-enhance-cp.sh` |
| 3:00 AM | Coolify Primary | `backup-coolify.sh` |
| 3:30 AM | Coolify Primary | `backup-coolify-apps.sh` |
| 4:00 AM | Coolify App Servers | `backup-coolify-apps.sh` |
| 10:00 AM | Enhance Backup Server | `backup-enhance.sh` |

### Cron Examples

```bash
# === Enhance Control Panel ===
30 2 * * * /opt/pbs_backup_hubseek/backup/backup-enhance-cp.sh >> /var/log/pbs-backup/cron.log 2>&1

# === Enhance Backup Server ===
0 10 * * * /opt/pbs_backup_hubseek/backup/backup-enhance.sh >> /var/log/pbs-backup/cron.log 2>&1

# === Coolify Primary (both scripts) ===
0 3 * * * /opt/pbs_backup_hubseek/backup/backup-coolify.sh >> /var/log/pbs-backup/cron.log 2>&1
30 3 * * * /opt/pbs_backup_hubseek/backup/backup-coolify-apps.sh >> /var/log/pbs-backup/cron.log 2>&1

# === Coolify App-Only Server ===
0 4 * * * /opt/pbs_backup_hubseek/backup/backup-coolify-apps.sh >> /var/log/pbs-backup/cron.log 2>&1

# === Standard VPS ===
0 2 * * * /opt/pbs_backup_hubseek/backup/backup-base.sh >> /var/log/pbs-backup/cron.log 2>&1
```

## Ansible Group Mapping

```ini
[enhance_cp]
# Run: backup-enhance-cp.sh
panel.example.com

[enhance_backup]
# Run: backup-enhance.sh
backup.example.com

[coolify_primary]
# Run: backup-coolify.sh + backup-coolify-apps.sh
coolify.example.com

[coolify_apps]
# Run: backup-coolify-apps.sh
app1.example.com
app2.example.com

[standard_vps]
# Run: backup-base.sh
mail.example.com
api.example.com
```

## Multiple Snapshots Per Server

When running multiple scripts on the same server (Coolify Primary), you'll get multiple snapshots in PBS:

```
host/coolify-server/2025-01-22T03:00:00Z  (from backup-coolify.sh)
host/coolify-server/2025-01-22T03:30:00Z  (from backup-coolify-apps.sh)
```

This is expected and correct. Each snapshot contains different archives:
- First snapshot: coolify-env.pxar, coolify-ssh.pxar, coolify-db.pxar
- Second snapshot: root.pxar, coolify-apps.pxar

## Restore Considerations

### Coolify Primary Full Restore

To fully restore a Coolify primary server, you need archives from BOTH snapshots:

1. From `backup-coolify-apps.sh` snapshot:
   - `root.pxar` - Full system
   - `coolify-apps.pxar` - Application data

2. From `backup-coolify.sh` snapshot:
   - `coolify-db.pxar` - Coolify database
   - `coolify-env.pxar` - APP_KEY
   - `coolify-ssh.pxar` - SSH keys

### Why Not Combine Into One Script?

Keeping them separate allows:
- Running just the instance backup more frequently if needed
- Clearer separation of concerns
- Smaller, faster instance-only backups
- Flexibility for different retention policies
