#!/usr/bin/env bash
set -euo pipefail

# Run OS package updates on every Dokku host (one per terraform workspace).
# Interactive by default; pass --yes to apply without prompting,
# or --dry-run to only list pending packages.
#
# Assumes ~/.ssh/config has a `dokku-<workspace>` alias for each instance
# (see README → SSH access).

YES=false
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --yes|-y) YES=true ;;
    --dry-run|-n) DRY_RUN=true ;;
    -h|--help)
      sed -n '3,7p' "$0" | sed 's/^# \{0,1\}//'
      echo "Usage: $0 [--yes|-y] [--dry-run|-n]"
      exit 0
      ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

workspaces=$(terraform workspace list | tr -d ' *' | grep -vE '^(default)?$')

if [ -z "$workspaces" ]; then
  echo "No terraform workspaces found." >&2
  exit 1
fi

confirm() {
  local prompt="$1"
  local ans
  read -r -p "$prompt [y/N] " ans </dev/tty
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

for ws in $workspaces; do
  host="dokku-${ws}"
  echo ""
  echo "==> ${ws} (${host})"

  if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" "true" 2>/dev/null; then
    echo "    Cannot reach ${host} — skipping."
    continue
  fi

  ssh "$host" "sudo apt-get update -qq" >/dev/null

  pending=$(ssh "$host" "apt list --upgradable 2>/dev/null | tail -n +2")
  count=$(printf '%s' "$pending" | grep -c . || true)

  if [ "$count" -eq 0 ]; then
    echo "    No upgradable packages."
    continue
  fi

  echo "    ${count} package(s) upgradable:"
  printf '%s\n' "$pending" | sed 's/^/      /'

  if ssh "$host" "test -f /var/run/reboot-required" 2>/dev/null; then
    reboot_pending=true
    echo "    (reboot already pending on this host)"
  else
    reboot_pending=false
  fi

  if [ "$DRY_RUN" = true ]; then
    echo "    Dry run — not upgrading."
    continue
  fi

  if [ "$YES" = false ] && ! confirm "    Upgrade ${ws}?"; then
    echo "    Skipped."
    continue
  fi

  echo "    Upgrading..."
  ssh "$host" "sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y && sudo apt-get autoremove -y"

  if [ "$reboot_pending" = true ] || ssh "$host" "test -f /var/run/reboot-required" 2>/dev/null; then
    if [ "$YES" = true ] || confirm "    Reboot required. Reboot ${ws} now?"; then
      echo "    Rebooting..."
      ssh "$host" "sudo reboot" || true
    else
      echo "    Reboot skipped (run manually: ssh ${host} sudo reboot)."
    fi
  else
    echo "    No reboot required."
  fi
done

echo ""
echo "==> Done"
