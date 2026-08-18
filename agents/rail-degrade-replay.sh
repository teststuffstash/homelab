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
# homelab#190 extends it: when the account balance moved off OpenRouter's management-only
# /api/v1/credits onto the proxy's /router-status, "the balance is unavailable" gained real,
# distinguishable failure modes — FAILOPEN..FAILOPEN4 + STALE/STALE2 are those rows, and they
# assert the fail-open is VISIBLE, which is the defect #190 was filed for.
# homelab#194 adds the second fact behind that same URL — the proxy's latched `.openrouter_capacity
# .down` — as a shadow-mode trigger. CAP..CAP6 pin the TRIGGER PRECEDENCE (the latch outranks the
# credit read), the two shapes that must NOT fire (a stale non-null `reason` beside `down:false`;
# a payload that never arrived), and that the fail-open line now says WHICH of the two facts is
# missing. The operator's ruling on #194 made those rows a condition of taking the change.
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
#   • `curl` is a recorder on $PATH — it never leaves the machine, serves the proxy's
#     /router-status from $STUB_CREDITS/$STUB_CREDIT_AGE/$STUB_CREDIT_MAX_AGE, and logs every call
#     so "probed 0 times" is assertable. This is the leg-1 instrument: scenario B asserts the log
#     is EMPTY. homelab#190: it also FAILS LOUDLY if the launcher ever calls the retired
#     /api/v1/credits again — that endpoint is management-key-only and 403s in production, so a
#     stub that served it would keep the dead gate looking green (it did, for weeks).
#   • `$HERE` points at a stub dir holding a stubbed `subscription-latch.sh` (the FU-088(a) probe,
#     which would otherwise need the in-cluster egress proxy) and a SYMLINK to the real
#     `agents/model_id.py` — the harness/model parse under test is the live one.
#   • `PROXY_URL` is set in the bridge, mirroring agent-session.sh's own derivation from
#     $AGENT_OPENROUTER_PROXY. If that ever drifts, the FU-088(b) rows go RED, not quiet.
# No cluster, no credentials, no network. Runs in a couple of seconds.
#
# WIRED INTO CI by the operator lane since (`devbox run rail-degrade-replay`, a step in
# .github/workflows/ci.yaml) — so this file is now a REQUIRED check, and a fixer-lane PR that
# changes the launcher blocks above must update the cases here in the same PR. `devbox.json` and
# .github/** themselves stay off-limits to that lane, because CI runs them from the PR's own
# branch. Same posture (and same lane split) as agents/coordinator/responder-behaviour-test.sh —
# see homelab#133 for the operator-side wiring.
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
  */router-status)
    # The proxy's capacity view (homelab#180 shape), trimmed to the fields the launcher reads.
    # $STUB_CREDITS doubles as the failure-mode selector, because every one of these is a way the
    # balance can be UNAVAILABLE and the launcher must treat them all alike — fail-open, loudly:
    #   unreachable → the proxy is not answering (-fsS fails; NetworkPolicy gap, pod rolling)
    #   garbage     → it answered, but not with JSON
    #   none        → it answered with no usable balance (NaN before the first poll, dead leg)
    #   oldproxy    → valid JSON with no capacity block at all (a proxy rolled back behind #180)
    case "${STUB_CREDITS:-}" in
      unreachable) exit 7;;
      garbage)     printf 'upstream connect error or disconnect/reset before headers'; exit 0;;
      oldproxy)    printf '{"subscription":{"limited":false}}'; exit 0;;
      none)        _credit=null;;
      *)           _credit="${STUB_CREDITS:-0}";;
    esac
    # homelab#194: the latch bit is a SELECTOR now, not a literal — the launcher reads it, so the
    # harness has to be able to set it. Defaults are today's healthy values (down:false, no reason,
    # nothing latched), which is what every pre-#194 row was implicitly asserting against.
    # $STUB_CAPACITY_REASON is emitted as JSON `null` when empty — and INDEPENDENTLY of `down`, the
    # way the proxy does it (`"reason": or_cap["reason"] or None` is unconditional, while `"down"`
    # is `until > now`), so the stale-reason-with-down:false shape is reachable here. It has a row.
    _reason=null; [ -n "${STUB_CAPACITY_REASON:-}" ] && _reason="\"${STUB_CAPACITY_REASON}\""
    printf '{"subscription":{"limited":false},"openrouter_capacity":{"down":%s,"reason":%s,"remaining_s":%s,"latched_total":%s,"credit_usd":%s,"credit_age_s":%s,"credit_source":"http://openrouter-operator-metrics.openrouter-operator.svc.cluster.local:9090/metrics","credit_source_age_s":%s,"credit_max_age_s":%s,"credit_poll_failures":0,"min_credit_usd":0.25,"recent_429_models":[]}}' \
      "${STUB_CAPACITY_DOWN:-false}" "$_reason" "${STUB_CAPACITY_REMAINING:-0}" "${STUB_CAPACITY_LATCHED_TOTAL:-0}" \
      "$_credit" "${STUB_CREDIT_AGE:-540}" "${STUB_CREDIT_AGE:-540}" "${STUB_CREDIT_MAX_AGE:-1800}"
    exit 0;;
  */api/v1/credits)
    # homelab#190: RETIRED. OpenRouter serves this to management keys only — with the pod's
    # project-scoped `ref:` it 403s, which is exactly how the credit gate died silently. Never
    # serve a balance here again; a launcher that calls it must fail this harness, not pass it.
    printf 'rail-degrade-replay: the launcher called the RETIRED /api/v1/credits (homelab#190) — it 403s in production.\n' >&2
    exit 22;;
