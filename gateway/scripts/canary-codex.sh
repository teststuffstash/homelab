#!/usr/bin/env bash
# The CODEX CANARY — spike step 4 (docs/spikes/codex-subscription-rail.md §Lighting the rail, FU-270):
# ONE prober ride on the codex rail through agents/agent-session.sh under the gateway (/sessions),
# `--harness codex`, a synthetic read-only prompt, a disposable task key. A JAIL verb like
# canary-entrants.sh; run it INSIDE a declared maintenance window (.claude/skills/maintenance-window):
# the ride is the first live use of the operator's ChatGPT subscription through the gateway.
#
#   bash gateway/scripts/canary-codex.sh [--dry-run] [--prompt "<text>"] [--capture] < /dev/null
#
# --capture (GW-CODEX-CAPTURE, the spike §Recorded live protocol experiment): the task is named
# `capture-codex-<ts>` — the prefix the deployed recorder is scoped to — and after the ride the
# session's sanitized four-boundary bundle is pulled (GET /sessions/{id}/capture, the caller's token)
# into CODEX_CAPTURE_DIR (default ~/.claude/codex-capture — restricted storage, never the repo) and
# summarised here: boundaries, header names, event types in order, the terminal's usage. The bundle
# carries no credential by construction; review it before any excerpt reaches the spike or a fixture.
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
DRY=0; CAPTURE=0
PROMPT="Reply with ONLY the first markdown heading text of README.md (no other words)."
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift;;
    --capture) CAPTURE=1; shift;;
    --prompt) PROMPT="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
case "$PROMPT" in *\"*|*\\*|*\$*|*\`*|*$'\n'*) echo "the prompt must carry no double quote, backslash, dollar, backtick or newline (it rides inside the pod's run command, which the pod's shell expands)" >&2; exit 2;; esac
pf=""; OWN_PF=""
cleanup() { [ -n "$pf" ] && kill "$pf" 2>/dev/null || true; }
trap cleanup EXIT
# The port-forward is re-opened whenever it is found dead: the first ride (2026-10-22) pulled a new
# agent-base image for ~4 min and the forward had died by the time the launcher's EXIT trap tried to
# release the session — the slot (max_sessions 1) was held until a hand DELETE. Same port every time
# (`:$port`), so AGENT_GATEWAY_URL stays valid for the launcher's own calls too.
open_pf() {
  [ -n "$OWN_PF" ] || return 0
  curl -fsS -o /dev/null --max-time 3 "$AGENT_GATEWAY_URL/healthz" 2>/dev/null && return 0
  [ -n "$pf" ] && kill "$pf" 2>/dev/null || true
  local log; log=$(mktemp)
  kubectl -n agent-egress port-forward svc/agent-gateway "${port:-0}:8080" >"$log" 2>&1 & pf=$!
  for _ in $(seq 1 30); do
    port=$(sed -nE 's/^Forwarding from 127\.0\.0\.1:([0-9]+) -> 8080$/\1/p' "$log" | head -n 1)
    [ -n "$port" ] && curl -fsS -o /dev/null "http://127.0.0.1:$port/healthz" 2>/dev/null && break
    sleep 1
  done
  [ -n "$port" ] || { echo "port-forward to svc/agent-gateway did not come up:"; cat "$log"; exit 1; }
  export AGENT_GATEWAY_URL="http://127.0.0.1:$port"
}
port=""
if [ -z "${AGENT_GATEWAY_URL:-}" ]; then OWN_PF=1; AGENT_GATEWAY_URL="http://127.0.0.1:0"; open_pf; fi
export AGENT_GATEWAY=sessions AGENT_GATEWAY_ROLE=prober
export AGENT_GATEWAY_CALLER_SA="${AGENT_GATEWAY_CALLER_SA:-platform-agents/agentstack-loop}"
PROJECT="${CANARY_PROJECT:-homelab}"

codex_series() {  # the rail's state as the gateway renders it — gauges, the poll counter, the request/token counters
  curl -fsS "$AGENT_GATEWAY_URL/metrics" | grep -E '^gateway_(subscription_utilization|subscription_reset_seconds|codex_usage_poll_total|requests_total|tokens_total|upstream_auth_rejected_total)\{[^}]*rail="codex"|^gateway_codex_usage_poll_total' || true
}
echo "== codex rail before the ride ($(date -u +%FT%TZ))"
before="$(codex_series)"; printf '%s\n' "$before" | sed 's/^/   /'
if ! grep -q 'gateway_codex_usage_poll_total{outcome="accepted"} [1-9]' <<< "$before"; then
  echo "   NOTE: no accepted usage poll yet — the gateway will defer quota-unknown / quota-stale; a dispatch means the poll caught up."
