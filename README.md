# Dokku Infrastructure

Terraform + cloud-init provisioning for Dokku hosts on Hetzner Cloud. Supports multiple instances via Terraform workspaces. All apps are behind Google SSO by default.

## What gets provisioned

- **Hetzner VPS** (Ubuntu 24.04, cx23 Helsinki)
- **Dokku** (latest stable) with letsencrypt and postgres plugins
- **oauth2-proxy** (managed by setup.sh) — Google SSO, restricted to your email domain
- **Global nginx template** — `auth_request` enforces SSO on every app
- **Security hardening** — UFW (ports 22/80/443), fail2ban, SSH key-only, unattended upgrades
- **Maintenance** — weekly Docker image cleanup cron, 2GB swap

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

Workspace-aware alias — automatically targets the active Terraform workspace:

```bash
dokku() {
  local ws=$(cd ~/path/to/hetzner-dokku && terraform workspace show)
  ssh "dokku-${ws}" "sudo dokku $*"
}
```

Then:

```bash
dokku apps:list
dokku logs myapp -t
dokku config:set myapp KEY=value
```

## Deploying an app

```bash
# 1. Create the app on the server
dokku apps:create myapp
dokku domains:set myapp myapp.example.com

# 2. Set environment variables
dokku config:set myapp KEY=value SECRET=xxx

# 3. Add git remote and deploy (use the -push host alias)
git remote add dokku dokku@dokku-work-push:myapp
git push dokku main

# 4. Enable SSL (after DNS points to the server)
dokku letsencrypt:enable myapp
```

Dokku auto-detects your stack via buildpacks, or you can add a `Dockerfile` for full control over versions (recommended for Elixir/Phoenix).

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
ssh dokku-work "sudo apt update && sudo apt install dokku"

# Postgres plugin updates
dokku postgres:stop myapp-db
dokku postgres:upgrade myapp-db
dokku postgres:start myapp-db

# Manual Docker cleanup (automatic weekly cron is already set up)
ssh dokku-work "docker system prune -af"
```

### Updating the global nginx template

If you modify `nginx.conf.sigil`, run setup.sh and rebuild each app:

```bash
./setup.sh
# Then for each app:
dokku ps:rebuild myapp
```

### Database backups

```bash
dokku postgres:backup-auth myapp-db AWS_ACCESS_KEY AWS_SECRET_KEY us-east-1
dokku postgres:backup-schedule myapp-db '0 3 * * *' my-backup-bucket
```

## Files

| File | Purpose |
|------|---------|
| `main.tf` | Hetzner VPS + SSH key + null_resource for auto setup |
| `variables.tf` | Input variables (tokens, keys, domain, `enable_oauth`) |
| `outputs.tf` | Server IP, SSH command, OAuth config |
| `cloud-init.yaml` | Server bootstrap: Dokku, plugins, hardening |
| `nginx.conf.sigil` | Global nginx template with SSO auth |
| `nginx.conf.sigil.public` | Default Dokku nginx template without auth (for public apps) |
| `setup.sh` | Deploys nginx template, manages oauth2-proxy install/toggle |
| `envs/*.tfvars` | Per-instance secrets (gitignored) |
| `envs/example.tfvars` | Config template |
