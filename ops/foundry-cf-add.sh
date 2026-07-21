#!/bin/bash
# Add the ExtractLab / DataForge / Insight ingress rules to the cloudflared tunnel.
# Runs as root (systemd oneshot). Inserts before the http_status:404 catch-all,
# validates, and restarts cloudflared. Idempotent — skips if already present.
set -e
CFG=/etc/cloudflared/config.yml
cp "$CFG" "${CFG}.bak.$(date -u +%Y%m%d%H%M%S)"

if grep -q 'extractlab.zoidlab.ai' "$CFG"; then
  echo "ingress already present — skipping edit"
else
  python3 - "$CFG" <<'PY'
import sys
cfg = sys.argv[1]
block = """  # --- ExtractLab (added 2026-07-21) ---
  - hostname: extractlab.zoidlab.ai
    service: http://localhost:3708
  # --- DataForge (added 2026-07-21) ---
  - hostname: dataforge.zoidlab.ai
    service: http://localhost:3709
  # --- Insight (added 2026-07-21) ---
  - hostname: insight.zoidlab.ai
    service: http://localhost:3710
"""
s = open(cfg).read()
marker = "  - service: http_status:404"
assert marker in s, "catch-all marker not found"
s = s.replace(marker, block + marker, 1)
open(cfg, "w").write(s)
print("ingress rules inserted")
PY
fi

echo "-- validate --"
cloudflared tunnel ingress validate || { echo "VALIDATE FAILED — restoring backup"; cp "$(ls -t ${CFG}.bak.* | head -1)" "$CFG"; exit 1; }
echo "-- restart cloudflared --"
systemctl restart cloudflared
sleep 3
echo "cloudflared: $(systemctl is-active cloudflared)"
