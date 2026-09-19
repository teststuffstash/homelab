# ── bridge ── the launcher state the acceptance-4 retry clause consumes, plus the two seams it
# calls at run time (`retry_rerun`, `curl`). Per-row state (STRIKE_LINE / ERR_CLASS / STATS /
# WORK_BRANCH / STRIKE_BY_POD / AGENT_RETRY_*) comes from the row's `vars.sh` overlay in
# $REPLAY_WORLD, sourced last so a row always wins.
HERE="$REPLAY_ROOT/agents"          # the doorbell block reads ${HERE}/stacks.json
PROJECT="test-project"
TASK="issue-42"
ROUND="1"
POD="agent-test-project-issue-42-r1"
STRUCK_MODEL="deepseek/deepseek-v4-flash"
MODEL="deepseek/deepseek-v4-flash"
STRIKE_APPLIES=1
RUNLOG="$REPLAY_WORLD/runlog.txt"
_or_probe_url="http://router.test"
ROUTER_URL="http://router.test"
AGENT_LOOP_WEBHOOK="http://doorbell.test/coordinate"
# The router's serving set, exactly as /router-status serves it (the payload the FU-088 capacity
# probe already fetched). A row may blank it to exercise the fallback probe.
_or_status='{"serving_classes":["auth-storm","provider-5xx","timeout","tool-loop"]}'
# Defaults a row overrides.
STRIKE_LINE=""
ERR_CLASS=""
STATS=""
WORK_BRANCH=""
_strike_provider=""
STRIKE_BY_POD="false"
AGENT_RETRY_CELLS=""
AGENT_RETRY_TASK_N="0"

# retry_rerun — the callee the clause calls on fire. STUBBED: the re-run itself is the launcher's
# own /route consult (pinned by the route-request fixtures); this fixture pins the CALL and the
# counters it carries, which is the whole acceptance-4 contract.
retry_rerun() {
  printf 'CALL retry_rerun AGENT_RETRY_CELLS=[%s] AGENT_RETRY_TASK_N=[%s]\n' \
    "${AGENT_RETRY_CELLS:-}" "${AGENT_RETRY_TASK_N:-}" >> "$REPLAY_ACTIONS"
  return "${RETRY_RERUN_RC:-0}"
}

# curl — recorded, never executed: the doorbell ring and the /router-status fallback probe. A row
# that wants the probe to ANSWER sets CURL_BODY to the payload it would have served.
curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  [ -n "${CURL_BODY:-}" ] && printf '%s' "$CURL_BODY"
  return "${CURL_RC:-0}"
}

. "$REPLAY_WORLD/vars.sh"