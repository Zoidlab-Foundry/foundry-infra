#!/bin/bash
# Health-check the zoidberg estate and email a report via Resend. arg1 = trigger label.
TRIGGER="${1:-manual}"
OPS=/home/mike/foundry-ops
STATE="$OPS/state"
mkdir -p "$STATE"
REPORT="$STATE/last-report.txt"
NOW=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
export REPORT_TO="${REPORT_TO:-mike@256kmagic.com}"

# --- update summary from the last update run (if any) ---
UPD_SUMMARY="(no automated update run recorded yet)"
UPD_TS=""
[ -f "$STATE/last-update.env" ] && . "$STATE/last-update.env"

# --- critical services ---
CRIT=(cloudflared docker zoidlab zoidlab-foundry-web mcp-gateway mcp-auth-proxy zoidberg-search \
  zoidlab-builder-api zoidlab-builder-web marketplace-api marketplace-web prompter-api prompter-web \
  memorymaker-api memorymaker-web rag-api rag-web trustgate-api trustgate-web spendguard-api spendguard-web \
  modelbench-api modelbench-web eval-api eval-web \
  visionlab-api visionlab-web visionlab-worker voicelab-api voicelab-web voicelab-worker \
  mcplab-api mcplab-web mcplab-worker swarmlab-api swarmlab-web swarmlab-worker)
svc_down=""; svc_ok=0
for s in "${CRIT[@]}"; do
  if [ "$(systemctl is-active "$s" 2>/dev/null)" = "active" ]; then svc_ok=$((svc_ok+1)); else svc_down="$svc_down $s"; fi
done

# --- docker infra ---
dock=""
for c in foundry-infra-postgres-1 foundry-infra-redis-1 foundry-infra-minio-1; do
  st=$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo missing)
  dock="$dock
  $c: $st"
done

# --- app HTTP health (tier-3 expose /api/health) ---
http=""
for pp in visionlab:8704 voicelab:8705 mcplab:8706 swarmlab:8707; do
  name=${pp%%:*}; port=${pp##*:}
  code=$(curl -s -o /dev/null -m 8 -w "%{http_code}" "http://127.0.0.1:$port/api/health" 2>/dev/null)
  http="$http
  $name /api/health -> ${code:-NO_RESPONSE}"
done
pub=$(curl -s -o /dev/null -m 10 -w "%{http_code}" "https://vision.zoidlab.ai/api/health" 2>/dev/null)

# --- failed units (split masked/benign vs real) ---
mapfile -t failed_arr < <(systemctl list-units --state=failed --no-legend --plain --no-pager 2>/dev/null | awk '{print $1}')
real_failed=""; masked_failed=""
for u in "${failed_arr[@]}"; do
  [ -z "$u" ] && continue
  if [ "$(systemctl show -p LoadState --value "$u" 2>/dev/null)" = "masked" ]; then
    masked_failed="$masked_failed $u"
  else
    real_failed="$real_failed $u"
  fi
done
if [ ${#failed_arr[@]} -eq 0 ]; then failed="none"; else failed="${failed_arr[*]}"; fi

# --- reboot / resources ---
if [ -f /var/run/reboot-required ]; then reboot_state="REBOOT REQUIRED (pending)"; else reboot_state="none required"; fi
disk=$(df -h / | tail -1 | awk '{print $3" used / "$4" free ("$5" used)"}')
mem=$(free -h | awk '/Mem:/{print $3" used / "$7" available of "$2}')
kern=$(uname -r); up=$(uptime -p 2>/dev/null)

# --- verdict (masked units are benign — they don't count against health) ---
verdict="ALL SYSTEMS OK"
probs=""
[ -n "$svc_down" ] && probs="services down:$svc_down"
[ -n "$real_failed" ] && probs="$probs; failed units:$real_failed"
[ "$pub" != "307" ] && [ "$pub" != "200" ] && probs="$probs; public app probe returned $pub"
[ -n "$probs" ] && verdict="NEEDS ATTENTION -$probs"

{
echo "ZOIDBERG OPS REPORT"
echo "==================="
echo "Time:     $NOW"
echo "Trigger:  $TRIGGER"
echo "Kernel:   $kern"
echo "Uptime:   $up"
echo ""
echo "VERDICT:  $verdict"
echo ""
echo "-- System updates --"
echo "$UPD_SUMMARY"
[ -n "$UPD_TS" ] && echo "Last update run: $UPD_TS"
echo "Reboot:   $reboot_state"
echo ""
echo "-- Services: $svc_ok/${#CRIT[@]} critical active --"
[ -n "$svc_down" ] && echo "NOT ACTIVE:$svc_down" || echo "all critical services active"
echo "Failed units: $failed"
[ -n "$masked_failed" ] && echo "  (masked/benign, clears on reboot:$masked_failed)"
echo ""
echo "-- Docker infra --$dock"
echo ""
echo "-- App health (localhost) --$http"
echo "  public vision.zoidlab.ai/api/health -> $pub (307/200 = up + gated)"
echo ""
echo "-- Resources --"
echo "Disk: $disk"
echo "Mem:  $mem"
echo ""
echo "(automated report from zoidberg foundry-ops)"
} > "$REPORT"

SUBJECT="[zoidberg] $TRIGGER ops report — ${verdict%% -*} — $(date -u '+%b %d %H:%M UTC')"
python3 "$OPS/foundry-email.py" "$SUBJECT" "$REPORT"
