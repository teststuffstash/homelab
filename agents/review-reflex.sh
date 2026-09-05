#!/usr/bin/env bash
# review-reflex — the deterministic SCHEDULER half of the merge path (FU-041, docs/agents/merge-path.md
# §Chosen design ▸3). NOT a second controller: it is the coordinator subsystem's mechanical transition
# "PR is green + current + unapproved → dispatch a reviewer", extracted so it never costs an LLM turn.
#
# Runs on a ~5-min CronJob in ns agent-coordinator (agents/coordinator/review-reflex.yaml). Each tick,
# LEVEL-TRIGGERED (re-lists the world; holds no state):
#   1. reap finished reviewer pods (restartPolicy: Never leaves them Completed/Failed).
#   2. per (repo, BASE) LANE, pick the OLDEST PR that is armed ∧ green ∧ not-conflicted ∧ reviewable
#      (unreviewed, OR changes-requested with new commits since the last review).
#   3. dispatch reviewer-session.sh for it — ONE per LANE (ADR-125: reviews serialize per (repo, base)
#      so a merge never stales a sibling's fresh approval, and only PRs sharing a base can do that to
#      each other; see merge-path.md §Why update-before-review), capped at K concurrent reviewer pods
#      GLOBALLY (protects the shared operator subscription quota — the lane split never raises K).
# Anything it can't mechanically progress (conflict, changes-requested-no-new-commits, red) it leaves for
# the updater workflow or the coordinator — it only ever dispatches a review, never merges or decides.
#
# Idempotency: a reviewer pod carries labels app=agent-reviewer,project=<repo>,pr=<n> (set by
# reviewer-session.sh). We skip a PR that already has a live reviewer pod, and reviewer Jobs are the
# unit of at-most-once dispatch (concurrencyPolicy: Forbid on the CronJob prevents overlapping ticks).
#
# Circuit breaker (2026-07-12, after the oracle-fleet#13 loop): PRs labelled `agent/error` are
# invisible to the reflex, and the reflex itself trips that label (+ an AGENT_ERROR comment) when a
# picked PR carries verdict counts no legitimate pick can have — see the breaker block below. A
# human removes the label to resume. Independent backstop: the github-exporter's AgentReviewLoop /
# AgentErrorFlagged Prometheus alerts (argocd/resources/github-exporter/).
#
#   Env (all optional): AGENT_REPOS="sleep-tracking snore-recorder"  ORG=teststuffstash
#                       REVIEW_CONCURRENCY=2  REVIEWER_NS=agent-coordinator  REVIEWER_LOGIN=homelab-reviewer
#                       REVIEW_ROUNDS_MAX=8
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

ORG="${ORG:-teststuffstash}"
# Repos: explicit AGENT_REPOS wins; else derive ALL stack repos from agents/stacks.json —
# the reflex runs from a fresh homelab clone each tick, so the stack list is always current
# (found live: PR oracle-fleet#5 sat green+armed+unapproved for 90min because this list was
# hardcoded to the sleep repos; TICK-LOG 2026-07-09).
if [ -n "${AGENT_REPOS:-}" ]; then
  REPOS="$AGENT_REPOS"
else
  _HERE=$(cd "$(dirname "$0")" && pwd)
  REPOS=$(jq -r '.stacks[].repos[]' "$_HERE/stacks.json" 2>/dev/null | sort -u | tr '
' ' ')
  REPOS="${REPOS:-sleep-tracking snore-recorder}"
fi
# FU-080 per-stack review cutover (mirror of coordinator-scan's graduated skip): a GRADUATED stack
# is reviewed by its OWN per-stack reflex — SCAN_STACK set → scope to that stack's repos and dispatch
# the reviewer pod INTO <stack>-agents as agentstack-loop (--loop-ns, broker role=reviewer). The
# GLOBAL reflex (SCAN_STACK unset) SKIPS graduated stacks so the two never double-review. graduated
# from stacks.json (the committed mirror — always present here; the reviewer.enabled knob below is
# orthogonal: "review at all" vs "review here-vs-per-stack").
_HERE="${_HERE:-$(cd "$(dirname "$0")" && pwd)}"
LOOP_NS_ARG=""
if [ -n "${SCAN_STACK:-}" ]; then
  REPOS=$(jq -r --arg s "$SCAN_STACK" '.stacks[]|select(.name==$s)|.repos[]' "$_HERE/stacks.json" 2>/dev/null | sort -u | tr '\n' ' ')
  LOOP_NS_ARG="${SCAN_STACK}-agents"
else
  grad_repos=$(jq -r '.stacks[]|select((.graduated // false)==true)|.repos[]' "$_HERE/stacks.json" 2>/dev/null | sort -u | tr '\n' ' ')
  if [ -n "$grad_repos" ]; then
    kept=""
    for r in $REPOS; do case " $grad_repos " in *" $r "*) ;; *) kept="$kept $r";; esac; done
    REPOS="$kept"
  fi
