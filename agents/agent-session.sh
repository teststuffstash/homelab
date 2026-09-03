#!/usr/bin/env bash
# agent-session — spawn a SCOPED, ephemeral per-project agent pod and attach.
#
# The cockpit→pod handoff: the risky per-project agent run happens in its OWN pod (one repo, that
# project's budget-capped key, its own egress) — NOT in the shared jail, which only orchestrates.
# Interactive and non-interactive are the SAME pod; only the command differs.
#
#   bash agents/agent-session.sh sleep-tracking
#       → interactive: preps the repo, drops you into a shell; run `goose`/`opencode` by hand.
#   bash agents/agent-session.sh sleep-tracking \
#       --run "goose run --recipe .agents/fix.yaml --params issue=42"
#       → headless: runs the recipe to a branch+PR, streams logs, pod self-terminates.
#
# Flags: --run "<cmd>"  --ref <base-branch>  --repo <git-url>  --harness goose|opencode|claude  --model provider/model
#
# FU-019 (ADR-078): migrate Pod → agent-sandbox Sandbox CR; scoped SA + RBAC. FU-020/FU-018
# (ADR-081): Cilium egress policy + auth-injecting proxy so the git/LLM tokens are INJECTED, never
# held in the pod; the egress policy must allow the nix cache for `devbox install`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# The goal `Budget:` arithmetic, shared with the scan's harvest-disposition block (ADR-102/#207).
# This launcher is its ENFORCING caller — see the pre-flight below.
. "${HERE}/goal-budget.sh"
# The one machine channel on a timeline (ADR-103 rule 2, #210): the check-run + the single edited
# summary comment. Shared with the coordinator brief's dispatch notice — one implementation, so the
# fallback stats emitter below cannot drift from what the rest of the loop writes.
. "${HERE}/machine-comment.sh"
# The 128KiB per-argv-element ceiling the base64 recipe carry rides into (homelab#242). Shared with
# retro-session.sh, whose brief travels the same channel one hop earlier — measured just before the
# pod command is frozen into `args:` below.
. "${HERE}/argv-guard.sh"
# $KUBECTL + $KUBE — the jail-vs-pod kubectl resolution, shared with retro-session.sh, which mints
# its cell's own budget key through the same two variables (homelab#270). Moved out verbatim; the
# reasoning that used to sit here lives in the helper's header.
. "${HERE}/kube.sh"

PROJECT="${1:?usage: agent-session <project> [--run \"<cmd>\"] [--ref <branch>] [--repo <url>] [--harness goose|opencode|claude] [--model provider/model]}"
case "$PROJECT" in --help|-h)  # a bare --help used to be swallowed as the PROJECT name (junk /route + ref-resolve rows, seen live 2026-08-02)
  echo "usage: agent-session <project> [--run \"<cmd>\"] [--ref <branch>] [--repo <url>] [--harness goose|opencode|claude] [--model provider/model] [--task issue-<n>] [--round <r>] [--recipe <path>] [--docker] [--openrouter-secret <name>] [--work-branch <b>] [--no-attach] [--no-arm] [--context-repo <url>]…"
  exit 0
;; esac
shift || true

# Default to a cheap, multi-provider, CACHED model bounded by the per-session budget cap. The
# per-stack chain (primary + fallbacks) lives in agents/stacks.json; an infra failure here costs one
# STRIKE (re-dispatch on the next chain model), so free/new entries are fair — see
# docs/agents/model-routing.md. Still avoid CLOAKED models as primary (rotated out → 404s mid-run).
RUN_CMD=""; BASE_REF="master"; REPO_URL=""; HARNESS="opencode"; MODEL="openrouter/deepseek/deepseek-v4-flash"; NO_ATTACH=""; OR_SECRET=""; TASK=""; ROUND="1"; WORK_BRANCH=""; DOCKER=""; RECIPE=""; NO_ARM=""; CONTEXT_REPOS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run)       RUN_CMD="$2"; shift 2;;
    --ref)       BASE_REF="$2"; shift 2;;
    --repo)      REPO_URL="$2"; shift 2;;
    --harness)   HARNESS="$2"; HARNESS_SET=1; shift 2;;
    --model)     MODEL="$2"; MODEL_SET=1; shift 2;;
    --docker)    DOCKER=1; shift;;    # repo needs a real docker daemon (kind/k3d CI gate): kata microVM pod + dind sidecar — stack POLICY, from the AgentStack claim's fixer.docker (counterpart of CI choosing the VM runner)
    --openrouter-secret) OR_SECRET="$2"; shift 2;;  # use a per-SESSION budget key Secret (the coordinator's ephemeral OpenRouterKey) instead of the shared <project>-openrouter
    --task)      TASK="$2"; shift 2;;   # transcript-capture task key: issue-<n> | pr-<n> (§A1 bucket prefix)
    --round)     ROUND="$2"; shift 2;;  # worker round on that task (prefix worker-r<N>)
    --work-branch) WORK_BRANCH="$2"; shift 2;;  # resume an EXISTING remote branch (fix round on a PR branch / a salvaged WIP branch) — the entrypoint checks it out tracking origin, deterministically (old finding C)
    --recipe)    RECIPE="$2"; shift 2;;  # claude harness: launcher BUILDS the run command from this goose recipe path — never LLM-assembled (2026-07-21 #55 incident)
    --no-attach) NO_ATTACH=1; shift;;   # interactive: create + prep the pod, print the attach cmd, don't exec
    --no-arm)    NO_ARM=1; shift;;      # human-gated PR (FU-105 researcher): finalize skips arm-at-open (AGENT_ARM_PR=0); C9 skips research/* branches
    --context-repo) CONTEXT_REPOS="${CONTEXT_REPOS:+$CONTEXT_REPOS }$2"; shift 2;;  # repeatable: read-only reference clone at /work/context/<name> (docs/spikes/context-repos.md pilot); public https URLs only — anonymous clone, no token
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

# ── RIDE PHASE TIMINGS (FU-160, homelab#287; spike: docs/spikes/ride-latency-breakdown.md) ──────
# One ride was reconstructed by hand on 2026-08-09, and the single most useful fact in it — whether
# that pod's image was node-cached — turned out to be UNKNOWABLE after the event: the pod events
# had aged out and nothing had emitted the timing while it was happening. A degraded cache adding
# minutes to every ride would present as "the loop feels slow" and nothing in the platform would
# say otherwise. So the launcher publishes the phases IT owns, as each one closes:
#
#   agent_run_phase_seconds{phase=dispatch-gates|pod-spinup}
#
# ⚠ TWO PHASES, AND THE LIST ENDS AT pod-Ready. This is the corrected shape (homelab#324); #287
# shipped `ride` and `bookkeeping` here too, and both had to go. The launcher closes them only if
# the LAUNCHER PROCESS outlives the ride, and in the cluster dispatch path it usually does not —
# the seat that runs this script is a coordinator session whose shell invocation is time-bounded,
# so the launcher is killed mid-follow and the last thing it ever pushed is `pod-spinup`.
# MEASURED on the live gateway at 2026-08-12T04:0xZ, 24 ride groups:
#   • `ride` was present on 5 of 24 — and the survivors are not the short rides (892s survived,
#     292s did not), so it is a race with the seat's remaining lifetime, not a threshold anyone
#     can tune. A metric that lands one time in five is not a slow metric, it is a biased one.
#   • On all 5 where it did land, `ride` equalled the sum of the IN-POD rows to within 1.0–2.7s
#     (892 vs 889.3, 268 vs 267.0, 215 vs 213.3, 339 vs 338.0, 200 vs 197.3). The envelope carries
#     no fact those rows do not — the delta IS the Ready→container-clock seam, and nothing else.
#   • `bookkeeping` was 0.0 on 5 of 5. It never measured anything, because FU-064/FU-043 moved the
#     work it was named for (arm, stats comment, strike) INTO the pod; what is left in the exit
#     path here is the fallback-not-taken, plus the router report and the doorbell.
# So the honest family is the two phases the launcher can always close, and the interior belongs
# to whoever survives to see it. That is `agent-finalize` (agent-runtime#66), which since
# 2026-08-11 pushes `clone|devbox-install|llm-loop|finalize` under this same metric and job with
# one extra grouping label, `source="in-pod"` — a distinct group, so neither side clobbers the
# other. Launcher rows carry no `source` label; `agent_run_phase_seconds{source=""}` selects
# exactly the two below. Together the chain is gapless from dispatch to PR-open.
#
# THE FAMILY IS RE-PUSHED WHOLE, every time, and that is not redundancy. The pushgateway replaces
# per METRIC NAME within a group, so a push carrying only `phase="pod-spinup"` would DELETE the
# `phase="dispatch-gates"` series pushed a minute earlier — every ride would end holding exactly
# one phase, the last one. Accumulating and re-pushing also means a ride that dies before Ready
# leaves the phase it did complete, which is the case the metric exists for.
#
# ITS OWN JOB, never `agent_run`: agent-finalize PUTs the run group at end-of-ride, and a PUT
# replaces the group WHOLESALE. Phases pushed into that group would be alive for the length of the
# ride and then vanish at the moment the ride became interesting. Group key is the same
# (project, issue, round, role) tuple the run ledger uses, so this adds one group and four series
# per ride alongside the group `agent_run_*` already leaves — same cardinality class, bounded the
# same way (emptyDir + persistence file: the store resets on a pushgateway reschedule).
#
# Best-effort, exactly like `scan_phase` and the router report: a dead gateway is an observability
# fault and must never change what gets dispatched. A jail run has no route to the ClusterIP at
# all (it does not cross the BGP boundary), so the warning is latched to one line per run.
# >>>REPLAY:run-phase-metric>>>
RUN_PHASE_PGW="${AGENT_PUSHGATEWAY_URL-http://prometheus-pushgateway.monitoring.svc.cluster.local:9091}"
RUN_PHASE_FAMILY=""      # every phase closed so far, in exposition format — re-pushed as one family
RUN_PHASE_WARNED=""
rp_now() { date -u +%s; }     # replay seam: the wall clock
RUN_PHASE_MARK="$(rp_now)"    # start of the OPEN phase; every close moves it forward
run_phase() {   # $1 = dispatch-gates | pod-spinup — close the open phase, publish, open the next
  local phase="${1:-}" now rp_issue
  case "$phase" in
    # The set is CLOSED at pod-Ready, deliberately (homelab#324). `ride` and `bookkeeping` land
    # here as unknown phases now — that is the guard, not an oversight: re-adding a call after the
    # log-follow re-introduces a series that exists on one ride in five and duplicates the in-pod
    # rows when it does. The interior is `source="in-pod"`, agent-finalize's.
    dispatch-gates|pod-spinup) ;;
    *) echo "run_phase: unknown phase '${phase}' — nothing pushed" >&2; return 0 ;;
  esac
  now="$(rp_now)"
  RUN_PHASE_FAMILY="${RUN_PHASE_FAMILY}agent_run_phase_seconds{phase=\"${phase}\"} $(( now - RUN_PHASE_MARK ))
"
  RUN_PHASE_MARK="$now"
  # No gateway (explicitly disabled) or no task key (an interactive/ad-hoc session) → the clock
  # still advances, nothing is published. `issue` is the run ledger's own convention: AGENT_TASK
  # with a leading `issue-` stripped, so `pr-12` stays `pr-12` and the two families join.
  [ -n "$RUN_PHASE_PGW" ] && [ -n "$TASK" ] || return 0
  rp_issue="${TASK#issue-}"
  printf '%s\n%s\n%s' \
    "# TYPE agent_run_phase_seconds gauge" \
    "# HELP agent_run_phase_seconds Seconds this ride spent in one LAUNCHER-owned phase; the in-pod breakdown belongs to agent-finalize (FU-160)." \
    "$RUN_PHASE_FAMILY" \
    | curl -fsS --max-time 5 --data-binary @- \
        "${RUN_PHASE_PGW}/metrics/job/agent_run_phase/project/${PROJECT}/issue/${rp_issue}/round/${ROUND}/role/worker" >/dev/null 2>&1 \
    || { [ -n "$RUN_PHASE_WARNED" ] \
           || echo "run_phase: pushgateway unreachable (${RUN_PHASE_PGW}) — ride unaffected; this ride contributes no agent_run_phase_seconds (a jail run lands here: the ClusterIP does not cross the BGP boundary)" >&2
         RUN_PHASE_WARNED=1; }
  return 0
}
# <<<REPLAY:run-phase-metric<<<

