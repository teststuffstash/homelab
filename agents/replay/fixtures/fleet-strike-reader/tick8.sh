# ────────────────────────────────────────────────────────────────────────────────────────────────
# TICK 8 — repost with cause marker (homelab#2327 row 2).
# The filing now exists (#999). When the scan runs, it should detect that the marker comment lacks
# the cause marker and repost it with the cause marker included.
# DATE_TS=1788285600 (same clock).
# Expected: The scan finds the existing marker comment, sees it lacks fleet-fault cause=, sees that
# filing_n is now set to 999, and reposts the comments with the cause marker included.
# ────────────────────────────────────────────────────────────────────────────────────────────────
echo "REACHED: tick 8 — repost with cause marker (homelab#2327 row 2)"
DATE_TS=1788285600
export REPLAY_WORLD="$REPLAY_FIXTURE/world-cause-repost"
# openall: four open issues (#326-#329) with agent-fix AND agent/error labels
openall="$(cat "$REPLAY_WORLD/gh/issue-list-openall.json")"