fi

# FU-104 TEETH: a stack whose error budget is BURNT gets its auto-merge lane parked — this
# reflex simply stops dispatching reviews for its repos (no bot approval ⇒ auto-merge never
# fires ⇒ merges wait for a HUMAN). Ground truth = the claim-rendered recording rule
# stack:error_budget_burnt:bool (agentstack Composition). FAIL-OPEN: a dead Prometheus must
# never freeze every merge lane (rule #6 in reverse — availability of the gate < the gate);
# a query failure logs loud and parks nothing.
# The ONE read lives in agents/slo-teeth.sh (homelab#831) — ALL dispatch sites call the same helper.
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
# >>>REPLAY:slo-teeth-filter>>>
_teeth_err="$(mktemp)"
REPOS="$(bash "$HERE/slo-teeth.sh" --filter $REPOS 2>"$_teeth_err" | tr '\n' ' ')" || true
while IFS= read -r l; do [ -n "$l" ] && log "$l"; done < "$_teeth_err"
rm -f "$_teeth_err"
if [ -z "${REPOS// /}" ]; then
  log "no repo is clear to review this tick (all parked by slo-teeth) — nothing to do"
  exit 0
fi
# <<<REPLAY:slo-teeth-filter<<<
# The egress proxy — same value subscription-latch.sh/agent-session.sh use for POST /route,
# GET /report/latest (the #803 decorrelate-from lookup at L319), /report, etc.
PROXY_URL="${AGENT_EGRESS_PROXY:-${AGENT_OPENROUTER_PROXY:-http://openrouter-proxy.agent-egress.svc.cluster.local:8080}}"
K="${REVIEW_CONCURRENCY:-2}"
NS="${REVIEWER_NS:-${LOOP_NS_ARG:-agent-coordinator}}"
REVIEWER_LOGIN="${REVIEWER_LOGIN:-homelab-reviewer}"   # the reviewer App's bot identity
WORKER_AUTHOR="${WORKER_AUTHOR:-app/homelab-agents-1234}" # the worker App's PR-author login (C9 re-arm scope)
# The base every ordinary agent PR targets. A PR based on anything else is STACKED work (an issue
# carrying `Base: <branch>`, 2026-08-05) and is un-armed on purpose — C9 must not "repair" that.
# Every repo in the fleet uses master; overridable rather than hardcoded at the jq call site.
DEFAULT_BRANCH="${DEFAULT_BRANCH:-master}"
ROUNDS_MAX="${REVIEW_ROUNDS_MAX:-8}"                   # circuit breaker: max bot verdicts per ISSUE, ever
                                                       # (summed across every PR that references it — homelab#156)
KUBECTL="$(command -v kubectl || echo kubectl)"

# >>>REPLAY:reflex-tick-gate>>>
# 0a. FU-088(a) reactive latch: the first 429 anywhere on the subscription latches the egress
#     proxy — skip the whole tick while latched (this reflex only ever spawns subscription
#     reviewers; level-triggered, so the next tick simply re-checks).
#     homelab#439: --pick-rail mode — when ANY rail is clear the tick proceeds; each
#     reviewer-session it dispatches runs its own #424 ladder downstream.
rail="$(SUBSCRIPTION_TIER=dispatch bash "$HERE/subscription-latch.sh" --pick-rail)" || rail=""
if [ -z "$rail" ]; then
  log "tick skipped — both rails latched (FU-088 latch)"
  exit 0
fi
log "rail clear: $rail — tick proceeds (each dispatched session picks its own rail downstream)"
# <<<REPLAY:reflex-tick-gate<<<

