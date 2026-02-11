# WZ Backup Manager

A unified Bash script for creating and cleaning up backups of Docker Compose services and system directories. Supports local storage or remote upload via [rclone](https://rclone.org/) (e.g. B2, S3, GCS), with optional Discord notifications and configurable retention policies.

## Features

- **Docker services**: Stops containers, zips data directories (with optional exclusions), uploads or moves backups, restarts containers
- **System directories**: Zips non-Docker paths and uploads or moves them
- **Local or remote**: `BACKUP_TYPE=1` for local-only; `BACKUP_TYPE=2` for rclone upload
- **Retention cleanup**: Daily / weekly / monthly retention; cleanup runs against the rclone remote
- **Parallel backups**: Configurable `MAX_THREADS` for concurrent service backups
- **Service filter**: Backup or target specific services via `--service`
- **Discord**: Optional webhook notifications for backup and cleanup summaries

## Requirements

- **Bash** 4 or newer (for associative arrays; script uses `[[ -v VAR[@] ]]` and `declare -A`)
- **zip**: Creating backup archives
- **Docker** and **Docker Compose**: For Docker-based backup entries (optional if you only use system directories)
- **rclone**: Required when `BACKUP_TYPE=2`; must be configured with at least one remote
- **curl**: Required only if `DISCORD_WEBHOOK_URL` is set
- **GNU coreutils**: Script uses `date -d` for timestamp parsing; intended for Linux (GNU `date`)

### Installing dependencies

**Debian / Ubuntu**

```bash
sudo apt-get update
sudo apt-get install -y bash zip curl
# Docker: https://docs.docker.com/engine/install/
# rclone: https://rclone.org/install/ or: sudo apt-get install -y rclone
```

**Fedora / RHEL**

```bash
sudo dnf install -y bash zip curl
# Install Docker and rclone per official docs
```

**rclone**

- Install from [rclone.org/downloads](https://rclone.org/downloads/) or your package manager.
- Configure remotes: `rclone config` (e.g. B2, S3, GCS). The script validates that the remote name in `REMOTE_BACKUP_DIR` exists.

**Docker Compose**

- Required only for entries in `DOCKER_SERVICES`. Each entry’s main directory should be a directory where `docker compose stop` / `docker compose start` are valid.

## Configuration

1. Copy or edit the config file next to the script:

   ```bash
   # Script and config must live together (script uses its own directory for CONFIG_FILE)
   /path/to/backup-manager.sh
   /path/to/backup-manager.conf
   ```

2. Edit `backup-manager.conf`:

   - **BACKUP_TYPE**: `1` = local only, `2` = rclone upload
   - **BACKUP_DIR**: Local directory for backups (used for local-only or as fallback when upload fails)
   - **REMOTE_BACKUP_DIR**: For rclone, use `remote-name:path` (e.g. `b2:my-bucket/backups`)
   - **DOCKER_SERVICES**: Array of entries: `service-name:main-dir[:extra-dir1:...][|exclude1:exclude2]`
   - **SYSTEM_DIRECTORIES**: Array of entries: `backup-name:/absolute/path`
   - **DISCORD_WEBHOOK_URL**: Optional; leave empty to disable notifications
   - **Retention**: `KEEP_DAILY`, `KEEP_WEEKLY`, `KEEP_MONTHLY` (see config comments)

3. **rclone (when BACKUP_TYPE=2)**  
   Ensure the remote in `REMOTE_BACKUP_DIR` exists (`rclone listremotes`). Create it with `rclone config` if needed. The script checks this at startup and exits with a clear error if the remote is missing.

4. **Discord (optional)**  
   Create a webhook in Discord (Server Settings → Integrations → Webhooks), set `DISCORD_WEBHOOK_URL` in the config. If unset, notifications are skipped.

## Usage

```text
Usage: ./backup-manager.sh [OPTIONS]

Options:
  --backup, -b          Run backup only (default if no options)
  --cleanup, -c         Run cleanup only
  --all, -a             Run backup then cleanup
  --execute, -e         Actually delete files during cleanup (default is dry run)
  --non-interactive, -y No prompts (for cron)
  --service, -s NAME    Limit to service(s), comma-separated
  --help, -h            Show help
```

**Examples**

```bash
# Backup all configured services (default)
./backup-manager.sh

# Backup a single service
./backup-manager.sh --backup --service wz-vaultwarden

# Backup multiple services
./backup-manager.sh --backup --service wz-vaultwarden,wz-authentik

# Cleanup dry run (show what would be deleted)
./backup-manager.sh --cleanup

# Cleanup and actually delete old backups
./backup-manager.sh --cleanup --execute

# Backup then cleanup (cleanup still dry run unless --execute)
./backup-manager.sh --all --execute
```

**Cron**

- Use absolute paths to the script and `--non-interactive` when running from cron.
- Cleanup that deletes files should use `--cleanup --execute --non-interactive`.

Example crontab entries:

```cron
# Backup all services daily at 3 AM
0 3 * * * /path/to/backup-manager.sh --backup --non-interactive

# Backup one service at 2 AM
0 2 * * * /path/to/backup-manager.sh --backup --service wz-vaultwarden --non-interactive

# Cleanup weekly (e.g. Sunday 4 AM)
0 4 * * 0 /path/to/backup-manager.sh --cleanup --execute --non-interactive
```

## Retention policy (cleanup)

Cleanup applies only to the **rclone remote** (`REMOTE_BACKUP_DIR`). It does not delete local files in `BACKUP_DIR`.

- **Daily**: Keep every backup from the last `KEEP_DAILY` days.
- **Weekly**: For backups older than `KEEP_DAILY` and not older than `KEEP_WEEKLY`, keep one backup per week (oldest in that week).
- **Monthly**: For backups older than `KEEP_WEEKLY` and not older than `KEEP_MONTHLY`, keep one backup per month (oldest in that month).
- **Beyond**: Backups older than `KEEP_MONTHLY` are deleted.

Without `--execute`, cleanup is a dry run: it only prints what would be kept or deleted.

## File layout

- `backup-manager.sh` – Main script; must be next to `backup-manager.conf`.
- `backup-manager.conf` – Required; defines backup type, paths, services, retention, and optional Discord webhook.

## License

GPL-3.0 (see [LICENSE](LICENSE)).
