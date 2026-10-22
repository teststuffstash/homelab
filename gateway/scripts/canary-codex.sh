#!/usr/bin/env bash
# The CODEX CANARY — spike step 4 (docs/spikes/codex-subscription-rail.md §Lighting the rail, FU-270):
# ONE prober ride on the codex rail through agents/agent-session.sh under the gateway (/sessions),
# `--harness codex`, a synthetic read-only prompt, a disposable task key. A JAIL verb like
# canary-entrants.sh; run it INSIDE a declared maintenance window (.claude/skills/maintenance-window):
# the ride is the first live use of the operator's ChatGPT subscription through the gateway.
#
#   bash gateway/scripts/canary-codex.sh [--dry-run] [--prompt "<text>"] < /dev/null
#
# The gateway is the gate and the judge: it admits the ride only on fresh account headroom (its own
# usage poll — GW-CODEX-HEADROOM §Poll; `quota-unknown` / `quota-stale` / `quota-limited` defer), on
# a `ready` credential (GW-CODEX-OAUTH) and under the rail's session cap; the pod's agent-codex renders
# the provider block from the pulled env (agent-runtime) and `codex exec --json` rides
# POST /openai/v1/responses (GW-RAIL-CODEX). Nothing here decides anything.
#
# What it prints is the evidence bundle's SUMMARY — never a token, never a body: the rail's headroom
# gauges and poll counter before and after, the launcher's dispatch banner (the gateway's answer), the
# session rows for the task (GW-SESSIONS-TOKEN: a list carries no token), and the request / token
# counters' deltas on rail="codex". The full transcript is the ride pod's /tmp/run.log (the pod name is
# in the banner) and the gateway's log lines `responses rail=codex session=…`.
#
#   AGENT_GATEWAY_URL        the control plane (default: a port-forward this script opens to svc/agent-gateway)
#   AGENT_GATEWAY_CALLER_SA  the dispatcher SA the jail impersonates (default platform-agents/agentstack-loop —
#                            the deployed caller whose roles include `prober`)
#   CANARY_PROJECT           the project namespace the prober pod runs in (default homelab)
#   KUBECONFIG               the cluster (default tofu/kubeconfig)
set -euo pipefail
cd "$(dirname "$0")/../.."
export KUBECONFIG="${KUBECONFIG:-$PWD/tofu/kubeconfig}"
DRY=0
PROMPT="Reply with ONLY the first markdown heading text of README.md (no other words)."
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift;;
    --prompt) PROMPT="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
case "$PROMPT" in *\"*|*\\*|*$'\n'*) echo "the prompt must carry no double quote, backslash or newline (it rides inside the pod's run command)" >&2; exit 2;; esac
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
PROJECT="${CANARY_PROJECT:-homelab}"

codex_series() {  # the rail's state as the gateway renders it — gauges, the poll counter, the request/token counters
  curl -fsS "$AGENT_GATEWAY_URL/metrics" | grep -E '^gateway_(subscription_utilization|subscription_reset_seconds|codex_usage_poll_total|requests_total|tokens_total|upstream_auth_rejected_total)\{[^}]*rail="codex"|^gateway_codex_usage_poll_total' || true
}
echo "== codex rail before the ride ($(date -u +%FT%TZ))"
before="$(codex_series)"; printf '%s\n' "$before" | sed 's/^/   /'
if ! printf '%s' "$before" | grep -q 'gateway_codex_usage_poll_total{outcome="accepted"} [1-9]'; then
  echo "   NOTE: no accepted usage poll yet — the gateway will defer quota-unknown / quota-stale; a dispatch means the poll caught up."
fi
task="canary-codex-$(date -u +%Y%m%dT%H%M%SZ)"
echo "== the ride: project=${PROJECT} role=prober harness=codex task=${task} caller=${AGENT_GATEWAY_CALLER_SA}"
echo "   prompt: ${PROMPT}"
if [ "$DRY" = 1 ]; then echo "== dry run — nothing dispatched"; exit 0; fi
# The ride names NO model (the gateway owns it under /sessions); the pod's agent-codex renders the
# provider block from the pulled env and runs `codex exec --json` — the pod is the sandbox.
rc=0
bash agents/agent-session.sh "$PROJECT" --harness codex --task "$task" --round 1 \
  --run "agent-codex --dangerously-bypass-approvals-and-sandbox \"$PROMPT\"" </dev/null 2>&1 | tail -n 40 || rc=$?
echo "== launcher exit: ${rc} (0 = the pod ran to its finalize; a router-defer exit = the gateway's NO, its reason is above)"
echo "== the session rows for task=${task} (no token in a list — GW-SESSIONS-TOKEN)"
curl -fsS "$AGENT_GATEWAY_URL/sessions?task=${task}" | jq . 2>/dev/null | sed 's/^/   /' || echo "   (no rows / the list needs the caller token — read it from the gateway log instead)"
echo "== codex rail after the ride ($(date -u +%FT%TZ))"
after="$(codex_series)"; printf '%s\n' "$after" | sed 's/^/   /'
echo "== deltas (after − before) on rail=\"codex\" counters"
python3 -I - "$before" "$after" <<'PY'
import re, sys
def parse(text):
    out = {}
    for line in text.splitlines():
        m = re.match(r'^(\S+?\{[^}]*\}|\S+) (\S+)$', line.strip())
        if m:
            out[m.group(1)] = float(m.group(2))
    return out
b, a = parse(sys.argv[1]), parse(sys.argv[2])
for k in sorted(set(a) | set(b)):
    if "_total" in k and a.get(k, 0) != b.get(k, 0):
        print(f"   {k}: {b.get(k, 0):g} → {a.get(k, 0):g}")
PY
echo "== evidence: the ride pod's /tmp/run.log (codex exec --json JSONL) and the gateway log lines 'responses rail=codex session=' hold the transcript; record the window + these lines in the spike (§Lighting the rail, step 4)"
