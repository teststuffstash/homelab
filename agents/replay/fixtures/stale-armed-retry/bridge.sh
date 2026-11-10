# ── bridge ── the per-repo scan variables the CI infra-death retry reads (shared by the family rows)
. "$REPLAY_ROOT/agents/machine-comment.sh"
mc_now() { printf '%s\n' "${IN_NOW:-2026-11-10T19:15:00Z}"; }

slug="$IN_SLUG"
repo="$IN_REPO"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list.json")"
orphans=""
# the grace clock: pinned so "dead for N hours" is a recorded fact, not the day the suite runs
sa_now() { date -u -d "${IN_NOW:-2026-11-10T19:15:00Z}" +%s; }
