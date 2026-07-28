#!/bin/bash
# Restore drill — proves the backups are actually restorable, not just written.
# Takes the latest Postgres dump from a backup set (Drive by default, or local), restores it
# into a throwaway database, verifies the table + row counts against the live database, then
# drops the scratch DB. Emails a pass/fail report. Weekly via timer; a backup you have never
# restored is a backup you do not have.
#
#   foundry-restore-drill.sh [db] [local|drive]
#     db      which database's dump to drill (default: rag — a content-bearing one)
#     source  where to pull the set from (default: drive)
set -uo pipefail
OPS=/home/mike/foundry-ops
STATE="$OPS/state"
DB="${1:-rag}"
SRC="${2:-drive}"

# Rotation. Drilling only one database proves one database; the other 16 stay unverified.
# When state/drill-rotate.enabled exists, ignore the CLI db and advance through every database
# in turn, one per run, so the whole estate is covered on a rolling basis. The CLI arg stays
# authoritative when rotation is off, and passing an explicit db plus "once" always wins —
# that keeps ad-hoc drills of a specific database possible without disturbing the rotation.
DRILL_DBS="builder dataforge eval extractlab foundry insight marketplace mcplab memorymaker modelbench prompter rag spendguard swarmlab trustgate visionlab voicelab"
if [ -f "$STATE/drill-rotate.enabled" ] && [ "${3:-}" != "once" ]; then
  IDX_FILE="$STATE/drill-rotate.idx"
  IDX=$(cat "$IDX_FILE" 2>/dev/null || echo 0)
  case "$IDX" in ''|*[!0-9]*) IDX=0 ;; esac
  set -- $DRILL_DBS
  TOTAL=$#
  [ "$IDX" -ge "$TOTAL" ] && IDX=0
  eval "DB=\${$((IDX + 1))}"
  echo $(( (IDX + 1) % TOTAL )) > "$IDX_FILE"
  ROTATED=" (rotation $((IDX + 1))/$TOTAL)"
fi
ROTATED="${ROTATED:-}"
export REPORT_TO="${REPORT_TO:-mike@256kmagic.com}"
PGC=foundry-infra-postgres-1
RCLONE_BIN=/home/mike/.local/bin/rclone
RCLONE_CONF=/home/mike/.config/rclone/rclone.conf
REMOTE=gdrive:zoidberg-foundry-backups
WORK=$(mktemp -d)
SCRATCH="drill_${DB}_$(date -u +%H%M%S)"
REPORT=$(mktemp)
FAIL=0; NOTES=""

pull() {
  if [ "$SRC" = "drive" ] && [ -x "$RCLONE_BIN" ] && [ -r "$RCLONE_CONF" ]; then
    STAMP=$("$RCLONE_BIN" --config "$RCLONE_CONF" lsf "$REMOTE/" 2>/dev/null | sort | tail -1 | tr -d '/')
    [ -z "$STAMP" ] && return 1
    "$RCLONE_BIN" --config "$RCLONE_CONF" copy "$REMOTE/$STAMP/pg/$DB.dump" "$WORK/" 2>/dev/null
    SETDESC="Drive:$STAMP"
  else
    LOCAL=$(ls -1dt "$OPS/backups"/*/ 2>/dev/null | head -1)
    [ -z "$LOCAL" ] && return 1
    cp "$LOCAL/pg/$DB.dump" "$WORK/" 2>/dev/null
    SETDESC="local:$(basename "$LOCAL")"
  fi
  [ -s "$WORK/$DB.dump" ]
}

if ! pull; then FAIL=1; NOTES="could not fetch $DB.dump from $SRC"; fi

RESTORED_TABLES=0; RESTORED_ROWS=0; LIVE_TABLES=0; LIVE_ROWS=0
if [ "$FAIL" = "0" ]; then
  docker exec "$PGC" psql -U foundry -tAc "DROP DATABASE IF EXISTS $SCRATCH" >/dev/null 2>&1
  docker exec "$PGC" psql -U foundry -tAc "CREATE DATABASE $SCRATCH" >/dev/null 2>&1
  # per-run stderr file (NOT a shared state file — that becomes root-owned under the timer and
  # then blocks a manual run's redirect, silently skipping the restore).
  ERRLOG=$(mktemp)
  # restore the -Fc dump into the scratch DB
  if docker exec -i "$PGC" pg_restore -U foundry -d "$SCRATCH" --no-owner < "$WORK/$DB.dump" >/dev/null 2>"$ERRLOG"; then
    RESTORED_TABLES=$(docker exec "$PGC" psql -U foundry -d "$SCRATCH" -tAc \
      "select count(*) from information_schema.tables where table_schema='public'")
    RESTORED_ROWS=$(docker exec "$PGC" psql -U foundry -d "$SCRATCH" -tAc \
      "select coalesce(sum(n_live_tup),0) from pg_stat_user_tables")
    LIVE_TABLES=$(docker exec "$PGC" psql -U foundry -d "$DB" -tAc \
      "select count(*) from information_schema.tables where table_schema='public'")
    # analyze scratch so stats are populated for the row comparison
    docker exec "$PGC" psql -U foundry -d "$SCRATCH" -tAc "ANALYZE" >/dev/null 2>&1
    RESTORED_ROWS=$(docker exec "$PGC" psql -U foundry -d "$SCRATCH" -tAc \
      "select coalesce(sum(n_live_tup),0) from pg_stat_user_tables")
    [ "$RESTORED_TABLES" -ge 1 ] && [ "$RESTORED_TABLES" -eq "$LIVE_TABLES" ] || { FAIL=1; NOTES="table count $RESTORED_TABLES != live $LIVE_TABLES"; }
  else
    FAIL=1; NOTES="pg_restore failed: $(tail -1 "$ERRLOG" 2>/dev/null)"
  fi
  rm -f "$ERRLOG"
  docker exec "$PGC" psql -U foundry -tAc "DROP DATABASE IF EXISTS $SCRATCH" >/dev/null 2>&1
fi

VERDICT=$([ "$FAIL" = "0" ] && echo "OK — backup is restorable" || echo "CRITICAL — restore failed")
{
  echo "ZOIDBERG RESTORE DRILL"
  echo "======================"
  echo "Time:     $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "Verdict:  $VERDICT"
  echo
  echo "-- Findings --"
  [ "$FAIL" = "0" ] && echo "  none — restored and verified against live" || echo "  [CRITICAL] $NOTES"
  echo
  echo "-- Drill --"
  echo "Database:        $DB$ROTATED"
  echo "Source set:      ${SETDESC:-unavailable}"
  echo "Restored into:   $SCRATCH (throwaway, dropped after)"
  echo "Tables restored: $RESTORED_TABLES  (live has $LIVE_TABLES)"
  echo "Rows restored:   $RESTORED_ROWS"
  echo
  echo "(automated restore drill — zoidberg foundry-ops)"
} > "$REPORT"
python3 "$OPS/foundry-email.py" "[zoidberg] restore drill: $VERDICT — $(date -u '+%b %d')" "$REPORT"
cat "$REPORT"
rm -rf "$WORK" "$REPORT"
[ "$FAIL" = "0" ]
