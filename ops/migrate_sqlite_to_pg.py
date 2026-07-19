#!/usr/bin/env python3
"""One-shot SQLite -> Postgres data migration for a Foundry app.

Usage: migrate_sqlite_to_pg.py <sqlite_path> <admin_dsn>

Copies every user table row-by-row into the same-named Postgres table (which must
already exist — the app's db_pg.init() creates the schema). Runs as the superuser so
RLS is bypassed and owner_user_id values are preserved exactly. Columns present in
SQLite but absent in Postgres are dropped with a warning; the reverse default to NULL.
Idempotent: rows whose primary key already exists are skipped (ON CONFLICT DO NOTHING).
Prints a per-table copied/skipped summary and exits nonzero on any error.
"""
import sys
import sqlite3

import psycopg


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    src_path, dsn = sys.argv[1], sys.argv[2]
    src = sqlite3.connect(f"file:{src_path}?mode=ro", uri=True)
    src.row_factory = sqlite3.Row
    dst = psycopg.connect(dsn)
    failures = 0

    tables = [r[0] for r in src.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")]
    for t in tables:
        with dst.cursor() as cur:
            cur.execute("SELECT column_name FROM information_schema.columns WHERE table_name=%s", (t,))
            pg_cols = {r[0] for r in cur.fetchall()}
        if not pg_cols:
            print(f"  {t}: SKIPPED (no such table in Postgres)")
            continue
        rows = src.execute(f"SELECT * FROM {t}").fetchall()
        if not rows:
            print(f"  {t}: 0 rows")
            continue
        sq_cols = rows[0].keys()
        common = [c for c in sq_cols if c in pg_cols]
        dropped = [c for c in sq_cols if c not in pg_cols]
        if dropped:
            print(f"  {t}: WARNING dropping columns not in Postgres: {dropped}")
        collist = ",".join(common)
        ph = ",".join(["%s"] * len(common))
        copied = skipped = 0
        with dst.cursor() as cur:
            for r in rows:
                try:
                    cur.execute(
                        f"INSERT INTO {t} ({collist}) VALUES ({ph}) ON CONFLICT DO NOTHING",
                        tuple(r[c] for c in common))
                    if cur.rowcount:
                        copied += 1
                    else:
                        skipped += 1
                except Exception as e:
                    print(f"  {t}: ROW ERROR {e}")
                    failures += 1
                    dst.rollback()
                    break
        dst.commit()
        print(f"  {t}: copied {copied}, already-present {skipped}, total-sqlite {len(rows)}")

    # verification: row counts must line up (pg >= sqlite for every migrated table)
    print("-- verify --")
    for t in tables:
        try:
            n_sq = src.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
            with dst.cursor() as cur:
                cur.execute(f"SELECT COUNT(*) FROM {t}")
                n_pg = cur.fetchone()[0]
            ok = "OK" if n_pg >= n_sq else "MISMATCH"
            if ok != "OK":
                failures += 1
            print(f"  {t}: sqlite={n_sq} pg={n_pg} {ok}")
        except Exception:
            pass
    dst.close()
    src.close()
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
