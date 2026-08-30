#!/usr/bin/env bash
# slo-teeth-replay — behavioural pin for the homelab#831 FU-104 error-budget teeth gate.
#
#   bash agents/slo-teeth-replay.sh     # or: devbox run -- bash agents/slo-teeth-replay.sh
#
# WHY THIS EXISTS. On a stack whose error budget is BURNT the primary edge path (github-exporter
# POST → Argo Events Sensor → review WorkflowTemplate → reviewer-session.sh) still dispatched a
# review, still collected the approving verdict, and auto-merge still fired — because the teeth
# lived in the reflex tick alone (review-reflex.sh), and the edge path never read them. Exactly
# the homelab#204 shape one lane over.
#
# That is why the assertion here is not "the reflex tick filters" but "NEITHER PATH DISPATCHES".
# A pin that only exercises the reflex tick would have been GREEN on the morning of the incident.
# §2 replays the edge path (reviewer-session.sh, the site that needs the fix) and §3 the tick;
# both must refuse on a burnt stack.
#
# WHAT IT RUNS. The gate blocks are EXTRACTED at run time from the shipped scripts by the
# `>>>REPLAY:<name>>>>` sentinels, never transcribed:
#   slo-teeth-gate     agents/reviewer-session.sh — the shell guard every dispatch site passes through
#   slo-teeth-filter   agents/review-reflex.sh    — the tick's repo filter + its empty-set early exit
# agents/slo-teeth.sh itself is run WHOLE (it IS the shared read; there is nothing to slice).
#
# THE SEAMS:
#   • `curl` is a stub on $PATH serving the Prometheus query, so the metric shapes are exact:
#     a burnt stack, no burnt stacks, and unreachable Prometheus. $STUB_PROM selects the shape:
#       burnt     → one burnt stack (platform), one burnt repo per stack
#       clear     → no results (empty data.result)
#       fail      → curl exits non-zero (Prometheus unreachable)
#   • any `curl` call that is not the Prometheus query aborts the harness
#   • no network, no cluster, no credentials. Runs in about a second.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION="${SESSION:-$HERE/reviewer-session.sh}"
REFLEX="${REFLEX:-$HERE/review-reflex.sh}"
SLOTEETH="${SLOTEETH:-$HERE/slo-teeth.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
CALLS="$TMP/calls.log"; : > "$CALLS"

command -v jq >/dev/null 2>&1 || { echo "slo-teeth-replay: needs jq (devbox run -- bash $0)"; exit 2; }
command -v awk >/dev/null 2>&1 || { echo "slo-teeth-replay: needs awk"; exit 2; }
for f in "$SESSION" "$REFLEX" "$SLOTEETH"; do
  [ -f "$f" ] || { echo "slo-teeth-replay: missing $f" >&2; exit 2; }
done

# ── the blocks under test, straight out of the shipped scripts ──────────────────────────────────
extract() {   # extract <marker-name> <file> → stdout; exit 3 if either sentinel is missing
  awk -v n="$1" '
    { line=$0; sub(/^[ \t]+/, "", line) }
    line == "# >>>REPLAY:" n ">>>" { inb=1; saw_open=1; next }
    line == "# <<<REPLAY:" n "<<<" { inb=0; saw_close=1; next }
    inb { print }
    END { if (!saw_open || !saw_close) exit 3 }
  ' "$2"
}
extract slo-teeth-gate   "$SESSION" > "$TMP/block.gate.sh"   || { echo "slo-teeth-replay: sentinel >>>REPLAY:slo-teeth-gate>>> missing from $SESSION"; exit 3; }
extract slo-teeth-filter "$REFLEX"  > "$TMP/block.filter.sh" || { echo "slo-teeth-replay: sentinel >>>REPLAY:slo-teeth-filter>>> missing from $REFLEX"; exit 3; }
for b in gate filter; do
  [ -s "$TMP/block.$b.sh" ] || { echo "slo-teeth-replay: block '$b' extracted EMPTY." >&2; exit 3; }
