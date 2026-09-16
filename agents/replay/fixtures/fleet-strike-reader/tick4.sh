# ────────────────────────────────────────────────────────────────────────────────────────────────
# TICK 4 — RESOLVED inside the window (homelab#1712). Same four strikes as tick 1, but a CLOSED
# filing (#999) for `error_class=unknown` covers the set and its close (2026-09-01T16:30:00Z) is
# NEWER than the newest strike in the set (15:00Z). The class was resolved inside the window, so
# the reader neither re-files nor re-applies `agent/error`.
# DATE_TS=1788285600 (2026-09-01T18:00:00Z — the 24h window is still live).
# Expected: ZERO writes — 4 comment reads + 1 closed-filing list + 1 filing-comment read — and the
# RESOLVED log line.
# ────────────────────────────────────────────────────────────────────────────────────────────────
echo "REACHED: tick 4 — closed filing newer than the strikes (resolved)"
DATE_TS=1788285600
export REPLAY_WORLD="$REPLAY_FIXTURE/world-resolved"
# openall: the same four open issues (#326-#329) with agent-fix, no agent/error
openall="$(cat "$REPLAY_WORLD/gh/issue-list-openall.json")"
