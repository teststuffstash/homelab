# Observe the printed container per chain (the tree + the expected values are in fixture.yaml).
_c=$(epic-container-walk 11 "$REPO_SLUG" master); echo "row_a goal>child container=$_c"
_c=$(epic-container-walk 51 "$REPO_SLUG" master); echo "row_b stint>child container=$_c"
_c=$(epic-container-walk 61 "$REPO_SLUG" master); echo "row_c closed-goal>child container=$_c"
_c=$(epic-container-walk 71 "$REPO_SLUG" master); echo "row_d plain>child container=$_c"
_c=$(epic-container-walk 81 "$REPO_SLUG" master); echo "row_e goal>theme>child container=$_c"
_c=$(epic-container-walk 91 "$REPO_SLUG" master); echo "row_f POST-LAUNCH-caps-space>child container=$_c"
_c=$(epic-container-walk 101 "$REPO_SLUG" master); echo "row_g label-keyed-goal>child container=$_c"
_c=$(epic-container-walk 11 "$REPO_SLUG" goal/10-x); echo "row_h goal-lane container=$_c"
# row i: the Goal's read fails (per-call injection, homelab#740) — unknown, the channel stays open.
export STUB_GH_api_repos_teststuffstash_test_project_issues_10=fail
_c=$(epic-container-walk 11 "$REPO_SLUG" master); echo "row_i parent-unreadable container=$_c"
unset STUB_GH_api_repos_teststuffstash_test_project_issues_10
# rows j/k/l: the rule appender mutates PROMPT only on `none`.
PROMPT="Initial prompt."
container-rule-append none && _rc=0 || _rc=$?
if printf '%s' "$PROMPT" | grep -q "NO CONTAINER RULE" && printf '%s' "$PROMPT" | grep -q "widens the issue footprint" && ! printf '%s' "$PROMPT" | grep -q "Follow-ups: section$"; then echo "row_j none=rule-appended+widen rc=$_rc"; else echo "row_j none=NO-RULE rc=$_rc"; fi
PROMPT="Initial prompt."
container-rule-append "goal#10" && _rc=0 || _rc=$?
if [ "$_rc" = 1 ] && [ "$PROMPT" = "Initial prompt." ]; then echo "row_k container=untouched rc=$_rc"; else echo "row_k container=MUTATED rc=$_rc"; fi
PROMPT="Initial prompt."
container-rule-append unknown && _rc=0 || _rc=$?
if [ "$_rc" = 1 ] && [ "$PROMPT" = "Initial prompt." ]; then echo "row_l unknown=untouched rc=$_rc"; else echo "row_l unknown=MUTATED rc=$_rc"; fi
echo "epic_container_walk_executed=1"
