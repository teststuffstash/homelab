#!/usr/bin/env bash
# reviewer-optout-replay — behavioural pin for the homelab#204 reviewer-dispatch opt-out gate.
#
#   bash agents/reviewer-optout-replay.sh     # or: devbox run -- bash agents/reviewer-optout-replay.sh
#
# WHY THIS EXISTS. On 2026-08-09 08:00Z the platform stack's claim said `reviewer.enabled: false`
# and agent-runtime#57 was bot-reviewed, APPROVED and auto-merged anyway — in the same minute the
# main reflex tick logged "[agent-runtime] skipped — stack reviewer.enabled=false". The knob was
# read in ONE of three dispatch sites. Nothing was broken; a second reader simply never existed,
# and the site that worked kept printing the reassuring line while the other one merged the PR.
#
# That is why the assertion here is not "the knob works" but "NEITHER PATH DISPATCHES". A pin that
# only exercises the reflex tick would have been GREEN on the morning of the incident. §3 replays
# the perstack Sensor path (the one that actually merged #57) and §2 the tick; both must refuse.
#
# WHAT IT RUNS. The gate blocks are EXTRACTED at run time from the shipped scripts by the
# `>>>REPLAY:<name>>>>` sentinels, never transcribed — a transcribed guard pins a copy and goes
# green while the real one drifts (the same reasoning as agents/state-fp-replay.sh):
#   optout-gate     agents/reviewer-session.sh — the shell guard every dispatch site passes through
#   optout-filter   agents/review-reflex.sh    — the tick's repo filter + its empty-set early exit
# agents/reviewer-optout.sh itself is run WHOLE (it IS the shared read; there is nothing to slice).
#
# THE SEAMS:
#   • `kubectl` is a stub on $PATH serving $FIXTURE, so the claim shapes are exact:
#     `.spec.reviewer.enabled` present/false/absent, `.spec.repos[]` as objects AND as bare
#     strings. $STUB_KUBECTL selects the failure modes:
#       forbidden → the LIVE shape, verified from a worker pod 2026-08-09: a syntactically valid
#                   empty List on STDOUT, "Error from server (Forbidden)" on stderr, exit 1. A
#                   guard that trusted stdout alone would read "no stack opted out" and dispatch.
#       fail      → plain non-zero, nothing on stdout (no cluster / no kubectl)
#       garbage   → a 200 that is not JSON
#   • any `kubectl` call that is not the claims read aborts the harness — the reviewer pod create
#     is a kubectl call, so an escaping dispatch cannot pass silently.
#   • no network, no cluster, no credentials. Runs in about a second.
#
# NOT WIRED INTO CI YET — that needs `devbox.json` + `.github/workflows/ci.yaml`, both NEVER-TOUCH
# from the fixer lane (CI runs them from the PR's own branch), so the wiring follows the merge in
# the operator lane: the #133 / #184 / #199 / state-fp-replay pattern. Until then this is a manual
# gate, and the PR that adds a FOURTH dispatch site is expected to add its row here.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION="${SESSION:-$HERE/reviewer-session.sh}"
REFLEX="${REFLEX:-$HERE/review-reflex.sh}"
OPTOUT="${OPTOUT:-$HERE/reviewer-optout.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
FIX="$TMP/claims.json"; CALLS="$TMP/calls.log"; : > "$CALLS"

command -v jq >/dev/null 2>&1 || { echo "reviewer-optout-replay: needs jq (devbox run -- bash $0)"; exit 2; }
command -v awk >/dev/null 2>&1 || { echo "reviewer-optout-replay: needs awk"; exit 2; }
for f in "$SESSION" "$REFLEX" "$OPTOUT"; do
  [ -f "$f" ] || { echo "reviewer-optout-replay: missing $f" >&2; exit 2; }
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
extract optout-gate   "$SESSION" > "$TMP/block.gate.sh"   || { echo "reviewer-optout-replay: sentinel >>>REPLAY:optout-gate>>> missing from $SESSION — the guard moved or the markers were deleted. Restore them; this harness pins homelab#204 and cannot assert on code it cannot find." >&2; exit 3; }
extract optout-filter "$REFLEX"  > "$TMP/block.filter.sh" || { echo "reviewer-optout-replay: sentinel >>>REPLAY:optout-filter>>> missing from $REFLEX — same." >&2; exit 3; }
for b in gate filter; do
  [ -s "$TMP/block.$b.sh" ] || { echo "reviewer-optout-replay: block '$b' extracted EMPTY." >&2; exit 3; }
