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

# Two test units in the queue for the initial run
# The block will loop through them, with the first returning exit 3
punits=""
units="queued-dispatch|homelab|issue-100
queued-dispatch|circles|issue-50"

# Mock coordinator-session.sh — return 3 on first call, 0 on second
# (This is the exit-3 test arm; exit-1 test will override this)
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
export -f bash stacks_json scan_phase dispatch_phase
