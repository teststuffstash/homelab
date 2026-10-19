#!/usr/bin/env bash
# The ENTRY CANARY's launcher (GW-CATALOG-OR §The entry canary, gateway/specs/endpoints/catalog.md;
# homelab#2742) — a JAIL verb: read the gateway's OpenRouter catalog, and for every (model, provider)
# cell still `candidate` launch ONE prober ride pinned to that cell through agents/agent-session.sh.
# The gateway is the gate and the judge: it admits a canary only while its budget holds (the
# per-refresh cap, the day's metered spend — a `canary-budget` defer otherwise, which this script
# reports and stops on), pins the ride to exactly that provider with no failover, and flips the cell
# to `eligible` on a clean outcome or `excluded` on a strike. Nothing here decides anything.
#
#   bash gateway/scripts/canary-entrants.sh [--max N] [--model <id>] [--dry-run]
#
#   AGENT_GATEWAY_URL        the control plane (default: a port-forward this script opens to svc/agent-gateway)
#   AGENT_GATEWAY_CALLER_SA  the dispatcher SA the jail impersonates for the admission (agent-session.sh's
#                            jail-canary rule; default platform-agents/agentstack-loop)
#   CANARY_PROJECT           the project namespace the prober pod runs in (default homelab)
#   KUBECONFIG               the cluster (default tofu/kubeconfig)
#
# ⚑ gap (catalog.md): no in-cluster trigger — a CronWorkflow reading the view would make this on-demand
# leg a schedule; the operator runs it after a refresh lands entrants (GatewayCanaryBudgetExhausted
# says when the cap, not the entrants, is what stops it).
set -euo pipefail
cd "$(dirname "$0")/../.."
export KUBECONFIG="${KUBECONFIG:-$PWD/tofu/kubeconfig}"
MAX=10; ONLY=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --max) MAX="$2"; shift 2;;
    --model) ONLY="$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
pf=""
cleanup() { [ -n "$pf" ] && kill "$pf" 2>/dev/null || true; }
trap cleanup EXIT
if [ -z "${AGENT_GATEWAY_URL:-}" ]; then
  log=$(mktemp); kubectl -n agent-egress port-forward svc/agent-gateway :8080 >"$log" 2>&1 & pf=$!
  port=""
  for _ in $(seq 1 30); do
    port=$(sed -nE 's/^Forwarding from 127\.0\.0\.1:([0-9]+) -> 8080$/\1/p' "$log" | head -n 1)
    [ -n "$port" ] && curl -fsS -o /dev/null "http://127.0.0.1:$port/healthz" 2>/dev/null && break
    sleep 1
  done
  [ -n "$port" ] || { echo "port-forward to svc/agent-gateway did not come up:"; cat "$log"; exit 1; }
  export AGENT_GATEWAY_URL="http://127.0.0.1:$port"
fi
export AGENT_GATEWAY=sessions AGENT_GATEWAY_ROLE=prober
export AGENT_GATEWAY_CALLER_SA="${AGENT_GATEWAY_CALLER_SA:-platform-agents/agentstack-loop}"
view=$(curl -fsS "$AGENT_GATEWAY_URL/catalog/openrouter")
echo "== catalog: $(jq -r '"\(.models_count) models, fetched \(.fetched_at // "never"); cells \(.cells | tojson); canary \(.canary | tojson)"' <<<"$view")"
cells=$(jq -r --arg only "$ONLY" '.models | to_entries[] | select($only == "" or .key == $only) | .key as $m | .value.endpoints[] | select(.state == "candidate") | "\($m)@\(.slug)"' <<<"$view" | sort -u)
[ -n "$cells" ] || { echo "== no candidate cell — nothing to canary"; exit 0; }
n=0
while IFS= read -r cell; do
  [ "$n" -lt "$MAX" ] || { echo "== --max $MAX reached"; break; }
  n=$((n + 1))
  model="${cell%@*}"
  echo "== canary $n/$MAX: $cell"
  if [ "$DRY" = 1 ]; then continue; fi
  # The ride (the scout's canary shape, agents/model-scout.sh scout_canary_ride): one trivial closed
  # task that makes the harness call a tool — a headless `opencode run`; agent-session.sh builds the
  # admission with `canary: {model, provider}` from the knob (harness opencode, the gateway's
  # canary.harness) and reports the outcome on exit. A dispatch is the gateway's YES; a
  # `canary-budget` / `canary-not-due` defer is its NO (the router-defer exit, no pod).
  task="canary-$(printf '%s' "$cell" | tr '/:.@' '----')"
  prompt="Reply with ONLY the first markdown heading text of README.md (no other words)."
  if ! AGENT_GATEWAY_CANARY="$cell" bash agents/agent-session.sh "${CANARY_PROJECT:-homelab}" --harness opencode \
       --model "openrouter/$model" --task "$task" --round 1 \
       --run "opencode run -m \"openrouter/$model\" \"$prompt\"" 2>&1 | tail -n 5; then
    echo "   ride did not dispatch — the gateway's answer is above"
    if [ "$(curl -fsS "$AGENT_GATEWAY_URL/catalog/openrouter" | jq -r '.canary.exhausted')" = "true" ]; then
      echo "== the canary budget is spent (GatewayCanaryBudgetExhausted) — stopping"; break
    fi
  fi
done
echo "== after: $(curl -fsS "$AGENT_GATEWAY_URL/catalog/openrouter" | jq -c '{cells, canary}')"
