#!/usr/bin/env bash
# state-fp-replay — behavioural pin for the homelab#198 PR-state-fingerprint debounce in
# agents/coordinator-scan.sh.
#
#   bash agents/state-fp-replay.sh          # or: devbox run -- bash agents/state-fp-replay.sh
#
# WHY THIS EXISTS (homelab#201). #198 shipped CURRENCY for the level-triggered clauses (arbitrate,
# ci-red, and merge-conflict since homelab#595): a condition that holds over unchanged PR state is
# a report line, not a fresh unit. It was verified by a throwaway sentinel-extraction harness — the
# PR#234 sequence plus the fingerprint stability/movement table and the fail-open edges — and that
# harness was never committed, so the guard shipped pinned by nothing. The failure mode it leaves open is quiet and
# expensive: a fingerprint that MOVES ON ITS OWN (a jq field added to the hash input, a sort
# dropped, `.comments` accidentally entering the hash) silently restores the five-rides-on-frozen-
# state churn #198 removed, and the only thing that would notice is the FU-069 anomaly breaker —
# after four opus rides have already been spent to conclude nothing. PR #200's Verification section
# is the spec; this file is that section, retained and executable.
#
# THE ONE THAT MATTERS MOST. The debounce marker is itself a PR comment, and the coordinator's own
# "state is identical, escalation stands" ruling is another. If comments ever enter the hash, the
# guard disarms itself on the very ride it is debouncing — it would look like it works (tick 1
# debounces nothing) and fail open forever after. Rows S3/S2 are that invariant, and the sequence
# in §5 exercises it end-to-end with the marker written by the SHIPPED writer.
#
# WHAT IT RUNS. Five blocks are EXTRACTED FROM agents/coordinator-scan.sh at run time by the
# `>>>REPLAY:<name>>>>` sentinels, never transcribed — a transcribed predicate pins a copy of the
# scan, which is worse than no pin because it goes green while the scan drifts:
#   state-fp-jq      the two jq programs (STATE_FP_JQ, STATE_FP_LAST_JQ)
#   state-fp-pair    pr_state_fp_pair() — one probe, both halves
#   arbitrate-gate   the whole arbitrate clause loop (label select → debounce → unit)
#   ci-red-gate      the currency check inside the ci-red DISPATCH branch
#   dispatch-marker  the marker WRITE, at dispatch time, in the priority loop
# They are composed into four small scripts, each opening with the scan's own `set -euo pipefail`
# so "the sequence survives -e" is asserted by every row rather than claimed once.
#
# THE SEAMS, all of them:
#   • `gh` is a stub on $PATH: `pr view` serves $FIXTURE (a PR-probe payload this harness edits with
#     jq between ticks), `pr comment` APPENDS to that same fixture. So the marker the shipped writer
#     writes is the marker the shipped reader reads — the round trip is closed, not assumed. Every
#     call lands in $CALLS. No network, no credentials, no cluster.
#   • $STUB_NOW is the harness clock for appended comments (createdAt), stepped one minute per
#     write — the newest-marker rule needs a deterministic order, and `date` in a fast loop gives
#     ties. Nothing under test reads it.
#   • The bridge lines in each composition are named inline; they are scan variables (`slug`,
#     `repo`, `prsjson`, `orphans`, `units`, `head8`, `ORG`, `urepo`, `uclause`, `uitem`) the
#     enclosing loops set, never harness inventions.
# Runs in about a second.
#
# WIRED INTO CI as the required `state-fp-replay` step (`devbox run state-fp-replay`, ci.yaml) — the
# operator-lane follow-up the original note here anticipated, landed. A PR that changes the
# fingerprint's inputs must update the rows here in the same PR, same posture as
# agents/rail-degrade-replay.sh and agents/footprint-test.sh.
#
# ALSO REGISTERED as the first fixture of the clause-replay harness
# (`agents/replay/fixtures/state-fp/`, homelab#206) — so `bash agents/replay/run.sh` runs it beside
# every other clause pin. Registration only: this file, its devbox script and its required status
# are unchanged, and the harness runs it rather than rewriting it. Its own extract()/stub/assertion
# copies fold onto `agents/replay/stubs/` later, when a fixture in `actions` mode has ridden a few
# clause changes (ADR-103 — backfill follows fix-density, not big-bang).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="${SCAN:-$HERE/coordinator-scan.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
FIX="$TMP/pr.json"; PRSJSON="$TMP/prs.json"; CALLS="$TMP/calls.log"; : > "$CALLS"

command -v jq >/dev/null 2>&1 || { echo "state-fp-replay: needs jq (devbox run -- bash $0)"; exit 2; }
command -v awk >/dev/null 2>&1 || { echo "state-fp-replay: needs awk"; exit 2; }
REAL_SHA="$(command -v sha256sum || true)"
[ -n "$REAL_SHA" ] || { echo "state-fp-replay: needs sha256sum (coreutils) — the hasher under test"; exit 2; }

