#!/bin/bash
# Nightly estate backup for zoidberg — Postgres (pg_dump -Fc), SQLite (online .backup via
# python3), MinIO object data (tar of the docker volume). Every artifact is verified after
# it is written: pg dumps must pass pg_restore --list, sqlite copies must pass PRAGMA
# integrity_check, tars must list. 14-day retention. Emails a report via foundry-email.py.
# Runs as root (systemd oneshot; daily timer 05:10 UTC — after Sunday's 04:15 autoupdate,
# before the 06:25 secscan).
set -u
OPS=/home/mike/foundry-ops
STATE="$OPS/state"
ROOT="$OPS/backups"
STAMP=$(date -u '+%Y%m%d-%H%M%S')
DEST="$ROOT/$STAMP"
REPORT="$STATE/last-backup.txt"
export REPORT_TO="${REPORT_TO:-mike@256kmagic.com}"
RETAIN_DAYS=14
PG_CONTAINER=foundry-infra-postgres-1
MINIO_VOL=/var/lib/docker/volumes/foundry-infra_foundry_minio/_data

mkdir -p "$DEST/pg" "$DEST/sqlite" "$STATE"
FAILS=()
WARNS=()
PG_LINES=()
SQ_LINES=()

# ---------- 1. Postgres: one -Fc dump per database, verified with pg_restore --list ----------
DBS=$(docker exec "$PG_CONTAINER" psql -U foundry -tAc \
      "select datname from pg_database where datistemplate=false and datname<>'postgres' order by 1" 2>/dev/null)
if [ -z "$DBS" ]; then
  FAILS+=("postgres: could not enumerate databases")
else
  for db in $DBS; do
    f="$DEST/pg/$db.dump"
    if docker exec "$PG_CONTAINER" pg_dump -U foundry -Fc "$db" > "$f" 2>>"$STATE/backup-errors.log" \
       && docker exec -i "$PG_CONTAINER" pg_restore --list < "$f" > /dev/null 2>&1; then
      PG_LINES+=("$db: $(du -h "$f" | cut -f1) verified")
    else
      FAILS+=("postgres/$db: dump or verify failed")
      rm -f "$f"
    fi
  done
fi

# ---------- 2. SQLite: online-consistent copy via the sqlite3 backup API ----------
SQLITES=$(find /home/mike/zoidlab-*/backend/data /home/mike/zoidlab/server/data \
          -maxdepth 1 \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) 2>/dev/null)
for src in $SQLITES; do
  name=$(basename "$src")
  dst="$DEST/sqlite/$name"
  if python3 - "$src" "$dst" <<'PYEOF'
import sqlite3, sys
src, dst = sys.argv[1], sys.argv[2]
s = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
d = sqlite3.connect(dst)
s.backup(d)
ok = d.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
s.close(); d.close()
sys.exit(0 if ok else 1)
PYEOF
  then
    SQ_LINES+=("$name: $(du -h "$dst" | cut -f1) integrity ok")
  else
    FAILS+=("sqlite/$name: backup or integrity check failed")
    rm -f "$dst"
  fi
done

# ---------- 3. MinIO: archive the object-store volume ----------
MINIO_LINE="skipped (volume missing)"
if [ -d "$MINIO_VOL" ]; then
  if tar -czf "$DEST/minio-data.tar.gz" -C "$MINIO_VOL" . 2>>"$STATE/backup-errors.log" \
     && tar -tzf "$DEST/minio-data.tar.gz" > /dev/null 2>&1; then
    MINIO_LINE="$(du -h "$DEST/minio-data.tar.gz" | cut -f1) verified"
  else
    FAILS+=("minio: archive or verify failed")
  fi
else
  WARNS+=("minio volume not found at $MINIO_VOL")
fi

# ---------- 4. Manifest with checksums (restore confidence + tamper evidence) ----------
( cd "$DEST" && find . -type f ! -name MANIFEST.sha256 -exec sha256sum {} \; > MANIFEST.sha256 )

# ---------- 5. Retention ----------
PURGED=$(find "$ROOT" -maxdepth 1 -mindepth 1 -type d -mtime +"$RETAIN_DAYS" | wc -l)
find "$ROOT" -maxdepth 1 -mindepth 1 -type d -mtime +"$RETAIN_DAYS" -exec rm -rf {} +

TOTAL=$(du -sh "$DEST" | cut -f1)
SETS=$(find "$ROOT" -maxdepth 1 -mindepth 1 -type d | wc -l)
ALLSZ=$(du -sh "$ROOT" | cut -f1)
FREE=$(df -h /home | awk 'NR==2{print $4}')

if [ ${#FAILS[@]} -gt 0 ]; then VERDICT="CRITICAL (${#FAILS[@]} failed)";
elif [ ${#WARNS[@]} -gt 0 ]; then VERDICT="WARNINGS (${#WARNS[@]})";
else VERDICT="OK"; fi

# ---------- 6. Report ----------
{
  echo "ZOIDBERG NIGHTLY BACKUP REPORT"
  echo "=============================="
  echo "Time:     $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "Verdict:  $VERDICT"
  echo
  echo "-- Findings --"
  if [ ${#FAILS[@]} -eq 0 ] && [ ${#WARNS[@]} -eq 0 ]; then
    echo "  none — all artifacts written and verified"
  else
    for f in ${FAILS[@]+"${FAILS[@]}"}; do echo "  [CRITICAL] $f"; done
    for w in ${WARNS[@]+"${WARNS[@]}"}; do echo "  [warn] $w"; done
  fi
  echo
  echo "-- Postgres (pg_dump -Fc, pg_restore-verified) --"
  for l in ${PG_LINES[@]+"${PG_LINES[@]}"}; do echo "$l"; done
  echo
  echo "-- SQLite (online .backup, integrity-checked) --"
  for l in ${SQ_LINES[@]+"${SQ_LINES[@]}"}; do echo "$l"; done
  echo
  echo "-- Objects --"
  echo "minio data: $MINIO_LINE"
  echo
  echo "-- Storage --"
  echo "This set:        $TOTAL  ($DEST)"
  echo "Sets retained:   $SETS (${RETAIN_DAYS}-day retention, $PURGED purged tonight)"
  echo "All backups:     $ALLSZ"
  echo "Disk free:       $FREE"
  echo
  echo "(automated nightly backup — zoidberg foundry-ops)"
} > "$REPORT"

python3 "$OPS/foundry-email.py" "[zoidberg] backup: $VERDICT — $(date -u '+%b %d %H:%M UTC')" "$REPORT"
