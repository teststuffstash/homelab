#!/usr/bin/env bash
# reviewer-session — review a project PR with Claude Code (subscription) in a scoped pod.
#
# The GATE between "worker opened a PR" and "GitHub auto-merges it". Shape-wise it's the worker's
# sibling (agent-session.sh): clone the PROJECT repo, check out the PR branch, run a headless pass,
# pod self-terminates. It renders a VERDICT as a native GitHub PR review (approve / request-changes) —
# not a homegrown flag — so branch protection ("require 1 approving review + CI green") turns that
# verdict into a mechanical merge gate, and GitHub's auto-merge completes the PR. Nobody clicks merge.
#
# Two distinct identities, on purpose:
#   • LLM auth = the operator SUBSCRIPTION via the ADR-087 ref rail (the pod holds only
#     ref:agent-coordinator/coordinator-claude; the egress proxy injects the token — FU-066d): free at
#     margin, a strong model, deliberately DECORRELATED from the cheap OpenRouter model that wrote the
#     PR. Reviewer must be at least as capable as the author; same model = same blind spots. Review +
#     coordination are the SAFETY NET, so they run on the SUBSCRIPTION with a capable model (**sonnet**,
#     the default) — NOT the cheap OpenRouter models the workers use. Don't cheap out on the reviewer.
#     (Proven live: on sleep-tracking#9 a *sonnet* reviewer caught the *coordinator's* own misjudgment —
#     dispatching a review on a DIRTY, superseded PR — and recommended close. Sonnet is sufficient here;
#     opus is available for a genuinely high-stakes PR via --model, but it is not the default.)
#   • VISIBILITY — the reviewer must see enough to reason about MESSY situations, not just the diff: it
#     does a FULL `gh repo clone` (master present) + `gh pr checkout`, so it can diff the PR against
#     current master and spot conflicts/supersession (that's how it found master's ced837d superseded #9).
#     Don't reduce it to a shallow/diff-only clone — visibility into master + history is load-bearing.
#   • GitHub identity = a SEPARATE review-bot App (reviewer-git → GH_TOKEN, e.g. homelab-reviewer[bot]).
#     GitHub blocks self-approval, so the reviewer MUST be a different bot than the worker that opened
#     the PR (homelab-agents[bot]) — reusing coordinator-git/agent-git-token would fail with
#     "Can not approve your own pull request". The review App needs only pull_requests:write +
#     contents:read — NO merge/contents:write (auto-merge does the merge).
# Both Secrets live in ns agent-coordinator; a Pod can't cross-mount a Secret, so the reviewer runs
# there. The reviewer only READS the diff + submits a review — it never executes project code (CI does
# that), so it needs neither the project's egress/budget sandbox nor merge rights.
#
#   bash agents/reviewer-session.sh sleep-tracking 8
#       → clone teststuffstash/sleep-tracking, `gh pr checkout 8`, /code-review, submit verdict, exit.
#
# The project-specific review rubric lives IN THE PROJECT REPO at .agents/review.md (versioned with
# the code, visible to PR authors) and is appended as Claude's system prompt — the same mechanism the
# coordinator uses for its own brief. The GENERIC "how to review" behavior is the PROMPT below: a code
# PR runs /code-review (built into the image's Claude Code); a DEPENDENCY/MAJOR bump (label major /
# deps-review, or a lockfile-only diff crossing a major) instead triggers a MIGRATION INVESTIGATION —
# read the tool's upstream breaking-changes, map them onto this repo's usage, comment concretely, and
# leave the merge to a human. Absent .agents/review.md, we just run the generic reviewer.
#
# Operator-side, ONCE (see docs/github-setup.md §2/§5):
#   • homelab-reviewer App + reviewer-git Secret:  scripts/github-app-bootstrap.sh homelab-reviewer
#       (check|manifest|convert|secrets|verify) → then apply agents/coordinator/reviewer-git.yaml
#   • merge gate = tofu/github/ (rulesets, NOT a shell script): the reviewer-approval gate is a per-repo
#       `pull_request` rule in repo_rulesets.tf → `tofu -chdir=tofu/github apply` (outside the jail).
#   • per-repo auto-merge + auto-delete-branch (not in tofu yet): `gh api -X PATCH /repos/<org>/<repo>`
#   • the worker arms it per PR:  gh pr merge <N> --auto --squash
# No new in-cluster RBAC (the pod spawns nothing and mints nothing; default SA is enough).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${HERE}/../tofu/kubeconfig" ]; then KUBE="--kubeconfig ${HERE}/../tofu/kubeconfig"; else KUBE=""; fi
KUBECTL="$(command -v kubectl || true)"
[ -n "$KUBECTL" ] || KUBECTL="${HERE}/../.devbox/nix/profile/default/bin/kubectl"
[ -x "$KUBECTL" ] || KUBECTL="kubectl"

PROJECT="${1:?usage: reviewer-session <project> <pr-number> [--repo owner/name] [--model m] [--rubric path]}"
PR="${2:?usage: reviewer-session <project> <pr-number> ...}"
shift 2 || true
# Stack for the telemetry attrs (cost attribution): derived from the claims mirror, tolerant of
# both repo-entry shapes (plain string and {name:} object). Env override wins; unknown → none.
STACK_LABEL="${STACK_LABEL:-$(jq -r --arg r "$PROJECT" \
  '.stacks[] | select([.repos[] | if type=="object" then .name else . end] | index($r)) | .name' \
  "$(dirname "$0")/stacks.json" 2>/dev/null | head -1)}"
STACK_LABEL="${STACK_LABEL:-none}"

# Pro/Max subscription ⇒ sonnet (a strong reviewer, free at margin). Override for a high-stakes PR
# (e.g. --model opus) or a metered run. Rubric path is relative to the project repo root.
REPO_SLUG=""; MODEL="sonnet"; RUBRIC=".agents/review.md"; PERM_MODE="bypassPermissions"; ROUND="1"; GO_SERVED=0; MODEL_RAIL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)            REPO_SLUG="$2"; shift 2;;   # owner/name or full URL; default teststuffstash/<project>
    --model)           MODEL="$2"; MODEL_SET_EXPLICIT=1; shift 2;;
    --rubric)          RUBRIC="$2"; shift 2;;      # project-relative path to the review system prompt
    --permission-mode) PERM_MODE="$2"; shift 2;;
    --round)           ROUND="$2"; shift 2;;       # review iteration on this PR (transcript prefix reviewer-r<N>)
    --loop-ns)         LOOP_NS_ARG="$2"; shift 2;;  # FU-080 perStack: run the reviewer pod in <stack>-agents as agentstack-loop; the review-bot token is fetched per-run from the proxy's TokenReview-gated /loop-git-token?role=reviewer (no Secret in that ns)
    --decorrelate-from) DECORRELATE_FROM="$2"; shift 2;;  # model family to decorrelate from (M5 evidence row — the served model, never the requested id)
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

# ── THE OPT-OUT GATE (homelab#204) ──────────────────────────────────────────────────────────────
# Honor the stack's `reviewer.enabled` knob HERE, at the one point ALL THREE dispatch sites pass
# through: the reflex tick, the `review-perstack` Sensor trigger, and the global `review`
# WorkflowTemplate (the latter two in agents/coordinator/review-argo.yaml, both `exec bash
# .../reviewer-session.sh`). The knob shipped inside the reflex tick alone, so on 2026-08-09 08:00Z
# the Sensor path reviewed, APPROVED and auto-merged agent-runtime#57 for a stack that had opted
# out — in the same minute the tick logged the correct skip. reviewer-optout.sh is the single read
# and the single (fail-CLOSED) posture; it prints its own reason to stderr.
# FIRST, deliberately: before the head-sha probe, before the latch, before the pod. A disabled
# stack must cost neither a GitHub call nor a subscription session.
# ⚠ The prompt's STEP 0 cannot stand in for this. That self-guard runs INSIDE the reviewer pod —
# by then the review the operator disabled has already been dispatched and paid for. This is the
# shell-level backstop the two Argo comments already claim exists.
# >>>REPLAY:optout-gate>>>
if ! bash "$HERE/reviewer-optout.sh" "$PROJECT"; then
  echo "→ review of ${PROJECT}#${PR} NOT dispatched — reviewer disabled for this stack (homelab#204)"
  exit 0
fi
# <<<REPLAY:optout-gate<<<

# ── THE SLO TEETH GATE (homelab#831, FU-104) ──────────────────────────────────────────────────
# Honor the stack's error budget burn state HERE, at the one point ALL dispatch sites pass
# through: the reflex tick AND the primary edge path (github-exporter → Sensor → review
# WorkflowTemplate). The teeth shipped inside the reflex tick alone, so on a burnt stack the
# edge path still dispatched a review, approved it, and auto-merge still fired — exactly the
# homelab#204 shape one lane over. slo-teeth.sh is the single read and the single (FAIL-OPEN)
# posture; it prints its own reason to stderr.
# FIRST, deliberately: before the head-sha probe, before the latch, before the pod. A burnt
# stack must cost neither a GitHub call nor a subscription session.
# FAIL-OPEN: a dead Prometheus must never freeze every merge lane (rule #6 in reverse —
# availability of the gate < the gate). An unreachable metric is NOT evidence of a burnt budget.
# >>>REPLAY:slo-teeth-gate>>>
if ! bash "$HERE/slo-teeth.sh" "$PROJECT"; then
  echo "→ review of ${PROJECT}#${PR} NOT dispatched — stack error budget burnt (auto-merge lane demoted to human, FU-104)"
  exit 0
fi
# <<<REPLAY:slo-teeth-gate<<<


# ── MCP knob read (#1041) ──────────────────────────────────────────────────────────────────────
# Read from reviewer-optout.sh's mcp_knob() — the ONE claims read for reviewer dispatch
# (homelab#204 two-readers-one-mirror class). The MCP endpoint is stack-wide (spec.mcp), not
# per-repo. Absent = no MCP config rendered.
MCP_ENDPOINT=""; MCP_TOOLS=""
_mcp_knob="$(bash "$HERE/reviewer-optout.sh" --mcp-knob "$PROJECT" 2>/dev/null)" || _mcp_knob=""
if [ -n "$_mcp_knob" ]; then
  MCP_ENDPOINT="${_mcp_knob%%|*}"
  MCP_TOOLS="${_mcp_knob#*|}"