# 0b. Honor the per-stack `reviewer.enabled` knob — the first CONSUMED slice of FU-080 (found
#     live 2026-07-17: the oracle claim synced `reviewer: {enabled: false}` but nothing read it,
#     so reviews kept firing). A stack that opted out drops ALL its repos from this tick.
#     The read itself lives in agents/reviewer-optout.sh (homelab#204) — this tick is only ONE of
#     three dispatch sites, and the inline jq that used to sit here was the whole bug: the other
#     two sites never grew a copy, so the perstack Sensor auto-merged agent-runtime#57 for an
#     opted-out stack while this line correctly logged the skip. reviewer-session.sh runs the same
#     helper for every site; filtering here as well is not redundancy, it saves a `gh pr list` and
#     a whole dispatch decision per opted-out repo.
#     ⚠ FAIL-CLOSED on a PROBE-FAIL, reversing this branch's original posture (which WARNed and
#     reviewed everything anyway). The old comment's instinct — "never silently change the review
#     set on a flaky read" — is right for a knob that ENABLES work and backwards for one that
#     DISABLES it: an unread claim is not permission to approve and auto-merge. A skipped tick
#     costs ~5 minutes on a level-triggered path; an un-skippable disabled review costs the gate.
#     The helper prints the reason (with the repo, the stack, and what to check) to stderr.
#     ONE invocation — stdout is the kept list, stderr the reasons, replayed through log() so they
#     keep this tick's timestamps. Calling it twice (once per stream) would double the cluster read
#     and could straddle a claim edit.
# >>>REPLAY:optout-filter>>>
#     `|| true` is load-bearing, not defensive noise: this file runs under `set -euo pipefail`, the
#     helper exits 1 on a PROBE-FAIL, and pipefail propagates that through the `| tr` into the
#     assignment — so without it the tick DIES at this line (exit 1, Failed pod) and never prints
#     the reason it collected. Caught by agents/reviewer-optout-replay.sh §4 before it ever ran.
#     Standing aside is the intended behaviour, the same as the FU-088 latch above: empty list →
#     the loud log line → exit 0.
_optout_err="$(mktemp)"
REPOS="$(bash "$HERE/reviewer-optout.sh" --filter $REPOS 2>"$_optout_err" | tr '\n' ' ')" || true
while IFS= read -r l; do [ -n "$l" ] && log "$l"; done < "$_optout_err"
rm -f "$_optout_err"
if [ -z "${REPOS// /}" ]; then
  log "no repo is clear to review this tick (all opted out, or the claims read failed) — nothing to do"
  exit 0
fi
# <<<REPLAY:optout-filter<<<

# 1. Reap finished reviewer pods so the "already under review?" check below stays accurate and the
#    namespace doesn't fill up (a completed pod's verdict already lives in the PR's state).
for phase in Succeeded Failed; do
  "$KUBECTL" -n "$NS" delete pod -l app=agent-reviewer \
    --field-selector "status.phase==${phase}" --ignore-not-found >/dev/null 2>&1 || true
done

dispatch=()   # "repo pr head [decorrelate-arg]" tuples, at most one per (repo, base) LANE per tick

for repo in $REPOS; do
  slug="$ORG/$repo"
  # Fail LOUD, never swallow: a `gh pr list` error (e.g. the token lacking checks:read/statuses:read,
  # so `--json statusCheckRollup` 403s) must NOT collapse into an empty list — that silently makes every
  # green PR invisible and the reflex "sees nothing to review" forever. Abort so the pod Fails visibly.
  # --limit 40 (not 50): gh's fixed statusCheckRollup fragment is deep, and GraphQL bills the *static*
  # worst-case node count from the query's first:/last: args (independent of how many PRs actually exist).
  # At 50 that estimate is ~515k > GitHub's 500k cap → hard error; 40 (~412k) always clears it. Bump only
  # in lockstep with this ceiling. 40 open+auto-merge PRs/repo is far beyond anything the agent flow hits.
  # `body` is a scalar (no node cost against that ceiling) and rides along for the issue-keyed
  # rounds ceiling below — it is where a PR that does not follow the fix/issue-<n>- branch
  # convention still names its issue.
  # One retry absorbs GitHub's one-shot GraphQL transients ("Something went wrong while executing
  # your query", seen 2026-07-15 on oracle-iac) without weakening the fail-loud posture: a real
  # outage/scope problem still aborts the run rather than silently reviewing nothing.
  errfile="$(mktemp)"
  attempt=0
  while ! prs="$(gh pr list --repo "$slug" --state open --limit 40 \
      --json number,createdAt,isDraft,mergeStateStatus,reviewDecision,autoMergeRequest,statusCheckRollup,reviews,commits,labels,author,headRefName,baseRefName,body \
      2>"$errfile")"; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 2 ]; then
      log "[$repo] FATAL: gh pr list failed (after retry) — aborting rather than silently reviewing nothing:"
      cat "$errfile" >&2
      rm -f "$errfile"
      exit 1
    fi
    log "[$repo] gh pr list failed (transient?) — retrying once in 10s:"
    cat "$errfile" >&2
    sleep 10
  done
  rm -f "$errfile"

  # C9 repair (TICK-LOG meta-7 retro (a) — the FU-079 class): a WORKER-authored PR that arrived
  # un-armed is invisible to the ENTIRE merge path (updater, this reflex, auto-merge). Arm it —
  # decision-free: arming only *requests* auto-merge, every gate (CI, review, CODEOWNERS) still
  # applies. Root fix = finalize's derived pr_url (agent-runtime#17); this is the level-triggered
  # belt. Scope: the worker App's PRs ONLY — operator/stacked PRs stay report-only by the FU-079
  # decision (the scan's orphan clause). Skips drafts + `agent/error` carriers. The just-armed PR
  # is picked up on the next pass (this tick's list predates the arm; the exporter edge or the
  # next backstop tick sees it armed).
  while read -r unarmed_pr; do
    [ -n "$unarmed_pr" ] || continue
    if gh pr merge "$unarmed_pr" --repo "$slug" --auto --squash >/dev/null 2>&1; then
      log "[$repo] C9: armed worker PR #$unarmed_pr (arrived un-armed — invisible to the merge path)"
    else
      log "[$repo] C9: arm of #$unarmed_pr FAILED (non-fatal — the scan's orphan clause reports it)"
    fi
  # ⚠ NO APOSTROPHES OR BACKTICKS in the comments below. This jq program is a SINGLE-QUOTED
  # argument inside $( ) in an unquoted heredoc: an apostrophe (coordinator's) CLOSES the quote and
  # bash then parses the jq parens as shell syntax; a backtick becomes command substitution.
  # bash -n cannot see either — the failure is at runtime and it kills the whole reflex (exit 2,
  # review + arm dead FLEET-WIDE until fixed). Cost one outage on 2026-08-05, from the word
  # "coordinator's". Test edits by RUNNING the block, not by parsing the file.
  done <<EOF_C9