done

# ── stubs ───────────────────────────────────────────────────────────────────────────────────────
cat > "$BIN/curl" <<'EOF'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$CALLS"
_args="$*"
case "$_args" in
  */api/v1/query*) ;;
  *) echo "slo-teeth-replay: UNEXPECTED curl call (not a Prometheus query): curl $*" >&2; exit 9;;
esac
case "${STUB_PROM:-clear}" in
  burnt)
    # One burnt stack: platform
    printf '{"status":"success","data":{"resultType":"vector","result":[{"metric":{"stack":"platform"},"value":[1234567890,"1"]}]}}'
    exit 0;;
  clear)
    # No burnt stacks
    printf '{"status":"success","data":{"resultType":"vector","result":[]}}'
    exit 0;;
  fail)
    # Prometheus unreachable
    printf 'curl: (7) Failed to connect to 192.168.40.13 port 9090: Connection refused' >&2
    exit 7;;
  *)
    echo "slo-teeth-replay: UNEXPECTED STUB_PROM value: ${STUB_PROM}" >&2; exit 9;;
esac
EOF
chmod +x "$BIN/curl"

# ── the composed replays ────────────────────────────────────────────────────────────────────────
# The gate: reviewer-session.sh's variables at the point the block runs. PROJECT/PR come from its
# argv; HERE is the agents dir it resolves at the top. "REACHED: dispatch" stands in for everything
# downstream of the guard.
{
  cat <<'PRE'
set -euo pipefail
HERE="$IN_HERE"; PROJECT="$IN_PROJECT"; PR="$IN_PR"
PRE
  cat "$TMP/block.gate.sh"
  cat <<'POST'
echo "REACHED: dispatch"
POST
} > "$TMP/gate.sh"

# The tick: `REPOS` is the space-separated repo list the teeth filter, `log()` the reflex's own
# timestamped printer, `HERE` the agents dir. The block can exit 0 (empty set) — that IS the
# behaviour under test.
{
  cat <<'PRE'
set -euo pipefail
HERE="$IN_HERE"; REPOS="$IN_REPOS"
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
PRE
  cat "$TMP/block.filter.sh"
  cat <<'POST'
printf 'KEPT %s\n' "$REPOS"
echo "REACHED: dispatch"
POST
} > "$TMP/tick.sh"

for s in gate tick; do
  bash -n "$TMP/$s.sh" || { echo "slo-teeth-replay: composed $s.sh is not valid shell — a block boundary is wrong." >&2; exit 1; }
done

# ── helpers ─────────────────────────────────────────────────────────────────────────────────────
_go() {   # _go <gate|tick|teeth> [args…]
  _what="$1"; shift
  case "$_what" in
    teeth) CALLS="$CALLS" STUB_PROM="$STUB_PROM" PATH="$BIN:$PATH" \
              bash "$SLOTEETH" "$@" > "$TMP/out.txt" 2> "$TMP/err.txt";;
    gate)  CALLS="$CALLS" STUB_PROM="$STUB_PROM" PATH="$BIN:$PATH" \
              IN_HERE="$HERE" IN_PROJECT="${1:-agent-runtime}" IN_PR="${2:-57}" \
              bash "$TMP/gate.sh" > "$TMP/out.txt" 2> "$TMP/err.txt";;
    tick)  CALLS="$CALLS" STUB_PROM="$STUB_PROM" PATH="$BIN:$PATH" \
              IN_HERE="$HERE" IN_REPOS="$1" \
              bash "$TMP/tick.sh" > "$TMP/out.txt" 2> "$TMP/err.txt";;
  esac
  RC=$?; OUT="$(cat "$TMP/out.txt")"; ERR="$(cat "$TMP/err.txt")"
}
reads() { awk '/query/' "$CALLS" | wc -l | tr -d ' '; }