# ── ADR-096 P3/P4: consult the router at the model-decision seam (POST /route) ──
# AGENT_ROUTER=shadow (default): consult + log the divergence, dispatch unchanged — the ≥1wk
# soak that gates the flip. =authoritative: the decision REPLACES the model — but an explicit
# --model always wins (the ADR override rule; under authoritative, dispatchers stop passing
# --model and the launcher owns the choice, ADR-094). =off: today's behavior exactly.
# The chain is the stacks.json mirror entry for this project's stack (same source the scan
# merges cluster-wins); /route filters it against strikes, cooldowns, class policy and capacity
# server-side and answers a dispatch or a typed defer. Fail-open: unreachable proxy (jail run
# without AGENT_EGRESS_PROXY) → static behavior, one loud line.
_srow="$(jq -c --arg p "$PROJECT" '[.stacks[] | select(.repos[]? == $p)][0] // {}' "$HERE/stacks.json" 2>/dev/null)" || _srow="{}"
[ -n "$_srow" ] || _srow='{}'   # normalize ONCE — `${_srow:-{}}` is a trap, see the guard below
# Per-stack routerMode (ADR-096 P4 knob, 2026-08-03): the claim/mirror row sets the stack's
# mode; an EXPLICIT AGENT_ROUTER env still wins (jail experiments). Chainless stacks (no
# workerModel) declare authoritative — enforced below.
_stack_rmode="$(printf '%s' "$_srow" | jq -r '.routerMode // ""')"
if [ -z "${AGENT_ROUTER:-}" ] && [ -n "$_stack_rmode" ]; then AGENT_ROUTER="$_stack_rmode"; fi
AGENT_ROUTER="${AGENT_ROUTER:-shadow}"
if [ "$AGENT_ROUTER" != "off" ]; then
  ROUTER_URL="${AGENT_EGRESS_PROXY:-${AGENT_OPENROUTER_PROXY:-http://openrouter-proxy.agent-egress.svc.cluster.local:8080}}"
  _chain="$(printf '%s' "$_srow" | jq -c '([.workerModel] + (.workerModelFallbacks // [])) | map(select(. != null))' 2>/dev/null)" || _chain="[]"
  if [ -n "${HARNESS_SET:-}" ]; then  # an explicit --harness bounds the rail this pod can ride
    case "$HARNESS" in
      claude) _chain="$(printf '%s' "$_chain" | jq -c 'map(select(startswith("claude/")))')";;
      *)      _chain="$(printf '%s' "$_chain" | jq -c 'map(select(startswith("claude/") | not))')";;
    esac
  fi
  # homelab#158 leg 1: a SUBSCRIPTION-rail ride sends NO key_ref. The OpenRouter key is that ride's
  # fallback rail, never its prerequisite — passing the ref invites the router to weigh OpenRouter
  # key state (headroom, a mint that never happened) in a decision about a rail that does not use
  # it. On 2026-08-08 that inversion deferred claudeTier dispatches four times while the
  # subscription sat idle. `null` = "this dispatch has no OpenRouter identity", which is the truth.
  # >>>REPLAY:route-request>>>
  # M11a's named caller gap, closed (the launcher-side leg deliberately left out of homelab#159's
  # Touches:): send the dispatch's LABELS — one gh read; the ROUTER resolves urgency from the
  # git-owned urgency_map it already falls back to, so the table keeps exactly one reader — and
  # an EXPLICIT `urgency` only where this launcher knows a round-state fact no label carries:
  # --work-branch means a fix round on an existing PR (ci-red retry / changes-requested), which is
  # deadline-tight by §M11's own examples. Best-effort by construction: an unreadable or non-array
  # label set degrades to [] (the router's default-tight path) — a labels read must never block or
  # skew a dispatch, and jq -e validates the shape so a gh error string cannot torpedo the jq -nc
  # below into an empty body.
  _route_labels="[]"
  case "${TASK:-}" in issue-*)
    _route_labels="$(gh issue view "${TASK#issue-}" --repo "${ORG:-teststuffstash}/${PROJECT}" \
        --json labels --jq '[.labels[].name]' 2>/dev/null)" || _route_labels="[]";;
  esac
  printf '%s' "$_route_labels" | jq -e 'type=="array"' >/dev/null 2>&1 || _route_labels="[]"
  _route_urgency=""
  [ -z "${WORK_BRANCH:-}" ] || _route_urgency="tight"
  _keyref="${PROJECT}/${OR_SECRET:-${PROJECT}-openrouter}"
  # Subscription-rail rides (Anthropic AND opencode-go) carry no OpenRouter key ref — the Go rail's
  # credential lives proxy-side (ADR-107 chunk C), exactly like the claude oauth.
  case "${HARNESS}:${MODEL}" in claude:*|*:claude/*|*:opencode-go/*) _keyref="";; esac
  _req="$(jq -nc --arg stack "$(printf '%s' "$_srow" | jq -r '.name // ""')" \
      --arg task "${TASK:-adhoc}" --arg session "agent-${PROJECT}-${TASK:-adhoc}-r${ROUND}" \
      --arg key_ref "$_keyref" \
      --arg urgency "$_route_urgency" \
      --argjson chain "$_chain" \
      --argjson labels "$_route_labels" \
      --argjson deny "$(printf '%s' "$_srow" | jq -c '.modelDeny // []')" \
      '{stack: $stack, task: $task, role: "worker", session: $session,
        key_ref: (if $key_ref == "" then null else $key_ref end), chain: $chain, deny: $deny,
        labels: $labels, urgency: (if $urgency == "" then null else $urgency end)}')"
  # <<<REPLAY:route-request<<<
  _decision="$(curl -fsS --max-time 5 -H "Content-Type: application/json" \
      -d "$_req" "$ROUTER_URL/route" 2>/dev/null)" || _decision=""
  if [ -z "$_decision" ]; then
    echo "→ router: $ROUTER_URL unreachable — static model chain (fail-open, AGENT_ROUTER=$AGENT_ROUTER)"
  else
    _verdict="$(printf '%s' "$_decision" | jq -r '.decision // "?"')"
    _rmodel="$(printf '%s' "$_decision" | jq -r '.model // ""')"
    _rwhy="$(printf '%s' "$_decision" | jq -r '[.reason, .basis, (if .half_open then "half-open" else empty end)] | map(select(. != null and . != "")) | join(",")')"
    echo "→ router(${AGENT_ROUTER}): ${_verdict} ${_rmodel:-—} [${_rwhy}] (static would be: ${MODEL})"
    if [ "$AGENT_ROUTER" = "authoritative" ]; then
      if [ -n "${MODEL_SET:-}" ]; then
        echo "→ router: explicit --model ${MODEL} wins over the routed decision (ADR-096 override rule)"
      elif [ "$_verdict" = "dispatch" ] && [ -n "$_rmodel" ]; then
        MODEL="$_rmodel"; _router_adopted=1
      elif [ "$_verdict" = "defer" ]; then
        # homelab#158: the exit moved BELOW the rail-degrade block — an `or-capacity-down:*` defer is a
        # provider outage, and this launcher has one more rail to try before it gives the round up.
        # Every other defer reason still ends the dispatch here, unchanged, one block down.
        _router_defer=1
        _retry="$(printf '%s' "$_decision" | jq -r '.retry_after_s // "?"')"
      fi
    fi
  fi
fi

# ── homelab#158: an OpenRouter capacity outage DEGRADES to the haiku subscription rail ────────────────
# (Operator directive, 2026-08-08; the reasoning and the doctrine amendment: model-routing.md §M12.)
#
# The evening it comes from: OpenRouter went hard-down for workers (provisioning keys-modify daily
# limit + a $0.17 balance) and the ENTIRE fleet's dispatch deferred for hours, while the
# subscription rail sat at 2/5 semaphore slots on a fresh plan. Deferring is the right answer to
# "this model costs money we do not have" and the WRONG answer to "the provider is down" — the
# second is an infra failure, the class this loop already knows how to survive.
#
# TWO triggers, because there are two ways the launcher can learn it and the fleet runs on both:
#   • the router's TYPED defer — reason `or-capacity-down:*`, which the proxy raises for
#     account-scope capacity ONLY (credit floor / hard-402 / cross-model 429s). A per-model
#     cooldown and a per-KEY budget exhaustion deliberately are not it: a bad model is not a dead
#     provider, and a spent project budget must not spill onto the subscription. Authoritative
#     stacks only — a shadow-mode defer changes nothing by definition.
#   • the launcher's own ACCOUNT-CREDIT read — the FU-088(b) gate's balance, hoisted here so the
#     same fact can DEGRADE instead of only deferring. This is the one that fires for the fleet
#     today (shadow is the default mode). Read ONCE: the gate below reuses this value. Its source
#     is the proxy's `/router-status` since homelab#190, NOT OpenRouter's management-only
#     `/api/v1/credits` — see the probe below for why that mattered.
#
# What it degrades TO is a constant, not a search: `claude/haiku` on the subscription, the model
# the directive names. Harness, env card, credential shape and the FU-088 capacity gate all follow
# from the model id downstream — which is why this sits ABOVE the model_id parse rather than next
# to the gate it pre-empts.
#
# BOUNDS, in the order they matter:
#  1. class=fix only — a tasked `issue-*` ride. Research/adhoc rides keep deferring: human-gated
#     or experimental, and neither is worth scarce subscription headroom.
#  2. semaphore-bounded — the degraded ride IS a claude ride, so the FU-088 latch/utilization/
#     semaphore gate below applies to it unchanged. The reviewer/coordinator safety net keeps its
#     slots, and when the subscription is limited too the ride defers exactly as it does today.
#  3. per-stack opt-out — `subscriptionFallback: false` on the stack row for a stack that should
#     strictly wait instead; `AGENT_SUBSCRIPTION_FALLBACK=0` is the per-run override.
#
# ⚠ The `>>>REPLAY:…>>>` / `<<<REPLAY:…<<<` sentinels below are load-bearing: agents/rail-degrade-replay.sh
# EXTRACTS the block between them and runs it against stubbed probes, so the nine-case table in
# homelab#162 is pinned against the real code rather than a transcription of it. Move the sentinels
# with the block if you move it; don't delete them (the replay fails loudly if a marker goes missing).
# >>>REPLAY:rail-degrade>>>
OR_MIN="${OPENROUTER_MIN_CREDIT:-0.25}"
OR_CREDITS=""; OR_CAPACITY_DOWN=""; RAIL_DEGRADED=""
# Router trigger — AUTHORITATIVE mode only, keyed on `_router_defer`, i.e. exactly the case where
# the routed defer is about to stop this dispatch. In shadow mode a defer changes nothing by
# contract ("consult + log, dispatch unchanged"), so degrading on it would be the launcher quietly
# promoting shadow to authoritative; the credit probe below is what covers shadow stacks.
if [ -n "${_router_defer:-}" ]; then
  case "${_rwhy:-}" in *or-capacity-down*) OR_CAPACITY_DOWN="router:${_rwhy}";; esac
fi
# Is this ride ALREADY on the subscription rail? Then there is nothing to degrade to, and — leg 1
# — no OpenRouter state may stand between it and its dispatch, so it does not even probe: a
# claudeTier ride's relationship to the OpenRouter key is "fallback I am not using", full stop.
_sub_rail_ride=""
# opencode-go/* joins the arm (2026-08-17, the platform Go-flash dogfood): a Go ride buys nothing
# from OpenRouter either — no credit probe, no #158 degrade (its own capacity gate is the
# /opencode-limit latch at the FU-088 gate below).
case "${HARNESS}:${MODEL}" in claude:*|*:claude/*|*:opencode-go/*) _sub_rail_ride=1;; esac
_or_probe_url="${AGENT_OPENROUTER_PROXY-http://openrouter-proxy.agent-egress.svc.cluster.local:8080}"
if [ -z "$_sub_rail_ride" ] && [ -z "$OR_CAPACITY_DOWN" ] \
   && [ -n "$_or_probe_url" ] && [ "${AGENT_CREDIT_GATE:-1}" = "1" ]; then
  # homelab#190: the balance comes from the PROXY's own capacity view, not from OpenRouter.
  # This probe used to be `GET /api/v1/credits` with the pod's opaque `ref:` — an endpoint
  # OpenRouter serves only to a MANAGEMENT key, so it 403'd on every dispatch, `OR_CREDITS` was
  # empty every time, and both consumers below (the #158 degrade and the FU-088(b) gate) were
  # dead while looking healthy. `/router-status` is unauthenticated, ClusterIP-local, on the same
  # host:port this already curled, and its `openrouter_capacity.credit_usd` is the value the
  # proxy itself gates on — sourced from the openrouter-operator's `openrouter_account_credit_usd`
  # gauge (homelab#180). One owner for account-scope facts, consumed operator→proxy→launcher;
  # parsing the operator gauge here instead would put a second, independently-drifting consumer
  # on the dispatch path and duplicate the NaN/staleness handling in awk.
  _or_status="$(curl -fsS --max-time 10 "$_or_probe_url/router-status" 2>/dev/null)" || _or_status=""
  # homelab#194: the proxy's LATCHED capacity bit, read out of the payload ALREADY IN HAND. No
  # second curl, deliberately — a separate call could observe a different latch state than the
  # balance it is being weighed against. This is the leg the 2026-08-08 outage needed: the fleet
  # was RPD-starved with a HEALTHY, topped-up balance, so the credit read below would not have
  # degraded anything. `/route`'s typed defer already carries all three legs, but it is
  # authoritative-mode only, and every OpenRouter-dispatching stack today runs SHADOW — for them
  # this is the only path to the hard-402 and cross-model-429 legs.
  # ⚠ Key on the BOOLEAN `.down`, NEVER on `.reason != null`. The proxy evaluates the hold when it
  # serves the payload (`"down": or_cap["until"] > now`) but emits `reason` unconditionally, and
  # only an early 2xx un-latch ever clears it — so after the first 429 the account takes, `reason`
  # stays a stale non-null string sitting next to `down:false, remaining_s:0`, and a reason-keyed
  # read would degrade the whole fleet permanently. That server-side expiry is also the answer to
  # "should an expired-but-set latch degrade?": there IS no expired-but-set state visible here, so
  # there is no launcher-side freshness bound to invent for it. `remaining_s` is a diagnostic for
  # the lines below, not an input to the verdict — unlike the credit leg, whose HELD value really
  # can be stale and so is judged against the proxy's own `credit_max_age_s`.
  _or_latch_read="$(printf '%s' "$_or_status" | jq -r '
    .openrouter_capacity as $c
    | if ($c | type) != "object" then "unknown"
      elif ($c.down == true)
        then "down:\($c.reason // "unnamed")\(if ($c.remaining_s | type) == "number"
                                              then " (proxy latch, \($c.remaining_s)s left)" else "" end)"
      elif ($c.down == false) then "up"
      else "unknown" end' 2>/dev/null)" || _or_latch_read=""
  # The latch OUTRANKS the credit read, and is set first so the credit trigger below cannot
  # overwrite it. They are not peers: `.down` is an account-scope VERDICT the owner has already
  # reached (its own floor, a hard 402, or 429s from ≥2 models), while the balance is an INPUT
  # this launcher applies its own policy to — and one that can be independently unusable. So a
  # latched account degrades even on a perfectly healthy balance, which is exactly the outage
  # shape above. The reason is carried through so a ride's log and a reviewer can tell
  # `capacity:rpd` from `credit:$0.17<$0.25`, as the routed leg already does.
  case "$_or_latch_read" in
    down:*) OR_CAPACITY_DOWN="capacity:${_or_latch_read#down:}";;
  esac
  # jq returns the whole verdict so the shell never RE-DERIVES the proxy's freshness bound — it
  # honours it. `credit_usd` is `null` until the first usable poll, and it is HELD across later
  # poll failures (the proxy only overwrites it on success), so age is the thing that makes a
  # number unusable: compare `credit_age_s` against the proxy's OWN `credit_max_age_s`. Anything
  # that is not a fresh number is "no balance", never a low one.
  _or_credit_read="$(printf '%s' "$_or_status" | jq -r '
    .openrouter_capacity as $c
    | if ($c | type) != "object"                then "no-capacity-block"
      elif ($c.credit_usd   | type) != "number" then "no-balance (the proxy holds none — leg never polled, or dead)"
      elif ($c.credit_age_s | type) != "number" then "no-credit-age"
      elif ($c.credit_max_age_s | type) == "number" and $c.credit_age_s > $c.credit_max_age_s
        then "stale: \($c.credit_age_s)s old, past the \($c.credit_max_age_s)s bound the proxy advertises"
      else "ok:\($c.credit_usd)" end' 2>/dev/null)" || _or_credit_read=""
  case "$_or_credit_read" in
    ok:*) OR_CREDITS="${_or_credit_read#ok:}";;
    # FAIL-OPEN, VISIBLY (homelab#190). An unavailable balance must never stop a dispatch — the
    # availability of the gate is worth less than the gate (FU-104) — but the silence is what
    # made this bug survive: an empty read looked exactly like a healthy account. One line, on
    # the dispatch path, naming the URL, so a NetworkPolicy gap in some other namespace is
    # diagnosable from the ride's own log instead of from an archived tracker entry.
    # homelab#194: there are now TWO account-scope facts behind this one URL, and the line must
    # say which of them it is missing. An unreachable or unparseable payload loses the latch bit
    # as well as the balance — reporting only "no balance" there would be the same silence-shaped
    # bug #190 fixed, one level up: a ride would read as "gate unavailable" when in truth the
    # launcher was also blind to whether the account was latched down.
    *) case "$_or_latch_read" in
         up)     _or_latch_note="the capacity latch bit WAS readable and is not down, so the balance is the only fact missing";;
         down:*) _or_latch_note="the capacity latch bit WAS readable and IS down [${OR_CAPACITY_DOWN}] — the homelab#158 capacity trigger fired on it regardless";;
         *)      _or_latch_note="the capacity latch bit (.openrouter_capacity.down) is MISSING TOO — BOTH account-scope facts are unknown here, so neither the credit trigger nor the homelab#194 capacity trigger can fire";;
       esac
       echo "→ FU-088(b) FAIL-OPEN: no usable OpenRouter balance from ${_or_probe_url}/router-status [${_or_credit_read:-unreachable or unparseable}] — dispatching WITHOUT the \$${OR_MIN} account-credit floor (and without the homelab#158 credit trigger); ${_or_latch_note}. Check the proxy and its credit leg (.openrouter_capacity.credit_poll_failures).";;
  esac
  # The floor stays the LAUNCHER's (`OPENROUTER_MIN_CREDIT`, default $0.25): the proxy owns the
  # account-scope FACT, this gate owns the dispatch POLICY, and it must stay overridable per run
  # without touching the proxy's env. Both defaults are $0.25 and the proxy publishes its own as
  # `.openrouter_capacity.min_credit_usd` — if they ever diverge deliberately, that is the field
  # to read, not this constant.
  # `-z "$OR_CAPACITY_DOWN"`: the latch above already spoke for the account (homelab#194). Both
  # legs would degrade to the same place, but the TRIGGER STRING is the record of why, and the
  # owner's verdict is the truer answer than a number this launcher thresholded itself.
  if [ -z "$OR_CAPACITY_DOWN" ] && [ -n "$OR_CREDITS" ] && awk -v c="$OR_CREDITS" -v m="$OR_MIN" 'BEGIN { exit !(c < m) }'; then
    OR_CAPACITY_DOWN="credit:\$${OR_CREDITS}<\$${OR_MIN}"
  fi
fi
if [ -n "$OR_CAPACITY_DOWN" ] && [ -n "$_sub_rail_ride" ]; then
  # A subscription ride that drew an or-capacity-down defer is blocked by something else (the
  # router types the FIRST rail's capacity reason, and for a claude chain the OpenRouter one is
  # noise). Degrading a claude ride TO claude would only convert an escalation into a silent
  # deferral — leave the verdict exactly as the router meant it.
  echo "→ homelab#158: OpenRouter capacity down [${OR_CAPACITY_DOWN}] but this ride is already on the subscription rail — nothing to degrade to; the routed verdict stands."
elif [ -n "$OR_CAPACITY_DOWN" ]; then
  # ⚠ NOT `.subscriptionFallback // true`: jq's `//` fires on FALSE as well as null, so the
  # alternative swallows the very value the knob exists to express and the opt-out silently never
  # works. Same family as the `${_srow:-{}}` trap above — caught by the replay, not by review.
  # An unreadable row falls back to the fleet default (degrade): this is an opt-OUT knob, and a
  # stack that means "strictly wait" says so explicitly.
  _fb_ok="$(printf '%s' "$_srow" | jq -r 'if .subscriptionFallback == false then "" else "1" end' 2>/dev/null)" || _fb_ok="1"
  _fb_why="subscriptionFallback:false on the stack row"
  if [ "${AGENT_SUBSCRIPTION_FALLBACK:-1}" != "1" ]; then _fb_ok=""; _fb_why="AGENT_SUBSCRIPTION_FALLBACK=0"; fi
  _fb_model="${AGENT_SUBSCRIPTION_FALLBACK_MODEL:-claude/haiku}"
  # The claim's modelDeny binds here too. A degrade is still a MODEL CHOICE, and an outage is not a
  # reason to hand a stack a model it has explicitly refused — /route filters deny before anything
  # else (router.py), and a launcher-side fallback that skipped it would be a way around the claim.
  if [ -n "$_fb_ok" ] \
     && [ "$(printf '%s' "$_srow" | jq -r --arg m "$_fb_model" '[(.modelDeny // [])[] | select(. == $m)] | length' 2>/dev/null || echo 0)" != "0" ]; then
    _fb_ok=""; _fb_why="${_fb_model} is in this stack's modelDeny — the claim wins over the fallback"
  fi
  case "${TASK:-}" in
    issue-[0-9]*)
      if [ -n "$_fb_ok" ]; then
        RAIL_DEGRADED="$_fb_model"
        echo "→ homelab#158 RAIL DEGRADE: OpenRouter capacity down [${OR_CAPACITY_DOWN}] — dispatching ${RAIL_DEGRADED} on the subscription instead of deferring (openrouter pick was: ${MODEL}). rail=subscription-fallback; the FU-088 gate still bounds this ride."
        # Preserve the original attempted model for strike attribution before the degrade
        STRUCK_MODEL_ORIG="$MODEL"
        MODEL="$RAIL_DEGRADED"
        # The explicit --harness the dispatcher passed selects WITHIN the OpenRouter rail, and that
        # rail is down — so it cannot bind here. Clearing the flag lets the harness follow the model
        # through the one parser (model_id.py) exactly as an undecorated claude/* dispatch does.
        HARNESS_SET=""
        _router_defer=""
      else
        # ⚠ Says what THIS block decided, not what the ride will do. Before homelab#194 the only
        # shadow trigger was the credit floor, so "defers" was always true here — the FU-088(b)
        # gate below was certain to stop a ride whose balance had just fired the trigger. A
        # `capacity:*` latch has no such guarantee: the balance can be perfectly healthy while the
        # account is 429-latched, and an opted-out stack then dispatches onto the latched rail.
        # That is the opt-out working as written (it means "do not MOVE me", not "block me"), and
        # the ride's own 429s are what it has chosen to wait on — but the line must not promise a
        # deferral it does not perform.
        echo "→ homelab#158: OpenRouter capacity down [${OR_CAPACITY_DOWN}] but the subscription fallback is OFF here (${_fb_why}) — strict wait: no degrade, and this ride is left to the gates below exactly as before the trigger existed."
      fi;;
    *)
      echo "→ homelab#158: OpenRouter capacity down [${OR_CAPACITY_DOWN}] — no degrade for a non-fix ride (task=${TASK:-adhoc}); the existing gates decide this one.";;
  esac
fi
if [ -n "${_router_defer:-}" ]; then
  echo "→ router: DEFER (${_rwhy}) retry_after=${_retry:-?}s — not dispatching. chain-exhausted means every model is struck/denied for this task: escalate." >&2
  exit 1
fi
# <<<REPLAY:rail-degrade<<<
# >>>REPLAY:chainless-guard>>>
# Chainless-stack guard (ADR-096 P5 pilot, 2026-08-03): a stack row WITHOUT workerModel has no
# static chain, and the hardcoded MODEL default would be a silent lie. Only an authoritative
# routed dispatch (or an explicit --model) may proceed — shadow/off/unreachable-router all
# refuse LOUDLY (rule #6: the router fail-open must never fail INTO a made-up model here).
# ⚠ NOT `${_srow:-{}}`: bash parses that as ${_srow:-{} plus a literal }, so a NON-empty row came
# out as `<json>}` and every jq here printed "parse error: Unmatched '}'" (found 2026-08-04). The
# values were still right — jq streams the leading value before choking on the trailing brace — so
# it read as harmless noise while actually leaving this guard one jq-behaviour change from
# silently inverting. _srow is normalized at its assignment; use it plainly.
# homelab#158: a rail-degraded dispatch satisfies this guard. The fallback is not the static default
# leaking through a fail-open — it is a named constant chosen by an operator directive in response
# to a MEASURED provider outage, which is the distinction rule #6 is actually about.
if [ -z "${MODEL_SET:-}" ] && [ -z "${RAIL_DEGRADED:-}" ] \
   && [ "$(printf '%s' "$_srow" | jq -r '.name // ""')" != "" ] \
   && [ "$(printf '%s' "$_srow" | jq -r '.workerModel // ""')" = "" ]; then
  if [ "$AGENT_ROUTER" != "authoritative" ] || [ "${_verdict:-}" != "dispatch" ] || [ -z "${_rmodel:-}" ]; then
    echo "FATAL: chainless stack (no workerModel in the claim) needs routerMode=authoritative + a routed dispatch — got AGENT_ROUTER=${AGENT_ROUTER}, verdict=${_verdict:-none}. Refusing the static default model." >&2
    exit 1
  fi
fi
# <<<REPLAY:chainless-guard<<<

# workerModel notation from the AgentStack claim (first used by oracle, oracle-iac#8): the string
# encodes the RAIL and sometimes the HARNESS by prefix, because the XRD carries no harness field
# (FU-066's fixer.claudeTier is the eventual shape). FU-127: the rules live in ONE place —
# agents/model_id.py — instead of being re-derived here, in research-fanout.sh, in
# estimate_budget.py and in the proxy. This keeps the same self-executing behaviour: the dispatcher
# passes --model straight from stacks.json and gets the right harness + a bare model id, and an
# explicit --harness still wins.
# >>>REPLAY:struck-model-init>>>
# Track the originally attempted model for strike attribution (FU-062 / issue#660 / #674): when we
# degrade to a fallback, MODEL is rewritten but STRUCK_MODEL remains at the original chain entry,
# so the strike comment records which model was attempted and failed (not which fallback was used).
# The chain entry must match what the coordinator sees in the claim (before model-id.py resolution
# strips prefixes like claude/* → haiku). Capture here BEFORE resolution.
# If degrade at :420 already set it, use that; otherwise use current MODEL.
STRUCK_MODEL="${STRUCK_MODEL_ORIG:-$MODEL}"
# <<<REPLAY:struck-model-init<<<
# >>>REPLAY:model-id-resolution>>>
# FU-127: consume the structured carrier when the router provides it — no re-parse needed.
# Falls back to the model_id.py parser when absent (mixed-deploy window: proxy and launcher
# deploy independently). Only consumed when the router's decision was actually adopted into
# MODEL (_router_adopted set at the MODEL="$_rmodel" line, which only fires under
# AGENT_ROUTER=authoritative + verdict=dispatch + _rmodel non-empty). Shadow/off/explicit
# --model paths take the fallback parse.
if [ -n "${_router_adopted:-}" ]; then
  _resolved="$(printf '%s' "${_decision:-}" | jq -r '.resolved // empty' 2>/dev/null)"
  if [ -n "$_resolved" ] && [ "$_resolved" != "null" ]; then
    MODEL_RAIL="$(printf '%s' "$_resolved" | jq -r '.rail // ""')"
    MODEL_HARNESS="$(printf '%s' "$_resolved" | jq -r '.harness // ""')"
    MODEL_MODEL="$(printf '%s' "$_resolved" | jq -r '.model // ""')"
    # Guard: if resolved.model is empty, fall back to the model_id.py parse
    # rather than assigning an empty MODEL (mixed-deploy window).
    if [ -z "$MODEL_MODEL" ]; then
      eval "$(python3 "$HERE/model_id.py" --shell "$MODEL")"
    fi
  else
    eval "$(python3 "$HERE/model_id.py" --shell "$MODEL")"
  fi
else
  eval "$(python3 "$HERE/model_id.py" --shell "$MODEL")"
fi
[ -z "$MODEL_HARNESS" ] || [ -n "${HARNESS_SET:-}" ] || HARNESS="$MODEL_HARNESS"
OPENCODE_MODEL="$MODEL"  # Full provider-prefixed id for opencode CLI (-m must receive openrouter/<vendor>/<model>)
MODEL="$MODEL_MODEL"
# <<<REPLAY:model-id-resolution<<<

# Without an explicit --task (interactive/ad-hoc runs) the transcript still lands somewhere findable.
TASK="${TASK:-adhoc-$(date -u +%Y%m%dT%H%M%SZ)}"

# Context-repos PILOT (docs/spikes/context-repos.md, 2026-08-04): circles rides get read-only
# reference clones by default — measurement is whether transcripts ever show /work/context reads.
# Circles-ONLY by design; promotion to other stacks = a claim knob (fixer.contextRepos) + XRD
# field + an ADR, gated on that measurement. Explicit --context-repo always wins.
if [ -z "$CONTEXT_REPOS" ] && [ "$PROJECT" = "circles" ]; then
  CONTEXT_REPOS="https://github.com/teststuffstash/circles-iac.git https://github.com/teststuffstash/homelab.git"
fi

# ── --recipe: LAUNCHER-OWNED claude run command (ADR-094 constraints-as-code) ──
# The coordinator brief used to instruct the item session to hand-assemble the base64-carry
# claude invocation — an LLM memory test that failed live 2026-07-21 (#55 r1: the README's
# literal `'$B64'` template shipped un-substituted, a haiku session ran on a garbage system
# prompt until the FU-069 breaker caught it). Now the dispatcher passes the recipe PATH (it has
# the repo clone) and THIS script builds the command deterministically: the whole recipe file is
# base64-carried as the system prompt (goose-format YAML — the model reads it fine, and no
# YAML-parsing dependency exists jail/pod-side), the issue number comes from --task.
if [ -n "${RECIPE:-}" ]; then
  # --recipe is now the launcher-owned path for BOTH harnesses (FU-114: was claude-only; goose
  # used a dispatcher-assembled `--run "goose run --recipe …"`, the ADR-094 gap the #55 incident
  # first exposed on goose). The RUN_CMD is BUILT below, after the environment knobs (--docker,
  # egress) are known — so the platform environment card (FU-114 L1) can be composed from them and
  # injected into the recipe. Here we only VALIDATE and derive launcher-owned flags.
  case "$HARNESS" in claude|goose|opencode) ;; *) echo "FATAL: --recipe supports the claude/goose/opencode harnesses (got '${HARNESS}')" >&2; exit 2;; esac
  [ -f "$RECIPE" ] || { echo "FATAL: --recipe ${RECIPE} not found (pass the dispatcher-side clone's path)" >&2; exit 2; }
  [ -z "$RUN_CMD" ] || { echo "--recipe and --run are mutually exclusive" >&2; exit 2; }
  # Task key → issue number. `issue-<N>` is the fixer shape; `research-<N>-<slug>` is the
  # FU-126 fan-out shape (per-model adhoc keys — no strike bookkeeping, no issue-* atomic gate;
  # the finalize strike path already matches issue-* only).
  case "$TASK" in
    issue-*)    ISSUE_N="${TASK#issue-}";;
    research-*) ISSUE_N="${TASK#research-}"; ISSUE_N="${ISSUE_N%%-*}";;
    *)          ISSUE_N="";;
  esac
  case "$ISSUE_N" in ''|*[!0-9]*) echo "FATAL: --recipe needs --task issue-<N> or research-<N>-<slug> (got '${TASK}')" >&2; exit 2;; esac
  # A research recipe's PR is human-gated BY DESIGN (FU-105) — derive --no-arm from the recipe
  # name so the un-armed gate is launcher-owned, never a dispatcher memory test (ADR-094; the
  # first live ride was armed by finalize right past the recipe's "do not arm").
  case "$(basename "$RECIPE")" in
    research*) NO_ARM=1; RESEARCH_RECIPE=1; echo "→ --no-arm derived from research recipe (human-gated PR)";;
  esac
fi

NS="$PROJECT"

# --docker is STACK POLICY (the claim's fixer.docker), not a dispatcher memory test: derive it
# from the AgentStack claim when the caller didn't pass it (found live 2026-07-18: an item
# session dispatched a docker-repo worker without --docker; the duplicate-dispatch dance cost a
# pod). Explicit --docker always wins; a failed probe leaves it unset and WARNS (the CI gate
# catches a wrong-mode ride — degrade loudly, never guess).
if command -v "$KUBECTL" >/dev/null 2>&1; then
  # The claims read runs even when --docker was explicit (homelab#990): the egress knobs it
  # yields drive the env card AND the enforce-default harness guard below, and both must see
  # the truth on every dispatch path — not only the docker-auto-derive one.
  if claims_json="$("$KUBECTL" $KUBE get agentstacks.platform.teststuff.net -o json 2>/dev/null)"; then
    if [ -z "$DOCKER" ] && [ "$(printf '%s' "$claims_json" | jq -r --arg p "$PROJECT" \
        '[.items[].spec.repos[] | select(.name == $p and (.fixer.docker == true))] | length' 2>/dev/null)" -gt 0 ] 2>/dev/null; then
      DOCKER=1
      echo "→ --docker derived from the AgentStack claim (fixer.docker=true for ${PROJECT})"
    fi
    # FU-114 L1: capture the egress knobs from the SAME claim read for the environment card (below).
    EGRESS_ENFORCE="$(printf '%s' "$claims_json" | jq -r --arg p "$PROJECT" '[.items[].spec.repos[]|select(.name==$p)|.fixer.egress.enforce]|map(select(.!=null))|first // empty' 2>/dev/null)"
    EGRESS_PROFILE="$(printf '%s' "$claims_json" | jq -r --arg p "$PROJECT" '[.items[].spec.repos[]|select(.name==$p)|.fixer.egress.profile]|map(select(.!=null))|first // empty' 2>/dev/null)"
    # MCP knob from the SAME claim read (stack-wide spec.mcp, #1041). The knob is at the
    # AgentStack level, not per-repo — find the stack whose repos include this project.
    # Absent = no MCP attached; the env card and the harness attach flag are gated on this being non-empty.
    MCP_ENDPOINT="$(printf '%s' "$claims_json" | jq -r --arg p "$PROJECT" '[.items[] | select(any(.spec.repos[]; .name == $p)) | .spec.mcp.endpoint] | first // empty' 2>/dev/null)"
    MCP_TOOLS="$(printf '%s' "$claims_json" | jq -rc --arg p "$PROJECT" '[.items[] | select(any(.spec.repos[]; .name == $p)) | .spec.mcp.tools] | first // empty' 2>/dev/null)"
  else
    echo "WARN: agentstacks probe failed — cannot derive --docker or the egress knobs; pass --docker explicitly for docker-gated repos" >&2
  fi
fi
# >>>REPLAY:harness-enforce-default>>>
# homelab#990 DURABLE WORKAROUND (operator, 2026-08-26): opencode's SDK-init fetches
# (models.opencode.ai / registry.npmjs.org — no kill knob on the pinned build, the L1812 block)
# carry NO timeout, and under an ENFORCED egress the CNP deny is a silent SYN black-hole — the
# ride wedges pre-LLM and sleeps to the 4h deadline (first chainless oracle ride, issue-272-r1,
# 2026-08-26 ×2). So an enforced-egress ride never takes opencode BY DEFAULT: goose rides the
# slot. An explicit --harness opencode still wins (operator override), and a model-derived
# harness (claude rails) is untouched — this guard fires only on the baked default.
# Delete this block when #990's fail-fast lands.
if [ "${EGRESS_ENFORCE:-}" = "true" ] && [ "$HARNESS" = "opencode" ] && [ -z "${HARNESS_SET:-}" ]; then
  echo "→ homelab#990 workaround: enforced egress + default harness → goose (opencode wedges on un-suppressible SDK-init fetches under enforcement)"
  HARNESS="goose"
fi
# <<<REPLAY:harness-enforce-default<<<
# ── FU-114 L1: the platform ENVIRONMENT CARD (docs/agents/fixer-context.md) ──────────────────
# Composed from the SAME knobs the launcher just used to BUILD this ride (--docker, egress), so it
# is accurate by construction — never the stale "no-real-data sandbox" framing that primed the #48
# ride to assert "I can't run k3d" without ever probing. It states the capability AND the verify
# command, and is injected into the recipe's instructions at the {{PLATFORM_ENV_CARD}} marker
# (deterministic awk-insert, no YAML dependency) so the worker cannot skip reading it.
# >>>REPLAY:render_env_card>>>
render_env_card() {
  local mdio="${AGENT_MIRROR_DOCKER_IO-http://192.168.40.20}" mghcr="${AGENT_MIRROR_GHCR-http://192.168.40.21}" mmcr="${AGENT_MIRROR_MCR-http://192.168.40.31}" ncache="${AGENT_NIX_CACHE_URL-http://192.168.40.23}" dsearch="${AGENT_DEVBOX_SEARCH_HOST-http://192.168.40.27}"
  # ═══ MAINTAINER NOTE — read before editing (this comment is NOT sent to the agent) ═══
  # Everything printf'd below is injected VERBATIM into the stack agent's prompt. Keep that text
  # MINIMAL and stack-agnostic: the rule + the value it needs to ACT, nothing else. All homelab-
  # internal context — the WHY, issue links, FU/ADR ids, incident dates, cross-stack pointers —
  # stays in `#` comments like these and is NOT sent. Litmus: a link/id/"we learned this on <date>"
  # is a COMMENT; something that changes what the agent DOES is CARD TEXT.
  # UNIVERSAL ground rules live in agents/ground-rules.md — ONE authored source (FU-117, S4
  # stint #762/#763; this card used to duplicate them from homelab/CLAUDE.md). The file is
  # injected VERBATIM for every ride on every harness (a worker clones only its project repo and
  # goose loads no CLAUDE.md, so the card is the only delivery channel). Grow universal rules
  # THERE; this function keeps only DYNAMIC per-ride facts. A missing file degrades LOUDLY —
  # never silently (the FU-125 class); the replay pin is env-card-ground-rules/missing.
  printf '%s\n\n' "## Platform environment (generated by the launcher from THIS ride's AgentStack claim — ground truth. VERIFY with the commands rather than assuming; the generic recipe doesn't know your ride's capabilities, this card does.)"

  # -r AND -s: a present-but-EMPTY file (truncated checkout, bad merge) must degrade as loudly
  # as a missing one — same FU-125 class, sibling case (PR#768 review). $HERE is the launcher's
  # own canonicalized dir (top of file); replays override via GROUND_RULES_FILE.
  local grf="${GROUND_RULES_FILE:-$HERE/ground-rules.md}"
  if [ -r "$grf" ] && [ -s "$grf" ]; then
    cat "$grf"
  else
    printf '%s\n' "- WARN: the platform ground-rules block is unavailable this ride (launcher-side gap, not yours) — follow the recipe conservatively."
    echo "WARN: ground-rules file missing/empty/unreadable: $grf — env card degraded (FU-117)" >&2
  fi

  # WHY: registry mirrors = FU-073/ADR-091 (.40.20/.21); nix-cache = ADR-083 (.40.23); devbox-search
  # = FU-118b (.40.27). The agent needs only the values + that a miss HANGS under the egress CNP.
  # WHY: the parenthetical must match the ACTUAL enforcement state — the FU-126 audit caught this
  # bullet asserting "egress-blocked / a miss HANGS" while the egress bullet below said "monitored,
  # not blocked" in the same card (deepseek arm flagged the contradiction).
  # WHY: the scheme-strip caveat = sleep-tracking PR#133 / homelab#1023 — sleep's
  # scripts/test-integration.sh:121 is the worked example. Card text stays stack-agnostic per the
  # maintainer note above.
  local pkg_why
  if [ "${EGRESS_ENFORCE:-}" = "true" ]; then
    pkg_why="upstream is egress-blocked — a miss HANGS, it does not error"
  else
    pkg_why="upstream is reachable today (egress monitor mode) but WILL be blocked at enforcement — use the proxies anyway so the ride stays reproducible"
  fi
  printf '%s\n' "- **Package proxies (${pkg_why}):** \`devbox install\` → \`\$NIX_CACHE_URL\` (${ncache}, automatic); \`devbox add\` resolves via \`\$DEVBOX_SEARCH_HOST\` (${dsearch}, automatic — no WAN needed); container images → docker.io=\`\$REGISTRY_MIRROR_DOCKER_IO\` (${mdio}), ghcr.io=\`\$REGISTRY_MIRROR_GHCR\` (${mghcr}), mcr.microsoft.com=\`\$REGISTRY_MIRROR_MCR\` (${mmcr}), **HTTP-only**; python → pip/uv against pypi.org + files.pythonhosted.org (open on the python egress profile). **Pod-only caveat:** these vars exist ONLY inside agent pods; a repo script that consumes them MUST supply a default (\`\${REGISTRY_MIRROR_DOCKER_IO:-${mdio}}\`, \`\${REGISTRY_MIRROR_GHCR:-${mghcr}}\`, \`\${REGISTRY_MIRROR_MCR:-${mmcr}}\`), because the same script runs in CI/dev environments without them. **Scheme caveat:** the values carry \`http://\` (correct for containerd/k3d \`endpoint =\` config), but a bare image ref cannot carry a scheme — use \`\${VAR#*://}\` to strip it."

  # WHY: docs/spikes/context-repos.md pilot (circles-only today). Read-only reference clones; the
  # spike's measurement is whether transcripts ever show /work/context reads, so the card ADVERTISES
  # and the recipes stay silent (capability truth lives here — the FU-126 folklore rule). Without
  # the pilot the ride clones ONLY /work/repo and service facts are the ISSUE AUTHOR's job to put
  # in the issue — that responsibility split IS the FU-117 role×context question, unresolved.
  if [ -n "${CONTEXT_REPOS:-}" ]; then
    local ctx_names="" _cu
    for _cu in $CONTEXT_REPOS; do ctx_names="${ctx_names:+$ctx_names, }$(basename "$_cu" .git)"; done
    printf '%s\n' "- **Context repos:** read-only reference clones at \`/work/context/\` (${ctx_names}) — grep them freely (SERVICES.md lives in homelab; deploy pins in circles-iac). REFERENCE only: never commit/push/build there, and your task's own facts still come from the issue. A \`WARN: context clone failed\` at the top of the run log means that repo is NOT mounted — work without it, don't fetch it yourself."
  fi
  if [ -n "$DOCKER" ]; then
    # WHY: docker-client-in-devbox.json = FU-119; the kind-node-hangs-on-missing-mirror trap =
    # sleep-tracking#67; the reference kind_mirror() impl is oracle-fleet scripts/e2e-kind.sh (and
    # each docker stack's own scripts/test-integration.sh after #71). Card keeps the actionable HOW.
    printf '%s\n' "- **Docker: YES.** A real daemon is live at \`\$DOCKER_HOST\` (\`docker info\` succeeds). The \`docker\`/\`kind\` CLIs come from your \`devbox.json\` (\`docker-client\`+\`kind\`) — if \`docker\` is 'command not found', add \`docker-client\` there (never download). Run \`kind\`/\`k3d\` here for e2e gates. **CRITICAL:** a kind/k3d NODE's own image pulls go to docker.io/ghcr.io and are egress-DENIED → the node never goes Ready and \`create\` times out (looks like 'docker is broken' — it's the MISSING MIRROR). Point the node's containerd at the mirrors BEFORE it starts — kind: \`docker exec <node> tee /etc/containerd/certs.d/<reg>/hosts.toml\` pointing at \`\$REGISTRY_MIRROR_DOCKER_IO\`/\`\$REGISTRY_MIRROR_GHCR\`; k3d: \`--registry-config\`."
  else
    printf '%s\n' "- **Docker: NO.** No daemon in this ride — docker-backed e2e gates run in GitHub CI, not here; don't try to start clusters."
  fi

  if [ "${EGRESS_ENFORCE:-}" = "true" ]; then
    printf '%s\n' "- **Egress: ENFORCED** (profile: ${EGRESS_PROFILE:-baseline}). Only allowlisted hosts are reachable; a miss HANGS. Use the mirrors above; don't reach upstream package/registry hosts directly."
  else
    printf '%s\n' "- **Egress: monitored, not blocked** — calls work; destinations are logged for the allowlist harvest."
  fi

  # WHY: the circles FU-126 A/B surfaced that recipes carried egress FOLKLORE ("WebFetch will
  # mostly be blocked") while the actual truth was per-HARNESS: claude has server-side WebSearch,
  # goose has no web tool at all. Capability truth belongs HERE, not in recipe text (operator,
  # 2026-08-03). FU-117 sighting noted in roles.md §Context delivery.
  # FU-134 ruling (2026-08-04): ADVERTISING the difference was not enough — "is this a known
  # upstream bug?" must not be answerable-or-not by which binary got spawned. The proxy's /search
  # endpoint is the platform floor (openrouter-proxy.py), so the card now states a GUARANTEE for
  # every harness. The in-harness tool is still named first where it exists: fewer hops, no spend.
  if [ "$HARNESS" = "claude" ]; then
    printf '%s\n' "- **Web research: WebSearch available** (server-side — runs OUTSIDE this pod, unaffected by the egress posture). WebFetch fetches FROM this pod and rides the egress posture above; if it fails, use WebSearch and mark snippet-level provenance."
  else
    printf '%s\n' "- **Web research: YES, via the platform endpoint** (this harness has no built-in web tool): \`curl -sS -X POST \${AGENT_SEARCH_URL}\` with \`-H \"Authorization: Bearer \$OPENROUTER_API_KEY\" -H 'Content-Type: application/json' -d '{\"q\":\"<your question>\"}'\` → JSON \`{answer, citations:[{url,title}]}\`. The search runs server-side, so it works under the egress posture above; it spends a few cents of THIS ride's budget per call, so ask few, real questions. Cite the URLs it returns, and if it returns no citations say the claim is unverified rather than filling the gap from memory."
  fi

  printf '%s\n' "- **Round ${ROUND}** of ${ROUNDS_MAX:-3} (a CHANGES_REQUESTED review or CI-red-on-your-change costs a round; infra failures don't). Land one tight, correct change."
  # WHY: the branch PREFIX is recipe-owned (fix/ fixer, research/ researcher) — the FU-126 audit
  # caught this card claiming fix/-only while a research ride legitimately pushed research/*
  # (a compliance-minded model could deadlock on the contradiction). Keyed on the RECIPE, not on
  # NO_ARM: since 2026-08-05 a `Base:` declaration also sets NO_ARM on a fix/ ride, and keying the
  # prefix off NO_ARM would have told that ride to push research/ — the same contradiction again.
  if [ -n "${RESEARCH_RECIPE:-}" ]; then
    printf '%s\n' "- **Write scope:** you can only push a \`research/\`-prefixed branch (the recipe's branch rule) and open a PR — master is unreachable (branch protection + token scope). A real boundary, not something to route around."
  else
    printf '%s\n' "- **Write scope:** you can only push a \`fix/\`-prefixed branch and open a PR — master is unreachable (branch protection + token scope). A real boundary, not something to route around."
  fi

  # WHY: a declared `Base:` (issue body) means the work is STACKED on an unmerged branch. Both
  # halves must be said or neither helps: the clone is already on that branch (launcher), but
  # `gh pr create` defaults to the repo's DEFAULT branch, and a PR opened against master would
  # show the entire base branch plus this change — a diff that cannot mean what it appears to
  # mean, reviewed by a reflex that would then arm it.
  if [ "$BASE_REF" != "master" ]; then
    printf '%s\n' "- **Base branch: \`${BASE_REF}\`, NOT master.** Your clone is already on it and your branch forks from it. Open the PR against it explicitly — \`gh pr create --base ${BASE_REF} …\` — or the PR will target master and its diff will include everything in \`${BASE_REF}\` on top of your work. This PR is human-gated: it will NOT auto-merge, which is deliberate."
  fi
  # FU-090 leg (c): the goal this issue serves. BOUNDED — Goal + Acceptance only (see the parse
  # site). Your issue is the contract; this is the reason it exists, and what "done" is measured
  # against when the parent is finally judged.
  if [ -n "${GOAL_CARD:-}" ]; then
    printf '%s\n' "- **This issue is one child of a GOAL.** It was split out so a single ride could finish it — deliver YOUR issue, not the goal. But the goal is what your work is finally judged against, so if finishing your slice would leave the goal's acceptance unreachable, say so in the PR body rather than quietly widening scope (a scope change belongs in a new issue for the owning concern — TRACKS rule 2). The parent, Goal + Acceptance only:"
    printf '%s\n' "$GOAL_CARD" | sed 's/^/  > /'
  fi
  # WHY: homelab#1175 — the launcher pre-fetches the issue + comments via REST and materializes
  # them as /work/issue.md before the harness starts. The env card tells the worker to read the
  # file first instead of making a live `gh issue view` call (which costs tokens and can 403 on
  # the App installation's GraphQL pool). Only emitted for recipe-based runs with an issue task.
  # Gate on TASK matching issue-[0-9]* (same predicate the prefetch block uses), NOT on ISSUE_N
  # alone — ISSUE_N is also set for research-* tasks, which never get /work/issue.md written.
  # Also gate on AGENT_PREFLIGHT: if pre-flight is skipped (AGENT_PREFLIGHT=0), the file is never
  # written while the card would still promise it.
  case "${TASK:-}" in
    issue-[0-9]*)
      if [ "${AGENT_PREFLIGHT:-1}" != "0" ]; then
        printf '%s\n' "- **Issue context:** Your issue + comments were pre-fetched at dispatch: read \`/work/issue.md\` FIRST; a live \`gh issue view\` is optional."
      fi
      ;;
  esac
  # WHY: Rung A evidence (oracle-fleet docs/feedback-rung-a.md, PR #295): organic feedback filing
  # 0/3; with a directed-act line 10/12; instructive voice executes 10/10; harness/model elicitation
  # from tool-description meta 0/10. The session cannot reliably report its own harness and model —
  # the launcher knows both, so the launcher stamps them (L1 provable-not-describable rule).
  # WHY: version skew — production serves the pinned release over the released corpus; a worktree
  # runs HEAD. Name the pin so a prod/worktree behavioral diff is interpretable rather than mysterious.
  # Both lines are gated on the MCP knob being present AND the harness actually attaching the
  # config (no MCP = no feedback tool to direct). All three harnesses (claude, goose, opencode)
  # now attach MCP (#1276), so the card claims the tool is available on any harness with the knob.
  if [ -n "${MCP_ENDPOINT:-}" ]; then
    printf '%s\n' "- **Feedback tool: available** (harness: ${HARNESS}, model: ${MODEL}). File structured feedback using the MCP tool — the harness and model above are stamped by the launcher, not self-reported."
    printf '%s\n' "- **Version skew:** Production serves ${AGENT_BASE_IMAGE##*:} (pinned release); this worktree runs HEAD. If behavior differs from production, the pin is the reference."
  fi
}
# <<<REPLAY:render_env_card<<<

# Build the launcher-owned RUN_CMD from --recipe now that the environment is known (FU-114): render
# the card, splice it into the recipe at the marker, base64-carry the augmented recipe, and wrap the
# harness-specific invocation. Both harnesses read the SAME augmented recipe (goose natively; claude
# as an appended system prompt — it parses the goose YAML fine, agent-runtime#14).
[ -f "$HERE/images.env" ] && . "$HERE/images.env" # pinned agent image versions (no :latest) — sourced before the env card is rendered so ${AGENT_BASE_IMAGE} is available (homelab#1041)
if [ -n "${RECIPE:-}" ]; then
  # FU-114 L3: deterministic task-type recipe selection (docs/agents/fixer-context.md). The
  # dispatcher passes the DEFAULT recipe (.agents/fix.yaml); if the issue carries a `task/<class>`
  # label and a sibling `.agents/<class>.yaml` exists, use THAT — launcher-owned, never LLM-picked
  # (ADR-094). Default is the passed recipe; an unknown class or missing sibling degrades to it loudly.
  if command -v gh >/dev/null 2>&1; then
    # ── `Base:` — the declared base branch (2026-08-05, circles handoff) ────────────────────────
    # Same unbulleted body-line grammar as `Touches:` (ADR-097), read
    # HERE rather than by the dispatcher: the launcher owns dispatch params (ADR-094), and a
    # dispatcher-side flag would be a memory test the coordinator has already failed twice
    # (#55's hand-assembled --run, the first research ride armed past its recipe).
    # ABSENT ⇒ master ⇒ every issue filed to date dispatches exactly as before.
    # Present ⇒ (1) fork + clone from that branch, (2) the card tells the agent to open its PR
    # against it, (3) NEVER arm auto-merge: stacked work on an unmerged base is human-gated by
    # construction — landing it automatically is precisely what the operator is holding back.
    # `--ref` still wins (an explicit operator override beats a declaration).
    ISSUE_BASE="$(gh issue view "$ISSUE_N" --repo "${ORG:-teststuffstash}/${PROJECT}" --json body \
      --jq '.body' 2>/dev/null | sed -n 's/^[Bb]ase:[[:space:]]*//p' | head -1 | tr -d '[:space:]' || true)"
    if [ -n "$ISSUE_BASE" ]; then
      if [ "$BASE_REF" != "master" ]; then
        echo "→ Base: ${ISSUE_BASE} declared on #${ISSUE_N} but --ref ${BASE_REF} was passed — the explicit flag wins"
      else
        BASE_REF="$ISSUE_BASE"
        # ARMING IS TIED TO THE PROTECTED CONVENTION, not to "is this master" (operator ruling
        # 2026-08-05: feature→goal is fine to automate; goal→master stays human).
        # `goal/**` is a goal's INTEGRATION branch and carries the same ruleset as master
        # (tofu/github/repo_rulesets.tf: required-checks + required-approval include
        # refs/heads/goal/**), so an armed child waits for CI + an approving review exactly as a
        # master PR does. ⚠ Any OTHER non-master base stays un-armed on purpose: GitHub's
        # auto-merge waits on branch-protection conditions, so arming into an UNPROTECTED branch
        # merges on open — no CI, no review. Verified live before this flip; do not widen the
        # match to "any non-default base" without protecting that base first.
        case "$BASE_REF" in
          goal/*)
            echo "→ Base: ${BASE_REF} (declared on #${ISSUE_N}) — forking from it, PR opens against it, auto-merge ARMED (protected integration branch)" ;;
          *)
            NO_ARM=1
            echo "→ Base: ${BASE_REF} (declared on #${ISSUE_N}) — forking from it, PR opens against it, auto-merge NOT armed (base is not a protected goal/** branch)" ;;
        esac
      fi
    fi
    # ── GOAL CONTEXT — a child must know the goal it serves (FU-090 leg (c), 2026-08-05) ────────
    # The harvest/decompose plays link children as NATIVE sub-issues, and until now NOTHING read
    # those links back: the lineage rendered in the GitHub UI and meant nothing to the machinery,
    # so a child ride saw only its own slice and the goal was structurally forgotten.
    # BOUNDED ON PURPOSE — the parent's Goal + Acceptance sections ONLY, never its whole body and
    # never the spec tree. Handing a child the entire parent re-imports the context cost that
    # decomposition exists to remove, which is exactly how circles#17 r1 died (read 91
    # requirements, wrote nothing). The child's own Touches:/spec rows carry the detail.
    # Failure is SILENT-SAFE: no parent, or an API that does not answer, dispatches as before.
    #
    # THE GOAL IS AN ANCESTOR, NOT NECESSARILY THE PARENT (homelab#367). This read used to be one
    # hop — `/issues/<n>/parent`, and whatever came back was treated as the goal. Right for a
    # direct child of a decompose; wrong for every post-launch sprout, whose parent is the ADR-102
    # BUCKET: no `Budget:` line ⇒ the gate below read `no-budget` and waved the ride through, and
    # no Goal/Acceptance headings ⇒ the card said "no heading found" and the ride went goal-blind.
    # Both halves came off this one line. The walk is `goal_resolve_ancestor` (agents/goal-budget.sh)
    # — the SAME one coordinator-scan.sh's harvest uses, which is the point: the scan was already
    # resolving `goal=278 bucket=295` for the very rides this pre-flight was gating against #295.
    #
    # IT STARTS AT THE PARENT, NEVER AT THIS ISSUE, and that is load-bearing: a `goal-review` ride
    # is dispatched with the goal itself as ISSUE_N, and a walk that tested the issue first would
    # gate a goal's own review behind that goal's exhausted budget — locking out the one ride that
    # can re-scope, refund or close it. The scan's caller DOES test its item first, because there
    # the item is a closeout and a goal's own closeout must resolve to itself; same walk, different
    # entry point, each stated where it is chosen.
    # >>>REPLAY:goal-ancestor>>>
    GOAL_PARENT=""
    _gp_direct="$(gh api "repos/${ORG:-teststuffstash}/${PROJECT}/issues/${ISSUE_N}/parent" \
      --jq '.number' 2>/dev/null || true)"
    case "$_gp_direct" in ''|*[!0-9]*) _gp_direct="";; esac
    if [ -n "$_gp_direct" ]; then
      goal_resolve_ancestor "${ORG:-teststuffstash}/${PROJECT}" "$_gp_direct"
      if [ -n "$GB_GOAL" ]; then
        GOAL_PARENT="$GB_GOAL"
        if [ "$GB_HOPS" -gt 0 ]; then
          echo "→ Goal context: #${ISSUE_N}'s parent #${_gp_direct} is not the goal — walked ${GB_HOPS} hop(s) up to goal #${GOAL_PARENT} (post-launch lane, ADR-102)"
        fi
      else
        # DEGRADE TO THE PRE-#367 BEHAVIOUR, never to nothing: an unlabelled, unfunded parent that
        # happens to carry Goal/Acceptance headings produced a card before this change, and a walk
        # that finds no goal must not take that away. It cannot weaken the GATE either — any
        # ancestor with a machine-readable `Budget:` line is a stop condition of the walk, so a
        # parent reached by this arm has none by construction and `goal_budget_read` returns
        # `no-budget` on it exactly as it did before.
        GOAL_PARENT="$_gp_direct"
        echo "→ Goal context: no task/goal or Budget: ancestor above #${ISSUE_N} within the walk's bound — using the direct parent #${_gp_direct} for the card only (no funded goal ⇒ nothing to gate)"
      fi
    fi
    if [ -n "$GOAL_PARENT" ]; then
      GOAL_CARD="$(gh issue view "$GOAL_PARENT" --repo "${ORG:-teststuffstash}/${PROJECT}" \
        --json number,title,body --jq '"#\(.number) — \(.title)\n" +
          ( ((.body // "") | split("\n")) as $l
            | [ range(0; ($l|length)) | select($l[.] | test("^#+ *(Goal|Acceptance)"; "i")) ] as $starts
            | if ($starts|length) == 0 then ""
              else [ $starts[] as $s
                     | ( [ range($s+1; ($l|length)) | select($l[.] | test("^#+ ")) ] | first ) as $stop
                     | $l[$s : (if $stop == null then ($l|length) else $stop end)] | join("\n") ]
                   | join("\n\n")
              end )' 2>/dev/null || true)"
      if [ -n "$GOAL_CARD" ]; then
        echo "→ Goal context: child of #${GOAL_PARENT} — injecting its Goal + Acceptance (bounded) into the env card"
      else
        echo "→ Goal context: child of #${GOAL_PARENT}, but no Goal/Acceptance heading found — dispatching without it"
      fi
    fi
    # <<<REPLAY:goal-ancestor<<<
    # ── Σ(spend + live reservations) ≤ the goal's `Budget:` — leg (c)'s deterministic gate ─────
    # "Enforced in the LAUNCHER pre-flight — deterministic, beside WIP=1, NEVER LLM-honored"
    # (docs/agents/issue-authoring.md §Leg (c)). A decomposition that overruns its goal's funding
    # must not be discovered one ride at a time, after the money is gone.
    #
    # THE ARITHMETIC MOVED (ADR-102, homelab#207) — agents/goal-budget.sh. It did not change: the
    # actual-spend accounting, the descendant fixpoint walk, the per-child fallbacks and the ledger
    # degradation all live there verbatim, with their reasoning. What changed is that a SECOND
    # caller needed the same number — the harvest's self-queue condition asks "does this goal still
    # have room" at a point where exiting the process is not an option. Duplicating the sum was the
    # one thing #207's ⚖ line forbade, so the sum became a function and THIS stayed the enforcer:
    # the pre-flight is what refuses, comments and exits; the harvest only demotes a label.
    # One `gh issue list` call + one ledger GET, only for a ride that HAS a goal.
    if [ -n "$GOAL_PARENT" ]; then
      # >>>REPLAY:goal-budget-gate>>>
      goal_budget_read "${ORG:-teststuffstash}/${PROJECT}" "$GOAL_PARENT" "$MODEL" "${ISSUE_N:-}"
      if [ "$GB_VERDICT" = "exhausted" ]; then
        # >>>REPLAY:goal-budget-refusal>>>
        # SAY IT WHERE A HUMAN LOOKS. Exiting 1 puts the reason in a failed tool call, and whether
        # it reaches the goal then depends on the coordinator session choosing to relay it — a
        # prose dependency, which is the failure class this platform keeps paying for. Comment on
        # the GOAL directly: the refusal is level-triggered and recurs every scan until a human
        # re-scopes or refunds, so the ONLY question is what the second, third and tenth refusal do.
        #
        # ONE COMMENT, EDITED IN PLACE — option 3 of homelab#361, chosen explicitly, with the two
        # rejected options recorded here rather than left to be re-litigated:
        #   (1) dedupe on the `AGENT_BUDGET_REFUSED:` PREFIX → one comment ever, but its numbers
        #       freeze at the first refusal, and a goal's sum moves every time a child settles or a
        #       key goes live. A human re-reading a stale $62.0 to decide a re-scope is worse than
        #       no comment: it looks current and is not.
        #   (2) dedupe on the FULL marker (numbers in it) over the whole thread → numbers always
        #       current, but one comment per distinct sum, and on this platform's busiest thread the
        #       sum moves constantly. That is the residue ADR-103 rule 2 exists to end, arriving by
        #       a slower road.
        # Editing keeps BOTH properties — one comment, current numbers — and is the shape the rest
        # of the loop converged on (agents/machine-comment.sh). It is NOT `mc_event`: that appends
        # one LINE to the `<!-- agent-summary -->` index, and a level-triggered refusal would grow
        # that index by a line per scan, while this body is a multi-line per-child cap table. The
        # detail channel (`mc_check_run`) is not available either — the pre-flight refuses BEFORE a
        # branch or head SHA exists, so there is nothing to hang a check-run on. Hence a comment of
        # its own, on its own marker, through the same three I/O seams.
        #
        # THE MARKER IS AN HTML COMMENT, not the `AGENT_BUDGET_REFUSED:` prefix. The prefix is
        # prose that appears in issues, dispatch notices and reviews ABOUT this mechanism (#361's
        # own thread quotes it), and a substring test cannot tell a marker from a mention —
        # fixtures/fix-debounce-quoted-marker-inert is the same lesson, paid for on homelab#238.
        # The human-readable `AGENT_BUDGET_REFUSED:` line stays in the body, where it is a label
        # rather than a predicate.
        #
        # NO TIMESTAMP IN THE BODY, on purpose: a clock in it would make every scan a distinct body
        # and turn "edit in place" into an edit per scan (GitHub stamps the edit itself — the
        # comment carries "edited …" and its own history).
        _gbr_slug="${ORG:-teststuffstash}/${PROJECT}"
        _gbr_mark='<!-- agent-budget-refusal -->'
        if [ "${GB_LEDGER_DEGRADED:-false}" = "true" ]; then
          _gbr_summary="The sum is a cap-sum estimate because the spend ledger was unreachable — every child was charged its full cap rather than its actual spend. This is the conservative fallback; once the ledger is reachable again the refusal will re-evaluate against real spend."
        else
          _gbr_summary="The sum is ACTUAL spend for settled children (the per-row notes name each charge) plus cap reservations for live keys and this dispatch; a ridden child with no ledger entry is charged its cap, conservatively."
        fi
        _gbr_body="$(printf '%s\nAGENT_BUDGET_REFUSED: Σ(spend + reservations) $%s > Budget $%s\n\nThe launcher refused to dispatch a child of this goal — deterministic pre-flight, not a model judgement (FU-090 leg (c)).\n\nPer-child caps:\n\n%b\nThis is a human decision either way: **re-scope the children** so their caps fit, or **raise the `Budget:` line** on this issue. Until one of those happens the refusal repeats every scan and no child of this goal dispatches.\n\n%s\n\n_Level-triggered: this is ONE comment, re-edited as the numbers move (ADR-103 rule 2) — not one comment per refusal._' \
          "$_gbr_mark" "$GB_SUM" "$GB_BUDGET" "$GB_ROWS" "$_gbr_summary")"
        _gbr_listed="$(mc_gh_comments "$_gbr_slug" "$GOAL_PARENT")" || _gbr_listed=''
        if ! printf '%s' "${_gbr_listed:-null}" | jq -e 'type == "array"' >/dev/null 2>&1; then   # :-null — jq 1.6 exits 0 on EMPTY input, inverting the guard (homelab#377)
          # FAIL CLOSED, exactly as mc_event does: an unreadable timeline plus a create is one new
          # comment per scan — the failure this whole block is about, reached through the error path
          # instead of the happy one. The refusal still stands; it just goes unsaid this tick.
          echo "→ Goal budget: could not read #${GOAL_PARENT}'s comments — refusal NOT posted (fail closed), the refusal still stands" >&2
        else
          # Oldest marked comment wins the tie, per mc_event: if a second one ever appears (a race,
          # a human paste), every later refusal converges back onto the first instead of alternating.
          #
          # The `startswith` arm ADOPTS a pre-marker refusal — the bodies the shipped code posted,
          # which carry no HTML marker at all. Without it the first refusal after this lands would
          # post a duplicate onto exactly the threads the fix exists to protect (goal #278 is
          # carrying one right now), and the fix would open by doing the thing it forbids. Adopting
          # it patches the marker IN, so this arm matches once per goal and never again; it can be
          # deleted when no live goal carries a pre-marker refusal. ANCHORED on purpose —
          # `startswith`, never `contains`: the prefix is prose in every issue about this mechanism,
          # and only the machine writes it as the first characters of a comment (the same rule
          # `AGENT_ERROR:`/`AGENT_INFEASIBLE:` are read under).
          _gbr_id="$(printf '%s' "$_gbr_listed" | jq -r --arg m "$_gbr_mark" \
            '[ .[] | select((.body // "") | (contains($m) or startswith("AGENT_BUDGET_REFUSED:"))) ]
             | sort_by(.created_at) | .[0].id // empty' 2>/dev/null || true)"
          if [ -z "$_gbr_id" ]; then
            mc_gh_comment_create "$_gbr_slug" "$GOAL_PARENT" "$_gbr_body" \
              && echo "→ Goal budget: refusal posted to #${GOAL_PARENT}" >&2 \
              || echo "→ Goal budget: refusal comment FAILED to post (token scope?) — the refusal still stands" >&2
          elif [ "$(printf '%s' "$_gbr_listed" | jq -r --argjson i "$_gbr_id" '.[] | select(.id == $i) | .body')" = "$_gbr_body" ]; then
            # Same numbers, same decision — the comment already says it. A PATCH here would buy an
            # "edited" badge per scan, which is the same noise in a different column.
            echo "→ Goal budget: refusal on #${GOAL_PARENT} already current (comment ${_gbr_id}) — untouched" >&2
          else
            mc_gh_comment_patch "$_gbr_slug" "$_gbr_id" "$_gbr_body" \
              && echo "→ Goal budget: refusal on #${GOAL_PARENT} re-stated in place (comment ${_gbr_id})" >&2 \
              || echo "→ Goal budget: refusal comment FAILED to update (token scope?) — the refusal still stands" >&2
          fi
        fi
        printf 'PREFLIGHT REFUSED: the decomposition of goal #%s overruns its Budget.\n' "$GOAL_PARENT" >&2
        printf '  Σ(spend + reservations) = $%s  >  Budget: $%s\n' "$GB_SUM" "$GB_BUDGET" >&2
        printf '%b' "$GB_ROWS" >&2
        printf '  This is deterministic and not the ride'"'"'s to argue with: re-scope the children or raise\n  the goal'"'"'s Budget: line — both are human edits. (leg (c), docs/agents/issue-authoring.md)\n' >&2
        exit 1
        # <<<REPLAY:goal-budget-refusal<<<
      elif [ "$GB_VERDICT" = "within" ]; then
        echo "→ Goal budget: Σ(spend + reservations) \$${GB_SUM} ≤ Budget \$${GB_BUDGET} on #${GOAL_PARENT} — within funding"
      elif [ "$GB_VERDICT" = "terminal" ]; then
        # homelab#509 — a goal a human has already ruled terminal (goal/validated|reverted|abandoned)
        # gates NOTHING: after a verdict the tree's remaining work is ordinary master-lane work, and
        # the budget line must not keep spending authority over it. SAID, like `within` — a human
        # reading the run sees why a funded ancestor did not gate.
        echo "→ Goal budget: goal #${GOAL_PARENT} is terminal (goal/validated|reverted|abandoned) — pass-through, no budget gate on a dead goal"
      fi
      # <<<REPLAY:goal-budget-gate<<<
      # GB_VERDICT=no-budget → the goal carries no machine-parsed `Budget:` line, so there is
      # nothing to enforce and the ride proceeds, exactly as before ADR-102. ⚠ The HARVEST reads
      # the same verdict the other way (no grant ⇒ no self-queue right) — see goal-budget.sh.
    fi
    TASK_CLASS="$(gh issue view "$ISSUE_N" --repo "${ORG:-teststuffstash}/${PROJECT}" --json labels \
      --jq '[.labels[].name|select(startswith("task/"))|ltrimstr("task/")]|first // empty' 2>/dev/null || true)"
    if [ -n "$TASK_CLASS" ]; then
      if [ -f "$(dirname "$RECIPE")/${TASK_CLASS}.yaml" ]; then
        RECIPE="$(dirname "$RECIPE")/${TASK_CLASS}.yaml"; echo "→ FU-114 L3: recipe .agents/${TASK_CLASS}.yaml selected (task/${TASK_CLASS} label)"
      else
        echo "→ FU-114 L3: issue has task/${TASK_CLASS} but no .agents/${TASK_CLASS}.yaml — using $(basename "$RECIPE")"
      fi
    fi
  fi
  # Splice the env card into the recipe's `instructions` block. Marker-first (the author chose
  # placement); fall back to right after `instructions: |`; WARN + no-card if neither shape is
  # found — NEVER FATAL (a missing marker in one stack's recipe must not wedge the whole loop; the
  # card is a strong aid, not a correctness gate — same degrade-loudly rule as the --docker probe).
  RECIPE_WITH_CARD="$(mktemp)"
  if grep -q '{{PLATFORM_ENV_CARD}}' "$RECIPE"; then
    IND="$(grep -m1 '{{PLATFORM_ENV_CARD}}' "$RECIPE" | sed 's/[^ ].*$//')"
    CARD="$(render_env_card | sed "s/^/${IND}/;s/[[:space:]]*$//")"
    awk -v c="$CARD" '!spliced && /{{PLATFORM_ENV_CARD}}/{print c; spliced=1; next} {print}' "$RECIPE" > "$RECIPE_WITH_CARD"
  elif grep -qE '^[[:space:]]*instructions:[[:space:]]*\|' "$RECIPE"; then
    IND="$(grep -m1 -E '^[[:space:]]*instructions:[[:space:]]*\|' "$RECIPE" | sed 's/[^ ].*$//')  "  # instructions key indent + one level
    CARD="$(render_env_card | sed "s/^/${IND}/;s/[[:space:]]*$//")"
    awk -v c="$CARD" 'p{print c; print ""; p=0} /^[[:space:]]*instructions:[[:space:]]*\|/{p=1} {print}' "$RECIPE" > "$RECIPE_WITH_CARD"
    echo "→ FU-114: env card injected after 'instructions:' (${RECIPE} has no {{PLATFORM_ENV_CARD}} marker)"
  else
    cp "$RECIPE" "$RECIPE_WITH_CARD"
    echo "WARN FU-114: no {{PLATFORM_ENV_CARD}} marker and no 'instructions: |' block in ${RECIPE} — dispatching WITHOUT the environment card" >&2
  fi
  # Recipe YAML gate (2026-08-04, agents/recipe-lint.sh). An unparseable recipe kills the ride ~30s
  # in — AFTER the pod exists, the git token is minted and (on a paid rail) real money is spent: the
  # missing colon-space in sleep-tracking's research.yaml did exactly that to all four goose arms of
  # the FU-126 fan-out once new-stack.sh copied it into circles. Split of blame decides the verdict:
  # a broken RAW recipe is repo content the ride cannot survive → FATAL before pod create; a break
  # that only appears AFTER the splice is OUR bug → drop the card and dispatch anyway, never wedge
  # the loop (same degrade-loudly rule as the missing-marker WARN above).
  if ! bash "$HERE/recipe-lint.sh" "$RECIPE"; then
    rm -f "$RECIPE_WITH_CARD"
    echo "FATAL: ${RECIPE} is not parseable YAML — goose would die 'Invalid recipe' after the pod exists. Fix it in ${PROJECT} (bash agents/recipe-lint.sh <file> reproduces this)." >&2
    exit 2
  fi
  if ! bash "$HERE/recipe-lint.sh" "$RECIPE_WITH_CARD"; then
    echo "WARN: the env-card splice broke the recipe YAML (launcher bug, not repo content) — dispatching the UN-CARDED ${RECIPE}" >&2
    cp "$RECIPE" "$RECIPE_WITH_CARD"
  fi
  RECIPE_B64="$(base64 -w0 "$RECIPE_WITH_CARD")"; rm -f "$RECIPE_WITH_CARD"
  # Context-repos pilot prelude (docs/spikes/context-repos.md): anonymous depth-1 clones into
  # /work/context BEFORE the harness starts. Rides the launcher-owned RUN_CMD so agent-runtime's
  # entrypoint (one REPO_URL) stays untouched; warn-don't-die — a failed clone degrades the ride
  # to exactly the pre-pilot world, and the env card's bullet tells the model the WARN means
  # "not mounted". All expansion is launcher-side (URLs are literals by the time the pod runs).
  CTX_PRELUDE=""
  if [ -n "$CONTEXT_REPOS" ]; then
    CTX_PRELUDE="mkdir -p /work/context; "
    for _CTXU in $CONTEXT_REPOS; do
      _CTXN="$(basename "$_CTXU" .git)"
      CTX_PRELUDE="${CTX_PRELUDE}git clone --depth 1 --quiet ${_CTXU} /work/context/${_CTXN} || echo \"WARN: context clone failed: ${_CTXU}\"; "
    done
  fi
  # GOOSE_MAX_TOKENS as a COMMAND-PREFIX env — it must exist in the POD, not this shell, exactly as
  # agents/retro-session.sh does it. The 16384 ceiling cures the `-32602` truncation class (proven
  # on mimo, 2026-07-25); the cure was wired into the retro path only and the worker's goose arm
  # never had it, which is 8 dead worker rounds with no branch salvaged in the r3 window
  # (homelab#256, docs/agents/retros/2026-08-11-oracle-r3-context.md F1). The proxy's completion
  # floor cannot stand in for it: that rewrites the UPSTREAM request and cannot govern goose's own
  # client-side emit ceiling. The claude arm stays untouched — the var is goose's.
  # >>>REPLAY:harness-run-cmd>>>
  # ── MCP attach (#1041): render the claim knob into each harness's REAL attach interface ─────
  # Rendered only when the stack declares spec.mcp.endpoint. The three harnesses take an MCP server
  # differently, and none took the shape #1041 first shipped (oracle-fleet#330 r1+r2, 2026-09-01:
  # goose rejected `--mcp-config` outright; claude ignored the `CLAUDE_CODE_MCP_CONFIG` env var —
  # it does not exist — so the file was written and never loaded; both verified against the
  # agent-base pins goose-cli 1.47.0 / claude-code 2.1.245):
  #   claude: `--mcp-config <file>` with the CLI's own JSON shape, {"mcpServers":{<name>:{type:
  #           "http",url}}} — the file is base64-carried into the pod command and decoded to
  #           /tmp/mcp-config.json (MCP_PRELUDE); tools need no allowlist under
  #           --dangerously-skip-permissions.
  #   goose:  `--with-streamable-http-extension <URL>` — the URL rides the CLI directly, no file.
  #   opencode: `OPENCODE_CONFIG` env var — the MCP server config is deep-merged into the session
  #             config JSON at /tmp/opencode-session.json (MCP_OPENCODE_CONFIG_JSON), in opencode's
  #             own {"mcp":{<name>:{type:"remote",url:...}}} shape (#1276, proven against pinned
  #             opencode 1.18.21 via `opencode mcp add` on 2026-09-02).
  # spec.mcp.tools is the ENV CARD's line (what the ride is told it has), not a harness input —
  # it is still parsed here so an unparseable knob degrades loudly to no attach on all three arms
  # (same guard as the reviewer arm); an aborted launcher here is fleet-wide, so this sibling
  # must never be the one that keeps set -e alive.
  # ⚠ This block sits INSIDE the replay region because replay clauses run self-contained — a shared
  # helper defined at the script top is invisible to them (proven by RC-127). MCP_PRELUDE,
  # MCP_CONFIG_B64, MCP_GOOSE_FLAG and MCP_OPENCODE_CONFIG_JSON are consumed by the case arms
  # below (or the opencode-session-config block), inside the same region.
  MCP_PRELUDE=""; MCP_GOOSE_FLAG=""; MCP_OPENCODE_CONFIG_JSON=""
  if [ -n "${MCP_ENDPOINT:-}" ]; then
    MCP_CONFIG_JSON="$(jq -cn --arg url "$MCP_ENDPOINT" --argjson tools "${MCP_TOOLS:-[]}" '{mcpServers: {"stack-mcp": {type: "http", url: $url}}}' 2>/dev/null)" || MCP_CONFIG_JSON=""
    MCP_OPENCODE_CONFIG_JSON="$(jq -cn --arg url "$MCP_ENDPOINT" '{mcp: {"stack-mcp": {type: "remote", url: $url}}}' 2>/dev/null)" || MCP_OPENCODE_CONFIG_JSON=""
    if [ -n "$MCP_CONFIG_JSON" ] && [ -n "$MCP_OPENCODE_CONFIG_JSON" ]; then
      MCP_CONFIG_B64="$(printf '%s' "$MCP_CONFIG_JSON" | base64 -w0)"
      MCP_PRELUDE="printf '%s' '${MCP_CONFIG_B64}' | base64 -d > /tmp/mcp-config.json; "
      # @sh-quoted: the endpoint is an unconstrained XRD string and RUN_CMD runs under bash -lc in
      # the pod — a raw '${MCP_ENDPOINT}' inside single quotes would let a literal ' break out
      # (reviewer catch, PR#1186). The claude arm never touches the shell with it (jq --arg) and
      # the opencode arm embeds it via jq --arg into the config JSON.
      MCP_GOOSE_FLAG=" --with-streamable-http-extension $(printf '%s' "$MCP_ENDPOINT" | jq -Rr @sh)"
    else
      MCP_OPENCODE_CONFIG_JSON=""
      echo "agent-session: MCP tools knob unparseable — dispatching WITHOUT MCP attach" >&2
    fi
  fi
  # A claude ride MUST carry --model: without the flag the CLI runs its own DEFAULT — measured
  # 2026-08-13 as claude-opus-5[1m] on this image — not the dispatched model. Every claude/haiku
  # ride since the harness landed (103 on the platform stack in the last 7d alone, ~$419
  # API-equivalent) ran opus-tier against the subscription while agent_run said haiku; found by
  # joining OTLP served-model to agent_run on session count. MODEL is FINAL here (routed /
  # degraded / model_id-parsed to the bare alias). A VENDOR-SLASH id reaching this arm — the
  # legacy launcher default when --harness claude is passed with no --model, which the model_id
  # parse strips to deepseek/deepseek-v4-flash (reviewer catch, PR#407: an openrouter/* pattern
  # here can never match the post-parse id) — is a model the claude CLI cannot run at all, so it
  # resolves to the haiku tier, the same answer the late GOOSE_MODEL shim gives it. The SHAPE is
  # the predicate, not MODEL_RAIL: a bare-alias operator override (--model sonnet) parses
  # rail=openrouter too (the parser's catch-all), and rail-keying would coerce it away.
  _claude_model="${MODEL:-haiku}"
  # An opencode-go/* id rides WHOLE: the CLI passes the string through to the API body and the
  # egress proxy keys the Go rail on the prefix (reviewer-proven wire shape, PR#437). Every OTHER
  # slash-id collapses to haiku exactly as before (the PR#407 vendor-slash rationale above).
  case "$_claude_model" in opencode-go/*) ;; */*) _claude_model="haiku";; esac
  # opencode-go/* ids are UNKNOWN to the claude CLI, which assumes a 200k context window and
  # auto-compacts a 1M-window model ~5x early (#523 ride, 2026-08-18). Emit the harness's own
  # remedy for unknown ids — CLAUDE_CODE_MAX_CONTEXT_TOKENS — as a command prefix; the
  # [1m]-suffix alternative would leak into the model string the egress proxy keys the rail on.
  # An unmapped Go model emits NOTHING (keeps the harness's conservative default, never
  # inherits another model's window). ⚠ Window table DUPLICATED in the --pick-rail ladder's
  # threading clause below — replay clauses run self-contained, so a shared helper defined at
  # the script top is invisible to them (proven by RC-127 in the first fixture run).
  case "$_claude_model" in opencode-go/deepseek-v4-flash) _go_ctx="CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000 ";; *) _go_ctx="";; esac
  case "$HARNESS" in
    claude) RUN_CMD="${CTX_PRELUDE}${MCP_PRELUDE}printf '%s' '${RECIPE_B64}' | base64 -d > /tmp/fix-recipe.yaml; ${_go_ctx}claude -p --model ${_claude_model}${MCP_CONFIG_B64:+ --mcp-config /tmp/mcp-config.json} --dangerously-skip-permissions --max-turns ${CLAUDE_MAX_TURNS:-200} --append-system-prompt-file /tmp/fix-recipe.yaml 'The appended system prompt is this repo'\\''s recipe (goose format) with the platform environment card at the top — TRUST the card over any assumption. Follow the recipe exactly; your task is its prompt with issue=${ISSUE_N}. End your final message with the JSON object its response schema describes (single line, all required keys).'";;
    goose)  RUN_CMD="${CTX_PRELUDE}printf '%s' '${RECIPE_B64}' | base64 -d > /tmp/fix-recipe.yaml; GOOSE_MAX_TOKENS=16384 goose run --recipe /tmp/fix-recipe.yaml --params issue=${ISSUE_N}${MCP_GOOSE_FLAG}";;
    opencode) RUN_CMD="${CTX_PRELUDE}printf '%s' '${RECIPE_B64}' | base64 -d > /tmp/fix-recipe.yaml; opencode run -m ${OPENCODE_MODEL} 'Read /tmp/fix-recipe.yaml (goose-format recipe) and follow its instructions exactly. Issue: '${ISSUE_N}'.'";;  # MCP wired via OPENCODE_CONFIG (merged into /tmp/opencode-session.json in the opencode-session-config block above) — #1276
  esac
  # <<<REPLAY:harness-run-cmd<<<
