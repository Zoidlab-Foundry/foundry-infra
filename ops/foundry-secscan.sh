#!/bin/bash
# Daily security scan for zoidberg. Runs as root (systemd). Emails a report via Resend.
OPS=/home/mike/foundry-ops
STATE="$OPS/state"
mkdir -p "$STATE"
export REPORT_TO="${REPORT_TO:-mike@256kmagic.com}"
REPORT="$STATE/last-secreport.txt"
NOTES="$STATE/.sec-notes.$$"
: > "$NOTES"
NOW=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
CRIT=0; WARN=0
crit(){ CRIT=$((CRIT+1)); echo "  [CRITICAL] $1" >> "$NOTES"; }
warn(){ WARN=$((WARN+1)); echo "  [warn] $1" >> "$NOTES"; }

# --- 1. pending security updates ---
apt-get update -qq 2>/dev/null
SECU=$(apt-get -s upgrade 2>/dev/null | grep -icE '^Inst .*-security|^Inst .*security\)')
ALLU=$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst ')
SEC_LIST=$(apt-get -s upgrade 2>/dev/null | grep -iE '^Inst .*security' | awk '{print $2}' | tr '\n' ' ' | cut -c1-500)
[ "${SECU:-0}" -gt 0 ] && warn "${SECU} security update(s) pending"

# --- 2. auth activity (last 24h) ---
FAILED24=$(lastb -s -24hours 2>/dev/null | grep -viE '^$|^btmp begins' | wc -l)
TOPIPS=$(lastb -s -24hours 2>/dev/null | awk '{print $3}' | grep -E '^[0-9]+\.' | sort | uniq -c | sort -rn | head -5 | awk '{print $2"("$1")"}' | tr '\n' ' ')
SUCCESS=$(last -s -24hours 2>/dev/null | grep -viE 'reboot|^$|^wtmp begins' | head -6 | awk '{print $1"@"$3}' | tr '\n' ' ')
SESS=$(who 2>/dev/null | awk '{print $1"@"$5}' | tr '\n' ' ')
[ "${FAILED24:-0}" -gt 100 ] && warn "${FAILED24} failed SSH logins in 24h"
[ "${FAILED24:-0}" -gt 1000 ] && crit "very high failed-login volume (${FAILED24}/24h) — likely brute force"

# --- 3. firewall ---
UFW1=$(ufw status 2>/dev/null | head -1)
UFW_ALLOW=$(ufw status 2>/dev/null | grep -i ALLOW | awk '{print $1}' | sort -u | tr '\n' ' ')
echo "$UFW1" | grep -qi inactive && crit "UFW firewall is INACTIVE"

# --- 4. non-loopback listening ports, diff vs baseline ---
CURPORTS=$(ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | grep -vE '127\.0\.0\.1|\[::1\]' | sed -E 's/.*:([0-9]+)$/\1/' | sort -un | tr '\n' ' ')
PB="$STATE/sec-baseline-ports.txt"
if [ ! -f "$PB" ]; then echo "$CURPORTS" > "$PB"; PORT_DIFF="(baseline established: $CURPORTS)"; else
  NEWP=$(comm -13 <(tr ' ' '\n' < "$PB" | sort -u) <(echo "$CURPORTS" | tr ' ' '\n' | sort -u) | grep . | tr '\n' ' ')
  GONE=$(comm -23 <(tr ' ' '\n' < "$PB" | sort -u) <(echo "$CURPORTS" | tr ' ' '\n' | sort -u) | grep . | tr '\n' ' ')
  PORT_DIFF="new: ${NEWP:-none} | removed: ${GONE:-none}"
  [ -n "$NEWP" ] && warn "new non-loopback listening port(s): $NEWP"
  echo "$CURPORTS" > "$PB"
fi

