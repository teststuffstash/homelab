# ────────────────────────────────────────────────────────────────────────────────────────────────
# TICK 3 — stale world: same four strikes but now_s is >24h after the newest strike.
# The strikes cluster within 24h of each other (span=5h) but the newest is 33h old.
# DATE_TS=1788451200 (2026-09-03T00:00:00Z, >24h after the last strike — window expired).
# Expected: ZERO new actions (the live-window check fires — now_s - max_ts > 86400).
# ────────────────────────────────────────────────────────────────────────────────────────────────
echo "REACHED: tick 3 — stale world (window expired)"
DATE_TS=1788451200
export REPLAY_WORLD="$REPLAY_FIXTURE/world"
# openall: same as tick 1 (four open issues with agent-fix, no agent/error)
openall="$(cat "$REPLAY_WORLD/gh/issue-list-openall.json")"