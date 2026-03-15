#!/usr/bin/env bash
set -euo pipefail

# Dokku host setup — runs automatically via terraform apply (null_resource),
# or manually: ./setup.sh
#
# Handles:
# - First-time setup (waits for cloud-init, deploys nginx sigil)
# - OAuth toggle (installs/starts or stops oauth2-proxy, swaps nginx sigil)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Read from env vars (set by Terraform local-exec) or fall back to terraform output
SERVER_IP="${TF_SERVER_IP:-$(terraform output -raw server_ip)}"
ENABLE_OAUTH="${TF_ENABLE_OAUTH:-$(terraform output -raw enable_oauth)}"
SSH_HOST="deploy@${SERVER_IP}"

echo "==> Dokku setup (oauth: ${ENABLE_OAUTH}, server: ${SERVER_IP})"

# Wait for SSH to become available (new servers take ~30s)
echo "==> Waiting for SSH..."
for i in $(seq 1 30); do
  ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o BatchMode=yes "$SSH_HOST" "true" 2>/dev/null && break
  echo "    Retry $i..."
  sleep 10
done

# Wait for cloud-init to finish
echo "==> Waiting for cloud-init..."
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$SSH_HOST" \
  "while [ ! -f ~/.cloud-init-complete ]; do sleep 5; done"
echo "==> Cloud-init complete."

if [ "$ENABLE_OAUTH" = "true" ]; then
  echo "==> Enabling OAuth..."

  # Read creds from env vars or terraform output
  GOOGLE_CLIENT_ID="${TF_GOOGLE_CLIENT_ID:-$(terraform output -raw google_client_id)}"
  GOOGLE_CLIENT_SECRET="${TF_GOOGLE_CLIENT_SECRET:-$(terraform output -raw google_client_secret)}"
  EMAIL_DOMAIN="${TF_EMAIL_DOMAIN:-$(terraform output -raw email_domain)}"

  # Install oauth2-proxy binary if missing
  ssh "$SSH_HOST" "which oauth2-proxy > /dev/null 2>&1" || {
    echo "==> Installing oauth2-proxy..."
    ssh "$SSH_HOST" "
      sudo wget -q https://github.com/oauth2-proxy/oauth2-proxy/releases/download/v7.7.1/oauth2-proxy-v7.7.1.linux-amd64.tar.gz -O /tmp/oauth2-proxy.tar.gz &&
      sudo tar xzf /tmp/oauth2-proxy.tar.gz -C /tmp &&
      sudo mv /tmp/oauth2-proxy-v7.7.1.linux-amd64/oauth2-proxy /usr/local/bin/ &&
      sudo chmod +x /usr/local/bin/oauth2-proxy &&
      sudo rm -rf /tmp/oauth2-proxy*
    "
  }

  # Preserve existing cookie secret or generate new one
  COOKIE_SECRET=$(ssh "$SSH_HOST" "sudo grep -oP '(?<=cookie-secret=)\S+' /etc/systemd/system/oauth2-proxy.service 2>/dev/null || echo ''")
  if [ -z "$COOKIE_SECRET" ]; then
    COOKIE_SECRET=$(openssl rand -hex 16)
  fi

  # Create systemd service file
  cat > /tmp/oauth2-proxy.service << EOF
[Unit]
Description=oauth2-proxy
After=network.target

[Service]
ExecStart=/usr/local/bin/oauth2-proxy \\
  --provider=google \\
  --client-id=${GOOGLE_CLIENT_ID} \\
  --client-secret=${GOOGLE_CLIENT_SECRET} \\
  --cookie-secret=${COOKIE_SECRET} \\
  --cookie-secure=true \\
  --cookie-domain=.${EMAIL_DOMAIN} \\
  --email-domain=${EMAIL_DOMAIN} \\
  --http-address=127.0.0.1:4180 \\
  --upstream=static://200 \\
  --reverse-proxy=true \\
  --set-xauthrequest=true