# ── assertions ──────────────────────────────────────────────────────────────────────────────────
PASS=0; FAIL=0; FAILED=()
ok()       { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()      { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  \033[31m✗\033[0m %s\n       %s\n' "$1" "$2"; }
section()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
eq()       { [ "$2" = "$3" ] && ok "$1" || bad "$1" "got '$2', wanted '$3'"; }
want()     { printf '%s' "$OUT" | grep -qF -- "$2" && ok "$1" || bad "$1" "stdout lacks: $2"; }
wanterr()  { printf '%s' "$ERR" | grep -qF -- "$2" && ok "$1" || bad "$1" "stderr lacks: $2"; }
noerr()    { [ -z "$ERR" ] && ok "$1" || bad "$1" "stderr: $(printf '%s' "$ERR" | head -2)"; }
wantrc()   { [ "$RC" = "$2" ] && ok "$1" || bad "$1" "exit $RC, wanted $2 (stderr: $(printf '%s' "$ERR" | tail -1))"; }
# The two that carry the whole point.
dispatched() { printf '%s' "$OUT" | grep -qF "REACHED: dispatch" && [ "$RC" = 0 ] \
                 && ok "$1" || bad "$1" "did NOT reach dispatch (rc=$RC, stderr: $(printf '%s' "$ERR" | tail -1))"; }
refused()    { printf '%s' "$OUT" | grep -qF "REACHED: dispatch" \
                 && bad "$1" "DISPATCHED — the slo-teeth gate was bypassed (this is homelab#831)" \
                 || { [ "$RC" = 0 ] && ok "$1" || bad "$1" "refused, but with exit $RC — a guard must stand aside cleanly, not fail the pod (stderr: $(printf '%s' "$ERR" | tail -1))"; }; }

printf '\033[1mslo-teeth-replay\033[0m — homelab#831 (FU-104): every dispatch site honours error-budget burn state\n'
printf 'session: %s\nreflex:  %s\nslo-teeth: %s\n' "$SESSION" "$REFLEX" "$SLOTEETH"

# ── 1 ── THE SHARED READ ────────────────────────────────────────────────────────────────────────
section "1 — the shared read (agents/slo-teeth.sh): what burnt means"

STUB_PROM="clear"
_go teeth agent-runtime
wantrc  "P1: no burnt stacks → dispatch"                        0
noerr   "P1: silently — the ordinary path says nothing"

_go teeth agent-runtime sleep-tracking
wantrc  "P1b: multiple args → predicate on first only"          0
noerr   "P1b: ordinary path says nothing"

STUB_PROM="burnt"
_go teeth agent-runtime
wantrc  "P2: a repo in a burnt stack is REFUSED"                1
wanterr "P2: naming the repo and the stack"                     "agent-runtime"

_go teeth sleep-tracking
wantrc  "P3: a repo in a non-burnt stack still dispatches"      0
noerr   "P3: ordinary path says nothing"

_go teeth --filter agent-runtime sleep-tracking homelab oracle-fleet
eq      "P4: --filter keeps only the non-burnt repos"           "$(printf '%s' "$OUT" | tr '\n' ' ')" "sleep-tracking oracle-fleet"
wanterr "P4: and explains each drop on stderr"                  "agent-runtime"
: > "$CALLS"
_go teeth --filter agent-runtime sleep-tracking homelab oracle-fleet
eq      "P5: ONE curl call for the whole list"                  "$(reads)" "1"

# ── 2 ── FAIL-OPEN ──────────────────────────────────────────────────────────────────────────────
section "2 — Prometheus unreachable: fail-open (proceed, loudly)"

STUB_PROM="fail"
_go teeth agent-runtime
wantrc  "F1: unreachable Prometheus → proceed (fail-open)"       0
wanterr "F1: loud log naming the consequence"                    "PROMETHEUS QUERY FAILED"
wanterr "F1: naming the fail-open posture"                       "fail-open"

_go teeth --filter agent-runtime sleep-tracking homelab
eq      "F2: --filter with fail-open keeps all repos"            "$(printf '%s' "$OUT" | tr '\n' ' ')" "agent-runtime sleep-tracking homelab"
wanterr "F2: loud log on stderr"                                 "PROMETHEUS QUERY FAILED"

# ── 3 ── THE EDGE / SENSOR PATH (reviewer-session.sh, the site that was MISSING the gate) ───────
section "3 — dispatch site 1: reviewer-session.sh (the edge path that was missing the gate)"

: > "$CALLS"
STUB_PROM="burnt"
_go gate agent-runtime 57
refused  "G1: agent-runtime#57 NOT dispatched — platform stack burnt"
want     "G1: and says why"                                       "NOT dispatched — stack error budget burnt"
wanterr  "G1: the shared read's reason rides along"               "PARKED"
eq       "G1: no curl call other than the Prometheus query"       "$(awk '!/query/' "$CALLS" | wc -l | tr -d ' ')" "0"

STUB_PROM="clear"
_go gate agent-runtime 57
dispatched "G2: no burnt stacks → dispatches normally"

STUB_PROM="burnt"
_go gate sleep-tracking 8
dispatched "G3: a non-burnt stack still dispatches"

STUB_PROM="fail"
_go gate agent-runtime 57
dispatched "G4: Prometheus unreachable → dispatches (fail-open)"

# ── 4 ── THE TICK (previously had its OWN inline query) ────────────────────────────────────────
section "4 — dispatch site 2: the review-reflex tick"

: > "$CALLS"
STUB_PROM="clear"
_go tick "agent-runtime sleep-tracking snore-recorder"
want     "T1: all repos survive"                                  "KEPT agent-runtime sleep-tracking snore-recorder"
dispatched "T1: the tick proceeds to dispatch"

STUB_PROM="burnt"
_go tick "agent-runtime sleep-tracking snore-recorder"
want     "T2: the non-burnt repos survive"                        "KEPT sleep-tracking snore-recorder"
want     "T2: the parked one is dropped"                          "agent-runtime"
dispatched "T2: the tick proceeds with the remaining repos"

STUB_PROM="burnt"
_go tick "agent-runtime homelab"
refused  "T3: all-parked tick exits before dispatch"
want     "T3: saying so"                                          "no repo is clear to review this tick (all parked by slo-teeth)"

STUB_PROM="fail"
_go tick "agent-runtime sleep-tracking snore-recorder"
dispatched "T4: fail-open keeps all repos"
want     "T4: proceeding"                                         "KEPT agent-runtime sleep-tracking snore-recorder"

# ── 5 ── SOURCE ORDERING — log() defined BEFORE the slo-teeth-filter block (homelab#831 r3) ──
section "5 — source ordering: log() defined before the filter block's first call site"
_log_line="$(grep -n '^log()' "$REFLEX" | head -1 | cut -d: -f1)"
_block_line="$(grep -n '>>>REPLAY:slo-teeth-filter>>>' "$REFLEX" | head -1 | cut -d: -f1)"
if [ -n "$_log_line" ] && [ -n "$_block_line" ] && [ "$_log_line" -lt "$_block_line" ]; then
  ok "O1: log() at line $_log_line, filter sentinel at line $_block_line — ordering enforced"
else
  bad "O1: log() definition (line ${_log_line:-?}) not before filter block sentinel (line ${_block_line:-?})" \
      "if log() is moved below >>>REPLAY:slo-teeth-filter>>> then every stderr line from slo-teeth.sh causes 'log: command not found' under set -euo pipefail"
fi

# ── result ──────────────────────────────────────────────────────────────────────────────────────
section "result"
printf '  %s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\n\033[31mFAILED:\033[0m\n'; for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
  printf '\nA dispatch site no longer honours the error-budget burnt state, or the fail-open\n'
  printf 'posture flipped. That is homelab#831: a bot verdict + auto-merge on a burnt stack.\n'
  printf 'If the change was deliberate, update the pin in the same commit.\n'
  exit 1
fi
printf '\n\033[32mEvery dispatch site honours error-budget burnt state, from one shared read.\033[0m\n'