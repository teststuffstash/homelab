# ── bridge ── set up variables that the fu124-nudge block needs
#
# The block expects slug, repo, and prsjson to be set. The prsjson variable
# carries the output of `gh pr list --json ...` — the nudge reads it to find
# armed+BEHIND PRs and their headRefOid values.
#
# Each row patches prsjson via the patches/ directory to set up its condition.
# The board world has a base prsjson with no BEHIND PRs.

slug="teststuffstash/testrepo"
repo="testrepo"

# prsjson is loaded from the world file by the table runner (the board world
# provides the base, patches add BEHIND PRs). The bridge reads it from the
# world path that the replay harness sets.
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list.json" 2>/dev/null || echo '[]')"