fi
task="$([ "$CAPTURE" = 1 ] && echo capture-codex || echo canary-codex)-$(date -u +%Y%m%dT%H%M%SZ)"
echo "== the ride: project=${PROJECT} role=prober harness=codex task=${task} caller=${AGENT_GATEWAY_CALLER_SA}"
echo "   prompt: ${PROMPT}"
if [ "$DRY" = 1 ]; then echo "== dry run — nothing dispatched"; exit 0; fi
# The ride names NO model (the gateway owns it under /sessions); the pod's agent-codex renders the
# provider block from the pulled env and runs `codex exec --json` — the pod is the sandbox.
rc=0
bash agents/agent-session.sh "$PROJECT" --harness codex --task "$task" --round 1 \
  --run "agent-codex --dangerously-bypass-approvals-and-sandbox \"$PROMPT\"" </dev/null 2>&1 | tail -n 40 || rc=$?
echo "== launcher exit: ${rc} (0 = the pod ran to its finalize; a router-defer exit = the gateway's NO, its reason is above)"
open_pf
# The session rows need the CALLER's token (GW-SESSIONS-AUTH: a judge/dispatcher sees its own); mint the
# same SA token the launcher used (the jail canary rule) — short-lived, never printed. Any session of
# this task still `active` is released here: the launcher's own release rides its EXIT trap through
# AGENT_GATEWAY_URL, which a dead forward silently fails (the 2026-10-22 ride).
tok="$(kubectl -n "${AGENT_GATEWAY_CALLER_SA%%/*}" create token "${AGENT_GATEWAY_CALLER_SA#*/}" --audience agent-gateway --duration 10m 2>/dev/null || true)"
echo "== the session rows for task=${task} (no token in a list — GW-SESSIONS-TOKEN)"
rows="$(curl -fsS "$AGENT_GATEWAY_URL/sessions?task=${task}" ${tok:+-H "Authorization: Bearer $tok"} 2>/dev/null || true)"
if [ -n "$rows" ]; then
  printf '%s\n' "$rows" | jq -c '(.sessions // .)[]? // . | {id, rail, harness, model, state, requests, tokens_in, tokens_out, requests_incomplete, outcome, released_at}' 2>/dev/null | sed 's/^/   /'
  for sid in $(printf '%s\n' "$rows" | jq -r '(.sessions // .)[]? | select(.state=="active") | .id' 2>/dev/null); do
    printf '   releasing still-active session %s → ' "$sid"
    curl -s -o /dev/null -w '%{http_code}\n' -X DELETE "$AGENT_GATEWAY_URL/sessions/$sid" ${tok:+-H "Authorization: Bearer $tok"}
  done
  if [ "$CAPTURE" = 1 ]; then
    dir="${CODEX_CAPTURE_DIR:-$HOME/.claude/codex-capture}"; mkdir -p "$dir"; chmod 700 "$dir"
    echo "== the capture bundles (GET /sessions/{id}/capture → ${dir}/, restricted; summary only here)"
    for sid in $(printf '%s\n' "$rows" | jq -r '(.sessions // .)[]? | .id' 2>/dev/null); do
      out="$dir/${task}-${sid}.json"
      code="$(curl -s -o "$out" -w '%{http_code}' "$AGENT_GATEWAY_URL/sessions/$sid/capture" ${tok:+-H "Authorization: Bearer $tok"})"
      if [ "$code" != 200 ]; then echo "   session $sid: HTTP $code — $(head -c 200 "$out")"; rm -f "$out"; continue; fi
      chmod 600 "$out"; echo "   session $sid → $out"
      python3 -I - "$out" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
recs = b["records"]
print(f"   format={b['format']} complete={b['complete']} records={len(recs)} boundaries={b['boundaries']}")
for r in recs:
    kind = r["boundary"]
    if kind == "upstream-event":
        continue
    hdrs = sorted(r.get("headers", {}))
    if kind == "client-request":
        print(f"   [{r['t_ms']:>6} ms] {kind}: {r['method']} {r['path']} body={r['body_bytes']}B headers={hdrs}")
    elif kind == "upstream-request":
        print(f"   [{r['t_ms']:>6} ms] {kind}: {r['method']} {r['host']}{r['path']} body={r['body_bytes']}B added={r['headers_added']} dropped={r['headers_dropped']}")
    elif kind == "upstream-response":
        kept = {k: v for k, v in r.get("headers", {}).items() if not isinstance(v, dict)}
        print(f"   [{r['t_ms']:>6} ms] {kind}: {r['status']} refusal={r.get('refusal')} first_byte={r['first_byte_ms']}ms headers={hdrs}")
        print(f"            kept values: {kept}")
    elif kind == "client-response":
        print(f"   [{r['t_ms']:>6} ms] {kind}: {r['status']} outcome={r['outcome']} events={r['events']} relayed={r['relayed_bytes']}B usage={r['usage']} cancelled={r['cancelled']} headers={hdrs}")
    else:
        print(f"   [{r['t_ms']:>6} ms] {kind}: {r}")
types = [e.get("event", {}).get("type", "<invalid>" if e.get("invalid") else "[DONE]" if e.get("done") else "?") for e in recs if e["boundary"] == "upstream-event"]
from collections import Counter
print(f"   events ({len(types)}): first {types[:4]} … last {types[-3:]}; by type: {dict(Counter(types))}")
PY
    done
  fi
else
  echo "   (no rows — read the gateway log: kubectl -n agent-egress logs deploy/agent-gateway | grep ${task})"
fi
unset tok
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
