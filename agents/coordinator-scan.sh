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
#          kubectl, probe failures skip the clause rather than fail into a wake). Once that state
#          has PERSISTED past C4C5_PERSIST_S and no merged PR mentions the issue, the scan
#          RECONCILES the label itself — agent/queued back on, agent/in-progress off, audit
#          commented (homelab#155) — because the phantom label also holds every sibling through
#          the ADR-097 footprint intersection. Everything it holds still rides as a unit.
# Deliberately EXCLUDES (so the LLM never wakes for a no-op): human-waiting states (`agent/blocked`,
# `major/awaiting-human`), the `agent/error` anomaly-breaker items (FU-069 — human-first,
# report-only), done/merged, and everything on the review-reflex's ARMED track — arming is the
# boundary (docs/agents/merge-path.md). red-beyond-T = the ci-red clause (FU-115) (guarded checks
# probe — a 403 skips it loudly); rounds-exhausted = the arbitrate clause (both 2026-07-27). Both
# of those two are CURRENCY-gated as well as condition-gated (homelab#198): a condition that holds
# over unchanged PR state is a report line, not a fresh unit — see §PR STATE FINGERPRINT below. The
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
# NO-OP ROUND PREDICATE — shared by the ci-red clause (FU-115b) and changes-requested (FU-147).
# Input: `gh pr view N --json comments,commits`. Prints "1" when the LAST completed round pushed
# nothing. Defined once because two copies WILL drift, and this one was already wrong twice:
#   (1) it read `.commits[]?.commit.committedDate` — but that field is TOP-LEVEL in gh output, so
#       every commit was null, $head was "", and the `$head == ""` branch fired "no-op" on every
#       PR it ever saw. Never observed only because no ci-red PR reached a completed round since
#       2026-08-02 (zero agent/arbitrate labels fleet-wide, zero of its comments in search).
#   (2) COUNTING is the fix, not comparison: a SUCCESSFUL round pushes its commit and only THEN
#       posts stats, so `newest_stats > newest_commit` is true for good rounds too. The round that
#       produced the newest commit posts exactly ONE stats comment after it — so a SECOND one
#       means a later round finished without pushing. Hence `>= 2`.
# Verified against circles PR#39 real history: final state (r6 pushed) -> no; state after r3 (the
# real truncation no-op) -> YES; state after r4 (real push) -> no. Merge commits excluded (the
# updater BEHIND merges are not round output — the nine-review-loop lesson).
#
# ── THE ROUND EVIDENCE, TWO CHANNELS ────────────────────────────────────────────────────────────
# Three clauses in this file count completed fix rounds off "one 🤖 Agent run stats comment per
# round" — the no-op predicate below, the per-PR `attempts` counter, and the issue-keyed ceiling.
# ADR-103/#210 moves that table off the timeline onto the `agent-ride` check-run plus ONE line
# appended to a single `<!-- agent-summary -->` comment, so "one round = one more comment" stops
# being true and a shape-only reader silently counts ZERO. That is not a cosmetic regression: at
# attempts=0 the ci-red clause never reaches RED_ROUNDS_MAX, never escalates to arbitrate, and
# re-dispatches the same red input forever — the exact livelock FU-115 built the cap to bound.
#
# So this def reads BOTH channels and is the ONLY place either shape is matched:
#   new — `<!-- agent-event kind=stats ts=… -->` markers inside the summary comment, one per round;
#   old — a whole comment containing "Agent run stats", timestamped by the comment itself.
# A UNION, not a replacement, and it stays one for as long as both emitters can post. The primary
# emitter is agent-finalize in the POD (agent-runtime#62, not yet landed); only the launcher
# fallback moves in this repo. Until the cross-repo half merges, a single PR can carry rounds in
# both shapes, and a reader that picked one would under-count either the old rides or the new.
# Delete the old branch when agent-runtime#62 has shipped AND no open PR still carries the shape —
# not before, and not by assuming the timeline is clean.
# >>>REPLAY:round-evidence>>>
STATS_TS_DEF='def stats_ts: [ .comments[]? | (.body // "") as $b
  | if ($b | test("<!-- agent-summary -->"))
    then [ $b | scan("<!-- agent-event kind=stats ts=([^ ]+) -->")[0] ]
    elif ($b | test("Agent run stats")) then [ .createdAt ]
    else [] end | .[] ];'
