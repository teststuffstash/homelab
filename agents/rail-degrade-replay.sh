#!/usr/bin/env bash
# rail-degrade-replay — behavioural pin for the homelab#158 rail-degrade path in agent-session.sh.
#
#   bash agents/rail-degrade-replay.sh          # or: devbox run -- bash agents/rail-degrade-replay.sh
#
# WHY THIS EXISTS (homelab#166). #158 leg 1 shipped an INVARIANT: a dispatch already on the
# subscription rail must proceed with ZERO OpenRouter key-API calls, even while the operator's
# OpenRouter account is dead. It was verified by a dev-time replay that was never committed — the
# replay found two real defects before commit and then evaporated, leaving the invariant pinned by
# nothing. The nine-case table in PR #162's body is the spec; this file is that table, retained.
#
# The two defects it must keep re-catching, because both were one-token errors that review passed:
#   1. `jq`'s `//` fires on FALSE as well as null, so `.subscriptionFallback // true` silently
#      disabled the per-stack opt-out knob.                                        → scenario C
#   2. The degrade ignored the claim's `modelDeny`, handing a stack a model it had refused.
#                                                                                  → scenario DENY
#
# WHAT IT RUNS. The launcher blocks under test are EXTRACTED FROM agents/agent-session.sh at run
# time by the `>>>REPLAY:<name>>>>` sentinels, never transcribed — so this file cannot drift from
# the launcher. Five blocks, composed in the launcher's own order, and nothing between them is
# invented except the two bridge lines called out below:
#
#   rail-degrade → chainless-guard → model-id-resolution → [bridge] → agent-rail → fu088-gates
#
# The chainless guard is in the chain deliberately: a degraded chainless ride has to survive it
# (`[ -z "${RAIL_DEGRADED:-}" ]`), and without that block scenario E would pass vacuously.
#
# THE SEAMS, all of them:
#   • `curl` is a recorder on $PATH — it never leaves the machine, serves /api/v1/credits from
#     $STUB_CREDITS, and logs every call so "probed 0 times" is assertable. This is the leg-1
#     instrument: scenario B asserts the log is EMPTY.
#   • `$HERE` points at a stub dir holding a stubbed `subscription-latch.sh` (the FU-088(a) probe,
#     which would otherwise need the in-cluster egress proxy) and a SYMLINK to the real
#     `agents/model_id.py` — the harness/model parse under test is the live one.
#   • `PROXY_URL` is set in the bridge, mirroring agent-session.sh's own derivation from
#     $AGENT_OPENROUTER_PROXY. If that ever drifts, the FU-088(b) rows go RED, not quiet.
# No cluster, no credentials, no network. Runs in a couple of seconds.
#
# NOT WIRED INTO CI, and not by preference: that needs a `devbox.json` script plus a step in
# .github/workflows/ci.yaml, and both are off-limits to the fixer lane precisely because CI runs
# them from the PR's own branch. Same posture (and same lane split) as
# agents/coordinator/responder-behaviour-test.sh — see homelab#133 for the operator-side wiring.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="${LAUNCHER:-$HERE/agent-session.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; STUBHOME="$TMP/stubhome"; mkdir -p "$BIN" "$STUBHOME"

command -v jq      >/dev/null 2>&1 || { echo "rail-degrade-replay: needs jq (devbox run -- bash $0)";      exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "rail-degrade-replay: needs python3 (devbox run -- bash $0)"; exit 2; }
command -v awk     >/dev/null 2>&1 || { echo "rail-degrade-replay: needs awk";                             exit 2; }

# ── the blocks under test, straight out of the launcher ─────────────────────────────────────────
extract() {   # extract <marker-name> → stdout; exit 3 if either sentinel is missing
  awk -v n="$1" '
    $0 == "# >>>REPLAY:" n ">>>" { inb=1; saw_open=1; next }
    $0 == "# <<<REPLAY:" n "<<<" { inb=0; saw_close=1; next }
    inb { print }
    END { if (!saw_open || !saw_close) exit 3 }
  ' "$LAUNCHER"
}
for b in rail-degrade chainless-guard model-id-resolution agent-rail fu088-gates; do
  extract "$b" > "$TMP/block.$b.sh" || {
    echo "rail-degrade-replay: sentinel >>>REPLAY:$b>>> / <<<REPLAY:$b<<< missing from $LAUNCHER." >&2
    echo "  The block moved or the markers were deleted. Restore them around the block — this" >&2
    echo "  harness pins homelab#158 leg 1 and cannot assert on code it cannot find." >&2
    exit 3; }
  [ -s "$TMP/block.$b.sh" ] || { echo "rail-degrade-replay: block '$b' extracted EMPTY from $LAUNCHER." >&2; exit 3; }