# ── the blocks under test, straight out of the scan ─────────────────────────────────────────────
# Leading whitespace is trimmed before the sentinel comparison: two of these blocks live deep inside
# the scan's per-repo loops, and a column-0 marker in the middle of an indented `if` would read as a
# mistake to the next person editing it.
extract() {   # extract <marker-name> → stdout; exit 3 if either sentinel is missing
  awk -v n="$1" '
    { line=$0; sub(/^[ \t]+/, "", line) }
    line == "# >>>REPLAY:" n ">>>" { inb=1; saw_open=1; next }
    line == "# <<<REPLAY:" n "<<<" { inb=0; saw_close=1; next }
    inb { print }
    END { if (!saw_open || !saw_close) exit 3 }
  ' "$SCAN"
}
for b in state-fp-jq state-fp-pair arbitrate-gate ci-red-gate dispatch-marker; do
  extract "$b" > "$TMP/block.$b.sh" || {
    echo "state-fp-replay: sentinel >>>REPLAY:$b>>> / <<<REPLAY:$b<<< missing from $SCAN." >&2
    echo "  The block moved or the markers were deleted. Restore them around the block — this" >&2
    echo "  harness pins homelab#198 and cannot assert on code it cannot find." >&2
    exit 3; }
  [ -s "$TMP/block.$b.sh" ] || { echo "state-fp-replay: block '$b' extracted EMPTY from $SCAN." >&2; exit 3; }
done

# ── stubs ───────────────────────────────────────────────────────────────────────────────────────
cat > "$BIN/gh" <<'EOF'
#!/bin/bash
# Fixture-backed gh. `pr view` serves the payload; `pr comment` appends to it, so a marker written
# by the scan's dispatch block is visible to the scan's reader on the next tick — the loop the
# whole debounce rests on. $STUB_GH selects the failure modes the guarded probe must survive:
#   fail     → non-zero exit (403/404/network; the `|| fp_probe=''` path)
#   body404  → gh printing its error to STDOUT and exiting 0 (the shape PR#200 names; only the
#              `jq -e .` guard stands between this and a fingerprint hashed from an error string)
#   garbage  → a 200 that is not JSON at all
printf '%s\n' "gh $*" >> "$CALLS"
[ "$1" = "pr" ] || { echo "state-fp-replay: unexpected gh call: gh $*" >&2; exit 9; }
case "$2" in
  view)
    case "${STUB_GH:-ok}" in
      fail)    printf 'gh: Not Found (HTTP 404)\n' >&2; exit 1;;
      body404) printf 'gh: Not Found (HTTP 404)\n';     exit 0;;
      garbage) printf 'upstream connect error or disconnect/reset before headers\n'; exit 0;;
    esac
    cat "$FIXTURE"; exit 0;;
  comment)
    [ "${STUB_GH_COMMENT:-ok}" = "refuse" ] && {
      printf 'gh: Resource not accessible by integration (HTTP 403)\n' >&2; exit 1; }
    _body=""; _prev=""
    for a in "$@"; do [ "$_prev" = "--body" ] && _body="$a"; _prev="$a"; done
    jq --arg b "$_body" --arg t "${STUB_NOW:-2026-08-09T03:00:00Z}" \
       '.comments += [{"body":$b,"createdAt":$t}]' "$FIXTURE" > "$FIXTURE.new" && mv "$FIXTURE.new" "$FIXTURE"
    exit 0;;
