# ── bridge ── the per-repo loop state the review-pick block reads (see two-lanes-two-picks/bridge.sh):
# `prs`, `REVIEWER_LOGIN`, `DEFAULT_BRANCH` — plus `required_json`, the base branch's required
# status contexts the reflex reads via the rules API just before the block (a recorded VALUE here,
# not a stubbed call: the block under test is the predicate).
prs="$(cat "$REPLAY_WORLD/gh/pr-list.json")"
REVIEWER_LOGIN="homelab-reviewer"
DEFAULT_BRANCH="master"
required_json='["ci", "iac-sentinel", "management-sentinel"]'
