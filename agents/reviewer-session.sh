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
REPO_SLUG=""; MODEL="sonnet"; RUBRIC=".agents/review.md"; PERM_MODE="bypassPermissions"; ROUND="1"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)            REPO_SLUG="$2"; shift 2;;   # owner/name or full URL; default teststuffstash/<project>
    --model)           MODEL="$2"; shift 2;;
    --rubric)          RUBRIC="$2"; shift 2;;      # project-relative path to the review system prompt
    --permission-mode) PERM_MODE="$2"; shift 2;;
    --round)           ROUND="$2"; shift 2;;       # review iteration on this PR (transcript prefix reviewer-r<N>)
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

NS="agent-coordinator"
[ -f "$HERE/images.env" ] && . "$HERE/images.env" # pinned agent image versions (no :latest)
IMAGE="${COORDINATOR_IMAGE:-${AGENT_COORDINATOR_IMAGE:-ghcr.io/teststuffstash/agent-coordinator:latest}}"   # ships Claude Code + gh wrapper
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
# FU-061: key the transcript by the ISSUE the PR fixes (not the PR), so a PR's reviews land beside
# the worker rounds + coordinator ticks for the same issue. Resolve via GitHub's closing-issue
# reference ("Fixes #N"); fall back to pr-<N> when the PR closes no issue.
ISSUE=\$(gh pr view ${PR} --json closingIssuesReferences -q '.closingIssuesReferences[0].number' 2>/dev/null || true)
if [ -n "\$ISSUE" ] && [ "\$ISSUE" != "null" ]; then TASK_KEY="issue-\$ISSUE"; else TASK_KEY="pr-${PR}"; ISSUE=""; fi
export TASK_KEY ISSUE
echo "→ transcript task key: \$TASK_KEY (fixes issue \${ISSUE:-none})"
RUBRIC_FLAG=""
[ -f "${RUBRIC}" ] && RUBRIC_FLAG="--append-system-prompt-file ${RUBRIC}"
echo "→ reviewing ${REPO_SLUG}#${PR} on \$(git rev-parse --abbrev-ref HEAD) (model: ${MODEL}); rubric: \${RUBRIC_FLAG:-<none>}"
PROMPT='Review pull request #${PR} on the checked-out branch.

STEP 0 — SELF-GUARD (anomaly breaker; you are the LAST line of defense against automation loops): run  gh pr view ${PR} --json reviews,commits,labels  and check your OWN bot identity (gh api user --jq .login) against the review history. If you have ALREADY submitted an APPROVED or CHANGES_REQUESTED verdict NEWER than the newest commit, the machinery that dispatched you is looping — do NOT submit another review and do NOT re-litigate the diff. Trip the breaker: run  gh pr edit ${PR} --add-label agent/error  (your token has issues:write since 2026-07-16 — homelab FU-069 b) and post exactly one comment starting with AGENT_ERROR: stating the verdict you already gave, its timestamp, and the newest commit timestamp, then stop. Do the same — label + one AGENT_ERROR: comment, no review, stop — whenever anything else smells like automation gone wrong: a pile of near-identical bot reviews or comments, contradictory labels, a PR that plainly should not have reached you (an agent/error label ALREADY present means someone tripped it before you: add nothing, touch nothing, stop silently). A burned session that produces a single anomaly report is a GOOD outcome; a duplicate verdict is not.

STEP 1 — classify the PR: run  gh pr view ${PR} --json labels,title,files  and decide which kind it is.

If it is a DEPENDENCY / TOOLCHAIN bump — it carries a label of major or deps-review, or it changes only devbox.lock / devbox.json / a lockfile AND crosses a MAJOR version — then a diff skim is NOT enough. Do a MIGRATION INVESTIGATION:
  1. List each tool whose MAJOR version changed, old -> new (read it from the lockfile diff).
  2. Fetch that tool major-version upstream release / migration notes with WebFetch and read the breaking-changes section. If egress blocks the fetch, reason from your own knowledge of that major and say so explicitly.
  3. Map every breaking change onto THIS repo actual usage: grep how the tool is invoked under scripts/, .github/, chart/, Makefile, and the devbox scripts in devbox.json. For each spot that must change, post an INLINE PR comment naming the exact change and citing the migration note.
  4. Note genuinely useful NEW capabilities of the major as ONE short, non-blocking follow-up comment.
  Verdict: --request-changes if ANY adaptation is required (a worker will fix it on this branch and you re-review); --approve only once every breaking change is either N/A or already handled in the diff. A major bump is HUMAN-GATED (not auto-merged): your review DOCUMENTS the migration so a human can merge with confidence — do not expect auto-merge.