NOOP_ROUND_JQ="${STATS_TS_DEF}"'
  ([.commits[]? | select((.messageHeadline // "" | startswith("Merge branch")) | not) | .committedDate] | max // "") as $head
  | ([ stats_ts[] | select($head == "" or . > $head) ] | length) as $after
  | if $after >= 2 then "1" else "" end'
# <<<REPLAY:round-evidence<<<
REPO_PR_CAP="${REPO_PR_CAP:-3}"

# ── PR STATE FINGERPRINT (homelab#198) ────────────────────────────────────────────────────────
# The arbitrate and ci-red DISPATCH legs are level-triggered off a label / a red rollup, so they
# re-emit their unit every scan for as long as that condition holds — existence, not currency.
# Live 2026-08-09 (oracle-fleet PR#234): five coordinator rides in ~30 minutes against BYTE-
# IDENTICAL state (same head, same red `e2e`, same stale CHANGES_REQUESTED, a `gh run rerun` 403),
# each correctly ruling "no change, escalation stands" and exiting. The anomaly breaker latched
# `agent/error` on the 4th — correctly, but a belt is not a guard: four opus rides had already
# been spent to conclude nothing.
#
# So the emission gains CURRENCY, keyed on a fingerprint of the state a ride would actually read:
#   head sha | reviewDecision | every check's conclusion | newest verdict's submittedAt
# Nothing else — a comment (including OUR marker and the coordinator's own ruling prose) must not
# move the hash, or the debounce disarms itself on the very ride it is debouncing. In-flight checks
# normalize to PENDING so a re-run reads as one state change, not one per polled sample.
#
# The marker is a `state-fp:<hash>` line in a PR comment, written at DISPATCH time by the block at
# the bottom of this script — deliberately NOT at emission time. The scan emits many units and
# dispatches exactly ONE (the priority loop): marking at emission would silently retire an
# arbitrate unit that lost the race to a higher-priority clause and never rode at all.
# FAIL-OPEN throughout, matching this file's guarded-probe posture: an unreadable probe or a
# missing hasher yields an empty fingerprint, which can never equal a recorded one, so the clause
# behaves exactly as it did before this guard existed. The breaker stays as the backstop for
# fingerprint BUGS (a hash that moves on its own re-arms the churn this guard removes).
# The five blocks below carry `>>>REPLAY:<name>>>>` sentinels: agents/state-fp-replay.sh EXTRACTS
# and executes them against fixtures (homelab#201, the rail-degrade-replay pattern) rather than
# transcribing them, so the pin cannot drift from this code. Moving a block is fine; dropping a
# sentinel is not — the harness exits 3 and says which one it could not find.
# >>>REPLAY:state-fp-jq>>>
STATE_FP_JQ='[ "head=" + (.headRefOid // "")
  , "review=" + (.reviewDecision // "NONE")
  , "checks=" + ([ .statusCheckRollup[]?
                   | ((.name // .context // "?") + "="
                      + (((.conclusion // .state) // "") | if . == "" then "PENDING" else . end)) ]
                 | sort | join(","))
  , "verdict=" + ([ .reviews[]? | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")
                    | .submittedAt ] | max // "")
  ] | join("|")'
# Newest recorded marker, by comment createdAt — `last` on the raw list would trust gh ordering.
STATE_FP_LAST_JQ='([ .comments[]? | select((.body // "") | test("state-fp:[0-9a-f]{6,64}")) ]
  | sort_by(.createdAt) | last // {})
  | (((.body // "") | [ scan("state-fp:[0-9a-f]{6,64}") ] | last) // "")
  | sub("^state-fp:"; "")'
# <<<REPLAY:state-fp-jq<<<

# pr_state_fp_pair <slug> <pr> → "<current>|<recorded>", either side empty when unknown.
# ONE probe answers both halves, so the comparison can never straddle two snapshots of the PR.
# Always exits 0: under `set -e` a probe failure here must skip the guard, never kill the scan.
# >>>REPLAY:state-fp-pair>>>
pr_state_fp_pair() {
  # Declared on their own line, never `local x="$(cmd)"` — that form makes `local` the command
  # whose status is tested, so the `|| fallback` and `set -e` both read the wrong exit code.
  local fp_probe fp_raw fp_prev fp_cur
  fp_probe="$(gh pr view "$2" --repo "$1" \
      --json headRefOid,reviewDecision,statusCheckRollup,reviews,comments 2>/dev/null)" || fp_probe=''
  if ! jq -e . >/dev/null 2>&1 <<<"$fp_probe"; then printf '%s|%s\n' '' ''; return 0; fi
  fp_raw="$(printf '%s' "$fp_probe" | jq -r "$STATE_FP_JQ" 2>/dev/null)" || fp_raw=''
  fp_prev="$(printf '%s' "$fp_probe" | jq -r "$STATE_FP_LAST_JQ" 2>/dev/null)" || fp_prev=''
  fp_cur=''
  # `sha256sum` is coreutils, which this script already requires (`date -u -d`), but a missing
  # hasher must degrade to "no fingerprint" rather than abort the stack's whole scan.
  [ -n "$fp_raw" ] && fp_cur="$(printf '%s' "$fp_raw" | sha256sum 2>/dev/null | cut -c1-12)"
  case "$fp_cur" in *[!0-9a-f]*|'') fp_cur='';; esac
  printf '%s|%s\n' "$fp_cur" "$fp_prev"
  return 0
}
# <<<REPLAY:state-fp-pair<<<

# homelab#155 belt: how long a phantom `agent/in-progress` (no pod, no PR) must PERSIST before the
# scan reconciles the label itself. One full scan interval is the */10 coordinator-reflex cron
# (agents/coordinator/reflexes-argo.yaml); 15 min is that plus margin for cron jitter and the
# doorbell, so the belt can never actuate on the same instant of state it first observed. The
# asymmetry sets the default: a phantom held one extra pass costs 10 minutes, a wrongly cleared
# label costs a duplicate ride on live work.
C4C5_PERSIST_S="${C4C5_PERSIST_S:-900}"

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
  # `body` rides this existing call for the FU-146 per-item hold below — no extra request.
  fprjson="$(gh pr view "${fitem#pr-}" --repo "${ORG}/${frepo}" --json state,reviewDecision,labels,body 2>/dev/null)" \
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
    # FU-146 PER-ITEM hold, ported here 2026-08-07. `fc606e2` put it in the MAIN scan path only,
    # and the doorbell takes THIS path — so the hold was bypassed on exactly the high-volume edge
    # it was written for. The WIP check above cannot substitute: it is a COUNT against
    # REPO_MAX_WIP, so one live pod (flive=1 < 3) still dispatches. Proven live in a single
    # window: tick `t967f` dispatched pr-45 while `agent-circles-issue-18-r3` had been Running 13
    # minutes, while the next FULL scan on the same state correctly reported nothing dispatchable.
    # This function's contract is "only ever cheaper, never weaker" (rule #6) — it was weaker.
    # Same predicate and same fail-safes as the main path: no link or no pod probe → fall through
    # unchanged, and the hold needs a LIVE pod so it self-releases and cannot wedge.
    fpr_issue="$(jq -r '(.body // "")
        | (capture("(?i)(implements|closes|closed|fixes|fixed|resolves|resolved)[ \t]+#(?<i>[0-9]+)") | .i) // ""' \
        <<<"$fprjson" 2>/dev/null)" || fpr_issue=""
    if [ -n "$fpr_issue" ] \
       && jq -e --arg pat "issue-${fpr_issue}-" \
            '[.items[]? | select((.metadata.name // "") | contains($pat))] | length > 0' >/dev/null 2>&1 <<<"$FPODS"; then
      echo "unit fast-path: held — a worker is already riding issue #${fpr_issue} (FU-146 per-item); PR ${fitem#pr-}"
      return 0
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
    # FU-087/FU-111: native GitHub `blockedBy` edges gate the queue — the machine-readable
    # dependency graph. (The `Depends-on:` body-line reader retired 2026-08-07 after native
    # edges were observed flowing under the App token — circles #30→#31→#32 full lifecycle;
    # the one open body-line holdout, oracle-fleet#84, was migrated to a native edge first.)
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
    # `updatedAt` is fetched for the homelab#155 belt's persistence guard (condition (c)) — read
    # the mergeStateStatus warning by the PR fetch below before touching this list: a selector
    # field that is not in --json comes back absent and silently matches nothing.
    inprog="$(gh issue list --repo "$slug" --state open --json number,title,labels,body,updatedAt \
      --jq '[.[]|(.labels|map(.name)) as $L|select(($L|index("agent-fix")) and ($L|index("agent/in-progress")))]' 2>/dev/null || echo '[]')"
    jq -e . >/dev/null 2>&1 <<<"$inprog" || inprog='[]'
    # ADR-097: one line per in-progress issue = its declared footprint; missing Touches: → `*`
    # (exclusive). The queued predicate below holds any unit whose footprint intersects a line.
    busy_fps="$(printf '%s' "$inprog" | jq -r '.[]
      | ([(.body // "") | scan("(?mi)^[ \\t]*touches:[ \\t]*(.+)$")] | flatten | join(","))
      | if . == "" then "*" else . end')"
    # ── FU-143 (contract points 1+2): a goal child cannot self-close ──────────────────────────
    # An OPEN in-progress issue whose body declares `Base: goal/**` and whose referencing PR
    # MERGED into exactly that base is FINISHED work the closing keyword could not close
    # (keywords fire on default-branch merges only). Detected HERE, before C4/C5, because BOTH
    # clauses need the set: C6 emits its closeout unit, and C4/C5 must EXCLUDE it in the same
    # tick — the abandoned-probe reads OPEN PRs only, so merged-into-goal looks abandoned, and
    # c4c5-redispatch OUTRANKS merged-closeout (without the exclusion the closeout unit starves
    # while merged work gets re-ridden). Base:-keyed ON PURPOSE — goal/** only, never "any
    # non-default base": the mirror hazard is agent-runtime#32 (an ordinary stacked PR closing
    # too EARLY), and the goal/ prefix is the same key arming already trusts to carry the
    # ruleset. Design: issue-authoring.md FU-143 section. Probe failures skip LOUDLY (rule #6).
    c6g=""; c6g_nums=""
    # ⚠ Candidate set is DELIBERATELY wider than $inprog: a goal child that lands cleanly in ONE
    # round ends in `agent/review`, not `agent/in-progress` (the launcher flips on PR-open —
    # MP-T10). Keying the goal-child leg off $inprog alone made the COMMON case invisible: only a
    # child dragged back to in-progress by a fix round could ever close. circles#32 auto-closed
    # (6 rounds, in-progress) while #40 — one clean round, `agent/review`, PR merged into the goal
    # base — sat open with nothing to claim it. C6's own CLOSED-issue leg has always accepted both
    # states; this leg was the odd one out. $inprog is left ALONE on purpose: it also feeds the
    # ADR-097 footprint holds, and widening those is a different decision.
    goalcand="$(gh issue list --repo "$slug" --state open --json number,title,labels,body \
      --jq '[.[]|(.labels|map(.name)) as $L|select(($L|index("agent-fix")) and (($L|index("agent/in-progress")) or ($L|index("agent/review"))))]' 2>/dev/null || echo '[]')"
    jq -e . >/dev/null 2>&1 <<<"$goalcand" || goalcand='[]'
    goalbased="$(printf '%s' "$goalcand" | jq -r '.[]
      | select(((.labels|map(.name))|index("agent/error"))|not)
      | .number as $n
      | ((((.body // "") | capture("(?m)^[ \\t]*[Bb]ase:[ \\t]*(?<b>goal/[^ \\t\\r\\n]+)") | .b)? // "")) as $b
      | select($b != "") | "\($n)|\($b)"')" || goalbased=""
    # FU-143 SOAK FAILURE, 2026-08-06 — every goal-based in-progress issue, matched or not.
    # C6 below can only claim an issue whose merged PR CITES it; circles#36 merged into
    # goal/29-p0-complete citing only its sibling #31, so #30 fell out of c6g, C4/C5 read
    # "in-progress + no open PR" as abandoned, and re-rode already-merged work. On a goal base the
    # closing keyword is INERT, so nothing motivates the worker to write the reference and nothing
    # checks that it did (agent-runtime#32 — finalize should guarantee the issue link). Until that
    # lands, "no open PR" cannot distinguish MERGED-BUT-UNLINKED from ABANDONED for these issues.
    # So C4/C5 must not guess: holding costs a meta nudge, guessing costs a duplicate ARMED PR onto
    # a protected goal branch that auto-merges. Asymmetric — hold.
    goalbased_nums="$(printf '%s' "$goalbased" | sed 's/|.*//' | tr '\n' ' ')"
    if [ -n "$goalbased" ]; then
      gmerged="$(gh pr list --repo "$slug" --state merged --limit 40 --json number,body,baseRefName 2>/dev/null)" || gmerged='X'
      gopen="$(gh pr list --repo "$slug" --state open --json body --jq '[.[].body // ""]' 2>/dev/null)" || gopen='X'
      if jq -e . >/dev/null 2>&1 <<<"$gmerged" && jq -e . >/dev/null 2>&1 <<<"$gopen"; then
        for gb in $goalbased; do
          gn="${gb%%|*}"; gbase="${gb#*|}"
          # ⚠ STRONG LINK REQUIRED, not a bare mention (incident 2026-08-06, the mirror of the
          # soak failure two paragraphs up). A bare `#<n>` cannot tell "the PR that IMPLEMENTS the
          # issue" from "a PR that NAMES it as a sibling seam" — and #29's decomposition RULES
          # REQUIRE seams pinned naming the producing/consuming sibling, so every child cites its
          # siblings by design. circles#36 said "that's the sibling issue (#31)" and one citation
          # did both halves of the damage: #30's closeout starved (ghit=0) AND #31 matched as
          # merged-and-done (ghit=1) while its ride was still RUNNING — a false close would have
          # flipped agent/done, closed the issue, fired goal-review and unblocked #32/#18/#19 on
          # work that does not exist. Asymmetry is the whole argument: a MISSED closeout costs a
          # meta nudge (and is reported below), a FALSE one corrupts the goal's completion state.
          # The keyword set is exactly what agent-runtime#32/#34 makes `finalize` guarantee, so
          # this predicate meets that fix rather than racing it. Until #34's image rolls out
          # nothing matches here — that is INTENDED (hand-close per meta-state), not a regression.
          # ⚠ MUST match what `finalize` accepts, or PRs strand. Found live 2026-08-06 on
          # circles#43: finalize logged "issue link already present (#40) — left alone" because the
          # recipe body carries a line-anchored `Issue: #40` TRAILER, while this guard demanded a
          # verb keyword — so finalize considered the PR linked and C6 refused to close it. A
          # trailer is a strong, structured ownership claim, unlike the prose sibling citation this
          # guard exists to reject ("that is the sibling issue (#31)"); anchoring to line start is
          # what keeps the two apart. Widen HERE rather than narrowing finalize: the authoring side
          # is already deployed fleet-wide and its trailer is the recipes own convention.
          ghit="$(jq -r --arg b "$gbase" --argjson n "$gn" \
            '[.[] | select(.baseRefName == $b)
                  | select((((.body // "") | test("(implements|closes|close[ds]?|fixe[ds]?|fix|resolve[ds]?)[ \\t]+#\($n)\\b"; "i")))
                        or (((.body // "") | test("(?m)^[ \\t]*issue:[ \\t]*#\($n)\\b"; "i"))))] | length' <<<"$gmerged")" || ghit=0
          # Reported, never silent: a merged PR MENTIONS it but no strong link ⇒ ambiguous, held.
          gmention="$(jq -r --arg b "$gbase" --argjson n "$gn" \
            '[.[] | select(.baseRefName == $b) | select((.body // "") | test("#\($n)\\b"))] | length' <<<"$gmerged")" || gmention=0
          gref="$(jq -r --argjson n "$gn" '[.[] | select(test("#\($n)\\b"))] | length' <<<"$gopen")" || gref=0
          # merged PR into the declared base cites the issue AND no OPEN PR still references it
          # (an open follow-up round means live work — not closeable yet)
          if [ "${ghit:-0}" -gt 0 ] && [ "${gref:-0}" -eq 0 ]; then
            c6g="${c6g}${gn}|${gbase}\n"; c6g_nums="${c6g_nums}${gn} "
          elif [ "${gmention:-0}" -gt 0 ] && [ "${ghit:-0}" -eq 0 ]; then
            orphans="${orphans}[$repo] ⛔ issue #${gn} — a merged PR into ${gbase} MENTIONS it but does not IMPLEMENT/CLOSE it (sibling-seam citation, not a closeout). Held: verify by hand, then hand-close. Auto-closeout resumes once agent-runtime#34's finalize ships the \`Implements #${gn}\` line.\n"
          fi
        done
      else
        echo "  [$repo] PROBE_FAILED reading merged/open PRs — FU-143 goal closeout skipped this tick (rule #6)" >&2
      fi
    fi
    # TRACKS rule 1 (open-PR bound) needs the count BEFORE the queued loop; the merge-path
    # clauses below reuse this same fetch (moved up 2026-08-03, ADR-097 — do not re-fetch).
    # mergeStateStatus is REQUIRED here: the FU-124 nudge below selects on it, and gh returns a
    # field it was not asked for as absent -> jq reads null -> the selector matched nothing, ever
    # (found 2026-08-05; the nudge had been silently falling back to the GitHub cron it exists to
    # stop depending on). Adding a selector field without adding it to --json is the failure mode.
    # ⚠ It happened AGAIN the very next commit to touch a selector: 671a053 (2026-08-02) scoped
    # the changes-requested clause on .author.login WITHOUT adding author here — the clause
    # matched NOTHING for four days (fixed 2026-08-06, with headRefName added for the FU-143
    # goal exclusions in the same breath). When you touch a jq selector, read this fetch first.
    # `body` is fetched for the FU-146 per-item hold: it carries the `Implements #<n>` line that
    # agent-runtime#34 now guarantees, which is the only reliable PR-to-issue key (branch names
    # are not — circles#31 rode `fix/p0-bake-resolution`, #32 rode `fix/32-p0-page-sunburst`).
    prsjson="$(gh pr list --repo "$slug" --state open --json number,title,labels,reviewDecision,autoMergeRequest,mergeStateStatus,author,headRefName,body 2>/dev/null)" || prsjson='[]'
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
    # WIPPODS_JSON MUST reset with them (FU-146, 2026-08-06): it is only assigned inside the elif
    # below, so a repo with no dispatchable work leaves the PREVIOUS repo pods in scope. Nothing
    # read it across repos before the per-item hold did; resetting closes that hole at the source.
    wip_busy=""; wip_allow=1; WIPPODS_JSON=""
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
    # ⚠ A POST-LAUNCH BUCKET IS NOT A SPROUT (ADR-102, homelab#207). It is bot-authored and carries
    # no `agent-fix`, so it matches this slice exactly — and it is a CONTAINER, not work. Left in,
    # every goal would add a permanent line to a report whose whole purpose is "these are rotting,
    # triage them", and the report's own instruction (label agent-fix[+queued] to adopt) would
    # dispatch a worker against an issue with nothing to build. Its children are the work, and they
    # appear here on their own when they land inert.
    # >>>REPLAY:sprout-report>>>
    sprouts="$(gh issue list --repo "$slug" --state open --json number,title,author,labels 2>/dev/null \
      | jq -r '[.[]|select((.author.is_bot == true) and (((.labels|map(.name))|index("agent-fix"))|not) and ((.title|startswith("post-launch:"))|not))|"  issue #\(.number) — \(.title) (by \(.author.login))"]|.[]' 2>/dev/null || true)"
    [ -n "$sprouts" ] && orphans="${orphans}[$repo] 🌱 bot-authored, awaiting human triage (FU-090 gate — label agent-fix[+queued] to adopt):\n${sprouts}\n"
    # <<<REPLAY:sprout-report<<<
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
        if depjson="$(gh issue view "$dnum" --repo "$dslug" --json state,stateReason,blockedBy 2>/dev/null </dev/null)"; then
          if [ "$(jq -r .state <<<"$depjson")" = "OPEN" ]; then
            blocked="${blocked} ${dslug}#${dnum}"
            # direct 2-cycle: the dependency's own native blockedBy points back at this issue.
            # GitHub may refuse creating such a pair; kept because that refusal is undocumented,
            # and rule #6 says never fail INTO a dispatch.
            if jq -e --arg u "https://github.com/${slug}/issues/${qnum}" \
                 '[((.blockedBy // {}).nodes // [])[] | .url] | index($u) != null' >/dev/null 2>&1 <<<"$depjson"; then
              qcycles="${qcycles}  issue #${qnum} ↔ ${dslug}#${dnum} — mutual blocked-by\n"
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
    done < <(printf '%s' "$queued" | jq -r '.[] | [ .number, .title, (([(.body // "") | scan("(?mi)^[ \\t]*touches:[ \\t]*(.+)$")] | flatten | join(",")) | if . == "" then "-" else . end), ([((.blockedBy // {}).nodes // [])[] | .url | capture("github.com/(?<r>[^/]+/[^/]+)/issues/(?<n>[0-9]+)") | "\(.r)#\(.n)"]
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
    #
    # THE SENTINEL SPANS THE WHOLE LANE (ADR-103 ratchet, homelab#208), selection included, because
    # the thing worth pinning is not any one leg but their INTERACTION: that a non-assembly merge
    # moves nothing, that a goal the lifecycle legs just acted on does not ALSO draw a goal-review
    # unit, and that a repo with no `task/goal` at all makes zero API calls. Extracting a leg on its
    # own would let each of those regress with every fixture still green.
    # >>>REPLAY:goal-lane>>>
    goals="$(printf '%s' "$openall" | jq -r '[.[] | select((.labels|map(.name)|index("task/goal")))] | .[].number' 2>/dev/null || true)"
    if [ -n "$goals" ]; then
      # one call for the whole repo's issues incl. closed — reused for every goal below.
      # `title,labels` ride along for the ADR-102 terminal legs (homelab#208): the close sweep
      # names what survives and the abandoned leg compares-then-writes on `agent/queued`. Extra
      # --json fields are free here (same request) and buying them with a second call would not be.
      kidsall="$(gh issue list --repo "$slug" --state all --limit 300 --json number,title,state,closedAt,parent,labels 2>/dev/null || echo '[]')"
      jq -e . >/dev/null 2>&1 <<<"$kidsall" || kidsall='[]'
      for g in $goals; do
        # FU-143 point 6: DESCENDANTS, not direct children — a sprout harvested from a child sits
        # at depth 2 (sub-issue of the CHILD), so a direct-children read neither re-fires this
        # clause when a sprout closes nor lets "goal met" see open sprouts. Same bug-shape the
        # budget gate already fixed in agent-session.sh (direct children [14,15] vs actual
        # descendants [14,15,17,18,21]). Fixpoint over the ONE kidsall fetch; the seen-set makes
        # it cycle-safe; depth is bounded (~3) by the reviewer emitting no Follow-ups at ≥2.
        gdesc=""; gfront="$g"
        while [ -n "$gfront" ]; do
          gnext="$(printf '%s' "$kidsall" | jq -r --arg f "$gfront" \
            '(($f | split(" ") | map(select(. != "") | tonumber))) as $F
             | [.[] | select(((.parent.number // 0)) as $p | $F | index($p)) | .number] | .[]' 2>/dev/null | tr '\n' ' ')" || gnext=""
          gnew=""
          for x in $gnext; do
            case " ${gdesc# } $g " in *" $x "*) ;; *) gnew="$gnew $x";; esac
          done
          gfront="${gnew# }"; gdesc="$gdesc$gnew"
        done
        # ── ADR-102 goal lifecycle: the midpoint and the three terminals (homelab#208) ──────────
        # WHAT CHANGED. Until now the goal-review play ruled "goal met" and the assembly PR's
        # `Fixes #<goal>` closed the goal on merge — one machine act deciding both "built as
        # specified" and "the idea works". circles#17 was machine-ruled met 100 minutes before the
        # operator refuted it, and that is not a prompt bug: nothing at merge time can know whether
        # production agrees. So the verdict is renamed ASSEMBLY-COMPLETE and demoted to a MIDPOINT
        # (the goal enters `goal/post-launch` and STAYS OPEN), and the goal closes only on a later
        # VERDICT — `goal/validated`, `goal/reverted`, `goal/abandoned`.
        #
        # WHY DETERMINISTIC AND HERE, not a session play. These four transitions are pure state
        # machine: a label is present, therefore issues close and labels move. ADR-094 says the LLM
        # never picks what a predicate can decide, and ADR-103 says a clause ships with an executed
        # replay — both point at shell, in the one place that already walks a goal's descendant
        # tree. The JUDGMENT stays outside the loop entirely: a human (later the KPI unit) applies
        # the verdict label, and this block only reacts to it.
        #
        # RUNS BEFORE the empty-descendants skip below, on purpose: a goal with no descendants at
        # all is still terminable, and `goal-review` is the clause that must not see it afterwards.
        glab="$(printf '%s' "$openall" | jq -r --argjson n "$g" \
          '[.[] | select(.number == $n) | .labels[].name] | join(" ")' 2>/dev/null || echo "")"
        gbody="$(printf '%s' "$openall" | jq -r --argjson n "$g" \
          '[.[] | select(.number == $n) | (.body // "")] | first // ""' 2>/dev/null || echo "")"
        gverdict=""
        for gv in validated reverted abandoned; do
          case " $glab " in *" goal/$gv "*) gverdict="$gv"; break ;; esac
        done
        gpl=0; case " $glab " in *" goal/post-launch "*) gpl=1 ;; esac
        gacted=""
        if [ -n "$gverdict" ]; then
          # ── TWO FAIL-CLOSED GATES BEFORE ANY TERMINAL WRITE ───────────────────────────────────
          # (1) AUTHORITY. `Verdict-authority: human | kpi` is a per-goal template line (ADR-102).
          # Only `human` is implemented here; the KPI unit is a later oracle-side issue, so a goal
          # that declares anything else is REPORTED and left alone rather than quietly ruled by the
          # wrong authority. Absent line ⇒ `human`, which is the safe default (it demands a person).
          # (2) ACTOR. The same breaker-#1 shape as goal-decompose, for the same reason and with
          # more at stake: this transition CLOSES a goal and, on revert, its whole tree. The App
          # holds issues:write, so nothing but this test stops the loop labelling its own goal
          # `goal/validated` and closing it. Bot ⇒ refuse. UNREADABLE ⇒ refuse (an unreadable
          # authorisation is not an authorisation — rule #6, never fail INTO a write).
          # ⚠ pipe to a REAL jq: `gh --jq` takes only an expression, and behind `|| echo ""` a
          # rejected --arg would yield an empty actor that this test must then treat as refusal.
          gauth="$(printf '%s\n' "$gbody" | awk '/^[ \t]*[Vv]erdict-authority:/ { v = $0; sub(/^[^:]*:[ \t]*/, "", v); gsub(/[ \t\r]/, "", v); print tolower(v); exit }')"
          [ -n "$gauth" ] || gauth="human"
          gactor="$(gh api "repos/${slug}/issues/${g}/events" --paginate 2>/dev/null \
            | jq -r --arg L "goal/${gverdict}" \
               '[.[] | select(.event == "labeled" and .label.name == $L)] | last | .actor.type // ""' 2>/dev/null || echo "")"
          if [ "$gauth" != "human" ]; then
            orphans="${orphans}[$repo] ⛔ goal #${g} carries goal/${gverdict} but declares \`Verdict-authority: ${gauth}\` — only \`human\` is implemented (ADR-102, homelab#208; the KPI unit is a later oracle-side issue). NOT actioned.\n"
            gacted="held"
          elif [ "$gactor" != "User" ]; then
            orphans="${orphans}[$repo] ⛔ goal #${g}: goal/${gverdict} was applied by ${gactor:-an UNREADABLE actor} — refusing to terminate (fail-closed: the loop may not rule its own goal; a human applies the verdict).\n"
            gacted="held"
          else
            # ── DESCENDANTS FIRST, THE GOAL LAST — the resumability contract ────────────────────
            # A closed goal drops out of `openall` and this leg never fires for it again. So a pass
            # that died halfway through the descendants with the goal ALREADY closed would strand
            # the remainder forever, with nothing reporting it. Closing the goal last means a
            # partial pass is simply re-run by the next scan, which is also what makes the per-pass
            # cap below safe rather than a silent truncation.
            gcap="${GOAL_TERMINAL_MAX:-20}"; gdone=0; gleft=0; gswept=""
            # TITLE LAST, and that is not cosmetic: `read` with IFS='|' puts every remaining field
            # into the final variable, so a title containing a pipe (they do) can only widen the
            # column that already absorbs the rest. Any other position would shift `dlabels` and
            # silently mis-read the `agent/queued` test one leg down.
            while IFS='|' read -r dn dstate dlabels dtitle; do
              [ -n "$dn" ] || continue
              [ "$dstate" = "OPEN" ] || continue
              case "$gverdict" in
                reverted)
                  # "the tree stays readable history" (ADR-102): CLOSE with an audit comment, never
                  # delete, and `not planned` because the work is not going to happen — the premise
                  # died with the goal. The scan's own stale-dep flag reads that reason downstream.
                  if [ "$gdone" -lt "$gcap" ]; then
                    if gh issue close "$dn" --repo "$slug" --reason "not planned" --comment "🤖 closed with goal #${g}, which was REVERTED (ADR-102 terminal, applied by a human as \`goal/reverted\`). The idea this work served was refuted in production, so its descendants die with it — this is successful refutation, not failure, and the issue stays as readable history. Reopen only if a new goal adopts the premise. Written by \`agents/coordinator-scan.sh\`." >/dev/null 2>&1; then
                      gdone=$((gdone+1))
                    else
                      gleft=$((gleft+1))
                      orphans="${orphans}[$repo] ⚠ goal #${g} revert: could not close descendant #${dn} (gh write refused?) — the goal stays OPEN so the next scan retries\n"
                    fi
                  else
                    gleft=$((gleft+1))
                  fi ;;
                abandoned)
                  # "descendants inert" — NOT closed. An abandoned goal ran out of money before a
                  # verdict; its work may still be worth doing under a refill or another goal, so
                  # the issues survive. What must stop is DISPATCH: a queued descendant of a dead
                  # goal burns a coordinator ride per tick to be refused by the launcher pre-flight,
                  # which is exactly the goal-174 shape. Compare-then-write (label discipline).
                  case " $dlabels " in
                    *" agent/queued "*)
                      if [ "$gdone" -lt "$gcap" ]; then
                        if gh issue edit "$dn" --repo "$slug" --remove-label "agent/queued" >/dev/null 2>&1 \
                           && gh issue comment "$dn" --repo "$slug" --body "🤖 de-queued: goal #${g} was ABANDONED (ADR-102 terminal — budget exhausted before a verdict). The issue is left OPEN and inert on purpose; the work may still be worth doing, but it may not spend a budget that is gone. Re-queue it under a refilled or different goal. Written by \`agents/coordinator-scan.sh\`." >/dev/null 2>&1; then
                          gdone=$((gdone+1))
                        else
                          gleft=$((gleft+1))
                          orphans="${orphans}[$repo] ⚠ goal #${g} abandon: could not de-queue descendant #${dn} (gh write refused?) — the goal stays OPEN so the next scan retries\n"
                        fi
                      else
                        gleft=$((gleft+1))
                      fi ;;
                  esac ;;
                validated)
                  # ── THE CLOSE SWEEP, REPORT-FIRST (⚖ pre-decided on homelab#208) ──────────────
                  # Batch disposition of the bucket's leftovers becomes LEGAL exactly here — and it
                  # stays a PROPOSAL until the goal registry panel exists, because "close 14 issues"
                  # is the one batch act nobody can undo by reading a diff. So: no descendant write
                  # at all on this leg. List what survives, propose a disposition per item from the
                  # labels already in hand, and let the operator confirm.
                  case "$dtitle" in
                    post-launch:*) gswept="${gswept}    #${dn} — ${dtitle} → CONTAINER: close with the goal\n" ;;
                    *) case " $dlabels " in
                         *" agent/queued "*|*" agent/in-progress "*|*" agent/review "*)
                           gswept="${gswept}    #${dn} — ${dtitle} → LIVE: let it finish, or re-home it into another goal (batch re-homing is legal at this sweep)\n" ;;
                         *) gswept="${gswept}    #${dn} — ${dtitle} → INERT: close as superseded, or re-home\n" ;;
                       esac ;;
                  esac ;;
              esac
            done <<<"$(printf '%s' "$kidsall" | jq -r --arg d "$gdesc" \
              '(($d | split(" ") | map(select(. != "") | tonumber))) as $D
               | [.[] | select(.number as $n | $D | index($n))] | sort_by(.number) | .[]
               | [(.number | tostring), .state, ((.labels // []) | map(.name) | join(" ")), (.title // "")] | join("|")' 2>/dev/null || true)"
            if [ "$gleft" -gt 0 ]; then
              # The goal is NOT closed while work remains — see the resumability contract above.
              orphans="${orphans}[$repo] ⏳ goal #${g} goal/${gverdict}: ${gdone} descendant(s) actioned, ${gleft} still to go (cap ${gcap}/scan) — the goal stays OPEN until the tree is done; the next scan continues\n"
              gacted="partial"
            else
              case "$gverdict" in
                validated)
                  greason="completed"
                  gnote="**VALIDATED** — production (or the operator's verdict-in-lieu) confirms the idea. Closed met."
                  [ -n "$gswept" ] && orphans="${orphans}[$repo] 📋 close sweep for VALIDATED goal #${g} (ADR-102 — REPORT-first, the batch action stays operator-confirmed until the goal registry panel exists):\n${gswept}" ;;
                reverted)
                  # The revert POINTER is declared, never guessed. ADR-102 makes the assembly squash
                  # the revert unit, so the pointer is a pin-rollback or a revert commit — both
                  # facts only the person who rolled back holds. A missing line is said plainly.
                  grev="$(printf '%s\n' "$gbody" | awk '/^[ \t]*[Rr]evert:/ { v = $0; sub(/^[^:]*:[ \t]*/, "", v); sub(/[ \t\r]+$/, "", v); print v; exit }')"
                  greason="completed"
                  gnote="**REVERTED** — production refuted the idea, and a refuted goal is a SUCCESSFULLY closed experiment, not a failure (hence \`completed\`, not \`not planned\`). Revert pointer: ${grev:-⚠ NONE DECLARED — add a \`Revert:\` line naming the pin rollback or the revert commit of the assembly squash; this comment is the audit record and it is incomplete without one}. ${gdone} open descendant(s) closed with the goal." ;;
                abandoned)
                  greason="not planned"
                  gnote="**ABANDONED** — budget exhausted before a verdict. Descendants are left OPEN and inert (${gdone} de-queued); refill or re-home them under another goal." ;;
              esac
              if gh issue close "$g" --repo "$slug" --reason "$greason" --comment "$(printf '%s\n' \
                    "🤖 goal terminal: ${gnote}" \
                    "" \
                    "Applied deterministically by \`agents/coordinator-scan.sh\` in reaction to the \`goal/${gverdict}\` label a human placed here — the loop reacts to the verdict, it never rules one (ADR-102, homelab#208)." )" >/dev/null 2>&1; then
                echo "  [$repo] ADR-102 terminal: goal #${g} → ${gverdict}, closed (${greason}); ${gdone} descendant(s) actioned"
                gacted="terminal"
              else
                orphans="${orphans}[$repo] ⚠ goal #${g}: descendants actioned for goal/${gverdict} but the goal itself could not be CLOSED (gh write refused?) — close it by hand; the next scan is idempotent on the descendants\n"
                gacted="partial"
              fi
            fi
          fi
        elif [ "$gpl" = 0 ]; then
          # ── ASSEMBLY-COMPLETE → POST-LAUNCH (the midpoint) ────────────────────────────────────
          # The assembly PR is the one with HEAD `goal/**` (its children have `fix/**` heads and a
          # `goal/**` BASE — the direction is what tells them apart). It is bound to THIS goal by a
          # line-anchored `Assembly-for: #<n>` trailer, the same strong-link shape `finalize` writes
          # as `Issue: #N` and for the identical reason (FU-143 / circles#36): a bare `#<n>` cannot
          # distinguish the PR that ASSEMBLES a goal from one that merely cites it, and here a false
          # match would announce a launch that never happened. No trailer, no transition — and a
          # merged goal/** PR that only MENTIONS the goal is reported rather than silently dropped.
          gmergedpr="$(gh pr list --repo "$slug" --state merged --limit 30 --json number,headRefName,body,mergedAt 2>/dev/null || echo '[]')"
          jq -e . >/dev/null 2>&1 <<<"$gmergedpr" || gmergedpr='[]'
          gasm="$(printf '%s' "$gmergedpr" | jq -r --argjson n "$g" \
            '[.[] | select((.headRefName // "") | startswith("goal/"))
                  | select((.body // "") | test("(?mi)^[ \\t]*assembly-for:[ \\t]*#\($n)\\b"))]
             | sort_by(.mergedAt // "") | last // {} | (.number // "") | tostring' 2>/dev/null || echo "")"
          case "$gasm" in ''|*[!0-9]*) gasm="" ;; esac
          if [ -z "$gasm" ]; then
            gasm_m="$(printf '%s' "$gmergedpr" | jq -r --argjson n "$g" \
              '[.[] | select((.headRefName // "") | startswith("goal/")) | select((.body // "") | test("#\($n)\\b"))] | length' 2>/dev/null || echo 0)"
            case "$gasm_m" in ''|*[!0-9]*) gasm_m=0 ;; esac
            [ "$gasm_m" -gt 0 ] && orphans="${orphans}[$repo] ⛔ goal #${g}: a merged goal/** PR MENTIONS it but carries no line-anchored \`Assembly-for: #${g}\` trailer — the post-launch transition is HELD (a mention is not an assembly claim). Add the trailer to the PR body, or label the goal by hand.\n"
          else
            # The bucket already exists in the ordinary case — `harvest-disposition` creates it at
            # the first closeout/review, deliberately earlier than this moment (IL-T17). Named here
            # so the comment tells a human where post-launch work goes; absence is not fatal.
            gbuck="$(gh api "repos/${slug}/issues/${g}/sub_issues" 2>/dev/null \
              | jq -r '[.[] | select(.title | startswith("post-launch:")) | .number] | first // ""' 2>/dev/null || true)"
            case "$gbuck" in ''|*[!0-9]*) gbuck="" ;; esac
            # Rendered here, not inline in the body below: `${x:+A}${x:-B}` reads like an if/else
            # and is not one — when x is SET the second expansion yields x itself, so the sentence
            # came out "sub-issue #7777". Two branches, one variable.
            if [ -n "$gbuck" ]; then
              gbucktxt="sub-issue #${gbuck}"
            else
              gbucktxt="the \`post-launch:\` bucket, which the next closeout or review creates under this goal"
            fi
            # LABEL FIRST, COMMENT SECOND, and the comment only on a label that stuck. The write is
            # not atomic and this leg is level-triggered: a landed comment with a failed label
            # re-comments every tick (the duplicate-bot-comment anomaly the FU-069 breaker watches
            # for), while a landed label with a failed comment costs one audit line and stops. Same
            # ORDER-IS-LOAD-BEARING reasoning as the IL-T16 phantom belt.
            if gh issue edit "$g" --repo "$slug" --add-label "goal/post-launch" >/dev/null 2>&1; then
              gh issue comment "$g" --repo "$slug" --body "$(printf '%s\n' \
                "🤖 **assembly-complete** — assembly PR #${gasm} merged. This goal is built as specified." \
                "" \
                "**That is a MIDPOINT, not a verdict** (ADR-102). Assembly-complete measures \"built as specified\"; it says nothing about whether the idea works — circles#17 was machine-ruled met 100 minutes before the operator refuted it, which is why this transition no longer closes anything. The goal is now \`goal/post-launch\` and STAYS OPEN, shipping to production at its own pace against the same \`Budget:\` line." \
                "" \
                "**Where post-launch work goes:** ${gbucktxt}. Children there base \`master\` and carry NO \`Base:\` line — the goal branch dies at the assembly squash, and goal identity is this issue plus its budget, never the branch. Open descendants still carrying a \`Base: goal/**\` line need retargeting to master at the next \`goal-review\`." \
                "" \
                "**It closes only on a VERDICT**, applied here as a label by this goal's verdict authority (\`Verdict-authority:\`, default \`human\`):" \
                "" \
                "- \`goal/validated\` — production confirms the idea → closed met, and the close sweep lists every surviving descendant with a proposed disposition (report-first; a human confirms the batch)." \
                "- \`goal/reverted\` — production refutes it → closed successfully-refuted, every open descendant closed with it. Roll back FIRST (the assembly squash is the revert unit) and declare the pointer as a \`Revert:\` line on this issue, or the audit record lands incomplete." \
                "- \`goal/abandoned\` — budget out before a verdict → closed not-planned; open descendants stay open but go inert." \
                "" \
                "Written by \`agents/coordinator-scan.sh\` (deterministic — no session judged this, and none can: the judgment is production's, or yours)." )" >/dev/null 2>&1 \
                || orphans="${orphans}[$repo] ⚠ goal #${g}: labelled goal/post-launch but the assembly-complete comment did not land (gh write refused?) — the transition HELD, the audit line is missing; add it by hand\n"
              echo "  [$repo] ADR-102 midpoint: goal #${g} → assembly-complete via PR #${gasm}, labelled goal/post-launch, left OPEN${gbuck:+ (bucket #${gbuck})}"
              gacted="post-launch"
            else
              orphans="${orphans}[$repo] ⚠ goal #${g}: assembly PR #${gasm} merged but \`goal/post-launch\` could not be applied (label missing from the claim taxonomy? gh write refused?) — the goal is stuck pre-launch; the next scan retries\n"
            fi
          fi
        fi
        # A goal this block moved is DONE for this pass: it is closed (terminal), just announced
        # (post-launch — that comment is also what retires the stateless goal-review predicate), or
        # deliberately held for a human. Any of the three makes a goal-review unit noise at best.
        [ -n "$gacted" ] && continue
        [ -z "${gdesc# }" ] && continue
        newest_close="$(printf '%s' "$kidsall" | jq -r --arg d "$gdesc" \
          '(($d | split(" ") | map(select(. != "") | tonumber))) as $D
           | [.[] | select(.number as $n | $D | index($n)) | select(.state == "CLOSED") | .closedAt] | sort | last // ""')"
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
    # <<<REPLAY:goal-lane<<<
    [ -n "$qblocked" ] && orphans="${orphans}[$repo] ⏳ queued-blocked (FU-087 native blocked-by; closure is seen next scan):\n${qblocked}"
    [ -n "$qcycles" ] && orphans="${orphans}[$repo] ⚠ blocked-by CYCLE (FU-087) — human-first, neither side dispatched:\n${qcycles}"
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
    # FU-143: an ASSEMBLY PR (head goal/**) with changes-requested is EXCLUDED — a fix round
    # pushes to the PR head, and the head IS the protected goal/** integration branch (the push
    # would be refused; the mandate is a NEW child on the goal — coordinator README goal-review
    # play). Report-only line below so it never rots silently.
    for u in $(printf '%s' "$prsjson" | jq -r '.[]|select(((.headRefName // "")|startswith("goal/")) and (.reviewDecision=="CHANGES_REQUESTED"))|.number'); do
      orphans="${orphans}[$repo] ⚠ ASSEMBLY PR #${u} has changes-requested (FU-143) — route as a NEW child on the goal; a fix round cannot push to the protected goal/** head\n"
    done
    for u in $(printf '%s' "$prsjson" | jq -r --arg wa "${WORKER_AUTHOR:-app/homelab-agents-1234}" '.[]|(.labels|map(.name)) as $L|select((($L|index("major/awaiting-human"))|not) and (($L|index("agent/error"))|not) and (($L|index("agent/arbitrate"))|not) and (.reviewDecision=="CHANGES_REQUESTED") and (.author.login==$wa) and (((.headRefName // "")|startswith("goal/"))|not))|.number'); do
      # ADR-094 project-WIP hold, same rationale as the queued gate above (meta-9, 2026-07-21:
      # while #60's fix round ran, every tick woke a redundant judge whose dispatch the launcher's
      # WIP=1 pre-flight would refuse — the Running worker IS this unit's in-flight work; C4/C5
      # re-emits if it dies, and the next bot verdict retires the clause).
      # FU-146 PER-ITEM hold (2026-08-06). The project-wide hold below was written when
      # REPO_MAX_WIP was 1, where "a worker is Running here" and "a worker is Running on THIS PR"
      # were the same sentence. ADR-097 raised the cap to 3 and silently made it a no-op for its
      # stated purpose: measured on circles PR#39, every tick AND doorbell re-emitted this unit
      # while its own fix round rode — ~59 of 71 coordinator sessions did nothing, and 13 of that
      # PR 22 comments were bot noise a human has to read past.
      # Key on the PR own linked issue vs the live ride pod names (agent-<stack>-issue-<n>-r<k>).
      # FAIL-SAFE BY CONSTRUCTION: no link found, or no pod probe this tick, falls through to the
      # project-wide behaviour unchanged — so this can only ADD holds, never remove one. And the
      # hold is conditioned on a LIVE pod, so it self-releases when that pod exits; it cannot wedge.
      pr_issue="$(printf '%s' "$prsjson" | jq -r --argjson n "$u" '.[] | select(.number == $n)
          | (.body // "")
          | (capture("(?i)(implements|closes|closed|fixes|fixed|resolves|resolved)[ \t]+#(?<i>[0-9]+)") | .i) // ""' 2>/dev/null)" || pr_issue=""
      if [ -n "$pr_issue" ] && [ -n "$WIPPODS_JSON" ] \
         && printf '%s' "$WIPPODS_JSON" | jq -e --arg pat "issue-${pr_issue}-" \
              '[.items[]? | select((.metadata.name // "") | contains($pat))] | length > 0' >/dev/null 2>&1; then
        orphans="${orphans}[$repo] ⏳ changes-requested held — a worker is already riding issue #${pr_issue} (FU-146 per-item):\n  PR #${u}\n"
        continue
      fi
      # BLOCKED-SOURCE hold (2026-08-07): an `agent/blocked` source issue is a HUMAN gate (budget
      # refusal, design decision) — re-judging its PR cannot move it and burned one sonnet judge
      # per cycle on circles PR#58 (AGENT_BUDGET_REFUSED, two sessions in 25 min). Fail-safe like
      # the hold above: no link, or issue not in openall → falls through unchanged; self-releases
      # the tick after the human clears the label (openall is re-fetched every tick).
      if [ -n "$pr_issue" ] \
         && printf '%s' "$openall" | jq -e --argjson n "$pr_issue" \
              '[.[] | select(.number == $n) | .labels[].name] | index("agent/blocked") != null' >/dev/null 2>&1; then
        orphans="${orphans}[$repo] ⏳ changes-requested held — source issue #${pr_issue} is agent/blocked (human-gated):\n  PR #${u}\n"
        continue
      fi
      if [ -n "$wip_busy" ]; then
        orphans="${orphans}[$repo] ⏳ changes-requested trigger held (project WIP at ${REPO_MAX_WIP} in ${repo}):\n  PR #${u}\n"
        continue
      fi
      # FU-147: the SAME no-op detection FU-115b gives the ci-red path. A fix round that completes
      # without pushing is otherwise invisible here, and the clause simply re-dispatches an
      # identical round forever. Live case that motivated it: circles#32 r3 died on a
      # goose-32602 truncation, reported `exit_status: clean`, banked nothing, and only a human
      # asking "where is the commit?" caught it. Reached only with NO live worker (both holds
      # above ran first), so a running round is never mistaken for a finished one.
      cr_probe="$(gh pr view "$u" --repo "$slug" --json comments,commits 2>/dev/null)" || cr_probe=''
      cr_noop=""
      if [ -n "$cr_probe" ]; then
        cr_noop="$(printf '%s' "$cr_probe" | jq -r "$NOOP_ROUND_JQ" 2>/dev/null)" || cr_noop=""
      fi
      if [ -n "$cr_noop" ]; then
        gh pr edit "$u" --repo "$slug" --add-label agent/arbitrate >/dev/null 2>&1 \
          && gh pr comment "$u" --repo "$slug" --body "ARBITRATE (changes-requested no-op round, FU-147): the last completed fix round posted its run stats without pushing a commit, so the reviewer findings are untouched and another identical round cannot converge. The coordinator arbitrate unit rules per the escalation table." >/dev/null 2>&1 \
          && orphans="${orphans}[$repo] ⚠ changes-requested NO-OP round → agent/arbitrate: PR #${u} (a completed round pushed nothing)\n" \
          || orphans="${orphans}[$repo] ⚠ changes-requested no-op arbitrate FAILED to label PR #${u} — human check\n"
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
          # ONE selector, THREE derivations (the belt, the report line, the unit) — this is
          # conditions (a)+(b) of the abandoned-ride predicate and the copies MUST NOT drift.
          # FU-143 point 2: the merged-into-goal set is NOT abandoned — excluded here (and so in
          # every derivation) or c4c5-redispatch, which outranks merged-closeout, re-rides merged
          # work every tick while the closeout unit starves. Detection block above.
          # ⚠ Kept SINGLE-quoted and concatenated as `jq "$C4C5_SEL"'|…'`. Pasting it into a
          # double-quoted jq program would eat one backslash and turn the `\\b` word boundary into
          # jq's `\b` BACKSPACE — the reference test would then match nothing and every
          # in-progress issue would read as abandoned. Variable expansion does no such thing.
          C4C5_SEL='.[] | select(((.labels|map(.name))|index("agent/error"))|not) | .number as $n
             | select((($cg | split(" ") | map(select(. != ""))) | index(($n|tostring))) | not)
             | select((($gb | split(" ") | map(select(. != ""))) | index(($n|tostring))) | not)
             | select(([$bodies[] | select(test("#\($n)\\b"))] | length) == 0)'
          # ── THE BELT (homelab#155): RECONCILE the phantom label, do not only report it ────────
          # A phantom `agent/in-progress` starves far more than its own issue: it counts against
          # REPO_MAX_WIP and holds every SIBLING through the ADR-097 footprint intersection
          # ("overlaps an in-progress issue's Touches"). Six of them across two stacks idled
          # oracle+circles for ~3h on 2026-08-08 and were cleared BY HAND — found only because the
          # operator asked why nothing was running. agent-runtime#36 owns the CAUSE (finalize must
          # run on every exit path); this is the BELT, because causes recur in new shapes (deadline
          # reap, node loss, OOM) and a belt catches every shape.
          # Two more holds before it writes, both fail-SAFE — an unreadable probe HOLDS, it never
          # clears (rule #6: never fail INTO a write):
          #   (c) PERSISTENCE. Nothing in a dispatch is transactional: the coordinator applies
          #       `agent/in-progress` and THEN creates the pod, and finalize opens the PR from
          #       inside a pod that is still Running. So a scan can land mid-transition and see
          #       (a)+(b) on perfectly live work. Two anchors, BOTH must be older than
          #       C4C5_PERSIST_S: the issue has been quiet (`updatedAt` — the label write that
          #       starts a ride bumps it, so this covers the dispatch race), and no agent-session
          #       pod for THIS issue went terminal recently (covers the finalize race, where the
          #       pod exits a beat before its PR appears).
          #   (d) NO MERGED PR mentions the issue. `Fixes #N` closes on a master merge so the
          #       normal case never reaches here — but a PR merged with a NON-closing reference
          #       leaves exactly this state, and re-queueing it re-rides finished work (the
          #       FU-143 lesson, one lane over). A bare mention is enough to hold: holding costs a
          #       report line, guessing costs a duplicate ride.
          # Anything the belt HOLDS keeps today's behaviour exactly — reported, and the
          # c4c5-redispatch unit still rides, so the LLM tick stays the path for every case the
          # belt will not touch by itself. Anything it CLEARS leaves the unit list: the issue is an
          # ordinary `agent/queued` item again and the normal dispatch path (with its footprint,
          # WIP and PR-cap gates) owns it on the next pass — no LLM tick spent to say "re-run it".
          c4c5_cleared=""
          c4c5_cands=""
          [ -n "$dispatchable" ] && c4c5_cands="$(printf '%s' "$inprog" \
            | jq -r --argjson bodies "$BODIES" --arg cg "${c6g_nums:-}" --arg gb "${goalbased_nums:-}" \
              "$C4C5_SEL"' | "\($n)|\(.updatedAt // "")"')"
          if [ -n "$c4c5_cands" ]; then
            now_s="$(date -u +%s)"
            # A SECOND pod probe on purpose: the live one above is the tested condition-(a)
            # predicate and stays byte-for-byte what it was. This one wants the TERMINAL pods it
            # filters out, with their finish times. Both probes failing is the same story — hold.
            TPODS="$("$KUBECTL" $KUBE -n "$repo" get pods -l app=agent-session,project="$repo" -o json 2>/dev/null)" || TPODS=""
            c4c5_merged="$(gh pr list --repo "$slug" --state merged --limit 40 --json body --jq '[.[].body // ""]' 2>/dev/null)" || c4c5_merged=""
            if ! jq -e . >/dev/null 2>&1 <<<"${TPODS:-}" || ! jq -e . >/dev/null 2>&1 <<<"${c4c5_merged:-}"; then
              orphans="${orphans}[$repo] ⚠ PROBE_FAILED (terminal pods / merged PRs) — the phantom-label belt held every candidate this tick; the C4/C5 report + unit below are unaffected (rule #6)\n"
            else
              for cand in $c4c5_cands; do
                cn="${cand%%|*}"; cupd="${cand#*|}"
                # jq parses the timestamps, not `date -d` — same reader the pod janitor at the top
                # of this file uses, and it does not assume GNU date in the scan image. An
                # UNPARSEABLE stamp yields -1, which is < the window, so it holds.
                cage="$(jq -rn --arg t "$cupd" --argjson now "$now_s" \
                  '($t | fromdateiso8601? // null) as $s | if $s == null then -1 else ($now - $s) end' 2>/dev/null || echo -1)"
                case "$cage" in ''|*[!0-9-]*) cage=-1;; esac
                if [ "$cage" -lt "$C4C5_PERSIST_S" ]; then
                  orphans="${orphans}[$repo] ⏳ phantom-label belt HELD — issue #${cn} was touched $(( cage < 0 ? 0 : cage / 60 ))m ago (< the ${C4C5_PERSIST_S}s transition-race guard, or an unreadable timestamp); re-checked next scan\n"
                  continue
                fi
                # Pod-transition anchor. No matching terminal pod at all ⇒ nothing recent to race
                # with (the big sentinel); a jq/read failure ⇒ 0 ⇒ held.
                ctage="$(jq -r --arg pat "issue-${cn}-" --argjson now "$now_s" \
                  '[ .items[]? | select((.metadata.name // "") | contains($pat))
                     | .status.containerStatuses[]?.state.terminated.finishedAt // empty
                     | fromdateiso8601? // empty ] | max as $m
                   | if $m == null then 999999999 else ($now - $m) end' <<<"$TPODS" 2>/dev/null || echo 0)"
                case "$ctage" in ''|*[!0-9-]*) ctage=0;; esac
                if [ "$ctage" -lt "$C4C5_PERSIST_S" ]; then
                  orphans="${orphans}[$repo] ⏳ phantom-label belt HELD — issue #${cn}: a worker pod for it went terminal $(( ctage / 60 ))m ago (< the ${C4C5_PERSIST_S}s guard — finalize may still be landing its PR)\n"
                  continue
                fi
                if [ "$(jq -r --argjson nn "$cn" '[.[] | select(test("#\($nn)\\b"))] | length' <<<"$c4c5_merged" 2>/dev/null || echo 1)" -gt 0 ]; then
                  orphans="${orphans}[$repo] ⛔ phantom-label belt HELD — issue #${cn} is mentioned by a MERGED PR: this may be finished work whose reference did not close it, not an abandoned ride. Re-queueing it would re-ride merged work — verify by hand (the c4c5-redispatch unit still carries it to the tick).\n"
                  continue
                fi
                # ⚠ ORDER IS LOAD-BEARING, and `gh issue edit --add-label X --remove-label Y` is
                # NOT atomic: if the add fails while the remove lands, the issue holds no lifecycle
                # label at all and goes invisible to EVERY clause. That is precisely how the
                # 2026-08-08 hand-clear lost oracle#193 a second time. Add `agent/queued` FIRST,
                # remove `agent/in-progress` SECOND, then RE-READ and prove the end state — the
                # audit comment is posted only against a state we verified.
                # The re-read runs on BOTH legs: a half-applied write is exactly the state that
                # needs reporting ACCURATELY, and "the edit returned non-zero" says nothing about
                # which of the two landed.
                # ⚠ `set -euo pipefail` is on: a bare `A && B` whose result is non-zero is NOT in a
                # condition context and would ABORT THE WHOLE SCAN mid-write — every later clause
                # and every other repo in the stack silently starved by one failed label edit.
                # (Caught in the fixture harness, exit 1 right after the failing edit.) The `if`
                # and the `|| true` are what keep a refused write a REPORTED write.
                cok=""
                if gh issue edit "$cn" --repo "$slug" --add-label agent/queued >/dev/null 2>&1; then
                  gh issue edit "$cn" --repo "$slug" --remove-label agent/in-progress >/dev/null 2>&1 || true
                fi
                cend="$(gh issue view "$cn" --repo "$slug" --json labels --jq '[.labels[].name]|join(",")' 2>/dev/null || echo "PROBE_FAILED")"
                case ",${cend}," in
                  *",agent/queued,"*) case ",${cend}," in *",agent/in-progress,"*) : ;; *) cok=1;; esac;;
                esac
                if [ -n "$cok" ]; then
                  gh issue comment "$cn" --repo "$slug" --body "$(printf '%s\n' \
                    "🤖 **Phantom \`agent/in-progress\` cleared — re-queued \`agent/queued\`** (deterministic scan belt, homelab#155)." \
                    "" \
                    "Audit, as of \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\`:" \
                    "" \
                    "- **No worker pod.** \`kubectl -n ${repo} get pods -l app=agent-session,project=${repo} --field-selector=status.phase!=Succeeded,status.phase!=Failed\` returned nothing, and no \`agent-session\` pod named for this issue went terminal within the last $(( C4C5_PERSIST_S / 60 ))m." \
                    "- **No open PR** references \`#${cn}\` (every open PR body in \`${slug}\` was checked), and no merged PR mentions it either." \
                    "- **The state persisted.** The issue had been untouched for $(( cage / 60 ))m — past the $(( C4C5_PERSIST_S / 60 ))m guard, which is one full scan interval plus margin, so this is not a pod-transition race." \
                    "" \
                    "The label was starving more than this issue: it counted against the repo WIP ceiling and held every sibling whose \`Touches:\` intersect it (ADR-097). The cause of the missing finalize is agent-runtime#36; this belt only reconciles the state it left behind." \
                    "" \
                    "If a ride really is live, its pod is what proves it — the clause holds as soon as one is visible. Re-applying \`agent/in-progress\` by hand with no pod behind it will simply be cleared again after the guard window." )" >/dev/null 2>&1 || true
                  c4c5_cleared="${c4c5_cleared}${cn} "
                  orphans="${orphans}[$repo] ⚠ phantom \`agent/in-progress\` RECONCILED → \`agent/queued\`: issue #${cn} (no live pod, no open PR, state persisted $(( cage / 60 ))m — audit commented; homelab#155). Frees its ADR-097 footprint + a WIP slot; dispatch resumes on the next pass.\n"
                else
                  orphans="${orphans}[$repo] ⛔ phantom-label reconcile FAILED or landed HALF-APPLIED on issue #${cn} — labels are now [${cend}]. Check by hand: with NEITHER label the issue is invisible to every clause; with BOTH it still holds its footprint. The issue keeps its c4c5-redispatch unit either way.\n"
                fi
              done
            fi
          fi
          v2="$(printf '%s' "$inprog" | jq -r --argjson bodies "$BODIES" --arg cg "${c6g_nums:-}" --arg gb "${goalbased_nums:-}" \
            --arg done "${c4c5_cleared:-}" \
            "$C4C5_SEL"' | select((($done | split(" ") | map(select(. != ""))) | index(($n|tostring))) | not)
             | "  issue #\($n) — \(.title) [in-progress, worker terminal, no PR → C4/C5 re-tick]"')"
          # The held goal children get their OWN report line — silence here is what let the first
          # one through. This is a REPORT, never a unit: a human/meta decides merged-vs-abandoned.
          ambig="$(printf '%s' "$inprog" | jq -r --argjson bodies "$BODIES" --arg cg "${c6g_nums:-}" --arg gb "${goalbased_nums:-}" \
            '.[] | select(((.labels|map(.name))|index("agent/error"))|not) | .number as $n
             | select((($cg | split(" ") | map(select(. != ""))) | index(($n|tostring))) | not)
             | select((($gb | split(" ") | map(select(. != ""))) | index(($n|tostring))))
             | select(([$bodies[] | select(test("#\($n)\\b"))] | length) == 0)
             | "  issue #\($n) — \(.title) [goal child, worker terminal, no open PR, and NO merged PR cites it — merged-but-unlinked or abandoned? C4/C5 HELD (FU-143 / agent-runtime#32). Verify against the goal branch, then close it or re-queue it by hand.]"')"
          [ -n "$ambig" ] && orphans="${orphans}[$repo] ⛔ goal child in an undecidable state — C4/C5 held rather than guessing:\n${ambig}\n"
          if [ -n "$dispatchable" ]; then
            # An issue the belt RE-QUEUED is deliberately excluded: it is a plain queued item now,
            # and emitting the unit too would race the queued lane onto the same issue.
            for u in $(printf '%s' "$inprog" | jq -r --argjson bodies "$BODIES" --arg cg "${c6g_nums:-}" --arg gb "${goalbased_nums:-}" \
                --arg done "${c4c5_cleared:-}" \
                "$C4C5_SEL"' | select((($done | split(" ") | map(select(. != ""))) | index(($n|tostring))) | not)
                 | "\($n)|\([.labels[].name | select(startswith("task/"))] | first // "task/fix" | ltrimstr("task/"))"'); do
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
    # ⚠ The label is STICKY on two of the four rulings (escalate keeps it deliberately; a human is
    # the next mover), so selecting on the label ALONE re-emits the unit every scan forever — the
    # PR#234 churn. The unit is emitted only when the state a ride would read has MOVED since the
    # last arbitrate dispatch (homelab#198, fingerprint helper at the top of this file); unchanged
    # state is a REPORT line, which is what an escalation waiting on a human should look like.
    # >>>REPLAY:arbitrate-gate>>>
    for u in $(printf '%s' "$prsjson" | jq -r '.[]|(.labels|map(.name)) as $L|select((($L|index("agent/error"))|not) and ($L|index("agent/arbitrate")))|.number'); do
      afp="$(pr_state_fp_pair "$slug" "$u")"; afp_prev="${afp#*|}"; afp_cur="${afp%%|*}"
      if [ -n "$afp_cur" ] && [ "$afp_cur" = "$afp_prev" ]; then
        orphans="${orphans}[$repo] ⏳ arbitrate DEBOUNCED — PR #${u}: head, checks, reviewDecision and newest verdict are all unchanged since the last arbitrate dispatch (\`state-fp:${afp_cur}\`, homelab#198). The escalation STANDS and the ruling on the thread is still the current one — a human (or new content) is the next mover, so no ride is spent to re-derive it.\n"
        continue
      fi
      units="${units}arbitrate|${repo}|pr-${u}\n"
    done
    # <<<REPLAY:arbitrate-gate<<<

    # ci-red (FU-115 / MP-T12, CONTENT-BASED rewrite of the old ci-red-stale time-gate): an ARMED
    # red PR is invisible to the whole merge path (updater + reviewer both skip red). The OLD trigger
    # was "quiet > RED_STALE_HOURS(4h)" — a coarse LAST-ACTIVITY timer that a no-op fix round's OWN
    # run-stats comment reset, giving a 4h-spaced LIVELOCK with no exhaustion→escalation (the red
    # loop lacked the review loop's ROUNDS_MAX→arbitrate). NOW keyed on CONTENT + a cap, symmetric
    # with the review path (MP-T11), and woken near-instant by the exporter's red edge (github-exporter
    # maybe_dispatch_cired → /coordinate) instead of only the poll. Per red PR we read the fix-round
    # history from the durable run-stats evidence in EITHER channel (`stats_ts`, §ROUND EVIDENCE,
    # TWO CHANNELS) plus `headRefOid` (NOT from `🔴 ci-red round` markers — those were a design
    # that never shipped; stale prose caught by the #198 ride):
    #   attempts==0                    → DISPATCH (first red)
    #   attempts>=RED_ROUNDS_MAX(3)     → ARBITRATE (exhausted — MP-T11 tie-break). The count is
    #                                    keyed on the ISSUE, summed across every PR that references
    #                                    it (homelab#156) — per-PR is only the fast path, because
    #                                    close-and-re-PR would otherwise hand out a fresh budget.
    #   head8 != last dispatched head  → DISPATCH (a round pushed new-but-still-red content; re-attempt)
    #   else (same head, round done)   → ARBITRATE (NO-OP round: the worker produced nothing → escalate,
    #                                    never re-dispatch the same input — this is the anti-livelock)
    # Guarded probe: statusCheckRollup needs checks:read; a 403/bad read SKIPS loudly (rule #6). Held
    # while a worker Runs (the fix round owns it). Dispatch cap 2/repo/scan; arbitrate is uncapped
    # (labeling is cheap + idempotent).
    # `body` rides this list for the FU-146 per-item hold below — without it the hold's issue-link
    # capture is always empty and the hold silently never fires (fail-safe, but useless).
    red_probe="$(gh pr list --repo "$slug" --state open --json number,labels,author,autoMergeRequest,headRefOid,headRefName,statusCheckRollup,body 2>/dev/null)" || red_probe=''
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
        # FU-146 PER-ITEM hold, ported here 2026-08-07 — the THIRD clause to need it (main scan
        # path `fc606e2`, doorbell fast path `277a73f`, now this one). The comment above claims
        # "Held while a worker Runs (the fix round owns it)", but `wip_busy` is the PROJECT-wide
        # cap: at ADR-097's REPO_MAX_WIP=3 it stays empty while ONE worker rides, so the clause
        # re-emitted the same unit every tick. Live 2026-08-07: tick `q66s7` dispatched pr-50 at
        # wip 2 while `agent-circles-issue-19-r3` had ridden 6 minutes, and each session correctly
        # exited clean — waste, on a subscription the loop needs for real dispatch.
        # Same predicate and fail-safes as the other two: no issue link or no pod probe → falls
        # through unchanged (can only ADD holds), and the hold needs a LIVE pod so it self-releases.
        red_issue="$(printf '%s' "$red_probe" | jq -r --argjson n "$u" '.[]|select(.number==$n)|(.body // "")
            | (capture("(?i)(implements|closes|closed|fixes|fixed|resolves|resolved)[ \t]+#(?<i>[0-9]+)") | .i) // ""' 2>/dev/null)" || red_issue=""
        if [ -n "$red_issue" ] && [ -n "$WIPPODS_JSON" ] \
           && printf '%s' "$WIPPODS_JSON" | jq -e --arg pat "issue-${red_issue}-" \
                '[.items[]? | select((.metadata.name // "") | contains($pat))] | length > 0' >/dev/null 2>&1; then
          orphans="${orphans}[$repo] ⏳ ci-red held — a worker is already riding issue #${red_issue} (FU-146 per-item):\n  PR #${u}\n"
          continue
        fi
        # BLOCKED-SOURCE hold (2026-08-07) — same as the changes-requested clause's, same
        # fail-safes; this clause is where the churn was actually measured (circles PR#58).
        if [ -n "$red_issue" ] \
           && printf '%s' "$openall" | jq -e --argjson n "$red_issue" \
                '[.[] | select(.number == $n) | .labels[].name] | index("agent/blocked") != null' >/dev/null 2>&1; then
          orphans="${orphans}[$repo] ⏳ ci-red held — source issue #${red_issue} is agent/blocked (human-gated):\n  PR #${u}\n"
          continue
        fi
        if [ -n "$wip_busy" ]; then
          orphans="${orphans}[$repo] ⏳ ci-red held (project WIP at ${REPO_MAX_WIP} in ${repo}):\n  PR #${u}\n"
          continue
        fi
        head8="$(printf '%s' "$red_probe" | jq -r --argjson n "$u" '.[]|select(.number==$n)|.headRefOid[0:8]')"
        u_head="$(printf '%s' "$red_probe" | jq -r --argjson n "$u" '.[]|select(.number==$n)|.headRefName // ""')"
        # attempts = durable count of completed fix rounds on THIS PR — the fast path under the
        # issue-keyed ceiling below, and still what the no-op detector needs. Restart-safe: it reads
        # GitHub, never launcher memory. Bounds the loop: a no-op round costs at most
        # RED_ROUNDS_MAX attempts before it escalates, never the old infinite 4h-spaced livelock.
        # (Immediate no-op detection — same head across a completed round → arbitrate NOW — is the
        # FU-115(b) refinement below; the cap is the v1 bound.)
        # ⚠ `stats_ts` — NOT a comment count. One round stopped meaning one comment when ADR-103
        # moved the table onto the check-run + the appended summary line; the def at the top of this
        # file reads both channels, and every round-counting site in here goes through it. See the
        # §ROUND EVIDENCE, TWO CHANNELS block.
        # >>>REPLAY:ci-red-rounds>>>
        round_probe="$(gh pr view "$u" --repo "$slug" --json comments,commits 2>/dev/null)" || round_probe=''
        attempts="$(printf '%s' "$round_probe" | jq -r "${STATS_TS_DEF}"'stats_ts | length' 2>/dev/null)" || attempts=0
        case "$attempts" in ''|*[!0-9]*) attempts=0;; esac
        # FU-115(b) immediate no-op detection (built 2026-08-02, marker-free): if the NEWEST
        # stats comment post-dates the newest NON-MERGE commit, the last completed round pushed
        # nothing — same head, still red → arbitrate NOW instead of burning the remaining cap.
        # Merge commits excluded (the updater's BEHIND merges are not round output — the
        # nine-review-loop lesson). ISO-8601 strings compare correctly as strings.
        noop_round=""
        if [ "$attempts" -ge 1 ]; then
          noop_round="$(printf '%s' "$round_probe" | jq -r "$NOOP_ROUND_JQ" 2>/dev/null)" || noop_round=""
        fi
        RED_MAX="${RED_ROUNDS_MAX:-3}"
        # ISSUE-KEYED ROUNDS CEILING (homelab#156, FU-154). `attempts` above is PER-PR, and PR
        # identity is not the unit of the work: close-and-re-PR is a DESIGNED play as of 2026-08-08
        # (#210 re-landed as #221, #214 closed and its issue re-queued, #209 superseded by #218-v2),
        # so every re-creation handed the loop a fresh RED_MAX budget — circles#19 burned five rounds
        # across PR#50 (2) + a fresh #51 (1) plus earlier ones and never hit the cap. The ISSUE is the
        # stable key: sum the SAME run-stats evidence across every PR in this repo whose branch or
        # body references that issue id. Per-PR stays the FAST PATH (no extra API call when it already
        # trips); the issue-keyed sum is the CEILING and can only RAISE the count, never lower it.
        # FAIL-OPEN, matching this clause's guarded-probe posture: an unreadable list warns and leaves
        # the per-PR count standing — the window is the newest 100 PRs, so a miss only UNDER-counts.
        # ⚠ The sibling-match rule (branch `issue-<n>-`, else body `#<n>`, both boundary-anchored) is
        # duplicated in review-reflex.sh's issue-keyed verdict ceiling. Change both or neither.
        # The key falls back to the fix/issue-<n>- branch convention when the body carries no closing
        # keyword; `red_issue` above stays body-only on purpose (it gates the per-item holds).
        red_key="$red_issue"
        if [ -z "$red_key" ]; then
          red_key="$(printf '%s' "$u_head" | sed -n 's/.*issue-\([0-9][0-9]*\)\(-.*\)\{0,1\}$/\1/p')"
        fi
        red_rounds="$attempts"; red_rounds_key="PR #${u}"
        if [ "$attempts" -lt "$RED_MAX" ] && [ -n "$red_key" ]; then
          if red_sib="$(gh pr list --repo "$slug" --state all --limit 100 \
                          --json number,headRefName,body,comments 2>/dev/null)"; then
            red_sum="$(printf '%s' "$red_sib" | jq -r --arg n "$red_key" "${STATS_TS_DEF}"'
              def refs($n): ((.headRefName // "") | test("(^|[^0-9])issue-" + $n + "(-|$)"))
                            or ((.body // "") | test("(^|[^0-9])#" + $n + "([^0-9]|$)"));
              [ .[] | select(refs($n)) ]
              | "\(length) \([ .[] | stats_ts[] ] | length)"
            ' 2>/dev/null)" || red_sum=""
            read -r red_sib_prs red_sib_n <<<"${red_sum:-}"
            case "${red_sib_n:-}" in ''|*[!0-9]*) red_sib_n=""; echo "  [$repo] WARN: issue-keyed round sum unreadable for issue #${red_key} — per-PR count stands for PR #${u}" >&2;; esac
            if [ -n "$red_sib_n" ] && [ "$red_sib_n" -gt "$red_rounds" ]; then
              red_rounds="$red_sib_n"; red_rounds_key="issue #${red_key} (${red_sib_prs} PRs)"
            fi
          else
            echo "  [$repo] WARN: issue-keyed round probe FAILED (gh pr list --state all) — per-PR count stands for PR #${u}" >&2
          fi
        fi
        # <<<REPLAY:ci-red-rounds<<<
        if [ -n "$noop_round" ]; then
          gh pr edit "$u" --repo "$slug" --add-label agent/arbitrate >/dev/null 2>&1 \
            && gh pr comment "$u" --repo "$slug" --body "ARBITRATE (ci-red no-op round, FU-115b): the last completed fix round left the head unchanged at ${head8} and CI is still red — dispatching more identical rounds cannot converge. The coordinator's arbitrate unit rules per the escalation table." >/dev/null 2>&1 \
            && orphans="${orphans}[$repo] ⚠ ci-red NO-OP round → agent/arbitrate NOW: PR #${u} (round ${attempts} pushed nothing, still red @ ${head8})\n" \
            || orphans="${orphans}[$repo] ⚠ ci-red no-op arbitrate FAILED to label PR #${u} — human check\n"
        elif [ "$red_rounds" -lt "$RED_MAX" ]; then
          # CURRENCY (homelab#198) — the EXTENSION of this clause's existing content key, not a
          # second mechanism beside it. The markers above answer "did a round complete, and did it
          # push?"; they say nothing when a dispatched round never RAN (pod never started, session
          # died pre-finalize, the /coordinate doorbell re-rang on the same red edge): no stats
          # comment, so `attempts` never moves, no new commit, so `head8` never moves, and the
          # clause re-dispatches the identical input every scan. The fingerprint covers that hole
          # from the other side — the state a fix round would READ. Checked here, inside the
          # dispatch branch only: the no-op→arbitrate leg above must stay level-triggered (it is
          # the anti-livelock), and `continue` before the cap so a debounced PR never spends one of
          # the two dispatch slots a live red PR could use.
          # >>>REPLAY:ci-red-gate>>>
          rfp="$(pr_state_fp_pair "$slug" "$u")"; rfp_prev="${rfp#*|}"; rfp_cur="${rfp%%|*}"
          if [ -n "$rfp_cur" ] && [ "$rfp_cur" = "$rfp_prev" ]; then
            orphans="${orphans}[$repo] ⏳ ci-red DEBOUNCED — PR #${u}: still red at ${head8} with head, checks, reviewDecision and newest verdict all unchanged since the last ci-red dispatch (\`state-fp:${rfp_cur}\`, homelab#198). A round was already dispatched at this exact input; re-dispatching it cannot read anything new. If no round ever completed here, the ride went terminal — that is the finding, not more dispatches.\n"
            continue
          fi
          # <<<REPLAY:ci-red-gate<<<
          # DISPATCH a fix round (under the attempt cap — the ISSUE-keyed one, see above)
          if [ "$red_n" -lt 2 ]; then
            # FU-106 (c): a RED deploy/* bump PR in an -iac repo is the typed infra-delta — the
            # infra-enrich class (diff values.schema.json, enrich the bump PR), not the generic play.
            case "$repo:$u_head" in
              *-iac:deploy/*) units="${units}infra-enrich|${repo}|pr-${u}\n"; rclause="infra-enrich";;
              *)              units="${units}ci-red|${repo}|pr-${u}\n"; rclause="ci-red";;
            esac
            # units-only clauses were invisible to the `[ -z "$items" ]` gate (the meta-14 stall) —
            # every dispatchable unit MUST also add an items line.
            items="${items}[$repo] PR #${u} — ${rclause} (CI red, armed; attempt $((red_rounds+1))/${RED_MAX} on ${red_rounds_key} @ ${head8})\n"
            red_n=$((red_n+1))
          fi
        else
          # ARBITRATE: red rounds EXHAUSTED. Reuse the review path's MP-T11 machinery — label
          # agent/arbitrate + comment; the arbitrate scan clause + coordinator tie-break (re-dispatch
          # a stronger model / park / close) take over. This is the Red→arbitrate edge the FSM lacked.
          gh pr edit "$u" --repo "$slug" --add-label agent/arbitrate >/dev/null 2>&1 \
            && gh pr comment "$u" --repo "$slug" --body "ARBITRATE (ci-red, FU-115): ${red_rounds} fix rounds counted on ${red_rounds_key} and CI still red at ${head8} (cap ${RED_MAX}). Rounds are counted against the ISSUE, not the PR (homelab#156), so closing this PR and opening a fresh one does not restore the budget. The CI-red fix-round loop is not converging on its own — review automation now skips it; the coordinator's arbitrate unit rules per the escalation table (re-dispatch with a stronger model / close as not-mergeable / escalate to a human)." >/dev/null 2>&1 \
            && orphans="${orphans}[$repo] ⚠ ci-red → agent/arbitrate: PR #${u} (${red_rounds} rounds on ${red_rounds_key}, still red — exhausted)\n" \
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
    # FU-143 point 1: the goal children detected above (OPEN, merged into their declared goal/**
    # base, keyword inert) — same unit, same play, same cap; emitted FIRST because C4/C5 was told
    # to stand aside for exactly these, and the closeout unblocks goal-review + blocked-by
    # siblings. The play closes the ISSUE too (README §merged-closeout, goal-child leg).
    for gb in $(printf '%b' "${c6g:-}"); do
      gn="${gb%%|*}"; gbase="${gb#*|}"
      if [ "$c6_n" -lt 3 ]; then
        units="${units}merged-closeout|${repo}|issue-${gn}\n"
        items="${items}[$repo] issue #${gn} — merged-closeout (FU-143: goal child merged into ${gbase}, keyword inert)\n"
        c6_n=$((c6_n+1))
      else
        orphans="${orphans}[$repo] ⏳ merged-closeout backlog (cap 3/scan): issue #${gn} (goal child) waits for the next pass\n"
      fi
    done
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
    # The stack's WORKER model — not this session's model. It is the sizing input the goal-budget
    # estimator needs (a cap is per-ride, and the rides a goal funds are worker rides), read here
    # beside cmodel so the harvest-disposition block below stays free of claim lookups.
    wmodel="$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|.workerModel // "claude/haiku"')"
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
    # homelab#198: RECORD the fingerprint of the state this ride is about to read, for the two
    # clauses whose emission is gated on it. Here and not at emission because this is the one place
    # a unit is known to be THE dispatched one; and BEFORE the spawn because the session's own work
    # (a pushed fix round, a dismissal, a rerun) is exactly the state change that must re-open the
    # gate — recording afterwards would fingerprint the outcome and debounce the follow-up ride.
    # A refused write only costs the debounce (the clause re-emits next scan, i.e. today's
    # behaviour), so it WARNs and dispatches; it never blocks the ride it is annotating.
    # >>>REPLAY:dispatch-marker>>>
    case "${uclause}:${uitem}" in
      arbitrate:pr-*|ci-red:pr-*|infra-enrich:pr-*)
        dfp="$(pr_state_fp_pair "${ORG}/${urepo}" "${uitem#pr-}")"; dfp="${dfp%%|*}"
        if [ -z "$dfp" ]; then
          echo "  WARN: state fingerprint unreadable for ${urepo} ${uitem} — dispatching anyway; the ${uclause} debounce cannot arm this pass (homelab#198)" >&2
        elif ! gh pr comment "${uitem#pr-}" --repo "${ORG}/${urepo}" --body "$(printf '%s\n' \
              "🤖 \`state-fp:${dfp}\` — deterministic scan dispatching a \`${uclause}\` unit at $(date -u +%Y-%m-%dT%H:%M:%SZ)." \
              "" \
              "Machine-readable debounce marker (homelab#198), written by \`agents/coordinator-scan.sh\`, not by the session that follows. It hashes the state that ride reads — head sha, every check's conclusion, \`reviewDecision\`, and the newest verdict's timestamp. While the hash is unchanged this clause emits a report line instead of another unit, so an escalation waiting on a human costs no further rides; any real movement on this PR changes it and the clause re-arms by itself." )" >/dev/null 2>&1; then
          echo "  WARN: could not record state-fp on ${urepo} ${uitem} (gh write refused?) — dispatching anyway; the ${uclause} clause will re-emit on unchanged state (homelab#198)" >&2
        fi
        ;;
    esac
    # <<<REPLAY:dispatch-marker<<<
    # ── HARVEST DISPOSITION (ADR-102 goal container, homelab#207) ─────────────────────────────
    # WHAT THIS DECIDES, AND WHY HERE. Until ADR-102 the harvest step of the merged-closeout play
    # judged two things in prose: where a sprout hangs (under the issue that produced it) and
    # whether it may self-apply `agent-fix`+`agent/queued` (unconditionally, whenever the
    # originating issue carried `Base: goal/**`). Both outlive the thing that authorises them —
    # the 2026-08-09 census caught #195/#211-shaped sprouts self-queueing with no budget left and
    # the goal already closed, and oracle-fleet goal-174 grew three generations 34h post-close
    # with nothing owning the tree. Under ADR-102 a sprout belongs to its goal's POST-LAUNCH
    # bucket and the self-queue right dies with the goal, so both answers are now DETERMINISTIC
    # and computed here — the session is told, never asked (ADR-094).
    #
    # AT DISPATCH, not at emission: exactly one unit is known to be THE dispatched one here (the
    # same reason the state-fp marker sits directly above), so the ancestry probe + budget read
    # cost one unit's worth of calls per scan instead of the emission cap's three.
    #
    # BUCKET CREATION IS IDEMPOTENT and fires at the goal-review/closeout site, which is where
    # ADR-102 puts it. It fires EARLIER than "at assembly merge" on purpose: deliverable 2 files
    # open-goal sprouts into the bucket, so the container must exist while the goal is still
    # pre-launch. One container per goal either way — the search below is what makes a second call
    # a no-op, not a second bucket.
    #
    # FAIL-CLOSED, EVERY EDGE. No goal ancestor → nothing is emitted and the master-lane harvest
    # stays inert exactly as breaker #1 has always required. Goal closed, budget exhausted, no
    # machine-parsed `Budget:` line, unreadable probe, or a bucket that could not be resolved →
    # `selfqueue=no`. The right to queue is a GRANT from an open funded goal; an unreadable grant
    # is not a grant, and the cost asymmetry is stark (a missed queue costs one human triage, a
    # wrong one costs rides against money that is gone).
    # >>>REPLAY:harvest-disposition>>>
    uharvest=""
    case "$uclause" in
      merged-closeout|goal-review)
        hslug="${ORG}/${urepo}"; hgoal=""; hbucket=""; hsq=""; hwhy=""
        case "$uclause" in
          # A goal-review unit IS the goal. Nothing to walk.
          goal-review) hgoal="${uitem#issue-}" ;;
          # A closeout item is the GOAL itself (the assembly PR's own closeout), a goal CHILD
          # (depth 1), or a sprout of one (depth 2+). Test the item, then climb the native
          # sub-issue chain. Testing the ITEM first is what puts the bucket under a goal whose own
          # closeout is the unit; a walk that only looks upward would miss exactly the
          # assembly-merge case ADR-102 names.
          #
          # THE BOUND IS 6, and it is measured, not guessed. The reviewer's depth-≥2 bar says
          # chains should stop at three, so 4 looked generous — until the #207 dry-run walked the
          # real circles#29 tree and found #75 → #47 → #18 → #29, which consumes all four. ADR-102's
          # other case, oracle-fleet goal-174, grew THREE generations post-close. A bound that a
          # live tree already touches is a bound that silently drops the deepest sprouts back onto
          # the master lane — the exact class of loss this clause exists to stop — so it sits well
          # clear of the observed maximum. The cost is two reads per hop, only until the goal
          # answers; a non-goal item hits the top of its tree and stops long before this bites.
          *) hcur="${uitem#issue-}"; hdepth=0
             case "$hcur" in ''|*[!0-9]*) hcur="";; esac
             # ⚠ PIPE TO A REAL jq, never `gh --jq`, on every read below (the standing rule in this
             # file — `gh --jq` takes only an expression and silently degrades). It is also what
             # lets the replay fixtures record REAL API payloads instead of post-jq scalars.
             while [ -n "$hcur" ] && [ "$hdepth" -lt 6 ]; do
               if [ "$(gh issue view "$hcur" --repo "$hslug" --json labels 2>/dev/null \
                        | jq -r '[.labels[].name]|index("task/goal")!=null' 2>/dev/null || echo false)" = "true" ]; then
                 hgoal="$hcur"; break
               fi
               hp="$(gh api "repos/${hslug}/issues/${hcur}/parent" 2>/dev/null \
                      | jq -r '.number // ""' 2>/dev/null || true)"
               case "$hp" in ''|*[!0-9]*) break;; esac
               hcur="$hp"; hdepth=$((hdepth+1))
             done ;;
        esac
        if [ -n "$hgoal" ]; then
          hgj="$(gh issue view "$hgoal" --repo "$hslug" --json title,state 2>/dev/null || echo '{}')"
          jq -e . >/dev/null 2>&1 <<<"$hgj" || hgj='{}'
          hgtitle="$(printf '%s' "$hgj" | jq -r '.title // ""')"
          hgstate="$(printf '%s' "$hgj" | jq -r '.state // "PROBE-FAILED"')"
          # ONE bucket, found by title under the goal's own sub-issue list — the container is a
          # SUB-ISSUE and not a label (operator ruling 2026-08-09: one container, one burn-down
          # anchor), so the sub-issue tree is also where you look it up.
          hbucket="$(gh api "repos/${hslug}/issues/${hgoal}/sub_issues" 2>/dev/null \
            | jq -r '[.[] | select(.title | startswith("post-launch:")) | .number] | first // ""' 2>/dev/null || true)"
          case "$hbucket" in ''|*[!0-9]*) hbucket="";; esac
          if [ -z "$hbucket" ] && [ -n "$hgtitle" ]; then
            hburl="$(gh issue create --repo "$hslug" --title "post-launch: ${hgtitle}" --body "$(printf '%s\n' \
              "Post-launch bucket for goal #${hgoal} — created by \`agents/coordinator-scan.sh\`, not by a session (ADR-102, homelab#207)." \
              "" \
              "**What lands here.** Every sprout harvested from a review of a PR descended from this goal. Assembly merge is a MIDPOINT, not the end: the goal keeps shipping to production at its own pace, and this issue is the one container that work hangs off — so the burn-down is a query, not archaeology." \
              "" \
              "**Children base \`master\`.** The goal branch dies at the assembly squash; goal identity is this issue plus its \`Budget:\` line, never the branch. Children here therefore carry NO \`Base:\` line." \
              "" \
              "**They spend the goal's money.** This bucket is a sub-issue of the goal, so its children are goal DESCENDANTS and the launcher pre-flight already counts them against the goal's \`Budget:\` (\`agents/goal-budget.sh\`). A sprout self-queues only while the goal is OPEN and that sum still fits; otherwise it lands here inert for human triage." \
              "" \
              "Closing this issue does not close the goal, and closing the goal kills this tree with it (ADR-102 terminals).")" 2>/dev/null || true)"
            hbucket="${hburl##*/}"
            case "$hbucket" in ''|*[!0-9]*) hbucket="";; esac
            if [ -n "$hbucket" ]; then
              # Native sub-issue edge, the same call the harvest and decompose plays make — the
              # lineage is read by machinery (the budget walk above all), so prose will not do.
              hbid="$(gh api "repos/${hslug}/issues/${hbucket}" 2>/dev/null \
                       | jq -r '.id // ""' 2>/dev/null || true)"
              if [ -z "$hbid" ] || ! gh api -X POST "repos/${hslug}/issues/${hgoal}/sub_issues" \
                   -F sub_issue_id="$hbid" >/dev/null 2>&1; then
                # An UNPARENTED bucket is worse than none: its children would sit outside the
                # goal's descendant walk and spend money the budget gate cannot see.
                echo "  ⚠ harvest: bucket #${hbucket} created but NOT linked under goal #${hgoal} (${hslug}) — its children would escape the budget walk; link it by hand" >&2
                hbucket=""
              fi
            fi
          fi
          if [ "$uclause" = "merged-closeout" ]; then
            if [ -z "$hbucket" ]; then
              hsq="no"; hwhy="no post-launch bucket could be resolved or created under goal #${hgoal} — nowhere to file, so nothing self-queues"
            elif [ "$hgstate" != "OPEN" ]; then
              hsq="no"; hwhy="goal #${hgoal} is ${hgstate} — the self-queue right dies with the goal (ADR-102)"
            else
              # The SAME arithmetic the launcher pre-flight enforces with — advisory here, per the
              # ⚖ line on #207: this read may demote a label, the pre-flight is what refuses a
              # ride. No dispatch issue is passed; the question is "does the goal have room", not
              # "may this key be minted".
              command -v goal_budget_read >/dev/null 2>&1 || . "${HERE}/goal-budget.sh"
              goal_budget_read "$hslug" "$hgoal" "${wmodel:-claude/haiku}"
              case "$GB_VERDICT" in
                within)    hsq="yes"; hwhy="goal #${hgoal} OPEN and Σ(spend + reservations) \$${GB_SUM} ≤ Budget \$${GB_BUDGET}" ;;
                exhausted) hsq="no";  hwhy="goal #${hgoal} OPEN but Σ(spend + reservations) \$${GB_SUM} > Budget \$${GB_BUDGET} — out of funding" ;;
                *)         hsq="no";  hwhy="goal #${hgoal} carries no machine-parsed \`Budget:\` line — no grant, no self-queue right (ADR-102 fail-closed)" ;;
              esac
            fi
          fi
          uharvest=" goal=${hgoal}${hbucket:+ bucket=${hbucket}}${hsq:+ selfqueue=${hsq}}"
          echo "  harvest disposition (ADR-102): ${urepo} ${uitem} → goal #${hgoal}, bucket ${hbucket:-UNRESOLVED}${hsq:+, self-queue ${hsq}}${hwhy:+ — ${hwhy}}"
        fi
        ;;
    esac
    # <<<REPLAY:harvest-disposition<<<
    echo "→ dispatching item unit for ${name}: ${urepo} ${uitem} (${uclause}${uclass:+, class ${uclass}}${uparent:+, child of goal #${uparent}}, model ${cmodel}, wip ${uwip})…"
    # FU-080 perStack: under a stack-scoped instance the item session runs in the loop home
    # (<stack>-agents, SA agentstack-loop, broker git creds) instead of agent-coordinator.
    bash "${HERE}/coordinator-session.sh" --stack "$name" --repos "${repos% }" --main-repo "$mainrepo" \
      --model "$cmodel" ${LOOP_NS:+--loop-ns "$LOOP_NS"} --wip "$uwip" \
      --item "repo=${urepo} item=${uitem} clause=${uclause}${uclass:+ class=${uclass}}${uparent:+ parent=${uparent}}${uharvest}"
  else
    echo "  run it (interactive, supervised):"
    echo "    devbox run coordinator-session -- --stack ${name} --repos \"${repos% }\" --main-repo ${mainrepo} --tick"
  fi
done

[ -n "$any_work" ] || echo "no stack has actionable work — nothing to spawn (no LLM woken)."
