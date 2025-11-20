# Ansible Deployment Guide

This guide documents requirements and examples for deploying the PBS backup suite via Ansible.

## Server Groups

Define these groups in your inventory based on server type:

```ini
# inventory/hosts.ini

[enhance_cp]
panel.hubseek.com

[enhance_backup]
backup1.hubseek.com
backup2.hubseek.com

[coolify_primary]
coolify.hubseek.com

[coolify_apps]
app1.hubseek.com
app2.hubseek.com

[standard_vps]
mail.hubseek.com
api.hubseek.com

# Parent group for all PBS backup clients
[pbs_clients:children]
enhance_cp
enhance_backup
coolify_primary
coolify_apps
standard_vps
```

## Required Variables

### Group Variables (group_vars/pbs_clients.yml)

```yaml
# PBS Server Connection
pbs_server: "pbs.example.com"
pbs_port: "8007"
pbs_datastore: "backups"
pbs_token_user: "backup@pbs"
pbs_token_name: "backup-token"

# Paths
pbs_backup_install_dir: "/opt/pbs_backup_hubseek"
pbs_keyfile_path: "/root/pbs_encryption_key.json"
pbs_log_dir: "/var/log/pbs-backup"

# Backup settings
backup_skip_lost_and_found: "true"
server_type: "auto"
```

### Vault Variables (group_vars/pbs_clients/vault.yml)

**Encrypt with ansible-vault:**

```yaml
# PBS API token secret
pbs_token_secret: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# Encryption key (JSON content)
pbs_encryption_key: |
  {
    "kdf": "scrypt",
    "created": "2025-01-01T00:00:00Z",
    ...
  }
```

## Role Structure

```
roles/pbs_backup/
├── tasks/
│   └── main.yml
├── templates/
│   ├── pbs.conf.j2
│   └── credentials.conf.j2
├── handlers/
│   └── main.yml
└── defaults/
    └── main.yml
```

## Example Tasks

### tasks/main.yml

```yaml
---
- name: Install Proxmox Backup Client
  block:
    - name: Add Proxmox GPG key
      get_url:
        url: https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg
        dest: /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg
        mode: '0644'

    - name: Add PBS client repository
      apt_repository:
        repo: "deb http://download.proxmox.com/debian/pbs-client bookworm main"
        filename: pbs-client
        state: present

    - name: Install proxmox-backup-client
      apt:
        name: proxmox-backup-client
        state: present
        update_cache: yes

- name: Install jq (required for Enhance restore)
  apt:
    name: jq
    state: present
  when: "'enhance' in group_names"

- name: Clone PBS backup scripts
  git:
    repo: "https://github.com/yourusername/pbs_backup_hubseek.git"
    dest: "{{ pbs_backup_install_dir }}"
    version: main
    force: yes

- name: Set script permissions
  file:
    path: "{{ pbs_backup_install_dir }}/{{ item }}"
    mode: '0755'
  loop:
    - backup/backup-base.sh
    - backup/backup-enhance.sh
    - backup/backup-enhance-cp.sh
    - backup/backup-coolify.sh
    - backup/backup-coolify-apps.sh
    - restore/restore-base.sh
    - restore/restore-enhance.sh
    - restore/restore-enhance-cp.sh
    - restore/restore-coolify.sh
    - restore/restore-coolify-apps.sh

- name: Create config directory
  file:
    path: "{{ pbs_backup_install_dir }}/config"
    state: directory
    mode: '0755'

- name: Deploy PBS configuration
  template:
    src: pbs.conf.j2
    dest: "{{ pbs_backup_install_dir }}/config/pbs.conf"
    mode: '0644'

- name: Deploy credentials configuration
  template:
    src: credentials.conf.j2
    dest: "{{ pbs_backup_install_dir }}/config/credentials.conf"
    mode: '0600'

- name: Deploy encryption key
  copy:
    content: "{{ pbs_encryption_key }}"
    dest: "{{ pbs_keyfile_path }}"
    mode: '0600'

- name: Create log directory
  file:
    path: "{{ pbs_log_dir }}"
    state: directory
    mode: '0755'

- name: Test PBS connection
  command: >
    proxmox-backup-client list
    --repository {{ pbs_token_user }}!{{ pbs_token_name }}@{{ pbs_server }}:{{ pbs_port }}:{{ pbs_datastore }}
  environment:
    PBS_PASSWORD: "{{ pbs_token_secret }}"
  changed_when: false
  register: pbs_test
  failed_when: pbs_test.rc != 0
```

### templates/pbs.conf.j2

