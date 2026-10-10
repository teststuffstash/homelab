# ── bridge ── the per-pick variables the two breaker blocks read, every one a REVIEW-REFLEX name.
# gh_label_add + mc_event come from the SHIPPED machine-comment.sh (sourced, never stubbed); the
# clock is pinned so the mc_event line is deterministic. `log` drops the wall-clock prefix only.
. "$REPLAY_ROOT/agents/machine-comment.sh"
mc_now() { printf '%s\n' "${MC_NOW:?fixture must pin MC_NOW}"; }
log() { printf '%s\n' "$*"; }
repo=oracle-fleet
slug=teststuffstash/oracle-fleet
ROUNDS_MAX=12
v_total="${IN_V_TOTAL:-1}"; v_head="${IN_V_HEAD:-0}"; v_head_approved="${IN_V_HEAD_APPROVED:-0}"
rounds_total="${IN_ROUNDS_TOTAL:-$v_total}"; rounds_key="issue #77 (2 PRs)"
for pick in 500; do
