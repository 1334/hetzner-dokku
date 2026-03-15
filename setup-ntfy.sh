#!/usr/bin/env bash
set -euo pipefail

# Configures update notification cron via ntfy.sh.
# Runs automatically via terraform apply (null_resource), or manually: ./setup-ntfy.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SERVER_IP="${TF_SERVER_IP:-$(terraform output -raw server_ip)}"
NTFY_TOPIC="${TF_NTFY_TOPIC:-}"
NTFY_SCHEDULE="${TF_NTFY_SCHEDULE:-0 3 * * 6}"
SSH_HOST="deploy@${SERVER_IP}"

if [ -n "$NTFY_TOPIC" ]; then
  echo "==> Setting up update notifications (topic: ${NTFY_TOPIC}, schedule: ${NTFY_SCHEDULE})..."
  ssh "$SSH_HOST" "sudo rm -f /etc/cron.weekly/update-check"
  ssh "$SSH_HOST" "sudo tee /usr/local/bin/update-check > /dev/null << 'SCRIPT'
#!/bin/bash
updates=\$(apt list --upgradable 2>/dev/null | grep -c upgradable || true)
dokku_current=\$(dokku version 2>/dev/null)
if [ \"\$updates\" -gt 0 ]; then
  curl -sf -d \"[\$(hostname)] \$updates packages upgradable. \$dokku_current\" ntfy.sh/${NTFY_TOPIC}
fi
SCRIPT
sudo chmod +x /usr/local/bin/update-check"
  ssh "$SSH_HOST" "echo '${NTFY_SCHEDULE} root /usr/local/bin/update-check' | sudo tee /etc/cron.d/update-check > /dev/null"
else
  echo "==> Removing update notifications (no ntfy topic set)..."
  ssh "$SSH_HOST" "sudo rm -f /etc/cron.weekly/update-check /etc/cron.d/update-check /usr/local/bin/update-check"
fi

echo "==> Done (ntfy)"