Restart=always
User=deploy

[Install]
WantedBy=multi-user.target
EOF

  scp /tmp/oauth2-proxy.service "${SSH_HOST}:/tmp/oauth2-proxy.service"
  rm /tmp/oauth2-proxy.service
  ssh "$SSH_HOST" "
    sudo mv /tmp/oauth2-proxy.service /etc/systemd/system/oauth2-proxy.service &&
    sudo systemctl daemon-reload &&
    sudo systemctl enable oauth2-proxy &&
    sudo systemctl restart oauth2-proxy
  "

  # Deploy auth sigil
  echo "==> Deploying nginx sigil with auth..."
  scp "${SCRIPT_DIR}/nginx.conf.sigil" "${SSH_HOST}:/tmp/nginx.conf.sigil"

else
  echo "==> Disabling OAuth..."

  # Stop oauth2-proxy if running
  ssh "$SSH_HOST" "sudo systemctl stop oauth2-proxy 2>/dev/null || true"
  ssh "$SSH_HOST" "sudo systemctl disable oauth2-proxy 2>/dev/null || true"

  # Deploy public sigil
  echo "==> Deploying nginx sigil without auth..."
  scp "${SCRIPT_DIR}/nginx.conf.sigil.public" "${SSH_HOST}:/tmp/nginx.conf.sigil"
fi

# Install sigil and rebuild all app configs
ssh "$SSH_HOST" "
  sudo cp /tmp/nginx.conf.sigil /etc/dokku/nginx.conf.sigil &&
  rm /tmp/nginx.conf.sigil &&
  sudo dokku nginx:set --global nginx-conf-sigil-path /etc/dokku/nginx.conf.sigil
"

# Rebuild each app so Dokku picks up the new sigil
for app in $(ssh "$SSH_HOST" "sudo dokku apps:list 2>/dev/null | tail -n +2"); do
  echo "==> Rebuilding ${app}..."
  ssh "$SSH_HOST" "sudo dokku ps:rebuild ${app}" || true
done

# Verify
echo ""
echo "==> Verifying..."
ssh "$SSH_HOST" "dokku version"
if [ "$ENABLE_OAUTH" = "true" ]; then
  ssh "$SSH_HOST" "systemctl status oauth2-proxy --no-pager" || true
fi

# Update notifications via ntfy.sh
NTFY_TOPIC="${TF_NTFY_TOPIC:-}"
NTFY_SCHEDULE="${TF_NTFY_SCHEDULE:-0 3 * * 6}"
if [ -n "$NTFY_TOPIC" ]; then
  echo "==> Setting up update notifications (topic: ${NTFY_TOPIC}, schedule: ${NTFY_SCHEDULE})..."
  ssh "$SSH_HOST" "sudo rm -f /etc/cron.weekly/update-check"
  ssh "$SSH_HOST" "sudo tee /usr/local/bin/update-check > /dev/null << 'SCRIPT'
#!/bin/bash
updates=\$(apt list --upgradable 2>/dev/null | grep -c upgradable || true)
dokku_current=\$(dokku version 2>/dev/null)
if [ \"\$updates\" -gt 0 ]; then
  curl -sf -d \"[\$(hostname)] \$updates packages upgradable. \$dokku_current\" https://ntfy.sh/${NTFY_TOPIC}
fi
SCRIPT
sudo chmod +x /usr/local/bin/update-check"
  ssh "$SSH_HOST" "echo '${NTFY_SCHEDULE} root /usr/local/bin/update-check' | sudo tee /etc/cron.d/update-check > /dev/null"
else
  echo "==> Removing update notifications (no ntfy topic set)..."
  ssh "$SSH_HOST" "sudo rm -f /etc/cron.weekly/update-check /etc/cron.d/update-check /usr/local/bin/update-check"
fi

echo ""
echo "==> Done (oauth: ${ENABLE_OAUTH})"
