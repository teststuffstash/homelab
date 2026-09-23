# ── bridge ── the launcher state the acceptance-4 retry clause consumes, plus the two seams it
# calls at run time (`retry_rerun`, `curl`).
#
# A row declares the CONDITION it wants in a vocabulary of its own (the `RT_*` knobs below), never
# by poking the clause's internals: this bridge translates that into exactly the variables the
# shipped terminal block reads (STRIKE_LINE / STRIKE_BY_POD / ERR_CLASS / STATS / WORK_BRANCH /
# AGENT_RETRY_*), so the table stays readable and no `RT_*` name can collide with an ambient pod
# variable (the hermeticity unset list in run.sh).
#
# The three launcher-side facts the clause derives, and where each comes from in production:
#   RT_STRIKE=launcher  the LAUNCHER's own strike (its classifier ran → ERR_CLASS), the pod did
#                       not post one. STRIKE_LINE carries the class verbatim.
#   RT_STRIKE=pod       agent-finalize's in-pod strike (the common path): STRIKE_BY_POD=true,
#                       STRIKE_LINE empty, so the class is read out of the STATS line the pod
#                       wrote — with the finalizer's own `failed`/`ci-failed` → `unknown` rewrite
#                       (agent-runtime agent-finalize:bookkeeping, the `err = "unknown"` arm).
#   RT_STRIKE=none      no strike at all.
#   RT_SALVAGE          the finalizer's `resumable_branch()` verdict, reproduced from the same
#                       three facts it reads (agent-runtime agent-finalize:resumable_branch):
#                       `pushed` → stats.salvaged_branch, `resuming` → WORK_BRANCH, `unknown` →
#                       stats.salvage_undetermined, else `none`.
#   RT_STATUS_MODE      `serving` = the /router-status payload the FU-088 capacity probe already
#                       fetched is in hand; `blank` = that ride skipped the probe (a sub-rail ride)
#                       so the clause must fall back to its own ClusterIP-local read.
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
PROXY_URL=""
# The serving set EXACTLY as router.py serves it on /router-status (sorted(SERVING_CLASSES)).
OR_STATUS_SERVING='{"serving_classes":["auth-storm","provider-5xx","timeout","tool-loop"]}'
# ORIG_ARGS simulates the launcher's command line. The --model and --openrouter-secret flags
# will be stripped by retry_rerun; we use deepseek as the model for testing.
ORIG_ARGS=(test-project --model deepseek/deepseek-v4-flash --openrouter-secret test-secret --harness goose)

# ── the row's declared condition ───────────────────────────────────────────────────────────────
RT_STRIKE="${RT_STRIKE:-launcher}"
RT_CLASS="${RT_CLASS:-timeout}"
RT_PROVIDER="${RT_PROVIDER-openrouter}"
# RT_STATS_PROVIDER — the provider the finalizer folds into the pod's STATS line (the second of the
# two cross-repo sources the cell reads). Empty = the field is ABSENT, which is the contract break
# the `no-retry-empty-provider` row pins; every other row leaves it at the served provider.
RT_STATS_PROVIDER="${RT_STATS_PROVIDER-openrouter}"
RT_SALVAGE="${RT_SALVAGE:-none}"
RT_PRIOR_CLASS="${RT_PRIOR_CLASS:-}"
RT_PRIOR_N="${RT_PRIOR_N:-0}"
RT_STATUS_MODE="${RT_STATUS_MODE:-serving}"
RT_STACK_MODE="${RT_STACK_MODE:-chainless}"  # chainless = no workerModel, for authoritative retries; chained = has workerModel
RT_ROUTER_MODE="${RT_ROUTER_MODE:-authoritative}"  # shadow or authoritative

case "$RT_STATUS_MODE" in
  blank) _or_status="";;
  *)     _or_status="$OR_STATUS_SERVING";;
esac

# Set up the stack row for the retry predicate. The chainless check reads _srow.workerModel.
case "$RT_STACK_MODE" in
  chainless) _srow='{"workerModel":""}' ;;  # Empty workerModel means chainless
  chained)   _srow='{"workerModel":"deepseek/deepseek-v4-flash"}' ;;  # Has a workerModel, so chained
esac

# Set the router mode so the retry predicate can check it.
AGENT_ROUTER="$RT_ROUTER_MODE"

_stats_merge() {   # _stats_merge <key> <json-literal> — fold one field into the STATS line
  STATS="$(jq -cn --argjson s "${STATS:-null}" --arg k "$1" --argjson v "$2" '$s + {($k): $v}')"
}

