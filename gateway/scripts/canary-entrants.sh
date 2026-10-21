#!/usr/bin/env bash
# The ENTRY CANARY's launcher (GW-CATALOG-OR §The entry canary, gateway/specs/endpoints/catalog.md;
# homelab#2742) — a JAIL verb: read the gateway's OpenRouter catalog, and for every (model, provider)
# cell still `candidate` that selection COULD pin — the view's `pinnable[<this ride's harness>]`, the
# policy floors' verdict (quantization, tool-choice modes, uptime) — launch ONE prober ride pinned to
# that cell through agents/agent-session.sh, CHEAPEST FIRST (the endpoint's output price, then its
# input price, then the model id). A candidate the floors reject is skipped and named in the banner
# with its `floor` reason: a canary on it would buy an `eligible` cell selection never pins (the
# first admission of 2026-10-20 went to deepseek-v4.1-flash@open-inference, fp4 — homelab#2775).
# The gateway is the gate and the judge: it admits a canary only while its budget holds (the
# per-refresh cap, the day's metered spend — a `canary-budget` defer otherwise, which this script
# reports and stops on), pins the ride to exactly that provider with no failover, and flips the cell
# to `eligible` on a clean outcome or `excluded` on a strike. Nothing here decides anything.
#
#   bash gateway/scripts/canary-entrants.sh [--max N] [--model <id>] [--dry-run] < /dev/null
#
#   --dry-run prints the banner and the walk (the cells, in order) and rides nothing. The ride's
#   stdin is /dev/null (a `while read` loop's body must never eat the list it walks — 2026-10-20).
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
HARNESS=opencode  # the ride's harness (the gateway's canary.harness) — the `pinnable` key this walk reads
view=$(curl -fsS "$AGENT_GATEWAY_URL/catalog/openrouter")
echo "== catalog: $(jq -r '"\(.models_count) models, fetched \(.fetched_at // "never"); cells \(.cells | tojson); canary \(.canary | tojson)"' <<<"$view")"
# The candidate cells, one per (model, provider): a provider's service tiers are ONE cell, priced by
# its representative (no service_tier, then the shortest tag — providers.representatives). Split by
# the view's floors verdict for THIS harness: the pinnable ones are the walk, cheapest first; the
# rest are skipped and named with their `floor`.
candidates=$(jq -c --arg only "$ONLY" --arg h "$HARNESS" '
  [ .models | to_entries[] | select($only == "" or .key == $only) | .key as $m
    | (.value.endpoints | map(select(.state == "candidate")) | group_by(.slug)
       | map(sort_by([(.service_tier != null), (.tag | length), .tag]) | .[0]) | .[])
    | {cell: "\($m)@\(.slug)", pinnable: ((.pinnable // {})[$h] // false), floor: ((.floor // {})[$h] // "no verdict"),
       out: (.out_price // 1e9), in: (.in_price // 1e9)} ]' <<<"$view")
cells=$(jq -r 'map(select(.pinnable)) | sort_by([.out, .in, .cell]) | .[] | "\(.cell)"' <<<"$candidates")
walk=$(jq -r 'map(select(.pinnable)) | sort_by([.out, .in, .cell]) | .[] | "\(.cell) (out \(.out) / in \(.in) $/M)"' <<<"$candidates")
skipped=$(jq -r 'map(select(.pinnable | not)) | sort_by(.cell) | .[] | "\(.cell) (\(.floor))"' <<<"$candidates")
echo "== walk (harness $HARNESS, pinnable candidate cells cheapest-first): $(jq -r 'map(select(.pinnable)) | length' <<<"$candidates") of $(jq -r 'length' <<<"$candidates") candidate cells"
[ -z "$walk" ] || while IFS= read -r line; do echo "   $line"; done <<<"$walk"
echo "== skipped (not pinnable for $HARNESS — a canary would buy a cell selection never pins): $(jq -r 'map(select(.pinnable | not)) | length' <<<"$candidates")"
[ -z "$skipped" ] || while IFS= read -r line; do echo "   $line"; done <<<"$skipped"
[ -n "$cells" ] || { echo "== no pinnable candidate cell — nothing to canary"; exit 0; }
n=0
while IFS= read -r cell; do
  [ "$n" -lt "$MAX" ] || { echo "== --max $MAX reached"; break; }
  n=$((n + 1))
  echo "== canary $n/$MAX: $cell"
  if [ "$DRY" = 1 ]; then continue; fi
  # The ride (the scout's canary shape, agents/model-scout.sh scout_canary_ride, minus its model
  # arguments): one trivial closed task that makes the harness call a tool — a headless `opencode run`;
  # agent-session.sh builds the admission with `canary: {model, provider}` from the knob (harness
  # opencode, the gateway's canary.harness) and reports the outcome on exit. A dispatch is the
  # gateway's YES; a `canary-budget` / `canary-not-due` defer is its NO (the router-defer exit, no pod).
  # The ride names NO model: under AGENT_GATEWAY=sessions the gateway owns it (GW-SESSIONS-ADMIT —
  # agent-session.sh's preflight refuses `--model` outright, FU-270), and the pod's provider + model
  # ARE the admission's OPENCODE_CONFIG_CONTENT, so an `opencode run -m openrouter/…` would steer
  # opencode at its unconfigured built-in provider instead of the pinned cell (the 2026-10-20 window
  # rode this exact shape, homelab#2775).
  task="canary-$(printf '%s' "$cell" | tr '/:.@' '----')"
  prompt="Reply with ONLY the first markdown heading text of README.md (no other words)."
  if ! AGENT_GATEWAY_CANARY="$cell" bash agents/agent-session.sh "${CANARY_PROJECT:-homelab}" --harness "$HARNESS" \
       --task "$task" --round 1 \
       --run "opencode run \"$prompt\"" </dev/null 2>&1 | tail -n 5; then
    echo "   ride did not dispatch — the gateway's answer is above"
    if [ "$(curl -fsS "$AGENT_GATEWAY_URL/catalog/openrouter" | jq -r '.canary.exhausted')" = "true" ]; then
      echo "== the canary budget is spent (GatewayCanaryBudgetExhausted) — stopping"; break
    fi
  fi
done <<<"$cells"
echo "== after: $(curl -fsS "$AGENT_GATEWAY_URL/catalog/openrouter" | jq -c '{cells, canary}')"
