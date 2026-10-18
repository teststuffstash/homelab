#!/usr/bin/env bash
# Refresh the tier-evidence snapshot (GW-MODEL-TIERS, specs/endpoints/catalog.md): gathers the three
# inputs from the cluster and the vendor, writes argocd/resources/agent-gateway/benchmarks.json, and
# prints what `apply` would change. The refresh is a reviewable diff — commit the snapshot and the
# re-applied policy.json together (`devbox run tiers -- apply`, then `-- check`).
#
#   kubectl on PATH (from the repo root: `devbox run -- bash gateway/scripts/benchmarks-snapshot.sh`)
#   KUBECONFIG      the cluster (default: tofu/kubeconfig at the repo root)
#   ANTHROPIC_ALIASES  the subscription rail's candidate aliases (ruling 4: the policy's three)
#
# Inputs (each saved beside the output under /tmp for the record of this run):
#   1. the capability rows — the OLD proxy's router store, table `capability` (the AA pull its
#      weekly `_capability_tick` records; the gateway itself never calls AA or the MCP): read in
#      the pod with python3 + sqlite3 over stdin (the pod has no shell tooling to lean on; ROUTER_DB
#      defaults to /data/router.db as in openrouter-proxy.py), JSON on the last line;
#   2. the Go catalog — the gateway's own `GET /catalog/opencode` (the snapshot admission reads),
#      through a port-forward to svc/agent-gateway;
#   3. OpenRouter's public model list — plain curl, unauthenticated.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(cd .. && pwd)
export KUBECONFIG="${KUBECONFIG:-$ROOT/tofu/kubeconfig}"
ALIASES="${ANTHROPIC_ALIASES:-claude/haiku,claude/sonnet,claude/opus}"
OUT="${1:-$ROOT/argocd/resources/agent-gateway/benchmarks.json}"
scratch=$(mktemp -d /tmp/benchmarks-snapshot.XXXXXX)
pf=""
cleanup() { [ -n "$pf" ] && kill "$pf" 2>/dev/null || true; }
trap cleanup EXIT

echo "== 1/3 capability rows from the openrouter-proxy router store"
kubectl -n agent-egress exec -i deploy/openrouter-proxy -- python3 - > "$scratch/cap.out" <<'PY'
import json, os, sqlite3
db = os.environ.get("ROUTER_DB", "/data/router.db")
c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
rows = c.execute("SELECT model, source, intelligence, coding, agentic, updated_ts FROM capability "
                 "WHERE source = 'artificial-analysis' ORDER BY model").fetchall()
print(json.dumps(rows))
PY
tail -n 1 "$scratch/cap.out" > "$scratch/capability.json"
python3 -I -c "import json,sys; print('   %d rows' % len(json.load(open(sys.argv[1]))))" "$scratch/capability.json"

echo "== 2/3 the Go catalog via GET /catalog/opencode (port-forward svc/agent-gateway)"
# an ephemeral local port (`:8080`): a fixed one collided with another forward on the same host
kubectl -n agent-egress port-forward svc/agent-gateway :8080 >"$scratch/pf.log" 2>&1 &
pf=$!
port=""
for _ in $(seq 1 30); do
  port=$(sed -nE 's/^Forwarding from 127\.0\.0\.1:([0-9]+) -> 8080$/\1/p' "$scratch/pf.log" | head -n 1)
  [ -n "$port" ] && curl -fsS -o /dev/null "http://127.0.0.1:$port/healthz" 2>/dev/null && break
  sleep 1
done
[ -n "$port" ] || { echo "port-forward to svc/agent-gateway did not come up:"; cat "$scratch/pf.log"; exit 1; }
curl -fsS "http://127.0.0.1:$port/catalog/opencode" > "$scratch/go-catalog.json"
kill "$pf" 2>/dev/null || true
pf=""
python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); s=d['sources']['config']; print('   plan %s, %s models, fetched %s' % (d['plan'], s['models'], s['fetched_at']))" "$scratch/go-catalog.json"

echo "== 3/3 OpenRouter's public model list"
curl -fsS -o "$scratch/openrouter-models.json" https://openrouter.ai/api/v1/models
fetched_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
python3 -I -c "import json,sys; print('   %d models' % len(json.load(open(sys.argv[1]))['data']))" "$scratch/openrouter-models.json"

echo "== snapshot → $OUT"
devbox run tiers -- snapshot \
  --capability "$scratch/capability.json" --go-catalog "$scratch/go-catalog.json" \
  --openrouter-models "$scratch/openrouter-models.json" --openrouter-fetched-at "$fetched_at" \
  --anthropic-aliases "$ALIASES" -o "$OUT"
echo "== inputs kept under $scratch"
echo "== derivation vs the deployed policy (apply with: devbox run tiers -- apply)"
devbox run tiers -- check --benchmarks "$OUT" || true