done

# ── stubs ───────────────────────────────────────────────────────────────────────────────────────
cat > "$BIN/kubectl" <<'EOF'
#!/bin/bash
printf 'kubectl %s\n' "$*" >> "$CALLS"
_args="$*"
case "$_args" in
  *agentstacks*) ;;
  *) echo "reviewer-optout-replay: UNEXPECTED kubectl call (a dispatch escaped the gate): kubectl $*" >&2; exit 9;;
esac
case "${STUB_KUBECTL:-ok}" in
  # The live 2026-08-09 shape: valid JSON on stdout, the error on stderr, exit 1.
  forbidden) printf '{\n    "apiVersion": "v1",\n    "items": [],\n    "kind": "List"\n}\n'
             printf 'Error from server (Forbidden): agentstacks.platform.teststuff.net is forbidden\n' >&2
             exit 1;;
  fail)      printf 'The connection to the server localhost:8080 was refused\n' >&2; exit 1;;
  garbage)   printf 'upstream connect error or disconnect/reset before headers\n'; exit 0;;
esac
cat "$FIXTURE"
EOF
chmod +x "$BIN"/*

# ── the composed replays, with every bridge line named ──────────────────────────────────────────
# The gate: reviewer-session.sh's variables at the point the block runs. PROJECT/PR come from its
# argv; HERE is the agents dir it resolves at the top. "REACHED: dispatch" stands in for everything
# downstream of the guard — the head-sha probe, the latch, the pod create.
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

# The tick: `REPOS` is the space-separated repo list step 0b filters, `log()` the reflex's own
# timestamped printer, `HERE` the agents dir. The block can `exit 0` (empty set) — that IS the
# behaviour under test, so nothing after it may run.
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
  bash -n "$TMP/$s.sh" || { echo "reviewer-optout-replay: composed $s.sh is not valid shell — a block boundary is wrong." >&2; exit 1; }
done

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────
# Three stacks in the live shape: platform opted OUT (the #57 claim), sleep enabled explicitly,
# oracle with no `reviewer` block at all (the XRD defaults enabled:true, and the API server
# materializes it — but an absent field must never read as an opt-out either way).
fx_base() {
  cat > "$FIX" <<'JSON'
{
  "apiVersion": "v1",
  "kind": "List",
  "items": [
    {
      "metadata": {"name": "platform"},
      "spec": {
        "reviewer": {"enabled": false, "goalModel": "sonnet"},
        "repos": [{"name": "agent-runtime"}, {"name": "agent-coordinator"}, {"name": "homelab"}, {"name": "openrouter-operator"}]
      }
    },
    {
      "metadata": {"name": "sleep"},
      "spec": {
        "reviewer": {"enabled": true},
        "repos": [{"name": "sleep-iac"}, {"name": "sleep-tracking"}, {"name": "snore-recorder"}]
      }
    },
    {
      "metadata": {"name": "oracle"},
      "spec": {
        "repos": [{"name": "oracle-fleet"}]
      }
    }
  ]
}
JSON
}
fx() { jq "$1" "$FIX" > "$FIX.new" && mv "$FIX.new" "$FIX" || { echo "reviewer-optout-replay: fixture edit failed: $1" >&2; exit 2; }; }

# ── runners ─────────────────────────────────────────────────────────────────────────────────────
STUB_KUBECTL="ok"
_go() {   # _go <gate|tick|optout> [args…]
  _what="$1"; shift
  case "$_what" in
    optout) FIXTURE="$FIX" CALLS="$CALLS" STUB_KUBECTL="$STUB_KUBECTL" PATH="$BIN:$PATH" \
              bash "$OPTOUT" "$@" > "$TMP/out.txt" 2> "$TMP/err.txt";;
    gate)   FIXTURE="$FIX" CALLS="$CALLS" STUB_KUBECTL="$STUB_KUBECTL" PATH="$BIN:$PATH" \
              IN_HERE="$HERE" IN_PROJECT="${1:-agent-runtime}" IN_PR="${2:-57}" \
              bash "$TMP/gate.sh" > "$TMP/out.txt" 2> "$TMP/err.txt";;
    tick)   FIXTURE="$FIX" CALLS="$CALLS" STUB_KUBECTL="$STUB_KUBECTL" PATH="$BIN:$PATH" \
              IN_HERE="$HERE" IN_REPOS="$1" \
              bash "$TMP/tick.sh" > "$TMP/out.txt" 2> "$TMP/err.txt";;
  esac
  RC=$?; OUT="$(cat "$TMP/out.txt")"; ERR="$(cat "$TMP/err.txt")"
}
reads() { awk '/agentstacks/' "$CALLS" | wc -l | tr -d ' '; }

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
# The two that carry the whole point. DISPATCHED is spelled as the absence of the downstream
# marker AND a zero exit — a guard that crashed instead of refusing is not a gate, it is an outage.
dispatched()   { printf '%s' "$OUT" | grep -qF "REACHED: dispatch" && [ "$RC" = 0 ] \
                   && ok "$1" || bad "$1" "did NOT reach dispatch (rc=$RC, stderr: $(printf '%s' "$ERR" | tail -1))"; }
refused()      { printf '%s' "$OUT" | grep -qF "REACHED: dispatch" \
                   && bad "$1" "DISPATCHED — the opt-out was bypassed (this is homelab#204)" \
                   || { [ "$RC" = 0 ] && ok "$1" || bad "$1" "refused, but with exit $RC — a guard must stand aside cleanly, not fail the pod (stderr: $(printf '%s' "$ERR" | tail -1))"; }; }

printf '\033[1mreviewer-optout-replay\033[0m — homelab#204: every dispatch site honors reviewer.enabled\n'
printf 'session: %s\nreflex:  %s\noptout:  %s\n' "$SESSION" "$REFLEX" "$OPTOUT"
printf 'condition under replay: platform claim reviewer.enabled=false; agent-runtime#57 approved+merged anyway\n'
fx_base

# ── 1 ── THE SHARED READ ────────────────────────────────────────────────────────────────────────
section "1 — the shared read (agents/reviewer-optout.sh): what the knob means"
_go optout agent-runtime
wantrc  "P1: a repo in an opted-out stack is REFUSED"            1
wanterr "P1: naming the repo, the stack and the field"           "[agent-runtime] skipped — stack 'platform' set reviewer.enabled=false"
_go optout sleep-tracking
wantrc  "P2: reviewer.enabled=true dispatches"                   0
noerr   "P2: silently — the ordinary path says nothing"
_go optout oracle-fleet
wantrc  "P3: an ABSENT reviewer block is not an opt-out"         0
_go optout some-unclaimed-repo
wantrc  "P4: a repo in NO claim is not an opt-out either"        0
noerr   "P4: (fail-closed is for UNKNOWN state, not unmanaged repos)"

fx '(.items[] | select(.metadata.name=="platform") | .spec.repos) = ["agent-runtime","homelab"]'
_go optout agent-runtime
wantrc  "P5: bare-string repo entries read the same as {name:}"  1
fx_base
fx '(.items[] | select(.metadata.name=="platform") | .spec.reviewer.enabled) = null'
_go optout agent-runtime
wantrc  "P6: enabled:null is NOT false — dispatch"               0
fx_base

_go optout --filter agent-runtime sleep-tracking homelab oracle-fleet
eq      "P7: --filter keeps exactly the enabled repos"           "$(printf '%s' "$OUT" | tr '\n' ' ')" "sleep-tracking oracle-fleet"
wanterr "P7: and explains each drop on stderr, not stdout"       "[homelab] skipped"
: > "$CALLS"; _go optout --filter agent-runtime sleep-tracking homelab oracle-fleet
eq      "P8: ONE cluster read for the whole list"                "$(reads)" "1"

# ── 2 ── THE TICK (the site that was ALREADY right — it must stay right) ────────────────────────
section "2 — dispatch site 1: the review-reflex tick"
_go tick "agent-runtime sleep-tracking snore-recorder"
want     "T1: the enabled repos survive"                          "KEPT sleep-tracking snore-recorder"
want     "T1: and the opted-out one is dropped"                   "[agent-runtime] skipped"
dispatched "T1: the tick proceeds to its dispatch loop"
_go tick "agent-runtime homelab"
refused  "T2: an ALL-opted-out tick exits before the dispatch loop"
want     "T2: saying so"                                          "no repo is clear to review this tick"

# ── 3 ── THE PERSTACK / SENSOR PATH (the site that merged #57) ──────────────────────────────────
# This is the row that would have been red on 2026-08-09 and green in every earlier pin.
section "3 — dispatch sites 2+3: reviewer-session.sh, the choke point (the #57 path)"
_go gate agent-runtime 57
refused  "S1: agent-runtime#57 is NOT dispatched (THE specimen)"
want     "S1: and says why, with the issue"                       "NOT dispatched — reviewer disabled for this stack (homelab#204)"
wanterr  "S1: the shared read's reason rides along"               "reviewer.enabled=false"
eq       "S1: no kubectl call other than the claims read"         "$(awk '!/agentstacks/' "$CALLS" | wc -l | tr -d ' ')" "0"
_go gate sleep-tracking 8
dispatched "S2: an enabled stack's PR still dispatches"
_go gate homelab 204
refused  "S3: every repo of the opted-out stack, not just the first"
_go gate oracle-fleet 234
dispatched "S4: a stack with no reviewer block is unaffected"

# The global `review` WorkflowTemplate defers on `graduated`, which is a DIFFERENT field for a
# DIFFERENT purpose — it is why site 3 looked safe (platform is graduated, so it never fired).
# A NON-graduated stack with reviewer.enabled=false must still be refused, at the choke point.
fx '.items += [{"metadata":{"name":"fledgling"},"spec":{"reviewer":{"enabled":false},"repos":[{"name":"new-thing"}]}}]'
_go gate new-thing 1
refused  "S5: a NON-graduated opted-out stack is refused too (graduated ≠ the knob)"
fx_base

# ── 4 ── FAIL-CLOSED. The pre-decided posture, and the half that was latent in the tick. ────────
section "4 — an unreadable claims read SKIPS (fail-closed) on every path"
for mode in forbidden fail garbage; do
  STUB_KUBECTL="$mode"
  _go optout agent-runtime
  wantrc  "F-$mode: the shared read refuses"                      1
  wanterr "F-$mode: loudly, naming the consequence"               "PROBE-FAILED"
  _go gate sleep-tracking 8
  refused "F-$mode: an ENABLED repo is skipped too — unknown is not permission"
  _go tick "sleep-tracking snore-recorder"
  refused "F-$mode: the tick stops rather than reviewing the world"
  want    "F-$mode: and says the claims read failed"              "no repo is clear to review this tick"
done
STUB_KUBECTL="ok"

# The one that reads as over-engineering until you run it: `kubectl get -o json` on a Forbidden
# prints a VALID empty List to stdout and exits 1. Trusting the payload alone yields "no stack
# opted out" — fail-OPEN, silently, which is the bug this file exists to keep closed.
STUB_KUBECTL="forbidden"
_go optout --filter agent-runtime sleep-tracking
eq       "F1: a Forbidden read keeps NO repo (not 'none opted out')" "$(printf '%s' "$OUT" | tr -d '\n')" ""
STUB_KUBECTL="ok"
_go optout --filter agent-runtime sleep-tracking
eq       "F1: (control) a readable cluster keeps the enabled one"    "$(printf '%s' "$OUT" | tr -d '\n')" "sleep-tracking"

# ── result ──────────────────────────────────────────────────────────────────────────────────────
section "result"
printf '  %s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\n\033[31mFAILED:\033[0m\n'; for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
  printf '\nA reviewer-dispatch site no longer honors the operator'"'"'s reviewer.enabled optout, or the\n'
  printf 'fail-closed posture flipped. That is homelab#204: a bot verdict + auto-merge on a PR whose\n'
  printf 'only intended gate was a human read. If the change was deliberate, update the row here in\n'
  printf 'the same commit.\n'
  exit 1
fi
printf '\n\033[32mEvery reviewer-dispatch site honors reviewer.enabled, from one shared read.\033[0m\n'
