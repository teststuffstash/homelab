#!/usr/bin/env bash
# coordinator-scan — the DETERMINISTIC gate in front of the LLM coordinator (FU-045). The cheap sibling
# of review-reflex.sh: per stack, list open issues/PRs across the stack's repos and answer the boolean
# "is there anything a coordinator TICK would act on?" — and ONLY spawn the LLM coordinator when yes.
# No subscription tokens are ever spent to discover "nothing to do".
#
# Actionability predicate (MUST track agents/coordinator/README.md §State machine — keep in sync):
#   issue: open ∧ `agent-fix` ∧ `agent/queued`                        (ready to dispatch)
#   PR:    open ∧ ¬`major/awaiting-human` ∧ (`major` ∨ `merge-conflict` ∨ reviewDecision=CHANGES_REQUESTED)
#   v2:    issue open ∧ `agent-fix` ∧ `agent/in-progress` ∧ no Running worker pod ∧ no open PR
#          referencing it (C4/C5 — a worker went terminal and nothing re-ticked; pod read via
#          kubectl, probe failures skip the clause rather than fail into a wake)
# Deliberately EXCLUDES (so the LLM never wakes for a no-op): human-waiting states (`agent/blocked`,
# `major/awaiting-human`), done/merged, and everything on the review-reflex's ARMED track — arming is the
# boundary (docs/agents/merge-path.md). Still v3 territory: red-beyond-T (needs checks:read). The
# `coordinator-reflex` CronJob (agents/coordinator/coordinator-reflex.yaml, FU-050) runs `--spawn` on a
# schedule — deployed SUSPENDED until the operator flips it (kubectl patch cronjob coordinator-reflex
# -n agent-coordinator -p '{"spec":{"suspend":false}}').
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

# kubectl for the v2 (C4/C5) predicate — same resolution as agent-session.sh: jail → tofu/kubeconfig;
# in-cluster (the coordinator-reflex CronJob) → the pod ServiceAccount (KUBE empty).
if [ -f "${HERE}/../tofu/kubeconfig" ]; then KUBE="--kubeconfig ${HERE}/../tofu/kubeconfig"; else KUBE=""; fi
KUBECTL="$(command -v kubectl || true)"
[ -n "$KUBECTL" ] || KUBECTL="${HERE}/../.devbox/nix/profile/default/bin/kubectl"

