#!/usr/bin/env bash
# research-fanout.sh — the FU-126 multi-model spec-writer fan-out: dispatch the SAME goal issue
# to N models, each as its own un-armed research ride, so the operator can compare and
# cherry-pick the resulting research/* branches (the nemotron /workspace/idp jail run is the
# reference output shape; oracle-fleet#166 / sleep PR port the grow-mode research recipes).
#
#   bash agents/research-fanout.sh <project> <goal-issue> <model> [model ...]
#   bash agents/research-fanout.sh oracle-fleet 210 nvidia/nemotron-3-ultra-550b-a55b \
#        qwen/qwen3-max moonshotai/kimi-k2.5 claude/opus
#
# `claude/<alias>` entries ride the SUBSCRIPTION claude harness (no OpenRouter key/mint —
# the FU-066 rail; the claim needs fixer.claudeTier: true).
#
# Per model: a short slug (vendor stripped, :free stripped, non-alnum → '-') keys EVERYTHING —
# the task (`research-<issue>-<slug>`), the ephemeral budget key session, the pod name — so N
# parallel rides never collide on the (task, round) idempotency key. research-* tasks are ADHOC
# to the launcher (no strike bookkeeping, no issue-* atomic gate) and a research* recipe
# auto-derives --no-arm (the FU-105 human gate; C9 skips research/* branches). The recipes tell
# each worker to suffix its branch with the model slug so branches don't collide either.
#
# WIP: parallel rides need AGENT_WIP_LIMIT ≥ N — set here per dispatch, scoped to this script.
# Budget: one EPHEMERAL key per ride (estimate_budget --emit-cr) — per-model cost isolation
# under the project's standing ceiling; the estimator's ESCALATE verdict stops that model's
# dispatch (not the whole fan-out).
#
# Jail-run (operator-invoked; FU-090(c) remains the future auto-dispatch path).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

PROJECT="${1:?usage: research-fanout.sh <project> <goal-issue> <model> [model ...]}"
ISSUE="${2:?goal issue number}"
shift 2
[ $# -ge 1 ] || { echo "at least one model required" >&2; exit 2; }

RECIPE="${RESEARCH_RECIPE:-/workspace/${PROJECT}/.agents/research.yaml}"
[ -f "$RECIPE" ] || { echo "recipe not found: ${RECIPE} (set RESEARCH_RECIPE)" >&2; exit 2; }

ORG="${ORG:-teststuffstash}"
N=$#
echo "→ FU-126 fan-out: ${PROJECT}#${ISSUE} → ${N} models (WIP limit ${N})"

for MODEL in "$@"; do
  # slug: last path segment, :free/:suffix stripped, lowercased, non-alnum → '-'
  SLUG="$(printf '%s' "${MODEL##*/}" | cut -d: -f1 | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//')"
  TASK="research-${ISSUE}-${SLUG}"
  SESSION="${TASK}-round-1"
  echo "── ${MODEL} (task ${TASK}) ──"

  # SUBSCRIPTION rail (operator 2026-08-03): a `claude/<alias>` entry rides the claude harness —
  # no OpenRouter key, no estimate/mint (the subscription is the budget; FU-088 latch gates load).
  # The launcher derives --harness claude from the prefix; the pod's only cred is the
  # claude-session ref (needs fixer.claudeTier: true on the claim). NB the branch model-slug rule
  # keys on GOOSE_MODEL, which a claude pod lacks — its branch carries the topic slug instead
  # (collision-free vs the goose arms; one claude arm per fan-out).
  case "$MODEL" in claude/*)
    AGENT_WIP_LIMIT="$N" bash "${HERE}/agent-session.sh" "$PROJECT" \
      --model "$MODEL" \
      --task "$TASK" --round 1 --recipe "$RECIPE" &
    sleep 5
    continue;;
  esac

  # Estimate + mint the per-ride ephemeral key (the coordinator's steps 3-4, deterministic).
  # ESCALATE for one model skips THAT model only — the others still ride.
  if ! gh issue view "$ISSUE" --repo "${ORG}/${PROJECT}" --json title,body -q '.title+"\n"+.body' \
      | python3 "${HERE}/estimate_budget.py" --model "$MODEL" \
          --project "$PROJECT" --session "$SESSION" --emit-cr \
      | "${KUBECTL:-kubectl}" --kubeconfig "${HERE}/../tofu/kubeconfig" apply -f -; then
    echo "  ⚠ estimate/mint FAILED for ${MODEL} — skipping this model (others continue)" >&2
    continue
  fi

  AGENT_WIP_LIMIT="$N" bash "${HERE}/agent-session.sh" "$PROJECT" \
    --harness goose --model "$MODEL" \
    --openrouter-secret "$(python3 -c "import sys; sys.path.insert(0,'${HERE}'); from estimate_budget import session_secret_name; print(session_secret_name('${PROJECT}','${SESSION}'))")" \
    --task "$TASK" --round 1 --recipe "$RECIPE" &
  sleep 5  # stagger pod creates (image-pull thundering herd on one node)
done

echo "→ all dispatches launched (backgrounded) — rides run in ns ${PROJECT}; branches arrive as"
echo "  research/issue-${ISSUE}-<model-slug>. Compare with:"
echo "    gh pr list --repo ${ORG}/${PROJECT} --state open --search 'head:research/issue-${ISSUE}'"
wait
echo "→ fan-out dispatch complete (rides continue in-cluster)"
