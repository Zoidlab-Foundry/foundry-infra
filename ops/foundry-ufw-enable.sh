#!/bin/bash
# Safely enable the ufw host firewall. Runs as root (systemd). Allows SSH first, arms a
# dead-man auto-disable, then enables with default-deny-incoming / allow-outgoing.
# cloudflared is unaffected (outbound tunnel + loopback to apps are always permitted).
LOG=/home/mike/foundry-ops/state/ufw-enable.log
exec > "$LOG" 2>&1
echo "== ufw enable — $(date -u) =="
echo "before: $(ufw status | head -1)"

# dead-man: auto-disable ufw in 5 min unless cancelled (systemctl stop ufw-deadman.timer)
systemctl stop ufw-deadman.timer 2>/dev/null
systemd-run --unit=ufw-deadman --on-active=300 /usr/sbin/ufw --force disable >/dev/null 2>&1
echo "dead-man armed: ufw auto-disables in 5 min unless 'systemctl stop ufw-deadman.timer'"

# allow SSH FIRST — this is what prevents lockout
ufw allow 22/tcp
ufw default deny incoming
ufw default allow outgoing
ufw --force enable

echo "-- status --"
ufw status verbose

# self-guard: if 22 somehow isn't allowed, disable immediately + cancel dead-man
if ufw status | grep -qE '22/tcp[[:space:]]+ALLOW'; then
  echo "OK: SSH (22/tcp) is allowed."
else
  echo "!! 22/tcp NOT allowed after enable — disabling ufw to prevent lockout"
  ufw --force disable
  systemctl stop ufw-deadman.timer 2>/dev/null
fi
