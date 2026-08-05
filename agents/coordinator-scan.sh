#!/usr/bin/env bash
# coordinator-scan — the DETERMINISTIC gate in front of the LLM coordinator. The cheap sibling
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
# boundary (docs/agents/merge-path.md). red-beyond-T = the ci-red clause (FU-115) (guarded checks
# probe — a 403 skips it loudly); rounds-exhausted = the arbitrate clause (both 2026-07-27). The
# `coordinator-reflex` CronJob (agents/coordinator/coordinator-reflex.yaml, FU-050) runs `--spawn` on a
# schedule — deployed SUSPENDED until the operator flips it (kubectl patch cronjob coordinator-reflex
# -n agent-coordinator -p '{"spec":{"suspend":false}}').
#
# STACK SOURCE — `stacks_json()` is the single swap-point: TODAY it reads agents/stacks.json; the
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
# ADR-097 footprint-intersection dispatch: the predicate lives in a sourceable helper so the
# double-dispatch belt (agents/footprint-test.sh, in ci) exercises the exact code the scan runs.
. "${HERE}/footprint.sh"
# Parallelism ceilings (ADR-097): hard per-repo worker max, and the TRACKS-rule-1 open-PR bound
# (updater churn is O(open PRs × merges)) that holds NEW work regardless of footprints.
REPO_MAX_WIP="${REPO_MAX_WIP:-3}"
REPO_PR_CAP="${REPO_PR_CAP:-3}"

# kubectl for the v2 (C4/C5) predicate — same resolution as agent-session.sh: jail → tofu/kubeconfig;
# in-cluster (the coordinator-reflex CronJob) → the pod ServiceAccount (KUBE empty).
if [ -f "${HERE}/../tofu/kubeconfig" ]; then KUBE="--kubeconfig ${HERE}/../tofu/kubeconfig"; else KUBE=""; fi

KUBECTL="$(command -v kubectl || true)"
[ -n "$KUBECTL" ] || KUBECTL="${HERE}/../.devbox/nix/profile/default/bin/kubectl"

# SESSION-POD JANITOR (2026-07-24 — the 118-pod audit): coordinator item/tick pods and reviewer
# pods are bare `kubectl create` pods (the pod-name idempotency design) — nothing TTLs them, and
# the reviewer launcher's "remove the pod:" line was a manual instruction nobody ran (55+33 in
# agent-coordinator, 30 in oracle-agents). Each scan janitors its OWN namespace: terminal
# session pods >24h (incident-forensics window; transcripts/stats upload in-pod before exit).
# No PVCs on these — clutter, not the scratch-pool hazard — but clutter compounds.
OWN_NS="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || true)"
if [ -n "$OWN_NS" ]; then
  for c in $("$KUBECTL" $KUBE -n "$OWN_NS" get pods -o json 2>/dev/null | jq -r --arg now "$(date -u +%s)" '
      .items[]
      | select(.status.phase == "Succeeded" or .status.phase == "Failed")
      | select(.metadata.name | test("^(coordinator|reviewer)-"))
      | select((.metadata.creationTimestamp | fromdateiso8601) < (($now | tonumber) - 86400))
      | .metadata.name' 2>/dev/null); do
    echo "janitor: deleting terminal session pod ${OWN_NS}/${c} (>24h; transcripts are in S3)"
    "$KUBECTL" $KUBE -n "$OWN_NS" delete pod "$c" --ignore-not-found >/dev/null 2>&1 || true
  done
fi

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
        # ADR-096 P4 per-stack knob (2026-08-03): shadow|authoritative|off; chainless stacks
        # (no workerModel) declare authoritative — the launcher enforces.
        routerMode: (.spec.routerMode // "shadow"),
        modelDeny: (.spec.modelDeny // []),
        # FU-080 cutover: a graduated stack is OWNED by its own per-stack loop (coordinate-<stack>
        # in <stack>-agents + the doorbell edge); the GLOBAL scan skips it below so the two never
        # double-run. Default false — perStack renders the loop, graduated retires the global belt.
        graduated: ((.spec.loop.graduated) // false),
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

# FU-085/FU-086(1) compound: an edge that already KNOWS its unit (a reviewer verdict is
# item-shaped — reviewer-session.sh computes `changes-requested|repo|pr-N` in SCRIPT code,
# never the LLM) skips the full multi-repo sweep. The fast path re-validates everything it
# relies on, scoped to the one item; ANY doubt returns 1 and the caller falls through to the
# FULL scan (rule #6 — the compound may only ever be cheaper, never weaker). v1 whitelist:
# changes-requested — the high-volume edge; in-flight clauses are exempt from the ADR-097
# new-work predicates (footprint/PR-cap), so the scoped checks match the main path exactly:
# breaker label, capacity latch, WIP probe.
fast_unit_dispatch() {
  fu="$1"
  fclause="${fu%%|*}"; frest="${fu#*|}"; frepo="${frest%%|*}"; fitem="${frest#*|}"
  [ "$fclause" = "changes-requested" ] || { echo "unit fast-path: clause '${fclause}' not whitelisted"; return 1; }
  case "$fitem" in pr-[1-9]*) ;; *) echo "unit fast-path: malformed item '${fitem}'"; return 1;; esac
  fstack="$(stacks_json | jq -r --arg r "$frepo" '[.stacks[]|select(.repos|index($r))|.name]|first // ""')"
  [ -n "$fstack" ] || { echo "unit fast-path: repo ${frepo} in no stack"; return 1; }
  # Scoping mirrors the main loop: a per-stack instance only serves its own stack; the global
  # instance never touches a graduated stack (its per-stack loop owns it — the doorbell routes
  # graduated events there with loop_ns, so this only rejects mis-routed events).
  if [ -n "${SCAN_STACK:-}" ]; then
    [ "$fstack" = "$SCAN_STACK" ] || { echo "unit fast-path: ${frepo} not in scoped stack ${SCAN_STACK}"; return 1; }
  elif [ "$(stacks_json | jq -r --arg n "$fstack" '.stacks[]|select(.name==$n)|.graduated // false')" = "true" ]; then
    echo "unit fast-path: ${fstack} graduated — global instance won't dispatch it"; return 1
  fi
  [ "$(stacks_json | jq -r --arg n "$fstack" '.stacks[]|select(.name==$n)|.coordinatorEnabled // false')" = "true" ] \
    || { echo "unit fast-path: coordinator.enabled=false for ${fstack}"; return 1; }
  # Re-validate the item live (at-least-once delivery): still open, still CHANGES_REQUESTED,
  # no breaker label. Probe failure → full scan decides (conservative).
  fprjson="$(gh pr view "${fitem#pr-}" --repo "${ORG}/${frepo}" --json state,reviewDecision,labels 2>/dev/null)" \
    || { echo "unit fast-path: PR probe FAILED"; return 1; }
  [ "$(jq -r .state <<<"$fprjson")" = "OPEN" ] || { echo "unit fast-path: PR not open"; return 0; }
  [ "$(jq -r .reviewDecision <<<"$fprjson")" = "CHANGES_REQUESTED" ] || { echo "unit fast-path: verdict moved on"; return 0; }
  jq -e '.labels|map(.name)|index("agent/error")' >/dev/null <<<"$fprjson" \
    && { echo "unit fast-path: agent/error breaker on the PR — human-first"; return 0; }
  if ! SUBSCRIPTION_TIER=dispatch bash "${HERE}/subscription-latch.sh"; then
    echo "unit fast-path: capacity limited (FU-088) — no dispatch (cron sweep re-checks)"; return 0
  fi
  # WIP probe, same shape as the main loop (null-strip is load-bearing — issue-96):
  # probe failure pins wip=1 (belt-only), never blocks the in-flight fix round.
  fwip=1
  if FPODS="$("$KUBECTL" $KUBE -n "$frepo" get pods -l app=agent-session,project="$frepo" \
        --field-selector=status.phase!=Succeeded,status.phase!=Failed -o json 2>/dev/null)" \
     && jq -e . >/dev/null 2>&1 <<<"$FPODS"; then
    flive="$(jq -r '[.items[] | select(([.status.containerStatuses[]? | select(.name == "agent")
        | .state.terminated | select(. != null)] | length) == 0)] | length' <<<"$FPODS")"
    case "${flive:-}" in ''|*[!0-9]*) flive=0;; esac
    if [ "$flive" -ge "$REPO_MAX_WIP" ]; then
      echo "unit fast-path: ${frepo} at WIP ceiling (${flive}) — cron sweep re-checks"; return 0
    fi
    fwip=$((flive + 1))
  fi
  frepos="$(stacks_json | jq -r --arg n "$fstack" '.stacks[]|select(.name==$n)|.repos[]' | tr '\n' ' ')"
  fmain="$(stacks_json | jq -r --arg n "$fstack" '.stacks[]|select(.name==$n)|.mainRepo // "homelab"')"
  fmodel="$(stacks_json | jq -r --arg n "$fstack" '.stacks[]|select(.name==$n)|.coordinatorModel // "sonnet"')"
  echo "→ unit fast-path dispatch for ${fstack}: ${frepo} ${fitem} (${fclause}, model ${fmodel}, wip ${fwip})"
  bash "${HERE}/coordinator-session.sh" --stack "$fstack" --repos "${frepos% }" --main-repo "$fmain" \
    --model "$fmodel" ${LOOP_NS:+--loop-ns "$LOOP_NS"} --wip "$fwip" \
    --item "repo=${frepo} item=${fitem} clause=${fclause}"
  return 0
}
case "${SCAN_UNIT:-}" in ""|"-") ;; *)
  if [ -n "$SPAWN" ]; then
    if fast_unit_dispatch "$SCAN_UNIT"; then exit 0; fi
    echo "unit fast-path fell through — running the full scan"
  fi
