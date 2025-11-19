# Full System Restore Guide

This guide covers restoring an entire VPS from a `root.pxar` backup using Proxmox Backup Server.

## When to Use Full System Restore

- **Complete server failure** - Hardware failure, unrecoverable disk corruption
- **Accidental deletion** - Critical system files or directories deleted
- **Ransomware/compromise** - Need to restore to known good state
- **Migration** - Moving to new VPS provider (same OS)

## Prerequisites

- Access to PBS (Proxmox Backup Server)
- Encryption key file used for backup
- Target system to restore to (rescue mode, live USB, or fresh install)

## Restore Scenarios

### Scenario 1: Restore to Same Server (Rescue Mode)

Boot into rescue mode and mount your target disk:

```bash
# Mount the target disk (adjust device name as needed)
mount /dev/sda1 /mnt

# If using LVM
vgchange -ay
mount /dev/vg0/root /mnt

# Install PBS client in rescue environment (if not available)
apt update && apt install -y proxmox-backup-client
```

Restore the full system:

```bash
proxmox-backup-client restore \
    "host/myserver/2025-01-22T15:19:17Z" \
    root.pxar \
    /mnt \
    --repository "backup@pbs!token@pbs.example.com:8007:datastore" \
    --keyfile /path/to/encryption_key.json
```

Reinstall bootloader if needed:

```bash
# For GRUB
mount --bind /dev /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys
chroot /mnt
grub-install /dev/sda
update-grub
exit

# Unmount and reboot
umount /mnt/dev /mnt/proc /mnt/sys /mnt
reboot
```

### Scenario 2: Restore to New Server

On a fresh Ubuntu installation:

```bash
# Install PBS client
wget https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg
echo "deb http://download.proxmox.com/debian/pbs-client bookworm main" > /etc/apt/sources.list.d/pbs-client.list
apt update && apt install -y proxmox-backup-client

# Restore to temp location first
mkdir /tmp/restore
proxmox-backup-client restore \
    "host/myserver/2025-01-22T15:19:17Z" \
    root.pxar \
    /tmp/restore \
    --repository "backup@pbs!token@pbs.example.com:8007:datastore" \
    --keyfile /path/to/encryption_key.json

# Selectively copy what you need
rsync -av /tmp/restore/etc/ /etc/
rsync -av /tmp/restore/var/www/ /var/www/
rsync -av /tmp/restore/home/ /home/
# etc.
```

### Scenario 3: Selective Restore (Specific Directories)

Restore only specific paths from the full system backup:

```bash
# Restore just /etc
proxmox-backup-client restore \
    "host/myserver/2025-01-22T15:19:17Z" \
    root.pxar \
    /tmp/restore-etc \
    --repository "..." \
    --keyfile "..." \
    --include "etc/**"

# Restore just /var/www
proxmox-backup-client restore \
    "host/myserver/2025-01-22T15:19:17Z" \
    root.pxar \
    /tmp/restore-www \
    --repository "..." \
    --keyfile "..." \
    --include "var/www/**"

# Restore multiple specific paths
proxmox-backup-client restore \
    "host/myserver/2025-01-22T15:19:17Z" \
    root.pxar \
    /tmp/restore \
    --repository "..." \
    --keyfile "..." \
    --include "etc/**" \
    --include "home/**" \
    --include "var/www/**"
```

## Using the PBS Web Interface

You can also browse and restore files via the PBS web UI:

1. Log in to PBS web interface
2. Navigate to **Datastore** → **Content**
3. Find your backup snapshot
4. Click to browse the archive
5. Download individual files or directories

## List Available Snapshots

```bash
# Using our restore script
./restore/restore-base.sh --list

# Or directly with PBS client
proxmox-backup-client snapshot list \
    --repository "backup@pbs!token@pbs.example.com:8007:datastore"
```

## Environment Variables

You can set these to avoid repeating connection details:

```bash
export PBS_REPOSITORY="backup@pbs!token@pbs.example.com:8007:datastore"
export PBS_PASSWORD="your-api-token-secret"

# Then just:
proxmox-backup-client restore \
    "host/myserver/2025-01-22T15:19:17Z" \
    root.pxar \
    /mnt \
    --keyfile /path/to/key.json
```

## Post-Restore Checklist

After restoring a full system:

- [ ] Verify hostname is correct: `hostnamectl`
- [ ] Check network configuration: `ip a`, `/etc/netplan/`
- [ ] Verify services start: `systemctl status`
- [ ] Check disk mounts: `df -h`, `/etc/fstab`
- [ ] Test SSH access
- [ ] Verify application functionality
- [ ] Update DNS if IP changed
- [ ] Check firewall rules: `ufw status` or `iptables -L`

## Troubleshooting

### "No such snapshot"

List available snapshots to find the correct path:
```bash
proxmox-backup-client snapshot list --repository "..."
```

### "Encryption key required"

You must provide the same encryption key used during backup:
```bash
--keyfile /path/to/pbs_encryption_key.json
```

### "Permission denied" during restore

Ensure you're running as root and the destination is writable.

### Restored system won't boot

- Verify bootloader was reinstalled
- Check `/etc/fstab` for correct UUIDs
- Verify kernel and initramfs are present

### Network not working after restore

The new server may have different interface names. Check:
```bash
ip link show
cat /etc/netplan/*.yaml
```

Update network configuration to match new interface names.

## Important Notes

- **Don't restore to running system root** - Boot from rescue/live media first
- **Mind the exclusions** - Our backups exclude `/proc`, `/sys`, `/dev`, `/tmp`, `/run` - these are recreated by the OS
- **UID/GID matching** - If restoring to new server, users may need to be recreated (see `restore-enhance.sh --create-users` for example)
- **Test restores regularly** - Don't wait for disaster to find out your backups work

## Quick Reference

```bash
# List snapshots
proxmox-backup-client snapshot list --repository "USER@HOST:DATASTORE"

# Full restore
proxmox-backup-client restore "SNAPSHOT" root.pxar /mnt --repository "..." --keyfile "..."

# Selective restore
proxmox-backup-client restore "SNAPSHOT" root.pxar /tmp/restore --repository "..." --keyfile "..." --include "path/**"

# Browse archive contents
proxmox-backup-client catalog dump "SNAPSHOT" root.pxar --repository "..."
```