# --- 5. failed systemd units ---
FAILEDU=$(systemctl list-units --state=failed --no-legend --plain --no-pager 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
[ -n "${FAILEDU// /}" ] && warn "failed systemd units: $FAILEDU"

# --- 6. docker containers ---
DCON=$(docker ps --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
DCON_CT=$(docker ps -q 2>/dev/null | wc -l)

# --- 7. rkhunter (rootkits) ---
if [ ! -f "$STATE/.rkhunter-init" ]; then rkhunter --propupd --nocolors >/dev/null 2>&1; touch "$STATE/.rkhunter-init"; fi
rkhunter --check --sk --nocolors --report-warnings-only >/tmp/rkh.out 2>&1
RKW=$(grep -ciE 'warning' /tmp/rkh.out)
RKSUM=$(grep -iE 'warning' /tmp/rkh.out | sed 's/\[.*\]//' | head -6 | tr '\n' ';')
[ "${RKW:-0}" -gt 0 ] && warn "rkhunter: ${RKW} warning(s)"

# --- 8. debsums (package file integrity) ---
DEBS=$(debsums -s 2>/dev/null | wc -l)
DEBSUM=$(debsums -s 2>/dev/null | head -5 | tr '\n' ';')
[ "${DEBS:-0}" -gt 0 ] && warn "debsums: ${DEBS} changed package file(s)"

# --- 9. lynis hardening audit ---
lynis audit system --quick --no-colors --quiet >/dev/null 2>&1
LR=/var/log/lynis-report.dat
HIDX=$(grep -i '^hardening_index=' "$LR" 2>/dev/null | tail -1 | cut -d= -f2)
LWARN=$(grep -c '^warning\[\]=' "$LR" 2>/dev/null)
LSUGG=$(grep -c '^suggestion\[\]=' "$LR" 2>/dev/null)
[ "${LWARN:-0}" -gt 0 ] && warn "lynis: ${LWARN} audit warning(s) (hardening index ${HIDX:-?})"

# --- 10. TLS cert expiry for the apex domain ---
END=$(echo | timeout 12 openssl s_client -servername zoidlab.ai -connect zoidlab.ai:443 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
if [ -n "$END" ]; then
  exp=$(date -d "$END" +%s 2>/dev/null); nows=$(date +%s); LEFT=$(( (exp-nows)/86400 ))
  CERT_INFO="${LEFT} days left (expires $END)"
  [ "$LEFT" -lt 14 ] 2>/dev/null && warn "TLS cert for zoidlab.ai expires in ${LEFT} days"
else CERT_INFO="could not read"; fi

# --- 11. SUID diff vs baseline ---
SB="$STATE/sec-baseline-suid.txt"
CURSUID=$(find /usr /bin /sbin -xdev -perm -4000 -type f 2>/dev/null | sort)
if [ ! -f "$SB" ]; then echo "$CURSUID" > "$SB"; SUID_DIFF="(baseline established, $(echo "$CURSUID"|grep -c .) files)"; else
  NEWS=$(comm -13 "$SB" <(echo "$CURSUID") | tr '\n' ' ')
  SUID_DIFF="${NEWS:-no change}"
  [ -n "${NEWS// /}" ] && crit "NEW SUID binary appeared: $NEWS"
  echo "$CURSUID" > "$SB"
fi

DISK=$(df -h / | tail -1 | awk '{print $5" used, "$4" free"}')
SEV="OK"; [ "$WARN" -gt 0 ] && SEV="WARNINGS ($WARN)"; [ "$CRIT" -gt 0 ] && SEV="CRITICAL ($CRIT)"

{
echo "ZOIDBERG DAILY SECURITY REPORT"
echo "=============================="
echo "Time:     $NOW"
echo "Verdict:  $SEV"
echo ""
echo "-- Findings --"
if [ "$CRIT" -eq 0 ] && [ "$WARN" -eq 0 ]; then echo "  none — clean"; else cat "$NOTES"; fi
echo ""
echo "-- Patch posture --"
echo "Security updates pending: ${SECU:-0}${SEC_LIST:+  [$SEC_LIST]}"
echo "Total updates pending:    ${ALLU:-0}   (weekly auto-update: Sun 04:15 UTC)"
echo ""
echo "-- Auth / access (last 24h) --"
echo "Failed SSH logins: ${FAILED24:-0}"
echo "Top source IPs:    ${TOPIPS:-none}"
echo "Successful logins: ${SUCCESS:-none}"
echo "Current sessions:  ${SESS:-none}"
echo ""
echo "-- Network exposure --"
echo "Firewall (ufw):    ${UFW1}"
echo "  allowed:         ${UFW_ALLOW:-none}"
echo "Non-loopback listeners: $CURPORTS"
echo "  change vs yesterday:  $PORT_DIFF"
echo ""
echo "-- Integrity / malware --"
echo "rkhunter warnings: ${RKW:-0}   ${RKSUM:+[$RKSUM]}"
echo "debsums changed:   ${DEBS:-0}  ${DEBSUM:+[$DEBSUM]}"
echo "SUID binaries:     $SUID_DIFF"
echo ""
echo "-- Hardening (lynis) --"
echo "Hardening index:   ${HIDX:-?}/100"
echo "Warnings / suggestions: ${LWARN:-0} / ${LSUGG:-0}"
echo ""
echo "-- Services / infra --"
echo "Failed units:      ${FAILEDU:-none}"
echo "Docker containers: ${DCON_CT} running (${DCON})"
echo ""
echo "-- Host --"
echo "TLS (zoidlab.ai):  $CERT_INFO"
echo "Disk:              $DISK"
echo ""
echo "(automated daily scan — zoidberg foundry-ops security)"
} > "$REPORT"

rm -f "$NOTES"
python3 "$OPS/foundry-email.py" "[zoidberg] security: $SEV — $(date -u '+%b %d %H:%M UTC')" "$REPORT"
