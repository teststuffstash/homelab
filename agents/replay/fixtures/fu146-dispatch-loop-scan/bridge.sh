# ── bridge ── set up variables and seams that the fu146-dispatch-loop block needs
#
# The block expects to be able to:
#   1. Declare variables (tried_units="", dispatch_succeeded="")
#   2. Reference units, punits, name, etc.
#   3. Call "bash coordinator-session.sh ..."
#   4. Use scan_phase and dispatch_phase functions
#
# We set up test data and mock coordinator-session.sh to return different exit codes.
HERE="${HERE:-.}"

# Required variables set up once at the start of the fixture run
tried_units=""
dispatch_succeeded=""
name="test-stack"
repos="homelab circles"
mainrepo="homelab"
cmodel="sonnet"
uwip="1"
uharvest=""
ORG="test"
wipmap=""  # WIP map for repositories (empty for test)

# Three test units: a c4c5 unit whose issue CLOSED since the list snapshot (the FU-121 skip —
# PR#631 r2: it must mark the unit tried and DRAIN, never re-select it forever), then the
# exit-3 racing pair. c4c5 outranks queued-dispatch in the clause priority, so it is selected
# first; its skip must still leave the pass able to dispatch.
punits=""
units="c4c5-redispatch|homelab|issue-77
queued-dispatch|homelab|issue-100
queued-dispatch|circles|issue-50"

# Mock coordinator-session.sh — return 3 on first call, 0 on second
# (This is the exit-3 test arm; exit-1 test is in fu146-dispatch-loop-exit1)
_mock_call_count=0
bash() {
  if [ "$1" = "${HERE}/coordinator-session.sh" ]; then
    _mock_call_count=$((_mock_call_count + 1))
    if [ $_mock_call_count -eq 1 ]; then
      echo "  [MOCK] coordinator-session.sh called for issue-100, returning exit 3 (FU-146 racing)"
      return 3
    else
      echo "  [MOCK] coordinator-session.sh called for issue-50, returning exit 0 (success)"
      return 0
    fi
  else
    command bash "$@"
  fi
}

# Mock gh for two probes, and nothing else — anything unlisted is a fixture bug and fails loudly
# rather than serving an invented answer.
#   1. the FU-121 fresh-state probe: issue-77 reads CLOSED (the raced close)
#   2. the ADR-125 aging probes (#829). Both units sit in ONE lane (homelab@master, no `Base:`
#      recorded), and the lane holds a recovery clause, so the aging predicate evaluates the
#      queued candidate: issue-100 was queued at 12:00Z and the lane's other in-flight item
#      (issue-77) carries ZERO dispatch markers newer than that. lost = 0 < N (3), so NO
#      escalation and NO report line — the ordinary walk, asserted by the absence below. This is
#      the non-regression half of #829 riding the exit-3 fixture for free.
gh() {
  if [ "$1" = "issue" ] && [ "$2" = "view" ] && [ "$3" = "77" ]; then
    printf 'CLOSED\n'; return 0
  fi
  case "$*" in
    *"issues/100/events"*)   printf '2026-08-23T12:00:00Z\n'; return 0 ;;
    *"issues/77/comments"*)  return 0 ;;   # no agent-summary comment at all → zero markers
  esac
  echo "UNEXPECTED gh call in fixture: $*" >&2; return 1
}

# Mock scan_phase and dispatch_phase to avoid needing cluster/gateway access
scan_phase() { :; }
dispatch_phase() { :; }

# Mock stacks_json for the while loop's unit dispatch logic
# The block calls stacks_json to get cmodel and wmodel for each unit
stacks_json() {
  cat <<'EOF'
{"stacks":[{"name":"test-stack","coordinatorModel":"sonnet","workerModel":"claude/haiku"}]}
EOF
}

# Make functions available to subshells
export -f bash gh stacks_json scan_phase dispatch_phase
