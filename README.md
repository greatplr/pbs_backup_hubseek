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

## Quick Start

### 1. Prerequisites

- Proxmox Backup Client installed (`proxmox-backup-client`)
- API token created in PBS
- Encryption key file created

### 2. Configuration

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

# Restore specific archive
sudo ./restore/restore-base.sh "host/myserver/2025-01-22T15:19:17Z" etc.pxar /tmp/restore
```

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

- [PBS Backup Examples](docs/reference/pbs-backup-examples.md) - Reference scripts and patterns
- [Server-Specific Guides](docs/) - Guides for different server types (coming soon)

## Security Notes

- Never commit `credentials.conf` or encryption keys
- Store encryption keys in a secure, separate location
- Use minimal permissions for API tokens
- Regularly rotate API tokens

## License

MIT License
