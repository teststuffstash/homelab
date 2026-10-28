# 2026-10-28 — opencode 2.x headless rides hung on open stdin (since the 10-26 major bump)

**Tracked by:** FU-187 (quiet-stall detection, still open). The fix shipped the same day (#2998).

**Impact.** From agent-runtime#183 (merged 2026-10-26 08:40Z, opencode 1.19.0 → 2.1.1) to
#2998 (2026-10-28 17:50Z), every headless `opencode run` launched with an open, never-closed
stdin hung before its first model call. That covers worker rides, scouts, re-review's Zen arm and
the specs reviewer's opencode arm. Each hung ride burned its pod until the 4h `activeDeadline`
reap, which skips finalize. Seen live: two circles#135 worker rounds (16:14Z, 16:56Z), each
silent for 38+ min. No alert fired. It was found because the operator asked the seat to check on
the ride.

**Timeline (UTC, 2026-10-28).**

- 16:14 circles#135 r1 starts: opencode with `deepseek/deepseek-v4.1-flash:exacto`. Its
  opencode.log ends at 16:15:52, right after "database schema bootstrap completed". run.log is
  empty and nothing in the work tree changes.
- 16:54 seat check-in: the proxy is healthy (`/healthz` 200 in 12 ms), and the pod holds no
  socket to it (one TIME_WAIT). Read as FU-187's class. The seat SIGTERMs the harness, which
  takes the storm watchdog's kill path: finalize runs, a strike is posted.
- 16:56 r2 dispatched. The same silence follows from 16:58:27.
- 17:2x control runs in the pod:
  - `opencode run "pong"` hangs for 60 s on two models (the ride's model and v4-flash). So the
    model was ruled out.
  - The same command with `</dev/null` answers and starts tool calls within 25 s.
  - Conclusion: opencode ≥2 reads piped stdin and waits for EOF.
- 17:50 **#2998 merged**: `</dev/null` on every headless call site, plus a replay stub that
  hangs on a piped stdin. 17:51 the seat SIGTERMs r2; the next round clones the fix.

**Root cause.** A harness major bump changed a CLI contract (stdin handling) that nothing on the
merge path exercises. agent-runtime#183's migration-lens approval read the lock diff. CI proves
the toolchain installs. Class 11's `version-set-probe` runs `--version`-shaped checks, not a
headless turn. Downstream, the stall is invisible to every alert (FU-187): no log lines for the
storm watchdog, `AgentQueueStalled` suppressed by the running pod, and phase metrics only push at
finalize.

**What would have caught it.** Any headless smoke turn of each baked harness in the image's own
CI, run with the pod's stdin shape. Or FU-187's no-growth belt, which would have struck the first
ride within minutes instead of hours.

**Residual.** FU-187 (the detector). A per-harness headless smoke in agent-runtime's
`build-image` is the class-11 proposer-side half; it isn't filed separately, and FU-187's Next
names both.
