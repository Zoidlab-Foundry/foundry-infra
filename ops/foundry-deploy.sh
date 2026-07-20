#!/bin/bash
# Git-based deploy for a Foundry app: fetch, checkout a ref, restart, health-gate.
#
#   foundry-deploy.sh <repo-dir-name> [ref] [--web]
#
#   repo-dir-name  e.g. zoidlab-modelbench (a git clone under /home/mike)
#   ref            branch/tag/sha, default origin/main
#   --web          also rebuild the Next.js frontend and restart the web service
#
# Provenance: prints previous and new commit. Rollback = re-run with the old sha.
# Service names follow the estate convention (<app>-api/<app>-web), with the
# builder's zoidlab- prefix and the zoidlab site handled explicitly.
set -e
DIR=$1; REF=${2:-origin/main}; WEB=0
[ "$3" = "--web" ] || [ "$2" = "--web" ] && WEB=1
[ "$2" = "--web" ] && REF=origin/main
cd "/home/mike/$DIR"

app=${DIR#zoidlab-}
case "$DIR" in
  zoidlab)          API=zoidlab; WEBSVC=""; PORT=8090 ;;
  zoidlab-builder)  API=zoidlab-builder-api; WEBSVC=zoidlab-builder-web; PORT=8200 ;;
  zoidlab-foundry)  API=""; WEBSVC=zoidlab-foundry-web; PORT=3200 ;;
  zoidlab-rag-builder) API=rag-api; WEBSVC=rag-web; PORT=8600 ;;
  *)                API=$app-api; WEBSVC=$app-web; PORT="" ;;
esac

OLD=$(git rev-parse --short HEAD 2>/dev/null || echo none)
git fetch -q origin
git checkout -q -f "$REF" -- . 2>/dev/null || { git checkout -q -f "$REF"; }
git reset -q --mixed "$REF" 2>/dev/null || true
NEW=$(git rev-parse --short "$REF")
echo "[$DIR] $OLD -> $NEW"
git log --oneline -1 "$REF" | sed 's/^/  /'

if [ -n "$API" ]; then
  rm -rf backend/__pycache__ 2>/dev/null || true
  sudo systemctl restart "$API.service" 2>/dev/null || systemctl restart "$API.service"
  sleep 3
  if [ -n "$PORT" ]; then
    H=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/api/health" || \
        curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/")
    echo "[$DIR] api health: $H"
    case "$H" in 200|307) ;; *) echo "[$DIR] HEALTH FAILED — rollback: foundry-deploy.sh $DIR $OLD"; exit 1;; esac
  fi
fi

if [ "$WEB" = "1" ] && [ -n "$WEBSVC" ]; then
  FD=frontend; [ -d frontend ] || FD=.
  ( cd "$FD" && npm run build > "/tmp/deploy_build_$DIR.log" 2>&1 ) || { echo "[$DIR] WEB BUILD FAILED"; tail -20 "/tmp/deploy_build_$DIR.log"; exit 1; }
  sudo systemctl restart "$WEBSVC.service" 2>/dev/null || systemctl restart "$WEBSVC.service"
  sleep 3
  echo "[$DIR] web restarted"
fi
echo "[$DIR] DEPLOYED $NEW"
