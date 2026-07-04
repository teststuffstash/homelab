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
#   • LLM auth = the operator SUBSCRIPTION (coordinator-claude → CLAUDE_CODE_OAUTH_TOKEN): free at
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
# coordinator uses for its own brief. The GENERIC "how to review" behavior is /code-review itself
# (built into the image's Claude Code). Absent .agents/review.md, we just run the generic reviewer.
#
# Operator-side, ONCE (see docs/github-setup.md §2/§5):
#   • homelab-reviewer App + reviewer-git Secret:  scripts/github-reviewer-app-bootstrap.sh
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

# Pro/Max subscription ⇒ sonnet (a strong reviewer, free at margin). Override for a high-stakes PR
# (e.g. --model opus) or a metered run. Rubric path is relative to the project repo root.
REPO_SLUG=""; MODEL="sonnet"; RUBRIC=".agents/review.md"; PERM_MODE="bypassPermissions"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)            REPO_SLUG="$2"; shift 2;;   # owner/name or full URL; default teststuffstash/<project>
    --model)           MODEL="$2"; shift 2;;
    --rubric)          RUBRIC="$2"; shift 2;;      # project-relative path to the review system prompt
    --permission-mode) PERM_MODE="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

NS="agent-coordinator"
IMAGE="${COORDINATOR_IMAGE:-ghcr.io/teststuffstash/agent-coordinator:latest}"   # ships Claude Code + gh wrapper
REPO_SLUG="${REPO_SLUG:-teststuffstash/${PROJECT}}"
REVIEWER_GIT="${REVIEWER_GIT:-reviewer-git}"   # Secret w/ the review-bot App token — MUST differ from the PR author's App
POD="reviewer-${PROJECT}-${PR}-$(date -u +%H%M%S)"

# In-pod prep, run under `bash -lc` so the image's gh-wrapper (reads the LIVE ~1h token from
# GH_TOKEN_FILE) is on PATH. gh repo clone → a full clone (master present) so /code-review can diff
# the PR branch against the base; gh pr checkout fetches the PR head + sets the branch /code-review
# and `--comment` resolve the PR from. Append the rubric only if the project ships one (an absent
# --append-system-prompt-file path is a hard error — the coordinator hit exactly that).
PREP=$(cat <<PREP
set -e
gh repo clone ${REPO_SLUG} /work/repo -- --quiet
cd /work/repo
gh pr checkout ${PR}
RUBRIC_FLAG=""
[ -f "${RUBRIC}" ] && RUBRIC_FLAG="--append-system-prompt-file ${RUBRIC}"
echo "→ reviewing ${REPO_SLUG}#${PR} on \$(git rev-parse --abbrev-ref HEAD) (model: ${MODEL}); rubric: \${RUBRIC_FLAG:-<none>}"
PROMPT='Review pull request #${PR} on the checked-out branch. Run /code-review to find correctness bugs and post them as inline PR comments. Then submit exactly ONE native GitHub review as your verdict: run gh pr review ${PR} --approve if you found no blocking correctness bugs, otherwise gh pr review ${PR} --request-changes --body with a one-paragraph summary of the blockers. Do NOT merge and do NOT push — auto-merge completes the PR once your review and CI pass.'
exec claude -p "\$PROMPT" --model ${MODEL} \$RUBRIC_FLAG --permission-mode ${PERM_MODE} --output-format json
PREP
)
ARGS="[\"bash\",\"-lc\",$(printf '%s' "$PREP" | jq -Rs .)]"

cat <<EOF | "$KUBECTL" $KUBE -n "$NS" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  labels: { app: agent-reviewer, project: ${PROJECT}, pr: "${PR}" }
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 5
  containers:
    - name: reviewer
      image: ${IMAGE}
      args: ${ARGS}
      env:
        - name: HOME
          value: "/home/node"
        # Operator subscription (Pro/Max): the ~1y token from \`claude setup-token\`. Do NOT also set
        # ANTHROPIC_API_KEY — it would take auth precedence over the subscription.
        - name: CLAUDE_CODE_OAUTH_TOKEN
          valueFrom:
            secretKeyRef: { name: coordinator-claude, key: CLAUDE_CODE_OAUTH_TOKEN }
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
gh pr view "${PR}" --repo "${REPO_SLUG}" --json reviewDecision -q .reviewDecision 2>/dev/null | sed 's/^/    reviewDecision=/' || true
echo "  (APPROVED + CI green ⇒ auto-merge completes the PR; CHANGES_REQUESTED ⇒ back to the worker.)"
echo "  remove the pod:  kubectl --kubeconfig tofu/kubeconfig -n ${NS} delete pod ${POD}"