esac
exit 0
EOF
cat > "$BIN/sha256sum" <<EOF
#!/bin/bash
# Passthrough to the real hasher, except when \$STUB_HASH says it is missing. The scan's comment
# claims a missing hasher degrades to "no fingerprint" rather than aborting the stack's whole scan —
# an untested claim about a \`set -e\` interaction, which is the class that gets this wrong.
[ "\${STUB_HASH:-ok}" = "missing" ] && { echo "bash: sha256sum: command not found" >&2; exit 127; }
exec "$REAL_SHA" "\$@"
EOF
chmod +x "$BIN"/*

# ── the composed replays: scan blocks in scan order, with every bridge line named ───────────────
{
  cat <<'PRE'
set -euo pipefail
PRE
  cat "$TMP/block.state-fp-jq.sh"
  cat "$TMP/block.state-fp-pair.sh"
  cat <<'POST'
# Observation point, not scan code.
pair="$(pr_state_fp_pair "$IN_SLUG" "$IN_PR" "${IN_UCLAUSE:-}")"
printf 'PAIR %s\n' "$pair"
printf 'CUR %s\n'  "${pair%%|*}"
printf 'PREV %s\n' "${pair#*|}"
echo "REACHED: end"
POST
} > "$TMP/probe.sh"

{
  cat <<'PRE'
set -euo pipefail
PRE
  cat "$TMP/block.state-fp-jq.sh"
  cat "$TMP/block.state-fp-pair.sh"
  cat <<'BRIDGE'
# ── bridge ── the per-repo loop variables the arbitrate clause reads and writes. `prsjson` is the
# `gh pr list` payload the scan already holds; `repo` is the short name that rides in a unit line,
# `slug` the ORG/name the probe takes.
slug="$IN_SLUG"; repo="$IN_REPO"; prsjson="$(cat "$IN_PRSJSON")"; orphans=""; units=""
# ── stub ── the scan accumulates rows during a pass and flushes one POST per (tick, namespace),
# so a harness running one extracted block has no flush to assert on; the function is inert here.
item_class_push() { :; }
BRIDGE
  cat "$TMP/block.arbitrate-gate.sh"
  cat <<'POST'
printf 'UNITS %s\n'   "$units"
printf 'ORPHANS %s\n' "$orphans"
echo "REACHED: end"
POST
} > "$TMP/arbitrate.sh"

{
  cat <<'PRE'
set -euo pipefail
PRE
  cat "$TMP/block.state-fp-jq.sh"
  cat "$TMP/block.state-fp-pair.sh"
  cat <<'BRIDGE'
# ── bridge ── the ci-red clause's per-red-PR loop, one PR wide. `head8` is the short head sha the
# clause computed above the extracted block and quotes in its report line; the `for` is the scan's
# own loop, kept because the block `continue`s out of it — that `continue` (before the 2/repo/scan
# dispatch cap, so a debounced PR never spends a slot a live red PR could use) is half the point.
slug="$IN_SLUG"; repo="$IN_REPO"; head8="$IN_HEAD8"; orphans=""
for u in "$IN_PR"; do
BRIDGE
  cat "$TMP/block.ci-red-gate.sh"
  cat <<'POST'
  echo "DISPATCH ci-red|${repo}|pr-${u}"
done
printf 'ORPHANS %s\n' "$orphans"
echo "REACHED: end"
POST
} > "$TMP/cired.sh"

{
  cat <<'PRE'
set -euo pipefail
PRE
  cat "$TMP/block.state-fp-jq.sh"
  cat "$TMP/block.state-fp-pair.sh"
  cat <<'BRIDGE'
# ── bridge ── the dispatch loop's variables for the ONE unit the priority loop picked. Run as its
# own step, after the clause emitted, because that separation IS the design (#198 point 2): marking
# at emission would retire a unit that lost the race and never rode.
ORG="$IN_ORG"; urepo="$IN_REPO"; uclause="$IN_UCLAUSE"; uitem="$IN_UITEM"
BRIDGE
  cat "$TMP/block.dispatch-marker.sh"
  cat <<'POST'
echo "REACHED: end"
POST
} > "$TMP/mark.sh"

for s in probe arbitrate cired mark; do
  bash -n "$TMP/$s.sh" || { echo "state-fp-replay: composed $s.sh is not valid shell — a block boundary is wrong." >&2; exit 1; }
done

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────
ORGN="teststuffstash"; REPO="oracle-fleet"; SLUG="${ORGN}/${REPO}"; PR="234"; HEAD8="aaaaaaaa"
CLOCK=0
_now() { CLOCK=$((CLOCK+1)); printf '2026-08-09T03:%02d:00Z' "$CLOCK"; }

# The live 2026-08-09 shape: armed, red `e2e`, a stale CHANGES_REQUESTED nobody has moved, prose on
# the thread. This is the state five coordinator rides read in thirty minutes.
fx_base() {
  cat > "$FIX" <<'JSON'
{
  "headRefOid": "aaaaaaaa11111111111111111111111111111111",
  "reviewDecision": "CHANGES_REQUESTED",
  "statusCheckRollup": [
    {"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-08-09T01:00:00Z"},
    {"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-08-09T01:00:00Z"},
    {"__typename":"CheckRun","name":"manifest-lint","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-08-09T01:00:00Z"}
  ],
  "reviews": [
    {"state":"CHANGES_REQUESTED","submittedAt":"2026-08-08T22:10:00Z"},
    {"state":"COMMENTED","submittedAt":"2026-08-09T01:00:00Z"}
  ],
  "comments": [
    {"body":"the escalation stands — a human is the next mover","createdAt":"2026-08-09T02:00:00Z"}
  ],
  "commits": [
    {"oid":"bbbbbbbb22222222222222222222222222222222","messageHeadline":"Merge branch 'master' into fix/something"},
    {"oid":"aaaaaaaa11111111111111111111111111111111","messageHeadline":"fix: resolve the actual issue"}
  ]
}
JSON
  printf '[{"number":%s,"labels":[{"name":"agent/arbitrate"}]}]\n' "$PR" > "$PRSJSON"
}
fx() {  # fx '<jq program>' — edit the fixture in place
  jq "$1" "$FIX" > "$FIX.new" && mv "$FIX.new" "$FIX" || { echo "state-fp-replay: fixture edit failed: $1" >&2; exit 2; }
}

# ── the runners ─────────────────────────────────────────────────────────────────────────────────
STUB_GH="ok"; STUB_GH_COMMENT="ok"; STUB_HASH="ok"; UITEM="pr-${PR}"; UCLAUSE=""
_go() {
  FIXTURE="$FIX" CALLS="$CALLS" STUB_GH="$STUB_GH" STUB_GH_COMMENT="$STUB_GH_COMMENT" \
  STUB_NOW="$(_now)" STUB_HASH="$STUB_HASH" \
  IN_SLUG="$SLUG" IN_ORG="$ORGN" IN_REPO="$REPO" IN_PR="$PR" IN_HEAD8="$HEAD8" \
  IN_PRSJSON="$PRSJSON" IN_UCLAUSE="$UCLAUSE" IN_UITEM="$UITEM" \
  PATH="$BIN:$PATH" \
    bash "$TMP/$1.sh" > "$TMP/out.txt" 2> "$TMP/err.txt"
  RC=$?; OUT="$(cat "$TMP/out.txt")"; ERR="$(cat "$TMP/err.txt")"
}
field() { printf '%s\n' "$OUT" | awk -v k="$1" '$1==k{sub("^" k " ?",""); print; exit}'; }
fp()    { _go probe; field CUR; }
prev()  { _go probe; field PREV; }

# ── assertions ──────────────────────────────────────────────────────────────────────────────────
PASS=0; FAIL=0; FAILED=()
ok()      { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()     { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  \033[31m✗\033[0m %s\n       %s\n' "$1" "$2"; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }
same()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "the fingerprint MOVED: $2 → $3"; }
differs() { [ "$2" != "$3" ] && ok "$1" || bad "$1" "the fingerprint did NOT move (both '$2')"; }
eq()      { [ "$2" = "$3" ] && ok "$1" || bad "$1" "got '$2', wanted '$3'"; }
nonempty(){ [ -n "$2" ] && ok "$1" || bad "$1" "empty, wanted a value"; }
isempty() { [ -z "$2" ] && ok "$1" || bad "$1" "got '$2', wanted empty"; }
want()    { printf '%s' "$OUT" | grep -qF -- "$2" && ok "$1" || bad "$1" "stdout lacks: $2"; }
wantnot() { printf '%s' "$OUT" | grep -qF -- "$2" && bad "$1" "stdout has: $2" || ok "$1"; }
wanterr() { printf '%s' "$ERR" | grep -qF -- "$2" && ok "$1" || bad "$1" "stderr lacks: $2"; }
noerr()   { [ -z "$ERR" ] && ok "$1" || bad "$1" "stderr: $(printf '%s' "$ERR" | head -2)"; }
wantrc()  { [ "$RC" = "$2" ] && ok "$1" || bad "$1" "exit $RC, wanted $2 (stderr: $(printf '%s' "$ERR" | tail -1))"; }
survives(){ printf '%s' "$OUT" | grep -qF "REACHED: end" && [ "$RC" = 0 ] \
              && ok "$1: runs to completion under set -euo pipefail" \
              || bad "$1: runs to completion under set -euo pipefail" "rc=$RC, stderr: $(printf '%s' "$ERR" | tail -1)"; }
markers() { jq '[.comments[]? | select((.body // "") | test("state-fp:[0-9a-f]{6,64}"))] | length' "$FIX"; }
newest()  { jq -r '.comments[-1].body // ""' "$FIX"; }   # what the last write actually put on the thread
wantnew() { newest | grep -qF -- "$2" && ok "$1" || bad "$1" "the newest comment body lacks: $2"; }

printf '\033[1mstate-fp-replay\033[0m — homelab#198 debounce, PR #200'"'"'s verification table replayed\n'
printf 'scan: %s\n' "$SCAN"
printf 'condition under replay: oracle-fleet PR#234, five rides in ~30min on byte-identical state\n'

# ── 1 ── THE FINGERPRINT IS STABLE across everything that is not the state a ride reads ─────────
section "1 — stability: only head / checks / reviewDecision / newest verdict may move the hash"
fx_base; BASE="$(fp)"
nonempty "S0: the base state fingerprints at all"    "$BASE"
_go probe; survives "S0"; noerr "S0: no stderr on the healthy path"
eq       "S0: 12 hex chars (sha256, truncated)"      "$(printf '%s' "$BASE" | grep -cE '^[0-9a-f]{12}$')" "1"

fx '.statusCheckRollup |= reverse'
same     "S1: stable across check RE-ORDERING (sort, not gh order)" "$BASE" "$(fp)"

fx '.comments += [{"body":"⏳ arbitrate DEBOUNCED — state is identical, escalation stands","createdAt":"2026-08-09T02:30:00Z"}]'
same     "S2: stable when the coordinator adds its own ruling prose" "$BASE" "$(fp)"

# THE self-disarm test, with the SHIPPED writer: the marker is a comment, and a comment that moved
# the hash would re-open the gate on the very tick it just closed.
BASE_ARB="$(UCLAUSE=arbitrate fp)"
UCLAUSE=arbitrate _go mark
same     "S3: stable after the real marker comment is written"       "$BASE_ARB" "$(UCLAUSE=arbitrate fp)"
eq       "S3: and the recorded hash round-trips to the current one"  "$(prev)" "$BASE_ARB"

fx '.reviews += [{"state":"COMMENTED","submittedAt":"2026-08-09T09:00:00Z"}]'
same     "S4: a COMMENTED review is not a verdict — hash unmoved"    "$BASE" "$(fp)"

# ── 2 ── AND IT MOVES on each of the four inputs, or the debounce is a permanent off switch ─────
section "2 — movement: every input a ride would read must re-open the gate"
fx_base
fx '.headRefOid = "bbbbbbbb2222222222222222222222222222222"'
differs  "M1: a new head sha moves it"                               "$BASE" "$(fp)"
fx_base
fx '(.statusCheckRollup[] | select(.name=="ci") | .conclusion) = "FAILURE"'
differs  "M2: a check flipping conclusion moves it"                  "$BASE" "$(fp)"
fx_base
fx '(.statusCheckRollup[] | select(.name=="e2e")) |= (.status="IN_PROGRESS" | .conclusion=null)'
INFLIGHT="$(fp)"
differs  "M3: a check going in-flight moves it"                      "$BASE" "$INFLIGHT"
fx '(.statusCheckRollup[] | select(.name=="e2e")) |= (.status="QUEUED")'
same     "M3b: QUEUED and IN_PROGRESS both normalize to PENDING"     "$INFLIGHT" "$(fp)"
fx_base
fx '.reviewDecision = "APPROVED"'
differs  "M4: reviewDecision moves it"                               "$BASE" "$(fp)"
fx_base
fx '.reviews += [{"state":"CHANGES_REQUESTED","submittedAt":"2026-08-09T10:00:00Z"}]'
differs  "M5: a NEWER verdict moves it"                              "$BASE" "$(fp)"
fx_base
fx '.statusCheckRollup += [{"__typename":"CheckRun","name":"e2e-kata","status":"COMPLETED","conclusion":"SUCCESS"}]'
differs  "M6: a check appearing moves it"                            "$BASE" "$(fp)"

# ── 3 ── SHAPES THAT MUST NOT ERROR. A jq error here yields an empty hash, which fails open — but
# quietly, and "the guard is off" is not something anyone would go looking for.
section "3 — payload shapes: legacy, in-flight, and empty must not raise"
fx_base
fx '.statusCheckRollup = [{"__typename":"StatusContext","context":"ci/legacy","state":"SUCCESS"}]'
LEGACY="$(fp)"; _go probe
nonempty "L1: legacy StatusContext entries fingerprint"              "$LEGACY"
noerr    "L1: and raise nothing on stderr"
fx '.statusCheckRollup = [{"__typename":"CheckRun","name":"ci/legacy","status":"COMPLETED","conclusion":"SUCCESS"}]'
same     "L1b: .context/.state key the same as .name/.conclusion"    "$LEGACY" "$(fp)"
fx '.statusCheckRollup = [{}]'
_go probe
nonempty "L2: a nameless rollup entry does not raise"                "$(field CUR)"
survives "L2"
printf '{}\n' > "$FIX"
_go probe
nonempty "L3: an empty object {} still fingerprints"                 "$(field CUR)"
isempty  "L3: with no recorded marker"                               "$(field PREV)"
survives "L3"

# ── 4 ── THE MARKER READ. `last` on the raw comment list would trust gh's ordering; the newest
# marker is the one the last dispatch wrote, and reading an older one debounces against state two
# rides ago — i.e. it fails CLOSED, holding a PR that has genuinely moved.
section "4 — marker read: newest by createdAt, empty when there is none"
fx_base
isempty  "K1: a prose-only thread records nothing"                   "$(prev)"
fx '.comments = [
      {"body":"🤖 `state-fp:ffffffffffff` — deterministic scan dispatching","createdAt":"2026-08-09T04:00:00Z"},
      {"body":"🤖 `state-fp:000000000000` — deterministic scan dispatching","createdAt":"2026-08-09T01:00:00Z"}
    ]'
eq       "K2: newest by createdAt wins, not array order"             "$(prev)" "ffffffffffff"
fx_base; UCLAUSE=arbitrate _go mark
eq       "K3: the shipped writer's full comment body reads back"      "$(prev)" "$BASE_ARB"
wantnew  "K3: and it explains itself to the human reading the thread" "Machine-readable debounce marker"
wantnew  "K3: naming the clause that is about to ride"               "dispatching a \`arbitrate\` unit"
fx '.comments += [{"body":"no hash here at all","createdAt":"2026-08-09T23:00:00Z"}]'
eq       "K4: later prose does not shadow the newest MARKER"         "$(prev)" "$BASE_ARB"

# ── 5 ── THE PR#234 GATE SEQUENCE, end to end, through the shipped arbitrate clause ─────────────
section "5 — the PR#234 sequence: five rides become one"
fx_base
_go arbitrate; ARB="$OUT"
printf '%s' "$ARB" | grep -qF "UNITS arbitrate|${REPO}|pr-${PR}" && ok "T1: tick 1 EMITS the arbitrate unit" \
  || bad "T1: tick 1 EMITS the arbitrate unit" "no unit line in: $ARB"
printf '%s' "$ARB" | grep -qF "DEBOUNCED" && bad "T1: and does not debounce (nothing recorded yet)" "debounced on the first tick" \
  || ok "T1: and does not debounce (nothing recorded yet)"
survives "T1"
UCLAUSE=arbitrate _go mark
eq       "T1: dispatch records exactly one marker"                   "$(markers)" "1"

# the ride runs and rules "escalation stands" — prose, and prose only
fx '.comments += [{"body":"ARBITRATE ruling: state unchanged, the escalation stands.","createdAt":"2026-08-09T05:00:00Z"}]'
_go arbitrate
want     "T2: tick 2 DEBOUNCES on unchanged state"                   "arbitrate DEBOUNCED"
want     "T2: the report line quotes the hash"                       "state-fp:${BASE_ARB}"
want     "T2: and says a human is the next mover"                    "a human (or new content) is the next mover"
wantnot  "T2: NO unit is emitted"                                    "UNITS arbitrate|"
survives "T2"

# four more identical ticks — the live churn was five rides in thirty minutes
T_EMITS=0
for _i in 1 2 3 4; do
  _go arbitrate
  printf '%s' "$OUT" | grep -qF "UNITS arbitrate|" && T_EMITS=$((T_EMITS+1))
done
eq       "T3: four further ticks on frozen state emit ZERO units"    "$T_EMITS" "0"
eq       "T3: and write no further markers"                          "$(markers)" "1"

# real movement re-arms the gate by itself — no human, no label churn.
# For the arbitrate clause, head= narrows to the newest non-merge commit (homelab#1011),
# so a pushed non-merge commit is what moves the fingerprint, not a headRefOid change alone.
fx '.commits += [{"oid":"cccccccc33333333333333333333333333333333","messageHeadline":"fix: a real pushed change"}] | .headRefOid = "cccccccc33333333333333333333333333333333"'
_go arbitrate
want     "T4: a pushed head RE-ARMS the clause"                      "UNITS arbitrate|${REPO}|pr-${PR}"
wantnot  "T4: no debounce line"                                      "DEBOUNCED"
UCLAUSE=arbitrate _go mark
eq       "T4: the new state is recorded beside the old"              "$(markers)" "2"
_go arbitrate
want     "T5: the NEWEST marker is what tick 5 debounces against"    "arbitrate DEBOUNCED"
wantnot  "T5: still no unit"                                         "UNITS arbitrate|"

# the label is what makes it a candidate at all — and agent/error (FU-069) outranks it
fx_base
printf '[{"number":%s,"labels":[{"name":"agent/arbitrate"},{"name":"agent/error"}]}]\n' "$PR" > "$PRSJSON"
_go arbitrate
wantnot  "T6: an agent/error PR is not an arbitrate candidate"       "UNITS arbitrate|"
wantnot  "T6: and is not debounce-reported either (breaker owns it)" "DEBOUNCED"

# ── 6 ── THE CI-RED LEG. Same fingerprint, different clause: it sits INSIDE the dispatch branch,
# and it must `continue` before the cap so a debounced PR never spends a live PR's slot.
# The ci-red clause uses STATE_FP_JQ_CIRED which folds each check's startedAt into the hash
# (homelab#1108), so a CI rerun changes the fingerprint. Compute a separate BASE_CIRED from the
# same fixture to assert the ci-red-specific hash.
section "6 — ci-red dispatch currency"
fx_base
UCLAUSE=ci-red _go probe; BASE_CIRED="$(field CUR)"
nonempty "R0: ci-red fingerprints with startedAt folded in"          "$BASE_CIRED"
differs  "R0: ci-red hash differs from the arbitrate hash"           "$BASE" "$BASE_CIRED"
fx_base
_go cired
want     "R1: first red tick DISPATCHES a fix round"                 "DISPATCH ci-red|${REPO}|pr-${PR}"
wantnot  "R1: no debounce with nothing recorded"                     "ci-red DEBOUNCED"
survives "R1"
UCLAUSE=ci-red _go mark
eq       "R1: a ci-red dispatch records the marker too"              "$(markers)" "1"
_go cired
want     "R2: an identical red state DEBOUNCES"                      "ci-red DEBOUNCED"
want     "R2: the line names the head it is still red at"            "still red at ${HEAD8}"
want     "R2: and the hash"                                          "state-fp:${BASE_CIRED}"
wantnot  "R2: the dispatch is skipped entirely (continue)"           "DISPATCH ci-red|"
want     "R2: it names the terminal-ride finding, not more rounds"   "the ride went terminal"
survives "R2"
fx '(.statusCheckRollup[] | select(.name=="e2e")) |= (.status="IN_PROGRESS" | .conclusion=null)'
_go cired
want     "R3: a re-run (check → PENDING) re-arms the dispatch"       "DISPATCH ci-red|${REPO}|pr-${PR}"
wantnot  "R3: no debounce"                                           "ci-red DEBOUNCED"

# ── 6b ── ARBITRATE-SPECIFIC FINGERPRINT (homelab#1011). The arbitrate clause uses
# STATE_FP_JQ_ARBITRATE which drops per-check conclusions (PR#1003's mover) and narrows head= to
# the newest non-merge commit (PR#1030's mover). Check churn must NOT re-arm arbitration, and
# updater merges must NOT re-arm it either.
section "6b — arbitrate-specific fingerprint: checks churn and merge commits are inert"
fx_base
UCLAUSE=arbitrate _go probe; BASE_ARB="$(field CUR)"
nonempty "A0: arbitrate fingerprint is non-empty"                    "$BASE_ARB"
differs  "A0: arbitrate hash differs from the ci-red hash"          "$BASE_ARB" "$BASE_CIRED"
# Check conclusion change (e2e FAILURE → SUCCESS) must NOT move the arbitrate fingerprint
fx '(.statusCheckRollup[] | select(.name=="e2e")) |= (.conclusion="SUCCESS" | .status="COMPLETED")'
UCLAUSE=arbitrate _go probe; ARB_AFTER_CHECK="$(field CUR)"
same     "A1: check conclusion change does NOT move arbitrate hash"  "$BASE_ARB" "$ARB_AFTER_CHECK"
# Check arrival (new check added) must NOT move the arbitrate fingerprint
fx '.statusCheckRollup += [{"__typename":"CheckRun","name":"new-check","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-08-09T02:00:00Z"}]'
UCLAUSE=arbitrate _go probe; ARB_AFTER_NEWCHECK="$(field CUR)"
same     "A2: new check arrival does NOT move arbitrate hash"       "$BASE_ARB" "$ARB_AFTER_NEWCHECK"
# Merge commit arrival (updater merges master) must NOT move the arbitrate fingerprint
fx ".commits += [{\"oid\":\"cccccccc33333333333333333333333333333333\",\"messageHeadline\":\"Merge branch 'master' into fix/something\"}]"
UCLAUSE=arbitrate _go probe; ARB_AFTER_MERGE="$(field CUR)"
same     "A3: merge commit arrival does NOT move arbitrate hash"    "$BASE_ARB" "$ARB_AFTER_MERGE"
# A real non-merge commit (new PR commit) MUST move the arbitrate fingerprint
fx ".commits += [{\"oid\":\"dddddddd44444444444444444444444444444444\",\"messageHeadline\":\"fix: another actual change\"}]"
UCLAUSE=arbitrate _go probe; ARB_AFTER_REAL="$(field CUR)"
differs  "A4: a real non-merge commit MOVES the arbitrate hash"     "$BASE_ARB" "$ARB_AFTER_REAL"
# Review decision change must still move the arbitrate fingerprint
fx_base
fx '.reviewDecision = "APPROVED"'
UCLAUSE=arbitrate _go probe; ARB_AFTER_REVIEW="$(field CUR)"
differs  "A5: review decision change MOVES the arbitrate hash"      "$BASE_ARB" "$ARB_AFTER_REVIEW"
# End-to-end: arbitrate debounce with the new fingerprint
fx_base
UCLAUSE=arbitrate _go mark
eq       "A6: an arbitrate dispatch records the marker"             "$(markers)" "1"
_go arbitrate
want     "A6: identical arbitrate state DEBOUNCES"                  "arbitrate DEBOUNCED"
wantnot  "A6: no unit emitted"                                      "UNITS arbitrate|"
survives "A6"

# ── 7 ── FAIL-OPEN. An unreadable probe must behave exactly as the pre-#198 clause did: EMIT. The
# guard is worth less than the loop it guards (FU-104), so every unknown resolves to "ride".
section "7 — fail-open: an unreadable probe never holds a unit back"
fx_base; UCLAUSE=arbitrate _go mark      # a marker IS on the thread, so only the probe can debounce
eq       "F0: the thread carries a marker to debounce against"       "$(markers)" "1"
_go arbitrate
want     "F0: (control) with a working probe it debounces"           "arbitrate DEBOUNCED"

STUB_GH="fail"
_go probe
isempty  "F1: a failed probe yields NO current fingerprint"          "$(field CUR)"
isempty  "F1: and no recorded one"                                   "$(field PREV)"
survives "F1"
_go arbitrate
want     "F1: the clause EMITS anyway (pre-#198 behaviour)"          "UNITS arbitrate|${REPO}|pr-${PR}"
wantnot  "F1: and does not report a debounce it cannot justify"      "DEBOUNCED"
_go cired
want     "F1: ci-red dispatches anyway"                              "DISPATCH ci-red|"

STUB_GH="body404"
_go probe
isempty  "F2: a 404 body on STDOUT is not a fingerprint"             "$(field CUR)"
survives "F2"
_go arbitrate
want     "F2: the clause EMITS"                                      "UNITS arbitrate|${REPO}|pr-${PR}"
wantnot  "F2: no debounce"                                           "DEBOUNCED"

STUB_GH="garbage"
_go arbitrate
want     "F3: a non-JSON 200 EMITS"                                  "UNITS arbitrate|${REPO}|pr-${PR}"
survives "F3"
STUB_GH="ok"

# The marker WRITE is the other half of fail-open: a refused write costs the debounce (the clause
# re-emits next scan, i.e. today's behaviour) and must never block the ride it annotates.
fx_base
STUB_GH_COMMENT="refuse"; UCLAUSE=arbitrate _go mark
wanterr  "F4: a refused marker write WARNs"                          "could not record state-fp"
want     "F4: and the dispatch proceeds"                             "REACHED: end"
wantrc   "F4: exit 0"                                                0
eq       "F4: nothing was recorded"                                  "$(markers)" "0"
STUB_GH_COMMENT="ok"
STUB_GH="fail"; UCLAUSE=arbitrate _go mark
wanterr  "F5: an unreadable fingerprint WARNs instead of marking"    "state fingerprint unreadable"
want     "F5: and the dispatch proceeds"                             "REACHED: end"
wantrc   "F5: exit 0"                                                0
STUB_GH="ok"

# The hasher is the one dependency whose absence lands INSIDE an `&&` list under `set -e` — the
# scan's comment promises it degrades rather than aborting the stack's whole scan, and that promise
# rests entirely on how bash scopes -e there. Untested, it is a guess.
fx_base; UCLAUSE=arbitrate _go mark; STUB_HASH="missing"
_go probe
isempty  "F6: a missing sha256sum yields no fingerprint"             "$(field CUR)"
survives "F6: and does NOT abort the scan"
_go arbitrate
want     "F6: the clause EMITS rather than debouncing blind"         "UNITS arbitrate|${REPO}|pr-${PR}"
survives "F6: arbitrate"
STUB_HASH="ok"

# ── 8 ── WHICH UNITS GET A MARKER. The case is the whole gate on the write side: the four PR
# clauses in, everything else out. An issue unit fingerprinted as a PR would probe a PR number
# that is an issue number — a different object, and a silent one.
section "8 — the marker is written for PR units of the four currency-gated clauses only"
fx_base; UCLAUSE=infra-enrich _go mark
eq       "W1: infra-enrich (a ci-red sibling) is marked"             "$(markers)" "1"
fx_base; UCLAUSE=merge-conflict _go mark
eq       "W1b: merge-conflict (MP-T06, homelab#595) is marked"        "$(markers)" "1"
fx_base; UCLAUSE=goal-decompose _go mark
eq       "W2: an unrelated clause is NOT marked"                     "$(markers)" "0"
fx_base; UCLAUSE=arbitrate UITEM="issue-77" _go mark
eq       "W3: an ISSUE unit is NOT marked"                           "$(markers)" "0"
UITEM="pr-${PR}"

# ── result ──────────────────────────────────────────────────────────────────────────────────────
section "result"
printf '  %s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\n\033[31mFAILED:\033[0m\n'; for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
  printf '\nThe #198 debounce changed behaviour. If that was deliberate, update the row here in the\n'
  printf 'same commit — PR #200'"'"'s verification table is the spec it is held to. If it was NOT, the\n'
  printf 'churn this guard removes is back and only the FU-069 breaker would have noticed.\n'
  exit 1
fi
printf '\n\033[32mThe homelab#198 state-fingerprint debounce holds.\033[0m\n'
