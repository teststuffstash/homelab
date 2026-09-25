# ── bridge ── the per-repo loop variables the C9 block reads. Every name is a REFLEX variable set
# earlier in the file (`prs` from `gh pr list`, `slug`/`repo` from the repo loop, WORKER_AUTHOR /
# DEFAULT_BRANCH from the top-of-file defaults), never a harness invention. `prs` is the list
# payload the reflex already holds when the block runs, so it arrives as a world file rather than
# a stubbed call. `log` is the reflex's clock-stamped logger with the clock shadowed (README §S3:
# a timestamp in the stream would never diff clean).
log() { printf '%s\n' "$*"; }
WORKER_AUTHOR="app/homelab-agents-1234"
DEFAULT_BRANCH="master"
slug="teststuffstash/sleep-iac"
repo="sleep-iac"
prs="$(cat "$REPLAY_WORLD/gh/pr-list.json")"
