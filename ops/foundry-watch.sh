#!/bin/bash
# Live health watch — runs every 5 minutes. Emails an alert ONLY when a check transitions
# (healthy -> down or down -> healthy), so it never spams. This is the "something just broke"
# signal that closes the gap between a failure and the next morning's daily scan.
# Complements: foundry-secscan (daily posture), foundry-backup (nightly), foundry-report (health).
OPS=/home/mike/foundry-ops
STATE="$OPS/state"
PREV="$STATE/watch-down.txt"
CUR=$(mktemp)
export REPORT_TO="${REPORT_TO:-mike@256kmagic.com}"
mkdir -p "$STATE"; touch "$PREV"

# --- collect current DOWN set ---
for e in builder:8200 marketplace:8300 prompter:8400 memorymaker:8500 rag:8600 trustgate:8700 \
         spendguard:8701 modelbench:8702 eval:8703 visionlab:8704 voicelab:8705 mcplab:8706 \
         swarmlab:8707 extractlab:8708 dataforge:8709 insight:8710; do
  a=${e%%:*}; p=${e##*:}
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "http://127.0.0.1:$p/api/health")
  [ "$code" = "200" ] || echo "api:$a (health $code)" >> "$CUR"
done
for p in 3100 3200 3300 3400 3500 3600 3700 3701 3702 3703 3704 3705 3706 3707 3708 3709 3710 8090; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:$p/")
  case "$code" in 200|307) ;; *) echo "web::$p (head $code)" >> "$CUR";; esac
done
for w in visionlab voicelab mcplab swarmlab; do
  [ "$(systemctl is-active "$w-worker.service" 2>/dev/null)" = "active" ] || echo "worker:$w (down)" >> "$CUR"
done
DH=$(docker ps --filter health=healthy --format '{{.Names}}' 2>/dev/null | grep -c foundry-infra)
[ "$DH" = "3" ] || echo "docker:foundry-infra ($DH/3 healthy)" >> "$CUR"

sort -o "$CUR" "$CUR"

NEWDOWN=$(comm -13 "$PREV" "$CUR")   # now down, wasn't before
RECOVERED=$(comm -23 "$PREV" "$CUR") # was down, now up

if [ -n "$NEWDOWN" ] || [ -n "$RECOVERED" ]; then
  DOWN_N=$(grep -c . "$CUR" || true)
  if [ -n "$NEWDOWN" ]; then SEV="CRITICAL"; else [ "$DOWN_N" = "0" ] && SEV="OK (recovered)" || SEV="WARNINGS"; fi
  REPORT=$(mktemp)
  {
    echo "ZOIDBERG LIVE HEALTH ALERT"
    echo "=========================="
    echo "Time:     $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "Verdict:  $SEV"
    echo
    echo "-- Findings --"
    if [ -n "$NEWDOWN" ]; then echo "$NEWDOWN" | while read -r l; do [ -n "$l" ] && echo "  [CRITICAL] NEW: $l"; done; fi
    if [ -n "$RECOVERED" ]; then echo "$RECOVERED" | while read -r l; do [ -n "$l" ] && echo "  [warn] RECOVERED: $l"; done; fi
    echo
    echo "-- Currently down ($DOWN_N) --"
    if [ "$DOWN_N" = "0" ]; then echo "  none — all checks healthy"; else cat "$CUR" | sed 's/^/  /'; fi
    echo
    echo "(live health watch — zoidberg foundry-ops · every 5 min, alerts on change only)"
  } > "$REPORT"
  python3 "$OPS/foundry-email.py" "[zoidberg] health: $SEV — $(date -u '+%b %d %H:%M UTC')" "$REPORT"
  echo "$(date -u) alert sent: $SEV (newdown=$(echo "$NEWDOWN"|grep -c .) recovered=$(echo "$RECOVERED"|grep -c .))" >> "$STATE/watch.log"
  rm -f "$REPORT"
fi

cp "$CUR" "$PREV"
rm -f "$CUR"
