# Dokku Infrastructure

Terraform + cloud-init provisioning for Dokku hosts on Hetzner Cloud. Supports multiple instances via Terraform workspaces. All apps are behind Google SSO by default.

## What gets provisioned

- **Hetzner VPS** (Ubuntu 24.04, cx23 Helsinki)
- **Dokku** (latest stable) with letsencrypt and postgres plugins
- **oauth2-proxy** (managed by setup.sh) — Google SSO, restricted to your email domain
- **Global nginx template** — `auth_request` enforces SSO on every app
- **Security hardening** — UFW (ports 22/80/443), fail2ban, SSH key-only, unattended upgrades
- **Maintenance** — Docker image cleanup cron, 2GB swap, optional update notifications via [ntfy.sh](https://ntfy.sh)

## Prerequisites

- Terraform >= 1.5
- Hetzner Cloud API token
- Google OAuth2 credentials (configured for your domain)
- SSH key pair

## Initial setup

```bash
# 1. Configure secrets
cp envs/example.tfvars envs/myinstance.tfvars
# Fill in: hcloud_token, ssh_public_key, google_client_id, google_client_secret

# 2. Create a workspace and provision
terraform init
terraform workspace new myinstance
terraform apply -var-file=envs/myinstance.tfvars
```

`terraform apply` provisions the server, waits for cloud-init (~8 min), then runs `setup.sh` automatically to deploy the nginx auth template and configure oauth2-proxy.

## Multiple instances

Each Dokku host is a Terraform workspace with its own tfvars file:

```bash
# Create instances
terraform workspace new work
terraform apply -var-file=envs/work.tfvars

terraform workspace new personal
terraform apply -var-file=envs/personal.tfvars

# Switch between them
terraform workspace select work
terraform apply -var-file=envs/work.tfvars
```

Each workspace has independent state — changes to one instance don't affect the other.

**Warning:** Terraform does not check that your `-var-file` matches the active workspace. Running `terraform apply -var-file=envs/work.tfvars` while the `personal` workspace is selected will apply work's config to your personal server.

Each tfvars file includes a `workspace_name` that must match the active workspace — Terraform will warn if they don't match. Make sure to set `workspace_name = "work"` in `envs/work.tfvars`, etc.

## SSH access

Add both admin and git-push entries per instance to `~/.ssh/config`:

```
# Instance: work
Host dokku-work
  HostName <ip-1>
  User deploy
  IdentityFile ~/.ssh/your-key
  IdentitiesOnly yes

Host dokku-work-push
  HostName <ip-1>
  User dokku
  IdentityFile ~/.ssh/your-key
  IdentitiesOnly yes

# Instance: personal
Host dokku-personal
  HostName <ip-2>
  User deploy
  IdentityFile ~/.ssh/your-key-2
  IdentitiesOnly yes

Host dokku-personal-push
  HostName <ip-2>
  User dokku
  IdentityFile ~/.ssh/your-key-2
  IdentitiesOnly yes
```

### Local dokku alias

Add to `~/.zshrc`:

```bash
dokku() {
  ssh "dokku-${DOKKU_HOST:?Set DOKKU_HOST first}" "sudo dokku $*"
}

# Interactive IEx session for Elixir/Phoenix apps
# Usage: dokku-iex <app-name>  (e.g. dokku-iex whats-next)
# Note: `dokku enter` doesn't handle interactive BEAM shells — this uses docker exec directly
dokku-iex() {
  local app="${1:?Usage: dokku-iex <app-name>}"
  local bin="${app//-/_}"
  ssh -t "dokku-${DOKKU_HOST:?Set DOKKU_HOST first}" "sudo docker exec -it ${app}.web.1 /app/bin/${bin} remote"
}
```

Set `DOKKU_HOST` to target an instance:

```bash
export DOKKU_HOST=work
dokku apps:list
dokku logs myapp -t

# Switch instance
export DOKKU_HOST=personal
dokku apps:list
```

## Deploying an app

### Via git push

```bash
# 1. Create the app on the server
dokku apps:create myapp
dokku domains:set myapp myapp.example.com

# 2. Set environment variables
dokku config:set myapp KEY=value SECRET=xxx

# 3. Add git remote and deploy (use the -push host alias)
git remote add dokku dokku-work-push:myapp
git push dokku main

# 4. Enable SSL (after DNS points to the server)
dokku letsencrypt:enable myapp
```

Dokku auto-detects your stack via buildpacks, or you can add a `Dockerfile` for full control over versions (recommended for Elixir/Phoenix).

### Via `git:from-image` (CI/CD)

For apps that build Docker images in CI (e.g. GitHub Actions), deploy from a pre-built image instead of building on the VPS:

```bash
# One-time: authenticate Dokku with the container registry
dokku registry:login ghcr.io USERNAME GITHUB_CLASSIC_PAT
# Requires a GitHub classic PAT with read:packages scope

# Deploy from image
dokku git:from-image myapp ghcr.io/org/myapp:sha
```

Dokku reads `app.json` from the image's `WORKDIR` for deployment tasks (migrations, healthchecks). Make sure to `COPY app.json ./` in your Dockerfile.

Example `app.json` for a Phoenix app:

```json
{
  "scripts": {
    "dokku": {
      "predeploy": "/app/bin/migrate"
    }
  },
  "healthchecks": {
    "web": [
      {
        "type": "startup",
        "name": "web check",
        "path": "/api/health",
        "attempts": 10,
        "wait": 5,
        "timeout": 30
      }
    ]
  }
}
```

Example GitHub Actions deploy step:

```yaml
- name: Deploy to Dokku
  uses: appleboy/ssh-action@v1.2.0
  with:
    host: ${{ secrets.DOKKU_HOST }}
    username: deploy
    key: ${{ secrets.DEPLOY_SSH_KEY }}
    script: |
      sudo dokku git:from-image myapp ghcr.io/org/myapp:${{ github.sha }}
```

## Adding a database

```bash
dokku postgres:create myapp-db
dokku postgres:link myapp-db myapp
# DATABASE_URL is automatically set in the app's environment
```

## SSO / Authentication

All apps are behind Google SSO (restricted to your `email_domain`) by default. This is enforced via a global `nginx.conf.sigil` template that adds `auth_request` directives to every app's nginx config. oauth2-proxy runs as a systemd service on `127.0.0.1:4180`.

The shared cookie domain means logging in to one app authenticates you for all apps on that instance.

### Toggling OAuth on/off

Set `enable_oauth` in your instance's tfvars:

```hcl
enable_oauth = true   # all apps behind Google SSO (default)
enable_oauth = false  # all apps publicly accessible
```

Then `terraform apply -var-file=envs/myinstance.tfvars`. This runs `setup.sh` which installs/starts or stops oauth2-proxy and swaps the nginx template. All apps are rebuilt to pick up the change.

### Making a single app public (while SSO is enabled)

Copy the public nginx template into the app's repo:

```bash
cp nginx.conf.sigil.public /path/to/your-app/nginx.conf.sigil
```

Commit and redeploy. That app bypasses SSO while all others remain protected.

To re-enable SSO for the app, delete `nginx.conf.sigil` from the repo and redeploy.

## Maintenance

```bash
# OS updates
ssh dokku-work "sudo apt update && sudo apt upgrade -y"

# Dokku updates
ssh dokku-work "sudo apt update && sudo apt install -y dokku"

# Postgres plugin updates
dokku postgres:stop myapp-db
dokku postgres:upgrade myapp-db
dokku postgres:start myapp-db

# Manual Docker cleanup (automatic weekly cron is already set up)
ssh dokku-work "docker system prune -af"
```

### Update notifications

Set `ntfy_topic` in your instance's tfvars to get push notifications when OS packages are upgradable:

```hcl
ntfy_topic    = "dokku-work-updates-abc123"  # use a random suffix
ntfy_schedule = "0 3 * * 6"                  # default: Saturday 3am
```

Common schedules: `"0 3 * * 6"` (weekly Saturday), `"0 3 1-7 * 6"` (first Saturday of the month), `"0 9 1 * *"` (monthly 1st), `"0 9 * * *"` (daily).

Subscribe to the topic on your phone via the [ntfy app](https://ntfy.sh) or at `ntfy.sh/your-topic`. Each server should use a separate topic. Notifications are only sent when updates are available.

### Updating the global nginx template

If you modify `nginx.conf.sigil`, run setup.sh and rebuild each app:

```bash
./setup.sh  # rebuilds all apps automatically
```

### Connecting to Postgres with GUI tools

Dokku Postgres runs in a Docker container that's only accessible from the server. Use your GUI tool's SSH tunnel feature to connect.

**1. Get the container's internal IP and password:**

```bash
# Internal IP
ssh dokku-work "docker inspect dokku.postgres.myapp-db --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'"

# Password (from the DSN)
dokku postgres:info myapp-db
# Look for the Dsn line: postgres://postgres:PASSWORD@...:5432/myapp_db
```

**2. Configure your GUI tool (TablePlus, DBeaver, pgAdmin, etc.):**

| Field | Value |
|-------|-------|
| Host | Container internal IP (e.g. `172.17.0.4`) |
| Port | `5432` |
| User | `postgres` |
| Password | From the Dsn above |
| Database | `myapp_db` |
| SSL mode | Preferred |
| **SSH tunnel** | |
| Server | Dokku host IP |
| Port | `22` |
| User | `deploy` |
| Auth | SSH key (your `~/.ssh/config` key for this instance) |

The internal IP can change if the container restarts. Re-run the `docker inspect` command if the connection drops.

### Database backups

```bash
# Configure S3-compatible credentials (e.g. Backblaze B2)
dokku postgres:backup-auth myapp-db AWS_ACCESS_KEY AWS_SECRET_KEY REGION v4 https://ENDPOINT

# Run first backup (sets the bucket name)
dokku postgres:backup myapp-db my-backup-bucket

# Schedule daily backups (bucket reused from above)
# Note: cron expression must be quoted when run via SSH
ssh dokku-work "sudo dokku postgres:backup-schedule myapp-db '0 3 * * *'"
```

## Files

| File | Purpose |
|------|---------|
| `main.tf` | Hetzner VPS + SSH key + null_resources for setup and ntfy |
| `variables.tf` | Input variables (tokens, keys, domain, `enable_oauth`, `ntfy_topic`, `ntfy_schedule`) |
| `outputs.tf` | Server IP, SSH command, OAuth config |
| `cloud-init.yaml` | Server bootstrap: Dokku, plugins, hardening |
| `nginx.conf.sigil` | Global nginx template with SSO auth |
| `nginx.conf.sigil.public` | Default Dokku nginx template without auth (for public apps) |
| `setup.sh` | Deploys nginx template, manages oauth2-proxy install/toggle |
| `setup-ntfy.sh` | Configures update notification cron via ntfy.sh |
| `envs/*.tfvars` | Per-instance secrets (gitignored) |
| `envs/example.tfvars` | Config template |
