# ZoidLab Foundry — Operations Runbook

Single-host estate on `zoidberg`. This is the "it broke / rebuild it" reference. For the
architecture, see [ARCHITECTURE.md](ARCHITECTURE.md).

The platform runs on one host by deliberate choice — it is 96% idle, so the risk is
availability, not capacity. This runbook is the resilience answer to single-host: fast,
tested recovery instead of always-on HA.

---

## Automated safety nets (all under `foundry-ops/`, all email `mike@256kmagic.com`)

| Timer | When | Does |
|-------|------|------|
| `foundry-watch` | every 5 min | Health of all 16 APIs + 17 web + 4 workers + infra; emails **only on state change** (up→down / down→up) |
| `foundry-backup` | daily 05:10 UTC | Verified pg/sqlite/MinIO backup → local + **Google Drive** (`gdrive:zoidberg-foundry-backups/`) |
| `foundry-restore-drill` | Sat 06:00 UTC | Restores the latest Drive set into a throwaway DB and verifies — proves backups are recoverable |
| `foundry-secscan` | daily 06:25 UTC | rkhunter/lynis/debsums, auth, ports, TLS |
| `foundry-autoupdate` | Sun 04:15 UTC | apt update/upgrade + conditional reboot + verify |

Manual: `bash foundry-ops/foundry-smoke.sh` (45 checks) · `bash foundry-ops/foundry-restore-drill.sh <db> drive`.

---

## Deploy & rollback

```bash
# deploy an app to origin/main (health-gated + post-deploy smoke gate):
bash /home/mike/foundry-ops/foundry-deploy.sh zoidlab-<app> [--web]
# rollback to a known-good sha (printed on every deploy):
bash /home/mike/foundry-ops/foundry-deploy.sh zoidlab-<app> <old-sha> [--web]
```
The deploy aborts (exit 2) if the estate smoke regresses after restart.

---

## Disaster recovery — rebuild the estate on a fresh host

Recovery time objective: a working estate in well under an hour. The off-site Google Drive
backups are what make this possible; the weekly restore drill is what proves it works.

1. **Base host** — Ubuntu 24.04, install docker + docker compose, create the `mike` user.
2. **Infra** — clone `Zoidlab-Foundry/foundry-infra`, `cd foundry-infra && bash setup.sh`
   (brings up Postgres :5433 + Redis :6380 + MinIO on `foundry_*` volumes) and
   `make_app_role.sh` (the non-superuser `app_rls` role).
3. **rclone** — restore `~/.local/bin/rclone` + `~/.config/rclone/rclone.conf` (600) so the
   host can read the Drive backups. (The config carries the Google OAuth token; treat as a secret.)
4. **Restore data** — pull the latest set and load every database:
   ```bash
   R="$HOME/.local/bin/rclone --config $HOME/.config/rclone/rclone.conf"
   STAMP=$($R lsf gdrive:zoidberg-foundry-backups/ | sort | tail -1 | tr -d /)
   $R copy gdrive:zoidberg-foundry-backups/$STAMP ./restore/ -P
   for d in ./restore/pg/*.dump; do
     db=$(basename "$d" .dump)
     docker exec foundry-infra-postgres-1 psql -U foundry -tAc "CREATE DATABASE $db" 2>/dev/null
     docker exec -i foundry-infra-postgres-1 pg_restore -U foundry -d "$db" --no-owner < "$d"
   done
   # MinIO objects:
   tar -xzf ./restore/minio-data.tar.gz -C /var/lib/docker/volumes/foundry-infra_foundry_minio/_data
   ```
5. **Apps** — for each `zoidlab-*` repo: clone, recreate `backend/.env` (secrets — from your
   password manager / the old host, NOT from git), `python -m venv .venv && pip install -r
   requirements.txt`, `npm install && npm run build`, install the systemd `-api`/`-web` units.
   The `provision_app.sh` pattern in the session notes automates this.
6. **Edge** — restore `cloudflared` + its tunnel credentials + `config.yml` ingress; the
   `*.zoidlab.ai` DNS CNAMEs already point at the tunnel, so no DNS change is needed.
7. **Verify** — `bash foundry-ops/foundry-smoke.sh` must read ALL PASS.

---

## Known-good invariants (what "healthy" looks like)

- `foundry-smoke.sh` → **SMOKE: ALL PASS** (16 API 200, 17 web 200/307, 4 workers active, infra 3/3)
- ufw active, default-deny incoming, only `22/tcp` allowed; no inbound HTTP (tunnel is outbound)
- 17 Postgres DBs, all tenant tables `FORCE ROW LEVEL SECURITY`
- Nightly backup verdict OK with an **Off-site** line confirming the Drive push
