#!/usr/bin/env bash
# coordinator-scan — the DETERMINISTIC gate in front of the LLM coordinator (FU-045). The cheap sibling
# of review-reflex.sh: per stack, list open issues/PRs across the stack's repos and answer the boolean
# "is there anything a coordinator TICK would act on?" — and ONLY spawn the LLM coordinator when yes.
# No subscription tokens are ever spent to discover "nothing to do".
#
# Actionability predicate (MUST track agents/coordinator/README.md §State machine — keep in sync):
#   issue: open ∧ `agent-fix` ∧ `agent/queued`                        (ready to dispatch)
#   PR:    open ∧ ¬`major/awaiting-human` ∧ (`major` ∨ `merge-conflict` ∨ reviewDecision=CHANGES_REQUESTED)
# Deliberately EXCLUDES (so the LLM never wakes for a no-op): human-waiting states (`agent/blocked`,
# `major/awaiting-human`), done/merged, and everything on the review-reflex's ARMED track — arming is the
# boundary (docs/agents/merge-path.md). v2 (needs pod/checks access): `agent/in-progress`+worker-done and
# red-beyond-T; the eventual `coordinator-reflex` CronJob that runs `--spawn` on a schedule (FU-050).
#
# STACK SOURCE — `stacks_json()` is the single swap-point: TODAY it reads agents/stacks.json; the FU-045
# TARGET is the cluster, where each stack's -iac repo owns a Crossplane `AgentStack` claim and this reads
# `kubectl get agentstacks -o json`. Policy (repos/models/tools) then lives in the stack, not here.
# See docs/agents/platform-and-stacks.md.
#
#   bash agents/coordinator-scan.sh            # REPORT: per-stack actionable items + the command to run
#   bash agents/coordinator-scan.sh --spawn    # for each stack with work, spawn a headless coordinator tick
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ORG="${ORG:-teststuffstash}"
STACKS_FILE="${STACKS_FILE:-${HERE}/stacks.json}"
SPAWN=""; [ "${1:-}" = "--spawn" ] && SPAWN=1

# The ONE source of the stack list. TODAY: agents/stacks.json. FUTURE (FU-045/FU-048): the cluster —
#   kubectl get agentstacks.platform.homelab -o json \
#     | jq '{stacks:[.items[]|{name:.metadata.name,repos:.spec.repos}]}'
stacks_json() { cat "$STACKS_FILE"; }

any_work=""
for name in $(stacks_json | jq -r '.stacks[].name'); do
  repos="$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|.repos[]' | tr '\n' ' ')"
  items=""; orphans=""
  for repo in $repos; do
    slug="$ORG/$repo"
    # gh's built-in --jq keeps this to one repo-read scope — no statusCheckRollup (checks:read) needed.
    iss="$(gh issue list --repo "$slug" --state open --json number,title,labels \
      --jq '[.[]|(.labels|map(.name)) as $L|select(($L|index("agent-fix")) and ($L|index("agent/queued")))|"  issue #\(.number) — \(.title)"]|.[]' 2>/dev/null || true)"
    prs="$(gh pr list --repo "$slug" --state open --json number,title,labels,reviewDecision \
      --jq '[.[]|(.labels|map(.name)) as $L|select((($L|index("major/awaiting-human"))|not) and (($L|index("major")) or ($L|index("merge-conflict")) or (.reviewDecision=="CHANGES_REQUESTED")))|"  PR #\(.number) — \(.title)"]|.[]' 2>/dev/null || true)"
    # BACKSTOP: a dependency PR that is un-armed AND carries NO lane label (automerge/deps-review/major)
    # is owned by NOBODY — not the renovate-approve reflex (needs `automerge`), not the review reflex
    # (needs armed), not the coordinator (needs `major`). Renovate is meant to classify+arm every bump, so
    # this catches its escapes: a disabled-manager leftover, a stale pre-classification PR, or a human's
    # dep PR. Report-only (NOT a spawn — the coordinator doesn't own dep classification, Renovate does).
    orph="$(gh pr list --repo "$slug" --state open --json number,title,labels,autoMergeRequest \
      --jq '[.[]|(.labels|map(.name)) as $L|select(($L|index("dependencies")) and (.autoMergeRequest==null) and (([$L[]|select(.=="automerge" or .=="deps-review" or .=="major")]|length)==0))|"  PR #\(.number) — \(.title)"]|.[]' 2>/dev/null || true)"
    [ -n "$iss" ]  && items="${items}[$repo]\n${iss}\n"
    [ -n "$prs" ]  && items="${items}[$repo]\n${prs}\n"
    [ -n "$orph" ] && orphans="${orphans}[$repo]\n${orph}\n"
  done

  [ -n "$orphans" ] && { echo "stack ${name}: ⚠ ORPHANED dep PRs (un-armed + unclassified — classify or close; Renovate didn't lane them):"; printf '%b' "$orphans"; }

  if [ -z "$items" ]; then
    echo "stack ${name}: nothing actionable"
    continue
  fi
  any_work=1
  echo "stack ${name}: ACTIONABLE —"
  printf '%b' "$items"

  if [ -n "$SPAWN" ]; then
    echo "→ spawning headless coordinator tick for ${name}…"
    bash "${HERE}/coordinator-session.sh" --stack "$name" --repos "${repos% }" --run-tick
  else
    echo "  run it (interactive, supervised):"
    echo "    devbox run coordinator-session -- --stack ${name} --repos \"${repos% }\" --tick"
  fi
done

[ -n "$any_work" ] || echo "no stack has actionable work — nothing to spawn (no LLM woken)."
