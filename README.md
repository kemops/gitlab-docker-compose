# Self-Hosted GitLab on Docker

A production-ready Docker Compose setup for running GitLab Community Edition on a single host. Configured with sensible defaults for small teams or personal use, with all sensitive values externalized to environment variables.

## Features

- GitLab CE with all data persisted to **Docker Named Volumes** (config, repos, logs, backups) to avoid host permission issues.
- Tuned for low-memory hosts (2 Puma workers, Sidekiq concurrency capped, Prometheus disabled)
- Built-in healthcheck against GitLab's `/-/health` endpoint
- 14-day rolling backup retention
- Custom SSH port (2222) to avoid conflicts with the host's SSH
- All host-facing settings (URL, ports, timezone) driven by `.env`

## Requirements

- Docker Engine 20.10+ and Docker Compose v2
- At least **4 GB RAM** free (8 GB recommended)
- ~10 GB free disk space to start

## Quick Start

```bash
# 1. Clone
git clone https://github.com/kemops/gitlab-docker-compose.git
cd gitlab-docker-compose

# 2. Configure
cp .env.example .env
# Edit .env and set GITLAB_EXTERNAL_URL to your server's IP or domain

# 3. Start
docker compose up -d

# 4. Watch it boot (3-5 minutes on first run)
docker compose logs -f gitlab
```

Once `docker compose ps` shows the container as `healthy`, open the URL from `.env` in your browser.

## First Login

GitLab generates a random password for the `root` user on first boot and writes it to `/etc/gitlab/initial_root_password` inside the container.

### Reveal the initial root password

```bash
docker exec -it gitlab grep 'Password:' /etc/gitlab/initial_root_password

```

Or print the full file (includes a warning header):

```bash
docker exec -it gitlab cat /etc/gitlab/initial_root_password

```

Expected output:

```bash
Password: aB3cD4eF5gH6iJ7kL8mN9oP0qR

```

### Sign in

1. Open the URL from `GITLAB_EXTERNAL_URL` in your browser
2. Username: `root`
3. Password: the value above

**Change the password immediately** under *Edit profile → Password*. The file `/etc/gitlab/initial_root_password` is auto-deleted 24 hours after first boot.

### Reset the root password if you missed it

If the file has already been deleted, reset via rake task:

```bash
docker exec -it gitlab gitlab-rake "gitlab:password:reset[root]"

```

You will be prompted for a new password twice.

### Set a fixed initial password (before first boot)

If you'd rather pick the password yourself instead of using the generated one, add this line to the `GITLAB_OMNIBUS_CONFIG` block in `compose.yaml` **before** the first `docker compose up`:

```bash
gitlab_rails['initial_root_password'] = ENV['GITLAB_ROOT_PASSWORD']

```

Then add to `.env`:

```bash
GITLAB_ROOT_PASSWORD=YourStrongPassword123!

```

This only works on the very first boot — once the database is seeded, the value is ignored.

## Configuration

All host-side configuration lives in `.env`:

| Variable | Default | Purpose |
| --- | --- | --- |
| `GITLAB_HOSTNAME` | `gitlab` | Container hostname |
| `GITLAB_EXTERNAL_URL` | `http://localhost:8000` | URL GitLab will generate in clone links, emails, etc. Must include the port. |
| `GITLAB_TIMEZONE` | `Asia/Bangkok` | Timezone for timestamps |
| `GITLAB_HTTP_PORT` | `8000` | Host port for HTTP |
| `GITLAB_HTTPS_PORT` | `8443` | Host port for HTTPS |
| `GITLAB_SSH_PORT` | `2222` | Host port for git+ssh |

For deeper GitLab tuning (SMTP, LDAP, registry, etc.), edit the `GITLAB_OMNIBUS_CONFIG` block in `compose.yaml`.

## Backup & Migration

A full GitLab backup has **two parts**. You need both to restore — losing either one corrupts the result.

| Part | What it contains | Where it lives |
| --- | --- | --- |
| **Application data** | Database, repositories, uploads, CI artifacts, LFS objects | `gitlab-backups` volume (`/var/opt/gitlab/backups/`) |
| **Secrets & config** | Encryption keys for 2FA / CI tokens / integrations, plus `gitlab.rb` | `gitlab-config` volume (`/etc/gitlab/`) |

> **Why both?** The application backup is encrypted with keys from `gitlab-secrets.json`. Restoring data without the matching secrets file means 2FA, CI/CD tokens, webhooks, and integrations all break silently.

### Manual backup

Since we are using Named Volumes, files cannot be copied directly from the host filesystem. Use `docker cp` to extract them from the container:

