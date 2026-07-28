#!/bin/bash
# Post-deploy smoke test for the whole estate — health, authenticated reads, workers, infra.
# Exit 0 = everything passed. Run after any deploy: bash /home/mike/foundry-ops/foundry-smoke.sh
FAIL=0
say() { printf '%-34s %s\n' "$1" "$2"; }

# 1. API health
for e in builder:8200 marketplace:8300 prompter:8400 memorymaker:8500 rag:8600 trustgate:8700 \
         spendguard:8701 modelbench:8702 eval:8703 visionlab:8704 voicelab:8705 mcplab:8706 swarmlab:8707 \
         extractlab:8708 dataforge:8709 insight:8710; do
  a="${e%%:*}"; p="${e##*:}"
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:$p/api/health")
  [ "$c" = "200" ] || { FAIL=1; }
  say "api:$a" "$c"
done

# 2. Web heads (200 public, 307 = SSO gate; anything else fails)
for p in 3100 3200 3300 3400 3500 3600 3700 3701 3702 3703 3704 3705 3706 3707 3708 3709 3710 8090; do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$p/")
  case "$c" in 200|307) ;; *) FAIL=1 ;; esac
  say "web::$p" "$c"
done

# 2b. Public reachability — the localhost checks above pass even if DNS or the Cloudflare
#     tunnel is broken, so prove each canonical hostname resolves and answers from outside.
#     A hostname that is missing from the tunnel or misspelled in docs fails here.
for h in zoidlab.ai foundry.zoidlab.ai builder.zoidlab.ai marketplace.zoidlab.ai \
         prompter.zoidlab.ai memorymaker.zoidlab.ai rag.zoidlab.ai trustgate.zoidlab.ai \
         spendguard.zoidlab.ai modelbench.zoidlab.ai eval.zoidlab.ai vision.zoidlab.ai \
         voice.zoidlab.ai mcplab.zoidlab.ai swarm.zoidlab.ai extractlab.zoidlab.ai \
         dataforge.zoidlab.ai insight.zoidlab.ai; do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://$h/" </dev/null)
  case "$c" in 200|302|307) ;; *) FAIL=1 ;; esac
  say "public:$h" "$c"
done

# 3. Authenticated read per app — a minted Pro session must see data through the full stack
SECRET=$(grep -E '^BUILDER_SESSION_SECRET=' /home/mike/zoidlab-visionlab/backend/.env | cut -d= -f2-)
TOK=$(python3 - "$SECRET" <<'PY'
import sys, json, time, hmac, hashlib, base64
def b64(d): return base64.urlsafe_b64encode(d).rstrip(b"=")
h = b64(json.dumps({"alg":"HS256","typ":"JWT"}).encode()); n = int(time.time())
p = b64(json.dumps({"sub":"smoke-test","email":"smoke@zoidlab.ai","tier":"pro","iat":n,"exp":n+300}).encode())
s = b64(hmac.new(sys.argv[1].encode(), h+b"."+p, hashlib.sha256).digest())
print((h+b"."+p+b"."+s).decode())
PY
)
for e in "marketplace:8300:/api/agents" "trustgate:8700:/api/policies" "modelbench:8702:/api/datasets" \
         "eval:8703:/api/targets" "rag:8600:/api/knowledge-bases" "memorymaker:8500:/api/stores" \
         "prompter:8400:/api/prompts" "spendguard:8701:/api/projects" "builder:8200:/api/workflows" \
         "extractlab:8708:/api/schemas" "dataforge:8709:/api/generators" "insight:8710:/api/datasets"; do
  a=$(echo "$e" | cut -d: -f1); p=$(echo "$e" | cut -d: -f2); path=$(echo "$e" | cut -d: -f3)
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Cookie: zb_session=$TOK" "http://127.0.0.1:$p$path")
  [ "$c" = "200" ] || FAIL=1
  say "auth-read:$a" "$c"
done

# 3b. Assistant endpoints — every app's in-app assistant plus the hub concierge.
#     Builder gates all /api/* behind the session, so it is checked WITH the smoke token.
for e in builder:8200 marketplace:8300 prompter:8400 memorymaker:8500 rag:8600 trustgate:8700          spendguard:8701 modelbench:8702 eval:8703 visionlab:8704 voicelab:8705 mcplab:8706          swarmlab:8707 extractlab:8708 dataforge:8709 insight:8710 hub:3200; do
  a="${e%%:*}"; p="${e##*:}"
  out=$(curl -s --max-time 8 -H "Cookie: zb_session=$TOK" "http://127.0.0.1:$p/api/assistant/health")
  echo "$out" | grep -q '"ok":true' && st="ok" || { st="FAIL"; FAIL=1; }
  say "assistant:$a" "$st"
done

# 4. Workers + infra
for u in visionlab-worker voicelab-worker mcplab-worker swarmlab-worker; do
  s=$(systemctl is-active "$u")
  [ "$s" = "active" ] || FAIL=1
  say "worker:$u" "$s"
done
d=$(docker ps --filter health=healthy --format '{{.Names}}' | grep -c foundry-infra || true)
[ "$d" = "3" ] || FAIL=1
say "docker:foundry-infra healthy" "$d/3"

if [ "$FAIL" = "0" ]; then echo "SMOKE: ALL PASS"; else echo "SMOKE: FAILURES ABOVE"; exit 1; fi
