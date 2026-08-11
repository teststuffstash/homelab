#!/usr/bin/env bash
# research-fanout.sh — the FU-126 multi-model spec-writer fan-out: dispatch the SAME goal issue
# to N models, each as its own un-armed research ride, so the operator can compare and
# cherry-pick the resulting research/* branches (the nemotron /workspace/idp jail run is the
# reference output shape; oracle-fleet#166 / sleep PR port the grow-mode research recipes).
#
#   bash agents/research-fanout.sh <project> <goal-issue> --arms N [--class regular] [--dry-run]
#   bash agents/research-fanout.sh oracle-fleet 210 --arms 7
#
# THE CALLER NAMES ZERO MODELS (ADR-104 / model-routing.md §M13, built FU-162). The roster is
# DRAWN: one `POST /route` per arm carrying `class` + `slot` + `jitter:false`, answered from the
# scout-curated pool, so the same (class, slot, pool-version) always yields the same model — a
# relaunched arm is identical and the mission is reproducible from its calls. Hand-picked model
# ids are refused: run 1's arm #2 rode deepseek-v4-**flash** where the intent was **pro**, a
# one-token slip nothing displayed, and that slip is why the draw exists.
#
# Over-provision instead of retrying (ADR-104 (3)): ask for 7 arms when 5 are needed. Slots that
# come back a TYPED defer (cooldown, capacity, a denied model) are printed in the arm table and
# left empty — never substituted, because a silently swapped arm corrupts the experiment. The
# operator re-runs with a wider `--arms` or waits out the retry, in the open.
#
# `claude/<alias>` draws ride the SUBSCRIPTION claude harness (no OpenRouter key/mint —
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

USAGE="usage: research-fanout.sh <project> <goal-issue> --arms N [--class regular] [--start-slot 1] [--dry-run]"
PROJECT="${1:?$USAGE}"
ISSUE="${2:?goal issue number}"
shift 2

