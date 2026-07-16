#!/bin/bash
# One-time (idempotent) remediation of the rkhunter warnings. Runs as root via systemd.
LOG=/home/mike/foundry-ops/state/rkhfix.log
mkdir -p /home/mike/foundry-ops/state
exec > "$LOG" 2>&1
echo "== rkhunter warning resolution — $(date -u) =="

# ---- 1. set an explicit SSH root-login policy (real fix for the PermitRootLogin warning) ----
if [ -s /root/.ssh/authorized_keys ]; then RL="prohibit-password"; else RL="no"; fi
echo "root authorized_keys present: $([ -s /root/.ssh/authorized_keys ] && echo yes || echo no)  ->  PermitRootLogin $RL"
echo "before: $(sshd -T 2>/dev/null | grep -i '^permitrootlogin')"

cp -n /etc/ssh/sshd_config /etc/ssh/sshd_config.rkhfix.bak
if grep -qiE '^[[:space:]]*PermitRootLogin' /etc/ssh/sshd_config; then
  sed -i -E "s|^[[:space:]]*PermitRootLogin.*|PermitRootLogin $RL|" /etc/ssh/sshd_config
  echo "updated existing PermitRootLogin -> $RL"
else
  printf '\n# hardening (foundry-ops): explicit root SSH policy\nPermitRootLogin %s\n' "$RL" >> /etc/ssh/sshd_config
  echo "appended 'PermitRootLogin $RL' to /etc/ssh/sshd_config"
fi

if sshd -t 2>/tmp/sshderr; then
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  echo "sshd config VALID; reloaded (existing sessions kept)."
  echo "after:  $(sshd -T 2>/dev/null | grep -i '^permitrootlogin')"
else
  echo "!! sshd -t FAILED — restoring backup, NOT reloading:"; cat /tmp/sshderr
  cp /etc/ssh/sshd_config.rkhfix.bak /etc/ssh/sshd_config
fi

# ---- 2. whitelist the confirmed-benign hidden system files ----
LOCAL=/etc/rkhunter.conf.local
touch "$LOCAL"
for line in "ALLOWHIDDENDIR=/etc/.java" "ALLOWHIDDENFILE=/etc/.updated" "ALLOWHIDDENFILE=/etc/.resolv.conf.systemd-resolved.bak"; do
  grep -qxF "$line" "$LOCAL" || echo "$line" >> "$LOCAL"
done
echo "rkhunter.conf.local whitelist:"; grep -E 'ALLOWHIDDEN' "$LOCAL" | sed 's/^/  /'

# ---- 3. refresh baseline (ssh config changed) + re-scan ----
rkhunter --propupd --nocolors >/dev/null 2>&1
rkhunter --check --sk --nocolors --report-warnings-only >/tmp/rkh2.out 2>&1
echo "== rkhunter re-check =="
if grep -qiE 'warning' /tmp/rkh2.out; then grep -iE 'warning' /tmp/rkh2.out | sed 's/^/  /'; else echo "  NO WARNINGS — clean"; fi
echo "final warning count: $(grep -ciE 'warning' /tmp/rkh2.out)"
