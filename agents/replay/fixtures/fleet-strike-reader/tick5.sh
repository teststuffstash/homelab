# ────────────────────────────────────────────────────────────────────────────────────────────────
# TICK 5 — RE-ARMED by a NEW strike (homelab#1712). The SAME closed filing (#999, closed
# 2026-09-01T16:30:00Z) and the same `issues=` marker, but #330 now carries a strike at
# 2026-09-01T17:30:00Z — NEWER than the close. The subtraction does not fire and the normal path
# owns the class: `agent/error` applied, ONE comment, ONE new filing (the old one is CLOSED, so the
# open-filing dedup finds nothing).
#
# The marker covers 326-330 in BOTH rows, so the coverage test passes in both and the ONLY
# discriminator between tick 4 and tick 5 is close-vs-newest-strike. That is the half of the
# subtraction this row exists to pin.
#
# DATE_TS=1788285600 (2026-09-01T18:00:00Z — the window is live; newest strike 30m old).
# Expected: 5 label edits + 1 comment + 1 filing + reads.
# ────────────────────────────────────────────────────────────────────────────────────────────────
echo "REACHED: tick 5 — new strike newer than the close (re-armed)"
DATE_TS=1788285600
export REPLAY_WORLD="$REPLAY_FIXTURE/world-resolved"
# openall: the four tick-4 issues PLUS #330, which struck at 17:30Z (after the 16:30Z close)
openall="$(cat "$REPLAY_WORLD/gh/issue-list-openall-rearmed.json")"