# The ONE source of the stack list (FU-048): cluster `AgentStack` claims first, stacks.json for
# stacks not yet migrated (cluster wins per stack name). PROBE-FIRST (meta-5 principle): a failed
# kubectl read is PROBE-FAILED — warn loudly + fall back to the file, never silently drop a
# migrated stack (migrated entries stay in stacks.json as the belt until the in-cluster reflex
# path is verified reading claims). Cached: one cluster read per scan.
STACKS_CACHE=""
stacks_json() {
  [ -n "$STACKS_CACHE" ] && { printf '%s' "$STACKS_CACHE"; return; }
  local file cluster
  file="$(cat "$STACKS_FILE")"
  if cluster="$($KUBECTL $KUBE get agentstacks.platform.teststuff.net -o json 2>/dev/null)"; then
    STACKS_CACHE="$(jq -n --argjson c "$cluster" --argjson f "$file" '
      (($c.items // []) | map({
        name: .metadata.name,
        repos: [.spec.repos[].name],
        mainRepo: (.spec.mainRepo // "homelab"),
        coordinatorModel: (.spec.coordinatorModel // "sonnet"),
        workerModel: .spec.workerModel,
        workerModelFallbacks: (.spec.workerModelFallbacks // [])
      })) as $claims
      | {stacks: ($claims + [$f.stacks[] | select(.name as $n | $claims | all(.name != $n))])}
    ')"
  else
    echo "WARN coordinator-scan: agentstacks read PROBE-FAILED — stack list from ${STACKS_FILE} only" >&2
    STACKS_CACHE="$file"
  fi
  printf '%s' "$STACKS_CACHE"
}
# Populate the cache HERE, in the main shell — every later call sites inside $(…) subshells, where
# an assignment would not survive. One cluster read per scan, not one per jq lookup.
STACKS_CACHE="$(stacks_json)"

any_work=""
for name in $(stacks_json | jq -r '.stacks[].name'); do
  repos="$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|.repos[]' | tr '\n' ' ')"
  # mainRepo is stack POLICY (the coordinator's cwd; FU-045) — default homelab for stacks whose
  # deploy/agent knowledge still lives in homelab docs.
  mainrepo="$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|.mainRepo // "homelab"')"
  items=""; orphans=""
  for repo in $repos; do
    slug="$ORG/$repo"
    # gh's built-in --jq keeps this to one repo-read scope — no statusCheckRollup (checks:read) needed.
    # `direction-change` (C10): a human reversed direction (language/architecture) — every carrying
    # item needs a human SWEEP (re-scope the issue / close the PR + delete its branch) BEFORE any
    # dispatch, or the tick works a dead assumption (live 2026-07-09: the TS→Python flip left a
    # CHANGES_REQUESTED PR the scan would happily have burned a round on). Excluded + reported.
    iss="$(gh issue list --repo "$slug" --state open --json number,title,labels \
      --jq '[.[]|(.labels|map(.name)) as $L|select(($L|index("agent-fix")) and ($L|index("agent/queued")) and (($L|index("direction-change"))|not))|"  issue #\(.number) — \(.title)"]|.[]' 2>/dev/null || true)"
    swept="$(gh issue list --repo "$slug" --state open --json number,title,labels \
      --jq '[.[]|(.labels|map(.name)) as $L|select($L|index("direction-change"))|"  issue #\(.number) — \(.title)"]|.[]' 2>/dev/null || true)"
    [ -n "$swept" ] && orphans="${orphans}[$repo] ⚠ direction-change — human sweep needed BEFORE dispatch:\n${swept}\n"
    # `major` is now set on Renovate majors too (renovate-global.json), so gate the major clause on
    # UN-ARMED — an armed PR is the review reflex's, never the coordinator's (arming is the boundary).
    prs="$(gh pr list --repo "$slug" --state open --json number,title,labels,reviewDecision,autoMergeRequest \
      --jq '[.[]|(.labels|map(.name)) as $L|select((($L|index("major/awaiting-human"))|not) and ((($L|index("major")) and (.autoMergeRequest==null)) or ($L|index("merge-conflict")) or (.reviewDecision=="CHANGES_REQUESTED")))|"  PR #\(.number) — \(.title)"]|.[]' 2>/dev/null || true)"
    # BACKSTOP: a dependency PR that is un-armed AND carries NO lane label (automerge/deps-review/major)
    # is owned by NOBODY — not the renovate-approve reflex (needs `automerge`), not the review reflex
    # (needs armed), not the coordinator (needs `major`). Renovate is meant to classify+arm every bump, so
    # this catches its escapes: a disabled-manager leftover, a stale pre-classification PR, or a human's
    # dep PR. Report-only (NOT a spawn — the coordinator doesn't own dep classification, Renovate does).
    orph="$(gh pr list --repo "$slug" --state open --json number,title,labels,autoMergeRequest \
      --jq '[.[]|(.labels|map(.name)) as $L|select(($L|index("dependencies")) and (.autoMergeRequest==null) and (([$L[]|select(.=="automerge" or .=="deps-review" or .=="major")]|length)==0))|"  PR #\(.number) — \(.title)"]|.[]' 2>/dev/null || true)"
    # v2 (FU-050, C4/C5): an `agent/in-progress` issue whose worker went TERMINAL is a silent stall
    # until someone re-ticks — this was meta-only work all through meta-session 2. actionable =
    # in-progress ∧ no Running worker pod in the project ns ∧ no OPEN PR referencing the issue (an
    # open PR means the merge-path reflexes own it, and blocked issues never carry in-progress).
    # A kubectl probe failure is reported and SKIPS the clause — it never fails INTO a wake
    # (rule #6); the launcher pre-flight is the double-dispatch belt either way.
    v2=""
    inprog="$(gh issue list --repo "$slug" --state open --json number,title,labels \
      --jq '[.[]|(.labels|map(.name)) as $L|select(($L|index("agent-fix")) and ($L|index("agent/in-progress")))]' 2>/dev/null || echo '[]')"
    if [ "$(printf '%s' "$inprog" | jq 'length')" -gt 0 ]; then
      if PODS="$("$KUBECTL" $KUBE -n "$repo" get pods -l app=agent-session,project="$repo" \
            --field-selector=status.phase=Running --no-headers 2>/dev/null)"; then
        if [ -z "$PODS" ]; then
          BODIES="$(gh pr list --repo "$slug" --state open --json body --jq '[.[].body]' 2>/dev/null || echo '[]')"
          v2="$(printf '%s' "$inprog" | jq -r --argjson bodies "$BODIES" \
            '.[] | .number as $n
             | select(([$bodies[] | select(test("#\($n)\\b"))] | length) == 0)
             | "  issue #\($n) — \(.title) [in-progress, worker terminal, no PR → C4/C5 re-tick]"')"
        fi
      else
        echo "  [$repo] PROBE_FAILED reading worker pods — C4/C5 clause skipped this tick (fail-loud, rule #6)" >&2
      fi
    fi
    # BACKSTOP (C10 leftover class): an agent-pattern branch (fix/*, feat/*, agent/*) with NO open
    # PR is a closed-PR leftover — a same-named future round dies non-fast-forward on it (live
    # 2026-07-09, defused by hand). Report-only; the fix is `gh pr close --delete-branch` hygiene.
    heads="$(gh api "repos/$slug/branches?per_page=100" --jq '[.[].name | select(test("^(fix|feat|agent)/"))]' 2>/dev/null || echo '[]')"
    prheads="$(gh pr list --repo "$slug" --state open --json headRefName --jq '[.[].headRefName]' 2>/dev/null || echo '[]')"
    stale="$(jq -rn --argjson h "$heads" --argjson p "$prheads" '$h - $p | .[] | "  branch \(.) — no open PR (stale; delete or resume)"')"
    [ -n "$stale" ] && orphans="${orphans}[$repo] ⚠ stale agent branches:\n${stale}\n"
    [ -n "$iss" ]  && items="${items}[$repo]\n${iss}\n"
    [ -n "$v2" ]   && items="${items}[$repo]\n${v2}\n"
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
    bash "${HERE}/coordinator-session.sh" --stack "$name" --repos "${repos% }" --main-repo "$mainrepo" --run-tick
  else
    echo "  run it (interactive, supervised):"
    echo "    devbox run coordinator-session -- --stack ${name} --repos \"${repos% }\" --main-repo ${mainrepo} --tick"
  fi
done

[ -n "$any_work" ] || echo "no stack has actionable work — nothing to spawn (no LLM woken)."
