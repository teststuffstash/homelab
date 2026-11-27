# ── bridge ── the dispatch loop's variables for ONE confirmed unit: the goal-checkpoint the
# assembly-ci-red trigger emitted for goal #3118, its PR carried in the trigger's side map.
uclause="goal-checkpoint"
uitem="issue-3118"
urepo="homelab"
assembly_cr_prs=""
assembly_red_prs=" homelab:issue-3118:3301"
# ── clock ── the marker's timestamp, pinned.
date() {
  if [ "$1" = "-u" ] && [ "$2" = "+%Y-%m-%dT%H:%M:%SZ" ]; then
    printf '2026-11-12T09:20:00Z'
  else
    command date "$@"
  fi
}
