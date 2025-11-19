# PBS Backup Suite - TODO

## Deployment

- [ ] **Ansible deployment playbook**
  - Deploy scripts to `/opt/pbs_backup_hubseek/` on all servers
  - Deploy config files (pbs.conf, credentials.conf)
  - Deploy encryption key
  - Set permissions (600 for credentials, 700 for scripts)
  - Decide: separate playbook or integrate with existing server provisioning

## Rundeck Jobs

- [ ] **Ansible deploy job**
  - Run Ansible playbook to deploy/update scripts on all servers
  - Trigger manually or on git push

- [ ] **Backup jobs (staggered schedule)**
  - Primary Coolify server:
    - 2:00 AM: `backup-coolify.sh`
    - 2:30 AM: `backup-coolify-apps.sh`
  - Secondary servers:
    - 3:00 AM: Server 1 `backup-coolify-apps.sh`
    - 3:30 AM: Server 2 `backup-coolify-apps.sh`
    - (continue staggering by 30 min)
  - Non-Coolify servers:
    - 4:00 AM+: `backup-base.sh`

  - Consider: One job per server or parameterized job with server list?

## Testing

- [ ] **Test restore scenario**
  - Deploy fresh app via Coolify
  - Restore persistent data/database from backup
  - Verify app works with restored data
  - Document the process

- [ ] **Test Coolify instance restore**
  - Restore to new server
  - Verify APP_KEY, SSH keys, database all work
  - Document any gotchas

## Script Updates

- [ ] **Review backup-base.sh for non-Coolify servers**
  - Verify it captures needed directories (/etc, etc.)
  - Test on a non-Coolify server
  - May need server-type specific adjustments

## Future Considerations

- [ ] Alerting on backup failures (Rundeck notifications or separate monitoring)
- [ ] Backup retention policy configuration
- [ ] Automated restore testing (periodic restore to test environment)