fi
# >>>REPLAY:reviewer-mcp-prep>>>
# Build the MCP config at launcher level (not inside the PREP heredoc) so the pod's env does not
# need MCP_ENDPOINT/MCP_TOOLS. The base64 encoding is shell-safe for the unquoted <<PREP heredoc.
# Knob absent → MCP_PREP is empty → nothing rendered. Unparseable tools → loud degrade, no attach.
# The file is claude's OWN --mcp-config shape ({"mcpServers":{<name>:{type:"http",url}}}) and
# reaches the CLI through the MCP_FLAG shell var the RUNPART's `claude -p` line expands — PREP
# and RUNPART are one `bash -lc` script in the pod. The first cut exported a
# CLAUDE_CODE_MCP_CONFIG env var instead; no such var exists, so the file was written and never
# loaded (oracle-fleet#330 r2, 2026-09-01 — the worker arm's sibling defect). spec.mcp.tools is
# the env card's line, not a CLI input: bypassPermissions admits every attached tool.
MCP_PREP=""
if [ -n "${MCP_ENDPOINT:-}" ]; then
  MCP_CONFIG_JSON="$(jq -cn --arg url "$MCP_ENDPOINT" --argjson tools "${MCP_TOOLS:-[]}" \
    '{mcpServers: {"stack-mcp": {type: "http", url: $url}}}' 2>/dev/null)" || MCP_CONFIG_JSON=""
  if [ -n "$MCP_CONFIG_JSON" ]; then
    MCP_CONFIG_B64="$(printf '%s' "$MCP_CONFIG_JSON" | base64 -w0)"
    MCP_PREP="printf '%s' '${MCP_CONFIG_B64}' | base64 -d > /tmp/mcp-config.json
MCP_FLAG='--mcp-config /tmp/mcp-config.json'
echo '→ MCP config written'"
  else
    echo "→ MCP knob unreadable for ${PROJECT} — no MCP attached (fail-closed, #1041)" >&2
  fi
fi
# <<<REPLAY:reviewer-mcp-prep<<<
# FU-080 perStack (mirror of coordinator-session.sh): --loop-ns runs the reviewer pod in the stack's
# loop home as agentstack-loop, fetching the review-bot token (loop-reviewer-git-<stack>) per-run
# from the broker. The reviewer-git secretKeyRef/volume below stay optional:true — inert in that ns;
# GH_TOKEN_FILE won't exist so the gh wrapper falls back to the env LOOP_FETCH exports.
NS="${LOOP_NS_ARG:-agent-coordinator}"
POD_SA="default"
LOOP_FETCH=""
if [ -n "${LOOP_NS_ARG:-}" ]; then
  POD_SA="agentstack-loop"
  LOOP_FETCH="export GH_TOKEN=\"\$(curl -fsS -H \"Authorization: Bearer \$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)\" \"http://openrouter-proxy.agent-egress.svc.cluster.local:8080/loop-git-token?ns=${NS}&role=reviewer\")\" || { echo 'FATAL: loop-reviewer token fetch refused/failed — not reviewing blind'; exit 1; }; "
fi
[ -f "$HERE/images.env" ] && . "$HERE/images.env" # pinned agent image versions (no :latest)
IMAGE="${COORDINATOR_IMAGE:-${AGENT_COORDINATOR_IMAGE:-ghcr.io/teststuffstash/agent-coordinator:latest}}"   # ships Claude Code + gh wrapper
REPO_SLUG="${REPO_SLUG:-teststuffstash/${PROJECT}}"
REVIEWER_GIT="${REVIEWER_GIT:-reviewer-git}"   # Secret w/ the review-bot App token — MUST differ from the PR author's App
# STEP 0 resolves its own identity from THIS literal, substituted into the prompt below — never at
# runtime (#126): `gh api user` is a user-to-server call and 403s for an App INSTALLATION token, so
# every self-guard branch that compares against "my own verdict" was unexecutable. Injecting it also
# works on the ADR-096 loop-home path, where the reviewer-git Secret is absent entirely.
# ⚠ NO `[bot]` suffix: REST reports the App as homelab-reviewer[bot], but `gh pr view --json reviews`
# is GraphQL-backed and returns `homelab-reviewer` — the suffixed form NEVER appears in
# reviews[].author.login, and matching it would silently stop the guard recognising its own verdicts
# (worse than the loud 403). Same value + same default as review-reflex.sh's REVIEWER_LOGIN.
REVIEWER_LOGIN="${REVIEWER_LOGIN:-homelab-reviewer}"   # the reviewer App's bot identity, as it appears in reviews[].author.login
# FU-092 (merge-path MP-G02): the pod name IS the (repo, pr, head-sha8) idempotency key — the
# same atomic-create test-and-set workers got 2026-07-21. A new push mints a new name (a
# legitimate re-review); event redelivery / edge+backstop races collide on the SAME name and the
# API server arbitrates. Head-sha probe failure degrades to the old timestamp name, loudly —
# the pod-label check + STEP-0 remain the belts on that path.
# >>>REPLAY:reviewer-currency-gate>>>
# CURRENCY GATE (2026-08-17): a launcher-side re-probe of the dispatch premise, the LAST check
# before pod creation — the FU-092 probe already fetches the PR head right here, so piggybacking
# state+mergeStateStatus costs ZERO extra API calls. 9 reviewer sessions burned as STANDING-ASIDE
# today: each dispatched at a green+current head, BEHIND by pod-execution — the pod and its
# subscription semaphore slot were already spent. The in-pod STEP-0 stays the belt behind this
# gate; probe FAILURE is fail-OPEN (a GitHub blip must not block every review).
PR_JSON="$(gh pr view "$PR" --repo "$REPO_SLUG" --json headRefOid,state,mergeStateStatus 2>/dev/null)" || PR_JSON=""
PR_STATE="$(printf '%s' "$PR_JSON" | jq -r '.state // empty' 2>/dev/null)" || PR_STATE=""
PR_MERGE_STATE="$(printf '%s' "$PR_JSON" | jq -r '.mergeStateStatus // empty' 2>/dev/null)" || PR_MERGE_STATE=""
HEADSHA8="$(printf '%s' "$PR_JSON" | jq -r '.headRefOid // empty' 2>/dev/null | cut -c1-8)" || HEADSHA8=""
if [ -n "$PR_STATE" ] && [ "$PR_STATE" != "OPEN" ]; then
  echo "→ review of ${REPO_SLUG}#${PR} skipped — PR is ${PR_STATE} (currency gate; nothing to review)"
  exit 0
fi
if [ "$PR_MERGE_STATE" = "BEHIND" ] || [ "$PR_MERGE_STATE" = "DIRTY" ]; then
  echo "→ review of ${REPO_SLUG}#${PR} skipped — head is ${PR_MERGE_STATE} at spawn time (currency gate: the level-triggered path re-picks when current; was a STANDING-ASIDE pod burn before)"
  exit 0
fi
if [ -n "$HEADSHA8" ]; then
  POD="reviewer-${PROJECT}-${PR}-${HEADSHA8}"
else
  echo "WARN: head-sha probe failed — timestamp pod name (idempotency belts: pod-label check + STEP-0 only)" >&2
  POD="reviewer-${PROJECT}-${PR}-$(date -u +%H%M%S)"
fi
# <<<REPLAY:reviewer-currency-gate<<<

# ── ADR-096: consult the router at the model-decision seam (POST /route) ──
# role: reviewer → class review; the class policy orders the subscription rail first, so behaviour
# is unchanged while capacity is ok — the routed pick replaces the literal, not the doctrine.
# AGENT_ROUTER=shadow (default): consult + log the divergence, dispatch unchanged.
# =authoritative: the decision REPLACES the model — but an explicit --model always wins.
# =off: today's behavior exactly.
# decorrelate_from is the M5 evidence row (the newest round's SERVED model, never the requested
# id) — the router excludes that FAMILY across rails (#516's primitive).
# Fail-open: unreachable proxy → static behavior, one loud line.
_srow="$(jq -c --arg p "$PROJECT" '[.stacks[] | select(.repos[]? == $p)][0] // {}' "$HERE/stacks.json" 2>/dev/null)" || _srow="{}"
[ -n "$_srow" ] || _srow='{}'
_stack_rmode="$(printf '%s' "$_srow" | jq -r '.routerMode // ""')"
if [ -z "${AGENT_ROUTER:-}" ] && [ -n "$_stack_rmode" ]; then AGENT_ROUTER="$_stack_rmode"; fi
AGENT_ROUTER="${AGENT_ROUTER:-shadow}"
# FU-188 INCIDENT PIN (2026-08-26): the review-class route can return an openrouter-rail model
# (the ADR-115 market basis), which this subscription-only session cannot ride — the pod is
# hardwired to the /anthropic surface, so the ride 404s with no verdict AND no strike
# (oracle-fleet#277: 72 dead dispatches/24h, zero generations, router re-picks forever). Until
# FU-188 legs (a)+(b) land, the reviewer consults in shadow at most; workers are untouched
# (chainless stacks REQUIRE authoritative — agent-session.sh chainless-guard).
if [ "$AGENT_ROUTER" = "authoritative" ]; then
  echo "→ router: authoritative DOWNGRADED to shadow for the reviewer (FU-188 incident pin)"
  AGENT_ROUTER="shadow"
fi
if [ "$AGENT_ROUTER" != "off" ]; then
  ROUTER_URL="${AGENT_EGRESS_PROXY:-${AGENT_OPENROUTER_PROXY:-http://openrouter-proxy.agent-egress.svc.cluster.local:8080}}"
  # No chain sent for reviewer — the class policy (class review) orders the rails server-side.
  # No key_ref — the reviewer uses the subscription rail exclusively (ref:coordinator-claude).
  # >>>REPLAY:route-request>>>
  _route_labels="[]"
  _route_urgency=""
  _task="${TASK_KEY:-review-${PROJECT}-${PR}}"
  _req="$(jq -nc --arg stack "$(printf '%s' "$_srow" | jq -r '.name // ""')" \
      --arg task "$_task" --arg session "reviewer-${PROJECT}-${PR}-r${ROUND}" \
      --arg urgency "$_route_urgency" \
      --argjson labels "$_route_labels" \
      --arg decorrelate_from "${DECORRELATE_FROM:-}" \
      '{stack: $stack, task: $task, role: "reviewer", session: $session,
        decorrelate_from: (if $decorrelate_from == "" then null else $decorrelate_from end),
        labels: $labels, urgency: (if $urgency == "" then null else $urgency end)}')"
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
      if [ -n "${MODEL_SET_EXPLICIT:-}" ]; then
        echo "→ router: explicit --model ${MODEL} wins over the routed decision (ADR-096 override rule)"
      elif [ "$_verdict" = "dispatch" ] && [ -n "$_rmodel" ]; then
        MODEL="$_rmodel"; _router_adopted=1
        # Consume the structured carrier when available
        _resolved="$(printf '%s' "${_decision:-}" | jq -r '.resolved // empty' 2>/dev/null)"
        if [ -n "$_resolved" ] && [ "$_resolved" != "null" ]; then
          MODEL_RAIL="$(printf '%s' "$_resolved" | jq -r '.rail // ""')"
          MODEL_HARNESS="$(printf '%s' "$_resolved" | jq -r '.harness // ""')"
          MODEL_MODEL="$(printf '%s' "$_resolved" | jq -r '.model // ""')"
          if [ -n "$MODEL_MODEL" ]; then
            eval "$(python3 "$HERE/model_id.py" --shell "$MODEL")"
          fi
        fi
        GO_SERVED=0
        [ "${MODEL_RAIL:-}" = "opencode-go" ] && GO_SERVED=1
      elif [ "$_verdict" = "defer" ]; then
        _router_defer=1
      fi
    fi
  fi
  # <<<REPLAY:route-request<<<
fi