Otherwise (a normal code PR): run /code-review to find correctness bugs and post them as inline PR comments — then apply the MERGE-FORWARD VERDICT DOCTRINE:
  The verdict question is NOT "is this perfect?" — it is "is master better off WITH this PR than without it?" Classify every finding you made:
    BLOCKING (--request-changes): the diff makes master WORSE or lands something unrecoverable — leaked secrets/credentials, committed binary blobs, CI red, breaking/deleting behavior that already worked on master, or (only in a repo whose rubric declares it PROD-SERVING) violating a pinned invariant in a way real consumers would ingest. The project rubric (.agents/review.md) may tighten or relax this set — the rubric wins.
    FOLLOW-UP (approve anyway): everything else — correctness edges in NEW code, unhandled input shapes you constructed, spec ambiguities you uncovered, dead code, style, missing tests. List each under a "Follow-ups:" heading in the review body, one concrete bullet each, written so it can become a backlog issue verbatim. A spec ambiguity is a proposed AMBIGUITY row for specs/, never a blocker.
  A greenfield / pre-prod repo (the rubric says which) biases HARD toward approve-with-follow-ups: with no consumers there is no "good enough" judgment to fail — forward progress merges NOW, and each residual finding becomes its own issue with its own round budget (which is cheaper and converges faster than piling rounds onto one PR). This is what a human author would negotiate: "better than master, merge it, backlog the nits." Do NOT re-litigate follow-ups already filed from earlier reviews of this same PR.

STEP FINAL — submit exactly ONE native GitHub review as your verdict: run gh pr review ${PR} --approve --body with the Follow-ups: section (when non-empty) if the diff moves master forward, otherwise gh pr review ${PR} --request-changes --body with a one-paragraph summary of the BLOCKING findings only (for a dependency bump, summarise the required adaptations). Do NOT merge and do NOT push.'
PREP
)

# §A1 transcript capture: the upload function + an EXIT trap are installed BEFORE the prep — so a
# failed clone/checkout (set -e) still uploads a manifest recording the attempt (the design's
# "trap, so failures upload too"). Single-quoted heredoc: pure pod-side — values arrive via pod env
# (PROJECT/PR_NUMBER/REVIEW_ROUND/MODEL/…), the S3 key via same-ns secretKeyRef
# (agents/coordinator/garage-workspace.yaml). Upload failures are loud but never fail the review.
UPLOADER=$(cat <<'SNIP'
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
trap upload_transcripts EXIT
SNIP
)
# The run tail: claude's result JSON goes to a file (not the live stream), the upload runs (its log
# lines join the "preamble" the launcher passes through), and the result is cat'ed LAST so the
# launcher's "JSON = from the first ^{ line" parse stays intact. Exit code stays claude's.
RUNPART=$(cat <<'SNIP'
set +e
claude -p "$PROMPT" --model "$MODEL" $RUBRIC_FLAG --permission-mode "$PERM_MODE" --output-format json > /tmp/result.json
RC=$?
echo "$RC" > /tmp/rc
trap - EXIT
upload_transcripts
cat /tmp/result.json
exit $RC
SNIP
)
ARGS="[\"bash\",\"-lc\",$(printf '%s\n%s\n%s' "$UPLOADER" "$PREP" "$RUNPART" | jq -Rs .)]"

# FU-088(a): defer while the subscription is 429-latched (covers the Sensor path too, which
# dispatches this script directly without the reflex tick's guard). Level-triggered upstream —
# the backstop tick re-picks this PR once the latch clears, so a skip loses nothing.
if ! bash "$HERE/subscription-latch.sh"; then
  echo "→ review of ${PROJECT}#${PR} deferred — subscription rate-limited (FU-088 latch)"
  exit 0
fi

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
        # Run context consumed by the in-pod RUNPART (claude flags + the transcript manifest).
        - name: PROJECT
          value: "${PROJECT}"
        - name: PR_NUMBER
          value: "${PR}"
        - name: REVIEW_ROUND
          value: "${ROUND}"
        - name: MODEL
          value: "${MODEL}"
        - name: PERM_MODE
          value: "${PERM_MODE}"
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
          value: "service.name=claude-code,role=reviewer,project=${PROJECT},pr=${PR}"
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
gh pr view "${PR}" --repo "${REPO_SLUG}" --json reviewDecision -q .reviewDecision 2>/dev/null | sed 's/^/    reviewDecision=/' || true
echo "  (APPROVED + CI green ⇒ auto-merge completes the PR; CHANGES_REQUESTED ⇒ back to the worker.)"
echo "  remove the pod:  kubectl --kubeconfig tofu/kubeconfig -n ${NS} delete pod ${POD}"
