# ── bridge ── the dispatch-marker block reads these variables from the dispatch loop.
# Pass 1: the (b) HOLD's side map carries the PR; the assembly-cr map is EMPTY, so the assertion
# isolates the arm homelab#2477 added.
uclause="goal-checkpoint"
uitem="issue-29"
urepo="circles"
assembly_cr_prs=""
goal_ckpt_b_prs="circles:issue-29:845"
# ── override pr_state_fp_pair ── return a known fingerprint. `09eb9ea954a4` is the hash the goal
# family's `goal-checkpoint-b-held` row records, so the two fixtures name the same state.
pr_state_fp_pair() {
  printf '%s\n' '09eb9ea954a4|'
  return 0
}
# ── override date ── deterministic timestamp.
date() {
  if [ "$1" = "-u" ] && [ "$2" = "+%Y-%m-%dT%H:%M:%SZ" ]; then
    printf '2026-10-10T17:33:00Z'
  else
    command date "$@"
  fi
}