STATS=""
STRIKE_LINE=""
ERR_CLASS=""
STRIKE_BY_POD="false"
WORK_BRANCH=""
case "$RT_STRIKE" in
  launcher) STRIKE_LINE="AGENT_STRIKE: model=${STRUCK_MODEL} error_class=${RT_CLASS} round=${ROUND} session=${POD}"
            ERR_CLASS="$RT_CLASS";;
  pod)      STRIKE_BY_POD="true"
            _stats_merge error_class "$(jq -cn --arg c "$RT_CLASS" '$c')"
            _stats_merge exit_status '"no-output"'
            # the finalizer folds the SERVED provider into the stats line (agent-finalize:router_report).
            # Parameterised by RT_STATS_PROVIDER so the family can express BOTH worlds: a populated
            # provider (every row but the boundary one) and an ABSENT field (the contract break).
            if [ -n "$RT_STATS_PROVIDER" ]; then
              _stats_merge provider "$(jq -cn --arg p "$RT_STATS_PROVIDER" '$p')"
            fi;;
esac
_strike_provider="$RT_PROVIDER"
case "$RT_SALVAGE" in
  pushed)   _stats_merge salvaged_branch '"agent/20260919-223248"';;
  resuming) WORK_BRANCH="agent/20260919-223248";;
  unknown)  _stats_merge salvage_undetermined 'true';;
esac

# The prior-attempt counters a RE-RUN carries in its environment. Production spells
# AGENT_RETRY_CELLS as a space-separated list of `<model>|<provider>|<class>`; a `|` cannot ride
# the table's `env` column (it is the psv delimiter), so a row declares the ONE prior cell it wants
# as its class alone (model and provider are the bridge's own, so the cell either matches or it
# does not) and the list is assembled here.
AGENT_RETRY_CELLS=""
[ -n "$RT_PRIOR_CLASS" ] && AGENT_RETRY_CELLS="${STRUCK_MODEL}|${_strike_provider}|${RT_PRIOR_CLASS}"
AGENT_RETRY_TASK_N="$RT_PRIOR_N"

# ── the two seams ─────────────────────────────────────────────────────────────────────────────
# retry_rerun — the callee the clause calls on fire. STUBBED: the re-run itself is the launcher's
# own /route consult (the route-request fixtures pin that), so what this fixture pins is the CALL,
# the ASSEMBLED ARGV (proving --model was stripped), and the counters it carries — which is the
# whole acceptance-4 contract. RETRY_RERUN_RC=1 is the re-dispatch that did not complete.
retry_rerun() {
  local _rr_argv_str=""; _rr_i=0; local _rr_model_next=0
  # Rebuild argv string with --model and rail flags stripped, matching the real implementation.
  local _rr_argv=()
  for (( _rr_i=0; _rr_i < ${#ORIG_ARGS[@]}; _rr_i++ )); do
    case "${ORIG_ARGS[$_rr_i]}" in
      --model) (( _rr_i++ )); continue;;
      --openrouter-secret) (( _rr_i++ )); continue;;
      --harness)
        if [ $(( _rr_i + 1 )) -lt ${#ORIG_ARGS[@]} ] && [ "${ORIG_ARGS[$(( _rr_i + 1 ))]}" = "goose" ]; then
          (( _rr_i++ )); continue
        fi
        _rr_argv+=("${ORIG_ARGS[$_rr_i]}")
        ;;
      *) _rr_argv+=("${ORIG_ARGS[$_rr_i]}");;
    esac
  done
  _rr_argv_str="$(printf '%q ' "${_rr_argv[@]}")"
  printf 'CALL retry_rerun ARGV=[%s] AGENT_RETRY_CELLS=[%s] AGENT_RETRY_TASK_N=[%s]\n' \
    "${_rr_argv_str% }" "${AGENT_RETRY_CELLS:-}" "${AGENT_RETRY_TASK_N:-}" >> "$REPLAY_ACTIONS"
  return "${RETRY_RERUN_RC:-0}"
}

# curl — recorded, never executed: the doorbell ring and the /router-status fallback probe. A row
# that wants the probe to ANSWER sets CURL_BODY to the payload it would have served; leaving it
# unset is the unreachable-router condition.
curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  [ -n "${CURL_BODY:-}" ] && printf '%s' "$CURL_BODY"
  return "${CURL_RC:-0}"
}
