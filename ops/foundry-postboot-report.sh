#!/bin/bash
# Runs on every boot (systemd). Only acts if the weekly updater left a pending flag before
# rebooting: waits for the estate to come back, then emails the post-reboot health report.
OPS=/home/mike/foundry-ops
STATE="$OPS/state"
FLAG="$STATE/postboot-report.pending"
[ -f "$FLAG" ] || exit 0

# wait up to ~4 min for the core stack to settle
for i in $(seq 1 48); do
  a=$(systemctl is-active cloudflared 2>/dev/null)
  b=$(systemctl is-active visionlab-api 2>/dev/null)
  d=$(docker inspect -f '{{.State.Health.Status}}' foundry-infra-postgres-1 2>/dev/null)
  [ "$a" = active ] && [ "$b" = active ] && [ "$d" = healthy ] && break
  sleep 5
done
sleep 10   # let web frontends + workers finish binding

/home/mike/foundry-ops/foundry-report.sh post-reboot
rm -f "$FLAG"
