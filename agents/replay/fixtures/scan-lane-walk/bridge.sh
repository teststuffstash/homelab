# ── bridge ── the world for the ADR-125 per-lane walk (family contract in fixture.yaml).
#
# The `unit-lane` block is composed BEFORE this file, so the lane map is populated here with the
# same calls the per-repo pass makes — one `Base:`/`baseRefName` reading per item, no re-read at
# dispatch. Every seam below (`bash`, `gh`, the phase emitters, the claim read) is shadowed the
# way the fu146-dispatch-loop fixtures shadow them; the dispatch loop itself is the shipped block.
HERE="${HERE:-.}"

tried_units=""
dispatch_succeeded=""
name="test-stack"
repos="homelab"
mainrepo="homelab"
cmodel="sonnet"
uwip="1"
uharvest=""
ORG="teststuffstash"
wipmap=""
punits=""

unit_lane_default_record homelab master

case "${ROW:?}" in
  two-lanes)
    # TWO LANES. The PR rides master; the queued child declares `Base: goal/x` (a level-2 goal
    # branch) and is a sub-issue of goal #590. Item numbers put the master lane first (500 < 600),
    # which is the lane order this family also pins: repos in emission order, then the lane whose
    # OLDEST item is oldest — GitHub numbers issues and PRs out of one per-repo sequence.
    units="changes-requested|homelab|pr-500
queued-dispatch|homelab|issue-600|fix|590"
    unit_lane_record homelab pr-500 master
    unit_lane_record homelab issue-600 "goal/x"
    ;;
  aged|not-yet|probe-unreadable)
    # ONE LANE — the #829 world. A standing `changes-requested` unit and a `goal-decompose` unit,
    # BOTH on master, so the priority walk is the only thing between them and `goal-decompose`
    # sits second-from-last. Whether it ever runs is what the aging predicate decides.
    units="changes-requested|homelab|pr-500
goal-decompose|homelab|issue-600|goal"
    unit_lane_record homelab pr-500 master
    unit_lane_record homelab issue-600 master
    ;;
esac

# ── the dispatch seam ──────────────────────────────────────────────────────────────────────────
# Both spawn paths land here. The latch line is what pins ADR-125's "the latch probe stays PER
# DISPATCH": it appears exactly once in `two-lanes` (before the SECOND spawn, never the first —
# the pass-level probe above this block covers that one) and never in the single-lane rows.
bash() {
  case "$1" in
    "${HERE}/coordinator-session.sh")
      echo "  [MOCK] coordinator-session.sh spawned → exit 0"; return 0 ;;
    "${HERE}/subscription-latch.sh")
      echo "  [MOCK] subscription-latch (tier=${SUBSCRIPTION_TIER:-unset}) → clear"; return 0 ;;
  esac
  command bash "$@"
}

# ── the GitHub seam ────────────────────────────────────────────────────────────────────────────
# Three reads, and nothing else may be called — an unlisted call fails loudly rather than serving
# an invented answer.
#
#   1. `gh pr view 500 … --json body` — the harvest-disposition block's PR→issue link probe for a
#      changes-requested unit (homelab#1381). `{}` = a PR with no `Fixes`/`Implements` line, so no
#      goal ancestor is walked and the disposition stays inert (the master-lane default).
#   2. `issues/600/events` — the aging predicate's `queued_at`: the newest `labeled` event for
#      `agent/queued`. `probe-unreadable` makes this read FAIL.
#   3. `issues/500/comments` — the dispatch markers on the lane's OTHER in-flight item. gh applies
#      the `--jq` filter itself, so the recorded answer is the already-filtered marker timestamps,
#      one per line. Counted against queued_at = 12:00:00Z:
#        aged     → 12:10, 12:20, 12:30  = 3 ≥ N(3) ⇒ escalate
#        not-yet  → 12:10, 12:20         = 2 <  N(3) ⇒ ordinary walk
#      (12:00:00Z itself is deliberately absent from both: the comparison is strictly `>`, and a
#      marker written in the same second the unit was queued did not happen while it waited.)
gh() {
  case "$*" in
    "pr view 500 --repo teststuffstash/homelab --json body")
      printf '{}\n'; return 0 ;;
    *"issues/600/events"*)
      [ "$ROW" = "probe-unreadable" ] && return 1
      printf '2026-08-23T12:00:00Z\n'; return 0 ;;
    *"issues/500/comments"*)
      case "$ROW" in
        aged)    printf '2026-08-23T12:10:00Z\n2026-08-23T12:20:00Z\n2026-08-23T12:30:00Z\n' ;;
        not-yet) printf '2026-08-23T12:10:00Z\n2026-08-23T12:20:00Z\n' ;;
      esac
      return 0 ;;
  esac
  echo "UNEXPECTED gh call in fixture: $*" >&2; return 1
}

scan_phase() { :; }
dispatch_phase() { :; }
item_class_flush() { printf 'CALL item_class_flush\n' >> "$REPLAY_ACTIONS"; }

stacks_json() {
  cat <<'JSON'
{"stacks":[{"name":"test-stack","coordinatorModel":"sonnet","workerModel":"claude/haiku"}]}
JSON
}

export -f bash gh stacks_json scan_phase dispatch_phase item_class_flush