fi

IMAGE="${HARNESS_IMAGE:-${AGENT_BASE_IMAGE:-ghcr.io/teststuffstash/agent-base:latest}}"
REPO_URL="${REPO_URL:-https://github.com/teststuffstash/${PROJECT}.git}"
SECRET="${OR_SECRET:-${PROJECT}-openrouter}"  # operator-minted, budget-capped. Default: the shared standing key; the coordinator passes --openrouter-secret to bind a per-session ephemeral key instead
# Idempotency: for TASKED runs the key IS the pod name (workflow.md §Hazards — implemented
# 2026-07-21 after the THIRD double-dispatch escape; tick-level guards all have windows, the API
# server doesn't). `kubectl create` below is the atomic test-and-set: EXISTS = someone owns
# (task, round) — a TERMINAL holder is reaped pre-create (its record lives in GitHub by then),
# a LIVE holder refuses the dispatch. Ad-hoc runs keep timestamp names (no natural key).
case "$TASK" in
  issue-[0-9]*|pr-[0-9]*) POD="agent-${PROJECT}-${TASK//[^a-z0-9]/-}-r${ROUND}";;
  *) POD="agent-${PROJECT}-$(date -u +%H%M%S)";;
esac

# ── FU-042 guard (a): the open-PR-liveness check, as a FUNCTION (sentinel-wrapped) so the
# clause-replay fixture can drive its five arms without replaying the pre-flight's other guards
# (WIP cap, session key, devbox.lock — pinned by their own fixtures). homelab#369 narrowed the
# predicate from a bare `#N` MENTION to a strong link: any prose cross-reference in an unrelated
# open PR used to park the issue and point the next round at the WRONG branch. The predicate is
# the C6 strong-link grammar (implements/closes/fixes/resolves, optional colon), the same set the
# review-flip belt and finalize key on — a sibling-seam mention is not a link. The alternation is
# anchored left with `\b` so ordinary prose containing a keyword as a SUFFIX (`unresolved`,
# `prefixes`, `disclose`) cannot false-match: the same failure the guard exists to kill, just
# triggered by prose instead of a bare mention (reviewer finding, PR #567 round 1). --work-branch
# == headRef stays the one legitimate fork exemption, unchanged.
# >>>REPLAY:fu042-guard-a>>>
fu042_guard_a() {
  PF_PR_LINE="$(gh pr list --repo "$PF_SLUG" --state open --json number,body,headRefName \
    --jq "[.[] | select(.body | test(\"(?i)\\\\b(implements|close[sd]?|fix(e[sd])?|resolve[sd]?):? #${PF_ISSUE}\\\\b\"))] | .[] | \"\(.number) \(.headRefName)\"" 2>/dev/null)" || {
    # An unreadable PR list is a DEFERRAL, not a refusal (the homelab#1175 shape, rule #6: never
    # fail INTO a write). A refusal tells the coordinator "fix the state"; an API blip has no state
    # to fix — the next pass retries. Codeowner read 2026-09-03 (ADR-110), on the 07:25Z throttle:
    # a refusal here would have parked every dispatch for the outage's length.
    echo "→ dispatch deferred — gh pr list unreadable, cannot run the duplicate-PR guard (FU-042; resets N/A) — the next pass retries" >&2
    exit 0
  }
  # FU-042 (b): multiple open PRs on one issue — refuse loudly rather than silently picking one.
  # gh pr list returns newest-first; with >1 open PR the invariant is already broken and a
  # legitimate fix round on the canonical PR is un-dispatchable until the duplicate is resolved.
  if [ "$(printf '%s\n' "$PF_PR_LINE" | grep -c . || true)" -gt 1 ]; then
    echo "PREFLIGHT REFUSED: issue #${PF_ISSUE} has multiple open PRs — resolve duplicates before dispatching (FU-042)." >&2
    exit 3
  fi
  if [ -n "$PF_PR_LINE" ]; then
    PF_PR="${PF_PR_LINE%% *}"; PF_HEAD="${PF_PR_LINE#* }"
    if [ -z "$WORK_BRANCH" ]; then
      echo "PREFLIGHT REFUSED: issue #${PF_ISSUE} already has open PR #${PF_PR} (${PF_SLUG}, branch ${PF_HEAD}) — resume it with --work-branch ${PF_HEAD}, don't fork it (FU-042)." >&2
      exit 3
    elif [ "$WORK_BRANCH" != "$PF_HEAD" ]; then
      echo "PREFLIGHT REFUSED: --work-branch ${WORK_BRANCH} does not match open PR #${PF_PR}'s branch ${PF_HEAD} — a resume must land on the PR's own branch (FU-042)." >&2
      exit 3
    fi
    echo "→ pre-flight: resuming open PR #${PF_PR} on its branch ${PF_HEAD} (fix round)"
  fi
}
# <<<REPLAY:fu042-guard-a<<<

# ── Dispatch pre-flight: deterministic guards (FU-042 + the TTL walls, TICK-LOG meta-2 2026-07-09) ──
# The brief's soft judgment failed each of these live: a second coordinator pass double-dispatched an
# in-progress issue (sleep-tracking#10 → conflicting PR #12), and three runs died on stale key/token
# deadlines. Headless task runs only; AGENT_PREFLIGHT=0 to bypass (e.g. deliberate parallel tracks).
if [ -n "$RUN_CMD" ] && [ "${AGENT_PREFLIGHT:-1}" != "0" ]; then
  case "$TASK" in issue-[0-9]*)
    PF_ISSUE="${TASK#issue-}"
    PF_SLUG="${REPO_URL#https://github.com/}"; PF_SLUG="${PF_SLUG%.git}"
    # (a) FU-042: an issue with an OPEN agent PR is alive in the merge path — dispatching a fresh
    # round would fork the work. The predicate and the two refusal arms live in fu042_guard_a
    # (defined above the pre-flight) so the clause-replay fixture can drive them; the legitimate
    # exception is a FIX ROUND resuming that PR's own branch (--work-branch == the PR's headRef).
    if ! command -v gh >/dev/null 2>&1; then
      echo "PREFLIGHT REFUSED: gh not on PATH — cannot check for duplicate PRs (FU-042)." >&2
      exit 3
    fi
    fu042_guard_a
    # (b) live-worker cap per project: default WIP=1; a repo with independent TRACK lanes
    # (TRACKS.md) may run one worker per lane — the dispatcher sets AGENT_WIP_LIMIT=<lanes>
    # (added 2026-07-10 when #2/#3 opened the first two-lane parallel dispatch).
    # >>>REPLAY:fu042-wip-cap>>>
    PF_LIMIT="${AGENT_WIP_LIMIT:-1}"
    # phase!=terminal, NOT phase=Running: a kata pod boots in Pending longer than a tick
    # interval — the Running filter double-dispatched #55 across consecutive ticks (2026-07-21).
    # FU-042 leg (b) / #937: a Pending pod that is Unschedulable (wedged) does NOT hold a WIP
    # slot — it will never run, so it is not live work. A 30-second grace period prevents a
    # briefly-unschedulable new pod from being discounted instantly.
    # #998: a pod whose .status.phase is absent/null is default-counted (parity with the
    # pre-#995 field-selector which matched any non-terminal phase, including empty/missing).
    PF_LIVE="$("$KUBECTL" $KUBE -n "$NS" get pods -l app=agent-session,project="$PROJECT" -o json 2>/dev/null \
      | jq '[.items[] | select(
        .status.phase != "Succeeded" and .status.phase != "Failed" and
        (
          .status.phase == "Running" or .status.phase == "Unknown"
          or
          (.status.phase == "Pending" and (
            ([.status.conditions[]? | select(.type == "PodScheduled" and .status == "False" and .reason == "Unschedulable")] | length) == 0
            or
            (now - (.metadata.creationTimestamp | fromdateiso8601)) < 30
          ))
          or
          (.status.phase | not)  # #998: absent/unset phase — default-count (parity with pre-#995 field-selector)
        )
      )] | length')"
    if [ "${PF_LIVE:-0}" -ge "$PF_LIMIT" ]; then
      echo "PREFLIGHT REFUSED: ${PF_LIVE} agent pod(s) Running in ns ${NS} ≥ WIP limit ${PF_LIMIT} (FU-042; AGENT_WIP_LIMIT raises it for multi-track dispatch)." >&2
      exit 3
    fi
    # <<<REPLAY:fu042-wip-cap<<<
    # (d) FU-118: an offline `devbox add` writes a `placeholder-<system>-<pkg>` store path into
    # devbox.lock that commits fine but hard-fails the NEXT round's bootstrap `devbox install`
    # (`path-info --offline` on a nonexistent path) BEFORE the agent runs — an opaque, unrecoverable
    # boot crash the worker can't self-recover from (#71 r4/r5 died identically here). A poisoned
    # lock on the branch we're about to clone means the round is dead on arrival — refuse loudly
    # with the fix instead of dispatching into the crash. THE FIX IS NEVER A MID-RIDE `devbox add`:
    # resolve the tool ONLINE on the stack's master first (jail/CI), commit the real lock, then the
    # ride USES it (the pre-provision pattern — sleep-tracking PR#75 kind, PR#81 docker-client).
    if command -v gh >/dev/null 2>&1 \
       && gh api "repos/${PF_SLUG}/contents/devbox.lock?ref=${WORK_BRANCH:-$BASE_REF}" \
            -H "Accept: application/vnd.github.raw" 2>/dev/null | grep -q 'placeholder-'; then
      echo "PREFLIGHT REFUSED: devbox.lock on ${PF_SLUG}@${WORK_BRANCH:-$BASE_REF} carries a placeholder store path — a \`devbox add\` wrote it while the FU-118(b) search proxy (\$DEVBOX_SEARCH_HOST, .40.27) was unreachable, so the bootstrap \`devbox install\` will boot-crash this round (FU-118). Fix: re-run the add with the proxy up (it resolves in-band → a REAL store path), or resolve on master; never hand-edit the lock." >&2
      exit 3
    fi
    # >>>REPLAY:context-prefetch>>>
    # ── Context pre-fetch: pre-read the directive channel via REST (homelab#1175) ──────────────
    # Pre-read the issue + comments via REST API (never GraphQL — the pool that failed on #969
    # is the App installation's GraphQL pool; REST has its own). Materialize into /work/issue.md
    # as a prelude to the pod command. Unreadable ⇒ DEFER (exit 0), not strike, not start.
    if command -v gh >/dev/null 2>&1; then
      PF_ISSUE_DATA=""
      PF_ISSUE_DATA="$(gh api "repos/${PF_SLUG}/issues/${PF_ISSUE}" --jq '{title, body, labels: [.labels[].name]}' 2>/dev/null)" || PF_ISSUE_DATA=""
      if [ -z "$PF_ISSUE_DATA" ]; then
        echo "→ dispatch deferred — directive unreadable (repos/${PF_SLUG}/issues/${PF_ISSUE}; resets N/A) — the next pass retries (homelab#1175)" >&2
        exit 0
      fi
      # Fetch comments as raw JSON array, then process with jq in the script
      PF_COMMENTS_RAW=""
      PF_COMMENTS_RAW="$(gh api "repos/${PF_SLUG}/issues/${PF_ISSUE}/comments" --paginate 2>/dev/null)" || PF_COMMENTS_RAW=""
      if [ -z "$PF_COMMENTS_RAW" ]; then
        echo "→ dispatch deferred — directive unreadable (repos/${PF_SLUG}/issues/${PF_ISSUE}/comments; resets N/A) — the next pass retries (homelab#1175)" >&2
        exit 0
      fi
      # Materialize the issue + comments into /work/issue.md as a prelude to the pod command.
      # Build the markdown: title, body, then comments in order with author + timestamp.
      PF_ISSUE_TITLE="$(printf '%s' "$PF_ISSUE_DATA" | jq -r '.title')"
      PF_ISSUE_BODY="$(printf '%s' "$PF_ISSUE_DATA" | jq -r '.body // ""')"
      PF_ISSUE_MD="# Issue #${PF_ISSUE}