ARMS=""; CLASS="regular"; START_SLOT=1; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --arms)       ARMS="${2:?--arms needs a count}"; shift 2;;
    --class)      CLASS="${2:?--class needs a band}"; shift 2;;
    --start-slot) START_SLOT="${2:?--start-slot needs a slot}"; shift 2;;
    --dry-run)    DRY=1; shift;;
    # The old interface took model ids here. Refuse them by name rather than mis-parsing: a
    # fan-out that quietly ignored a hand-picked roster would be the same class of invisible
    # slip ADR-104 was written for.
    */*|claude/*) echo "research-fanout no longer takes model ids — the roster is DRAWN (ADR-104). Use --arms N [--class regular]." >&2; exit 2;;
    *)            echo "$USAGE" >&2; exit 2;;
  esac
done
case "$ARMS" in ''|*[!0-9]*) echo "$USAGE" >&2; exit 2;; esac
[ "$ARMS" -ge 1 ] || { echo "--arms must be ≥ 1" >&2; exit 2; }
case "$START_SLOT" in ''|*[!0-9]*) echo "--start-slot must be a positive integer" >&2; exit 2;; esac
[ "$START_SLOT" -ge 1 ] || { echo "--start-slot must be a positive integer (got 0)" >&2; exit 2; } # PR#320 review finding: the pattern alone admitted 0

RECIPE="${RESEARCH_RECIPE:-/workspace/${PROJECT}/.agents/research.yaml}"
if [ "$DRY" = 0 ] && [ ! -f "$RECIPE" ]; then
  echo "recipe not found: ${RECIPE} (set RESEARCH_RECIPE)" >&2; exit 2
fi

ORG="${ORG:-teststuffstash}"
ROUTER_URL="${AGENT_EGRESS_PROXY:-${AGENT_OPENROUTER_PROXY:-http://openrouter-proxy.agent-egress.svc.cluster.local:8080}}"
STACK="$(jq -r --arg p "$PROJECT" '[.stacks[] | select(.repos[]? == $p)][0].name // ""' "$HERE/stacks.json" 2>/dev/null)" || STACK=""

# ── SEAM (agents/replay/) ── the draw's ONE piece of I/O. A replay bridge redefines exactly this
# function to serve recorded decisions; the slot walk, the arm table and the dispatch split above
# it stay real, which is the rule the harness README states for sourced helpers.
rf_route() {   # rf_route <class> <slot> <session> → the /route decision JSON on stdout
  jq -nc --arg cls "$1" --argjson slot "$2" --arg session "$3" \
         --arg stack "$STACK" --arg task "research-${ISSUE}" \
     '{stack: $stack, task: $task, role: "researcher", session: $session,
       class: $cls, slot: $slot, jitter: false}' \
  | curl -fsS --max-time 10 -H "Content-Type: application/json" -d @- "${ROUTER_URL}/route"
}

echo "→ FU-126 fan-out: ${PROJECT}#${ISSUE} → drawing ${ARMS} arm(s) from the ${CLASS} pool"

# >>>REPLAY:draw-roster>>>
# The DRAW (ADR-104 §M13). One /route per slot, jitter off, no substitution: a slot that defers
# stays empty and is reported, because the arm table is the artifact — "slot 4 deferred, cooldown"
# is evidence, a silently shifted roster is not.
ROSTER_SLOTS=(); ROSTER_MODELS=(); POOL_VERSION=""; DRAWN=0
_slot="$START_SLOT"; _last=$(( START_SLOT + ARMS - 1 ))
while [ "$_slot" -le "$_last" ]; do
  _dec="$(rf_route "$CLASS" "$_slot" "research-${ISSUE}-slot-${_slot}")" || _dec=""
  if [ -z "$_dec" ]; then
    echo "  slot ${_slot}: router unreachable (${ROUTER_URL}) — no arm drawn"
    _slot=$(( _slot + 1 )); continue
  fi
  _verdict="$(printf '%s' "$_dec" | jq -r '.decision // "?"')"
  _model="$(printf '%s' "$_dec" | jq -r '.model // ""')"
  _pv="$(printf '%s' "$_dec" | jq -r '.pool_version // ""')"
  if [ -n "$_pv" ]; then POOL_VERSION="$_pv"; fi   # `[ … ] && x=y` would exit under set -e
  if [ "$_verdict" = "dispatch" ] && [ -n "$_model" ]; then
    ROSTER_SLOTS+=("$_slot"); ROSTER_MODELS+=("$_model")
    DRAWN=$(( DRAWN + 1 ))
    echo "  slot ${_slot}: ${_model}"
  else
    _why="$(printf '%s' "$_dec" | jq -r '[.reason, (.retry_after_s | if . == null then empty else "retry " + (.|tostring) + "s" end)] | map(select(. != null and . != "")) | join(", ")')"
    echo "  slot ${_slot}: — (${_verdict}: ${_why:-no reason given}) — NOT substituted (ADR-104)"
  fi
  _slot=$(( _slot + 1 ))
done
echo "→ arm table: ${DRAWN}/${ARMS} arm(s) drawn, class=${CLASS} pool-version=${POOL_VERSION:-unknown}"
# <<<REPLAY:draw-roster<<<

[ "$DRAWN" -ge 1 ] || { echo "no arms drawn — nothing to dispatch" >&2; exit 3; }
if [ "$DRY" = 1 ]; then
  echo "→ --dry-run: roster drawn, nothing dispatched (re-run without --dry-run to ride it)"
  exit 0
fi

N="$DRAWN"
echo "→ dispatching ${N} ride(s) (WIP limit ${N})"
for _i in "${!ROSTER_MODELS[@]}"; do
  SLOT="${ROSTER_SLOTS[$_i]}"; MODEL="${ROSTER_MODELS[$_i]}"
  # slug: last path segment, :free/:suffix stripped, lowercased, non-alnum → '-'
  SLUG="$(printf '%s' "${MODEL##*/}" | cut -d: -f1 | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//')"
  TASK="research-${ISSUE}-${SLUG}"
  SESSION="${TASK}-round-1"
  echo "── slot ${SLOT}: ${MODEL} (task ${TASK}) ──"

  # SUBSCRIPTION rail (operator 2026-08-03): a `claude/<alias>` entry rides the claude harness —
  # no OpenRouter key, no estimate/mint (the subscription is the budget; FU-088 latch gates load).
  # The launcher derives --harness claude from the prefix; the pod's only cred is the
  # claude-session ref (needs fixer.claudeTier: true on the claim). NB the branch model-slug rule
  # keys on GOOSE_MODEL, which a claude pod lacks — its branch carries the topic slug instead
  # (collision-free vs the goose arms; one claude arm per fan-out).
  # FU-127: the rail comes from the ONE parser (agents/model_id.py), not a prefix match here.
  if [ "$(python3 "${HERE}/model_id.py" "$MODEL" | jq -r .rail)" = "anthropic-subscription" ]; then
    AGENT_WIP_LIMIT="$N" bash "${HERE}/agent-session.sh" "$PROJECT" \
      --model "$MODEL" \
      --task "$TASK" --round 1 --recipe "$RECIPE" &
    sleep 5
    continue
  fi

  # Estimate + mint the per-ride ephemeral key (the coordinator's steps 3-4, deterministic).
  # ESCALATE for one model skips THAT model only — the others still ride. The estimator prints
  # the verdict to stderr and still emits a top-cap CR, so the gate is HERE: buffer the CR,
  # read the verdict, apply only if clean or the operator pre-approved the draw
  # (FANOUT_APPROVE_ESCALATE=1 — the ride then runs under the top-tier hard cap and may 403
  # unfinished; incremental pushes bank the WIP).
  EST_ERR="$(mktemp)"
  CR="$(gh issue view "$ISSUE" --repo "${ORG}/${PROJECT}" --json title,body -q '.title+"\n"+.body' \
      | python3 "${HERE}/estimate_budget.py" --model "$MODEL" \
          --project "$PROJECT" --session "$SESSION" --emit-cr 2>"$EST_ERR")" || CR=""
  cat "$EST_ERR" >&2
  if [ -z "$CR" ]; then
    echo "  ⚠ estimate/mint FAILED for ${MODEL} — skipping this model (others continue)" >&2
    rm -f "$EST_ERR"; continue
  fi
  if grep -q "ESCALATE" "$EST_ERR" && [ "${FANOUT_APPROVE_ESCALATE:-0}" != "1" ]; then
    echo "  ⚠ ESCALATE for ${MODEL} — skipping (human gate, FU-126). Re-run with FANOUT_APPROVE_ESCALATE=1 to ride it under the top-tier cap." >&2
    rm -f "$EST_ERR"; continue
  fi
  rm -f "$EST_ERR"
  if ! printf '%s\n' "$CR" | "${KUBECTL:-kubectl}" --kubeconfig "${HERE}/../tofu/kubeconfig" apply -f -; then
    echo "  ⚠ key CR apply FAILED for ${MODEL} — skipping this model (others continue)" >&2
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