$(printf '%s' "$prs" | jq -r --arg author "$WORKER_AUTHOR" --arg default "$DEFAULT_BRANCH" '
    .[] | select(.autoMergeRequest == null and .isDraft == false
                 and .author.login == $author
                 and all(.labels[].name; . != "agent/error")
                 # major/awaiting-human = a PR a human has deliberately parked (a major bump
                 # awaiting a person, or a FROZEN comparison arm — circles#21). Before goal/**
                 # became armable its non-default base was what kept it un-armed; that accident is
                 # gone, so the intent has to be stated. Same label the changes-requested
                 # clause in coordinator-scan.sh already honours.
                 and all(.labels[].name; . != "major/awaiting-human")
                 # research/* = the FU-105 researcher convention: DELIBERATELY un-armed — the
                 # human gate IS the un-armed state (roles.md §researcher); never re-arm.
                 and ((.headRefName // "") | startswith("research/") | not)
                 # STACKED work (2026-08-05, revised same day): a PR into a goal/** INTEGRATION
                 # branch IS armable — that branch carries the same ruleset as master, so the arm
                 # waits for CI + an approving review (operator: feature→goal automates,
                 # goal→master stays human). Any OTHER non-default base still refuses: auto-merge
                 # waits on branch protection, so arming into an unprotected base merges on open.
                 and (((.baseRefName // $default) == $default)
                      or ((.baseRefName // "") | startswith("goal/"))))
        | .number')
EOF_C9

  # >>>REPLAY:review-pick>>>
  # Reviewable = armed ∧ not-conflicted ∧ GREEN ∧ ( unreviewed OR changes-requested-with-new-commits )
  #              ∧ NOT `automerge`-labelled.  CURRENCY IS NOT A PRECONDITION.
  #   green: every check present is a success-equivalent AND at least one check ran (never rubber-stamp a no-CI PR).
  #   DIRTY → conflict (coordinator's job); APPROVED → already merging.
  #   BEHIND USED TO SKIP HERE, and does not any more (2026-09-05, homelab#1422). The skip was
  #   designed against `dismiss_stale_reviews_on_push = true` (tofu/github/repo_rulesets.tf:138)
  #   eating a fresh approval on the updater's catch-up merge — "update before review", the
  #   ordering merge-path.md §Why update-before-review argues for. The premise is FALSE for
  #   update-branch merges: GitHub RE-POINTS a review's commit_id on them, so the approval
  #   survives. Measured the day this changed: PR#1386's bot approval survived four updater
  #   merges (07:06-07:37Z), as did #1388's and #1389's. Only CONTENT pushes dismiss.
  #   Meanwhile the skip cost real first-review starvation — PR#1437 sat BEHIND through 7 master
  #   moves and 3 updater merges the same day and never got a first review, because on a busy
  #   master "current" is a window a PR can miss indefinitely. So a BEHIND-but-green PR is
  #   admitted to its FIRST review and the updater + CI simply run after the verdict. Everything
  #   else stands: DIRTY still skips, `reviewable_again` still governs RE-reviews (a
  #   changes-requested PR with no new content is not reviewable, BEHIND or not — replayed as
  #   fixtures/review-pick/behind-cr-no-content-held), `bot_approved_head` still holds.
  #   ⚠ The launcher's spawn-time currency gate (reviewer-session.sh) is the second half of this
  #   rule and was narrowed to DIRTY in the same commit — leaving it would have let this pick be
  #   dispatched and then immediately skipped at spawn.
  #   "unreviewed" means THE REVIEWER BOT hasn't approved the current head — NOT reviewDecision !=
  #   APPROVED. On code-owner-gated repos (oracle-fleet: /specs/ + /.agents/ gate on Rasmus,
  #   tofu/github/variables.tf) reviewDecision stays REVIEW_REQUIRED after a bot approval, waiting
  #   for the human; conflating the two re-dispatched a reviewer EVERY tick — 12 duplicate approvals
  #   in 90 min on oracle-fleet#13 until the subscription session limit cut it off (2026-07-12).
  #   A bot approval OLDER than the newest commit doesn't count (new push → genuine re-review), and
  #   a DISMISSED approval doesn't either — so a human can dismiss the bot's review to force one.
  #   BEHIND *re-review* exception (deadlock found live on oracle-fleet#6, 2026-07-09): the adRise
  #   updater refuses any PR with a changes-requested review, so CHANGES_REQUESTED + fix pushed +
  #   master moved = updater waits for the review, reflex waited for the updater — forever. A
  #   re-review may proceed on a BEHIND branch (the verdict is about the fix, not currency);
  #   approval clears changesRequestedReviews → updater updates → fresh CI → auto-merge.
  #   `automerge` label = the MECHANICAL path (Renovate trivial/digest/dev-dep bumps auto-approved by the
  #   renovate-approve reflex, CI-only, no LLM). Skip them so the reviewer isn't burned on digest noise.
  #   Renovate's REVIEWABLE bumps carry `deps-review` (not `automerge`) → they fall through here and get
  #   the LLM reviewer like any agent PR (FU-046; docs/renovate.md + docs/agents/merge-path.md).
  #   ARMING IS THE BOUNDARY: this reflex only ever touches auto-merge-armed PRs. Un-armed `major` devbox
  #   bumps (devbox-update.sh gate, FU-022) are HUMAN-GATED and COORDINATOR-owned — the coordinator
  #   dispatches their investigation review directly (even while red) and hands off to a human; the reflex
  #   must NOT reach across the arming wall for them, or the two would fight over one PR. See merge-path.md.
  picks="$(printf '%s' "$prs" | jq -r --arg bot "$REVIEWER_LOGIN" --arg default "$DEFAULT_BRANCH" '
    def green:
      ([ .statusCheckRollup[]? | (.conclusion // .state // "") ]) as $c
      | ($c | length) > 0
        and ([ $c[] | select(. != "SUCCESS" and . != "NEUTRAL" and . != "SKIPPED") ] | length) == 0;
    def newest_review_at:
      ([ .reviews[]? | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED") | .submittedAt ] | max) // "";
    def newest_commit_at:
      # UPDATER MERGE COMMITS ARE NOT NEW CONTENT (found live 2026-07-21, oracle-fleet#57: the
      # update-branch merges kept outdating a valid head approval — re-review → merge → re-review,
      # NINE reviewer sessions before STEP-0 tripped the breaker). A merge brings no PR-authored
      # diff; CI still re-runs on the new head via the required check either way.
      ([ .commits[]? | select(((.messageHeadline // "") | startswith("Merge branch ")) | not) | .committedDate ] | max) // "";
    def reviewable_again:
      (.reviewDecision == "CHANGES_REQUESTED") and (newest_commit_at > newest_review_at);
    def bot_approved_head:
      ([ .reviews[]?
         | select(((.author.login // "") | sub("\\[bot\\]$"; "")) == $bot)
         | select(.state == "APPROVED")
         | .submittedAt ] | max // "") > newest_commit_at;
    [ .[]
      | select(.isDraft | not)
      | select(([ .labels[]?.name ] | index("automerge")) | not)
      | select(([ .labels[]?.name ] | index("agent/error")) | not)
      | select(([ .labels[]?.name ] | index("agent/arbitrate")) | not)
      | select(.autoMergeRequest != null)
      | select(.mergeStateStatus != "DIRTY")
      | select(green)
      | select((.reviewDecision // "") != "APPROVED")
      | select(((.reviewDecision // "") != "CHANGES_REQUESTED") or reviewable_again)
      | select(bot_approved_head | not)
    ]
    # PER-LANE PICK (ADR-125 (1), homelab#1422). The serialization unit is (repo, BASE), not the
    # repo: the serializer exists to avoid the merge -> behind -> dismiss-approval chain, and that
    # chain only ever runs between PRs sharing a base. A repo-level boundary serialized master-lane
    # and goal-lane work that cannot invalidate each other (goal #278 lost 361 minutes to it). So:
    # group the SAME filtered candidate set by base, and emit the oldest of each group. The loop
    # below runs every per-pick step (decorrelation, breaker telemetry, the issue-keyed rounds
    # ceiling, the pod-name key) once per lane exactly as it ran once per repo before. The K
    # concurrency cap and the FU-088 latch are UNCHANGED and stay the fleet-wide ceiling — lanes
    # buy parallelism inside that ceiling, they never raise it.
    | group_by(.baseRefName // $default)
    | map(sort_by(.createdAt) | .[0])
    | .[]
    # CIRCUIT-BREAKER TELEMETRY rides along with the pick: the bot verdict counts, recomputed from
    # the RAW fields on purpose — the breaker must not share code (or bugs) with the defs above.
    # A stateless level-triggered reflex turns any predicate bug into an infinite dispatcher (the
    # 2026-07-12 oracle-fleet#13 loop: 12 duplicate approvals), so the shell trips agent/error
    # instead of dispatching when the counts are impossible for a legitimate pick.
    | ([ .commits[]? | select(((.messageHeadline // "") | startswith("Merge branch ")) | not) | .committedDate ] | max // "") as $head
    | ([ .reviews[]?
         | select((.author.login // "") | startswith($bot))
         | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED") ]) as $verdicts
    | ($verdicts | map(select(.submittedAt > $head))) as $at_head
    # ISSUE KEY of the pick, for the issue-keyed rounds ceiling in the shell below: the branch
    # convention fix/issue-<n>-<slug> first, else the first closing keyword in the body. "-" when
    # neither names an issue (then only the per-PR count applies). Boundary-anchored on purpose:
    # issue-15 must not match a fix/issue-156-... branch.
    | ((((.headRefName // "") | capture("issue-(?<i>[0-9]+)(-|$)") | .i)
        // ((.body // "") | capture("(?i)(^|[^a-z])(implements|closes|closed|fixes|fixed|resolves|resolved)[ \t]+#(?<i>[0-9]+)") | .i)
        // "-")) as $ikey
    | "\(.number) \($verdicts | length) \($at_head | length) \([ $at_head[] | select(.state == "APPROVED") ] | length) \(.headRefName // "-") \($ikey) \(.baseRefName // $default)"
  ')"
  # <<<REPLAY:review-pick<<<

  [ -n "$picks" ] || { log "[$repo] nothing to review"; continue; }
  # ONE pick per lane, each carried through the full per-pick gauntlet below. A here-string (not a
  # pipe) so `dispatch+=` lands in THIS shell, and `continue` still means "next lane", never "next
  # repo" — a breaker trip on the master lane must not silence a goal lane's pick.
  while read -r pick v_total v_head v_head_approved pick_head pick_issue pick_base; do
  [ -n "$pick" ] || continue
  log "[$repo] lane=$pick_base pick=#$pick"

  # ── Decorrelation: resolve the newest round's SERVED model for this task ────────────────
  # The dispatch resolves the M5 evidence row (the served model, never the requested id) from
  # the run-report store and passes it as --decorrelate-from so the router excludes that family
  # across rails (#516's primitive). The proxy stores run_reports via POST /report from every
  # worker session; query the latest here.
  # >>>REPLAY:decorrelate-resolution>>>
  decorrelate_arg=""
  if [ "$pick_issue" != "-" ] && [ -n "${PROXY_URL:-}" ]; then
    _last_report="$(curl -fsS --max-time 3 \
      "${PROXY_URL}/report/latest?task=issue-${pick_issue}" 2>/dev/null)" || _last_report=""
    if [ -n "$_last_report" ]; then
      _last_model="$(printf '%s' "$_last_report" | jq -r '.served_model // .model // ""' 2>/dev/null)" || _last_model=""
      if [ -n "$_last_model" ]; then
        decorrelate_arg="--decorrelate-from $_last_model"
        log "[$repo] decorrelate_from: $_last_model (issue #${pick_issue})"
      fi
    fi
  fi
  [ -n "$decorrelate_arg" ] || log "[$repo] decorrelate_from: not available (run-report query skipped or unreachable)"
  # <<<REPLAY:decorrelate-resolution<<<

  # Breaker: a legit pick has ZERO bot approvals at head (the predicate filters those), <2 bot
  # verdicts at head, and fewer than ROUNDS_MAX verdicts ever ON ITS ISSUE — see the issue-keyed
  # ceiling below; the at-head checks stay strictly per-PR (beyond that it's a worker↔reviewer
  # flip-flop — merge-path.md escalation table). Any of these ⇒ label agent/error + one AGENT_ERROR
  # comment, never dispatch. Labelled PRs are filtered before the pick, so this fires ONCE; a human
  # removes the label to resume automation. Label add failing (missing label/scope) is logged loud
  # every tick on purpose — the dispatch is still skipped, and the exporter's AgentReviewLoop alert
  # (github_pull_request_reviews_recent) is the independent backstop.
  # FU-086 arbitrate split (MP-G04, 2026-07-27): ROUNDS-EXHAUSTED is an ESCALATION, not an
  # anomaly — the coordinator is the designed tie-breaker (merge-path.md escalation table), so it
  # gets `agent/arbitrate` (scan-actionable: the arbitrate clause dispatches an item session).
  # The two IMPOSSIBLE-STATE signatures (approval at head / duplicate verdicts at head) stay
  # `agent/error` — those mean the MACHINERY misbehaved, human-first.
  if [ "$v_head_approved" -ge 1 ] || [ "$v_head" -ge 2 ]; then
    log "[$repo] BREAKER on #$pick (verdicts: total=$v_total at-head=$v_head approved-at-head=$v_head_approved) — agent/error, NOT dispatching"
    if gh pr edit "$pick" --repo "$slug" --add-label "agent/error" >/dev/null 2>&1; then
      gh pr comment "$pick" --repo "$slug" --body "AGENT_ERROR: review-reflex circuit breaker tripped — this PR was selected for review with an impossible state (bot verdicts: ${v_total} total, ${v_head} since the newest commit, ${v_head_approved} of those approvals). Automation now skips this PR. A human: inspect the review thread + reflex logic, then remove the \`agent/error\` label to resume." >/dev/null 2>&1 \
        || log "[$repo] WARN: breaker comment on #$pick failed"
    else
      log "[$repo] WARN: could not add agent/error to #$pick (label missing on repo? token scope?) — dispatch still skipped"
    fi
    continue
  fi
  # ISSUE-KEYED ROUNDS CEILING (homelab#156, FU-154). $v_total counts verdicts on THIS PR, and PR
  # identity is not the unit of the work: close-and-re-PR is a DESIGNED play as of 2026-08-08
  # (the merge-conflict lane re-landed #210 as #221, the coordinator closed #214 and re-queued its
  # issue, #209 was superseded by #218-v2). Every re-creation restarted the count at zero, so a
  # pathological loop could launder unlimited rounds through fresh PRs. The ISSUE is the stable
  # key: sum the SAME verdict evidence across every PR in this repo whose branch or body references
  # that issue id. Per-PR stays the FAST PATH (it trips with no extra API call); the issue-keyed sum
  # is the CEILING and can only raise the number, never lower it.
  # PR#143 INTENDED-SEMANTICS EXCEPTION PRESERVED: a DISMISSED verdict deliberately does NOT count
  # (the arbitration ruling ended that round, it did not spend one). A dismissal rewrites the review
  # state to DISMISSED, so the APPROVED/CHANGES_REQUESTED filter below drops it exactly as the
  # per-PR counter above already does — the two counters must stay identical on this point.
  # FAIL-OPEN on a bad read (the FU-104 posture — availability of the gate < the gate): warn loudly
  # and let the per-PR count stand rather than park a lane on a flaky list. The window is the newest
  # 100 PRs of the repo, so anything missed can only UNDER-count.
  # ⚠ The sibling-match rule (branch `issue-<n>-`, else body closing keyword `#<n>`, both boundary-anchored) is
  # duplicated in coordinator-scan.sh's ci-red clause, which counts run-stats rounds on the same
  # key. Two copies WILL drift — change both or neither.
  rounds_total="$v_total"; rounds_key="PR #${pick}"
  if [ "$v_total" -lt "$ROUNDS_MAX" ] && [ "$pick_issue" != "-" ]; then
    if sib="$(gh pr list --repo "$slug" --state all --limit 100 \
                --json number,headRefName,body,reviews 2>/dev/null)"; then
      sib_sum="$(printf '%s' "$sib" | jq -r --arg bot "$REVIEWER_LOGIN" --arg n "$pick_issue" '
        def refs($n): ((.headRefName // "") | test("(^|[^0-9])issue-" + $n + "(-|$)"))
                      or ((.body // "") | test("(?i)(^|[^a-z])(implements|closes|closed|fixes|fixed|resolves|resolved)[ \t]+#" + $n + "([^0-9]|$)"));
        [ .[] | select(refs($n)) ]
        | "\(length) \([ .[] | .reviews[]?
              | select((.author.login // "") | startswith($bot))
              | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED") ] | length)"
      ' 2>/dev/null)" || sib_sum=""
      read -r sib_prs sib_v <<<"${sib_sum:-}"
      case "${sib_v:-}" in ''|*[!0-9]*) sib_v=""; log "[$repo] WARN: issue-keyed rounds sum unreadable for issue #${pick_issue} — per-PR count stands for #$pick";; esac
      if [ -n "$sib_v" ] && [ "$sib_v" -gt "$rounds_total" ]; then
        rounds_total="$sib_v"; rounds_key="issue #${pick_issue} (${sib_prs} PRs)"
        log "[$repo] issue-keyed rounds for #$pick: ${sib_v} verdicts across ${sib_prs} PRs referencing issue #${pick_issue} (per-PR: ${v_total})"
      fi
    else
      log "[$repo] WARN: issue-keyed rounds probe FAILED (gh pr list --state all) — per-PR count stands for #$pick"
    fi
  fi
  if [ "$rounds_total" -ge "$ROUNDS_MAX" ]; then
    log "[$repo] ROUNDS EXHAUSTED on #$pick (${rounds_total} bot verdicts on ${rounds_key} ≥ cap ${ROUNDS_MAX}) — agent/arbitrate (coordinator tie-break), NOT dispatching"
    gh label create "agent/arbitrate" --repo "$slug" --color "d93f0b" --force \
      --description "rounds exhausted / flip-flop — coordinator tie-break (merge-path escalation table)" >/dev/null 2>&1 || true
    if gh pr edit "$pick" --repo "$slug" --add-label "agent/arbitrate" >/dev/null 2>&1; then
      gh pr comment "$pick" --repo "$slug" --body "ARBITRATE: ${rounds_total} bot review verdicts counted on ${rounds_key} (cap ${ROUNDS_MAX}) — a worker↔reviewer loop that will not converge on its own. Rounds are counted against the ISSUE, not the PR (homelab#156), so closing this PR and opening a fresh one does not restore the budget. Review automation now skips it; the coordinator's arbitrate unit rules per the escalation table (re-dispatch with clarified instructions / close as not-mergeable / escalate to a human)." >/dev/null 2>&1 \
        || log "[$repo] WARN: arbitrate comment on #$pick failed"
    else
      log "[$repo] WARN: could not add agent/arbitrate to #$pick — dispatch still skipped"
    fi
    continue
  fi

  if "$KUBECTL" -n "$NS" get pods -l "app=agent-reviewer,project=${repo},pr=${pick}" \
        --no-headers 2>/dev/null | grep -q .; then
    log "[$repo] PR #$pick already under review — skip"
    continue
  fi

  dispatch+=("$repo $pick $pick_head $decorrelate_arg")
  # The lane loop's body is deliberately left at the enclosing indentation: re-flowing ~130 lines
  # would bury the one change (per repo -> per lane) in a whitespace diff.
  done <<< "$picks"
done

[ "${#dispatch[@]}" -gt 0 ] || { log "no PRs to dispatch this tick"; exit 0; }

# Dispatch, capped at K concurrent reviewer sessions globally. reviewer-session.sh blocks until its pod
# finishes (~4-8 min), so background them and gate with `wait -n`.
running=0
for pair in "${dispatch[@]}"; do
  # shellcheck disable=SC2086
  set -- $pair; repo="$1"; pr="$2"; phead="${3:-}"
  # Fields 4+ are this pick's decorrelate flag (possibly absent). It rides the TUPLE because the
  # loop above now resolves one per lane: reading the bare `decorrelate_arg` here would hand every
  # dispatch whatever the last resolution left behind (already wrong across repos, and unmissable
  # once a repo contributes several picks).
  dcorr=""
  if [ "$#" -gt 3 ]; then dcorr="${*:4}"; fi
  # A pick whose HEAD is goal/** is the ASSEMBLY PR (goal -> master, the review-goal.md shape) —
  # the one review the whole goal rests on, cumulative over several separately-reviewed slices.
  # Model is configurable via REVIEW_GOAL_MODEL (default sonnet; mirrors GOAL_MODEL in
  # coordinator-scan.sh and dies the same M10 death when this lane is wired to /route). NB the
  # assembly reviewer must DIFFER from the decomposing model (issue-authoring leg (c)) — with
  # goal-decompose on opus, setting REVIEW_GOAL_MODEL=opus would collide; escalate GOAL_MODEL
  # or this, not both. Rubric routes to .agents/review-goal.md; reviewer-session falls back to
  # the generic prompt when a repo does not ship that file (per-repo opt-in by shipping it).
  # Child PRs (fix/* heads INTO goal/**) deliberately stay on the default rubric+model path.
  extra=""
  case "$phead" in
    goal/*) extra="--model ${REVIEW_GOAL_MODEL:-sonnet} --rubric .agents/review-goal.md"
            log "→ assembly PR (head ${phead}): model ${REVIEW_GOAL_MODEL:-sonnet}, rubric review-goal.md";;
  esac
  log "→ dispatch reviewer: ${repo} #${pr}${LOOP_NS_ARG:+ (loop-ns ${LOOP_NS_ARG})}${dcorr:+ (decorrelate-from ${dcorr#--decorrelate-from })}"
  # shellcheck disable=SC2086
  bash "$HERE/reviewer-session.sh" "$repo" "$pr" $extra $dcorr ${LOOP_NS_ARG:+--loop-ns "$LOOP_NS_ARG"} &
  running=$((running + 1))
  if [ "$running" -ge "$K" ]; then wait -n || true; running=$((running - 1)); fi
done
wait
log "reflex tick done"