done

# ── stubs ───────────────────────────────────────────────────────────────────────────────────────
cat > "$BIN/curl" <<'EOF'
#!/bin/bash
# Recorder. Never reaches the network; every invocation lands in $CALLS so a scenario can assert
# on the NUMBER of OpenRouter probes (leg 1: a subscription ride makes zero) and on the shape of
# the Authorization header (opaque `ref:`, never key material).
printf '%s\n' "curl $*" >> "$CALLS"
_url=""
for a in "$@"; do case "$a" in http://*|https://*) _url="$a";; esac; done
case "$_url" in
  */api/v1/credits)
    [ "${STUB_CREDITS:-}" = "unreachable" ] && exit 7   # -fsS would fail the same way
    printf '{"data":{"total_credits":%s,"total_usage":0}}' "${STUB_CREDITS:-0}"; exit 0;;
esac
exit 0
EOF
cat > "$STUBHOME/subscription-latch.sh" <<'EOF'
#!/bin/bash
# The FU-088(a) probe: exit 0 = clear, exit 1 = deferred. Real one talks to the egress proxy.
printf '%s\n' "subscription-latch $*" >> "$CALLS"
[ "${STUB_LATCH:-clear}" = "latched" ] && { echo "→ subscription limited (stub: 429 latch)" >&2; exit 1; }
exit 0
EOF
chmod +x "$BIN"/* "$STUBHOME/subscription-latch.sh"
ln -sf "$HERE/model_id.py" "$STUBHOME/model_id.py"   # the REAL parser — not a stub

# ── the composed replay: launcher blocks in launcher order, with the inputs named ───────────────
{
  cat <<'PRE'
set -euo pipefail
# Inputs the launcher would have computed above the first block under test (argv parse, stacks.json
# read, /route call). Everything here is a launcher variable, not a harness invention.
HERE="$REPLAY_STUBHOME"
PROJECT="$IN_PROJECT";       OR_SECRET=""
HARNESS="$IN_HARNESS";       MODEL="$IN_MODEL";      HARNESS_SET="$IN_HARNESS_SET"
MODEL_SET="$IN_MODEL_SET";   TASK="$IN_TASK";        _srow="$IN_SROW"
AGENT_ROUTER="$IN_ROUTER_MODE"
_router_defer="$IN_ROUTER_DEFER"; _rwhy="$IN_RWHY"; _retry="30"
_verdict="$IN_VERDICT";           _rmodel="$IN_RMODEL"
PRE
  cat "$TMP/block.rail-degrade.sh"
  cat "$TMP/block.chainless-guard.sh"
  cat "$TMP/block.model-id-resolution.sh"
  cat <<'BRIDGE'
# ── bridge ── the two lines the launcher runs between the blocks above and the gates below that
# this harness must restate: the egress-proxy URL (agent-session.sh derives PROXY_URL from the same
# env var, next to the goose proxy env) and DOCKER, which only selects the endpoint-IP form.
PROXY_URL="${AGENT_OPENROUTER_PROXY-http://openrouter-proxy.agent-egress.svc.cluster.local:8080}"
BRIDGE
  cat "$TMP/block.agent-rail.sh"
  cat <<'STATE'
# Observation point, not launcher code: the resolved model/harness/rail, printed BEFORE the FU-088
# gates so the scenarios that legitimately defer there can still be asserted on what they resolved.
printf 'STATE MODEL=%s HARNESS=%s RAIL=%s DEGRADED=%s CAPACITY_DOWN=%s CREDITS=%s\n' \
  "$MODEL" "$HARNESS" "${AGENT_RAIL:-}" "${RAIL_DEGRADED:-}" "${OR_CAPACITY_DOWN:-}" "${OR_CREDITS:-}"
STATE
  cat "$TMP/block.fu088-gates.sh"
  cat <<'POST'
echo "REACHED: dispatch"
POST
} > "$TMP/replay.sh"
bash -n "$TMP/replay.sh" || { echo "rail-degrade-replay: the composed replay is not valid shell — a block boundary is wrong." >&2; exit 1; }

# ── assertions ──────────────────────────────────────────────────────────────────────────────────
PASS=0; FAIL=0; FAILED=()
ok()      { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()     { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  \033[31m✗\033[0m %s\n       %s\n' "$1" "$2"; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Defaults per scenario: a healthy or-primary stack on a fix ride, shadow router, nothing wrong.
scenario() {
  SCEN="$1"; printf '\n\033[1m%s\033[0m\n' "$1"
  CALLS="$TMP/calls.$RANDOM.log"; : > "$CALLS"
  IN_PROJECT="oracle-iac"; IN_HARNESS="opencode"; IN_MODEL="xiaomi/mimo-v2.5"
  IN_HARNESS_SET=""; IN_MODEL_SET=""; IN_TASK="issue-166"
  IN_SROW='{"name":"oracle","workerModel":"xiaomi/mimo-v2.5","workerModelFallbacks":["qwen/qwen3-coder:free"]}'
  IN_ROUTER_MODE="shadow"; IN_ROUTER_DEFER=""; IN_RWHY=""; IN_VERDICT=""; IN_RMODEL=""
  STUB_CREDITS="12.40"; STUB_LATCH="clear"
}
go() {
  CALLS="$CALLS" STUB_CREDITS="$STUB_CREDITS" STUB_LATCH="$STUB_LATCH" \
  REPLAY_STUBHOME="$STUBHOME" \
  IN_PROJECT="$IN_PROJECT" IN_HARNESS="$IN_HARNESS" IN_MODEL="$IN_MODEL" \
  IN_HARNESS_SET="$IN_HARNESS_SET" IN_MODEL_SET="$IN_MODEL_SET" IN_TASK="$IN_TASK" \
  IN_SROW="$IN_SROW" IN_ROUTER_MODE="$IN_ROUTER_MODE" IN_ROUTER_DEFER="$IN_ROUTER_DEFER" \
  IN_RWHY="$IN_RWHY" IN_VERDICT="$IN_VERDICT" IN_RMODEL="$IN_RMODEL" \
  PATH="$BIN:$PATH" \
    bash "$TMP/replay.sh" > "$TMP/out.txt" 2> "$TMP/err.txt"
  RC=$?
  OUT="$(cat "$TMP/out.txt")"; ERR="$(cat "$TMP/err.txt")"
}
want()     { printf '%s' "$OUT" | grep -qF -- "$2" && ok "$1" || bad "$1" "stdout lacks: $2"; }
wantnot()  { printf '%s' "$OUT" | grep -qF -- "$2" && bad "$1" "stdout has: $2" || ok "$1"; }
wanterr()  { printf '%s' "$ERR" | grep -qF -- "$2" && ok "$1" || bad "$1" "stderr lacks: $2"; }
wantrc()   { [ "$RC" = "$2" ] && ok "$1" || bad "$1" "exit $RC, wanted $2 (stderr: $(printf '%s' "$ERR" | tail -1))"; }
probes()   { grep -c 'api/v1/credits' "$CALLS" 2>/dev/null || true; }
wantprobes() { n="$(probes)"; n="${n:-0}"; [ "$n" = "$2" ] && ok "$1" || bad "$1" "OpenRouter probed ${n}×, wanted $2"; }

printf '\033[1mrail-degrade-replay\033[0m — homelab#158 leg 1 + the #162 nine-case table, replayed\n'
printf 'launcher: %s\n' "$LAUNCHER"
printf 'condition under replay: OpenRouter account $0.17 with a $0.25 floor (2026-08-08)\n'

# ── A ── or-primary stack, class=fix, shadow mode → degrade to the subscription rail ────────────
scenario "A — or-primary stack, class=fix, shadow mode, dead account"
STUB_CREDITS="0.17"
go
want    "A: degrades instead of deferring"            "RAIL DEGRADE"
want    "A: names the credit trigger"                 'credit:$0.17<$0.25'
want    "A: dispatches on the subscription rail"      "rail=subscription-fallback"
want    "A: MODEL=haiku HARNESS=claude RAIL=subscription-fallback" \
        "STATE MODEL=haiku HARNESS=claude RAIL=subscription-fallback"
want    "A: reaches dispatch"                         "REACHED: dispatch"
wantrc  "A: does not exit"                            0
wantprobes "A: probes the account exactly once"       1

# ── B ── THE LEG-1 REGRESSION PIN ───────────────────────────────────────────────────────────────
# A ride already on the subscription rail must not consult OpenRouter state AT ALL — not to degrade,
# not to gate. The account being dead is not a fact about this ride. Both dispatch shapes:
#   B1 = `--harness claude` (explicit), B2 = a claudeTier claim's `workerModel: claude/haiku`
#        with no --harness, i.e. what the coordinator actually dispatches for circles.
scenario "B1 — claudeTier ride (--harness claude), same dead account"
IN_HARNESS="claude"; IN_MODEL="haiku"; IN_HARNESS_SET="1"
IN_SROW='{"name":"circles","workerModel":"claude/haiku","modelDeny":["openrouter/owl-alpha"]}'
STUB_CREDITS="0.17"
go
wantprobes "B1: OpenRouter probed ZERO times (leg 1)"  0
wantnot "B1: no degrade attempted"                     "RAIL DEGRADE"
wantnot "B1: no capacity verdict at all"               "OpenRouter capacity down"
want    "B1: model untouched, subscription rail"       "STATE MODEL=haiku HARNESS=claude RAIL=subscription"
want    "B1: reaches dispatch"                         "REACHED: dispatch"
wantrc  "B1: does not exit"                            0

scenario "B2 — claudeTier claim (workerModel claude/haiku, no --harness), same dead account"
IN_HARNESS="opencode"; IN_MODEL="claude/haiku"
IN_SROW='{"name":"circles","workerModel":"claude/haiku","modelDeny":["openrouter/owl-alpha"]}'
STUB_CREDITS="0.17"
go
wantprobes "B2: OpenRouter probed ZERO times (leg 1)"  0
wantnot "B2: no degrade attempted"                     "RAIL DEGRADE"
want    "B2: parses to the claude harness"             "STATE MODEL=haiku HARNESS=claude RAIL=subscription"
want    "B2: reaches dispatch"                         "REACHED: dispatch"
wantrc  "B2: does not exit"                            0

# ── C ── the per-stack opt-out. DEFECT 1: `// true` would swallow `false` and degrade anyway. ────
scenario "C — subscriptionFallback:false → strict wait, no degrade"
IN_SROW='{"name":"oracle","workerModel":"xiaomi/mimo-v2.5","subscriptionFallback":false}'
STUB_CREDITS="0.17"
go
wantnot "C: does NOT degrade (jq // -on-false defect)" "RAIL DEGRADE"
want    "C: says why it is not degrading"              "subscriptionFallback:false on the stack row"
want    "C: model unchanged"                           "STATE MODEL=xiaomi/mimo-v2.5 HARNESS=opencode RAIL=openrouter"
want    "C: falls through to the FU-088(b) floor"      "below the \$0.25 floor"
wantrc  "C: defers (exit 0), does not dispatch"        0
wantnot "C: never reaches dispatch"                    "REACHED: dispatch"

scenario "C2 — AGENT_SUBSCRIPTION_FALLBACK=0 per-run override → strict wait"
IN_SROW='{"name":"oracle","workerModel":"xiaomi/mimo-v2.5"}'
STUB_CREDITS="0.17"; export AGENT_SUBSCRIPTION_FALLBACK=0
go
unset AGENT_SUBSCRIPTION_FALLBACK
wantnot "C2: does NOT degrade"                         "RAIL DEGRADE"
want    "C2: names the run-level override"             "AGENT_SUBSCRIPTION_FALLBACK=0"

# ── D ── non-fix rides keep deferring: scarce subscription headroom is for tasked rides ──────────
scenario "D — research fan-out arm (non-fix ride) → no degrade"
IN_TASK="research-openrouter-alternatives"
STUB_CREDITS="0.17"
go
wantnot "D: does NOT degrade"                          "RAIL DEGRADE"
want    "D: says it is a non-fix ride"                 "no degrade for a non-fix ride"
want    "D: still defers on the FU-088(b) floor"       "below the \$0.25 floor"
wantrc  "D: defers (exit 0)"                           0

# ── E ── the ROUTER trigger, on a chainless stack: degrade instead of exit 1 ─────────────────────
scenario "E — authoritative defer or-capacity-down:rpd, chainless stack → dispatches haiku"
IN_ROUTER_MODE="authoritative"; IN_ROUTER_DEFER="1"; IN_RWHY="or-capacity-down:rpd,account"
IN_SROW='{"name":"newstack"}'                       # chainless: no workerModel
go
want    "E: degrades on the typed router defer"        "RAIL DEGRADE"
want    "E: names the router as the trigger"           "router:or-capacity-down:rpd"
want    "E: does NOT die on the chainless guard"       "STATE MODEL=haiku HARNESS=claude RAIL=subscription-fallback"
want    "E: reaches dispatch"                          "REACHED: dispatch"
wantrc  "E: exit 0, not the router's exit 1"           0
wantprobes "E: no probe needed — capacity already known" 0

# ── F ── escalation preserved: chain-exhausted is not a provider outage ──────────────────────────
scenario "F — authoritative defer chain-exhausted → still exit 1"
IN_ROUTER_MODE="authoritative"; IN_ROUTER_DEFER="1"; IN_RWHY="chain-exhausted"
go
wantnot "F: does NOT degrade"                          "RAIL DEGRADE"
wanterr "F: escalates, unchanged"                      "router: DEFER (chain-exhausted)"
wantrc  "F: exits 1 (escalation preserved)"            1
wantnot "F: never reaches dispatch"                    "REACHED: dispatch"

# ── G ── the healthy path is untouched ───────────────────────────────────────────────────────────
scenario "G — healthy account → nothing happens"
go
wantnot "G: no degrade"                                "RAIL DEGRADE"
wantnot "G: no capacity verdict"                       "OpenRouter capacity down"
want    "G: stays on the openrouter rail"              "STATE MODEL=xiaomi/mimo-v2.5 HARNESS=opencode RAIL=openrouter"
want    "G: reaches dispatch"                          "REACHED: dispatch"
wantprobes "G: probes the account exactly once"        1
grep -qF -- 'Authorization: Bearer ref:oracle-iac/oracle-iac-openrouter' "$CALLS" \
  && ok "G: the probe carries an OPAQUE ref, never key material" \
  || bad "G: the probe carries an OPAQUE ref, never key material" "no 'Bearer ref:<project>/<secret>' in the call log"

scenario "G2 — SHADOW-mode router defer → not a trigger (shadow must not self-promote)"
IN_ROUTER_MODE="shadow"; IN_ROUTER_DEFER=""; IN_RWHY="or-capacity-down:rpd"   # shadow never sets _router_defer
go
wantnot "G2: a shadow defer does not degrade"          "RAIL DEGRADE"
want    "G2: dispatch proceeds unchanged"              "REACHED: dispatch"

# ── H ── the degraded ride is still bounded by FU-088(a) ─────────────────────────────────────────
scenario "H — degraded ride + latched subscription → defers"
STUB_CREDITS="0.17"; STUB_LATCH="latched"
go
want    "H: the degrade happened"                      "RAIL DEGRADE"
want    "H: and the FU-088(a) latch still binds it"    "claude-tier dispatch deferred — subscription limited (FU-088)"
wantrc  "H: defers (exit 0)"                           0
wantnot "H: never reaches dispatch"                    "REACHED: dispatch"

# ── I ── everything that did not degrade still hits the FU-088(b) floor ──────────────────────────
scenario "I — no degrade (opted out) → defers on the credit floor exactly as before"
IN_SROW='{"name":"oracle","workerModel":"xiaomi/mimo-v2.5","subscriptionFallback":false}'
STUB_CREDITS="0.17"
go
want    "I: FU-088(b) floor still fires"               "dispatch deferred — OpenRouter account credit \$0.17 below the \$0.25 floor"
wantrc  "I: defers (exit 0)"                           0
wantnot "I: never reaches dispatch"                    "REACHED: dispatch"

# ── DENY ── DEFECT 2: the claim's modelDeny binds the fallback too ───────────────────────────────
scenario "DENY — claude/haiku in the claim's modelDeny → the claim wins, no degrade"
IN_SROW='{"name":"oracle","workerModel":"xiaomi/mimo-v2.5","modelDeny":["claude/haiku","openrouter/owl-alpha"]}'
STUB_CREDITS="0.17"
go
wantnot "DENY: does NOT degrade into a denied model"   "RAIL DEGRADE"
want    "DENY: says the claim beat the fallback"       "in this stack's modelDeny — the claim wins over the fallback"
want    "DENY: model unchanged"                        "STATE MODEL=xiaomi/mimo-v2.5"
wantrc  "DENY: defers (exit 0)"                        0

# ── FAILOPEN ── an unreachable probe is not an outage verdict ────────────────────────────────────
scenario "FAILOPEN — credit probe unreachable → fail open, dispatch unchanged"
STUB_CREDITS="unreachable"
go
wantnot "FAILOPEN: no degrade on a failed probe"       "RAIL DEGRADE"
wantnot "FAILOPEN: no credit-floor defer either"       "below the \$0.25 floor"
want    "FAILOPEN: dispatch proceeds"                  "REACHED: dispatch"
wantrc  "FAILOPEN: exit 0"                             0

# ── result ──────────────────────────────────────────────────────────────────────────────────────
section "result"
printf '  %s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\n\033[31mFAILED:\033[0m\n'; for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
  printf '\nThe rail-degrade path changed behaviour. If that was deliberate, update the case here in\n'
  printf 'the same commit — the nine-case table in homelab#162 is the spec it is held to.\n'
  exit 1
fi
printf '\n\033[32mThe homelab#158 rail-degrade contract holds.\033[0m\n'
