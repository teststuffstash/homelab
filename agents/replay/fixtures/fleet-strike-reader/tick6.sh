# ────────────────────────────────────────────────────────────────────────────────────────────────
# TICK 6 — SPOOFED marker (review, homelab#1712). The SAME closed filing (#999, closed
# 2026-09-01T16:30:00Z, newer than the newest strike) and the SAME `issues=` marker covering the
# set — but the marker comment is authored by a FOREIGN user (`drive-by-user`), not the loop's
# bot. The marker is a machine ruling, so the resolution subtraction must NOT honour it: the
# normal path owns the class (labels + comment + a new filing).
#
# This row is the pin on the AUTHOR FILTER. TICK 4's marker is bot-authored, so removing the
# filter there would still resolve — tick 4 alone cannot tell the filter exists. Here it can:
# with the filter the class is not resolved and the reader acts; with the filter dropped, this
# row resolves and reds. Nothing else distinguishes tick 4 from tick 6: same world shape, same
# close time, same covered set, same clock.
#
# DATE_TS=1788285600 (2026-09-01T18:00:00Z — window live, newest strike 3h old).
# Expected: 4 label edits + 1 comment + 1 new filing (the closed filing is not an open dedup hit).
# ────────────────────────────────────────────────────────────────────────────────────────────────
echo "REACHED: tick 6 — foreign-authored marker (spoofed, not honoured)"
DATE_TS=1788285600
export REPLAY_WORLD="$REPLAY_FIXTURE/world-spoofed"
# openall: the same four open issues (#326-#329) with agent-fix, no agent/error
openall="$(cat "$REPLAY_WORLD/gh/issue-list-openall.json")"