## ${PF_ISSUE_TITLE}

${PF_ISSUE_BODY}

## Comments"
      # Process each comment from the raw JSON array
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        PF_AUTHOR="$(printf '%s' "$line" | jq -r '.user.login // ""')"
        PF_CREATED="$(printf '%s' "$line" | jq -r '.created_at // ""')"
        PF_COMMENT_BODY="$(printf '%s' "$line" | jq -r '.body // ""')"
        PF_ISSUE_MD="${PF_ISSUE_MD}

### ${PF_AUTHOR} (${PF_CREATED})

${PF_COMMENT_BODY}"
      done <<< "$(printf '%s' "$PF_COMMENTS_RAW" | jq -c '.[]')"
      PF_ISSUE_B64="$(printf '%s' "$PF_ISSUE_MD" | base64 -w0)"
      PF_ISSUE_PRELUDE="printf '%s' '${PF_ISSUE_B64}' | base64 -d > /work/issue.md; "
      # Prepend the prelude to RUN_CMD so the pod writes /work/issue.md before the harness starts
      if [ -n "${RUN_CMD:-}" ]; then
        RUN_CMD="${PF_ISSUE_PRELUDE}${RUN_CMD}"
      fi
      echo "→ context pre-fetch: issue #${PF_ISSUE} + comments materialized as /work/issue.md (prepended to pod command)"
    fi
    # <<<REPLAY:context-prefetch<<<
  ;; esac
  # (c) session-key freshness: post openrouter-operator#6 the CR surfaces the LIVE key expiry in
  # .status.openrouter.expires_at (the PATCH re-mint bug killed a healthy run at its STALE deadline —
  # the CR spec claimed 20:19, the real key died 18:40). <30 min of real life → refuse; the fix is
  # delete the CR + re-mint (the POST path). Operators without the field → check skipped.
  # claude harness: no OpenRouter key in play — the check would misfire on the standing key.
  PF_EXP=""
  [ "$HARNESS" = "claude" ] || PF_EXP="$("$KUBECTL" $KUBE -n "$NS" get openrouterkeys -o json 2>/dev/null \
    | jq -r --arg s "$SECRET" '[.items[] | select((.spec.secretName // (.metadata.name + "-openrouter")) == $s)][0].status.openrouter.expires_at // empty')"
  if [ -n "$PF_EXP" ]; then
    PF_EXP_S="$(date -d "$PF_EXP" +%s 2>/dev/null || echo 0)"
    if [ "$PF_EXP_S" -gt 0 ] && [ "$PF_EXP_S" -lt $(( $(date +%s) + 1800 )) ]; then
      echo "PREFLIGHT REFUSED: session key ${SECRET} expires at ${PF_EXP} (<30 min real life) — delete the OpenRouterKey CR and re-mint before dispatch (openrouter-operator#6)." >&2
      exit 3
    fi
  fi