;; esac

any_work=""
for name in $(stacks_json | jq -r '.stacks[].name'); do
  # FU-080 perStack: a stack-scoped instance (the coordinate-<stack> CronWorkflow in
  # <stack>-agents sets SCAN_STACK) scans ONLY its own stack; the global reflex keeps sweeping
  # everything as the migration belt.
  [ -n "${SCAN_STACK:-}" ] && [ "$name" != "$SCAN_STACK" ] && continue
  # FU-080 cutover: the GLOBAL instance (SCAN_STACK unset) skips a graduated stack — its own
  # per-stack coordinate loop (cron + doorbell edge) owns it, so scanning here too would double-run
  # (the #134 label-race class). The per-stack instance (SCAN_STACK == name) reaches this line only
  # for its own stack and proceeds. Graduation is retirable in one flag flip (claim loop.graduated).
  if [ -z "${SCAN_STACK:-}" ] \
     && [ "$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|.graduated // false')" = "true" ]; then
    echo "  [$name] graduated — owned by its per-stack loop; skipped in the global scan" >&2
    continue
  fi
  repos="$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|.repos[]' | tr '\n' ' ')"
  # mainRepo is stack POLICY (the coordinator's cwd) — default homelab for stacks whose
  # deploy/agent knowledge still lives in homelab docs.
  mainrepo="$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|.mainRepo // "homelab"')"
  items=""; orphans=""; units=""; punits=""; wipmap=""
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
    # ONE fetch, two derivations (leg (c)): `queued` is the dispatchable set; `openall` keeps the
    # unfiltered list so the goal-review clause can find goals that have LEFT agent/queued for the
    # non-dispatchable tracking state. Deriving beats a second call — the App's GraphQL pool is
    # what this loop actually runs out of (FU-084).
    openall="$(gh issue list --repo "$slug" --state open --json number,title,labels,body,isPinned,blockedBy,parent 2>/dev/null)" || openall='[]'
    jq -e . >/dev/null 2>&1 <<<"$openall" || openall='[]'
    queued="$(printf '%s' "$openall" \
      | jq '[.[]|(.labels|map(.name)) as $L|select(($L|index("agent-fix")) and ($L|index("agent/queued")) and (($L|index("direction-change"))|not) and (($L|index("agent/error"))|not))] | sort_by(.number)' 2>/dev/null)" || queued='[]'
    jq -e . >/dev/null 2>&1 <<<"$queued" || queued='[]'
    # In-progress issues once per repo — the C4/C5 clause below AND the ADR-097 footprint
    # predicate (declared `Touches:` body lines; no line = exclusive `*`) read it.
    # NB agent/error stays IN this fetch (an error-flagged in-progress issue still holds its
    # footprint — a human is on it) but is excluded from the C4/C5 clause below: FU-069 makes it
    # invisible to every ACTIONABLE clause (missed on the first item-mode cut — two workers were
    # dispatched INTO a breaker-flagged issue 2026-07-21 before the breaker was cleared).
    inprog="$(gh issue list --repo "$slug" --state open --json number,title,labels,body \
      --jq '[.[]|(.labels|map(.name)) as $L|select(($L|index("agent-fix")) and ($L|index("agent/in-progress")))]' 2>/dev/null || echo '[]')"
    jq -e . >/dev/null 2>&1 <<<"$inprog" || inprog='[]'
    # ADR-097: one line per in-progress issue = its declared footprint; missing Touches: → `*`
    # (exclusive). The queued predicate below holds any unit whose footprint intersects a line.
    busy_fps="$(printf '%s' "$inprog" | jq -r '.[]
      | ([(.body // "") | scan("(?mi)^[ \\t]*touches:[ \\t]*(.+)$")] | flatten | join(","))
      | if . == "" then "*" else . end')"
    # TRACKS rule 1 (open-PR bound) needs the count BEFORE the queued loop; the merge-path
    # clauses below reuse this same fetch (moved up 2026-08-03, ADR-097 — do not re-fetch).
    # mergeStateStatus is REQUIRED here: the FU-124 nudge below selects on it, and gh returns a
    # field it was not asked for as absent -> jq reads null -> the selector matched nothing, ever
    # (found 2026-08-05; the nudge had been silently falling back to the GitHub cron it exists to
    # stop depending on). Adding a selector field without adding it to --json is the failure mode.
    prsjson="$(gh pr list --repo "$slug" --state open --json number,title,labels,reviewDecision,autoMergeRequest,mergeStateStatus 2>/dev/null)" || prsjson='[]'
    jq -e . >/dev/null 2>&1 <<<"$prsjson" || prsjson='[]'
    # TRACKS rule 1 counts ARMED PRs only. The bound exists because updater churn is
    # O(open PRs x merges) — and the updater only ever touches armed PRs (the nudge below selects
    # autoMergeRequest != null; un-armed PRs are "invisible to the merge path", FU-079). Counting
    # un-armed PRs charged the budget for work the updater never does: circles' twelve human-gated
    # research/comparison PRs held issue #17 out of dispatch indefinitely, silently, on 2026-08-05.
    # A parked PR awaiting a human is not churn — it is the human gate doing its job.
    open_prs="$(jq '[.[] | select(.autoMergeRequest != null)] | length' <<<"$prsjson")"
    # ADR-097 project-WIP predicate (was binary WIP=1; found live meta-8: two dispatchers raced
    # #52 inside one scan window; 2026-07-21 #55: two CRON ticks raced through the phase=Running
    # filter while a kata pod sat Pending — so the probe counts everything non-terminal): the
    # live-pod COUNT feeds the ceiling (hold everything at ≥ REPO_MAX_WIP) and the AGENT_WIP_LIMIT
    # the dispatch passes down (live+1 — the launcher pre-flight belt matches the raise, and a
    # stale count only ever DEFERS: the belt refuses, the next scan recomputes).
    # Probe-first: a FAILED pod probe leaves the units flowing at wip_allow=1 (belt-only — the
    # parallel raise NEVER rides a dead probe; rule #6).
    # Fixerless (context-only) repos never run workers and have no ns RBAC — probing them is a
    # guaranteed per-tick FAILED warning (snore-recorder, 2026-08-02), so skip, don't probe.
    wip_busy=""; wip_allow=1
    if [ -z "$dispatchable" ]; then
      :
    elif WIPPODS_JSON="$("$KUBECTL" $KUBE -n "$repo" get pods -l app=agent-session,project="$repo" \
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
      # NB the null-strip is LOAD-BEARING: a RUNNING agent container yields .state.terminated
      # = null, and [null] has length 1 — without select(.!=null) every Running ride was
      # invisible to this hold (only Pending pods held the queue), so each tick burned a
      # sonnet deferral session against the launcher belt (found 2026-08-02, issue-96 churn).
      live="$(printf '%s' "$WIPPODS_JSON" | jq -r '[.items[]
          | select(([.status.containerStatuses[]? | select(.name == "agent") | .state.terminated
                     | select(. != null)] | length) == 0)] | length')"
      case "${live:-}" in ''|*[!0-9]*) live=0;; esac
      if [ "$live" -ge "$REPO_MAX_WIP" ]; then
        wip_busy=1
      else
        wip_allow=$((live + 1))
      fi
    else
      # Rule #6: a dead probe must not read as calm — the launcher belt still refuses, but say so.
      echo "  [$repo] ⚠ WIP pod probe FAILED (kubectl error) — units flow at wip=1, launcher belt only"
    fi
    # Per-repo AGENT_WIP_LIMIT for whatever unit the spawn block picks for this repo (units are
    # stack-pooled there, so carry the per-repo value out of the loop).
    wipmap="${wipmap}${repo} ${wip_allow}\n"
    # COMPLETED-POD JANITOR (2026-07-22 — the #41/#63 scratch-pool exhaustion): a Completed ride
    # pod pins its GENERIC EPHEMERAL docker-lib PVC (20Gi longhorn-scratch each) until the POD
    # object is deleted — 8 kept-for-reading pods held ~160Gi, the pool filled, and every new
    # ride's volume FAULTED at replica-scheduling ("insufficient storage"), wedging pods in Init
    # while both the WIP probe (fail-open) and the launcher belt let more spawn into the trap.
    # Transcripts/stats upload to S3 in-pod before exit. 30min grace (was 2h): on 2026-07-25
    # nine rides inside 2h held 9x20Gi scratch allocations and pushed BOTH bulk-tier disks past
    # the scheduling cap — new scratch PVCs faulted (ReplicaSchedulingFailure) and wedged every
    # subsequent ride+worker Init. The grace only protects log reads; stats/transcripts are in S3.
    # FU-116: Failed pods leak their ephemeral docker-lib PVCs exactly like Succeeded ones (one
    # r1 PVC sat Bound 18h, regressing the #41/#63 scratch-pool-exhaustion fix) — janitor BOTH
    # terminal phases. Failed gets a longer grace (2h vs 30min): a hard-died ride may not have
    # uploaded transcripts, so its pod log is briefly the only forensics.
    for c in $("$KUBECTL" $KUBE -n "$repo" get pods -l app=agent-session,project="$repo" \
        -o json 2>/dev/null | jq -r '.items[]
        | select(.status.phase == "Succeeded" or .status.phase == "Failed")
        | .status.phase as $p
        | select((.status.startTime // "1970-01-01T00:00:00Z") | fromdateiso8601
                 < (now - (if $p == "Failed" then 7200 else 1800 end)))
        | .metadata.name' 2>/dev/null); do
      echo "  [$repo] janitor: deleting terminal ride pod ${c} (releases its ephemeral scratch PVC)"
      "$KUBECTL" $KUBE -n "$repo" delete pod "$c" --ignore-not-found >/dev/null 2>&1 || true
    done
    # FU-090 visibility slice: bot-authored issues without `agent-fix` are harvested/drafted work
    # awaiting HUMAN triage (TICK-LOG §Loop-safety breaker #1 keeps them inert) — surface them so
    # they never rot silently.
    sprouts="$(gh issue list --repo "$slug" --state open --json number,title,author,labels \
      --jq '[.[]|select((.author.is_bot == true) and (((.labels|map(.name))|index("agent-fix"))|not))|"  issue #\(.number) — \(.title) (by \(.author.login))"]|.[]' 2>/dev/null || true)"
    [ -n "$sprouts" ] && orphans="${orphans}[$repo] 🌱 bot-authored, awaiting human triage (FU-090 gate — label agent-fix[+queued] to adopt):\n${sprouts}\n"
    iss=""; qblocked=""; qcycles=""
    # ⚠ tab is IFS *whitespace*: POSIX read COLLAPSES consecutive tabs, so an empty middle
    # field shifts every later field left (live 2026-07-27: track-less sleep-iac#25's
    # Depends-on landed in qtracks, qdeps read empty → the FU-087 gate silently never ran and
    # the dep-blocked issue dispatched twice). The jq emits "-" placeholders for the two
    # optional fields; normalize them back to empty here. Repro: printf 'a\tb\t\td\n' | read.
    while IFS="$(printf '\t')" read -r qnum qtitle qtouches qdeps qpin qclass qparent; do
      # FU-114 L3: the task class rides the unit (label task/* → .agents/<class>.yaml, default fix)
      [ -n "$qclass" ] || qclass="fix"
      [ -n "$qnum" ] || continue
      # ADR-097: "-" = no Touches: line = exclusive footprint (`*` conflicts with everything —
      # legacy issues keep WIP=1 semantics without backfill).
      [ "$qtouches" = "-" ] && qtouches="*"
      [ "$qdeps" = "-" ] && qdeps=""
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
      # ADR-097 footprint hold (supersedes the track-label lane hold): a queued unit is held iff
      # its declared footprint intersects ANY in-progress issue's footprint. Undeclared (`*`)
      # conflicts with everything, so a repo with any in-progress work keeps WIP=1 for legacy
      # issues; disjoint declared footprints dispatch in parallel (launcher limit rides wipmap).
      if fp_conflict_multi "$qtouches" "$(printf '%b' "$busy_fps")"; then
        orphans="${orphans}[$repo] ⏳ footprint held (ADR-097: overlaps an in-progress issue's Touches):\n  issue #${qnum} — ${qtitle} (declared: ${qtouches})\n"
        continue
      fi
      if [ -n "$wip_busy" ]; then
        orphans="${orphans}[$repo] ⏳ project WIP at ceiling (${REPO_MAX_WIP} live workers in ${repo} — ADR-097 hard max):\n  issue #${qnum} — ${qtitle}\n"
        continue
      fi
      # TRACKS rule 1: NEW work is held while the repo carries ≥ REPO_PR_CAP open PRs — the
      # updater reflex rebases every open PR on every merge (churn is O(open PRs × merges)).
      # In-flight recovery clauses (c4c5, merge-conflict, …) are exempt: they REDUCE the count.
      if [ "${open_prs:-0}" -ge "$REPO_PR_CAP" ]; then
        orphans="${orphans}[$repo] ⏳ PR budget (${open_prs} open ≥ cap ${REPO_PR_CAP} — TRACKS rule 1, updater churn):\n  issue #${qnum} — ${qtitle}\n"
        continue
      fi
      if [ -n "$stale" ]; then
        iss="${iss}  issue #${qnum} — ${qtitle} [⚠ dep${stale} closed as not-planned — premise may be dead]\n"
      else
        iss="${iss}  issue #${qnum} — ${qtitle}\n"
      fi
      # FU-110 operator priority = the GitHub issue PIN (`gh issue pin N`): pinned queued issues
      # dispatch before unpinned — board-native, max 3 pins/repo caps the ladder, zero platform
      # surface. A taxonomy label was REJECTED: the claim's IssueLabels set is authoritative
      # ("anything else gets deleted"), so an ad-hoc label self-destructs. All other predicates
      # (deps, lane, WIP) still apply — a pinned blocked issue stays blocked.
      # LEG (c), 2026-08-05 — a GOAL is not a task. `task/goal` routes to the coordinator's
      # DECOMPOSE play instead of a worker recipe, and this branch MUST come before the recipe
      # choice below: `--recipe` is launcher-owned (ADR-094), so a `goal` class would send the
      # launcher looking for `.agents/goal.yaml` and exit FATAL. There is deliberately no such
      # recipe — the item session authors child issues and NO worker pod is created.
      # Why it exists: circles#17 was a goal handed to a builder (nothing distinguished the two),
      # and produced "analysed everything, built nothing" twice with no cap near binding.
      # Design + the forest/trees rule: docs/agents/issue-authoring.md §Leg (c).
      if [ "$qclass" = "goal" ]; then
        # BREAKER #1, moved UP not away (issue-authoring.md §Leg (c)): a goal's children are queued
        # by the coordinator, and the thing that authorises them is that a HUMAN queued the GOAL.
        # That was prose until 2026-08-05 — nothing checked it, so a bot-queued goal would have
        # self-authorised a whole subtree. Now checked, fail-CLOSED.
        # What the actor test can and cannot see: the loop's own writes are `homelab-agents-1234[bot]`
        # (type Bot) while both the operator AND the jail session are `RasmusSoot` (type User) — the
        # jail holds the operator's PAT. So this does NOT distinguish operator from jail, and is not
        # meant to: the jail is operator-delegated. It distinguishes THE LOOP from a person, which
        # is the actual risk — the loop authorising its own goal.
        #
        # ⚠ THIS IS DEFENCE IN DEPTH, NOT THE BOUNDARY (operator ruling 2026-08-05). Do not build on
        # it and do not let it grow. The App already holds issues:write for other reasons, so an
        # author==human check partway through the process is defeatable in principle — a coordinator
        # could have an -iac worker change the rule that constrains it. The REAL defence is
        # CODEOWNERS gating the MERGE: what lands decides what was allowed, and that check cannot be
        # routed around from inside the loop. Kept because it is one API call and fails closed;
        # retire it without hesitation the day it costs more than it buys.
        # Doctrine: docs/agents/issue-authoring.md §Gate the merge, not the launch.
        qactor="$(gh api "repos/${slug}/issues/${qnum}/events" --paginate \
          --jq '[.[] | select(.event=="labeled" and .label.name=="agent/queued")] | last | .actor.type // ""' 2>/dev/null || echo "")"
        if [ "$qactor" = "Bot" ]; then
          orphans="${orphans}[$repo] ⛔ goal #${qnum} was queued by a BOT — refusing to decompose (breaker #1: a human must authorise a goal; the loop may not authorise its own)\n"
          continue
        fi
        if [ -z "$qactor" ]; then
          orphans="${orphans}[$repo] ⛔ goal #${qnum}: could not read who applied agent/queued — refusing to decompose (fail-closed; an unreadable authorisation is not an authorisation)\n"
          continue
        fi
        if [ "$qpin" = "P" ]; then
          punits="${punits}goal-decompose|${repo}|issue-${qnum}\n"
        else
          units="${units}goal-decompose|${repo}|issue-${qnum}\n"
        fi
        continue
      fi
      # FU-090 leg (c) forest/trees: a child's unit carries its GOAL, so the item session re-reads
      # the parent before acting instead of judging the child in isolation. Free — `parent` rides
      # the issue-list call above, no extra request against the App's GraphQL pool. Empty for the
      # ordinary case (no parent), which parses back to the 4-field shape unchanged.
      if [ "$qpin" = "P" ]; then
        punits="${punits}queued-dispatch|${repo}|issue-${qnum}|${qclass}${qparent:+|${qparent}}\n"
      else
        units="${units}queued-dispatch|${repo}|issue-${qnum}|${qclass}${qparent:+|${qparent}}\n"
      fi
    done < <(printf '%s' "$queued" | jq -r '.[] | [ .number, .title, (([(.body // "") | scan("(?mi)^[ \\t]*touches:[ \\t]*(.+)$")] | flatten | join(",")) | if . == "" then "-" else . end), ((([(.body // "") | scan("(?mi)^[ \\t]*depends-on:[ \\t]*(.+)$")] | flatten)
             + [((.blockedBy // {}).nodes // [])[] | .url | capture("github.com/(?<r>[^/]+/[^/]+)/issues/(?<n>[0-9]+)") | "\(.r)#\(.n)"])
            | unique | join(", ") | if . == "" then "-" else . end), (if .isPinned then "P" else "-" end), ([.labels[].name | select(startswith("task/"))] | first // "task/fix" | ltrimstr("task/")), ((.parent.number // "") | tostring) ] | @tsv')
    iss="$(printf '%b' "$iss")"  # the emitters below expect newline-joined plain text
    # ── goal-review (FU-090 leg (c), 2026-08-05) ───────────────────────────────────────────────
    # The forest/trees rule's third leg: a goal must be RE-EVALUATED, not merely survive its
    # children. Fires when a child CLOSES — not only when the last one does (operator, 2026-08-05:
    # "there should be some kind of backstop on the goal also ... it will deadlock too much when
    # only child traffic causes the goal to move").
    # Predicate is stateless and level-triggered, the same shape as the reviewer's
    # newest_commit_at test: a child closed MORE RECENTLY than the newest bot comment on the goal.
    # Once the session comments, the goal falls out of the clause until the next child closes.
    # Scoped to repos that actually have an open task/goal — no goal, no extra API calls at all.
    goals="$(printf '%s' "$openall" | jq -r '[.[] | select((.labels|map(.name)|index("task/goal")))] | .[].number' 2>/dev/null || true)"
    if [ -n "$goals" ]; then
      # one call for the whole repo's issues incl. closed — reused for every goal below
      kidsall="$(gh issue list --repo "$slug" --state all --limit 300 --json number,state,closedAt,parent 2>/dev/null || echo '[]')"
      jq -e . >/dev/null 2>&1 <<<"$kidsall" || kidsall='[]'
      for g in $goals; do
        newest_close="$(printf '%s' "$kidsall" | jq -r --argjson p "$g" \
          '[.[] | select((.parent.number // 0) == $p) | select(.state == "CLOSED") | .closedAt] | sort | last // ""')"
        [ -z "$newest_close" ] || [ "$newest_close" = "null" ] && continue
        # newest comment BY THE LOOP on the goal — a human comment must not silence the clause
        # ⚠ `gh --jq` takes ONLY an expression — it has no --arg/--argjson (those are jq flags).
        # Passing them makes gh exit "accepts 1 arg(s)", and behind `|| echo ""` that yields an
        # EMPTY last_bot, which this predicate reads as "the loop has never commented" — so the
        # clause re-fires EVERY tick for any goal with a closed child, burning a coordinator
        # session each time. Two were spent (16:30, 17:00) on 2026-08-05 before it was caught.
        # This is the SAME trap already written up for the budget gate hours earlier in the same
        # session; pipe to a real jq, always.
        last_bot="$(gh issue view "$g" --repo "$slug" --json comments 2>/dev/null \
          | jq -r --arg wa "${WORKER_AUTHOR:-app/homelab-agents-1234}" \
             '[.comments[] | select(.author.login == ($wa|ltrimstr("app/"))) | .createdAt] | sort | last // ""' 2>/dev/null || echo "")"
        # ISO-8601 Z sorts lexically, but `[ a \> b ]` is a bashism that silently misbehaves under
        # other shells — compare with sort so the predicate cannot quietly invert.
        newer="$(printf '%s\n%s\n' "$newest_close" "$last_bot" | sort | tail -1)"
        if [ -z "$last_bot" ] || { [ "$newer" = "$newest_close" ] && [ "$newest_close" != "$last_bot" ]; }; then
          units="${units}goal-review|${repo}|issue-${g}\n"
        fi
      done
    fi
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
    # (prsjson fetched ABOVE the queued loop since ADR-097 — the open-PR cap reads it first.)
    prs="$(printf '%s' "$prsjson" | jq -r '[.[]|(.labels|map(.name)) as $L|select((($L|index("major/awaiting-human"))|not) and (($L|index("agent/error"))|not) and ((($L|index("major")) and (.autoMergeRequest==null)) or ($L|index("merge-conflict")) or (.reviewDecision=="CHANGES_REQUESTED")))|"  PR #\(.number) — \(.title)"]|.[]')"
    # FU-124: an ARMED PR stuck BEHIND relies on GitHub's cron sweeper as its sole updater
    # trigger for the LAST open PR, and GitHub drops scheduled runs (sleep#100 hung ~1h).
    # DETERMINISTIC nudge: call the update-branch API directly — idempotent at GitHub (422 =
    # already current), self-limiting (a nudged PR stops being BEHIND), FAIL-LOUD on 403 (a
    # token-scope gap must be visible, not silent). No LLM, no unit, no session.
    for u in $(printf '%s' "$prsjson" | jq -r '.[]|select((.autoMergeRequest!=null) and (.mergeStateStatus=="BEHIND"))|.number'); do
      if gh api -X PUT "repos/${slug}/pulls/${u}/update-branch" >/dev/null 2>&1; then
        echo "  [$repo] FU-124: nudged updater — update-branch on armed BEHIND PR #${u}"
      else
        echo "  [$repo] ⚠ FU-124: update-branch API FAILED for PR #${u} (token scope? conflict?) — updater cron remains the backstop"
      fi
    done
    # ADR-094 units: each predicate row IS an action class — (clause, repo, item), the LLM never picks.
    # AUTHOR-scoped (2026-08-02, found live on snore#15): the fix-round play only has a mandate
    # over WORKER-authored PRs (same WORKER_AUTHOR scope as the reflex's C9). A human/operator PR
    # with CHANGES_REQUESTED stays on the report surface above — before this filter, every tick
    # dispatched a session that re-concluded "human PR, no mandate" (a per-tick sonnet leak, the
    # same absorbing-belt class as the WIP-hold jq-null bug).
    for u in $(printf '%s' "$prsjson" | jq -r --arg wa "${WORKER_AUTHOR:-app/homelab-agents-1234}" '.[]|(.labels|map(.name)) as $L|select((($L|index("major/awaiting-human"))|not) and (($L|index("agent/error"))|not) and (($L|index("agent/arbitrate"))|not) and (.reviewDecision=="CHANGES_REQUESTED") and (.author.login==$wa))|.number'); do
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
    for u in $(printf '%s' "$prsjson" | jq -r '.[]|(.labels|map(.name)) as $L|select((($L|index("agent/error"))|not) and (($L|index("agent/arbitrate"))|not) and ($L|index("merge-conflict")) and (.reviewDecision!="CHANGES_REQUESTED"))|.number'); do
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
                 | .number as $n | select(([$bodies[] | select(test("#\($n)\\b"))] | length) == 0)
                 | "\(.number)|\([.labels[].name | select(startswith("task/"))] | first // "task/fix" | ltrimstr("task/"))"'); do
              units="${units}c4c5-redispatch|${repo}|issue-${u%%|*}|${u#*|}\n"
            done
          fi
        fi
      else
        echo "  [$repo] PROBE_FAILED reading worker pods — C4/C5 clause skipped this tick (fail-loud, rule #6)" >&2
      fi
    fi
    # arbitrate (FU-086 / MP-G04, built 2026-07-27): the review reflex labels a rounds-exhausted
    # PR `agent/arbitrate` (escalation, NOT anomaly — agent/error stays for impossible states).
    # The coordinator is the designed tie-breaker: one unit per labeled PR; the item session
    # rules per the escalation table (brief §arbitrate).
    for u in $(printf '%s' "$prsjson" | jq -r '.[]|(.labels|map(.name)) as $L|select((($L|index("agent/error"))|not) and ($L|index("agent/arbitrate")))|.number'); do
      units="${units}arbitrate|${repo}|pr-${u}\n"
    done

    # ci-red (FU-115 / MP-T12, CONTENT-BASED rewrite of the old ci-red-stale time-gate): an ARMED
    # red PR is invisible to the whole merge path (updater + reviewer both skip red). The OLD trigger
    # was "quiet > RED_STALE_HOURS(4h)" — a coarse LAST-ACTIVITY timer that a no-op fix round's OWN
    # run-stats comment reset, giving a 4h-spaced LIVELOCK with no exhaustion→escalation (the red
    # loop lacked the review loop's ROUNDS_MAX→arbitrate). NOW keyed on CONTENT + a cap, symmetric
    # with the review path (MP-T11), and woken near-instant by the exporter's red edge (github-exporter
    # maybe_dispatch_cired → /coordinate) instead of only the poll. Per red PR we read the fix-round
    # history from durable `🔴 ci-red round rN @ <head8>` markers (coordinator posts one per dispatch):
    #   attempts==0                    → DISPATCH (first red)
    #   attempts>=RED_ROUNDS_MAX(3)     → ARBITRATE (exhausted — MP-T11 tie-break)
    #   head8 != last dispatched head  → DISPATCH (a round pushed new-but-still-red content; re-attempt)
    #   else (same head, round done)   → ARBITRATE (NO-OP round: the worker produced nothing → escalate,
    #                                    never re-dispatch the same input — this is the anti-livelock)
    # Guarded probe: statusCheckRollup needs checks:read; a 403/bad read SKIPS loudly (rule #6). Held
    # while a worker Runs (the fix round owns it). Dispatch cap 2/repo/scan; arbitrate is uncapped
    # (labeling is cheap + idempotent).
    red_probe="$(gh pr list --repo "$slug" --state open --json number,labels,author,autoMergeRequest,headRefOid,headRefName,statusCheckRollup 2>/dev/null)" || red_probe=''
    if [ -n "$red_probe" ] && jq -e . >/dev/null 2>&1 <<<"$red_probe"; then
      # MANDATE check (homelab#88, sleep-tracking#113 livelock 2026-08-03): red CI on a PR the
      # loop did NOT author is the author's to fix — the scan kept dispatching sessions at a
      # human's armed+red PR every tick until the coordinator breaker-labeled it. Same author
      # predicate as the changes-requested clause; out-of-mandate armed+red stays VISIBLE as a
      # report-only line (a human wants to know their armed PR is stuck red), never a unit.
      red_foreign="$(printf '%s' "$red_probe" | jq -r --arg wa "${WORKER_AUTHOR:-app/homelab-agents-1234}" '
          .[]|select(.author.login != $wa)
          | select(.autoMergeRequest != null)
          | select([.statusCheckRollup[]? | select(.conclusion == "FAILURE" or .conclusion == "TIMED_OUT")] | length > 0)
          | "  PR #\(.number) (author \(.author.login))"')"
      [ -n "$red_foreign" ] && orphans="${orphans}[$repo] ⚠ armed+red but NOT loop-authored (mandate: author fixes; no dispatch):\n${red_foreign}\n"
      red_n=0
      for u in $(printf '%s' "$red_probe" | jq -r --arg wa "${WORKER_AUTHOR:-app/homelab-agents-1234}" '
          .[]|(.labels|map(.name)) as $L
          | select(.author.login == $wa)
          | select((($L|index("agent/error"))|not) and (($L|index("agent/arbitrate"))|not)
                   and (($L|index("major"))|not) and (($L|index("major/awaiting-human"))|not))
          | select(.autoMergeRequest != null)
          | select([.statusCheckRollup[]? | select(.conclusion == "FAILURE" or .conclusion == "TIMED_OUT")] | length > 0)
          | .number'); do
        if [ -n "$wip_busy" ]; then
          orphans="${orphans}[$repo] ⏳ ci-red held (worker Running in ${repo} — the fix round owns it):\n  PR #${u}\n"
          continue
        fi
        head8="$(printf '%s' "$red_probe" | jq -r --argjson n "$u" '.[]|select(.number==$n)|.headRefOid[0:8]')"
        u_head="$(printf '%s' "$red_probe" | jq -r --argjson n "$u" '.[]|select(.number==$n)|.headRefName // ""')"
        # attempts = durable count of completed fix rounds on this PR (the launcher's finalize posts
        # one `🤖 Agent run stats` comment per round — no extra marker needed, restart-safe: reads
        # GitHub). Bounds the loop: a no-op round costs at most RED_ROUNDS_MAX attempts before it
        # escalates, never the old infinite 4h-spaced livelock. (Immediate no-op detection — same
        # head across a completed round → arbitrate NOW — is the FU-115(b) refinement, needs a
        # dispatch-time @head marker; the cap is the v1 bound.)
        round_probe="$(gh pr view "$u" --repo "$slug" --json comments,commits 2>/dev/null)" || round_probe=''
        attempts="$(printf '%s' "$round_probe" | jq -r '[.comments[]|select(.body|test("Agent run stats"))]|length' 2>/dev/null)" || attempts=0
        case "$attempts" in ''|*[!0-9]*) attempts=0;; esac
        # FU-115(b) immediate no-op detection (built 2026-08-02, marker-free): if the NEWEST
        # stats comment post-dates the newest NON-MERGE commit, the last completed round pushed
        # nothing — same head, still red → arbitrate NOW instead of burning the remaining cap.
        # Merge commits excluded (the updater's BEHIND merges are not round output — the
        # nine-review-loop lesson). ISO-8601 strings compare correctly as strings.
        noop_round=""
        if [ "$attempts" -ge 1 ]; then
          noop_round="$(printf '%s' "$round_probe" | jq -r '
            ([.comments[]|select(.body|test("Agent run stats"))|.createdAt] | max // "") as $stats
            | ([.commits[]?.commit | select((.messageHeadline // "" | startswith("Merge branch")) | not) | .committedDate] | max // "") as $head
            | if $stats != "" and ($head == "" or $stats > $head) then "1" else "" end' 2>/dev/null)" || noop_round=""
        fi
        RED_MAX="${RED_ROUNDS_MAX:-3}"
        if [ -n "$noop_round" ]; then
          gh pr edit "$u" --repo "$slug" --add-label agent/arbitrate >/dev/null 2>&1 \
            && gh pr comment "$u" --repo "$slug" --body "ARBITRATE (ci-red no-op round, FU-115b): the last completed fix round left the head unchanged at ${head8} and CI is still red — dispatching more identical rounds cannot converge. The coordinator's arbitrate unit rules per the escalation table." >/dev/null 2>&1 \
            && orphans="${orphans}[$repo] ⚠ ci-red NO-OP round → agent/arbitrate NOW: PR #${u} (round ${attempts} pushed nothing, still red @ ${head8})\n" \
            || orphans="${orphans}[$repo] ⚠ ci-red no-op arbitrate FAILED to label PR #${u} — human check\n"
        elif [ "$attempts" -lt "$RED_MAX" ]; then
          # DISPATCH a fix round (under the attempt cap)
          if [ "$red_n" -lt 2 ]; then
            # FU-106 (c): a RED deploy/* bump PR in an -iac repo is the typed infra-delta — the
            # infra-enrich class (diff values.schema.json, enrich the bump PR), not the generic play.
            case "$repo:$u_head" in
              *-iac:deploy/*) units="${units}infra-enrich|${repo}|pr-${u}\n"; rclause="infra-enrich";;
              *)              units="${units}ci-red|${repo}|pr-${u}\n"; rclause="ci-red";;
            esac
            # units-only clauses were invisible to the `[ -z "$items" ]` gate (the meta-14 stall) —
            # every dispatchable unit MUST also add an items line.
            items="${items}[$repo] PR #${u} — ${rclause} (CI red, armed; attempt $((attempts+1))/${RED_MAX} @ ${head8})\n"
            red_n=$((red_n+1))
          fi
        else
          # ARBITRATE: red rounds EXHAUSTED. Reuse the review path's MP-T11 machinery — label
          # agent/arbitrate + comment; the arbitrate scan clause + coordinator tie-break (re-dispatch
          # a stronger model / park / close) take over. This is the Red→arbitrate edge the FSM lacked.
          gh pr edit "$u" --repo "$slug" --add-label agent/arbitrate >/dev/null 2>&1 \
            && gh pr comment "$u" --repo "$slug" --body "ARBITRATE (ci-red, FU-115): ${attempts} fix rounds and CI still red at ${head8} (cap ${RED_MAX}). The CI-red fix-round loop is not converging on its own — review automation now skips it; the coordinator's arbitrate unit rules per the escalation table (re-dispatch with a stronger model / close as not-mergeable / escalate to a human)." >/dev/null 2>&1 \
            && orphans="${orphans}[$repo] ⚠ ci-red → agent/arbitrate: PR #${u} (${attempts} rounds, still red — exhausted)\n" \
            || orphans="${orphans}[$repo] ⚠ ci-red arbitrate FAILED to label PR #${u} (gh write refused?) — human check\n"
        fi
      done
    else
      echo "  [$repo] PROBE_FAILED reading check rollups — ci-red clause skipped this tick (needs checks:read; fail-loud rule #6)" >&2
    fi

    # C6 merged-closeout (FU-090a / MP-G03, built 2026-07-27): an issue CLOSED by its merged PR
    # but still carrying a non-terminal `agent/*` state is a loop nobody closed — outcome
    # unverified, label stale, and the merged PR's review `Follow-ups:` bullets die in the comment.
    # BOTH pre-merge states qualify: `agent/in-progress` (auto-merge outran the review-flip) AND
    # `agent/review` (the happy-path pre-merge state per merge-path-fsm.md MP-T10 — nothing else
    # flips it to agent/done; #46/PR#63 sat stale here). Emit ONE unit per such issue (the item
    # session verifies, flips agent/done, harvests the bullets as INERT issues — breaker #1).
    # Level-triggered off closed-issue state; capped at 3/repo/scan (a housekeeping trickle — first
    # run meets history) with the overflow reported, 21-day window (older = archaeology).
    closed_ip="$(gh issue list --repo "$slug" --state closed --label agent-fix --limit 30 \
      --json number,title,labels,updatedAt 2>/dev/null)" || closed_ip='[]'
    jq -e . >/dev/null 2>&1 <<<"$closed_ip" || closed_ip='[]'
    c6_all="$(printf '%s' "$closed_ip" | jq -r --arg cutoff "$(date -u -d '-21 days' +%Y-%m-%dT%H:%M:%SZ)" \
      '[.[] | (.labels|map(.name)) as $L
             | select(($L|index("agent/error"))|not)
             | select(($L|index("agent/done"))|not)
             | select(($L|index("agent/in-progress")) or ($L|index("agent/review")))
             | select(.updatedAt >= $cutoff) | .number] | .[]')"
    c6_n=0
    for u in $c6_all; do
      if [ "$c6_n" -lt 3 ]; then
        units="${units}merged-closeout|${repo}|issue-${u}\n"
        # trip the actionability gate + surface in the report (see the ci-red note above) —
        # otherwise a merged issue's agent/done flip + Follow-ups harvest silently never dispatches.
        items="${items}[$repo] issue #${u} — merged-closeout (closed, still non-terminal agent/*)\n"
        c6_n=$((c6_n+1))
      else
        orphans="${orphans}[$repo] ⏳ merged-closeout backlog (cap 3/scan): issue #${u} waits for the next pass\n"
      fi
    done

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
    # A branch owned by a RUNNING ride is not stale — the worker pushes its branch before the PR
    # opens, and the flag fired on active rides' branches twice on 2026-07-26 (issues 129, 138).
    # Probe failure keeps run_iss empty → no exclusion → at worst the old (noisy) behavior.
    run_iss="$("$KUBECTL" $KUBE -n "$repo" get pods -l app=agent-session --no-headers 2>/dev/null | grep -oE 'issue-[0-9]+' | sort -u | paste -sd'|' -)" || run_iss=""
    if [ -n "$run_iss" ]; then
      heads="$(jq --arg re "(^|[^0-9])(${run_iss})([^0-9]|$)" '[.[] | select(test($re) | not)]' <<<"$heads")"
    fi
    stale="$(jq -rn --argjson h "$heads" --argjson p "$prheads" '$h - $p | .[] | "  branch \(.) — no open PR (stale; delete or resume)"')"
    [ -n "$stale" ] && orphans="${orphans}[$repo] ⚠ stale agent branches:\n${stale}\n"
    [ -n "$iss" ]  && items="${items}[$repo]\n${iss}\n"
    [ -n "$v2" ]   && items="${items}[$repo]\n${v2}\n"
    [ -n "$prs" ]  && items="${items}[$repo]\n${prs}\n"
    [ -n "$orph" ] && orphans="${orphans}[$repo] ⚠ un-armed open PRs (invisible to the merge path — arm or park, FU-079):\n${orph}\n"
  done

  [ -n "$orphans" ] && { echo "stack ${name}: ⚠ REPORT-ONLY items (human attention; the tick does not touch these):"; printf '%b' "$orphans"; }

  # FU-086(4): the daily JANITOR tick — the board-level judgment ADR-094 (4) retained, at its
  # own cadence (the janitor-<stack> CronWorkflow sets SCAN_JANITOR=1). Report-only by prompt
  # (coordinator README §The janitor tick): it dispatches nothing and the only writes allowed
  # are INERT spec-gap drafts (issue-authoring leg b). Runs BEFORE the quiet-stack skip on
  # purpose — a clause bug that starves an item class makes the stack LOOK quiet, and catching
  # exactly that is sweep #1.
  if [ -n "$SPAWN" ] && [ "${SCAN_JANITOR:-}" = "1" ]; then
    if [ "$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|.coordinatorEnabled // false')" != "true" ]; then
      echo "  janitor: coordinator.enabled=false for ${name} — skipped."
      continue
    fi
    if ! SUBSCRIPTION_TIER=dispatch bash "${HERE}/subscription-latch.sh"; then
      echo "  janitor: capacity limited (FU-088) — skipped this day (tomorrow's cron retries)."
      continue
    fi
    cmodel="$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|.coordinatorModel // "sonnet"')"
    echo "→ spawning janitor tick for ${name} (report-only, model ${cmodel})…"
    bash "${HERE}/coordinator-session.sh" --stack "$name" --repos "${repos% }" --main-repo "$mainrepo" \
      --model "$cmodel" ${LOOP_NS:+--loop-ns "$LOOP_NS"} --janitor
    continue
  fi

  # ⚠ `units` is NOT derivable from `items`, and gating on `items` alone silently starves a whole
  # clause. Every OTHER unit happens to feed both — its subject is a queued/in-progress issue or an
  # open PR, which also lands in a report list — but `goal-review`'s subject is a goal parked in
  # `agent/blocked`, deliberately in no report list at all. So the backstop was unreachable in
  # EXACTLY the state it was built for: every child closed and nothing else going on, which is the
  # deadlock the operator asked to be backstopped ("it will deadlock too much when only child
  # traffic causes the goal to move"). It read as working for hours because it only ever ran while
  # OTHER work kept `items` non-empty — 16:30 and 17:00 fired, 18:00 went quiet with the predicate
  # TRUE (2026-08-05, circles#17 with both children closed). Gate on the union, not on the report.
  if [ -z "$items" ] && [ -z "$units" ]; then
    echo "stack ${name}: nothing actionable"
    continue
  fi
  any_work=1
  echo "stack ${name}: ACTIONABLE —"
  if [ -n "$items" ]; then
    printf '%b' "$items"
  else
    # Say it out loud: a dispatchable unit with no report line is the case that hid the bug.
    echo "  (no report items — a units-only clause is dispatchable; see the unit line below)"
  fi

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
    if ! SUBSCRIPTION_TIER=dispatch bash "${HERE}/subscription-latch.sh"; then
      echo "  capacity: subscription limited (FU-088) — no dispatch this pass (level-triggered; next scan re-checks)."
      continue
    fi
    if [ "${SCAN_ITEM_MODE:-1}" = "0" ]; then
      echo "→ spawning headless coordinator tick for ${name} (SCAN_ITEM_MODE=0 whole-stack mode)…"
      bash "${HERE}/coordinator-session.sh" --stack "$name" --repos "${repos% }" --main-repo "$mainrepo" --run-tick
      continue
    fi
    unit=""
    # FU-110: pinned queued-dispatch units go FIRST WITHIN their clause — prepending is safe
    # because the clause loop below greps by clause name, so higher-priority clauses (in-flight
    # recovery etc.) still win regardless of position.
    units="${punits}${units}"
    # Priority: in-flight recovery first, then merge-path exceptions, then CLOSE loops on merged
    # work (C6 — cheap bookkeeping that keeps state honest), and only then open NEW work.
    # goal-decompose sits just BEFORE queued-dispatch: it opens new work like a queued issue does,
    # but it must win over it when a repo has both, because a goal left undecomposed is what makes
    # its children exist at all (leg (c), 2026-08-05). It stays BELOW every recovery and merge-path
    # clause — an in-flight failure is always more urgent than planning the next thing.
    for clause in c4c5-redispatch arbitrate changes-requested merge-conflict unarmed-major infra-enrich ci-red merged-closeout goal-review goal-decompose queued-dispatch; do
      unit="$(printf '%b' "$units" | grep -m1 "^${clause}|" || true)"
      [ -n "$unit" ] && break
    done
    if [ -z "$unit" ]; then
      echo "  actionable items but no dispatchable unit (context-only repos / gated) — report-only."
      continue
    fi
    uclause="${unit%%|*}"; rest="${unit#*|}"; urepo="${rest%%|*}"; rest2="${rest#*|}"
    # FU-114 L3: 4-field units (queued-dispatch, c4c5-redispatch) carry the task class from the
    # issue's task/* label — the recipe choice is DETERMINISTIC (never the session "figuring it
    # out"; ADR-094). 3-field units (merge-path clauses) have no class — the session derives it
    # from the issue labels per its brief.
    case "$rest2" in
      *"|"*) uitem="${rest2%%|*}"; uclass="${rest2#*|}";;
      *)     uitem="$rest2"; uclass="";;
    esac
    # FU-090 leg (c): a 5th field is the GOAL this item is a child of. Split it back off the class
    # so the coordinator's brief can name it — the whole point of the forest/trees rule is that a
    # child unit never arrives without its goal attached.
    case "$uclass" in
      *"|"*) uparent="${uclass#*|}"; uclass="${uclass%%|*}";;
      *)     uparent="";;
    esac
    # FU-121: a c4c5 redispatch can race a closing issue (the #71 r9 spurious round — the scan's
    # list snapshot predated the close). Re-probe the ISSUE fresh immediately before spending a
    # session: closed → skip this unit (the next scan's list won't carry it). Probe failure
    # dispatches anyway (level-triggered permissive — the session's own re-read is the belt).
    if [ "$uclause" = "c4c5-redispatch" ]; then
      fresh_state="$(gh issue view "${uitem#issue-}" --repo "${ORG}/${urepo}" --json state --jq .state 2>/dev/null || echo PROBE-FAILED)"
      if [ "$fresh_state" = "CLOSED" ]; then
        echo "  FU-121: ${urepo} ${uitem} closed since the list snapshot — redispatch skipped."
        continue
      fi
    fi
    cmodel="$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|.coordinatorModel // "sonnet"')"
    # ── goal-decompose runs a REASONING tier (operator ruling, 2026-08-05) ─────────────────────
    # The axis is AUTHORING vs CHECKING, not goal vs routine. `goal-decompose` CREATES the work —
    # a mis-scoped child burns rides, mis-narrows `Touches:`, and is expensive to undo once its
    # ride opens a PR. Everything else in the lane checks work that is already framed.
    # ⚠ `goal-review` was in this list for ~90 minutes and was REMOVED (operator challenge, same
    # day): it is mostly verification against an acceptance list the goal already carries, and both
    # of its live runs on 2026-08-05 were SONNET and both were right — the 16:32 one ruled "not yet
    # met", correctly told branch-2 (a child covers the gap) from branch-3 (author the missing
    # child), authored no redundant child, and caught stale `Base:` prose the meta session missed;
    # the 18:15 one verified against the goal branch + post-merge CI rather than labels and left
    # the human-reserved PRs alone. It also contradicted standing doctrine — reviewer-session.sh:
    # "Sonnet is sufficient here; opus is available for a genuinely high-stakes PR via --model, but
    # it is not the default." A review is a review. Escalate a SPECIFIC hard goal with GOAL_MODEL,
    # do not raise the floor for the whole clause.
    # ⚠ Launcher-side map ON PURPOSE (ADR-094: dispatch params are launcher-owned, never
    # LLM-assembled). The router's vocabulary already describes this better — it grades
    # `claude/opus: premium` in `model_tiers` and separates `reasoning: true` classes from
    # `dispatch` — but /route's ONLY caller is agent-session.sh (the worker launcher);
    # coordinator-session.sh consults the proxy solely for /loop-git-token, so there is nothing to
    # route through yet. When the coordinator lane is wired to /route (post-P4, FU-095), this map
    # becomes a subscription-rail reasoning class and dies here. See docs/agents/model-routing.md §M10.
    case "$uclause" in
      goal-decompose) cmodel="${GOAL_MODEL:-opus}";;
    esac
    # ADR-097: the launcher-owned AGENT_WIP_LIMIT for this repo (live workers + 1, ceiling-capped;
    # 1 on probe failure). Computed by the scan, carried as pod env — never LLM-assembled.
    uwip="$(printf '%b' "$wipmap" | awk -v r="$urepo" '$1==r{print $2}' | head -1)"
    case "${uwip:-}" in ''|*[!0-9]*) uwip=1;; esac
    echo "→ dispatching item unit for ${name}: ${urepo} ${uitem} (${uclause}${uclass:+, class ${uclass}}${uparent:+, child of goal #${uparent}}, model ${cmodel}, wip ${uwip})…"
    # FU-080 perStack: under a stack-scoped instance the item session runs in the loop home
    # (<stack>-agents, SA agentstack-loop, broker git creds) instead of agent-coordinator.
    bash "${HERE}/coordinator-session.sh" --stack "$name" --repos "${repos% }" --main-repo "$mainrepo" \
      --model "$cmodel" ${LOOP_NS:+--loop-ns "$LOOP_NS"} --wip "$uwip" \
      --item "repo=${urepo} item=${uitem} clause=${uclause}${uclass:+ class=${uclass}}${uparent:+ parent=${uparent}}"
  else
    echo "  run it (interactive, supervised):"
    echo "    devbox run coordinator-session -- --stack ${name} --repos \"${repos% }\" --main-repo ${mainrepo} --tick"
  fi
done

[ -n "$any_work" ] || echo "no stack has actionable work — nothing to spawn (no LLM woken)."