# In-pod prep, run under `bash -lc` so the image's gh-wrapper (reads the LIVE ~1h token from
# GH_TOKEN_FILE) is on PATH. gh repo clone → a full clone (master present) so /code-review can diff
# the PR branch against the base; gh pr checkout fetches the PR head + sets the branch /code-review
# and `--comment` resolve the PR from. Append the rubric only if the project ships one (an absent
# --append-system-prompt-file path is a hard error — the coordinator hit exactly that).
# FU-090 rung 2 + S6 child 1: depth-rule-append applies the lane-split depth guard.
# Defined at TOP LEVEL (genuinely outside the PREP heredoc — the first cut sat INSIDE it after
# a quote that was heredoc TEXT, so every unescaped $ expanded at generation time and the pod
# got a corrupted function; seat gate-read catch, 2026-08-20). The definition stays unescaped
# here so the replay extraction runs it verbatim; the pod script receives it via the
# $(declare -f) injection inside the heredoc below — command-substitution results are not
# re-expanded, so $1/$PROMPT survive to pod-time.
# >>>REPLAY:s6-child-1-depth-rule>>>
depth-rule-append() {
  # Args: SPROUT_DEPTH PR_BASE ISSUE_TITLE ISSUE_BODY ISSUE REPO_SLUG
  # Mutates: PROMPT
  # Returns: 0 if rule was appended, 1 otherwise
  local sprout_depth="$1" pr_base="$2" issue_title="$3" issue_body="$4" issue="$5" repo_slug="$6"

  if [ "${sprout_depth:-0}" -lt 2 ]; then
    return 1
  fi

  local is_goal_lane=false
  case "$pr_base" in
    goal/*) is_goal_lane=true;;
  esac

  if [ "$is_goal_lane" = true ]; then
    # Goal-lane (code-first): suppress Follow-ups at depth ≥2
    PROMPT="$PROMPT
DEPTH RULE (this PR closes issue #$issue, which sits at follow-up depth $sprout_depth — a follow-up of a follow-up). You are near the end of a sprout chain, where each extra deferral costs another issue, another dispatch and another review for steadily smaller returns. So DO NOT emit a Follow-ups: section at all in this review. Each finding gets exactly one of two fates: if it genuinely must not ship, make it a BLOCKING finding and request changes so it is fixed in THIS PR; otherwise drop it, or leave it as a plain review comment that no one will file. Collapse the tail — that judgement is yours to make here and nobody else gets the chance."
    return 0
  fi

  if [ "${sprout_depth:-0}" -lt 4 ]; then
    return 1
  fi

  # Organic lane, depth ≥4: check hotfix status
  local issue_is_hotfix=false
  case "$issue_title" in
    🚨*) issue_is_hotfix=true;;
  esac
  if printf '%s' "$issue_body" | grep -qE '^alert-fp:'; then
    issue_is_hotfix=true
  fi

  if [ "$issue_is_hotfix" = false ]; then
    # Non-hotfix: emit Container-findings instead of Follow-ups
    PROMPT="$PROMPT
DEPTH RULE (this PR closes issue #$issue, which sits at follow-up depth $sprout_depth — a follow-up of a follow-up). You are near the end of a sprout chain. Since this is not a hotfix-class issue (no alert-fp: line or 🚨 title marker), emit findings ONLY under a 'Container-findings:' heading instead of 'Follow-ups:', one concrete bullet each, written so it can become a backlog issue verbatim. Container-findings get merged into the ancestor issue as a comment post-deploy rather than minting new issues — that is how deep chains converge. Classify findings as before: BLOCKING if it makes master worse, otherwise drop it or leave a plain review comment. A Container-findings finding that is BLOCKING still requests changes so it gets fixed in THIS PR."
    return 0
  fi

  return 1
}
# <<<REPLAY:s6-child-1-depth-rule<<<

# FU-101 lens posture: read the per-stack lenses→posture map from the SAME single claim read
# that feeds the optout gate (reviewer-optout.sh). This costs zero extra cluster calls and
# cannot straddle a claim edit the way two reads can. Fail-closed: unreadable → empty map
# (every lens stays advisory, consistent with the optout gate's posture).
# >>>REPLAY:lens-posture-gate>>>
LENS_MAP="$(bash "$HERE/reviewer-optout.sh" --lens-map "$PROJECT" 2>/dev/null || echo "{}")"
# <<<REPLAY:lens-posture-gate<<<

# ── CAPABILITY CARD (homelab#1055) ──────────────────────────────────────────
# Generate the reviewer's capability card from the mint sources, prepended to
# the system prompt so the LLM knows its own identity, permissions, and failure
# signatures. Accurate by construction (FU-049 generate-from-sources rule);
# NEVER a hand-authored index file.
CAPABILITY_CARD=""
if [ -f "${HERE}/coordinator/reviewer-git.yaml" ]; then
  _PERMS=$(sed -n '/permissions:/,/^[a-z]/p' "${HERE}/coordinator/reviewer-git.yaml" | grep '^    [a-z]' | sed 's/^    //;s/  *#.*//')
  CAPABILITY_CARD="── CAPABILITY CARD (generated from mint sources) ──
Identity: homelab-reviewer[bot] (reviewer-git)
Minted permissions (from agents/coordinator/reviewer-git.yaml):
${_PERMS}

Declared permissions: docs/github-apps.yaml (homelab-reviewer entry)
Live view: github-exporter.monitoring.svc:9504/apps.md

Failure signatures:
  REST 403 \"Resource not accessible by integration\" → the response header
    \`x-accepted-github-permissions\` NAMES the needed permission — re-run with \`gh api -i\`.
  GraphQL NOT_FOUND/null under an App token → NOT evidence of nonexistence;
    cross-check REST, which fails honestly and names the permission.
────────────────────────────────────────────────────────────────────────────────"
fi

PREP=$(cat <<PREP
set -e
${LOOP_FETCH}gh repo clone ${REPO_SLUG} /work/repo -- --quiet
cd /work/repo
gh pr checkout ${PR}
# MCP config (#1041): injected from the launcher-side MCP_PREP (built above the replay region).
# Knob absent → MCP_PREP is empty → blank line, nothing attached.
${MCP_PREP}
# >>>REPLAY:issue-derivation>>>
# FU-061: key the transcript by the ISSUE the PR fixes (not the PR), so a PR's reviews land beside
# the worker rounds + coordinator ticks for the same issue. Resolve via GitHub's closing-issue
# reference ("Fixes #N"); fall back to parsing the PR body for a closing keyword when
# closingIssuesReferences is empty (e.g. PR base != default branch — #1189); then pr-<N>.
_PR_META=\$(gh pr view ${PR} --json closingIssuesReferences,baseRefName,body 2>/dev/null || true)
ISSUE=\$(printf '%s' "\$_PR_META" | jq -r '.closingIssuesReferences[0].number // empty' 2>/dev/null || true)
PR_BASE=\$(printf '%s' "\$_PR_META" | jq -r '.baseRefName // empty' 2>/dev/null || true)
# Fallback (#1189): when closingIssuesReferences is empty (GitHub omits it for non-default-base
# PRs), parse the PR body for a closing keyword (close|closes|closed|fix|fixes|fixed|
# resolve|resolves|resolved) followed by #<n>, case-insensitive.
if [ -z "\$ISSUE" ] || [ "\$ISSUE" = "null" ]; then
  _PR_BODY=\$(printf '%s' "\$_PR_META" | jq -r '.body // ""' 2>/dev/null || true)
  _BODY_ISSUE=\$(printf '%s' "\$_PR_BODY" | grep -ioE '\b(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)\s+#([0-9]+)\b' | head -1 | grep -oE '[0-9]+' || true)
  if [ -n "\$_BODY_ISSUE" ]; then
    ISSUE="\$_BODY_ISSUE"
    echo "→ ISSUE derived from PR body closing keyword: #\$_BODY_ISSUE"
  fi
fi
# <<<REPLAY:issue-derivation<<<
ISSUE_TITLE=""
ISSUE_BODY=""
ISSUE_UNREADABLE=0
if [ -n "\$ISSUE" ] && [ "\$ISSUE" != "null" ]; then
  _ISSUE_JSON=\$(gh api "repos/\${REPO_SLUG}/issues/\${ISSUE}" 2>/dev/null || true)
  if [ -z "\$_ISSUE_JSON" ] || [ "\$_ISSUE_JSON" = "null" ]; then
    ISSUE_UNREADABLE=1
    echo "→ ISSUE_UNREADABLE: issue #\$ISSUE read failed (403/NOT_FOUND) — cannot verify Touches: footprint; no verdict will be emitted (homelab#1055)"
  else
    ISSUE_TITLE=\$(printf '%s' "\$_ISSUE_JSON" | jq -r '.title // ""' 2>/dev/null || true)
    ISSUE_BODY=\$(printf '%s' "\$_ISSUE_JSON" | jq -r '.body // ""' 2>/dev/null || true)
  fi
fi
if [ -n "\$ISSUE" ] && [ "\$ISSUE" != "null" ]; then TASK_KEY="issue-\$ISSUE"; else TASK_KEY="pr-${PR}"; ISSUE=""; fi
export TASK_KEY ISSUE PR_BASE ISSUE_TITLE ISSUE_BODY ISSUE_UNREADABLE
echo "→ transcript task key: \$TASK_KEY (fixes issue \${ISSUE:-none})"
# ── SPROUT DEPTH (FU-090 rung 2, 2026-08-05) ───────────────────────────────────────────────────
# How deep in the follow-up tree is the issue this PR closes? The harvest already flags depth ≥2
# AFTER the fact — which is too late by construction: by then the PR has merged and "fix it in
# this PR" is no longer an option. Rung 2's rule ("deep → fix-in-PR and collapse the tail") is a
# REVIEWER decision, so the depth has to arrive here, before the Follow-ups: bullets are written.
# Walks the native parent chain; 0 = not a sprout. Failure leaves it 0 (advisory, never blocking).
SPROUT_DEPTH=0
if [ -n "\$ISSUE" ]; then
  _cur="\$ISSUE"
  for _hop in 1 2 3 4 5 6; do
    _par=\$(gh api "repos/${REPO_SLUG}/issues/\$_cur/parent" --jq '.number' 2>/dev/null || true)
    case "\$_par" in ''|*[!0-9]*) break;; esac
    SPROUT_DEPTH=\$_hop; _cur="\$_par"
  done
fi
export SPROUT_DEPTH
echo "→ sprout depth: \$SPROUT_DEPTH (0 = not a follow-up of a follow-up)"
# FU-101 review lenses: a DETERMINISTIC diff-class predicate selects externally-sourced ADVISORY
# lens briefs (agents/lenses/*.md, platform-owned), fetched from the public homelab repo at review
# time (no image rebuild, always current-pinned) and appended to the system prompt AFTER the
# project rubric. Advisory framing lives inside each lens file (findings = Follow-ups, never the
# verdict); a fetch failure skips the lens loudly — lenses must never block a review.
LENS_BASE="\${LENS_BASE:-https://raw.githubusercontent.com/teststuffstash/homelab/master/agents/lenses}"
CHANGED="\$(gh pr view ${PR} --json files -q '.files[].path' 2>/dev/null || true)"
LENSES=""
printf '%s\n' "\$CHANGED" | grep -qE '^charts?/' && LENSES="helm"
if printf '%s\n' "\$CHANGED" | grep -qE '^charts?/templates/|^(argocd|k8s|manifests|deploy)/.*\.ya?ml\$' \
   || gh pr diff ${PR} 2>/dev/null | grep -qE '^\+.*kind: *(Deployment|StatefulSet|DaemonSet|CronJob)\b'; then
  LENSES="\$LENSES k8s-prod"
fi
# >>>REPLAY:asvs-predicate>>>
# ASVS lens: code-class predicate for auth/input/session code (issue#833).
# Prefers quiet miss — see agents/lenses/asvs.md for false-positive analysis.
# Signals: auth imports, auth function definitions, session management, input parsing,
# new public endpoint route registrations across Go/Python/TypeScript.
if gh pr diff ${PR} 2>/dev/null | grep -qE \
  '^\+.*(import|from|using|require)\s+.*(auth|jwt|oauth|saml|oidc|csrf|cors|bcrypt|argon2|passport)' \
  || gh pr diff ${PR} 2>/dev/null | grep -qE \
  '^\+.*(func.*[^A-Z](Login|Logout|Auth|Authenticate|Authorize|Register|Signup|Token|Session|Refresh|Middleware|Guard)|def.*[^a-z](login|logout|auth|authenticate|authorize|register|signup|session|token|refresh|middleware|guard))' \
  || gh pr diff ${PR} 2>/dev/null | grep -qE \
  '^\+.*(session\.(Save|Get|Set|Delete|Destroy|Regenerate|Start|Create)[^a-z]|csrf\.(Protect|Token|Middleware)|cors\.(New|Allow|Handle)|ParseForm|ParseMultipartForm|\.Bind\(|\.Validate\(|\.Sanitize\(|\.Escape\()' \
  || gh pr diff ${PR} 2>/dev/null | grep -qE \
  '^\+.*(http\.(Handle|HandleFunc|ServeMux)|HandleFunc\(|mux\.(NewRouter|Handle|Methods|Headers)|gin\.(Default|New|Group|RouterGroup)|echo\.(New|Group|Route)|chi\.(NewRouter|Route|Group|Mux))' \
  || gh pr diff ${PR} 2>/dev/null | grep -qE \
  '^\+.*(router\.(get|post|put|delete|patch|GET|POST|PUT|DELETE|PATCH)\(|@(Get|Post|Put|Delete|Patch)\(|app\.(get|post|put|delete|patch|route|router)|@app\.route\(|@router\.(get|post|put|delete|patch)\(|\.add_url_rule\()'; then
  LENSES="\$LENSES asvs"
fi
# <<<REPLAY:asvs-predicate<<<
SYSFILE=/tmp/review-system.md
if [ -f "${RUBRIC}" ]; then cp "${RUBRIC}" "\$SYSFILE"; else : > "\$SYSFILE"; fi
# Lens posture map from the single claim read (FU-101): absent lenses → advisory
LENS_MAP='$LENS_MAP'
# >>>REPLAY:lens-posture-handling>>>
for l in \$LENSES; do
  _posture=\$(printf '%s' "\$LENS_MAP" | jq -r --arg l "\$l" '.[\$l] // "advisory"' 2>/dev/null || echo "advisory")
  if { printf '\n\n---\n\n'; curl -fsS --max-time 10 "\$LENS_BASE/\$l.md"; } >> "\$SYSFILE"; then
    if [ "\$_posture" = "blocking" ]; then
      printf '\n**POSTURE: blocking** — findings from this lens MAY determine the verdict.\n' >> "\$SYSFILE"
      echo "→ lens attached: \$l (BLOCKING — \$_posture)"
    else
      echo "→ lens attached: \$l (advisory — FU-101)"
    fi
  else
    if [ "\$_posture" = "blocking" ]; then
      echo "WARN: lens \$l fetch FAILED — lens is BLOCKING for this stack, but review proceeds without it (a blocking lens that cannot be fetched must NOT silently become advisory)"
    else
      echo "WARN: lens \$l fetch failed — review proceeds without it (advisory-only, never blocks)"
    fi
  fi
done
# <<<REPLAY:lens-posture-handling<<<
RUBRIC_FLAG=""
[ -s "\$SYSFILE" ] && RUBRIC_FLAG="--append-system-prompt-file \$SYSFILE"
echo "→ reviewing ${REPO_SLUG}#${PR} on \$(git rev-parse --abbrev-ref HEAD) (model: \${MODEL}); rubric: \${RUBRIC_FLAG:-<none>}"
PROMPT='
${CAPABILITY_CARD}

Review pull request #${PR} on the checked-out branch.

STEP 0 — SELF-GUARD (you are the LAST line of defense against automation loops): run  gh pr view ${PR} --json reviews,comments,commits,labels,mergeStateStatus,statusCheckRollup,headRefOid  and check the review history against your OWN bot identity, which is the literal login  ${REVIEWER_LOGIN}  — use that string, do NOT look it up at runtime (you authenticate with an App INSTALLATION token, for which  gh api user  returns 403, and note the login carries no [bot] suffix here). Your own verdicts, and your own asides below, are exactly the entries whose author.login is  ${REVIEWER_LOGIN} . The guard REFUSES in every case it refused before — what changed (homelab#122, 2026-08-08) is only WHICH terminal a refusal picks. Sort what you see into one of two classes; you submit NO review in either.
  (a) PRECONDITION FAILURE — the dispatch premise was true when you were QUEUED and stopped being true before you EXECUTED. Under semaphore queueing that gap routinely reaches ~10 minutes, so this is ordinary contention, not a malfunction, and the machinery resolves it without a human: the review path is LEVEL-TRIGGERED (an Argo Events edge plus a */15 CronWorkflow backstop), so the state settling IS the re-dispatch. Post ONE short standing-aside comment (gh pr comment ${PR} --body ...) naming the precondition and the head sha, add NO label, submit NO review, do not re-litigate the diff, and stop. Exactly these states are preconditions:
    • mergeStateStatus is DIRTY or UNKNOWN. DIRTY belongs to the merge-conflict lane (the coordinator dispatches a worker to rebase); UNKNOWN means GitHub is still computing mergeability and clears in seconds. Latching agent/error here would wedge the PR out of the very lane that owns its state, because agent/error excludes it from EVERY clause.
    • the checks on the CURRENT head have not concluded — some check is QUEUED/PENDING/IN_PROGRESS, or nothing has reported yet (gh pr checks ${PR}). Your dispatch premise was green-at-head; a push or a re-run since then belongs to the next pass, not to you. (A check that concluded FAILURE is not this case and is not yours either — the coordinator ci-red clause owns it. Stand aside the same way and name what you saw.)
    • a LIVE verdict of YOUR OWN identity already exists for THIS EXACT COMMIT, i.e. submitted at or after the newest non-merge commit. Count ONLY reviews whose state field is APPROVED or CHANGES_REQUESTED in the reviews JSON — exactly the filter the reflex breaker count uses. A review shown DISMISSED is an ENDED round (someone dismissed it — a coordinator arbitration ruling or a human), NOT a verdict: never count it and never reconstruct its original state, because the dismissal is the point — the PR is reviewable again and the level-triggered path re-dispatches it. Counting a dismissed review as your own verdict refuses that re-review forever (homelab#556). A live verdict at head means another pass got there first; the work is done and its record is already on the PR.
    • the linked issue could not be read (403/NOT_FOUND) — ISSUE_UNREADABLE. When the OWN credential of the reviewer cannot read the issue this PR claims to fix, the session must NOT emit a content verdict from that premise. The Touches: footprint, sprout depth, and issue body are all unavailable; a verdict built without them is unreliable (homelab#1038: four false CHANGES_REQUESTED on sleep-tracking#137). Post a standing-aside comment with pre=issue-unreadable, emit a TOOL_GAP line naming the issue read failure, and stop. On reproduction (a second session hitting the same unreadable issue), escalate via the platform-intake filing contract (coordinator README, "Cross-boundary filing") — do NOT keep standing aside.
  IDEMPOTENT ASIDE — the aside is keyed by (content commit, precondition), NOT by pass and NOT by the branch tip. Before posting, read the existing comments — the  comments  field of the STEP 0 call above already has them, no second call needed: if one of YOUR asides (author.login  ${REVIEWER_LOGIN} ) already carries a marker naming the newest NON-MERGE commit AND this same precondition, post NOTHING and exit silently. Several passes can hit one precondition while the queue drains, and a pile of near-identical bot comments is itself an anomaly signal — never manufacture the thing this guard watches for. The dedup key is a MACHINE MARKER (ADR-103 channel-separation precedent: match on the marker, never on prose — two asides for the same precondition whose only difference is the prose tail never match; the PR#547 asides landed at efc90c5a and at fd2efc80 for one content commit), first line exactly:
    STANDING ASIDE: <precondition> at <content-commit-sha8> — no verdict; the level-triggered review path re-dispatches when this settles. <!-- standing-aside head=<content-commit-sha8> pre=<precondition-slug> -->
  The marker  head  field is the newest NON-MERGE commit — the content the review is about — NOT the branch tip, which moves on every  Merge branch master  no-op (an update-branch push is not new content). The  pre  slug is exactly one of  merge-state | checks-pending | own-verdict-at-head | issue-unreadable. A later pass must produce the SAME marker for the same content commit + same precondition, or the dedup never matches and the guard manufactures the pile it watches for.
  (b) GENUINE ANOMALY — a state the machinery CANNOT resolve by dispatching again later. Trip the breaker: run  gh pr edit ${PR} --add-label agent/error  (your token has issues:write since 2026-07-16 — homelab FU-069 b) and post exactly ONE comment starting with AGENT_ERROR: stating what you saw, then stop. This terminal keeps every state it already owned: MORE THAN ONE LIVE (non-DISMISSED) verdict from your identity at the current head, or a pile of near-identical bot reviews or comments (that is the dispatcher loop this breaker was built for — oracle-fleet#57 burned nine sessions before it tripped); a review history that cannot be reconciled with the commit history; contradictory labels; a PR that plainly should not have reached you. Unchanged too: an agent/error label ALREADY present means someone tripped it before you — add nothing, touch nothing, stop silently (no aside either).
  THE TEST, when you cannot tell which class you are in: will this state look different if the reflex dispatches me again in fifteen minutes? Yes → precondition: aside, no label, stop. No → anomaly: label, one AGENT_ERROR: comment, stop. A burned session that stands aside is a GOOD outcome, and so is one that files a single anomaly report; a duplicate verdict is neither.

STEP 1 — classify the PR: run  gh pr view ${PR} --json labels,title,files  and decide which kind it is.

If it is a DEPENDENCY / TOOLCHAIN bump — it carries a label of major or deps-review, or it changes only devbox.lock / devbox.json / a lockfile AND crosses a MAJOR version — then a diff skim is NOT enough. Do a MIGRATION INVESTIGATION:
  1. List each tool whose MAJOR version changed, old -> new (read it from the lockfile diff).
  2. Fetch that tool major-version upstream release / migration notes with WebFetch and read the breaking-changes section. If egress blocks the fetch, reason from your own knowledge of that major and say so explicitly.
  3. Map every breaking change onto THIS repo actual usage: grep how the tool is invoked under scripts/, .github/, chart/, Makefile, and the devbox scripts in devbox.json. For each spot that must change, post an INLINE PR comment naming the exact change and citing the migration note.
  4. Note genuinely useful NEW capabilities of the major as ONE short, non-blocking follow-up comment.
  Verdict: --request-changes if ANY adaptation is required (a worker will fix it on this branch and you re-review); --approve only once every breaking change is either N/A or already handled in the diff. A major bump is HUMAN-GATED (not auto-merged): your review DOCUMENTS the migration so a human can merge with confidence — do not expect auto-merge.

THE REQUIRED CHECKS ARE ALREADY GREEN — NEVER ASK A HUMAN TO RE-RUN THE GATE. You were dispatched by review-reflex.sh, whose pick predicate includes  select(green)  — every check on this head reported SUCCESS/NEUTRAL/SKIPPED and at least one check existed. A red PR CANNOT reach you (the coordinator routes those to the worker via its ci-red clause) — that held when you were DISPATCHED, and STEP 0 is where you re-check it at EXECUTION time: a head that is red or still running when YOU look is a STEP 0 precondition (stand aside, no label), never a finding and never a reason to ask for a re-run. Your sandbox deliberately has no devbox and no network — you READ the diff, you never execute project code (CI does). That is the design, not a limitation of your run, so do not report it as one, and never close a review with "someone with a working devbox should confirm the tests pass": that is the gate re-litigating itself through you.
  ⚠ PRECISION: what is guaranteed is that the checks PASSED — NOT what they COVER. Most stacks make CI run  devbox run ci  (the same gate you would run locally), but a repo whose .github/workflows/ defines CI as something narrower makes "green" a weaker statement. You have the repo CHECKED OUT: if a finding of yours turns on whether CI actually exercises something, READ  .github/workflows/  and say what you found — no API call, no permission needed. For check-level detail your token also carries checks/statuses/actions:read (operator grant 2026-07-10):  gh pr checks ${PR} . The project rubric (.agents/review*.md) is what says how much the local gate is worth in THIS repo; it wins over this paragraph.
  What you must still state plainly is which of YOUR OWN judgments are unverified — "I did not trace this caller", "I could not tell whether X regresses under concurrency". Those are honest limits. "Please run the tests" is not.

  TOOL GAPS (homelab#536) — when a NAMED diagnostic or tool is unavailable and its absence changed what you could verify (an egress-blocked WebFetch, a gh verb your token 403s on, a read you could not take), emit ONE line in your review body or a PR comment whose first characters are exactly "TOOL_GAP: <tool-or-verb> — <what it was needed for, one clause>", once per session per tool. Evidence, not lobbying — never a request for the grant, and never the deliberate devbox/network absence in this sandbox (that is the design above, not a gap): name one only where the absence actually changed your verdict.

Otherwise (a normal code PR): run /code-review to find correctness bugs and post them as inline PR comments — then apply the MERGE-FORWARD VERDICT DOCTRINE:
  The verdict question is NOT "is this perfect?" — it is "is master better off WITH this PR than without it?" Classify every finding you made:
    BLOCKING (--request-changes): the diff makes master WORSE or lands something unrecoverable — leaked secrets/credentials, committed binary blobs, CI red, breaking/deleting behavior that already worked on master, or (only in a repo whose rubric declares it PROD-SERVING) violating a pinned invariant in a way real consumers would ingest, OR the diff is an INCOMPLETE version of its OWN fix — a defect of the SAME CLASS this PR is fixing that the fix demonstrably missed (it guards N of N+1 sibling cases: e.g. a COALESCE guard applied to 13 of 14 band columns with the 14th left to clobber). Requesting the missed sibling COMPLETES the job this PR set out to do, on this branch — that is finishing the fix, NOT piling a new round, so it is exempt from the merge-forward backlog bias below (do not defer a finding that makes the PR self-inconsistent with its own stated fix). The project rubric (.agents/review.md) may tighten or relax this set — the rubric wins.
    FOLLOW-UP (approve anyway): everything else — correctness edges in NEW code, unhandled input shapes you constructed, spec ambiguities you uncovered, dead code, style, missing tests. List each under a "Follow-ups:" heading in the review body, one concrete bullet each, written so it can become a backlog issue verbatim. HARVEST BAR — a Follow-up must be worth a human opening the issue: if you would yourself qualify the finding as inert (no caller reaches it), not-a-gap (existing coverage already exercises it), wont-fix (not worth guarding unless actually seen), or pure style-preference (the current code is clear as-is), it is a review COMMENT at most, NEVER a Follow-ups bullet — filing it as a tracked issue is noise that sprouts across runs without ever converging. A spec ambiguity is a proposed AMBIGUITY row for specs/, never a blocker.
  A greenfield / pre-prod repo (the rubric says which) biases HARD toward approve-with-follow-ups: with no consumers there is no "good enough" judgment to fail — forward progress merges NOW, and each residual finding becomes its own issue with its own round budget (which is cheaper and converges faster than piling rounds onto one PR). This is what a human author would negotiate: "better than master, merge it, backlog the nits." Do NOT re-litigate follow-ups already filed from earlier reviews of this same PR.

STEP FINAL — submit exactly ONE native GitHub review as your verdict: run gh pr review ${PR} --approve --body with the Follow-ups: section (when non-empty) if the diff moves master forward, otherwise gh pr review ${PR} --request-changes --body with a one-paragraph summary of the BLOCKING findings only (for a dependency bump, summarise the required adaptations). Do NOT merge and do NOT push.'
# the depth-rule-append definition is injected here at generation time (declare -f;
# see the top-level definition + rationale above the PREP heredoc)
$(declare -f depth-rule-append)

# FU-090 rung 2: the depth-conditional half of the harvest bar. The bar above filters follow-ups by
# QUALITY; this filters by POSITION. A finding on a sprout-of-a-sprout is not less true, it is less
# worth another issue — the tail has to collapse somewhere, and the only actor who can collapse it
# is the one deciding whether to defer or block. Appended as a MECHANISM so no recipe has to
# remember it, and only when it applies: a depth-0 review is untouched.
if [ "\${SPROUT_DEPTH:-0}" -ge 2 ]; then
  depth-rule-append "\${SPROUT_DEPTH}" "\${PR_BASE}" "\${ISSUE_TITLE}" "\${ISSUE_BODY}" "\${ISSUE}" "\${REPO_SLUG}" || true
fi
PREP
)
# Dispatch-time syntax guard (homelab#1113): verify each assembled heredoc parses before
# spawning a pod. The defect class lives in the ASSEMBLED pod script, not in the source file,
# so it is invisible to `bash -n` on this file and invisible to replay.
# An apostrophe in an interpolated variable (e.g. CAPABILITY_CARD from reviewer-git.yaml)
# would break the single-quoted PROMPT='...' assembly — this catches it host-side.
if ! printf '%s\n' "$PREP" | bash -n /dev/stdin 2>/dev/null; then
  echo "FATAL: PREP heredoc has a syntax error — review dispatch aborted before pod creation (homelab#1113)" >&2
  exit 1
fi

# ── TOUCHES: FOOTPRINT CHECK (ADR-097, homelab#379) — a POD-SIDE part, quoted heredoc ──────────
# Runs in the pod AFTER $PREP (so $ISSUE, $CHANGED and $PROMPT already exist there), which is why
# it is a separate quoted part and not more PREP: inside the unquoted <<PREP heredoc every one of
# these references would need backslash-escaping to survive to the pod, and round 5 of PR#473
# proved that class of defect is invisible to CI and replay alike (the block compiled to dead code
# in the launcher). The helper pair is fetched master-pinned from the public homelab repo — the
# FU-101 lens pattern — because the review pod only holds the PROJECT's clone; a launcher path
# like $HERE does not exist here. A safety belt must FAIL OPEN: $PREP's `set -e` is still live in
# this shell, so every fallible command is guarded, and any fetch/source/compute failure degrades
# to TOUCHES-ESCAPES: unavailable plus a WARN — never a dead review lane.
TOUCHESPART=$(cat <<'SNIP'
# >>>REPLAY:reviewer-touches-check>>>
TOUCHES_ESCAPES="unavailable"
if [ -z "${ISSUE:-}" ]; then
  TOUCHES_ESCAPES="undeclared"
  echo "→ TOUCHES: undeclared (PR closes no issue)"
else
  TOUCHES_BASE="${TOUCHES_BASE:-https://raw.githubusercontent.com/teststuffstash/homelab/master/agents}"
  _tc_ok=1
  _tc_dir="$(mktemp -d)" || _tc_ok=0
  if [ "$_tc_ok" = "1" ]; then
    for _tc_f in touches-check.sh footprint.sh; do
      curl -fsS --max-time 10 "$TOUCHES_BASE/$_tc_f" -o "$_tc_dir/$_tc_f" || { _tc_ok=0; break; }
    done
  fi
  if [ "$_tc_ok" = "1" ]; then
    . "$_tc_dir/touches-check.sh" 2>/dev/null || _tc_ok=0
  fi
  if [ "$_tc_ok" = "1" ]; then
    ISSUE_BODY=$(gh api "repos/$REPO_SLUG/issues/$ISSUE" --jq '.body // ""' 2>/dev/null || true)
    # UNION of every Touches: line (S6 sprout, #716: a later line supersedes/widens the original
    # footprint — head -1 ran the check against the stale first line and self-reported false
    # escapes on PR#759; the scan's jq `scan(...) | join(",")` has always been the union).
    DECLARED_TOUCHES=$(printf '%s' "$ISSUE_BODY" | grep -iE '^[ \t]*touches:[ \t]*' | sed -E 's/^[ \t]*touches:[ \t]*//i' | tr -d '\r' | paste -sd, -)
    # #944 / ADR-097 addendum 3: files whose whole delta is REPLAY sentinel markers are a
    # compelled counterpart (extract() cannot pin a block without them) — CONTENT-verified from
    # the diff, never path-keyed. An unavailable diff yields the empty set: the exemption just
    # doesn't engage and the check stays strict (fail-conservative, not fail-open).
    _TC_DIFF=$(gh pr diff "${PR_NUMBER:-}" 2>/dev/null) || _TC_DIFF=""
    _TC_SENTINEL=$(sentinel_only_paths "$_TC_DIFF" 2>/dev/null) || _TC_SENTINEL=""
    ESCAPES_RAW=$(touches_check "$DECLARED_TOUCHES" "${CHANGED:-}" "$_TC_SENTINEL" 2>/dev/null) || { _tc_ok=0; ESCAPES_RAW=""; }
  fi
  if [ "$_tc_ok" = "1" ]; then
    if [ -n "$ESCAPES_RAW" ]; then
      TOUCHES_ESCAPES=$(printf '%s\n' "$ESCAPES_RAW" | while read -r line; do
        path="${line%%|*}"; marker="${line#*|}"
        if [ "$marker" = "governance" ]; then
          printf '[GOVERNANCE] %s\n' "$path"
        else
          printf '%s\n' "$path"
        fi
      done | sort)
      echo "→ TOUCHES: escapes detected (ADR-097 footprint check — homelab#379):"
      printf '%s\n' "$TOUCHES_ESCAPES" | sed 's/^/  /'
    else
      TOUCHES_ESCAPES="none"
      echo "→ TOUCHES: no escapes (all paths covered by declared footprint)"
    fi
  else
    echo "WARN: touches-check helpers unavailable (fetch/source/compute failed) — TOUCHES-ESCAPES: unavailable; the review proceeds (the belt fails open)"
  fi
fi
export TOUCHES_ESCAPES
PROMPT="${PROMPT:-}

TOUCHES: FOOTPRINT CHECK (ADR-097, homelab#379) — declared \`Touches:\` footprint against the changed paths:
  TOUCHES-ESCAPES: $TOUCHES_ESCAPES
Semantics: \`none\` = every changed path is covered by the closing issue's declared footprint; \`undeclared\` = this PR closes no issue, so there is no footprint to check; \`unavailable\` = the checker could not run — treat it as NO SIGNAL, not as clean; otherwise each listed path fell OUTSIDE the declared footprint. Files whose ENTIRE diff is REPLAY sentinel marker comments are already excluded (ADR-097 addendum 3, homelab#944 — a compelled edit, content-verified); do not re-derive an escape for them from the raw diff. When escapes land in governance paths (\`agents/**\`, \`.agents/**\`, \`scripts/**\`, \`policy/**\`, \`.github/**\`, \`tofu/github/**\`, \`tofu/cloudflare/**\`) — marked [GOVERNANCE] — the diff is BLOCKING per .agents/review.md §BLOCKING. This is computed fact for your rubric check, not a verdict.

ISSUE_UNREADABLE: ${ISSUE_UNREADABLE:-0}
If set (1), the linked issue could not be read (403/NOT_FOUND) by the reviewer's own credential. Do NOT emit a content verdict from this premise. Instead, emit a TOOL_GAP line naming the issue read failure and post a standing-aside comment with pre=issue-unreadable. The exit-contract terminal handling applies (homelab#1055)."
# <<<REPLAY:reviewer-touches-check<<<
SNIP
)
if ! printf '%s\n' "$TOUCHESPART" | bash -n /dev/stdin 2>/dev/null; then
  echo "FATAL: TOUCHESPART heredoc has a syntax error — review dispatch aborted before pod creation (homelab#1113)" >&2
  exit 1
fi

# §A1 transcript capture: the upload function + an EXIT trap are installed BEFORE the prep — so a
# failed clone/checkout (set -e) still uploads a manifest recording the attempt (the design's
# "trap, so failures upload too"). Single-quoted heredoc: pure pod-side — values arrive via pod env
# (PROJECT/PR_NUMBER/REVIEW_ROUND/MODEL/…), the S3 key via same-ns secretKeyRef
# (agents/coordinator/garage-workspace.yaml). Upload failures are loud but never fail the review.
UPLOADER=$(cat <<'SNIP'
# record_review_state — snapshot the PR's exact input state for Go-served reviews (homelab#424).
# Ruled 2026-08-13: a Go-served review's exact input state is re-reviewable later by sonnet
# (time-travel re-review); this snapshot is that contract. Uploaded to s3://<bucket>/<project>/<TASK_KEY>/review-state-<headsha8>-<ts>/.
# MUST be called BEFORE the claude invocation — the snapshot is the review's INPUT, not output.
# Upload failures are loud but never fail the review (same discipline as upload_transcripts).
record_review_state() {
  [ "${GO_SERVED:-0}" = "1" ] || { echo "review-state: GO_SERVED!=1 — snapshot skipped (only for Go-served reviews)"; return 0; }
  [ -n "${AGENT_TS_ACCESS_KEY_ID:-}" ] || { echo "review-state: no S3 key in pod — snapshot skipped"; return 0; }
  command -v s5cmd >/dev/null 2>&1 || { echo "review-state: s5cmd not in this image — snapshot skipped"; return 0; }
  command -v gh >/dev/null 2>&1 || { echo "review-state: gh not found — snapshot skipped"; return 0; }
  TS=$(date -u +%Y%m%dT%H%M%SZ)
  TASK_KEY="${TASK_KEY:-pr-${PR_NUMBER}}"
  HEADSHA="$(gh pr view "${PR_NUMBER}" --repo "${REPO_SLUG}" --json headRefOid -q '.headRefOid' 2>/dev/null | cut -c1-8)" || true
  [ -n "${HEADSHA}" ] || HEADSHA="unknown"
  P="s3://${AGENT_TS_BUCKET}/${PROJECT}/${TASK_KEY}/review-state-${HEADSHA}-${TS}"
  export AWS_ACCESS_KEY_ID="$AGENT_TS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AGENT_TS_SECRET_ACCESS_KEY" AWS_REGION=garage
  # pr.json — the PR state (no statusCheckRollup — 403s on App token, and CI is already green by dispatch predicate)
  gh pr view "${PR_NUMBER}" --json number,title,body,headRefOid,baseRefName,state,reviews,comments,files > /tmp/pr.json 2>/dev/null \
    || { echo "review-state: pr.json capture FAILED (non-fatal)"; : > /tmp/pr.json; }
  # diff.patch — the full PR diff
  gh pr diff "${PR_NUMBER}" > /tmp/diff.patch 2>/dev/null \
    || { echo "review-state: diff.patch capture FAILED (non-fatal)"; : > /tmp/diff.patch; }
  # head-sha.txt — the head sha
  printf '%s\n' "${HEADSHA}" > /tmp/head-sha.txt
  # rubric.sha.txt — hash of the rubric file as checked out in the pod
  if [ -f "${RUBRIC:-}" ]; then
    git hash-object "${RUBRIC}" > /tmp/rubric.sha.txt 2>/dev/null || printf 'hash-failed\n' > /tmp/rubric.sha.txt
  else
    printf 'no-rubric-file\n' > /tmp/rubric.sha.txt
  fi
  # snapshot-manifest.json — same style as upload_transcripts manifest
  jq -n --arg project "$PROJECT" --arg task "$TASK_KEY" --arg pr "${PR_NUMBER}" \
        --arg round "${REVIEW_ROUND}" --arg model "${MODEL}" --arg headsha "${HEADSHA}" --arg ts "$TS" \
        '{project:$project, task:$task, pr:$pr, round:($round|tonumber), model:$model, headsha8:$headsha, timestamp:$ts,
          files:["pr.json","diff.patch","head-sha.txt","rubric.sha.txt","snapshot-manifest.json"]}' > /tmp/snapshot-manifest.json
  # Upload all files
  for f in pr.json diff.patch head-sha.txt rubric.sha.txt snapshot-manifest.json; do
    [ -s "/tmp/$f" ] && { s5cmd --endpoint-url "$AGENT_TS_ENDPOINT" cp "/tmp/$f" "$P/$f" || echo "review-state: $f upload FAILED (non-fatal)"; }
  done
  echo "review-state: uploaded → $P"
}

upload_transcripts() {
  [ -n "${AGENT_TS_ACCESS_KEY_ID:-}" ] || { echo "transcripts: no S3 key in pod (agent-transcripts-s3 Secret absent?) — upload skipped"; return 0; }
  command -v s5cmd >/dev/null 2>&1 || { echo "transcripts: s5cmd not in this image — upload skipped (bump AGENT_COORDINATOR_IMAGE)"; return 0; }
  TS=$(date -u +%Y%m%dT%H%M%SZ)
  # FU-061: TASK_KEY = issue-<N> (PR→issue resolved in PREP), falling back to pr-<N> if the clone
  # failed before it was set. Bucket key is <project>/<TASK_KEY>/reviewer-r<round>-<ts>/.
  TASK_KEY="${TASK_KEY:-pr-${PR_NUMBER}}"
  P="s3://${AGENT_TS_BUCKET}/${PROJECT}/${TASK_KEY}/reviewer-r${REVIEW_ROUND}-${TS}"
  RC_VAL="$(cat /tmp/rc 2>/dev/null || true)"
  export AWS_ACCESS_KEY_ID="$AGENT_TS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AGENT_TS_SECRET_ACCESS_KEY" AWS_REGION=garage
  jq -n --arg role reviewer --arg project "$PROJECT" --arg task "$TASK_KEY" --arg issue "${ISSUE:-}" \
        --arg pr "$PR_NUMBER" --arg round "$REVIEW_ROUND" \
        --arg model "${MODEL:-}" --arg key coordinator-claude --arg pod "${HOSTNAME:-}" --arg rc "${RC_VAL}" \
        '{role:$role, project:$project, issue:$issue, pr:$pr, task:$task, round:($round|tonumber), model:$model,
          session_key:$key, pod:$pod, exit_status:($rc|tonumber? // $rc),
          files:["result.json"], grafana_query:("{pod=\""+$pod+"\"}")}' > /tmp/manifest.json
  [ -s /tmp/result.json ] && { s5cmd --endpoint-url "$AGENT_TS_ENDPOINT" cp /tmp/result.json "$P/result.json" || echo "transcripts: result.json upload FAILED (non-fatal)"; }
  find "$HOME/.claude/projects" -name '*.jsonl' 2>/dev/null | while read -r f; do
    s5cmd --endpoint-url "$AGENT_TS_ENDPOINT" cp "$f" "$P/$(basename "$f")" || echo "transcripts: upload FAILED for $f (non-fatal)"
  done
  s5cmd --endpoint-url "$AGENT_TS_ENDPOINT" cp /tmp/manifest.json "$P/manifest.json" || echo "transcripts: manifest upload FAILED (non-fatal)"
  echo "transcripts: uploaded → $P"
}
# homelab#560 (upload-always, exit-honest): preserve the ORIGINAL exit code across the trap. A
# plain `trap fn EXIT` hands the shell's final status to whatever fn's last command did, so a run
# that aborts before RUNPART (e.g. a PREP syntax error — the 2026-08-18 class) could surface a
# clean pod exit after a failed session. Capture $? FIRST, upload, then re-exit the captured code
# so the launcher's pod-exit read (the same contract, launcher leg) has a truthful number to
# propagate to the Argo workflow.
trap 'rc=$?; upload_transcripts; exit $rc' EXIT
SNIP
)
if ! printf '%s\n' "$UPLOADER" | bash -n /dev/stdin 2>/dev/null; then
  echo "FATAL: UPLOADER heredoc has a syntax error — review dispatch aborted before pod creation (homelab#1113)" >&2
  exit 1
fi

# The run tail: claude's result JSON goes to a file (not the live stream), the upload runs (its log
# lines join the "preamble" the launcher passes through), and the result is cat'ed LAST so the
# launcher's "JSON = from the first ^{ line" parse stays intact. Exit code stays claude's.
RUNPART=$(cat <<'SNIP'
set +e
# Go-served review: capture the input state snapshot BEFORE the review runs (homelab#424).
[ "${GO_SERVED:-0}" = "1" ] && record_review_state
claude -p "$PROMPT" --model "$MODEL" $RUBRIC_FLAG ${MCP_FLAG:-} --permission-mode "$PERM_MODE" --output-format json > /tmp/result.json
RC=$?
# >>>REPLAY:reviewer-exit-contract>>>
# EXIT CONTRACT (homelab#560): a session that ends with NO verdict, NO standing-aside comment, and
# NO agent/error label is a FAILURE — the 2026-08-18 outage class was a pod that died on a PREP
# syntax error (the #547 apostrophe), uploaded its transcript via the trap, and still reported
# Succeeded (the workflow container exits 0 because the launcher never propagated the pod's exit).
# After claude returns, re-read the PR's OWN review state and assert one of the three terminals
# exists with ${REVIEWER_LOGIN} at this head. Fail-CLOSED: an unreadable state is no-terminal (a
# GitHub blip reds one run; a silent green would mask the next outage). The three legitimate quiet
# exits — standing-aside posted / agent/error already present / opt-out skip before pod creation
# (which never reaches here) — stay exit 0: the assert is "one terminal exists", not "a verdict
# exists".
assert_review_terminal() {
  local state newest_commit newest_sha8 head_ts verdict aside error_label
  [ -n "${REVIEWER_LOGIN:-}" ] || { echo "exit-contract: REVIEWER_LOGIN unset — cannot verify a terminal; failing closed" >&2; return 1; }
  state="$(gh pr view "${PR_NUMBER}" --repo "${REPO_SLUG}" --json reviews,comments,labels,commits,headRefOid 2>/dev/null)" || {
    echo "exit-contract: review-state re-read FAILED — cannot prove a terminal exists; failing closed" >&2; return 1; }
  # The newest NON-MERGE commit — the content this review was about; matches the STEP-0 aside
  # marker's head= field and review-reflex.sh's at-head filter. A MERGE is skipped by its GitHub
  # default message shape (homelab#560 round 2): the update-branch "Merge branch 'x'", the
  # agent-authored conflict-resolution "Merge remote-tracking branch 'origin/x' into y" (this
  # PR's own newest commit was exactly that — the old startswith("Merge branch ") filter resolved
  # newest_sha8 to the MERGE sha and hid a legitimately-posted aside), and "Merge pull request #N".
  # gh pr view --json commits does not expose .parents[], so the message-shape match is the
  # structural test available on this call (coordinator probe, round-2 dispatch).
  newest_commit="$(printf '%s' "$state" | jq -r '[.commits[]? | select(((.messageHeadline // "") | (startswith("Merge branch ") or startswith("Merge remote-tracking branch ") or startswith("Merge pull request "))) | not) | .committedDate] | max // ""' 2>/dev/null)" || newest_commit=""
  newest_sha8="$(printf '%s' "$state" | jq -r '[.commits[]? | select(((.messageHeadline // "") | (startswith("Merge branch ") or startswith("Merge remote-tracking branch ") or startswith("Merge pull request "))) | not)] | sort_by(.committedDate) | last | .oid // ""' 2>/dev/null | cut -c1-8)" || newest_sha8=""
  head_ts="${newest_commit:-0000-00-00T00:00:00Z}"
  # TERMINAL 1 — a LIVE (non-DISMISSED, APPROVED/CHANGES_REQUESTED) verdict from our identity
  # submitted at or after the newest non-merge commit (the STEP-0 self-guard's own filter).
  verdict="$(printf '%s' "$state" | jq -r --arg bot "$REVIEWER_LOGIN" --arg h "$head_ts" '
    [ .reviews[]? | select(.author.login == $bot and (.state == "APPROVED" or .state == "CHANGES_REQUESTED")) | select(.submittedAt >= $h) ] | length' 2>/dev/null)" || verdict=""
  # TERMINAL 2 — a standing-aside comment from our identity carrying the machine marker at THIS
  # content head (head=<sha8>): `pre` may vary; the head field is what makes it this head's aside.
  aside="$(printf '%s' "$state" | jq -r --arg bot "$REVIEWER_LOGIN" --arg h "${newest_sha8:-}" '
    [ .comments[]? | select(.author.login == $bot and (.body | contains("<!-- standing-aside head="))) | select(.body | contains("head=" + $h)) ] | length' 2>/dev/null)" || aside=""
  # TERMINAL 3 — an agent/error label already present: someone tripped the breaker before us, and
  # the silent stop IS the terminal (the STEP-0 GENUINE-ANOMALY branch).
  error_label="$(printf '%s' "$state" | jq -r '[ .labels[]? | select(.name == "agent/error") ] | length' 2>/dev/null)" || error_label=""
  if [ "${verdict:-0}" -gt 0 ]; then
    echo "exit-contract: terminal OK — live ${REVIEWER_LOGIN} verdict at this head"
    return 0
  fi
  if [ "${aside:-0}" -gt 0 ]; then
    echo "exit-contract: terminal OK — ${REVIEWER_LOGIN} standing-aside at this head"
    return 0
  fi
  if [ "${error_label:-0}" -gt 0 ]; then
    echo "exit-contract: terminal OK — agent/error already present (breaker tripped; silent stop is the terminal)"
    return 0
  fi
  echo "exit-contract: NO TERMINAL — no ${REVIEWER_LOGIN} verdict, no standing-aside, no agent/error at head ${newest_sha8:-unknown} (verdict=$verdict aside=$aside error=$error_label); a green here would mask a dead review plane" >&2
  return 1
}
TERMINAL_OK=0
if assert_review_terminal; then TERMINAL_OK=1; fi
# Exit policy: a terminal exists → 0 (even if claude crashed right after posting it — the review
# landed and its record is on the PR); claude failed with no terminal → claude's own RC (honest);
# claude "succeeded" with no terminal → 10, the silent-green class this contract exists to kill.
if [ "${TERMINAL_OK:-0}" = "1" ]; then FINAL=0
elif [ "${RC:-0}" -ne 0 ]; then FINAL="${RC:-1}"
else FINAL=10; fi
# <<<REPLAY:reviewer-exit-contract<<<
echo "$FINAL" > /tmp/rc
trap - EXIT
upload_transcripts
cat /tmp/result.json
exit "$FINAL"
SNIP
)
if ! printf '%s\n' "$RUNPART" | bash -n /dev/stdin 2>/dev/null; then
  echo "FATAL: RUNPART heredoc has a syntax error — review dispatch aborted before pod creation (homelab#1113)" >&2
  exit 1
fi
# Combined syntax guard: verify the full assembled pod script parses before spawning a pod.
# This catches cross-part issues (e.g. a function defined in UPLOADER called in RUNPART that
# would be syntactically valid in isolation but malformed in combination).
_COMBINED="$(printf '%s\n%s\n%s\n%s' "$UPLOADER" "$PREP" "$TOUCHESPART" "$RUNPART")"
if ! printf '%s\n' "$_COMBINED" | bash -n /dev/stdin 2>/dev/null; then
  echo "FATAL: combined pod script has a syntax error — review dispatch aborted before pod creation (homelab#1113)" >&2
  exit 1
fi
ARGS="[\"bash\",\"-lc\",$(printf '%s\n%s\n%s\n%s' "$UPLOADER" "$PREP" "$TOUCHESPART" "$RUNPART" | jq -Rs .)]"

# >>>REPLAY:reviewer-go-failover-gate>>>
# FU-088(a): defer while the subscription is 429-latched (covers the Sensor path too, which
# dispatches this script directly without the reflex tick's guard). Level-triggered upstream —
# the backstop tick re-picks this PR once the latch clears, so a skip loses nothing.
# FAIL-OVER LADDER (homelab#424, ADR-096 shadow): when the subscription is latched, probe the Go rail
# (/opencode-limit). If Go is available (limited=false), serve the review from the Go rail
# instead of deferring. An explicit --model always wins — the failover only kicks in when
# the operator didn't pin a model.
# The /route consult above may have already resolved the model (authoritative mode). In that case
# only the deferral arm applies. In shadow/off/unreachable mode the routed verdict did NOT replace
# the model, so the legacy ladder remains the dispatch's only capacity gate — identical to the
# pattern agent-session.sh uses downstream of a shadow consult.
if [ -n "${_router_defer:-}" ]; then
  echo "→ review of ${PROJECT}#${PR} deferred — ${_rwhy:-router deferral}"
  exit 0
elif [ -z "${_router_adopted:-}" ]; then
  # shadow/off, or the router was unreachable/declined: the routed verdict did NOT replace the
  # model, so this dispatch's ONLY capacity gate is the legacy ladder — exactly as agent-session.sh
  # keeps its static chain + FU-088 gates intact downstream of the consult in shadow mode.
  if ! bash "$HERE/subscription-latch.sh"; then
    # Subscription is latched — probe the Go rail before deferring.
    # Reuse the same proxy base URL that subscription-latch.sh uses (AGENT_EGRESS_PROXY env).
    PROXY="${AGENT_EGRESS_PROXY:-http://openrouter-proxy.agent-egress.svc.cluster.local:8080}"
    go_reply="$(curl -fsS --max-time 5 "$PROXY/opencode-limit" 2>/dev/null)" || go_reply=""
    go_limited="true"
    if [ -n "$go_reply" ]; then
      go_limited="$(printf '%s' "$go_reply" | jq -r '.limited // false' 2>/dev/null)" || go_limited="true"
    fi
    if [ "$go_limited" = "false" ]; then
      # Go rail is available — use it for this review (only when no explicit --model was passed).
      if [ -z "${MODEL_SET_EXPLICIT:-}" ]; then
        MODEL="opencode-go/qwen3.5-plus"
        GO_SERVED=1
        echo "→ Anthropic latched — serving review of ${PROJECT}#${PR} from the Go rail (opencode-go/qwen3.5-plus)"
      else
        echo "→ review of ${PROJECT}#${PR} deferred — subscription rate-limited (explicit --model=${MODEL} pinned, cannot failover to Go)"
        exit 0
      fi
    else
      echo "→ review of ${PROJECT}#${PR} deferred — subscription rate-limited (FU-088 latch)"
      exit 0
    fi
  fi
fi
# <<<REPLAY:reviewer-go-failover-gate<<<

# FU-092 atomic gate (the worker pattern): a TERMINAL same-key holder is reaped — the dispatch
# predicate (reflex/Sensor: bot_review_at_head=none) already guarantees this head has no verdict,
# so the dead pod is a failed/refused attempt whose record lives in GitHub. A LIVE holder refuses
# — that IS the double-dispatch this key exists to kill. `create` (never `apply` — apply silently
# ADOPTS an existing pod and the idempotency story dies) is the test-and-set.
EXISTING_PHASE="$("$KUBECTL" $KUBE -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
case "$EXISTING_PHASE" in
  Succeeded|Failed)
    echo "→ reaping terminal same-key reviewer pod ${POD} (${EXISTING_PHASE}) before re-dispatch"
    "$KUBECTL" $KUBE -n "$NS" delete pod "$POD" --ignore-not-found >/dev/null 2>&1 || true;;
  "") :;;
  *)
    echo "REVIEW REFUSED: pod ${POD} already ${EXISTING_PHASE} — this (pr, head) is under review (FU-092 key)." >&2
    exit 3;;
esac
cat <<EOF | "$KUBECTL" $KUBE -n "$NS" create -f - \
  || { echo "REVIEW REFUSED (atomic): create of ${POD} failed — a racing dispatcher won the (pr, head) key, or the manifest is invalid (see kubectl error above)." >&2; exit 3; }
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  labels: { app: agent-reviewer, project: ${PROJECT}, pr: "${PR}", "homelab.teststuff.net/subscription-session": claude }
spec:
  serviceAccountName: ${POD_SA}
  restartPolicy: Never
  terminationGracePeriodSeconds: 5
  containers:
    - name: reviewer
      image: ${IMAGE}
      args: ${ARGS}
      env:
        - name: HOME
          value: "/home/node"
        # Run context consumed by the in-pod RUNPART (claude flags + the transcript manifest).
        - name: PROJECT
          value: "${PROJECT}"
        - name: PR_NUMBER
          value: "${PR}"
        - name: REPO_SLUG
          value: "${REPO_SLUG}"
        - name: REVIEW_ROUND
          value: "${ROUND}"
        - name: MODEL
          value: "${MODEL}"
        - name: RUBRIC
          value: "${RUBRIC}"
        - name: GO_SERVED
          value: "${GO_SERVED:-0}"
        - name: PERM_MODE
          value: "${PERM_MODE}"
        # homelab#560: the pod's exit contract asserts on its OWN review-bot identity — re-reading
        # the PR's reviews/comments/labels and matching reviews[].author.login / aside marker
        # against this literal (same value the prompt's STEP-0 is injected with; no [bot] suffix).
        - name: REVIEWER_LOGIN
          value: "${REVIEWER_LOGIN}"
        # A0 standard rail: OTLP metrics+logs → the in-cluster collector (Loki/Prometheus).
        - name: CLAUDE_CODE_ENABLE_TELEMETRY
          value: "1"
        - name: OTEL_METRICS_EXPORTER
          value: "otlp"
        - name: OTEL_LOGS_EXPORTER
          value: "otlp"
        - name: OTEL_EXPORTER_OTLP_PROTOCOL
          value: "http/protobuf"
        - name: OTEL_EXPORTER_OTLP_ENDPOINT
          value: "${OTLP_ENDPOINT:-http://otel-collector.monitoring.svc.cluster.local:4318}"
        - name: OTEL_RESOURCE_ATTRIBUTES
          # stack derived from the claims mirror (2026-08-08): the reviewer was the ONE role
          # without it — USD 103.74 of 7d subscription-equiv sat unattributable as stack="" on
          # the cost dashboard until the label audit caught it.
          # ⚠ NO DOLLAR-PREFIXED NUMBERS in this heredoc: it EXPANDS, so "\$103.74" parsed as
          # positional \${1}03.74 and, under set -u, killed EVERY reviewer dispatch at the pod
          # create from c377da9 (2026-08-08 ~19:00Z) until 2026-08-09 00:30Z — oracle PR#234/#235
          # sat unreviewed ~2h. The apostrophe-outage class: prose inside executing code.
          value: "service.name=claude-code,role=reviewer,stack=${STACK_LABEL:-none},project=${PROJECT},pr=${PR}"
        # §A1 transcript capture: write-only key for the agent-transcripts bucket (same-ns Secret,
        # written by the Crossplane Workspace). optional:true → reviews run before it exists.
        - name: AGENT_TS_ENDPOINT
          value: "http://garage.garage.svc.cluster.local:3900"
        - name: AGENT_TS_BUCKET
          value: "agent-transcripts"
        - name: AGENT_TS_ACCESS_KEY_ID
          valueFrom:
            secretKeyRef: { name: agent-transcripts-s3, key: writer_access_key_id, optional: true }
        - name: AGENT_TS_SECRET_ACCESS_KEY
          valueFrom:
            secretKeyRef: { name: agent-transcripts-s3, key: writer_secret_access_key, optional: true }
        # Subscription auth rides the ADR-087 ref rail (FU-066d) — the reviewer checks out
        # LLM-authored PR code, so it of all roles must not hold the raw ~1y token. The pod carries
        # only the opaque ref; the proxy resolves + injects (token + oauth beta). Do NOT also set
        # ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN — they take auth precedence over this path.
        - name: ANTHROPIC_BASE_URL
          value: "http://openrouter-proxy.agent-egress.svc.cluster.local:8080/anthropic"
        - name: ANTHROPIC_AUTH_TOKEN
          value: "ref:agent-coordinator/coordinator-claude"
        # gh clone / pr checkout / pr review: the REVIEW-BOT App token (distinct identity from the PR
        # author, or Approve self-rejects). Env is the frozen fallback; the image's gh-wrapper prefers
        # the LIVE token file (ESO re-mints it ~hourly).
        - name: GH_TOKEN
          valueFrom:
            secretKeyRef: { name: ${REVIEWER_GIT}, key: GH_TOKEN, optional: true }
        - name: GH_TOKEN_FILE
          value: "/var/run/reviewer-git/GH_TOKEN"
      volumeMounts:
        - { name: reviewer-git, mountPath: /var/run/reviewer-git, readOnly: true }
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        allowPrivilegeEscalation: false
        capabilities: { drop: ["ALL"] }
        seccompProfile: { type: RuntimeDefault }
      resources:
        requests: { cpu: "250m", memory: "512Mi" }
        limits:   { cpu: "2",    memory: "2Gi" }
  volumes:
    - name: reviewer-git
      secret: { secretName: ${REVIEWER_GIT}, optional: true }
EOF

echo "→ waiting for ${POD} (clone + checkout + review)…"
"$KUBECTL" $KUBE -n "$NS" wait --for=condition=Ready pod/"${POD}" --timeout=120s || true
# `claude -p --output-format json` is silent until it finishes, then prints ONE result object (not the
# turn-by-turn transcript — use --output-format json, NOT stream-json/--verbose, which would stream every
# tool call). `logs -f` blocks until the container exits, so we capture the whole run: pass the pre-claude
# preamble (clone/checkout/banner) through, then reduce claude's JSON to a single usage/cost line + the
# verdict text. A caller that ingests this (the coordinator) gets a couple of lines, not the full run, and
# we record exact tokens+cost — Claude Code computes total_cost_usd itself (subscription-equivalent).
raw=$("$KUBECTL" $KUBE -n "$NS" logs -f "${POD}" 2>/dev/null || true)
printf '%s\n' "$raw" | awk '/^\{/{exit} NF'                       # preamble before claude's JSON
json=$(printf '%s\n' "$raw" | awk '/^\{/{f=1} f')                 # claude's JSON result (from first {)
if [ -n "$json" ]; then
  printf '%s' "$json" | jq -r '"→ reviewer \(.subtype // "done"): in=\(.usage.input_tokens // 0) out=\(.usage.output_tokens // 0) cache_read=\(.usage.cache_read_input_tokens // 0) turns=\(.num_turns // 0) cost=$\(.total_cost_usd // 0)", (.result // "")' 2>/dev/null \
    || printf '%s\n' "$json"
else
  echo "  (no JSON result — reviewer likely errored; kubectl --kubeconfig tofu/kubeconfig -n ${NS} logs ${POD})"
fi
echo "→ review submitted on ${REPO_SLUG}#${PR}. verdict:"
_verdict="$(gh pr view "${PR}" --repo "${REPO_SLUG}" --json reviewDecision -q .reviewDecision 2>/dev/null || true)"
echo "    reviewDecision=${_verdict:-unknown}"
echo "  (APPROVED + CI green ⇒ auto-merge completes the PR; CHANGES_REQUESTED ⇒ back to the worker.)"
echo "  remove the pod:  kubectl --kubeconfig tofu/kubeconfig -n ${NS} delete pod ${POD}"
# ── EXIT CONTRACT (homelab#560), launcher leg ───────────────────────────────────────────────────
# `logs -f` above returned only after the reviewer container terminated, so the pod's terminated
# exitCode IS the honest verdict on the run — and the workflow container exits with THIS script's
# code, which is what Argo reads as Succeeded/Failed. Before this, every pod — including the
# 2026-08-18 apostrophe aborts, whose transcripts uploaded and whose exit was swallowed by the
# `logs -f ... || true` above — reported Succeeded. Propagate the pod's code: a session that died
# on prep, or produced no terminal (the pod-side exit-contract assert), must red the workflow so
# argo_workflows_* metrics and the UI carry it.
_pod_rc="$("$KUBECTL" $KUBE -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || true)"
_pod_phase="$("$KUBECTL" $KUBE -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
case "${_pod_phase:-}" in
  Succeeded) _pod_rc=0;;
  Failed)    [ -n "${_pod_rc:-}" ] || _pod_rc=1;;
  *)
    echo "WARN: cannot confirm ${POD} terminal state (phase=${_pod_phase:-unknown}) — failing closed" >&2
    [ -n "${_pod_rc:-}" ] || _pod_rc=1;;
esac
echo "→ pod exit code: ${_pod_rc}"
if [ "${_pod_rc}" = "0" ]; then
  # FU-085: a verdict is scan-actionable (CHANGES_REQUESTED → round N+1 is the coordinator's move) —
  # ring the doorbell instead of waiting out the */10 cron. Cheap over-approximation: ring on every
  # verdict, the scan re-applies the full predicate. Fail-open off-cluster.
  # homelab#560: gated on a successful run. A failed/terminal-less session rings NOTHING — the red
  # workflow IS the signal, and the level-triggered backstops re-pick at their natural cadence; a
  # ring→fail→ring loop on a persistent failure is its own anomaly signal, not an accelerator.
  # FU-080 doorbell routing: carry {stack,loop_ns} for a GRADUATED stack so the coordinator Sensor's
  # per-stack trigger inlines into <loop_ns>; else plain {repo}. Best-effort (miss → */10 cron covers).
  _grad="$(jq -r --arg r "$PROJECT" '.stacks[]|select((.graduated // false)==true)|select([.repos[]]|index($r))|.name' "${HERE}/stacks.json" 2>/dev/null | head -1)"
  # FU-085 compound: a CHANGES_REQUESTED verdict IS item-shaped — carry the unit so the Sensor's
  # workflow runs the scan's fast-path (scoped re-validation + dispatch) instead of a full sweep.
  # Computed HERE in script code (never the LLM); any other verdict rings the plain doorbell and
  # the full scan/cron decide. The fast-path re-validates, so a stale unit costs a few gh calls.
  _unit=""
  [ "${_verdict:-}" = "CHANGES_REQUESTED" ] && _unit=",\"unit\":\"changes-requested|${PROJECT}|pr-${PR}\""
  if [ -n "$_grad" ] && [ "$_grad" != "null" ]; then
    _door="{\"repo\":\"${PROJECT}\",\"stack\":\"${_grad}\",\"loop_ns\":\"${_grad}-agents\"${_unit}}"
  else
    _door="{\"repo\":\"${PROJECT}\"${_unit}}"
  fi
  curl -m 5 -s -X POST -H "Content-Type: application/json" -d "$_door" \
    "${AGENT_LOOP_WEBHOOK:-http://agent-loop-eventsource-svc.agent-coordinator.svc.cluster.local:12000}/coordinate" \
    >/dev/null 2>&1 && echo "→ coordinator doorbell rung (/coordinate ${_door})" || true
fi
exit "${_pod_rc}"
