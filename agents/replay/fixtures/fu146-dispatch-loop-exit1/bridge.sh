# ── bridge ── set up variables and seams that the fu146-dispatch-loop block needs
#
# The block expects to be able to:
#   1. Declare variables (tried_units="", dispatch_succeeded="")
#   2. Reference units, punits, name, etc.
#   3. Call "bash coordinator-session.sh ..."
#   4. Use scan_phase and dispatch_phase functions
#
# We set up test data and mock coordinator-session.sh to return exit 1 (real error).
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

# Three test units. Like the exit-3 fixture, the first is c4c5 (which is skipped due to FU-121),
# the second is where we return exit 1 (real error).
punits=""
units="c4c5-redispatch|homelab|issue-77
queued-dispatch|homelab|issue-100
queued-dispatch|circles|issue-50"

# Mock coordinator-session.sh — return 1 (real error) on first call
# (This is the exit-1 arm: the error propagates, loop exits)
_mock_call_count=0
bash() {
  if [ "$1" = "${HERE}/coordinator-session.sh" ]; then
    _mock_call_count=$((_mock_call_count + 1))
    if [ $_mock_call_count -eq 1 ]; then
      echo "  [MOCK] coordinator-session.sh called for issue-100, returning exit 1 (real error)"
      return 1
    else
      # If we get here, the loop should have already exited with 1, so this should not be called
      echo "  [MOCK] ERROR: coordinator-session.sh called a second time (should have exited on first call)"
      return 1
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

# PR#915 (2026-08-26): the hard-exit path now flushes the item-class accumulator first. The
# composed clause cannot see the real function (self-contained blocks — the RC-127 trap), so a
# recording stub PINS that the flush happens before the exit; the -scan sibling never reaches
# the hard exit and needs none.
item_class_flush() { printf 'CALL item_class_flush\n' >> "$REPLAY_ACTIONS"; }
