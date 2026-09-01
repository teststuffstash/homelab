# ── bridge ── the dispatch-marker block reads these variables from the dispatch loop.
# This fixture tests the goal-checkpoint:issue-* arm when the side map is EMPTY
# (an ordinary threshold-fired goal-checkpoint with no assembly PR).
# ORG is set via fixture.yaml env.
uclause="goal-checkpoint"
uitem="issue-281"
urepo="oracle-fleet"
# Side map is empty — no assembly PR carried this unit.
assembly_cr_prs=""
# ── override pr_state_fp_pair ── return a known fingerprint (abc123).
pr_state_fp_pair() {
  printf '%s\n' 'abc123|'
  return 0
}
# ── override date ── deterministic timestamp.
date() {
  if [ "$1" = "-u" ] && [ "$2" = "+%Y-%m-%dT%H:%M:%SZ" ]; then
    printf '2026-09-01T12:41:00Z'
  else
    command date "$@"
  fi
}