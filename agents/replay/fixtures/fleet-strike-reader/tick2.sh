# ────────────────────────────────────────────────────────────────────────────────────────────────
# TICK 2 — second pass against the POST-ACTION world.
# Issues now carry agent/error label, the first affected issue (#326) already has the
# fleet-strike-fp: marker comment, and the filing already exists.
# DATE_TS=1788285600 (same clock — same scan tick, but world reflects already-actioned state).
# Expected: ZERO new actions (idempotency guards fire on all three paths).
# ────────────────────────────────────────────────────────────────────────────────────────────────
echo "REACHED: tick 2 — second pass, post-action world (idempotency)"
DATE_TS=1788285600
export REPLAY_WORLD="$REPLAY_FIXTURE/world-tick2"
# openall: four open issues (#326-#329) with agent-fix AND agent/error labels
openall="$(cat "$REPLAY_WORLD/gh/issue-list-openall.json")"