```bash
# 1. Create the application backup
docker exec -t gitlab gitlab-backup create

# 2. Extract the newest backup and secrets
mkdir -p ./backup-stage
BACKUP_FILE=$(docker exec gitlab bash -c "ls -t /var/opt/gitlab/backups/*_gitlab_backup.tar | head -1" | tr -d '\r')
docker cp gitlab:${BACKUP_FILE} ./backup-stage/
docker cp gitlab:/etc/gitlab/gitlab-secrets.json ./backup-stage/

# 3. Bundle everything into a single tarball
DATE=$(date +%Y%m%d_%H%M%S)
tar -czf gitlab_full_${DATE}.tar.gz -C ./backup-stage .
rm -rf ./backup-stage

# Or backup script
chmod +x scripts/backup.sh
./scripts/backup.sh
```

GitLab keeps 14 days of application backups automatically inside the volume (configured by `backup_keep_time` in `compose.yaml`).

### Automated daily backup

A ready-to-use script lives at [`scripts/backup.sh`](https://www.google.com/search?q=scripts/backup.sh). Install it as a cron job:

```bash
chmod +x scripts/backup.sh
sudo crontab -e
# Add this line — runs every day at 2:00 AM, keeps 14 days of archives
0 2 * * * /absolute/path/to/scripts/backup.sh >> /var/log/gitlab-backup.log 2>&1

```

The script runs the backup inside the container, uses `docker cp` to extract the necessary files, creates a single timestamped tarball in `./archives/`, and prunes archives older than 14 days.

### Restore

The fastest way to restore is to use [`scripts/restore.sh`](https://www.google.com/search?q=scripts/restore.sh) against an archive produced by `backup.sh`:

```bash
# Recover archive files in ./archives/
./scripts/restore.sh

# Restore the newest archive in ./archives/
./scripts/restore.sh --latest

# Or restore a specific archive
./scripts/restore.sh ./archives/gitlab_full_20260515_020000.tar.gz

# Skip the confirmation prompt (use in automation)
./scripts/restore.sh -y --latest

```

The script will:

1. Verify the archive contains both the application tar and `gitlab-secrets.json`
2. Stop `puma` and `sidekiq` inside the container
3. Inject `gitlab-secrets.json` and the backup tarball back into the container using `docker cp`
4. Run `gitlab-backup restore` with the right `BACKUP=` identifier
5. Reconfigure, restart all services, and run `gitlab:check`

The restore prompts for confirmation before overwriting anything — it is a destructive operation.

### Migrate to a new machine

The new machine must run the **same GitLab major version** as the source (or one minor version higher). Check with `docker exec gitlab gitlab-rake gitlab:env:info` before starting.

```bash
# On the OLD machine — produce a single archive
./scripts/backup.sh
ls ./archives/   # note the latest gitlab_full_*.tar.gz

# Transfer the archive and your compose files to the new host
rsync -avz \
    ./archives/gitlab_full_*.tar.gz \
    compose.yaml .env \
    scripts/ \
    user@newhost:/srv/gitlab/

# On the NEW machine
cd /srv/gitlab
docker compose up -d
sleep 60                     # let GitLab finish first-boot reconfigure

# Restore — the script handles secrets, app data, reconfigure, and restart
./scripts/restore.sh --latest

```

If `gitlab:check` finishes without red errors, the migration is good. Update DNS / `GITLAB_EXTERNAL_URL` to point to the new host and you're done.

## Git Workflow

After creating a user and project in the UI:

```bash
# Via HTTPS (use a Personal Access Token as password)
git clone http://<host>:8000/<user>/<project>.git

# Via SSH (add your SSH key in Preferences → SSH Keys first)
git clone ssh://git@<host>:2222/<user>/<project>.git

```

## Project Layout

```
.
├── compose.yaml         # Docker Compose definition (using Named Volumes)
├── .env.example         # Template — copy to .env
├── .env                 # Your actual values (gitignored)
├── .gitignore           # Excludes archives, stage dirs, env files
├── README.md            # This file
├── scripts/
│   ├── backup.sh        # Full backup script (Docker CP method, cron-friendly)
│   └── restore.sh       # Restore script (injects data via Docker CP)
└── archives/            # Tarballs from backup.sh (gitignored)

```

## Troubleshooting

**Container keeps restarting** — first boot is slow. Give it 5 minutes and watch `docker compose logs -f gitlab` for the line `gitlab Reconfigured!`.

**`HTTP Basic: Access denied`** when pushing — GitLab requires a Personal Access Token (Preferences → Access Tokens), not your user password.

**`Permission denied (publickey)`** when pushing — add your `~/.ssh/id_ed25519.pub` to Preferences → SSH Keys.

**Port already in use** — change the host ports in `.env`, then `docker compose up -d --force-recreate`.

**Something is completely broken** — if you need to start over completely fresh, destroy the container and the named volumes:

```bash
docker compose down -v
docker compose up -d

```