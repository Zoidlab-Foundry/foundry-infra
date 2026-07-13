# Foundry Infra

Shared enterprise datastores for the ZoidLab Foundry Tier-3 apps (§3.2 platform stack),
run as Docker containers on zoidberg, all bound to 127.0.0.1.

- **Postgres 16** (`:5433`) — one database per app (visionlab/voicelab/mcplab/swarmlab),
  per-tenant Row-Level Security enforced via a non-superuser `app_rls` role.
- **Redis 7** (`:6380`) — Celery broker + result backend; one DB index per app (0–3).
- **MinIO** (`:9100` API / `:9101` console) — S3 object storage (VisionLab image assets).

## Bring up
```
bash setup.sh          # generates .env with fresh secrets on first run, brings the stack up
bash make_app_role.sh  # creates the RLS-enforced app_rls role + grants
```

Secrets live only in `.env` (git-ignored, chmod 600). Each app reads DATABASE_URL / REDIS_URL /
MINIO_* from its own backend `.env`, derived from these.