esac
exit 0
EOF
cat > "$STUBHOME/subscription-latch.sh" <<'EOF'
#!/bin/bash
# The FU-088(a) probe: exit 0 = clear, exit 1 = deferred. Real one talks to the egress proxy.
# homelab#439 leg 2: --pick-rail mode — print the rail name when ANY rail is clear, exit 1 only
# when BOTH are latched. STUB_GO_LATCH selects the Go rail's state once the Anthropic latch holds
# (default clear, so a STUB_LATCH=latched scenario that does not name a Go state FAILS OVER — the
# same default the real ladder's fail-open Go probe produces).
printf '%s\n' "subscription-latch $*" >> "$CALLS"
if [ "${1:-}" = "--pick-rail" ]; then
  if [ "${STUB_LATCH:-clear}" = "latched" ]; then
    if [ "${STUB_GO_LATCH:-clear}" = "latched" ]; then
      echo "→ both rails latched (stub)" >&2
      exit 1
    fi
    echo "opencode-go/deepseek-v4-flash"
    exit 0
  fi
  echo "anthropic"
  exit 0
fi
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
  STUB_CREDITS="12.40"; STUB_LATCH="clear"; STUB_GO_LATCH="clear"
  # The freshness pair the launcher honours instead of re-deriving (homelab#190): a balance the
  # proxy is holding past its own credit_max_age_s is NOT a balance.
  STUB_CREDIT_AGE="540"; STUB_CREDIT_MAX_AGE="1800"
  # The proxy's account-scope latch (homelab#194), healthy by default: no hold, nothing latched.
  STUB_CAPACITY_DOWN="false"; STUB_CAPACITY_REASON=""; STUB_CAPACITY_REMAINING="0"
  STUB_CAPACITY_LATCHED_TOTAL="0"
}
go() {
  CALLS="$CALLS" STUB_CREDITS="$STUB_CREDITS" STUB_LATCH="$STUB_LATCH" STUB_GO_LATCH="$STUB_GO_LATCH" \
  STUB_CREDIT_AGE="$STUB_CREDIT_AGE" STUB_CREDIT_MAX_AGE="$STUB_CREDIT_MAX_AGE" \
  STUB_CAPACITY_DOWN="$STUB_CAPACITY_DOWN" STUB_CAPACITY_REASON="$STUB_CAPACITY_REASON" \
  STUB_CAPACITY_REMAINING="$STUB_CAPACITY_REMAINING" \
  STUB_CAPACITY_LATCHED_TOTAL="$STUB_CAPACITY_LATCHED_TOTAL" \
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
# homelab#190: the account-scope probe is the proxy's /router-status, not OpenRouter's
# management-only /api/v1/credits. Counting the NEW path is what keeps leg 1 pinned — a launcher
# that reverted to the old endpoint would score 0 here and fail the G/A rows, not pass quietly.
probes()   { grep -c 'router-status' "$CALLS" 2>/dev/null || true; }
wantprobes() { n="$(probes)"; n="${n:-0}"; [ "$n" = "$2" ] && ok "$1" || bad "$1" "OpenRouter capacity probed ${n}×, wanted $2"; }

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
# homelab#190: the probe used to carry the pod's opaque `ref:` to an endpoint that refused it.
# /router-status is unauthenticated by design, so the invariant is now the stronger one — NO
# credential of any shape leaves the launcher for an account-scope read.
grep -qF -- 'Authorization' "$CALLS" \
  && bad "G: the capacity probe sends NO credential at all" "the call log carries an Authorization header" \
  || ok "G: the capacity probe sends NO credential at all"
grep -qF -- '/router-status' "$CALLS" \
  && ok "G: reads the proxy's capacity view, not OpenRouter" \
  || bad "G: reads the proxy's capacity view, not OpenRouter" "no /router-status call in the log"

scenario "G2 — SHADOW-mode router defer → not a trigger (shadow must not self-promote)"
IN_ROUTER_MODE="shadow"; IN_ROUTER_DEFER=""; IN_RWHY="or-capacity-down:rpd"   # shadow never sets _router_defer
go
wantnot "G2: a shadow defer does not degrade"          "RAIL DEGRADE"
want    "G2: dispatch proceeds unchanged"              "REACHED: dispatch"

# ── H ── the degraded ride is still bounded by FU-088(a) ─────────────────────────────────────────
# homelab#439 leg 2: "bounded" is now the FULL ladder — the Anthropic latch alone no longer
# defers a ride that could fail over to the Go rail. H keeps the both-latched row (Go must be
# latched too, else the ride fails over), H2 pins the new failover leg.
scenario "H — degraded ride + BOTH rails latched → defers"
STUB_CREDITS="0.17"; STUB_LATCH="latched"; STUB_GO_LATCH="latched"
go
want    "H: the degrade happened"                      "RAIL DEGRADE"
want    "H: and the FU-088(a) latch still binds it"    "claude-tier dispatch deferred — both rails latched (FU-088)"
wantrc  "H: defers (exit 0)"                           0
wantnot "H: never reaches dispatch"                    "REACHED: dispatch"

# ── H2 ── the leg-2 failover: Anthropic latched but the Go window clear → serve on the Go rail ──
scenario "H2 — degraded ride + latched subscription + Go clear → fails over to the Go rail (leg 2)"
STUB_CREDITS="0.17"; STUB_LATCH="latched"; STUB_GO_LATCH="clear"
go
want    "H2: the degrade happened"                     "RAIL DEGRADE"
want    "H2: names the Go rail the ride rides"         "serving oracle-iac on the Go rail (opencode-go/deepseek-v4-flash)"
want    "H2: reaches dispatch"                         "REACHED: dispatch"
wantrc  "H2: exit 0"                                   0

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

# ── FAILOPEN ── an unavailable balance is not an outage verdict — but it must never be SILENT ────
# homelab#190 is exactly this row. Fail-open is the right default for a dispatch gate (FU-104: the
# availability of the gate is worth less than the gate), but for weeks it was fail-open BY ACCIDENT
# and in silence — a 403'd probe and a healthy account produced byte-identical output, while the
# archived FU-088(b) entry told an operator a floor existed. Every way the balance can be
# unavailable gets a row, and every row asserts the VISIBLE line, naming the URL that failed.
# homelab#194 makes the third argument load-bearing: ONE URL now carries TWO account-scope facts,
# and which of them is missing changes what an operator should go look at. A payload that never
# arrived loses the latch bit as well as the balance; a payload that arrived with a dead credit leg
# loses only the balance. "no balance" printed for both is the #190 silence one level up.
_failopen_asserts() {   # $1 = label prefix, $2 = the bracketed reason, $3 = the latch clause
  wantnot "$1: no degrade without a balance"           "RAIL DEGRADE"
  wantnot "$1: no credit-floor defer either"           "below the \$0.25 floor"
  want    "$1: SAYS it is fail-open (not silence)"     "FU-088(b) FAIL-OPEN"
  want    "$1: names the URL it could not use"         "http://openrouter-proxy.agent-egress.svc.cluster.local:8080/router-status"
  want    "$1: names the reason"                       "$2"
  want    "$1: says what it knows of the LATCH bit"    "$3"
  want    "$1: dispatch proceeds"                      "REACHED: dispatch"
  wantrc  "$1: exit 0"                                 0
}
_LATCH_UNKNOWN="the capacity latch bit (.openrouter_capacity.down) is MISSING TOO"
_LATCH_UP="the capacity latch bit WAS readable and is not down"

scenario "FAILOPEN — /router-status unreachable → visibly fail open, dispatch unchanged"
STUB_CREDITS="unreachable"
go
_failopen_asserts "FAILOPEN" "unreachable or unparseable" "$_LATCH_UNKNOWN"

scenario "FAILOPEN2 — /router-status answers with garbage → visibly fail open"
STUB_CREDITS="garbage"
go
_failopen_asserts "FAILOPEN2" "unreachable or unparseable" "$_LATCH_UNKNOWN"

scenario "FAILOPEN3 — proxy holds NO balance (credit leg dead / NaN before first poll)"
STUB_CREDITS="none"
go
# The payload ARRIVED and its latch bit is readable — only the balance is gone. That is a different
# thing to go look at (the credit leg) than a proxy that did not answer at all.
_failopen_asserts "FAILOPEN3" "no-balance" "$_LATCH_UP"
wantprobes "FAILOPEN3: it did ask the proxy"           1

scenario "FAILOPEN4 — proxy answers without a capacity block (rolled back behind homelab#180)"
STUB_CREDITS="oldproxy"
go
# A proxy behind #180 publishes NEITHER fact. It must fail open on both legs — never degrade on a
# `.down` it cannot see, and never mistake its absence for `down:false`.
_failopen_asserts "FAILOPEN4" "no-capacity-block" "$_LATCH_UNKNOWN"

# ── STALE ── the proxy HOLDS its last balance across poll failures, so age is what makes a number
# unusable. A low-but-stale number must not gate: that is a fact about 2h ago, and acting on it is
# how a recovered account stays deferred. The bound is the PROXY's (`credit_max_age_s`), read from
# the payload — never a second copy of the threshold living here.
scenario "STALE — a LOW balance held past the proxy's own credit_max_age_s → fail open, not a floor hit"
STUB_CREDITS="0.17"; STUB_CREDIT_AGE="3600"; STUB_CREDIT_MAX_AGE="1800"
go
_failopen_asserts "STALE" "stale: 3600s old" "$_LATCH_UP"
wantnot "STALE: does not act on a two-hour-old number" "credit:\$0.17"

scenario "STALE2 — the same low balance INSIDE the bound still gates (the bound is not an off switch)"
STUB_CREDITS="0.17"; STUB_CREDIT_AGE="1799"; STUB_CREDIT_MAX_AGE="1800"
go
want    "STALE2: degrades on the fresh low balance"    "RAIL DEGRADE"
want    "STALE2: names the credit trigger"             'credit:$0.17<$0.25'
wantnot "STALE2: no fail-open line when it is usable"  "FU-088(b) FAIL-OPEN"

# ── CAP ── the proxy's LATCHED capacity bit as a shadow-mode trigger (homelab#194) ───────────────
# The credit leg alone could not see the 2026-08-08 outage: the account was RPD-starved with a
# balance the operator had just topped up. `/route` types all three legs, but only in authoritative
# mode — and every OpenRouter-dispatching stack is shadow. These rows pin the TRIGGER PRECEDENCE the
# meta ruling on #194 attached as a condition, and the one shape that must NOT fire (CAP5).
scenario "CAP — .openrouter_capacity.down=true with a HEALTHY balance → degrades on the latch"
STUB_CAPACITY_DOWN="true"; STUB_CAPACITY_REASON="rpd"; STUB_CAPACITY_REMAINING="412"
STUB_CAPACITY_LATCHED_TOTAL="3"     # STUB_CREDITS stays $12.40: the outage shape, exactly
go
want    "CAP: degrades on the latch bit alone"         "RAIL DEGRADE"
want    "CAP: names the leg that fired"                "capacity:rpd"
want    "CAP: carries the latch's remaining hold"      "(proxy latch, 412s left)"
wantnot "CAP: the healthy balance is NOT the trigger"  "credit:\$"
want    "CAP: dispatches on the subscription rail"     "rail=subscription-fallback"
want    "CAP: MODEL=haiku HARNESS=claude"              "STATE MODEL=haiku HARNESS=claude RAIL=subscription-fallback"
wantnot "CAP: no fail-open line (the read worked)"     "FU-088(b) FAIL-OPEN"
want    "CAP: reaches dispatch"                        "REACHED: dispatch"
wantrc  "CAP: does not exit"                           0
wantprobes "CAP: one probe, same payload as the balance" 1

# PRECEDENCE. Both legs fire; the trigger string must record the OWNER's verdict, not the number
# this launcher thresholded itself. Same destination either way — but the string is the record of
# why the fleet moved, and `capacity:rpd` and `credit:$0.17<$0.25` are different incidents.
scenario "CAP2 — latch down AND balance under the floor → the latch names the trigger, not credit"
STUB_CAPACITY_DOWN="true"; STUB_CAPACITY_REASON="402"; STUB_CAPACITY_REMAINING="900"
STUB_CREDITS="0.17"
go
want    "CAP2: degrades"                               "RAIL DEGRADE"
want    "CAP2: the latch wins the trigger string"      "capacity:402"
wantnot "CAP2: the credit leg does not overwrite it"   'credit:$0.17<$0.25'
want    "CAP2: reaches dispatch"                       "REACHED: dispatch"

# The balance can be unusable while the latch bit is perfectly readable — they fail independently.
# The degrade still happens, and the fail-open line must say the latch was read and was DOWN, or it
# reads as "the launcher saw nothing" while it in fact acted.
scenario "CAP3 — latch down + a balance held past credit_max_age_s → still degrades, visibly"
STUB_CAPACITY_DOWN="true"; STUB_CAPACITY_REASON="rpd"; STUB_CAPACITY_REMAINING="88"
STUB_CREDITS="0.17"; STUB_CREDIT_AGE="3600"; STUB_CREDIT_MAX_AGE="1800"
go
want    "CAP3: degrades on the latch"                  "RAIL DEGRADE"
want    "CAP3: names the latch leg"                    "capacity:rpd"
want    "CAP3: still SAYS the balance was unusable"    "FU-088(b) FAIL-OPEN"
want    "CAP3: names the stale balance"                "stale: 3600s old"
want    "CAP3: and that the latch bit WAS read, down"  "the capacity latch bit WAS readable and IS down"
wantnot "CAP3: does not act on the stale number"       'credit:$0.17<$0.25'
want    "CAP3: reaches dispatch"                       "REACHED: dispatch"
wantrc  "CAP3: exit 0"                                 0

# No payload, no latch bit. A transport failure cannot be read as `down` — nor as `down:false`.
scenario "CAP4 — the proxy is unreachable → the latch is UNKNOWN, not down; fail open on both legs"
STUB_CAPACITY_DOWN="true"      # what the proxy WOULD have said, had it answered at all
STUB_CAPACITY_REASON="rpd"; STUB_CREDITS="unreachable"
go
_failopen_asserts "CAP4" "unreachable or unparseable" "$_LATCH_UNKNOWN"
wantnot "CAP4: no capacity trigger from a lost payload" "capacity:rpd"
want    "CAP4: says BOTH facts are unknown"            "BOTH account-scope facts are unknown"

# ⚠ THE TRAP OF THIS ROUND, and the reason the launcher keys on the BOOLEAN. The proxy expires the
# hold when it serves the payload, but `reason` is emitted unconditionally and is only ever cleared
# by an early 2xx un-latch — so a healthy account that took one 429 last week still publishes
# `reason:"rpd"` beside `down:false, remaining_s:0`. A `.reason != null` read would degrade the
# entire fleet to haiku permanently, from the first 429 the account ever takes, and it would look
# exactly like a working trigger.
scenario "CAP5 — down=false with a STALE non-null reason → no degrade (never key on .reason)"
STUB_CAPACITY_DOWN="false"; STUB_CAPACITY_REASON="rpd"; STUB_CAPACITY_REMAINING="0"
STUB_CAPACITY_LATCHED_TOTAL="7"    # it HAS latched before — 7 times — and is not latched now
go
wantnot "CAP5: does NOT degrade on a stale reason"     "RAIL DEGRADE"
wantnot "CAP5: no capacity verdict at all"             "OpenRouter capacity down"
want    "CAP5: stays on the openrouter rail"           "STATE MODEL=xiaomi/mimo-v2.5 HARNESS=opencode RAIL=openrouter"
want    "CAP5: reaches dispatch"                       "REACHED: dispatch"
wantrc  "CAP5: exit 0"                                 0

# The opt-out binds the new leg exactly as it binds the credit leg — and the line must not promise
# a deferral the gates below will not perform: with a healthy balance there is no credit floor to
# catch this ride, so "strict wait" here means "not moved", and it dispatches onto the latched rail.
scenario "CAP6 — latch down + subscriptionFallback:false → no degrade, and the line says so honestly"
IN_SROW='{"name":"oracle","workerModel":"xiaomi/mimo-v2.5","subscriptionFallback":false}'
STUB_CAPACITY_DOWN="true"; STUB_CAPACITY_REASON="rpd"
go
wantnot "CAP6: does NOT degrade"                       "RAIL DEGRADE"
want    "CAP6: names the opt-out"                      "subscriptionFallback:false on the stack row"
want    "CAP6: does not claim a deferral it won't do"  "left to the gates below"
want    "CAP6: model unchanged"                        "STATE MODEL=xiaomi/mimo-v2.5 HARNESS=opencode RAIL=openrouter"
want    "CAP6: reaches dispatch (healthy balance)"     "REACHED: dispatch"
wantrc  "CAP6: exit 0"                                 0

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
