#!/usr/bin/env bash
# board-test.sh — the SMOKE pin for agents/board.sh (homelab#493).
#
#   bash agents/board-test.sh                   (also runs under `devbox run clause-replay`,
#                                                 registered as agents/replay/fixtures/board-classification)
#
# WHY THIS EXISTS. board.sh is the operator's who-acts todo view: read-only `gh`/`kubectl`
# retrieval whose only failure protection is a WARN belt over READ failures. The defect class a
# WARN belt cannot see is a silent jq-predicate break that EMPTIES a section while the board still
# renders healthy — PR#490's review already caught one (the SOLVE/TRIAGE disjointness bug). At
# SMOKE depth (operator scoping, 2026-08-18), this pins two things and nothing wider: one recorded
# world where each board section classifies known rows (incl. the BACKLOG aggregate/oldest math),
# and the PROBE-FAILED loudness so it cannot regress fail-open.
#
# MECHANICS. The suite is mode: suite in the replay harness: it lifts the real replay stubs
# (agents/replay/stubs/) onto a throwaway PATH bin and points them at the committed world
# (agents/replay/fixtures/board-classification/world/) — the same recorded-response machinery the
# actions-mode fixtures use, driven by the suite's own assertions. board.sh runs for REAL against
# that world with its clock pinned via BOARD_NOW (the seam it declares), so the expected/ outputs
# are the tool's own render of the recorded world, never a re-implementation.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
FIX="$ROOT/agents/replay/fixtures/board-classification/board-classification"
STUBS="$ROOT/agents/replay/stubs"
NOW=1787054400   # 2026-08-18T12:00:00Z — the world's pinned clock (world/ createdAt rows, fixture.yaml)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }

present() { # present <desc> <needle> <haystack>
  if printf '%s' "$3" | grep -Fq -- "$2"; then ok "$1"; else bad "$1 — missing: $2"; fi
}
absent() { # absent <desc> <needle> <haystack>
  if printf '%s' "$3" | grep -Fq -- "$2"; then bad "$1 — present but must not be: $2"; else ok "$1"; fi
}
# section <header> <full-output> — the lines under one board section, up to the next § or the
# totals line (blank lines dropped). The disjointness checks must be scoped to a SECTION: an
# issue can legitimately appear elsewhere on the board (SOLVE owns agent/error, BACKLOG owns
# agent-fix), and a whole-output `absent` would red on that legitimate appearance.
section() {
  printf '%s\n' "$2" | awk -v h="$1" '
    $0 == h { insec=1; next }
    insec && /^§ / { exit }
    insec && /^totals —/ { exit }
    insec && NF { print }
  '
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cp "$STUBS/gh" "$STUBS/kubectl" "$TMP/bin/" && chmod +x "$TMP/bin/gh" "$TMP/bin/kubectl"

# board <actions> <stderr> <extra-env> <args...>  → sets $BOARD_OUT (stdout) and $BOARD_RC
board() {
  local act="$1" err="$2" extra="$3"; shift 3
  : > "$act"; : > "$err"
  if ! BOARD_OUT="$(env $extra PATH="$TMP/bin:$PATH" REPLAY_WORLD="$FIX/world" \
      REPLAY_ACTIONS="$act" REPLAY_STUB_DIR="$STUBS" BOARD_NOW="$NOW" \
      bash "$ROOT/agents/board.sh" "$@" 2>"$err")"; then
    BOARD_RC=1
  else
    BOARD_RC=0
  fi
}

# The read-only contract: the happy runs must make exactly three calls — one AgentStack claim
# read, one issues list, one PR list — and nothing else (no loop-polls, no mutations).
readonly_calls() { # readonly_calls <desc> <actions-file>
  local desc="$1" act="$2" n
  n="$(grep -c . "$act" 2>/dev/null || true)"
  # The platform-request slice (ADR-119) adds 2 more calls: kubectl get all agentstacks
  # and gh issue list --label platform-request. Total = 5.
  if [ "$n" = 5 ] \
     && [ "$(grep -c '^CALL kubectl' "$act" || true)" = 2 ] \
     && [ "$(grep -c '^CALL gh issue list ' "$act" || true)" = 2 ] \
     && [ "$(grep -c '^CALL gh pr list ' "$act" || true)" = 1 ]; then
    ok "$desc — exactly 5 reads (2 kubectl + 2 issue list + 1 pr list), no mutations"
  else
    bad "$desc — expected exactly 5 read calls (2 kubectl + 2 issue list + 1 pr list)" "$(cat "$act")"
  fi
}

# ── the stderr contract, with the migration meter carved out (ADR-122 (3), homelab#1430) ──────
# board.sh reads the `Capability:` grammar through the ONE parser (agents/issue_body.py), which
# prints `LEGACY-GRAMMAR Capability <ref>` on stderr for every legacy fall-through. That line is
# the MIGRATION METER and is never suppressed by contract — but it is not a WARN, and the
# assertion this test has always made is "the board reported nothing wrong". So the meter lines
# are separated out, the no-WARN assertion is unchanged for everything else, and the meter is
# additionally pinned POSITIVELY: its absence would mean the board had quietly stopped reading
# through the shared parser. Both halves retire together at S8 closeout 2, with the legacy read.
stderr_clean() {   # stderr_clean <desc> <errfile>
  grep -v '^LEGACY-GRAMMAR ' "$2" > "$2.nometer" 2>/dev/null || true
  if [ ! -s "$2.nometer" ]; then ok "$1: no WARN on stderr (the LEGACY-GRAMMAR meter aside)"
  else bad "$1: unexpected stderr" "$(cat "$2.nometer")"; fi
  if grep -q '^LEGACY-GRAMMAR Capability ' "$2"; then
    ok "$1: the Capability: read ran through agents/issue_body.py (the meter fired)"
  else
    bad "$1: no LEGACY-GRAMMAR Capability line — the board is no longer reading the grammar through the one parser" "$(cat "$2")"
  fi
}

# ══ 1. the recorded world, plain view ═════════════════════════════════════════════════════════
board "$TMP/plain.actions" "$TMP/plain.err" "" platform
if [ "$BOARD_RC" = 0 ]; then ok "plain: board.sh exits 0"; else bad "plain: board.sh exited $BOARD_RC"; fi

if diff -u "$FIX/expected/board-plain.txt" <(printf '%s\n' "$BOARD_OUT") > "$TMP/plain.diff" 2>&1; then
  ok "plain: rendered board matches expected/board-plain.txt exactly"
else
  bad "plain: rendered board moved" "$(head -40 "$TMP/plain.diff")"
fi
stderr_clean "plain" "$TMP/plain.err"
readonly_calls "plain" "$TMP/plain.actions"

# ── the SOLVE/TRIAGE disjointness the round-1 review caught (PR#490) ─────────────────────────
# TRIAGE must never list an agent/*-labelled issue — those belong to SOLVE (agent/error,
# agent/blocked) or BACKLOG (agent-fix+agent/in-progress) — or a bot issue carrying agent-fix.
SEC_SOLVE="$(section '§ SOLVE (parks & latches)' "$BOARD_OUT")"
SEC_TRIAGE="$(section '§ TRIAGE' "$BOARD_OUT")"
SEC_BACKLOG="$(section '§ BACKLOG (suitable, unqueued)' "$BOARD_OUT")"
absent "disjoint: TRIAGE excludes agent/error issues (SOLVE owns them)"   "circles#101" "$SEC_TRIAGE"
absent "disjoint: TRIAGE excludes agent/blocked issues (SOLVE owns them)" "circles#102" "$SEC_TRIAGE"
absent "disjoint: TRIAGE excludes the error+blocked overlap"              "circles#103" "$SEC_TRIAGE"
absent "disjoint: TRIAGE excludes a queued (state-labelled) issue"        "circles#110" "$SEC_TRIAGE"
absent "disjoint: a bot issue with agent-fix is BACKLOG, not TRIAGE"      "circles#113" "$SEC_TRIAGE"
absent "triage: post-launch buckets are containers, not work"             "circles#112" "$SEC_TRIAGE"
absent "triage: stint: parents are containers, not strays (2026-08-19)"   "circles#115" "$SEC_TRIAGE"
absent "triage: a zero-label issue younger than a day waits"              "circles#106" "$SEC_TRIAGE"
# `agent/queued` WITHOUT `agent-fix` retired as an anti-pattern (ADR-122 (2), S8 #1432): it is a
# legal, dispatchable state now — no board line anywhere, same as an ordinary paired queued issue.
absent "triage: agent/queued WITHOUT agent-fix draws no line (legal state, ADR-122 (2), #1432)" "circles#114" "$SEC_TRIAGE"
absent "triage: a properly-paired queued issue draws no line either"      "circles#110" "$SEC_TRIAGE"
absent "backlog: agent/queued-without-agent-fix is not suitable-unqueued (no agent-fix)" "circles#114" "$SEC_BACKLOG"
# Within SOLVE, a blocked issue already flagged agent/error shows ⛔ only (FU-069), never ⏸ too.
absent "solve: agent/error overrides agent/blocked (no double line)"      "⏸ circles#103" "$SEC_SOLVE"
# ── the FIX row (2026-08-19): seat-authored changes-requested PRs are the seat's own queue ───
# (an operator-lane PR has no machine owner — the between-sessions backstop for the PR#568 class)
SEC_FIX="$(section '§ FIX (seat PRs awaiting your fix round)' "$BOARD_OUT")"
present "fix: a seat-authored changes-requested PR lists"           "circles#207" "$SEC_FIX"
absent  "fix: a bot-authored changes-requested PR is machine-owned" "circles#203" "$SEC_FIX"
present "fix: a seat-authored merge-conflict PR lists (homelab#595)" "circles#209" "$SEC_FIX"
absent  "fix: a bot-authored merge-conflict PR is machine-owned"    "circles#210" "$SEC_FIX"
absent  "fix: agent/error stays SOLVE's line (no double list)"      "circles#208" "$SEC_FIX"
absent  "fix: major/awaiting-human stays REVIEW's"                  "circles#202" "$SEC_FIX"
present "solve: the error-latched seat PR shows under SOLVE"        "⛔ circles#208" "$SEC_SOLVE"
# Backlog aggregate counts only agent-fix issues with no agent/* state label.
present "backlog: aggregate pins count + oldest math" \
  "circles: 3 suitable-unqueued (oldest 17d)" "$SEC_BACKLOG"
absent "backlog: a state-labelled issue is not suitable-unqueued"         "circles#110" "$SEC_BACKLOG"
# ── the DEMAND section (ADR-119) ──────────────────────────────────────────────────────────────
SEC_DEMAND="$(section '§ DEMAND (platform-request)' "$BOARD_OUT")"
present "demand: platform-request section renders" "§ DEMAND (platform-request)" "$BOARD_OUT"
present "demand: capability fingerprint shown" "public-edge.abuse-fairness" "$SEC_DEMAND"
present "demand: oldest age shown" "oldest 17d" "$SEC_DEMAND"
present "demand: stack count shown" "1 stacks" "$SEC_DEMAND"
present "demand: first issue listed" "circles#116 public edge fairness" "$SEC_DEMAND"
present "demand: second issue listed" "circles#117 circles edge fairness" "$SEC_DEMAND"

# ══ 2. --full expands the backlog beneath the unchanged aggregate ═════════════════════════════
board "$TMP/full.actions" "$TMP/full.err" "" platform --full
if [ "$BOARD_RC" = 0 ]; then ok "full: board.sh exits 0"; else bad "full: board.sh exited $BOARD_RC"; fi
if diff -u "$FIX/expected/board-full.txt" <(printf '%s\n' "$BOARD_OUT") > "$TMP/full.diff" 2>&1; then
  ok "full: rendered board matches expected/board-full.txt exactly"
else
  bad "full: rendered board moved" "$(head -40 "$TMP/full.diff")"
fi
stderr_clean "full"  "$TMP/full.err"
readonly_calls "full" "$TMP/full.actions"
present "full: aggregate line unchanged under --full" "circles: 3 suitable-unqueued (oldest 17d)" "$BOARD_OUT"
present "full: backlog detail is sorted by number (oldest first)" "  circles#108 suitable backlog older (17d)" "$BOARD_OUT"
present "full: backlog detail includes the newer row"             "  circles#109 suitable backlog newer (16d)" "$BOARD_OUT"
present "full: backlog detail includes the bot row"               "  circles#113 bot queued fix (17d)" "$BOARD_OUT"
# ── DEMAND section under --full (ADR-119) ─────────────────────────────────────────────────────
SEC_DEMAND_FULL="$(section '§ DEMAND (platform-request)' "$BOARD_OUT")"
present "full-demand: platform-request section renders" "§ DEMAND (platform-request)" "$BOARD_OUT"
present "full-demand: capability fingerprint shown" "public-edge.abuse-fairness" "$SEC_DEMAND_FULL"
present "full-demand: oldest age shown" "oldest 17d" "$SEC_DEMAND_FULL"
present "full-demand: stack count shown" "1 stacks" "$SEC_DEMAND_FULL"

# ══ 3. the PROBE-FAILED loudness — a failed read is a WARN + a skipped repo, never a clean ═══
# board.sh cannot regress to fail-open: a gh probe that dies must still surface as a loud,
# per-repo skip (an empty board can be a probe, not a clean queue) and inflate the ⚠ totals.
board "$TMP/probe.actions" "$TMP/probe.err" "STUB_GH=fail" platform
if [ "$BOARD_RC" = 0 ]; then ok "probe-fail: board.sh warns and continues (exit 0)"; else bad "probe-fail: board.sh exited $BOARD_RC"; fi
if diff -u "$FIX/expected/board-probe-fail.txt" <(printf '%s\n' "$BOARD_OUT") > "$TMP/probe.diff" 2>&1; then
  ok "probe-fail: all-zero totals + ⚠ summary on stdout"
else
  bad "probe-fail: stdout moved" "$(head -40 "$TMP/probe.diff")"
fi
absent "probe-fail: no board section renders for a skipped repo" "§ " "$BOARD_OUT"
present "probe-fail: issue-list probe failure is WARNed (with the loud-absence contract)" \
  "WARN board: teststuffstash/circles issue list PROBE-FAILED — repo skipped (an empty board can be a probe, not a clean queue)" \
  "$(cat "$TMP/probe.err")"
present "probe-fail: PR-list probe failure is WARNed" \
  "WARN board: teststuffstash/circles PR list PROBE-FAILED — repo skipped (an empty board can be a probe, not a clean queue)" \
  "$(cat "$TMP/probe.err")"
present "probe-fail: platform-request probe failure is WARNed" \
  "WARN board: teststuffstash/circles platform-request probe PROBE-FAILED — repo skipped (an empty board can be a probe, not a clean queue)" \
  "$(cat "$TMP/probe.err")"

printf '\n  %s passed, %s failed\n' "$PASS" "$FAIL"

# ══ 4. --machine mode — derived classes from Prometheus (homelab#892) ════════════════════════
# Seam: PROMETHEUS_URL=${PROMETHEUS_URL:-http://kube-prometheus-stack-prometheus.monitoring.svc:9090}
# (overridable to http://stub for testing with a curl stub). The curl stub returns synthetic
# agent_item_class series data in Prometheus JSON format.

# Create a curl stub for Prometheus
cat > "$TMP/bin/curl" <<'CURLSTUB'
#!/usr/bin/env bash
# Stub curl for Prometheus queries — matches the most specific query FIRST.
# Distinguishes goal_descendant_info (scope resolution), agent_item_class_since_timestamp_seconds
# (age computation), and agent_item_class (classification). Scoped variants carry an
# item=~"..." filter that narrows the returned rows to the goal's descendants.
if [[ "$*" == *"goal_descendant_info"* ]]; then
  # Goal descendant info: return a strict subset of the agent_item_class items
  # (items 833 and 834 are in scope for goal 775; 889, 840, 841, aggregate are out)
  cat <<'JSON'
{"status":"success","data":{"resultType":"vector","result":[
  {"metric":{"item":"833"},"value":[1787054400,"1"]},
  {"metric":{"item":"834"},"value":[1787054400,"1"]}
]}}
JSON
elif [[ "$*" == *"agent_item_class_since_timestamp_seconds"* ]]; then
  if [[ "$*" == *"item=~"* ]]; then
    # Scoped timestamp series — only items in scope (833, 834)
    cat <<'JSON'
{"status":"success","data":{"resultType":"vector","result":[
  {"metric":{"repo":"homelab","item":"833"},"value":[1787054400,"1787027400"]},
  {"metric":{"repo":"homelab","item":"834"},"value":[1787054400,"1787027400"]}
]}}
JSON
  else
    # Full timestamp series: item -> start epoch in value[1]
    cat <<'JSON'
{"status":"success","data":{"resultType":"vector","result":[
  {"metric":{"repo":"homelab","item":"833"},"value":[1787054400,"1787027400"]},
  {"metric":{"repo":"homelab","item":"834"},"value":[1787054400,"1787027400"]},
  {"metric":{"repo":"homelab","item":"889"},"value":[1787054400,"1787054040"]},
  {"metric":{"repo":"homelab","item":"840"},"value":[1787054400,"1787054400"]},
  {"metric":{"repo":"homelab","item":"aggregate"},"value":[1787054400,"1785931200"]}
]}}
JSON
  fi
elif [[ "$*" == *"/api/v1/query"* ]]; then
  if [[ "$*" == *"item=~"* ]]; then
    # Scoped class series — only items in scope (833, 834)
    cat <<'JSON'
{"status":"success","data":{"resultType":"vector","result":[
  {"metric":{"repo":"homelab","item":"833","class":"strike-held","who":"operator"},"value":[1787054400,"1"]},
  {"metric":{"repo":"homelab","item":"834","class":"queued-held-by-ghost","who":"operator"},"value":[1787054400,"1"]}
]}}
JSON
  else
    # Full class series (includes one item absent from timestamp series to test unknown case)
    cat <<'JSON'
{"status":"success","data":{"resultType":"vector","result":[
  {"metric":{"repo":"homelab","item":"833","class":"strike-held","who":"operator"},"value":[1787054400,"1"]},
  {"metric":{"repo":"homelab","item":"834","class":"queued-held-by-ghost","who":"operator"},"value":[1787054400,"1"]},
  {"metric":{"repo":"homelab","item":"889","class":"riding","who":"machine"},"value":[1787054400,"1"]},
  {"metric":{"repo":"homelab","item":"840","class":"container","who":"none"},"value":[1787054400,"1"]},
  {"metric":{"repo":"homelab","item":"841","class":"parked-blocked","who":"operator"},"value":[1787054400,"1"]},
  {"metric":{"repo":"homelab","item":"aggregate","class":"backlog-aggregate","who":"operator"},"value":[1787054400,"1"]}
]}}
JSON
  fi
fi
exit 0
CURLSTUB
chmod +x "$TMP/bin/curl"

board "$TMP/machine.actions" "$TMP/machine.err" "PROMETHEUS_URL=http://stub BOARD_NOW=$NOW" --machine platform
if [ "$BOARD_RC" = 0 ]; then ok "machine: board.sh --machine exits 0"; else bad "machine: board.sh --machine exited $BOARD_RC"; fi
present "machine: header has board v1 prefix" "board v1" "$BOARD_OUT"
present "machine: header has scope=stack:platform" "scope=stack:platform" "$BOARD_OUT"
present "machine: header has sources=labels:live pods:live derived:tick@" "sources=labels:live pods:live derived:tick@" "$BOARD_OUT"
present "machine: strike-held row (who=operator)" "who=operator class=strike-held id=homelab#833" "$BOARD_OUT"
present "machine: queued-held-by-ghost row (who=operator)" "who=operator class=queued-held-by-ghost id=homelab#834" "$BOARD_OUT"
present "machine: computed elapsed times (7h30m for items 833 and 834)" "since=7h30m" "$BOARD_OUT"
present "machine: backlog-aggregate row (who=operator)" "who=operator class=backlog-aggregate id=homelab/aggregate" "$BOARD_OUT"
present "machine: riding row (who=machine) with computed age" "who=machine  class=riding id=homelab#889 age=6m" "$BOARD_OUT"
present "machine: container row (who=none)" "who=none     class=container id=homelab#840" "$BOARD_OUT"
present "machine: item absent from timestamp series renders unknown" "since=unknown" "$BOARD_OUT"
absent "machine: no § REVIEW section" "§ " "$BOARD_OUT"
absent "machine: UNSCOPED board carries no disposition token (no container to ask)" "disposition=" "$BOARD_OUT"
absent "machine: UNSCOPED board makes no store read" "issues/775/comments" "$(cat "$TMP/machine.actions")"
absent "machine: no totals line" "totals —" "$BOARD_OUT"
# ── platform-request rows in machine mode (ADR-119) ────────────────────────────────────────────
present "machine: platform-request row" "who=operator class=platform-request" "$BOARD_OUT"
present "machine: platform-request capability" "capability=public-edge.abuse-fairness" "$BOARD_OUT"
present "machine: platform-request stacks count" "stacks=1" "$BOARD_OUT"
present "machine: platform-request oldest age" "oldest=17d" "$BOARD_OUT"

# ══ --scope content assertions (homelab#914) ═══════════════════════════════════════════════
# The two --scope cases below test BOTH flag forms AND assert row content. The curl stub's
# goal_descendant_info response seeds items 833 and 834 as descendants of goal 775, leaving
# items 889, 840, 841, and aggregate out of scope. Assertions:
#   - in-scope items (833, 834) ARE present in $BOARD_OUT
#   - out-of-scope items (889, 840) ARE absent from $BOARD_OUT
# This catches the regression class where the unwrapping bug on board.sh:220 silently returned
# the full unscoped board while BOARD_RC=0 — the absence assertion would red.

# --scope=goal:775 (equals form) — also tests the --scope=value parsing codepath
board "$TMP/scope-eq.actions" "$TMP/scope-eq.err" "PROMETHEUS_URL=http://stub BOARD_NOW=$NOW" --machine --scope=goal:775 platform 2>/dev/null || true
if [ "$BOARD_RC" = 0 ]; then ok "machine: --scope=goal:775 (equals form) parsing works"; else bad "machine: --scope=goal:775 parsing failed"; fi
present "scope-eq: in-scope item 833 present" "id=homelab#833" "$BOARD_OUT"
present "scope-eq: in-scope item 834 present" "id=homelab#834" "$BOARD_OUT"
absent  "scope-eq: out-of-scope item 889 absent" "id=homelab#889" "$BOARD_OUT"
absent  "scope-eq: out-of-scope item 840 absent" "id=homelab#840" "$BOARD_OUT"
# ── dispositions in goal scope (ADR-122 (4), homelab#1419) ─────────────────────────────────
# The recorded store on goal 775 carries `#833 adopted` and `#834 deferred` (world/gh/
# api-repos-teststuffstash-homelab-issues-775-comments-per-page-100.json), so the two in-scope
# rows must render the CONTAINER's ruling verbatim. The board never derives one — the
# one-computer rule — so these tokens can only come from the store.
present "scope-eq: member 833 carries its adopted disposition" \
  "id=homelab#833 pod=none since=7h30m next=\"verify goal branch, then close or re-queue\" disposition=adopted" "$BOARD_OUT"
present "scope-eq: member 834 carries its deferred disposition" "disposition=deferred" "$BOARD_OUT"
absent  "scope-eq: no member is reported undispositioned (both carry rows)" "disposition=undispositioned" "$BOARD_OUT"

# --scope goal:775 (space form) — the form that was actually broken in round 3
board "$TMP/scope-sp.actions" "$TMP/scope-sp.err" "PROMETHEUS_URL=http://stub BOARD_NOW=$NOW" --machine --scope goal:775 platform 2>/dev/null || true
if [ "$BOARD_RC" = 0 ]; then ok "machine: --scope goal:775 (space form) parsing works"; else bad "machine: --scope goal:775 parsing failed"; fi
present "scope-sp: in-scope item 833 present" "id=homelab#833" "$BOARD_OUT"
present "scope-sp: in-scope item 834 present" "id=homelab#834" "$BOARD_OUT"
absent  "scope-sp: out-of-scope item 889 absent" "id=homelab#889" "$BOARD_OUT"
absent  "scope-sp: out-of-scope item 840 absent" "id=homelab#840" "$BOARD_OUT"
present "scope-sp: member 833 carries its adopted disposition" "id=homelab#833" "$BOARD_OUT"
present "scope-sp: dispositions ride the space form of --scope too" "disposition=adopted" "$BOARD_OUT"

[ "$FAIL" -eq 0 ] || exit 1