fi
# goose's provider is GOOSE_PROVIDER, so it wants the model in the RAIL's own namespace — which is
# exactly the parse above (FU-127): `openrouter/vendor/model` → `vendor/model`, while a CLOAKED
# `openrouter/<codename>` keeps its prefix because that id really does live under that namespace.
GOOSE_MODEL="$MODEL_MODEL"

# ADR-081 v1 (FU-062 §M4, GOOSE ONLY): goose cannot carry OpenRouter `provider` prefs, so its
# OpenRouter traffic rides the in-cluster egress proxy, which injects the per-model provider pin
# into chat/completions bodies (argocd/resources/openrouter-proxy/ — provider-injection only in
# v1; cred injection + Cilium lockdown stay FU-018/FU-020). Opt out with
# AGENT_OPENROUTER_PROXY="" for direct egress (e.g. the proxy is down and it's striking runs).
WORK_BRANCH_ENV=""
if [ -n "$WORK_BRANCH" ]; then
  WORK_BRANCH_ENV=$'        - name: WORK_BRANCH\n          value: "'"$WORK_BRANCH"'"'
fi

# FU-105: human-gated PR — finalize must NOT arm auto-merge (needs the agent-runtime build with
# AGENT_ARM_PR support; an older image ignores the env and the C9 research/* exclusion still
# keeps the PR un-armed after a manual disarm).
ARM_ENV=""
if [ -n "${NO_ARM:-}" ]; then
  ARM_ENV=$'        - name: AGENT_ARM_PR\n          value: "0"'
fi

# homelab#587 leg 2 (§B2 The split): a ~1h READ-ONLY fleet-wide token for the platform retro ride
# ONLY — deliberately NOT GH_TOKEN (the ADR-087 leg B broker's per-repo token path stays
# untouched; this rides alongside it, never replaces it). The launcher is handed a Secret NAME
# (RETRO_GH_SECRET, set by retro-argo.yaml's retro-cell step) and renders a secretKeyRef the pod
# resolves against the IN-NAMESPACE mirror (retro-git.yaml's FU-080 (a) ClusterSecretStore +
# per-ride-ns ExternalSecret) — the raw value never appears in any manifest or any launcher env
# (PR#619 r2: literal cross-namespace env values are the pattern FU-080 (a) exists to forbid).
# optional: true — a namespace without the mirror (every ordinary fixer dispatch) resolves to an
# unset var, and the brief tells the model to name unreachable repos rather than guess.
# >>>REPLAY:retro-gh-token-env>>>
RETRO_GH_TOKEN_ENV=""
if [ -n "${RETRO_GH_SECRET:-}" ]; then
  RETRO_GH_TOKEN_ENV=$'        - name: RETRO_GH_TOKEN\n          valueFrom:\n            secretKeyRef: { name: "'"$RETRO_GH_SECRET"'", key: GH_TOKEN, optional: true }'
fi
# <<<REPLAY:retro-gh-token-env<<<

GOOSE_PROXY_ENV=""; PROXY_URL=""
PROXY_URL="${AGENT_OPENROUTER_PROXY-http://openrouter-proxy.agent-egress.svc.cluster.local:8080}"
if [ "$HARNESS" = "goose" ] && [ -n "$PROXY_URL" ]; then
  GOOSE_PROXY_ENV=$'        - name: OPENROUTER_HOST\n          value: "'"$PROXY_URL"'"'
fi

# ── docker mode (kata microVM + dind sidecar; spike: docs/spikes/kata-ci-gate.md) ──
# Kata guests can't reach cluster-service VIPs (FU-072), so every in-cluster dependency is
# rewritten to a RESOLVED ENDPOINT (pod) IP at dispatch — pod-to-pod works from kata, and the
# egress CNP's toEndpoints rules still match (identity-based). A ride outlives no endpoint here
# in practice (singleton services); when FU-072 lands, delete resolve_ep and the rewrites.
resolve_ep() { # <ns> <svc> → first endpoint IP, empty on failure
  "$KUBECTL" $KUBE -n "$1" get endpoints "$2" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true
}
if [ -n "$DOCKER" ]; then
  if [ -n "$PROXY_URL" ]; then
    EP="$(resolve_ep agent-egress openrouter-proxy)"
    if [ -n "$EP" ]; then
      PROXY_URL="http://${EP}:8080"
      GOOSE_PROXY_ENV=$'        - name: OPENROUTER_HOST\n          value: "'"$PROXY_URL"'"'
      echo "→ docker mode: openrouter-proxy via endpoint IP ${EP} (FU-072 workaround)"
    else
      echo "WARN docker mode: openrouter-proxy endpoint unresolvable — goose/claude LLM egress will fail from the kata guest (FU-072)" >&2
    fi
  fi
fi

