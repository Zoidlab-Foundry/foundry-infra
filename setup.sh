#!/bin/bash
# Provision the shared Foundry infra (Postgres + Redis + MinIO) via Docker.
# Generates secrets into .env (chmod 600) on first run; never prints them.
set -e
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "generating .env with fresh secrets"
  {
    echo "PG_PASSWORD=$(openssl rand -hex 24)"
    echo "REDIS_PASSWORD=$(openssl rand -hex 24)"
    echo "MINIO_ROOT_USER=foundryadmin"
    echo "MINIO_ROOT_PASSWORD=$(openssl rand -hex 24)"
  } > .env
  chmod 600 .env
else
  echo ".env already present — keeping existing secrets"
fi

docker compose up -d
echo "waiting for postgres to be healthy..."
for i in $(seq 1 30); do
  st=$(docker inspect -f '{{.State.Health.Status}}' foundry-infra-postgres-1 2>/dev/null || echo starting)
  [ "$st" = "healthy" ] && break
  sleep 2
done
echo "postgres: $(docker inspect -f '{{.State.Health.Status}}' foundry-infra-postgres-1 2>/dev/null)"
echo "redis:    $(docker inspect -f '{{.State.Health.Status}}' foundry-infra-redis-1 2>/dev/null)"
echo "minio:    $(docker inspect -f '{{.State.Health.Status}}' foundry-infra-minio-1 2>/dev/null)"

# create the object-storage bucket for VisionLab assets (idempotent)
set -a; . ./.env; set +a
docker run --rm --network host --entrypoint sh minio/mc -c \
  "mc alias set fdry http://127.0.0.1:9100 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD >/dev/null 2>&1 && \
   mc mb --ignore-existing fdry/visionlab-assets >/dev/null 2>&1 && echo 'bucket visionlab-assets ready'" || echo "bucket step skipped"

echo "DATABASES:"; docker exec foundry-infra-postgres-1 psql -U foundry -tAc "SELECT datname FROM pg_database WHERE datname IN ('visionlab','voicelab','mcplab','swarmlab') ORDER BY 1;"
echo "INFRA_UP"
