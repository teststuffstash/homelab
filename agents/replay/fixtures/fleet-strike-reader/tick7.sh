# ────────────────────────────────────────────────────────────────────────────────────────────────
# TICK 7 — marker-less latch case (homelab#2327).
# A previous tick posted the fleet-strike-fp: marker but the gh issue create failed (filing_n empty),
# so no fleet-fault cause= marker was written. The issues carry agent/error but the marker comment
# lacks the cause pointer — undiagnosable and un-clearable by the un-latch clause (which requires both).
# Expected: The scan runs again; it finds a marker comment without cause and filing_n is still empty
# (the filing list is empty). No new actions since no filing exists yet (filing_n stays empty).
# DATE_TS=1788285600 (same as tick 2 for simplicity).
# ────────────────────────────────────────────────────────────────────────────────────────────────
echo "REACHED: tick 7 — marker-less latch, no filing yet (homelab#2327 row 1)"
DATE_TS=1788285600
export REPLAY_WORLD="$REPLAY_FIXTURE/world-cause-fail"
# openall: four open issues (#326-#329) with agent-fix AND agent/error labels
openall="$(cat "$REPLAY_WORLD/gh/issue-list-openall.json")"
