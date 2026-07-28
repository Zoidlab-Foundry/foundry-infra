#!/bin/bash
# One-time privacy purge — destroy backup sets that predate a data scrub.
#
# Context: demo/seed content once referenced a real client business. That was scrubbed from
# source and from the live databases on 2026-07-27, but every backup set taken BEFORE the
# scrub still contains the real name inside its Postgres dumps and SQLite copies. Local sets
# live 14 days and Drive sets 30, so without this they linger for weeks.
#
# Driven by a marker file so it is auditable and idempotent:
#   $STATE/purge-before.txt   contains a backup stamp, e.g. 20260728-032200
# Every set whose stamp sorts BEFORE that value is deleted locally and on Drive. On success
# the marker is renamed to purge-done-<date>.txt so it never runs twice.
#
# Runs as root (invoked from foundry-backup.sh, or by hand with sudo). Backup set directories
# are root-owned, so this genuinely needs root — that is why it is not a plain user script.
set -uo pipefail
OPS=/home/mike/foundry-ops
STATE="$OPS/state"
MARKER="$STATE/purge-before.txt"
RCLONE_BIN=/home/mike/.local/bin/rclone
RCLONE_CONF=/home/mike/.config/rclone/rclone.conf
REMOTE=gdrive:zoidberg-foundry-backups

[ -f "$MARKER" ] || exit 0
CUTOFF=$(tr -d '[:space:]' < "$MARKER")
[ -n "$CUTOFF" ] || { echo "purge: marker empty, refusing"; exit 1; }

echo "privacy purge: removing backup sets older than $CUTOFF"
LOCAL_N=0
for d in "$OPS/backups"/*/; do
  [ -d "$d" ] || continue
  stamp=$(basename "$d")
  # string compare is correct here: stamps are fixed-width YYYYMMDD-HHMMSS
  if [[ "$stamp" < "$CUTOFF" ]]; then
    rm -rf "$d" && LOCAL_N=$((LOCAL_N + 1)) && echo "  local purged: $stamp"
  fi
done

REMOTE_N=0
if [ -x "$RCLONE_BIN" ] && [ -r "$RCLONE_CONF" ]; then
  while read -r stamp; do
    stamp=$(echo "$stamp" | tr -d '/')
    [ -n "$stamp" ] || continue
    if [[ "$stamp" < "$CUTOFF" ]]; then
      if "$RCLONE_BIN" --config "$RCLONE_CONF" purge "$REMOTE/$stamp" 2>/dev/null; then
        REMOTE_N=$((REMOTE_N + 1)); echo "  drive purged: $stamp"
      else
        echo "  drive PURGE FAILED: $stamp"
      fi
    fi
  done < <("$RCLONE_BIN" --config "$RCLONE_CONF" lsf "$REMOTE/" 2>/dev/null)
else
  echo "  drive: rclone/config unavailable — local only, marker RETAINED for a later run"
  echo "privacy purge: local=$LOCAL_N drive=skipped"
  exit 0
fi

mv "$MARKER" "$STATE/purge-done-$(date -u +%Y%m%d).txt"
echo "privacy purge: complete — local=$LOCAL_N drive=$REMOTE_N sets destroyed"
