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
  if [ "$n" = 3 ] \
     && [ "$(grep -c '^CALL kubectl' "$act" || true)" = 1 ] \
     && [ "$(grep -c '^CALL gh issue list ' "$act" || true)" = 1 ] \
     && [ "$(grep -c '^CALL gh pr list ' "$act" || true)" = 1 ]; then
    ok "$desc — exactly 3 reads (kubectl claim + issue list + pr list), no mutations"
  else
    bad "$desc — expected exactly 3 read calls (claim, issue list, pr list)" "$(cat "$act")"
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
[ ! -s "$TMP/plain.err" ] && ok "plain: no WARN on stderr" || bad "plain: unexpected stderr" "$(cat "$TMP/plain.err")"
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
# Half-labeled (2026-08-19, oracle-fleet#260): queued WITHOUT agent-fix is invisible to every
# dispatch clause and every other board section — TRIAGE surfaces it with a ⚠ repair line.
present "triage: agent/queued WITHOUT agent-fix surfaces as ⚠ half-labeled" "⚠ circles#114" "$SEC_TRIAGE"
absent "triage: a properly-paired queued issue draws no half-labeled ⚠"    "⚠ circles#110" "$SEC_TRIAGE"
absent "backlog: half-labeled is not suitable-unqueued (no agent-fix)"     "circles#114" "$SEC_BACKLOG"
# Within SOLVE, a blocked issue already flagged agent/error shows ⛔ only (FU-069), never ⏸ too.
absent "solve: agent/error overrides agent/blocked (no double line)"      "⏸ circles#103" "$SEC_SOLVE"
# ── the FIX row (2026-08-19): seat-authored changes-requested PRs are the seat's own queue ───
# (an operator-lane PR has no machine owner — the between-sessions backstop for the PR#568 class)
SEC_FIX="$(section '§ FIX (seat PRs awaiting your fix round)' "$BOARD_OUT")"
present "fix: a seat-authored changes-requested PR lists"           "circles#207" "$SEC_FIX"
absent  "fix: a bot-authored changes-requested PR is machine-owned" "circles#203" "$SEC_FIX"
absent  "fix: agent/error stays SOLVE's line (no double list)"      "circles#208" "$SEC_FIX"
absent  "fix: major/awaiting-human stays REVIEW's"                  "circles#202" "$SEC_FIX"
present "solve: the error-latched seat PR shows under SOLVE"        "⛔ circles#208" "$SEC_SOLVE"
# Backlog aggregate counts only agent-fix issues with no agent/* state label.
present "backlog: aggregate pins count + oldest math" \
  "circles: 3 suitable-unqueued (oldest 17d)" "$SEC_BACKLOG"
absent "backlog: a state-labelled issue is not suitable-unqueued"         "circles#110" "$SEC_BACKLOG"

# ══ 2. --full expands the backlog beneath the unchanged aggregate ═════════════════════════════
board "$TMP/full.actions" "$TMP/full.err" "" platform --full
if [ "$BOARD_RC" = 0 ]; then ok "full: board.sh exits 0"; else bad "full: board.sh exited $BOARD_RC"; fi
if diff -u "$FIX/expected/board-full.txt" <(printf '%s\n' "$BOARD_OUT") > "$TMP/full.diff" 2>&1; then
  ok "full: rendered board matches expected/board-full.txt exactly"
else
  bad "full: rendered board moved" "$(head -40 "$TMP/full.diff")"
fi
[ ! -s "$TMP/full.err" ] && ok "full: no WARN on stderr" || bad "full: unexpected stderr" "$(cat "$TMP/full.err")"
readonly_calls "full" "$TMP/full.actions"
present "full: aggregate line unchanged under --full" "circles: 3 suitable-unqueued (oldest 17d)" "$BOARD_OUT"
present "full: backlog detail is sorted by number (oldest first)" "  circles#108 suitable backlog older (17d)" "$BOARD_OUT"
present "full: backlog detail includes the newer row"             "  circles#109 suitable backlog newer (16d)" "$BOARD_OUT"
present "full: backlog detail includes the bot row"               "  circles#113 bot queued fix (17d)" "$BOARD_OUT"

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

printf '\n  %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
