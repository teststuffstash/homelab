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
# `major/awaiting-human`), the `agent/error` anomaly-breaker items (FU-069 — human-first,
# report-only), done/merged, and everything on the review-reflex's ARMED track — arming is the
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
        workerModelFallbacks: (.spec.workerModelFallbacks // []),
        # FU-080 per-stack autonomy knob: only spawn the LLM coordinator for a stack that opted in
        # (default false). Graduated autonomy — enable a proven stack while newer ones stay off.
        coordinatorEnabled: (.spec.coordinator.enabled // false),
        # repos whose fixer declared docker=true: dispatch their workers with
        # agent-session.sh --docker (kata microVM + dind — the CI-gate runtime choice)
        dockerRepos: [.spec.repos[] | select(.fixer.docker == true) | .name],
        # ADR-094 dispatchability predicate: only repos with a fixer block can run workers —
        # a context-only repo (oracle-iac) becomes a VISIBLE predicate, not an implicit
        # clone-but-cant-work state. Absent from the file fallback → null → treated as unknown
        # (all repos dispatchable — the belt stays permissive, never silently narrower).
        fixerRepos: [.spec.repos[] | select(.fixer) | .name]
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
  # FU-080 perStack: a stack-scoped instance (the coordinate-<stack> CronWorkflow in
  # <stack>-agents sets SCAN_STACK) scans ONLY its own stack; the global reflex keeps sweeping
  # everything as the migration belt.
  [ -n "${SCAN_STACK:-}" ] && [ "$name" != "$SCAN_STACK" ] && continue
  repos="$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|.repos[]' | tr '\n' ' ')"
  # mainRepo is stack POLICY (the coordinator's cwd; FU-045) — default homelab for stacks whose
  # deploy/agent knowledge still lives in homelab docs.
  mainrepo="$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|.mainRepo // "homelab"')"
  items=""; orphans=""; units=""
  # ADR-094 dispatchability: repos with a fixer block (from the claim; null = unknown → permissive)
  fixer_repos="$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|(.fixerRepos // ["__ALL__"])[]' | tr '\n' ' ')"
  for repo in $repos; do
    slug="$ORG/$repo"
    case " $fixer_repos" in *" __ALL__ "*|*" $repo "*) dispatchable=1;; *) dispatchable="";; esac
    # gh's built-in --jq keeps this to one repo-read scope — no statusCheckRollup (checks:read) needed.
    # `direction-change` (C10): a human reversed direction (language/architecture) — every carrying
    # item needs a human SWEEP (re-scope the issue / close the PR + delete its branch) BEFORE any
    # dispatch, or the tick works a dead assumption (live 2026-07-09: the TS→Python flip left a
    # CHANGES_REQUESTED PR the scan would happily have burned a round on). Excluded + reported.
    # FU-087: `Depends-on: [<org>/<repo>]#N[, …]` issue-body lines gate the queue — the
    # machine-readable dependency graph, mirroring the `Fixes #N` idiom (bare #N = same repo).
    # Level-triggered each scan: any referenced issue still OPEN → the issue is ⏳ queued-blocked
    # (reported, never dispatched; closure is seen next pass — *closed* is the right satisfaction
    # proxy because `Fixes #N` closes on merge). A dep closed as NOT-PLANNED → still actionable
    # but flagged stale (the dependent's premise may have died with it). A direct A↔B cycle →
    # human-first report (agent/error style), not dispatched. A FAILED dep probe blocks
    # CONSERVATIVELY with a PROBE-FAILED marker — rule #6: never fail INTO a dispatch.
    queued="$(gh issue list --repo "$slug" --state open --json number,title,labels,body \
      --jq '[.[]|(.labels|map(.name)) as $L|select(($L|index("agent-fix")) and ($L|index("agent/queued")) and (($L|index("direction-change"))|not) and (($L|index("agent/error"))|not))] | sort_by(.number)' 2>/dev/null)" || queued='[]'
    jq -e . >/dev/null 2>&1 <<<"$queued" || queued='[]'
    # In-progress issues once per repo — the C4/C5 clause below AND the ADR-094 lane predicate
    # (`track/*` labels = the human-declared independence assertion; ≤1 in flight per lane) read it.
    # NB agent/error stays IN this fetch (an error-flagged in-progress issue still holds its
    # lane — a human is on it) but is excluded from the C4/C5 clause below: FU-069 makes it
    # invisible to every ACTIONABLE clause (missed on the first item-mode cut — two workers were
    # dispatched INTO a breaker-flagged issue 2026-07-21 before the breaker was cleared).
    inprog="$(gh issue list --repo "$slug" --state open --json number,title,labels \
      --jq '[.[]|(.labels|map(.name)) as $L|select(($L|index("agent-fix")) and ($L|index("agent/in-progress")))]' 2>/dev/null || echo '[]')"
    jq -e . >/dev/null 2>&1 <<<"$inprog" || inprog='[]'
    busy_tracks="$(printf '%s' "$inprog" | jq -r '.[].labels[].name | select(startswith("track/"))' | sort -u | tr '\n' ' ')"
    # ADR-094 project-WIP predicate (found live meta-8: two dispatchers raced #52 inside one scan
    # window; 2026-07-21 #55: two CRON ticks raced through the phase=Running filter while a kata
    # pod sat Pending — so the probe counts everything non-terminal): a live worker in the repo
    # ns HOLDS this repo's queued-dispatch units — the
    # launcher's WIP=1 pre-flight would refuse the spawn anyway; better to never wake the session.
    # Probe-first: a FAILED pod probe leaves the units flowing (the launcher refusal is the belt).
    wip_busy=""
    if WIPPODS_JSON="$("$KUBECTL" $KUBE -n "$repo" get pods -l app=agent-session,project="$repo" \
          --field-selector=status.phase!=Succeeded,status.phase!=Failed -o json 2>/dev/null)"; then
      jq -e . >/dev/null 2>&1 <<<"$WIPPODS_JSON" || WIPPODS_JSON='{"items":[]}'
      # ZOMBIE REAP belt (2026-07-21 — the 3-day post-#56 stall): a pod whose agent container
      # terminated but whose sidecar lives (pre-native-sidecar dind) is phase=Running yet holds
      # no work — it wedges this hold AND the launcher WIP=1 forever. Reap when the agent
      # finished >30min ago (in-pod bookkeeping/stats/transcripts are long out by then; the
      # margin keeps a just-finished pod readable per the meta-2 rule), and never count it busy.
      for z in $(printf '%s' "$WIPPODS_JSON" | jq -r '.items[]
          | select([.status.containerStatuses[]? | select(.name == "agent") | .state.terminated
                    | select(. != null and (.finishedAt | fromdateiso8601) < (now - 1800))] | length > 0)
          | .metadata.name'); do
        echo "  [$repo] reaping zombie worker ${z} (agent terminated >30m ago; sidecar held the pod Running)"
        "$KUBECTL" $KUBE -n "$repo" delete pod "$z" --ignore-not-found >/dev/null 2>&1 || true
      done
      live="$(printf '%s' "$WIPPODS_JSON" | jq -r '[.items[]
          | select(([.status.containerStatuses[]? | select(.name == "agent") | .state.terminated] | length) == 0)] | length')"
      [ "${live:-0}" -gt 0 ] 2>/dev/null && wip_busy=1
    fi
    # FU-090 visibility slice: bot-authored issues without `agent-fix` are harvested/drafted work
    # awaiting HUMAN triage (TICK-LOG §Loop-safety breaker #1 keeps them inert) — surface them so
    # they never rot silently.
    sprouts="$(gh issue list --repo "$slug" --state open --json number,title,author,labels \
      --jq '[.[]|select((.author.is_bot == true) and (((.labels|map(.name))|index("agent-fix"))|not))|"  issue #\(.number) — \(.title) (by \(.author.login))"]|.[]' 2>/dev/null || true)"
    [ -n "$sprouts" ] && orphans="${orphans}[$repo] 🌱 bot-authored, awaiting human triage (FU-090 gate — label agent-fix[+queued] to adopt):\n${sprouts}\n"
    iss=""; qblocked=""; qcycles=""
    while IFS="$(printf '\t')" read -r qnum qtitle qtracks qdeps; do
      [ -n "$qnum" ] || continue
      blocked=""; stale=""
      for dep in $(printf '%s' "$qdeps" | tr ',' ' '); do
        dnum="${dep##*#}"; dslug="$slug"
        case "$dep" in *"/"*"#"*) dslug="${dep%#*}";; esac
        case "$dnum" in ''|*[!0-9]*) continue;; esac  # not a #N token — ignore, don't guess
        if depjson="$(gh issue view "$dnum" --repo "$dslug" --json state,stateReason,body 2>/dev/null </dev/null)"; then
          if [ "$(jq -r .state <<<"$depjson")" = "OPEN" ]; then
            blocked="${blocked} ${dslug}#${dnum}"
            # direct 2-cycle: the dependency's own Depends-on lines point back at this issue.
            # A bare #N in the dep's body refers to the DEP's repo — only equal-repo bare refs count.
            if [ "$dslug" = "$slug" ]; then revpat="(${slug})?#${qnum}"; else revpat="${slug}#${qnum}"; fi
            if jq -r '.body // ""' <<<"$depjson" | grep -iE '^[[:space:]]*depends-on:' | grep -qE "(^|[ ,:])${revpat}([ ,]|\$)"; then
              qcycles="${qcycles}  issue #${qnum} ↔ ${dslug}#${dnum} — mutual Depends-on\n"
            fi
          elif [ "$(jq -r '.stateReason // ""' <<<"$depjson")" = "NOT_PLANNED" ]; then
            stale="${stale} ${dslug}#${dnum}"
          fi
        else
          blocked="${blocked} ${dslug}#${dnum}(PROBE-FAILED)"
        fi
      done
      if [ -n "$blocked" ]; then
        qblocked="${qblocked}  issue #${qnum} — ${qtitle} (waiting${blocked})\n"
        continue
      fi
      # ADR-094 scheduling predicates (deterministic — the LLM never picks):
      if [ -z "$dispatchable" ]; then
        orphans="${orphans}[$repo] ⚠ queued but NOT dispatchable (no fixer block — context-only repo; jail work):\n  issue #${qnum} — ${qtitle}\n"
        continue
      fi
      lane_busy=""
      for t in $(printf '%s' "$qtracks" | tr ',' ' '); do
        case " $busy_tracks" in *" $t "*) lane_busy="$t";; esac
      done
      if [ -n "$lane_busy" ]; then
        orphans="${orphans}[$repo] ⏳ lane busy (ADR-094: ≤1 in flight per track):\n  issue #${qnum} — ${qtitle} (lane ${lane_busy} has an in-progress issue)\n"
        continue
      fi
      if [ -n "$wip_busy" ]; then
        orphans="${orphans}[$repo] ⏳ project WIP busy (a worker is Running in ${repo} — launcher WIP=1):\n  issue #${qnum} — ${qtitle}\n"
        continue
      fi
      if [ -n "$stale" ]; then
        iss="${iss}  issue #${qnum} — ${qtitle} [⚠ dep${stale} closed as not-planned — premise may be dead]\n"
      else
        iss="${iss}  issue #${qnum} — ${qtitle}\n"
      fi
      units="${units}queued-dispatch|${repo}|issue-${qnum}\n"
    done < <(printf '%s' "$queued" | jq -r '.[] | [ .number, .title, ([.labels[].name | select(startswith("track/"))] | join(",")), ([(.body // "") | scan("(?mi)^[ \\t]*depends-on:[ \\t]*(.+)$")] | flatten | join(", ")) ] | @tsv')
    iss="$(printf '%b' "$iss")"  # the emitters below expect newline-joined plain text
    [ -n "$qblocked" ] && orphans="${orphans}[$repo] ⏳ queued-blocked (FU-087 Depends-on; closure is seen next scan):\n${qblocked}"
    [ -n "$qcycles" ] && orphans="${orphans}[$repo] ⚠ Depends-on CYCLE (FU-087) — human-first, neither side dispatched:\n${qcycles}"
    swept="$(gh issue list --repo "$slug" --state open --json number,title,labels \
      --jq '[.[]|(.labels|map(.name)) as $L|select($L|index("direction-change"))|"  issue #\(.number) — \(.title)"]|.[]' 2>/dev/null || true)"
    [ -n "$swept" ] && orphans="${orphans}[$repo] ⚠ direction-change — human sweep needed BEFORE dispatch:\n${swept}\n"
    # FU-069(a): `agent/error` = the anomaly circuit-breaker (merge-path.md §Runaway dispatch) —
    # HUMAN-FIRST, excluded from every actionable clause above/below. Reported so it never rots
    # silently, but a tick must not touch it (no dispatch, no relabel, no arbitration).
    errs="$( { gh issue list --repo "$slug" --state open --json number,title,labels \
        --jq '[.[]|(.labels|map(.name)) as $L|select($L|index("agent/error"))|"  issue #\(.number) — \(.title)"]|.[]' 2>/dev/null || true; \
      gh pr list --repo "$slug" --state open --json number,title,labels \
        --jq '[.[]|(.labels|map(.name)) as $L|select($L|index("agent/error"))|"  PR #\(.number) — \(.title)"]|.[]' 2>/dev/null || true; } )"
    [ -n "$errs" ] && orphans="${orphans}[$repo] ⚠ agent/error (anomaly breaker, FU-069) — human-first, NOT dispatched:\n${errs}\n"
    # `major` is now set on Renovate majors too (renovate-global.json), so gate the major clause on
    # UN-ARMED — an armed PR is the review reflex's, never the coordinator's (arming is the boundary).
    prsjson="$(gh pr list --repo "$slug" --state open --json number,title,labels,reviewDecision,autoMergeRequest 2>/dev/null)" || prsjson='[]'
    jq -e . >/dev/null 2>&1 <<<"$prsjson" || prsjson='[]'
    prs="$(printf '%s' "$prsjson" | jq -r '[.[]|(.labels|map(.name)) as $L|select((($L|index("major/awaiting-human"))|not) and (($L|index("agent/error"))|not) and ((($L|index("major")) and (.autoMergeRequest==null)) or ($L|index("merge-conflict")) or (.reviewDecision=="CHANGES_REQUESTED")))|"  PR #\(.number) — \(.title)"]|.[]')"
    # ADR-094 units: each predicate row IS an action class — (clause, repo, item), the LLM never picks.
    for u in $(printf '%s' "$prsjson" | jq -r '.[]|(.labels|map(.name)) as $L|select((($L|index("major/awaiting-human"))|not) and (($L|index("agent/error"))|not) and (.reviewDecision=="CHANGES_REQUESTED"))|.number'); do
      # ADR-094 project-WIP hold, same rationale as the queued gate above (meta-9, 2026-07-21:
      # while #60's fix round ran, every tick woke a redundant judge whose dispatch the launcher's
      # WIP=1 pre-flight would refuse — the Running worker IS this unit's in-flight work; C4/C5
      # re-emits if it dies, and the next bot verdict retires the clause).
      if [ -n "$wip_busy" ]; then
        orphans="${orphans}[$repo] ⏳ changes-requested trigger held (worker Running in ${repo} — launcher WIP=1):\n  PR #${u}\n"
        continue
      fi
      units="${units}changes-requested|${repo}|pr-${u}\n"
    done
    for u in $(printf '%s' "$prsjson" | jq -r '.[]|(.labels|map(.name)) as $L|select((($L|index("agent/error"))|not) and ($L|index("merge-conflict")) and (.reviewDecision!="CHANGES_REQUESTED"))|.number'); do
      units="${units}merge-conflict|${repo}|pr-${u}\n"
    done
    for u in $(printf '%s' "$prsjson" | jq -r '.[]|(.labels|map(.name)) as $L|select((($L|index("major/awaiting-human"))|not) and (($L|index("agent/error"))|not) and ($L|index("major")) and (.autoMergeRequest==null) and (.reviewDecision!="CHANGES_REQUESTED") and (($L|index("merge-conflict"))|not))|.number'); do
      units="${units}unarmed-major|${repo}|pr-${u}\n"
    done
    # BACKSTOP (FU-079, generalizes the old dep-only clause): an un-armed open PR that no lane owns
    # is invisible to the ENTIRE merge path — the updater, review reflex, and auto-merge all key on
    # armed PRs (by design), so it stalls silently (live: oracle-fleet#16, a stacked PR born
    # un-armed, stuck at ci "Expected" then BEHIND). Owned lanes excluded: automerge/deps-review
    # (their reflexes arm), un-armed `major` + merge-conflict + CHANGES_REQUESTED (coordinator
    # actionable, above), major/awaiting-human (parked on a human by design), agent/error
    # (human-first). Report-only: the fix is `gh pr merge --auto` or an explicit parking label —
    # arm-at-open is operator discipline (merge-path.md).
    orph="$(gh pr list --repo "$slug" --state open --json number,title,labels,reviewDecision,autoMergeRequest \
      --jq '[.[]|(.labels|map(.name)) as $L|select((.autoMergeRequest==null)
        and (([$L[]|select(.=="automerge" or .=="deps-review" or .=="major" or .=="major/awaiting-human" or .=="merge-conflict" or .=="agent/error")]|length)==0)
        and (.reviewDecision!="CHANGES_REQUESTED"))|"  PR #\(.number) — \(.title)"]|.[]' 2>/dev/null || true)"
    # v2 (FU-050, C4/C5): an `agent/in-progress` issue whose worker went TERMINAL is a silent stall
    # until someone re-ticks — this was meta-only work all through meta-session 2. actionable =
    # in-progress ∧ no Running worker pod in the project ns ∧ no OPEN PR referencing the issue (an
    # open PR means the merge-path reflexes own it, and blocked issues never carry in-progress).
    # A kubectl probe failure is reported and SKIPS the clause — it never fails INTO a wake
    # (rule #6); the launcher pre-flight is the double-dispatch belt either way.
    v2=""
    if [ "$(printf '%s' "$inprog" | jq 'length')" -gt 0 ]; then
      if PODS="$("$KUBECTL" $KUBE -n "$repo" get pods -l app=agent-session,project="$repo" \
            --field-selector=status.phase!=Succeeded,status.phase!=Failed --no-headers 2>/dev/null)"; then
        if [ -z "$PODS" ]; then
          BODIES="$(gh pr list --repo "$slug" --state open --json body --jq '[.[].body]' 2>/dev/null || echo '[]')"
          v2="$(printf '%s' "$inprog" | jq -r --argjson bodies "$BODIES" \
            '.[] | select(((.labels|map(.name))|index("agent/error"))|not) | .number as $n
             | select(([$bodies[] | select(test("#\($n)\\b"))] | length) == 0)
             | "  issue #\($n) — \(.title) [in-progress, worker terminal, no PR → C4/C5 re-tick]"')"
          if [ -n "$dispatchable" ]; then
            for u in $(printf '%s' "$inprog" | jq -r --argjson bodies "$BODIES" \
                '.[] | select(((.labels|map(.name))|index("agent/error"))|not)
                 | .number as $n | select(([$bodies[] | select(test("#\($n)\\b"))] | length) == 0) | .number'); do
              units="${units}c4c5-redispatch|${repo}|issue-${u}\n"
            done
          fi
        fi
      else
        echo "  [$repo] PROBE_FAILED reading worker pods — C4/C5 clause skipped this tick (fail-loud, rule #6)" >&2
      fi
    fi
    # BACKSTOP (C10 leftover class): an agent-pattern branch (fix/*, feat/*, agent/*) with NO open
    # PR is a closed-PR leftover — a same-named future round dies non-fast-forward on it (live
    # 2026-07-09, defused by hand). Report-only; the fix is `gh pr close --delete-branch` hygiene.
    # NB the fallback must live OUTSIDE the $() — `gh api` prints the error BODY to stdout on a 404,
    # so `$(gh … || echo '[]')` concatenates body+[] (live crash 2026-07-12, a nonexistent claim repo).
    # Meta-5 probe rule: a failed probe's stdout is NOT a value — validate or zero it.
    heads="$(gh api "repos/$slug/branches?per_page=100" --jq '[.[].name | select(test("^(fix|feat|agent)/"))]' 2>/dev/null)" || heads='[]'
    prheads="$(gh pr list --repo "$slug" --state open --json headRefName --jq '[.[].headRefName]' 2>/dev/null)" || prheads='[]'
    jq -e . >/dev/null 2>&1 <<<"$heads" || heads='[]'
    jq -e . >/dev/null 2>&1 <<<"$prheads" || prheads='[]'
    stale="$(jq -rn --argjson h "$heads" --argjson p "$prheads" '$h - $p | .[] | "  branch \(.) — no open PR (stale; delete or resume)"')"
    [ -n "$stale" ] && orphans="${orphans}[$repo] ⚠ stale agent branches:\n${stale}\n"
    [ -n "$iss" ]  && items="${items}[$repo]\n${iss}\n"
    [ -n "$v2" ]   && items="${items}[$repo]\n${v2}\n"
    [ -n "$prs" ]  && items="${items}[$repo]\n${prs}\n"
    [ -n "$orph" ] && orphans="${orphans}[$repo] ⚠ un-armed open PRs (invisible to the merge path — arm or park, FU-079):\n${orph}\n"
  done

  [ -n "$orphans" ] && { echo "stack ${name}: ⚠ REPORT-ONLY items (human attention; the tick does not touch these):"; printf '%b' "$orphans"; }

  if [ -z "$items" ]; then
    echo "stack ${name}: nothing actionable"
    continue
  fi
  any_work=1
  echo "stack ${name}: ACTIONABLE —"
  printf '%b' "$items"

  # FU-080 coordinator knob: default-off, opt in per stack via the claim's spec.coordinator.enabled.
  coord_enabled="$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|.coordinatorEnabled // false')"
  if [ -n "$SPAWN" ] && [ "$coord_enabled" != "true" ]; then
    echo "  coordinator.enabled=false for stack ${name} — NOT spawning (report-only; enable in the AgentStack claim)."
    continue
  fi
  if [ -n "$SPAWN" ]; then
    # ADR-094/FU-086 item dispatch: the scan SCHEDULES (one highest-priority unit — WIP=1; the
    # FU-088 gates are the belt), the session JUDGES one item. Priority finishes in-flight work
    # before starting new: c4c5 > changes-requested > merge-conflict > unarmed-major > queued.
    # SCAN_ITEM_MODE=0 = rollback to the whole-stack tick (also the janitor/manual path).
    if ! bash "${HERE}/subscription-latch.sh"; then
      echo "  capacity: subscription limited (FU-088) — no dispatch this pass (level-triggered; next scan re-checks)."
      continue
    fi
    if [ "${SCAN_ITEM_MODE:-1}" = "0" ]; then
      echo "→ spawning headless coordinator tick for ${name} (SCAN_ITEM_MODE=0 whole-stack mode)…"
      bash "${HERE}/coordinator-session.sh" --stack "$name" --repos "${repos% }" --main-repo "$mainrepo" --run-tick
      continue
    fi
    unit=""
    for clause in c4c5-redispatch changes-requested merge-conflict unarmed-major queued-dispatch; do
      unit="$(printf '%b' "$units" | grep -m1 "^${clause}|" || true)"
      [ -n "$unit" ] && break
    done
    if [ -z "$unit" ]; then
      echo "  actionable items but no dispatchable unit (context-only repos / gated) — report-only."
      continue
    fi
    uclause="${unit%%|*}"; rest="${unit#*|}"; urepo="${rest%%|*}"; uitem="${rest#*|}"
    cmodel="$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|.coordinatorModel // "sonnet"')"
    echo "→ dispatching item unit for ${name}: ${urepo} ${uitem} (${uclause}, model ${cmodel})…"
    # FU-080 perStack: under a stack-scoped instance the item session runs in the loop home
    # (<stack>-agents, SA agentstack-loop, broker git creds) instead of agent-coordinator.
    bash "${HERE}/coordinator-session.sh" --stack "$name" --repos "${repos% }" --main-repo "$mainrepo" \
      --model "$cmodel" ${LOOP_NS:+--loop-ns "$LOOP_NS"} --item "repo=${urepo} item=${uitem} clause=${uclause}"
  else
    echo "  run it (interactive, supervised):"
    echo "    devbox run coordinator-session -- --stack ${name} --repos \"${repos% }\" --main-repo ${mainrepo} --tick"
  fi
done

[ -n "$any_work" ] || echo "no stack has actionable work — nothing to spawn (no LLM woken)."
