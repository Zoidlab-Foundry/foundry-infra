#!/bin/bash
# Weekly system update. Runs as root (systemd). arg1: "weekly" (reboot if required) or
# "noreboot" (apply + report, never reboot). Patches, records what changed, then either
# reboots (post-boot verifier emails the report) or emails the report immediately.
set -o pipefail
MODE="${1:-weekly}"
OPS=/home/mike/foundry-ops
STATE="$OPS/state"
mkdir -p "$STATE"
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a         # auto-restart services with updated libs (safe; we reboot anyway)
LOG="$STATE/apt-$(date -u +%Y%m%d-%H%M%S).log"

{
  echo "=== apt update $(date -u) ==="
  apt-get update
  echo "=== apt upgrade ==="
  apt-get -y upgrade
  echo "=== apt autoremove ==="
  apt-get -y --purge autoremove
} >>"$LOG" 2>&1

upgraded=$(grep -c '^Setting up ' "$LOG" 2>/dev/null)
pkgs=$(grep '^Setting up ' "$LOG" 2>/dev/null | awk '{print $3}' | tr '\n' ' ')
[ -z "$pkgs" ] && pkgs="none"
pkgs=$(echo "$pkgs" | cut -c1-900)

cat > "$STATE/last-update.env" <<EOF
UPD_TS="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
UPD_SUMMARY="Applied ${upgraded:-0} package update(s). Packages: ${pkgs}"
EOF

# keep only the last 8 apt logs
ls -1t "$STATE"/apt-*.log 2>/dev/null | tail -n +9 | xargs -r rm -f

if [ "$MODE" != "noreboot" ] && [ -f /var/run/reboot-required ]; then
  echo "post-reboot $(date -u)" > "$STATE/postboot-report.pending"
  /usr/bin/systemctl reboot
else
  /home/mike/foundry-ops/foundry-report.sh "${MODE}-update"
fi