# ── claude harness (FU-066): the SUBSCRIPTION worker tier — Haiku by default ──
# Auth is ADR-087 leg A through the proxy's /anthropic upstream: the pod holds ONLY
# `ref:<ns>/claude-session` (a session-key-labeled Secret with data key AUTH_TOKEN —
# operator-created per enabled namespace until it joins the AgentStack claim); the proxy
# resolves the ref, injects the subscription oauth token + the oauth beta header. The unscoped
# ~1y token NEVER sits in a worker pod (unlike the trusted coordinator/reviewer roles, which
# still hold it directly — unify them onto this rail once it has mileage).
# Image = agent-base, same as goose/opencode (it ships the claude CLI + the pre-seeded
# onboarding/trust files since agent-runtime#14): the entrypoint preps the repo, the project
# devbox toolchain (`devbox run ci`) works, and `--docker` (kata+dind) is structurally valid —
# the FU-066(e) coordinator-image interim is retired. Needs AGENT_BASE_IMAGE ≥ the
# agent-runtime#14 build (the deploy-pin bump in images.env); on an older pin the ride fails
# loudly at `claude: command not found` → one strike, no silent damage.
CLAUDE_ENV=""; SUB_LABEL=""
if [ "$HARNESS" = "claude" ]; then
  case "$MODEL" in
    opencode-go/*)
      # Go-rail ride (ADR-107, platform dogfood 2026-08-17): draws the OpenCode Go windows, NOT
      # the Anthropic subscription — so NO subscription-session label (the FU-088 semaphore's
      # label-selector must not count it against the Anthropic slots), rail label instead (the
      # #158 cost-visibility pattern: "what rode the Go rail" is one kubectl/Loki query).
      SUB_LABEL=', "homelab.teststuff.net/rail": opencode-go';;
    *)
      # FU-088: mark subscription-drawing pods for the concurrency semaphore's label-selector count
      SUB_LABEL=', "homelab.teststuff.net/subscription-session": claude'
      # homelab#158: a DEGRADED ride carries its rail on the pod itself, so "which rides did the outage
      # push onto the subscription, and what did they cost" is one kubectl/Loki query away rather than
      # an inference from the model id. A separate label key — the semaphore's selector must keep
      # counting this pod exactly like any other claude ride, because it draws the same capacity.
      [ -z "${RAIL_DEGRADED:-}" ] || SUB_LABEL="${SUB_LABEL}"', "homelab.teststuff.net/rail": subscription-fallback';;
  esac
  # >>>REPLAY:tier-default-struck-model-sync>>>
  # Tier default: Haiku (fast, ~$0 marginal on subscription). An explicit --model wins.
  if [ "$MODEL" = "openrouter/deepseek/deepseek-v4-flash" ]; then
    # The pre-rewrite value is this script's OWN default (:48) — never a chain entry a dispatcher
    # chose or a model that served a request — so the strike must name what actually runs. Contrast
    # the two degrade sites below, which deliberately do NOT sync (#660 acceptance). The chain id
    # for haiku is claude/haiku, so strikes record the chain-entry shape for coordinator matching (#674).
    MODEL="haiku"; STRUCK_MODEL="claude/haiku"
  fi
  GOOSE_MODEL="$MODEL"
  # <<<REPLAY:tier-default-struck-model-sync<<<
  # Cost attribution (2026-08-08 label audit): claude-harness WORKERS exported no telemetry, so
  # every haiku ride was missing from the stacks' subscription-equiv on the agent-cost dashboard.
  STACK_LABEL="${STACK_LABEL:-$(jq -r --arg r "$PROJECT" \
    '.stacks[] | select([.repos[] | if type=="object" then .name else . end] | index($r)) | .name' \
    "$HERE/stacks.json" 2>/dev/null | head -1)}"
  CLAUDE_ENV=$'        - name: ANTHROPIC_BASE_URL\n          value: "'"$PROXY_URL"$'/anthropic"\n        - name: ANTHROPIC_AUTH_TOKEN\n          value: "ref:'"$NS"$'/claude-session"\n        - name: CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC\n          value: "1"\n        - name: CLAUDE_CODE_ENABLE_TELEMETRY\n          value: "1"\n        - name: OTEL_METRICS_EXPORTER\n          value: "otlp"\n        - name: OTEL_LOGS_EXPORTER\n          value: "otlp"\n        - name: OTEL_EXPORTER_OTLP_PROTOCOL\n          value: "http/protobuf"\n        - name: OTEL_EXPORTER_OTLP_ENDPOINT\n          value: "http://otel-collector.monitoring.svc.cluster.local:4318"\n        - name: OTEL_RESOURCE_ATTRIBUTES\n          value: "service.name=claude-code,role=worker,stack='"${STACK_LABEL:-none}"$',project='"$PROJECT"$'"'
fi

# ADR-087 / FU-018 leg A (DEFAULT-ON for goose+proxy since 2026-07-10 — acceptance green on
# oracle-fleet#7/PR#12: full cycle incl. salvage-push + PR-open with zero pod credentials;
# AGENT_CRED_INJECT=0 opts out; opencode joined the rail 2026-07-16 — the FU-018 opencode leg:
# its session config points baseURL at the proxy, the pod key is the same opaque ref): the pod
# gets an OPAQUE REF instead of the real OpenRouter key — the egress proxy resolves ref→key
# (label-checked, per-namespace RBAC) and injects upstream. The ref is worthless outside the
# cluster.
OR_KEY_ENV="        - name: OPENROUTER_API_KEY
          valueFrom:
            secretKeyRef: { name: ${SECRET}, key: OPENROUTER_API_KEY }"
CRED_BROKER_ENV=""; OC_INJECT=""
if [ "$HARNESS" = "claude" ]; then
  OR_KEY_ENV=""   # subscription tier: no OpenRouter key at all — the pod's only cred is the claude ref
fi
if [ "${AGENT_CRED_INJECT:-1}" = "1" ] && [ -n "$PROXY_URL" ] && [ "$HARNESS" = "claude" ]; then
  # FU-089: claude rides join the broker path too — they used to lean on the standing in-ns
  # agent-git-token Secret (the optional fallback FU-089 deleted; found live: issue-135 r1,
  # clone died tokenless — the goose/opencode-only gate was the gap).
  echo "→ cred-inject (claude): git tokens fetched per-op from the proxy (FU-089)"
  CRED_BROKER_ENV="        - name: GIT_CRED_BROKER_URL
          value: \"${PROXY_URL}/git-token?ns=${NS}\""
fi
if [ "${AGENT_CRED_INJECT:-1}" = "1" ] && [ -n "$PROXY_URL" ] \
   && { [ "$HARNESS" = "goose" ] || [ "$HARNESS" = "opencode" ]; }; then
  echo "→ cred-inject: pod holds ref:${NS}/${SECRET}; git tokens fetched per-op from the proxy (ADR-087)"
  OR_KEY_ENV="        - name: OPENROUTER_API_KEY
          value: \"ref:${NS}/${SECRET}\""
  # leg B: the entrypoint's credential helper + gh wrapper fetch the live token per operation from
  # the proxy's /git-token endpoint — the env/mount below stay as fallback until FU-020 removes them.
  CRED_BROKER_ENV="        - name: GIT_CRED_BROKER_URL
          value: \"${PROXY_URL}/git-token?ns=${NS}\""
  if [ "$HARNESS" = "opencode" ]; then
    OC_INJECT=1
    # agent-finalize's or_usage() reads the key's usage via OPENROUTER_HOST — under injection the
    # pod key is a ref only the proxy can resolve, so the read MUST ride the proxy (opencode itself
    # ignores this env; its own traffic is routed by the baseURL merged into OC_CONFIG below).
    GOOSE_PROXY_ENV=$'        - name: OPENROUTER_HOST\n          value: "'"$PROXY_URL"'"'
  fi
fi
# Git credentials are broker-only (FU-089): every ride sets GIT_CRED_BROKER_URL and the pod holds
# no standing git Secret at all — the in-ns agent-git-token fallback was deleted with FU-089 (a
# standing token in a workbench-admin namespace was the cross-stack escalation the airlock exists
# to prevent). The per-op proxy fetch TokenReviews the pod's SA (GIT_TOKEN_REQUIRE_AUTH=1).

# FU-018 interim leg (FU-062 / model-routing.md §M4, OPENCODE ONLY): the prompt cache lives at the
# provider, so per-request provider roulette destroys it — pin the SESSION to the registry's
# effective-cheapest cache-supporting tools-capable provider. Rendered as a per-session opencode
# config (OPENCODE_CONFIG merges under the repo's own opencode.json, so a project override wins);
# allow_fallbacks:true keeps the run alive if the pin is down, and max_price (2× the pinned
# provider's headline prompt $/M) blocks the expensive-lottery fallback (the $5.79 qwen incident).
# goose deliberately gets NOTHING here — it cannot carry provider prefs; that's the ADR-081 proxy.
OC_SETUP=""; OC_ENV=""
# >>>REPLAY:opencode-session-config>>>
if [ "$HARNESS" = "opencode" ]; then
  PIN_JSON="$(python3 "$HERE/estimate_budget.py" --model "$MODEL" --lookup 2>/dev/null || true)"
  # order carries the ROUTING slug — OpenRouter matches tags ("deepinfra"), display names no-op.
  # homelab#876: opencode silently falls back to its default model if the -m provider is not recognized.
  # No config knob exists on the pinned binary (v1.18.13) to disable this fallback (no strict mode or
  # provider allowlist). The fix is launcher-side: compose the full provider-prefixed ID in the CLI
  # argument so opencode recognizes it and never reaches the fallback path.
  OC_CONFIG="$(printf '%s' "$PIN_JSON" | jq -c --arg m "$GOOSE_MODEL" '
    select(.pinned_provider != null) |
    {"$schema": "https://opencode.ai/config.json",
     provider: {openrouter: {models: {($m): {options: {provider: {
       order: [.pinned_provider.slug // .pinned_provider.provider],
       allow_fallbacks: true,
       max_price: {prompt: ((.pinned_provider.prompt * 2 * 10000 | ceil) / 10000)}
     }}}}}}}' 2>/dev/null || true)"
  [ -n "$OC_CONFIG" ] \
    && echo "→ opencode session pin: $(printf '%s' "$PIN_JSON" | jq -r '"\(.pinned_provider.provider) (effective $\(.pinned_provider.effective_per_mtok)/M in)"')" \
    || echo "→ opencode session pin unavailable (registry lookup failed / no eligible provider) — running unpinned"
  # FU-018 opencode leg: under cred injection, route opencode's OpenRouter traffic through the
  # egress proxy (deep-merged into the session config so the pin above survives) — the proxy
  # resolves the ref key exactly as for goose. Without injection opencode stays direct.
  # apiKey must be EXPLICIT here: once the config custom-configures the provider's options
  # (baseURL), opencode skips its env auto-detection and sends NO Authorization header at all —
  # the proxy 401s "Missing Authentication header" (validation ride adhoc-fu018, 2026-07-16).
  # The {env:...} placeholder resolves in-pod, so the ref never lands in the config file either.
  if [ -n "$OC_INJECT" ]; then
    OC_CONFIG="$(jq -cn --argjson base "${OC_CONFIG:-null}" --arg u "${PROXY_URL}/api/v1" '
      ($base // {"$schema": "https://opencode.ai/config.json"})
      * {provider: {openrouter: {options: {baseURL: $u, apiKey: "{env:OPENROUTER_API_KEY}"}}}}')"
    echo "→ opencode via egress proxy: baseURL ${PROXY_URL}/api/v1 (ADR-087; AGENT_CRED_INJECT=0 opts out)"
  fi
  # Headless mode: auto-approve tool calls (read/write/bash) — matching goose's GOOSE_MODE=auto.
  # Without this, an unattended opencode run prompts "user rejected permission" (homelab#792 gap 2).
  # The base is seeded when OC_CONFIG is empty (unpinned + no injection) so the guard never
  # fails open on the headless path — every --recipe opencode ride gets mode.autoApprove.
  # The correct shape for the pinned opencode binary (v1.18.13) is a sub-object under mode:
  #   mode.autoApprove.permission and mode.autoApprove.options (each {} = approve all).
  # The root-level autoApprove: true used in PR#800 was rejected at config validation
  # (homelab#804). Verified against the pinned binary on 2026-08-23.
  if [ -n "$RUN_CMD" ]; then
    OC_CONFIG="$(jq -cn --argjson base "${OC_CONFIG:-null}" '
      ($base // {"$schema": "https://opencode.ai/config.json"})
      * {mode: {autoApprove: {permission: {}, options: {}}}}')"
  fi
  # homelab#1276: merge the MCP server config into the opencode session config when the stack
  # declares spec.mcp.endpoint. The opencode config format uses a top-level "mcp" key with
  # {type: "remote", url: ...} — proven against the pinned binary (opencode 1.18.21) via
  # `opencode mcp add` on 2026-09-02. MCP_OPENCODE_CONFIG_JSON is set in the MCP attach block
  # above (harness-run-cmd replay region) when MCP_ENDPOINT is non-empty and parseable.
  if [ -n "${MCP_OPENCODE_CONFIG_JSON:-}" ]; then
    OC_CONFIG="$(jq -cn --argjson base "${OC_CONFIG:-null}" --argjson mcp "$MCP_OPENCODE_CONFIG_JSON" '
      ($base // {"$schema": "https://opencode.ai/config.json"}) * $mcp')"
    echo "→ opencode MCP server attached: stack-mcp (remote, ${MCP_ENDPOINT})"
  fi
  if [ -n "$OC_CONFIG" ]; then
    # base64 keeps the JSON inert through the bash -c → jq -Rs → pod-yaml quoting layers.
    OC_SETUP="printf '%s' '$(printf '%s' "$OC_CONFIG" | base64 -w0)' | base64 -d > /tmp/opencode-session.json; "
    OC_ENV=$'        - name: OPENCODE_CONFIG\n          value: "/tmp/opencode-session.json"'
  fi
fi
# <<<REPLAY:opencode-session-config<<<

if [ -n "$RUN_CMD" ]; then
  # Run the harness, tee its output to a file, then emit the AGENT_RUN_STATS line (agent-finalize
  # parses the run's structured outcome from that file + computes cost/duration). `set +e` so a
  # harness failure still runs finalize; the tee keeps the live stream intact for `kubectl logs -f`.
  # HARNESS_EXIT (the harness's own status, not tee's) feeds the transcript manifest (§A1).
  # All harnesses (incl. claude since agent-runtime#14 / the 2026-07-16 acceptance ride) take the
  # normal in-pod finalize path: tokens/turns + transcripts for subscription runs (FU-066 b). The
  # coordinator-image-era minimal-stats fallback is gone — an AGENT_BASE_IMAGE pin older than
  # agent-runtime#14 would fail loudly at `claude: command not found` long before finalize.
  # FU-120 belt: pin the agent-base harness profile on PATH for finalize. Its `#!/usr/bin/env
  # python3` shebang (+ the git/gh subprocesses it spawns) must resolve even if the ride left PATH
  # in a weird state — #71 r2 crashed here with `env: python3: not found` on a storming kata pod, so
  # the strike/report/salvage never ran. python IS baked + normally on PATH (agent-base/devbox.json,
  # /opt/agent/.devbox), so this guards that anomaly, not a missing dep. `\$PATH` expands in-pod.
  FINALIZE="HARNESS_EXIT=\${PIPESTATUS[0]} PATH=/opt/agent/.devbox/nix/profile/default/bin:\$PATH agent-finalize /tmp/run.log"
  WRAPPED="${OC_SETUP}set +e; { ${RUN_CMD} ; } 2>&1 | tee /tmp/run.log; ${FINALIZE}"
  # ── the payload ceiling (homelab#242) ─────────────────────────────────────────────────────────
  # `args: ["bash","-c","<WRAPPED>"]` is ONE argv string when the kubelet execs the container, and
  # the card-spliced recipe rides inside it as base64. Measure it HERE: this is the last point at
  # which the string is final AND no pod exists — past the ceiling the exec dies E2BIG inside a pod
  # that already cost a mint and a schedule, with `Argument list too long` as its whole diagnosis.
  # >>>REPLAY:argv-payload-ceiling>>>
  if ! argv_guard "the pod command for ${POD}" "$WRAPPED"; then
    printf '  REFUSED before pod create — no pod, no minted git token, no spend. Harness %s.\n' "$HARNESS" >&2
    exit 2
  fi
  # <<<REPLAY:argv-payload-ceiling<<<
  ARGS="[\"bash\",\"-c\",$(printf '%s' "$WRAPPED" | jq -Rs .)]"
elif [ -n "$OC_SETUP" ]; then
  # Interactive opencode session: write the pin config, then idle for the exec below.
  ARGS="[\"bash\",\"-c\",$(printf '%s' "${OC_SETUP}exec sleep infinity" | jq -Rs .)]"
else
  ARGS="[\"sleep\",\"infinity\"]"       # idle after prep; you exec in below
fi

# §A1 transcript capture (docs/agents/observability-and-retro.md): fetch the WRITE-ONLY key for the
# agent-transcripts bucket and inject it as env VALUES below — a secretKeyRef can't cross namespaces
# (source of truth: agent-coordinator ns, written by the Crossplane Workspace
# agents/coordinator/garage-workspace.yaml; the AgentStack Composition mirrors it into each fixer
# namespace as an ExternalSecret — FU-080 a — and the pod secretKeyRefs it in-ns, so this launcher
# reads NO key material). Best-effort: without the mirror the run proceeds and agent-finalize
# skips the upload loudly.
# FU-095 P1: the stack name rides into the pod (AGENT_STACK) so the in-pod finalize can POST
# /report itself — resolution is launcher-owned (stacks.json; empty = unresolvable, finalize skips).
REPORT_STACK="$(jq -r --arg r "$PROJECT" '.stacks[]|select([.repos[]]|index($r))|.name' "${HERE}/stacks.json" 2>/dev/null | head -1)"
[ "$REPORT_STACK" = "null" ] && REPORT_STACK=""
# homelab#158: the resolved rail, one string, computed once from the FINAL harness — never re-derived
# downstream (the same one-parser rule FU-127 applied to model ids).
# >>>REPLAY:agent-rail>>>
if [ -n "${RAIL_DEGRADED:-}" ]; then AGENT_RAIL="subscription-fallback"
elif [ "$HARNESS" = "claude" ];  then
  case "$MODEL" in opencode-go/*) AGENT_RAIL="opencode-go";; *) AGENT_RAIL="subscription";; esac
else                                  AGENT_RAIL="openrouter"; fi
# <<<REPLAY:agent-rail<<<
TS_ENDPOINT="http://garage.garage.svc.cluster.local:3900"; TS_BUCKET="agent-transcripts"
PGW_URL="${AGENT_PUSHGATEWAY_URL:-http://prometheus-pushgateway.monitoring.svc.cluster.local:9091}"
if [ -n "$DOCKER" ]; then # FU-072: service VIPs unreachable from kata guests — ride on endpoint IPs
  EP="$(resolve_ep garage garage)";                          [ -n "$EP" ] && TS_ENDPOINT="http://${EP}:3900" || echo "→ docker mode: garage endpoint unresolvable — transcript upload will be skipped"
  EP="$(resolve_ep monitoring prometheus-pushgateway)";      [ -n "$EP" ] && PGW_URL="http://${EP}:9091" || echo "→ docker mode: pushgateway endpoint unresolvable — run metrics push will fail silently"
fi
"$KUBECTL" $KUBE -n "$NS" get secret agent-transcripts-s3 >/dev/null 2>&1 \
  || echo "→ transcript mirror agent-transcripts-s3 absent in ns ${NS} (claim not synced?) — run proceeds, upload will be skipped"

# Persistent uv (PyPI wheel) cache: if a `agent-uv-cache` PVC exists in the namespace, mount it so
# `devbox run ci`'s `uv sync` fetches wheels once across runs (the nix cache only covers `devbox
# install`). Optional — projects without the PVC just get an ephemeral cache. RWX so concurrent
# agent pods can share it; fsGroup below makes it writable for the non-root user.
UV_MOUNT=""; UV_VOLUME=""; UV_ENV=""
if "$KUBECTL" $KUBE -n "$NS" get pvc agent-uv-cache >/dev/null 2>&1; then
  UV_MOUNT=$'\n        - { name: uv-cache, mountPath: /uv-cache }'
  UV_VOLUME=$'\n    - name: uv-cache\n      persistentVolumeClaim: { claimName: agent-uv-cache }'
  # Point uv at the shared cache ONLY when it's actually mounted. Setting UV_CACHE_DIR=/uv-cache
  # without the mount makes uv `mkdir /uv-cache` at `/`, which the non-root (1000) user can't write —
  # "failed to create directory /uv-cache: Permission denied". Absent the mount, leaving UV_CACHE_DIR
  # unset lets uv fall back to its writable default (~/.cache/uv). Couple the two; never split them.
  UV_ENV=$'        - name: UV_CACHE_DIR\n          value: "/uv-cache"'
fi

# FU-096: the stack's CI-published devbox cache (eval seed + file:// store), mounted read-only
# via a k8s ImageVolume (verified on-cluster, oracle-fleet#106) — the entrypoint seeds ~/.cache
# and adds the substituter so the per-pod `devbox install` skips the eval tax. Mount ONLY when
# the :latest manifest is anonymously pullable (a missing/PRIVATE package would otherwise fail
# the whole pod at image-pull — probe-then-mount, degrade loudly to a cold ride). Anonymous is
# the same auth the kubelet pull uses (no imagePullSecrets on ride pods), so probe ≈ pullable.
# Kata rides included: ImageVolume-under-kata canaried green 2026-07-27 (read-only mount
# readable inside the microVM — both pilot stacks run fixer.docker, so kata IS the common case).
# AGENT_STACK_CACHE=0 opts out.
SC_MOUNT=""; SC_VOLUME=""
if [ "${AGENT_STACK_CACHE:-1}" = "1" ]; then
  SC_IMAGE="ghcr.io/teststuffstash/${PROJECT}/devbox-cache:latest"
  SC_TOKEN="$(curl -fsS --max-time 5 "https://ghcr.io/token?scope=repository:teststuffstash/${PROJECT}/devbox-cache:pull" 2>/dev/null | jq -r '.token // empty')" || SC_TOKEN=""
  if [ -n "$SC_TOKEN" ] && curl -fsSI --max-time 5 -H "Authorization: Bearer $SC_TOKEN" \
       -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json" \
       "https://ghcr.io/v2/teststuffstash/${PROJECT}/devbox-cache/manifests/latest" >/dev/null 2>&1; then
    echo "→ stack devbox-cache: mounting ${SC_IMAGE} (FU-096)"
    SC_MOUNT=$'\n        - { name: stack-cache, mountPath: /stack-cache, readOnly: true }'
    SC_VOLUME=$'\n    - name: stack-cache\n      image: { reference: "'"$SC_IMAGE"'", pullPolicy: Always }'
  else
    echo "→ stack devbox-cache absent for ${PROJECT} (no public :latest at ghcr) — cold bring-up (FU-096: publish via devbox-cache.reusable.yml + make the package public)"
  fi
fi

# opencode's Bun runtime needs AVX2 → it SIGILLs ("Illegal instruction") on the older homelab CPUs
# (hp-01, thinkcentre). goose (Rust) runs anywhere. Pin opencode pods to AVX2-capable nodes via the
# homelab.io/cpu-avx2 label (the Proxmox VMs + the Haswell/Broadwell ThinkPads carry it). NB: that
# label is currently set imperatively — codify it in Talos machine.nodeLabels so it survives a node
# reinstall (boot-from-git follow-up).
AFFINITY=""
if [ "$HARNESS" = "opencode" ]; then
  AFFINITY=$'  affinity:\n    nodeAffinity:\n      requiredDuringSchedulingIgnoredDuringExecution:\n        nodeSelectorTerms:\n          - matchExpressions:\n              - { key: homelab.io/cpu-avx2, operator: In, values: ["true"] }'
fi

# >>>REPLAY:opencode-hostaliases>>>
# homelab#990: opencode's SDK-init fetches to models.dev + models.opencode.ai carry NO timeout
# under enforced egress (CNP deny is a silent SYN black-hole). Stub them to 127.0.0.1 so the
# init fails fast (instant RST) instead of wedging to the 4h deadline.
#
# Why kill-at-the-tool (homelab#456) doesn't cover this: the SDK-init fetches are NOT
# suppressible on the pinned opencode build (tested 2026-08-26: no knob found), so the
# resolver (hostAliases) is the only remaining kill point.
HOST_ALIASES=""
if [ "$HARNESS" = "opencode" ] && [ "${EGRESS_ENFORCE:-}" = "true" ]; then
  HOST_ALIASES=$'  hostAliases:\n    - ip: "127.0.0.1"\n      hostnames:\n        - "models.dev"\n        - "models.opencode.ai"'
fi
# homelab#107: registry.npmjs.org drops from ALL homelab rides (goose/claude, not just opencode)
# under enforced egress with no node profile. The CNP deny is a silent SYN black-hole → ride
# hang. Stub to 127.0.0.1 so the connection fails fast (instant RST) instead of wedging.
# This applies to every harness — the source of the npm traffic is not yet identified (no
# cluster access to trace the call site), but the resolver stub is harmless and converts
# silent-drop → fast-fail for any ride under enforced egress without a node profile.
if [ "${EGRESS_ENFORCE:-}" = "true" ] && [ "${EGRESS_PROFILE:-}" != "node" ]; then
  if [ -n "$HOST_ALIASES" ]; then
    HOST_ALIASES="${HOST_ALIASES}"$'\n    - ip: "127.0.0.1"\n      hostnames:\n        - "registry.npmjs.org"'
  else
    HOST_ALIASES=$'  hostAliases:\n    - ip: "127.0.0.1"\n      hostnames:\n        - "registry.npmjs.org"'
  fi
fi
# <<<REPLAY:opencode-hostaliases<<<

# ── docker-mode pod fragments (kata microVM + dind sidecar; every accommodation is a spike
# finding, docs/spikes/kata-ci-gate.md): RuntimeClass kata schedules onto the kata-labeled
# laptops + tolerates the compute taint by itself. dnsPolicy None + LAN resolver = the FU-072
# workaround. The sidecar preamble: inotify sysctls (kubelet watches), mknod /dev/kmsg (kata
# guests lack it; kubelet/cadvisor hard-requires it — THE spike root cause), MTU clamp 1350,
# mkfs+mount /var/lib/docker from an ephemeral BLOCK PVC (longhorn-scratch, FU-081): kata
# hotplugs a block volume as virtio-blk — the one disk shape where overlay2 works in the guest
# (it can't stack on the virtiofs rootfs, and the earlier 2Gi tmpfs charged the dind cgroup —
# the full kind gate OOMed on image builds). --group=1000 lets the
# non-root agent use the socket; dockerd-entrypoint.sh (not raw dockerd) keeps the dind cgroup-v2
# nesting that gives inner containers the memory controller. Memory envelope: agent 2Gi + dind
# 2560Mi, layer store on disk ≈ the acceptance-proven ~5Gi VM with tmpfs headroom back — sized to
# FIT THE 8G LAPTOPS: 2560 + 2048 + 512 (RuntimeClass overhead) = 5120Mi against ~6.3Gi
# allocatable, Guaranteed QoS (kata.tf).
# ⚠ "one docker ride per node" was true of an all-8G kata fleet and is NO LONGER a fleet-wide
# fact: the pool is wk-metal-01..04 and wk-metal-04 has 16G (~14.2Gi allocatable), so it fits TWO
# and is the only node that does. The per-node count is a CONSEQUENCE of the request against that
# node's memory, not a policy — which is why concurrency here is memory-bound and asymmetric while
# REPO_MAX_WIP merely counts pods. Observed live 2026-08-07: two kata rides co-scheduled on -04
# with -01..-03 free, which is the scheduler placing on capacity, exactly as intended.
# ⚠ Do NOT "fix" that with a topologySpreadConstraint — spreading moves a ride off the only node
# with real headroom onto a 6.3Gi one.
KATA_BLOCK=""; DOCKER_ENV=""; DOCKER_MOUNT=""; DOCKER_VOLUMES=""; DIND_CONTAINER=""
AGENT_LIMITS='{ cpu: "6",    memory: "4Gi" }'   # install is partly CPU-bound; allow burst past 2
# ⚠ MEMORY requests MUST EQUAL limits (no overcommit) for agent workloads — 2026-07-27
# incident: the #48 docker ride requested 2Gi total but its kata VM grows to limits (~5Gi
# incl. RuntimeClass overhead); the scheduler placed it on a node with ~2Gi free and the
# KERNEL global-OOMed wk-metal-03, SIGKILLing longhorn-manager + cilium-agent as collateral.
# The "one docker ride per node" envelope (comment above) is only real if requests SAY so.
# CPU stays overcommitted deliberately: throttling is safe, and cpu=2 requests can't fit
# 2-core kata nodes.
AGENT_REQUESTS='{ cpu: "500m", memory: "4Gi" }'
if [ -n "$DOCKER" ]; then
  AGENT_LIMITS='{ cpu: "2", memory: "2Gi" }'    # heavy lifting moves into the dind sidecar
  AGENT_REQUESTS='{ cpu: "500m", memory: "2Gi" }'
  KATA_BLOCK=$'  runtimeClassName: kata\n  dnsPolicy: "None"\n  dnsConfig:\n    nameservers: ["192.168.2.1"]'
  # Pull-through mirrors (FU-073, argocd/resources/registry-cache/): docker.io rides the mirror
  # via dockerd registry-mirrors (Hub-only by dockerd design); the ghcr mirror is exported for
  # gate scripts (kind: certs.d/hosts.toml into the node, oracle-fleet#35). BGP VIPs, git-pinned —
  # reachable from kata guests where ClusterIPs are not (FU-072). NO upstream fallback once the
  # egress CNP drops the docker.io FQDNs: mirror down ⇒ pulls hang ⇒ AgentWorkerEgressDropped.
  MIRROR_DOCKER_IO="${AGENT_MIRROR_DOCKER_IO-http://192.168.40.20}"
  MIRROR_GHCR="${AGENT_MIRROR_GHCR-http://192.168.40.21}"
  MIRROR_MCR="${AGENT_MIRROR_MCR-http://192.168.40.31}"
  # nix-cache via its BGP VIP (FU-073e): the entrypoint's default is the ClusterIP service DNS,
  # unreachable from a kata guest (FU-072) — without this override a docker ride's `devbox
  # install` fell back to cache.nixos.org over the WAN (~4 min cold, measured 2026-07-14).
  NIX_CACHE_VIP="${AGENT_NIX_CACHE_URL-http://192.168.40.23}"
  DOCKER_ENV=$'        - name: DOCKER_HOST\n          value: "unix:///docker-run/docker.sock"\n        - name: NIX_CACHE_URL\n          value: "'"$NIX_CACHE_VIP"$'"\n        - name: REGISTRY_MIRROR_DOCKER_IO\n          value: "'"$MIRROR_DOCKER_IO"$'"\n        - name: REGISTRY_MIRROR_GHCR\n          value: "'"$MIRROR_GHCR"$'"\n        - name: REGISTRY_MIRROR_MCR\n          value: "'"$MIRROR_MCR"$'"'
  DOCKER_MOUNT=$'\n        - { name: docker-run, mountPath: /docker-run }'
  DOCKER_VOLUMES=$'\n    - name: docker-run\n      emptyDir: {}\n    - name: docker-lib\n      ephemeral:\n        volumeClaimTemplate:\n          spec:\n            accessModes: ["ReadWriteOnce"]\n            volumeMode: Block\n            storageClassName: longhorn-scratch\n            resources: { requests: { storage: 20Gi } }'
  # NATIVE SIDECAR (initContainers + restartPolicy Always): the kubelet terminates it when the
  # main container completes — without this the pod sat phase=Running on a live dockerd after the
  # agent exited, wedging the WIP=1 pre-flight + the scan's project-WIP hold for 3 DAYS (found
  # 2026-07-21, the post-#56 queue stall).
  DIND_CONTAINER="$(cat <<'DIND'
  initContainers:
    - name: dind
      image: __DIND_IMAGE__
      restartPolicy: Always                   # ← what makes it a sidecar, not a blocking init
      securityContext: { privileged: true }   # root in the microVM only, not on the node (kata)
      command: ["sh", "-c"]
      args:
        - |
          sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512 >/dev/null || true
          mknod /dev/kmsg c 1 11 2>/dev/null || true
          # mount-first, mkfs on failure: busybox blkid exits 0 on a BLANK device, so it can't
          # be the "is it formatted" guard (learned live — dockerd fell back to the virtiofs
          # rootfs and overlay2 refused). Hard-fail instead of letting that happen again.
          mkdir -p /var/lib/docker
          mount /dev/docker-scratch /var/lib/docker 2>/dev/null \
            || { mkfs.ext4 -q /dev/docker-scratch && mount /dev/docker-scratch /var/lib/docker; } \
            || { echo "FATAL: scratch block volume mount failed"; exit 1; }
          mkdir -p /etc/docker && echo '{"mtu": 1350, "storage-driver": "overlay2", "registry-mirrors": ["__MIRROR_DOCKER_IO__"], "insecure-registries": ["__MIRROR_HOST__"]}' > /etc/docker/daemon.json
          exec dockerd-entrypoint.sh dockerd --host=unix:///run/docker.sock --group=1000
      volumeMounts:
        - { name: docker-run, mountPath: /run }
      volumeDevices:
        - { name: docker-lib, devicePath: /dev/docker-scratch }
      resources:
        requests: { cpu: "500m", memory: "2560Mi" }  # = limit (no memory overcommit; wk-metal-03 global-OOM 2026-07-27)
        limits:   { cpu: "2",    memory: "2560Mi" }
DIND
)"
  DIND_CONTAINER="${DIND_CONTAINER/__DIND_IMAGE__/${AGENT_DIND_IMAGE:-ghcr.io/k3d-io/k3d:5-dind}}"
  DIND_CONTAINER="${DIND_CONTAINER/__MIRROR_DOCKER_IO__/${MIRROR_DOCKER_IO}}"
  DIND_CONTAINER="${DIND_CONTAINER/__MIRROR_HOST__/${MIRROR_DOCKER_IO#http://}}"
fi

# >>>REPLAY:fu088-gates>>>
# FU-088(a): a claude-harness worker draws on the one operator subscription — defer the spawn
# while the egress proxy's 429 latch / utilization threshold / concurrency semaphore says so
# (OpenRouter harnesses are unaffected). An opencode-go/* ride probes ITS rail's latch instead —
# the proxy's self-metered Go window (chunk C /opencode-limit; the reviewer failover's gate,
# transposed). Every OTHER claude ride consults the ONE ladder (--pick-rail): Anthropic clear →
# proceed as dispatched; Anthropic latched but Go clear → FAIL OVER to the Go rail (leg 2, #439 —
# the worker was the last gate that consulted the Anthropic latch alone); both latched → defer.
# All three probes are fail-open burn-savers: the proxy 429s a genuinely latched window.
if [ "$HARNESS" = "claude" ]; then
  case "$MODEL" in
    opencode-go/*)
      _go_reply="$(curl -fsS --max-time 5 "${AGENT_EGRESS_PROXY:-http://openrouter-proxy.agent-egress.svc.cluster.local:8080}/opencode-limit" 2>/dev/null)" || _go_reply=""
      if [ -n "$_go_reply" ] && [ "$(printf '%s' "$_go_reply" | jq -r '.limited // false' 2>/dev/null)" = "true" ]; then
        # homelab#600 (launcher half): the /opencode-limit `reason` separates the TRANSIENT
        # semaphore leg from a CAPACITY one. The exact semaphore string is `semaphore` — the
        # anthropic arm folds its semaphore in with reason="semaphore" (openrouter-proxy.py:1552,
        # "the FU-088 concurrency semaphore is folded in server-side (reason \"semaphore\")") and
        # FU-170 piece a composes the Go semaphore into the SAME top-level `limited` verdict
        # (openrouter-proxy.py:1584-1597, _go_semaphore_state; no launcher change needed for the
        # bound). The Go leg does NOT publish a `reason` today (openrouter-proxy.py:1596-1603 —
        # the /opencode-limit payload has no `reason` key), so until homelab#600's proxy half
        # lands, `.reason` is empty and every limited reply DEFERS exactly as before. The capacity
        # reasons — window utilizations (the anthropic arm's `utilization-<window>` shape, here
        # 5h/7d/30d) and homelab#600's observed-429/observed-402 — are what this arm REROUTES on.
        _go_reason="$(printf '%s' "$_go_reply" | jq -r '.reason // ""' 2>/dev/null)"
        case "$_go_reason" in
          semaphore|"")
            # transient: the semaphore releases in minutes, and an untyped limited (empty reason
            # — the proxy as it stands) defers too. Fail-safe: never burn subscription capacity on
            # a condition that will resolve on its own (the #158 inversion, one rail down).
            echo "→ ${PROJECT} Go-rail dispatch deferred — opencode window limited (${_go_reason:-?})"
            exit 0;;
          *)
            # CAPACITY: a window is latched (the monthly reset is ~25 days out) or homelab#600's
            # observed-429/402 fired — deferring parks every Go-primary dispatch for the whole
            # window. REROUTE through the M12 degrade path (docs/agents/model-routing.md §M12)
            # instead, with the SAME bounds. ⚠ This is a FAITHFUL DUPLICATION of the rail-degrade
            # block's bounds (:404-438) — the replay ratchet extracts the two sentinels
            # independently, so a shared helper defined in one block is invisible to the other's
            # fixtures (proven by RC-127); the dedup debt is named here, not silently paid.
            _fb_ok="$(printf '%s' "$_srow" | jq -r 'if .subscriptionFallback == false then "" else "1" end' 2>/dev/null)" || _fb_ok="1"
            _fb_why="subscriptionFallback:false on the stack row"
            if [ "${AGENT_SUBSCRIPTION_FALLBACK:-1}" != "1" ]; then _fb_ok=""; _fb_why="AGENT_SUBSCRIPTION_FALLBACK=0"; fi
            _fb_model="${AGENT_SUBSCRIPTION_FALLBACK_MODEL:-claude/haiku}"
            if [ -n "$_fb_ok" ] \
               && [ "$(printf '%s' "$_srow" | jq -r --arg m "$_fb_model" '[(.modelDeny // [])[] | select(. == $m)] | length' 2>/dev/null || echo 0)" != "0" ]; then
              _fb_ok=""; _fb_why="${_fb_model} is in this stack's modelDeny — the claim wins over the fallback"
            fi
            case "${TASK:-}" in
              issue-[0-9]*)
                if [ -n "$_fb_ok" ]; then
                  # Re-point the pod command at the fallback model FIRST — RUN_CMD was baked above
                  # (harness-run-cmd) with the Go model; thread it in place like the #439 leg-2
                  # failover (:1498-1521). The pre-thread token is captured first: _claude_model
                  # takes the fallback below and can no longer serve as the match pattern. Thread
                  # BEFORE announcing (the leg-2 finding-2 ratchet): never log a RAIL DEGRADE over
                  # a pod that would serve the latched Go rail.
                  _degrade_model="${_fb_model#claude/}"
                  _old_model="${_claude_model:-${MODEL}}"
                  _new_cmd="${RUN_CMD:-}"
                  _new_cmd="${_new_cmd//--model ${_old_model} /--model ${_degrade_model} }"
                  # The Go model's window env (harness-run-cmd baked
                  # CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000 for the 1M-window flash id) must NOT
                  # ride a haiku fallback — the M12 degrade shape has no Go env, and a 200k model
                  # declared at 1M auto-compacts wrong. Strip it; a no-op when it was never baked
                  # (the --run/retro shape, or a non-flash Go id).
                  _new_cmd="${_new_cmd//CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000 /}"
                  case "$_new_cmd" in
                    *"--model ${_degrade_model} "*) ;;   # recipe/worker shape: the substitution took
                    *"claude -p "*)                     # --run shape: no --model flag at all — insert one
                      _new_cmd="${_new_cmd/claude -p /claude -p --model ${_degrade_model} }";;
                    *)                                  # neither shape: never announce a rail the pod will not serve
                      echo "→ ${PROJECT} Go-rail dispatch deferred — opencode window limited (${_go_reason}); the subscription fallback's model could not be threaded into the pod command"
                      exit 0;;
                  esac
                  RUN_CMD="$_new_cmd"
                  RAIL_DEGRADED="$_fb_model"
                  echo "→ homelab#158 RAIL DEGRADE: Go-rail capacity limited [go-limited:${_go_reason}] — dispatching ${RAIL_DEGRADED} on the subscription instead of deferring (go-rail pick was: ${MODEL}). rail=subscription-fallback; the FU-088 gate still bounds this ride."
                  # The pre-gate SUB_LABEL/AGENT_RAIL were computed from the PRE-reroute Go model
                  # (:1147, :1305) — the degraded ride draws SUBSCRIPTION capacity (not the Go
                  # window), so override them exactly as the M12 degrade leaves them
                  # (:1149-1155 subscription-session:claude + rail:subscription-fallback, :1303).
                  # STRUCK_MODEL is deliberately NOT synced here (#660 acceptance; PR#668 arbitration).
                  # The pre-degrade entry is the one that was dispatched and found unavailable — that is
                  # what the strike must name, so the coordinator's chain walk skips it and keeps the
                  # fallback. Syncing to the fallback IS the #652 defect. The tier-default rewrite above
                  # is the opposite shape (a placeholder default → the model that runs) and does sync.
                  MODEL="$_degrade_model"
                  GOOSE_MODEL="$_degrade_model"
                  SUB_LABEL=', "homelab.teststuff.net/subscription-session": claude, "homelab.teststuff.net/rail": subscription-fallback'
                  AGENT_RAIL="subscription-fallback"
                else
                  # Says what THIS block decided, not what the ride will do — same shape as the
                  # M12 strict-wait line (:435): an opted-out stack dispatches onto the latched
                  # rail, and its own 429s are what it has chosen to wait on.
                  echo "→ homelab#158: Go-rail capacity limited [go-limited:${_go_reason}] but the subscription fallback is OFF here (${_fb_why}) — strict wait: no degrade, and this ride is left to the gates below exactly as before the trigger existed."
                fi;;
              *)
                echo "→ homelab#158: Go-rail capacity limited [go-limited:${_go_reason}] — no degrade for a non-fix ride (task=${TASK:-adhoc}); the existing gates decide this one.";;
            esac;;
        esac
      fi;;
    *)
      # homelab#439 leg 2: the ONE ladder replaces the Anthropic-only probe — when the
      # subscription is latched but the Go rail is clear, a claude-harness worker/retro ride
      # FAILS OVER to the Go rail instead of idling (the reviewer #424 and the leg-1 non-worker
      # sites already do this). Both-latched stays a defer, report-only, exactly as before.
      # The ladder's stderr flows to the pod log (homelab#443/#568 — $() captures stdout only,
      # so suppressing it discarded the latch's window/semaphore diagnostics during exactly the
      # latched runs that need them). SUBSCRIPTION_TIER=dispatch: same consumer tier the
      # non-worker sites use.
      rail="$(SUBSCRIPTION_TIER=dispatch bash "$HERE/subscription-latch.sh" --pick-rail)" || rail=""
      if [ -z "$rail" ]; then
        echo "→ ${PROJECT} claude-tier dispatch deferred — both rails latched (FU-088)"
        exit 0
      fi
      # Go rail picked: thread its model through the PR#407 _claude_model plumbing — the pod
      # command was baked above with the dispatched model, so re-point it at the Go rail's id
      # (the pre-override token is captured first: _claude_model takes the rail id below and can
      # no longer serve as the match pattern; the nounset guard keeps the block composable where
      # RUN_CMD has not been built — recipe-less /--run dispatches, the replay harnesses).
      case "$rail" in
        opencode-go/*)
          # Thread the Go rail's model into the pod command, and NEVER announce a rail the pod
          # will not serve: the recipe/worker shape already carries `--model <id> ` (swap it in
          # place), the --run shape (retro, retro-session.sh:104) has no --model flag at all
          # (insert one after `claude -p `), and a command that is neither shape DEFERS rather
          # than dispatch a mis-served pod (#439 leg 2 finding 2 — a no-op substitution used to
          # send a false 'on the Go rail' ride against the still-latched Anthropic API).
          _old_model="${_claude_model:-haiku}"
          _claude_model="$rail"
          _new_cmd="${RUN_CMD:-}"
          _new_cmd="${_new_cmd//--model ${_old_model} /--model ${_claude_model} }"
          case "$_new_cmd" in
            *"--model ${_claude_model} "*) ;;   # recipe/worker shape: the substitution took
            *"claude -p "*)                     # --run shape: no --model flag at all — insert one
              _new_cmd="${_new_cmd/claude -p /claude -p --model ${_claude_model} }";;
            *)                                  # neither shape: never announce a rail the pod will not serve
              echo "→ ${PROJECT} claude-tier dispatch deferred — Anthropic latched and the Go rail's model could not be threaded into the pod command (FU-088)"
              exit 0;;
          esac
          # The pre-failover command was baked without the Go window env (the dispatched model
          # was Anthropic-known); prepend it now so the threaded ride doesn't auto-compact at
          # the harness's 200k unknown-model default. ⚠ Window table DUPLICATED from the
          # harness-run-cmd clause (rationale there) — replay clauses run self-contained.
          case "$rail" in opencode-go/deepseek-v4-flash) _ctx_env="CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000 ";; *) _ctx_env="";; esac
          if [ -n "$_ctx_env" ]; then
            case "$_new_cmd" in
              *CLAUDE_CODE_MAX_CONTEXT_TOKENS=*) ;;
              *) _new_cmd="${_new_cmd/claude -p /${_ctx_env}claude -p }";;
            esac
          fi
          RUN_CMD="$_new_cmd"
          # PR#528 review round 3: the threading re-pointed the pod COMMAND, but SUB_LABEL/AGENT_RAIL
          # (and the manifest's MODEL env) were computed above from the PRE-failover MODEL — the
          # FU-088 semaphore would still count this Go-served ride against the Anthropic slots it
          # never draws, and the #158 outage-cost store would not see the Go rail. Override them on
          # the proven-threaded path only (the un-threadable defer above never reaches here),
          # mirroring the RAIL_DEGRADED pattern — :418-420 runs before the label block and propagates
          # cleanly; this failover runs after it, so the overrides must be explicit.
          # STRUCK_MODEL is deliberately NOT synced here (#660 acceptance; PR#668 arbitration).
          # The pre-degrade entry is the one that was dispatched and found unavailable — that is
          # what the strike must name, so the coordinator's chain walk skips it and keeps the
          # fallback. Syncing to the fallback IS the #652 defect. The tier-default rewrite above
          # is the opposite shape (a placeholder default → the model that runs) and does sync.
          MODEL="$rail"
          # PR#643 r1: GOOSE_MODEL was computed at :~1182 from the PRE-failover MODEL and feeds
          # the pod manifest env the strike/stats readers compare — the same MODEL-vs-GOOSE_MODEL
          # divergence #629 fixed on the opencode-go/* arm, sibling instance.
          GOOSE_MODEL="$rail"
          SUB_LABEL=', "homelab.teststuff.net/rail": opencode-go'
          AGENT_RAIL="opencode-go"
          echo "→ Anthropic latched — serving ${PROJECT} on the Go rail ($rail)"
          ;;
      esac;;
  esac
fi

# FU-088(b): account-level OpenRouter credit gate — credit exhaustion otherwise surfaces only as
# per-pod 402 retry storms AFTER spawn (agent-runtime#8 hard-stops in-pod; this saves the spawn).
# The read itself moved UP to the homelab#158 rail-degrade block (one unauthenticated curl per
# dispatch against the proxy's /router-status, no key material either way, fail-open — and since
# homelab#190 fail-open LOUDLY, one line there) — because a fact this gate can only defer on is a
# fact the degrade can ACT on, and it has to be known before the harness is fixed. What remains
# here is the gate: everything that did NOT degrade (opted out, non-fix ride, or a stack that
# strictly waits) defers exactly as it did before. `OR_CREDITS` empty = no usable balance = this
# gate does not fire; it is never treated as $0.
if [ "$HARNESS" != "claude" ] && [ -n "$PROXY_URL" ] && [ "${AGENT_CREDIT_GATE:-1}" = "1" ] \
   && [ -n "$OR_CREDITS" ] && awk -v c="$OR_CREDITS" -v m="$OR_MIN" 'BEGIN { exit !(c < m) }'; then
  echo "→ ${PROJECT} dispatch deferred — OpenRouter account credit \$${OR_CREDITS} below the \$${OR_MIN} floor (FU-088b; top up, or OPENROUTER_MIN_CREDIT / AGENT_CREDIT_GATE=0 to override)"
  exit 0
fi
# <<<REPLAY:fu088-gates<<<

# The atomic gate: reap a TERMINAL same-key holder, refuse a LIVE one, then `create` (NOT apply —
# apply would silently adopt/patch an existing pod and the whole idempotency story dies).
case "$TASK" in issue-[0-9]*|pr-[0-9]*)
  EXISTING_PHASE="$("$KUBECTL" $KUBE -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "$EXISTING_PHASE" in
    Succeeded|Failed)
      echo "→ reaping terminal same-key pod ${POD} (${EXISTING_PHASE}) before re-dispatch"
      "$KUBECTL" $KUBE -n "$NS" delete pod "$POD" --ignore-not-found >/dev/null 2>&1 || true;;
    "") :;;  # no holder — create proceeds
    *)
      echo "PREFLIGHT REFUSED: pod ${POD} already ${EXISTING_PHASE} — (task=${TASK}, round=${ROUND}) is owned; resume/wait, don't fork (workflow.md idempotency key)." >&2
      exit 3;;
  esac
;; esac
# FU-160 phase 1 of 2. Everything above this line is the launcher's DETERMINISTIC dispatch cost —
# the router consult, the rail probe, the card + recipe build, the pre-flight guards, the
# subscription latch, the credit gate, the stack-cache probe, the argv ceiling. It closes here
# because past this point a pod exists and the cost stops being ours.
run_phase dispatch-gates
cat <<EOF | "$KUBECTL" $KUBE -n "$NS" create -f - \
  || { echo "PREFLIGHT REFUSED (atomic): create of ${POD} failed — a racing dispatcher won the (task, round) key, or the manifest is invalid (see kubectl error above)." >&2; exit 3; }
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  labels: { app: agent-session, project: ${PROJECT}${SUB_LABEL} }
spec:
  restartPolicy: Never
  # homelab#22: total-session wall clock. No bound existed (200 turns × ~5min slow-model turns
  # ≈ 16h theoretical); 4h matches the session key's TTL (estimate_budget.py --ttl-hours) — past
  # it the ride can only 401-storm anyway. K8s kills with reason DeadlineExceeded; the launcher
  # classifier below maps that to a \`timeout\` strike, so the chain re-dispatches on the next model.
  # (FU-128: backticks in THIS comment must stay escaped — it is inside the unquoted pod-manifest
  # heredoc, so the shell command-substitutes them at expansion time, comment or not.)
  activeDeadlineSeconds: ${AGENT_POD_DEADLINE_S:-14400}
  # FU-089: the worker's PROVABLE identity — the proxy's /git-token TokenReviews this SA's
  # projected token (Composition renders the SA per fixer ns; no RBAC grants attached).
  serviceAccountName: agentstack-worker
  terminationGracePeriodSeconds: 5
  # FU-136 / homelab#919: non-docker rides (goose, claude, opencode) need the ephemeral-tier
  # toleration to schedule onto the compute/burst nodes (wk-metal-01..04, wk-03) that carry
  # homelab.io/ephemeral=true:NoSchedule. Docker rides get this via kata RuntimeClass already.
  # The AVX2 nodeAffinity (opencode only) is orthogonal — goose/claude run fine on non-AVX2 nodes.
  tolerations:
    - key: homelab.io/ephemeral
      operator: Equal
      value: "true"
      effect: NoSchedule
${AFFINITY}
${KATA_BLOCK}
${HOST_ALIASES}
  securityContext:
    fsGroup: 1000          # make the shared uv-cache RWX volume writable for the non-root (1000) user
${DIND_CONTAINER}
  containers:
    - name: agent
      image: ${IMAGE}
      args: ${ARGS}
      env:
        # devbox self-update phone-home (releases.jetify.com) is DENIED by the egress CNP —
        # correctly, but 3 drops/min per ride kept AgentWorkerEgressDropped warm (2026-07-21).
        # Disable the check instead of widening policy for telemetry. 2026-07-22: the update-check
        # var alone did NOT silence it (live drops to 104.18.18/19.165:443 = releases.jetify.com
        # from a ride that HAD the var) — devbox telemetry is a separate phone-home; belt both.
        - name: DEVBOX_NO_UPDATE_CHECK
          value: "1"
        - name: DO_NOT_TRACK
          value: "1"
        - name: DEVBOX_DISABLE_TELEMETRY
          value: "1"
        # opencode-1.18.18: SDK init fetches to models.opencode.ai + registry.npmjs.org are
        # not suppressible on the pinned build (tested 2026-08-26: no knob found). OPENCODE_DISABLE_AUTOUPDATE
        # silences the periodic autoupdate check only, not one-time SDK init fetches. The CNP Policy DENY
        # to models.opencode.ai + registry.npmjs.org is the intended backstop (homelab#792, #456 r2).
        # These are expected drops per PR #503 doctrine (kill at tool, not extraFQDNs).
        - name: OPENCODE_DISABLE_AUTOUPDATE
          value: "1"
        # homelab#1247 (the #1190 caller hunt): scripts/mermaid-lint.sh's \`npm ci\` ran a full
        # registry install on every md-touching homelab ride (~12k POLICY_DENIED/24h — the CNP
        # denies npmjs correctly; the hostAliases fast-fail stub did not stop the retry storm).
        # Kill at the tool per PR #503 doctrine: the script skips the install (and the lint,
        # loudly) under this var when node_modules is not already populated — GitHub CI, which
        # never sets it, stays the real gate. Unconditional like its siblings: only homelab's
        # diff-ci reaches the script today, but the emitter rides along whichever repo runs it.
        - name: MERMAID_LINT_NO_INSTALL
          value: "1"
        # 2026-08-08 (operator + the homelab#107 21:35Z triage, same conclusion): uv with an
        # unpinned python-preference FETCHES A MANAGED CPython from releases.astral.sh even when
        # devbox already provisions an interpreter satisfying the project's constraint — ~272
        # POLICY_DENIED drops in one night from oracle-fleet rides. Kill at the tool, not the
        # allowlist: only-system makes uv reuse the devbox interpreter; a repo whose constraint
        # the devbox python cannot satisfy now fails LOUDLY ("no matching interpreter") and the
        # fix is that repo's devbox pin — never a per-ride WAN fetch of an unpinned binary.
        - name: UV_PYTHON_PREFERENCE
          value: "only-system"
        # 2026-08-02, third phone-home path: the /usr/local/bin/devbox LAUNCHER (jetify's wrapper
        # script) ignores all of the above — without DEVBOX_USE_VERSION it re-downloads
        # releases.jetify.com/devbox/stable/version whenever ~/.cache/devbox/current-version is
        # older than VERSION_CACHE_TTL (24h default; the devbox-cache PVC keeps the file, so it
        # goes stale between image builds and EVERY ride's first devbox call phones home). A year
        # of TTL pins the launcher to the cached version without hardcoding it here.
        - name: VERSION_CACHE_TTL
          value: "31536000"
        # FU-118(b): \`devbox add\` resolves through the in-cluster search proxy (VIP, kata-reachable
        # like the other package proxies) instead of the WAN — so a mid-ride add gets a REAL store
        # path in devbox.lock, not the offline \`placeholder-*\` that boot-crashes the next round.
        # (FU-128: escaped backticks — unquoted heredoc, see the activeDeadlineSeconds comment.)
        # argocd/resources/devbox-search/ + ip-plan.md; the egress CNP allows .40.27 (composition.yaml).
        - name: DEVBOX_SEARCH_HOST
          value: "http://192.168.40.27"
        - name: REPO_URL
          value: "${REPO_URL}"
        - name: BASE_REF
          value: "${BASE_REF}"
        - name: HARNESS
          value: "${HARNESS}"
        # Stats context for agent-finalize (project label + which node it ran on).
        - name: PROJECT
          value: "${PROJECT}"
        # FU-095 P1 coverage: agent-finalize POSTs the run report to the router itself (the
        # launcher's POST /report twin) — coordinator-path rides have no attending launcher, so
        # without this their outcomes never reach the shadow-decision store. Stack resolution
        # stays LAUNCHER-owned (the pod has no homelab checkout).
        - name: AGENT_STACK
          value: "${REPORT_STACK}"
        # homelab#158: the rail this ride actually buys its tokens on — \`subscription-fallback\` marks a
        # ride the OpenRouter outage pushed onto the subscription, so its cost lands VISIBLY
        # instead of looking like a free lunch. Three surfaces, deliberately: the pod label (live,
        # queryable now), this env (for agent-finalize to fold into AGENT_RUN_STATS — the
        # agent-runtime half, not shipped here), and the launcher's POST /report field below.
        - name: AGENT_RAIL
          value: "${AGENT_RAIL}"
        - name: AGENT_REPORT_URL
          value: "${PROXY_URL:+${PROXY_URL}/report}"
        # FU-134: the platform web-research endpoint, named in the env card. An env var rather than a
        # literal in the card text because the VIP/DNS form differs per ride (kata guests cannot
        # reach ClusterIPs — FU-072), and the card must never print an address this pod cannot use.
        - name: AGENT_SEARCH_URL
          value: "${PROXY_URL:+${PROXY_URL}/search}"
        - name: NODE_NAME
          valueFrom:
            fieldRef: { fieldPath: spec.nodeName }
        # §A1 transcript capture context: agent-finalize uploads run.log + the goose session dir +
        # manifest.json to s3://agent-transcripts/<project>/<task>/worker-r<round>-<ts>/. The key is
        # write-only (append-only exhaust; no list/get) and injected as VALUES — see the fetch above.
        - name: AGENT_TASK
          value: "${TASK}"
        - name: AGENT_ROUND
          value: "${ROUND}"
        # Retro r1 F6: dispatch timestamp — finalize records queue_wait_s = dispatch → pod
        # start, so ledger wall times stop conflating queue with compute.
        - name: AGENT_DISPATCH_EPOCH
          value: "$(date +%s)"
        - name: AGENT_SESSION_KEY
          value: "${SECRET}"
        - name: AGENT_TS_ENDPOINT
          value: "${TS_ENDPOINT}"
        - name: AGENT_TS_BUCKET
          value: "${TS_BUCKET}"
        # FU-080 (a): the write-only transcripts key is mirrored INTO each fixer namespace by the
        # AgentStack Composition (ClusterSecretStore agent-transcripts) — referenced in-ns, so the
        # launcher never touches key material. optional:true = a namespace without the mirror
        # (claim not synced yet) still runs; agent-finalize skips the upload loudly.
        - name: AGENT_TS_ACCESS_KEY_ID
          valueFrom:
            secretKeyRef: { name: agent-transcripts-s3, key: writer_access_key_id, optional: true }
        - name: AGENT_TS_SECRET_ACCESS_KEY
          valueFrom:
            secretKeyRef: { name: agent-transcripts-s3, key: writer_secret_access_key, optional: true }
        # FU-057 §B1: agent-finalize PUTs this run's cost/duration/outcome here (goose has no OTLP
        # rail). Cross-namespace to the monitoring pushgateway; unset it to disable the push.
        - name: AGENT_PUSHGATEWAY_URL
          value: "${PGW_URL}"
        # goose reads provider+model from env; opencode auto-detects OPENROUTER_API_KEY and takes
        # the model as the full vendor/model id (e.g. \`openrouter/vendor/model\`). Using the
        # stripped MODEL id (e.g. \`-m \$MODEL\`) silently falls back to opencode's default.
        - name: GOOSE_PROVIDER
          value: "openrouter"
        - name: GOOSE_MODEL
          value: "${GOOSE_MODEL}"
        # goose→OpenRouter via the ADR-081 egress proxy (emitted only for goose, see above).
${GOOSE_PROXY_ENV}
        - name: MODEL
          value: "${MODEL}"
        # Per-session opencode provider pin (FU-018 interim, emitted ONLY when the pin config is
        # written by the command prefix above — same couple-the-two rule as UV_ENV below).
${OC_ENV}
        # Persistent uv wheel cache: env emitted ONLY when the agent-uv-cache PVC is mounted (UV_ENV),
        # so an unmounted /uv-cache never gets set as the cache dir. See the UV_ENV note above.
${UV_ENV}
        # Auto-approve tool calls: a headless --run recipe has no TTY to confirm at, so without this
        # goose blocks forever. The pod is the isolation boundary, so autonomy here is the point.
        - name: GOOSE_MODE
          value: "auto"
        # Second belt behind the runtime storm watchdog (agent-runtime#8 + the goose storm watchdog, docs/agents/model-routing.md §The bundle — both proven
        # live on sleep-tracking#20): on a dead key goose's final-output continuation loops fresh
        # requests until max_turns (default 1000). 200 clears every legit run measured (owl 72,
        # the pathological qwen loop 187) and bounds anything the watchdog somehow misses.
        - name: GOOSE_MAX_TURNS
          value: "${GOOSE_MAX_TURNS:-200}"
${OR_KEY_ENV}
        # Git credential (ADR-087 leg B / FU-089): the pod holds NO git token — the entrypoint's
        # credential helper + gh wrapper fetch a live token per operation from the proxy's
        # /git-token endpoint, which TokenReviews the pod's SA (GIT_TOKEN_REQUIRE_AUTH=1). The
        # old standing in-ns agent-git-token fallback was deleted with FU-089.
${CRED_BROKER_ENV}
        # Ledger-backfill anchor (FU-057): the operator writes the OpenRouter key HASH into the
        # session Secret; finalize surfaces it in stats so cost_unknown runs stay accountable.
        - name: OPENROUTER_KEY_HASH
          valueFrom:
            secretKeyRef: { name: ${SECRET}, key: KEY_HASH, optional: true }
        # Resume an existing remote branch deterministically (fix rounds / salvaged WIP — finding C).
        # Empty ⇒ the entrypoint forks a fresh agent/<ts> branch from BASE_REF as before.
${WORK_BRANCH_ENV}
${ARM_ENV}
        # platform retro ride only (homelab#587 leg 2): fleet-wide READ-ONLY token, emitted only
        # when the launcher's own environment carries it. See RETRO_GH_TOKEN_ENV above.
${RETRO_GH_TOKEN_ENV}
        # docker mode only: the repo's own docker CLI (devbox.json) talks to the dind sidecar.
${DOCKER_ENV}
        # claude harness only (FU-066): proxy base URL + the opaque session ref — no real creds.
${CLAUDE_ENV}
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000           # jetpackio/devbox 'devbox' user; numeric so k8s can verify non-root
        runAsGroup: 1000
        allowPrivilegeEscalation: false
        capabilities: { drop: ["ALL"] }
        seccompProfile: { type: RuntimeDefault }
      resources:
        requests: ${AGENT_REQUESTS}
        limits:   ${AGENT_LIMITS}
      volumeMounts:${UV_MOUNT}${DOCKER_MOUNT}${SC_MOUNT}
  volumes:${UV_VOLUME}${DOCKER_VOLUMES}${SC_VOLUME}
EOF

echo "→ waiting for ${POD} (a cold node may pull the image + nix store for minutes)…"
"$KUBECTL" $KUBE -n "$NS" wait --for=condition=Ready pod/"${POD}" --timeout=600s || true
# FU-160 phase 2 of 2 — the LAST phase the launcher owns, and the one the spike was written for:
# schedule + image pull + container start. Everything after this line is measured from INSIDE the
# pod (`source="in-pod"`), because that is the only process guaranteed to still be alive for it.
# `|| true` above means a pod that never became Ready closes this phase at the 600s timeout
# rather than never closing it — a 600s bar is itself the finding, so the value is kept, not
# suppressed. This is the number that makes "was the image node-cached?" answerable while it is
# still true, instead of after the events have aged out.
run_phase pod-spinup

if [ -n "$RUN_CMD" ]; then
  # Follow logs to termination — resiliently. `logs -f` FAILS while the container is still
  # ContainerCreating (slow image pull), and under set -e + pipefail that used to kill the launcher
  # before ANY post-run bookkeeping — i.e. exactly the runs the strike path exists for died
  # untracked (found live: the storm-watchdog acceptance run, 2026-07-09). Retry while the pod is
  # Pending/Running; a clean `logs -f` exit means the container terminated. Each attempt restreams
  # from the start, so plain tee keeps RUNLOG = one complete copy.
  RUNLOG="$(mktemp)"
  DEADLINE=$(( $(date +%s) + ${AGENT_LOG_DEADLINE_S:-1800} ))
  while :; do
    if "$KUBECTL" $KUBE -n "$NS" logs -f "${POD}" 2>/dev/null | tee "$RUNLOG"; then break; fi
    PHASE="$("$KUBECTL" $KUBE -n "$NS" get pod "${POD}" -o jsonpath='{.status.phase}' 2>/dev/null || echo Gone)"
    case "$PHASE" in
      Pending|Running|Unknown) ;;
      *) break ;;   # Succeeded/Failed/Gone — grab whatever logs exist below and move on
    esac
    if [ "$(date +%s)" -ge "$DEADLINE" ]; then
      echo "→ gave up following ${POD} after $((${AGENT_LOG_DEADLINE_S:-1800}/60))min (phase: ${PHASE}) — bookkeeping continues on partial logs"
      break
    fi
    sleep 5
  done
  # Terminal-but-empty (pod failed before/without streaming): one non-follow dump so the
  # classification below has something to read.
  [ -s "$RUNLOG" ] || "$KUBECTL" $KUBE -n "$NS" logs "${POD}" > "$RUNLOG" 2>/dev/null || true
  echo "→ run finished. delete with: kubectl -n ${NS} delete pod ${POD}"
  # FU-160 / homelab#324: NO `run_phase ride` here, and the absence is the fix. Reaching this line
  # means the launcher outlived the ride — which happened on 5 of 24 measured rides, so a phase
  # closed here would be a sample of the rides that let the launcher live, presented as a fleet
  # median. The interior of the envelope arrives from inside the pod instead
  # (`agent_run_phase_seconds{source="in-pod"}`, agent-runtime#66) on every ride, including the
  # ones this process never sees the end of. Emitter header has the measurements.

  # End-of-session stats: agent-finalize emitted one AGENT_RUN_STATS json line into the logs (cost,
  # duration, model, and the recipe's outcome). Echo it, and if a PR was opened, post it as a PR
  # comment with a Grafana Explore deep-link to THIS pod's logs — so reviewing the PR is one click
  # from both the stats and the full run logs (no more guessing the pod name). Posted from here (the
  # jail GH_TOKEN can comment) rather than the pod (scoped agent token may lack issues:write).
  STATS="$(grep -ao 'AGENT_RUN_STATS .*' "$RUNLOG" | tail -1 | sed 's/^AGENT_RUN_STATS //')"
  PR_URL=""
  if [ -n "$STATS" ]; then
    echo "→ stats: $STATS"
    PR_URL="$(printf '%s' "$STATS" | jq -r '.pr_url // empty' 2>/dev/null)"
    # FU-064/FU-043: bookkeeping now runs IN-POD (agent-finalize) so it survives this launcher
    # exiting early (the coordinator path). Everything below is the FALLBACK for pre-mount images /
    # in-pod failures — the *_by_pod flags on the stats line say what already happened.
    ARMED_BY_POD="$(printf '%s' "$STATS" | jq -r '.armed_by_pod // false' 2>/dev/null)"
    COMMENT_BY_POD="$(printf '%s' "$STATS" | jq -r '.stats_comment_by_pod // false' 2>/dev/null)"
    STRIKE_BY_POD="$(printf '%s' "$STATS" | jq -r '.strike_by_pod // false' 2>/dev/null)"
    # --no-arm rides (research, FU-105/FU-126): "not armed" IS the desired end state — the pod's
    # armed_by_pod=false is BY DESIGN, not an in-pod failure, and must never trip this fallback.
    # Observed live 2026-08-03: the circles fan-out's research PRs #2/#3 were armed by this leg
    # (defeating the human gate, hand-disarmed) and got double stats comments.
    ARM_SATISFIED="$ARMED_BY_POD"
    [ -n "${NO_ARM:-}" ] && ARM_SATISFIED="true"
    if [ "$ARM_SATISFIED" = "true" ] && [ "$COMMENT_BY_POD" = "true" ]; then
      echo "→ PR bookkeeping done in-pod (armed-or-no-arm + stats comment) — launcher fallback skipped"
      PR_BOOKKEEPING_DONE=1
    else
      PR_BOOKKEEPING_DONE=""
    fi
    if [ -n "$PR_URL" ] && [ -z "$PR_BOOKKEEPING_DONE" ] && [ -n "${GH_TOKEN:-}" ]; then
      # ARM AUTO-MERGE — mandatory post-PR step (docs/agents/merge-path.md §Chosen design ▸1).
      # The deterministic merge path only ever touches auto-merge-armed PRs: the updater keeps armed PRs
      # current, the review reflex only reviews armed PRs, and GitHub completes an armed PR the moment
      # approval + CI land. An un-armed PR is invisible to all of it and stalls. Squash keeps master linear
      # (matches the reviewer-session.sh header + repos.tf squash config). Idempotent — re-arming is a no-op.
      if [ -n "${NO_ARM:-}" ]; then
        echo "→ arming SKIPPED (--no-arm — human-gated PR; comment fallback only)"
      else
        echo "→ arming auto-merge (squash) on ${PR_URL}"
        gh pr merge "$PR_URL" --auto --squash 2>&1 | tail -1 || echo "  (arm failed — non-fatal; coordinator re-arms in step 6)"
      fi
      GRAFANA_URL="${GRAFANA_URL:-https://grafana.teststuff.net}"
      PANES="$(jq -cn --arg pod "$POD" '{ag:{datasource:"loki",queries:[{refId:"A",expr:("{pod=\""+$pod+"\"}"),datasource:{type:"loki",uid:"loki"}}],range:{from:"now-6h",to:"now"}}}')"
      LOGS_URL="${GRAFANA_URL}/explore?schemaVersion=1&orgId=1&panes=$(jq -rn --arg p "$PANES" '$p|@uri')"
      # CHANNEL SEPARATION (ADR-103 rule 2, homelab#210). This table used to be a NEW PR comment
      # every round — one of the two biggest per-PR residue sources the 2026-08-09 census found. It
      # is now a check-run (detail, in the checks tab) plus ONE appended line on the single
      # `<!-- agent-summary -->` comment (index, in the timeline). Nothing is lost: the ledger and
      # the S3 transcript copy already hold all of it.
      #
      # ⚠ THIS IS THE FALLBACK EMITTER, NOT THE ONLY ONE. agent-finalize posts the same thing
      # in-pod on every ride that reaches it (`stats_comment_by_pod`); this leg runs only for
      # pre-mount images and in-pod failures. Its channel MUST stay identical to the finalize-side
      # conversion in agent-runtime#62 — if one moves and the other does not, the old comment shape
      # returns on every fallback ride, which is the "two emitters, one channel" twin of the trap
      # #210's reader audit warns about.
      BODY="$(printf '%s' "$STATS" | jq -r --arg logs "$LOGS_URL" --arg task "$TASK" '
        "| metric | value |\n|---|---|\n" +
        "| model | `\(.model // "?")` (\(.harness // "?")) |\n" +
        "| cost | $\(.cost_usd // 0) |\n" +
        "| duration | \(.duration_s // 0)s |\n" +
        "| reproduced | \(.reproduced // "?") |\n" +
        "| ci_passed | \(.ci_passed // "?") |\n" +
        "| error_class | `\(if ((.error_class // "") == "") then "clean" else .error_class end)` |\n" +
        "| coverage | \(.coverage_pct // "?")% |\n" +
        "| node / pod | `\(.node // "?")` / `\(.pod // "?")` |\n\n" +
        "[📜 run logs in Grafana](\($logs))\n" +
        "🗂 transcripts: `s3://agent-transcripts/\(.project // "?")/\($task)/` · [viewer](https://transcripts.local.teststuff.net)"')"
      LINE="$(printf '%s' "$STATS" | jq -r --arg logs "$LOGS_URL" --arg task "$TASK" '
        "**run stats** — `\(.model // "?")` · $\(.cost_usd // 0) · \(.duration_s // 0)s · ci=\(.ci_passed // "?") · " +
        "[logs](\($logs)) · `s3://agent-transcripts/\(.project // "?")/\($task)/`"')"
      PR_SLUG="$(mc_slug_from_url "$PR_URL")"
      PR_SHA="$(gh pr view "$PR_URL" --json headRefOid -q '.headRefOid' 2>/dev/null || echo '')"
      echo "→ posting agent-ride check-run + summary line to ${PR_URL}"
      if mc_check_run "$PR_SLUG" "$PR_SHA" "agent ride — ${TASK}" "$BODY"; then
        mc_event "$PR_SLUG" "${PR_URL##*/}" stats "$LINE" || echo "  (summary line failed — non-fatal)"
      else
        # Check-runs are an App-only endpoint: a classic PAT cannot create one whatever its scopes,
        # and this leg runs jail-side where GH_TOKEN may be exactly that. Degrading to a SECOND
        # comment would undo the whole change, so the table rides into the one summary comment
        # instead — folded, so the timeline stays quiet.
        echo "  (check-run refused — folding the table into the summary comment instead)"
        mc_event "$PR_SLUG" "${PR_URL##*/}" stats \
          "$(printf '%s\n<details><summary>run stats (check-run unavailable — App-token-only endpoint)</summary>\n\n%s\n</details>' "$LINE" "$BODY")" \
          || echo "  (summary line failed — non-fatal)"
      fi
    fi
  fi

  # >>>REPLAY:post-merge-push>>>
  # POST-MERGE-PUSH DETECTOR (homelab#1212): if this ride's PR merged during the run and its head
  # branch received commits after mergedAt, emit ONE loud marker naming the branch so the stranded
  # work is salvageable by --work-branch (acceptance 1+2). The finalize-side refusal leg (refuse a
  # push whose PR is already merged) rides agent-runtime#66 and is NOT in this checkout.
  if [ -n "$PR_URL" ] && [ -n "${GH_TOKEN:-}" ]; then
    PR_STATE="$(gh pr view "$PR_URL" --json state,mergedAt,headRefName -q '{state,mergedAt,headRefName}' 2>/dev/null || echo '')"
    if [ -n "$PR_STATE" ]; then
      _state="$(printf '%s' "$PR_STATE" | jq -r '.state // empty' 2>/dev/null)"
      _merged_at="$(printf '%s' "$PR_STATE" | jq -r '.mergedAt // empty' 2>/dev/null)"
      _head_ref="$(printf '%s' "$PR_STATE" | jq -r '.headRefName // empty' 2>/dev/null)"
      if [ "$_state" = "MERGED" ] && [ -n "$_merged_at" ] && [ -n "$_head_ref" ]; then
        # Derive the repo slug (owner/repo) from REPO_URL before the branch probe.
        _slug="${REPO_URL#https://github.com/}"; _slug="${_slug%.git}"
        # Check if the head branch still exists (it may have been auto-deleted on merge).
        # If it exists, check whether its latest commit post-dates the merge.
        _branch_info="$(gh api "repos/${_slug}/branches/${_head_ref}" --jq '.commit.commit.author.date // empty' 2>/dev/null || echo '')"
        if [ -n "$_branch_info" ]; then
          _merged_ts="$(date -d "$_merged_at" +%s 2>/dev/null || echo 0)"
          _branch_ts="$(date -d "$_branch_info" +%s 2>/dev/null || echo 0)"
          if [ "$_branch_ts" -gt "$_merged_ts" ] 2>/dev/null; then
            echo "⚠️  POST-MERGE PUSH DETECTED: PR ${PR_URL} merged at ${_merged_at} but branch ${_head_ref} received commits after merge — stranded work is salvageable via --work-branch ${_head_ref}"
            # Emit ONE loud marker on the issue so the coordinator / human sees it.
            _issue_n=""
            case "$TASK" in issue-[0-9]*) _issue_n="${TASK#issue-}";; esac
            if [ -n "$_issue_n" ] && [ -n "$_slug" ]; then
              gh issue comment "$_issue_n" --repo "$_slug" \
                --body "⚠️ **POST-MERGE PUSH DETECTED** — PR ${PR_URL} merged at \`${_merged_at}\` but branch \`${_head_ref}\` received commits after merge. Stranded work is salvageable via \`--work-branch ${_head_ref}\`." \
                2>&1 | tail -1 || echo "  (post-merge-push comment failed — non-fatal)"
            fi
          fi
        fi
      fi
    fi
  fi
  # <<<REPLAY:post-merge-push<<<

  # >>>REPLAY:strike-scope>>>
  # STRIKE BOOKKEEPING (FU-062, docs/agents/model-routing.md §M1): a run that terminates with a
  # harness death is an infra strike candidate — classify it and post ONE structured comment to the ISSUE.
  # That comment IS the strike store: state lives in GitHub, and the coordinator greps `AGENT_STRIKE:`
  # in issue comments to blacklist the model for this task and pick the next chain entry. Keep the first
  # line's format STABLE — it's the machine interface. Strike semantics apply only to TASKED rides
  # (issue-*/pr-*) — an adhoc ride (validation, experiment) expects no constraints; striking it is noise
  # (the finalize-side twin landed in agent-runtime#16 the same day). homelab#866: a harness death is
  # defined by its signature (config-invalid, provider-5xx, etc), not by PR-absence. A fix round on an
  # existing PR can die in its harness and must emit a strike to avoid mis-classifying it as a clean
  # round (which would escalate the PR to arbitrate, costing a coordinator ride to re-derive "never ran").
  case "$TASK" in issue-*|pr-*) STRIKE_APPLIES=1;; *) STRIKE_APPLIES="";; esac
  if [ -n "$STRIKE_APPLIES" ] && [ "${STRIKE_BY_POD:-false}" != "true" ]; then
    # >>>REPLAY:strike-classifier>>>
    if [ -n "$STATS" ]; then
      # >>>REPLAY:strike-stats-classifier>>>
      # agent-finalize already classified the run (authoritative — it saw the full log + exit code).
      # Its exit_status maps onto the strike taxonomy; anything else (failed/no-output/ci-failed) is
      # "unknown" — still a strike if not covered by a more specific signature, just an unclassified one.
      # homelab#804: when the exit_status is "failed" (harness exited non-zero with no matching
      # failure signature), check the run log for a config validation error — the opencode binary
      # rejects unknown config keys at startup and the pod dies in under 15s at zero cost. Map
      # that class of death to harness-death so the coordinator strikes the model instead of
      # treating the round as "unknown" (which re-dispatches on the same broken config).
      ERR_CLASS="$(printf '%s' "$STATS" | jq -r '
        (.exit_status // "") as $s
        | if $s == "no-artifact" then (.error_class // "no-pr")
          elif $s == "budget-403" then ({"budget-exhausted-key":"budget-403-key","budget-exhausted-account":"budget-403-account","http-403-other":"http-403-other"}[.error_class // ""] // "budget-403")
          elif (["harness-death","auth-storm","timeout"] | index($s)) then $s
          else "unknown" end' \
        2>/dev/null || echo unknown)"
      if [ "$ERR_CLASS" = "unknown" ] && grep -qiE 'Configuration is invalid|Unrecognized key' "$RUNLOG" 2>/dev/null; then
        ERR_CLASS="harness-death"
      fi
      # homelab#866: provider-5xx error signature (harness-side UnknownError from the model API).
      # Zero cost, sub-30s duration, no new artifact — a startup death like config-invalid.
      if [ "$ERR_CLASS" = "unknown" ] && grep -qE '"name":\s*"UnknownError"|Unexpected server error' "$RUNLOG" 2>/dev/null; then
        ERR_CLASS="harness-death"
      fi
      # <<<REPLAY:strike-stats-classifier<<<
    else
      # No AGENT_RUN_STATS line at all = finalize never ran (the pod died hard / wait timed out) —
      # Classify the raw log jail-side with the same signatures agent-finalize uses (that script is
      # the authoritative copy of these patterns). homelab#22: an activeDeadlineSeconds kill leaves
      # no log signature at all — the pod's status.reason is the only evidence, and it maps to the
      # `timeout` strike class.
      # >>>REPLAY:strike-quota-classifier>>>
      POD_REASON="$("$KUBECTL" $KUBE -n "$NS" get pod "$POD" -o jsonpath='{.status.reason}' 2>/dev/null || true)"
      if [ "$POD_REASON" = "DeadlineExceeded" ]; then
        ERR_CLASS="timeout"
      # homelab#804: the opencode binary validates its config at startup and exits non-zero on
      # unknown/unsupported keys. A pod that dies before the LLM loop in under 15s at zero cost
      # with this signature is a harness-startup death — should never be classified "clean".
      elif grep -qiE 'Configuration is invalid|Unrecognized key' "$RUNLOG"; then
        ERR_CLASS="harness-death"
      elif grep -qiE -e '-32602|EOF while parsing|response may have been truncated|context_length_exceeded|panicked at' "$RUNLOG"; then
        ERR_CLASS="harness-death"
      # homelab#866: provider-5xx error signature (harness-side UnknownError from the model API).
      # Zero cost, sub-30s duration, no new artifact — a startup death like config-invalid.
      elif grep -qE '"name":\s*"UnknownError"|Unexpected server error' "$RUNLOG"; then
        ERR_CLASS="harness-death"
      elif grep -qiE '429.*quota|429.*limit|monthly.*limit.*reached|rate limit exceeded' "$RUNLOG"; then
        ERR_CLASS="quota"
      elif BUDGET_MATCH="$(grep -iE 'key limit exceeded' "$RUNLOG" | head -1)" && [ -n "$BUDGET_MATCH" ]; then
        ERR_CLASS="budget-403-key"
      elif BUDGET_MATCH="$(grep -iE 'insufficient (credit|fund)|402 payment|payment required|out of credit' "$RUNLOG" | head -1)" && [ -n "$BUDGET_MATCH" ]; then
        ERR_CLASS="budget-403-account"
      elif BUDGET_MATCH="$(grep -iE 'insufficient quota|quota exceeded|budget exceeded' "$RUNLOG" | head -1)" && [ -n "$BUDGET_MATCH" ]; then
        ERR_CLASS="budget-403"
      elif [ "$(grep -ciE 'authentication failed|401 unauthorized|403 forbidden|invalid api key|no auth credentials' "$RUNLOG")" -ge 3 ]; then
        ERR_CLASS="auth-storm"
      elif grep -qiE 'context deadline exceeded|request timed out|operation timed out' "$RUNLOG"; then
        ERR_CLASS="timeout"
      else
        ERR_CLASS="unknown"
      fi
      # <<<REPLAY:strike-quota-classifier<<<
    fi
    # <<<REPLAY:strike-classifier<<<
    # >>>REPLAY:strike-line-format>>>
    # FU-202 (homelab#1233): key-class error_class (budget-403-key, budget-exhausted-key) is a
    # mint defect, not a model strike — post a KEY-RETRY marker instead, so the coordinator's
    # chain-walk skips it and re-dispatches on the SAME model with a fresh session key.
    # homelab#866: the EMIT decision. A PR-less ride keeps FU-062 semantics unchanged — ANY
    # classified error strikes, `unknown` included (that is the chain-walk signal). A ride WITH
    # an open PR strikes only on a harness-death-class signature, because a clean round with a
    # PR classifies as `unknown` and must never strike.
    EMIT_STRIKE=""
    EMIT_KEY_RETRY=""
    case "$ERR_CLASS" in
      harness-death|auth-storm|timeout|quota|budget-403-account|http-403-other) EMIT_STRIKE=1;;
      budget-403-key|budget-exhausted-key) EMIT_KEY_RETRY=1;;
      budget-403) ;;  # residual — estimator/cap problem → escalate (neither strike nor key-retry)
    esac
    # PR-less ride: strike on any classified error (FU-062 semantics), EXCEPT key-class which
    # gets a KEY-RETRY marker instead (FU-202), and residual budget-403 which escalates.
    [ -n "${PR_URL:-}" ] || [ -n "$EMIT_KEY_RETRY" ] || [ "$ERR_CLASS" = "budget-403" ] || EMIT_STRIKE=1

    # A non-striking run must report an empty error_class, not "unknown" — a PR-present ride with
    # no specific signature must not be recorded as having an error. Inside the block on purpose:
    # this reset is behaviour replay has to pin, not control flow it may drop (PR #942 review).
    # FU-202: key-class errors keep their error_class for the KEY-RETRY marker.
    # Residual budget-403 keeps its error_class for the escalate path.
    [ -n "$EMIT_STRIKE" ] || [ -n "$EMIT_KEY_RETRY" ] || [ "$ERR_CLASS" = "budget-403" ] || ERR_CLASS=""
    # STRIKE_LINE is empty exactly when EMIT_STRIKE is unset, so the gate itself is extracted and
    # the composed replay script branches on it the way the shipped script does.
    STRIKE_LINE=""
    if [ -n "$EMIT_STRIKE" ]; then
      STRIKE_LINE="AGENT_STRIKE: model=${STRUCK_MODEL} error_class=${ERR_CLASS} round=${ROUND} session=${POD}"
      if [ -n "${BUDGET_MATCH:-}" ]; then
        STRIKE_LINE="${STRIKE_LINE} match=${BUDGET_MATCH}"
      fi
    fi
    # KEY_RETRY_LINE is the key-class equivalent — a marker, not a strike.
    KEY_RETRY_LINE=""
    if [ -n "$EMIT_KEY_RETRY" ]; then
      KEY_RETRY_LINE="KEY-RETRY: model=${STRUCK_MODEL} error_class=${ERR_CLASS} round=${ROUND} session=${POD}"
      if [ -n "${BUDGET_MATCH:-}" ]; then
        KEY_RETRY_LINE="${KEY_RETRY_LINE} match=${BUDGET_MATCH}"
      fi
    fi
    # <<<REPLAY:strike-line-format<<<
  fi

    # >>>REPLAY:router-report>>>
    # ROUTER REPORT (ADR-096, M5 attribution) — unconditional POST, runs for every run with
    # PROXY_URL set and STATS or ERR_CLASS defined. The session key ref (_keyref) is sent
    # in the Authorization header when non-empty (OpenRouter rail); subscription rides
    # (claude/*, *:claude/*, *:opencode-go/*) have empty _keyref and post without the header.
    # Issue #1268: the report carries the session key ref so the proxy can look up the
    # served provider from provider_events. The reply includes the resolved provider for
    # composing into strike/key-retry lines.
    _report_provider=""
    if [ -n "${PROXY_URL:-}" ] && { [ -n "${STATS:-}" ] || [ -n "${ERR_CLASS:-}" ]; }; then
      _rstack="$(jq -r --arg r "$PROJECT" '.stacks[]|select([.repos[]]|index($r))|.name' "${HERE}/stacks.json" 2>/dev/null | head -1)" || _rstack=""
      _report="$(jq -cn --arg session "$POD" --arg task "$TASK" --arg stack "${_rstack:-}" \
        --arg model "$MODEL" --arg round "$ROUND" --arg err "${ERR_CLASS:-}" --arg pr "$PR_URL" \
        --arg rail "${AGENT_RAIL:-}" \
        --argjson stats "${STATS:-null}" '
        {session: $session, task: $task, stack: $stack, role: "worker",
         round: ($round | tonumber? // 1), model: $model, rail: $rail,
         cost_usd: (($stats.cost_usd? // 0) | tonumber? // 0),
         error_class: (if $err != "" then $err else ($stats.error_class? // "") end),
         outcome: (if $pr != "" then "pr" else ($stats.exit_status? // "no-pr") end)}' 2>/dev/null)"
      if [ -n "$_report" ]; then
        if [ -n "${_keyref:-}" ]; then
          _reply="$(curl -fsS -m 5 -X POST -H 'Content-Type: application/json' \
            -H "Authorization: Bearer ref:$_keyref" \
            -d "$_report" "${PROXY_URL}/report" 2>/dev/null)" || _reply=""
        else
          _reply="$(curl -fsS -m 5 -X POST -H 'Content-Type: application/json' \
            -d "$_report" "${PROXY_URL}/report" 2>/dev/null)" || _reply=""
        fi
        if [ -n "$_reply" ]; then
          _report_provider="$(printf '%s' "$_reply" | jq -r '.provider // ""' 2>/dev/null || true)"
          echo "→ router report posted (${PROXY_URL}/report)"
        else
          echo "  (router report unreachable — non-fatal, jail runs land here)"
        fi
      fi
    fi
    # <<<REPLAY:router-report<<<
    # <<<REPLAY:strike-scope<<<

    if [ -n "$STRIKE_APPLIES" ] && [ "${STRIKE_BY_POD:-false}" != "true" ]; then
      # >>>REPLAY:strike-provider-append>>>
      # Provider append: source from /report reply, fall back to STATS for subscription rides.
      # FU-201 c (#1268): provider is sourced from the /report reply when available (the proxy
      # resolves it from provider_events via the session key ref). Falls back to STATS for
      # subscription rides that have no key ref. Absent a provider field, the strike still
      # records — the router sources it proxy-side from provider_events.
      _strike_provider="${_report_provider:-}"
      [ -n "$_strike_provider" ] || _strike_provider="$(printf '%s' "${STATS:-}" | jq -r '.provider // ""' 2>/dev/null || true)"
      [ -z "$STRIKE_LINE" ]    || [ -z "$_strike_provider" ] || STRIKE_LINE="${STRIKE_LINE} provider=${_strike_provider}"
      [ -z "$KEY_RETRY_LINE" ] || [ -z "$_strike_provider" ] || KEY_RETRY_LINE="${KEY_RETRY_LINE} provider=${_strike_provider}"
      # <<<REPLAY:strike-provider-append<<<

    if [ -n "$STRIKE_LINE" ]; then
      if [ -z "${PR_URL:-}" ]; then
        echo "→ no PR opened — ${STRIKE_LINE}"
      else
        echo "→ harness death with PR — ${STRIKE_LINE}"
      fi
      ISSUE_N=""
      case "$TASK" in issue-[0-9]*) ISSUE_N="${TASK#issue-}";; esac
      SLUG=""
      case "$REPO_URL" in https://github.com/*) SLUG="${REPO_URL#https://github.com/}"; SLUG="${SLUG%.git}";; esac
      if [ -n "$ISSUE_N" ] && [ -n "$SLUG" ] && [ -n "${GH_TOKEN:-}" ]; then
        # ~~~ fences (not ```) so backticks inside log lines can't break out of the block.
        STRIKE_BODY="$(printf '%s\n\n<details><summary>last 15 log lines (%s)</summary>\n\n~~~text\n%s\n~~~\n\n</details>\n' \
          "$STRIKE_LINE" "$POD" "$(tail -n 15 "$RUNLOG")")"
        echo "→ posting strike comment to ${SLUG}#${ISSUE_N}"
        gh issue comment "$ISSUE_N" --repo "$SLUG" --body "$STRIKE_BODY" 2>&1 | tail -1 \
          || echo "  (strike comment failed — non-fatal; the strike still shows in these logs)"
      else
        echo "  (no issue task / non-GitHub repo / no GH_TOKEN — strike not posted, logged above only)"
      fi
    fi
    if [ -n "$KEY_RETRY_LINE" ]; then
      echo "→ key-class failure — ${KEY_RETRY_LINE}"
      ISSUE_N=""
      case "$TASK" in issue-[0-9]*) ISSUE_N="${TASK#issue-}";; esac
      SLUG=""
      case "$REPO_URL" in https://github.com/*) SLUG="${REPO_URL#https://github.com/}"; SLUG="${SLUG%.git}";; esac
      if [ -n "$ISSUE_N" ] && [ -n "$SLUG" ] && [ -n "${GH_TOKEN:-}" ]; then
        KEY_RETRY_BODY="$(printf '%s\n\n<details><summary>last 15 log lines (%s)</summary>\n\n~~~text\n%s\n~~~\n\n</details>\n' \
          "$KEY_RETRY_LINE" "$POD" "$(tail -n 15 "$RUNLOG")")"
        echo "→ posting key-retry marker to ${SLUG}#${ISSUE_N}"
        gh issue comment "$ISSUE_N" --repo "$SLUG" --body "$KEY_RETRY_BODY" 2>&1 | tail -1 \
          || echo "  (key-retry marker failed — non-fatal; the marker still shows in these logs)"
      else
        echo "  (no issue task / non-GitHub repo / no GH_TOKEN — key-retry not posted, logged above only)"
      fi
    fi
  fi

  # FU-085: ring the coordinator doorbell — a tasked worker's terminal state is scan-actionable
  # (C4/C5 re-dispatch, strike chain-walk, C6 bookkeeping). Doorbell, never a work item: the scan
  # re-lists and re-applies the full predicate; a false wake costs `gh` calls, not an LLM tick.
  # Fail-open: unreachable off-cluster (jail runs — the cron backstop covers those).
  if [ -n "$STRIKE_APPLIES" ]; then
    # FU-080 doorbell routing: if PROJECT belongs to a GRADUATED stack, carry {stack,loop_ns} so the
    # global `coordinator` Sensor's per-stack trigger inlines a Workflow INTO <loop_ns> (data-driven).
    # Non-graduated / unresolvable → plain {repo} (the global scan handles it). Best-effort: a miss
    # only costs edge latency — the stack's */10 cron still ticks. loop_ns is <stack>-agents by convention.
    _grad="$(jq -r --arg r "$PROJECT" '.stacks[]|select((.graduated // false)==true)|select([.repos[]]|index($r))|.name' "${HERE}/stacks.json" 2>/dev/null | head -1)"
    if [ -n "$_grad" ] && [ "$_grad" != "null" ]; then
      _door="{\"repo\":\"${PROJECT}\",\"stack\":\"${_grad}\",\"loop_ns\":\"${_grad}-agents\",\"unit\":\"-\"}"
    else
      _door="{\"repo\":\"${PROJECT}\",\"unit\":\"-\"}"
    fi
    # `unit` is sent EXPLICITLY as "-" (= no specific unit, let the scan decide). The Sensor's
    # triggers map body.unit into the Workflow, and a missing key made every ride's doorbell log
    # `failed to get value by key: key body.unit does not exist to in the event payload` — harmless
    # to the dispatch (the scan runs anyway) but a permanent error line in the Sensor log, which is
    # exactly the noise floor that hid a spinning Sensor for ~50 minutes on 2026-08-05 (homelab#103).
    # Content-Type: application/json so the eventsource PARSES body.repo/stack/loop_ns as fields —
    # without it curl sends form-urlencoded and the whole JSON becomes one body KEY (the Sensor's
    # data filters then can't see body.loop_ns, so the per-stack routing never fires).
    curl -m 5 -s -X POST -H "Content-Type: application/json" -d "$_door" \
      "${AGENT_LOOP_WEBHOOK:-http://agent-loop-eventsource-svc.agent-coordinator.svc.cluster.local:12000}/coordinate" \
      >/dev/null 2>&1 && echo "→ coordinator doorbell rung (/coordinate ${_door})" || true
  fi
  # FU-160 / homelab#324: no `run_phase bookkeeping` either. It measured 0s on 5 of the 5 rides
  # that ever reached it, and that is correct rather than broken — FU-064/FU-043 moved arming, the
  # stats comment and the strike INTO the pod, so everything above is the fallback-not-taken plus
  # a router report and a doorbell. The in-pod `finalize` row (~11s, on every ride) is where that
  # work now is. What this drops is the ability to see a GitHub API stall in the launcher's own
  # exit path; the *_by_pod flags on the stats line say whether the fallback ran at all, and a
  # stall in the leg that matters is inside `finalize`.
  rm -f "$RUNLOG"
else
  ATTACH="kubectl --kubeconfig tofu/kubeconfig -n ${NS} exec -it ${POD} -- bash -c 'cd /work/repo; exec bash -l'"
  echo "→ pod ${POD} ready at /work/repo. harnesses are wired to OpenRouter (model: ${MODEL}); try:"
  echo "    goose run -t \"<task>\"        # or: goose run --recipe .agents/fix.yaml --params issue=N"
  echo "    opencode -m \"\$MODEL\"          # TUI   |   opencode run -m \"\$MODEL\" \"<task>\"   # headless"
  if [ -n "$NO_ATTACH" ]; then
    # A non-TTY caller (orchestrator / jail agent) can prep the pod; you attach the TUI from YOUR
    # terminal. Re-runnable — attach, detach, re-attach without recreating the pod.
    echo "→ attach the interactive TUI from a real terminal:"
    echo "    ${ATTACH}"
    echo "  remove when done:  kubectl --kubeconfig tofu/kubeconfig -n ${NS} delete pod ${POD}"
  else
    echo "  exit leaves the pod up; remove with:  kubectl -n ${NS} delete pod ${POD}"
    "$KUBECTL" $KUBE -n "$NS" exec -it "${POD}" -- bash -c 'cd /work/repo 2>/dev/null; exec bash'
  fi
fi