```bash
# PBS Backup Configuration
# Managed by Ansible - do not edit manually

# PBS Server Connection
PBS_SERVER="{{ pbs_server }}"
PBS_PORT="{{ pbs_port }}"
PBS_DATASTORE="{{ pbs_datastore }}"

# API Token Authentication
PBS_TOKEN_USER="{{ pbs_token_user }}"
PBS_TOKEN_NAME="{{ pbs_token_name }}"

# Encryption
PBS_KEYFILE="{{ pbs_keyfile_path }}"

# Backup Settings
BACKUP_SKIP_LOST_AND_FOUND="{{ backup_skip_lost_and_found }}"
BACKUP_LOG_DIR="{{ pbs_log_dir }}"

# Server Type Detection
SERVER_TYPE="{{ server_type }}"
```

### templates/credentials.conf.j2

```bash
# PBS Credentials
# Managed by Ansible - do not edit manually

PBS_TOKEN_SECRET="{{ pbs_token_secret }}"
```

## Playbook Examples

### Site Playbook (site.yml)

```yaml
---
- name: Deploy PBS backup to all clients
  hosts: pbs_clients
  become: yes
  roles:
    - pbs_backup
```

### Run with Vault

```bash
# With vault password prompt
ansible-playbook -i inventory/hosts.ini site.yml --ask-vault-pass

# With vault password file
ansible-playbook -i inventory/hosts.ini site.yml --vault-password-file ~/.vault_pass

# Limit to specific group
ansible-playbook -i inventory/hosts.ini site.yml --limit enhance_cp --ask-vault-pass
```

## Script Selection by Group

You may want to set which script each group uses:

### group_vars/enhance_cp.yml
```yaml
backup_script: "backup-enhance-cp.sh"
```

### group_vars/enhance_backup.yml
```yaml
backup_script: "backup-enhance.sh"
```

### group_vars/coolify_primary.yml
```yaml
backup_script: "backup-coolify.sh"
```

### group_vars/coolify_apps.yml
```yaml
backup_script: "backup-coolify-apps.sh"
```

### group_vars/standard_vps.yml
```yaml
backup_script: "backup-base.sh"
```

This variable can be used by Rundeck to know which script to execute on each server.

## Rundeck Integration

### Option 1: Rundeck Key Storage

Store the vault password in Rundeck Key Storage, then:

```bash
# Rundeck job command
ansible-playbook -i inventory/hosts.ini site.yml \
  --vault-password-file <(echo "${RD_OPTION_VAULT_PASSWORD}")
```

### Option 2: Pre-decrypted Variables

Decrypt sensitive vars before Rundeck job runs, store in Rundeck Key Storage:

```bash
# Rundeck job passes variables directly
ansible-playbook -i inventory/hosts.ini site.yml \
  -e "pbs_token_secret=${RD_KEY_PBS_TOKEN_SECRET}"
```

### Backup Job Definition

Rundeck job to run backups:

```yaml
- name: "PBS Backup - {{ inventory_hostname }}"
  command: "{{ pbs_backup_install_dir }}/backup/{{ backup_script }}"
  schedule: "0 3 * * *"  # Adjust per server
```

## Verification Tasks

Add these to verify deployment:

```yaml
- name: Verify backup script exists
  stat:
    path: "{{ pbs_backup_install_dir }}/backup/{{ backup_script }}"
  register: script_check
  failed_when: not script_check.stat.exists

- name: Run backup dry-run
  command: "{{ pbs_backup_install_dir }}/backup/{{ backup_script }} --dry-run"
  register: dry_run
  changed_when: false

- name: Display dry-run output
  debug:
    var: dry_run.stdout_lines
```

## Security Considerations

1. **Vault encryption** - Always encrypt `pbs_token_secret` and `pbs_encryption_key`
2. **File permissions** - credentials.conf must be 0600, encryption key must be 0600
3. **Git ignore** - Never commit actual credentials to the Ansible repo
4. **Vault password** - Store securely (Rundeck Key Storage, password manager, etc.)

## Update Procedure

To update backup scripts on all servers:

```bash
# Pull latest changes and redeploy
ansible-playbook -i inventory/hosts.ini site.yml --tags update --ask-vault-pass
```

Add a tag to the git clone task:

```yaml
- name: Clone PBS backup scripts
  git:
    repo: "https://github.com/yourusername/pbs_backup_hubseek.git"
    dest: "{{ pbs_backup_install_dir }}"
    version: main
    force: yes
  tags:
    - update
```

## Troubleshooting

### "Permission denied" on credentials.conf

Verify mode is 0600:
```bash
ansible all -i inventory/hosts.ini -m file -a "path=/opt/pbs_backup_hubseek/config/credentials.conf mode=0600" --become
```

### PBS connection fails

Test manually on server:
```bash
PBS_PASSWORD="token-secret" proxmox-backup-client list \
  --repository backup@pbs!backup-token@pbs.example.com:8007:backups
```

### Encryption key issues

Verify key file is valid JSON:
```bash
ansible all -i inventory/hosts.ini -m command -a "cat /root/pbs_encryption_key.json | python3 -m json.tool" --become
```
