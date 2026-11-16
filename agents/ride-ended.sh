#!/usr/bin/env bash
# shellcheck disable=SC2034  # the per-pod variables are the launcher blocks' inputs, read via eval
# ride-ended.sh — the dead-ride recorder: a ride's hard death always leaves its terminal record.
#
#   bash agents/ride-ended.sh <repo>        # the repo's worker namespace (= the repo name)
#
# Called once per repo per scan pass by agents/coordinator-scan.sh (`REPLAY:dead-ride-record`),
# under the scan's own identity (the loop ServiceAccount already reads pods + pods/log in every
# fixer namespace for the pod janitor; GH_TOKEN is the token the coordinator's launches comment
# with). KUBECTL / KUBE arrive from the caller's environment.
#
# WHY. A worker ride's terminal record (`AGENT_STRIKE:` / `KEY-RETRY:` on its issue) has two
# writers today, and a hard death defeats both: the in-pod finalize dies with the container, and
# the launcher's no-stats fallback lives in the LAUNCHER process — which the coordinator runs inside
# its own time-bounded LLM session, so it is usually gone long before the ride ends. Nothing then
# records the death, the issue stays `agent/in-progress`, and the scan cannot decide it.
#
# WHAT. For every ride pod whose `agent` container ended non-zero more than RIDE_ENDED_SETTLE_S ago
# (default 600s — a live launcher writes its own record within seconds of the end, so this pass
# never races it) and whose log carries NO `AGENT_RUN_STATS` line (finalize never ran): run the
# LAUNCHER's own blocks over it — `strike-classifier`, `strike-line-format`, `strike-comment-post`,
# extracted verbatim from agents/agent-session.sh between their REPLAY sentinels, exactly as the
# clause-replay harness composes them. There is no second classifier and no second comment format:
# a change to the launcher's blocks changes this pass in the same commit. `strike-comment-post`
# owns write-once (`session=<pod>` since the pod's creation) and the resumable-branch line.
#
# Read failures write nothing (rule #6): an unreadable pod list, log or comment list skips that
# pod for this pass; the scan's janitor keeps a Failed pod until its agent container ended
# RIDE_ENDED_JANITOR_S (3600s) ago, so later passes have room to retry.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="${1:?usage: ride-ended.sh <repo>}"
NS="$REPO"
KUBECTL="${KUBECTL:-kubectl}"
KUBE="${KUBE:-}"
SETTLE_S="${RIDE_ENDED_SETTLE_S:-600}"
LAUNCHER="${HERE}/agent-session.sh"

# The replay harness's own extractor (agents/replay/run.sh `extract`) — same sentinel grammar.
launcher_block() {
  awk -v n="$1" '
    { line = $0; sub(/^[ \t]+/, "", line) }
    line == "# >>>REPLAY:" n ">>>" { inb = 1; saw_open  = 1; next }
    line == "# <<<REPLAY:" n "<<<" { inb = 0; saw_close = 1; next }
    inb { print }
    END { if (!saw_open || !saw_close) exit 3 }
  ' "$LAUNCHER"
}
BLOCKS=""
for b in strike-classifier strike-line-format strike-comment-post; do
  if ! part="$(launcher_block "$b")" || [ -z "$part" ]; then
    echo "  [$REPO] ⚠ dead-ride record: launcher block \`$b\` not found in agents/agent-session.sh — pass skipped" >&2
    exit 1
  fi
  BLOCKS="${BLOCKS}${part}"$'\n'
done

if ! pods="$("$KUBECTL" $KUBE -n "$NS" get pods -l app=agent-session,project="$REPO" -o json 2>/dev/null)" \
   || ! jq -e '.items' >/dev/null 2>&1 <<<"${pods:-null}"; then
  echo "  [$REPO] ⚠ dead-ride record: pod list unreadable — nothing recorded this pass" >&2
  exit 0
fi

# One row per ended-non-zero, settled ride pod: name, creation, task, round, harness,
# struck model (annotation, else the MODEL env), repo URL, work branch.
rows="$(jq -r --argjson settle "$SETTLE_S" '
  .items[]
  | ([.status.containerStatuses[]? | select(.name == "agent") | .state.terminated | select(. != null)] | first) as $t
  | select($t != null and (($t.exitCode // 0) != 0))
  | select((($t.finishedAt // "") | fromdateiso8601? // null) as $f | $f != null and $f < (now - $settle))
  | ([.spec.containers[]? | select(.name == "agent") | .env[]? | {(.name): (.value // "")}] | add // {}) as $e
  | [ .metadata.name, (.metadata.creationTimestamp // ""), ($e.AGENT_TASK // ""), ($e.AGENT_ROUND // "1"),
      ($e.HARNESS // ""),
      ((.metadata.annotations // {})["agent.teststuff.net/struck-model"] // $e.MODEL // ""),
      ($e.REPO_URL // ""), ($e.WORK_BRANCH // "") ]
  | map(gsub("[\u001f\n]"; " ")) | join("\u001f")' <<<"$pods" 2>/dev/null)" || rows=""

# US (0x1f), not TAB: a whitespace IFS collapses empty fields and would shift every later column.
while IFS=$'\x1f' read -r POD RIDE_SINCE TASK ROUND HARNESS STRUCK_MODEL REPO_URL WORK_BRANCH; do
  [ -n "$POD" ] || continue
  case "$TASK" in issue-*|pr-*) ;; *) continue;; esac   # strike semantics are TASKED rides only
  RUNLOG="$(mktemp)"
  if ! "$KUBECTL" $KUBE -n "$NS" logs "$POD" -c agent > "$RUNLOG" 2>/dev/null; then
    echo "  [$REPO] ⚠ dead-ride record: log of ${POD} unreadable — not recorded this pass" >&2
    rm -f "$RUNLOG"; continue
  fi
  if grep -aq 'AGENT_RUN_STATS ' "$RUNLOG"; then
    rm -f "$RUNLOG"; continue   # finalize ran: its record (and the launcher's stats path) own this ride
  fi
  echo "  [$REPO] dead ride ${POD} (${TASK} r${ROUND}): agent ended non-zero, no AGENT_RUN_STATS — recording it with the launcher's classifier"
  # A subshell per pod: the launcher's blocks set globals (ERR_CLASS, STRIKE_LINE, …) and define
  # harness_fault_sig; nothing may leak from one pod into the next.
  (
    STATS=""; PR_URL=""; BUDGET_MATCH=""; STRIKE_APPLIES=1
    export GH_TOKEN="${GH_TOKEN:-}"
    eval "$BLOCKS"
  )
  rm -f "$RUNLOG"
done <<<"$rows"
exit 0
