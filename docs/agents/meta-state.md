# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).

_Session handoff 2026-07-24 ~16:00 (operator break; FU-015 in a fresh session):_

- **FU-015 (CI speedup)** — THE NEXT SESSION'S OPENING TASK, operator-directed. Measured:
  454s of a 610s ci job is devbox install. Order: custom ARC runner image (xz/gh/nix/devbox +
  nixcache-VIP substituter) first, warm-store layer second. arc-runners.yaml currently runs the
  stock image; the scale set template gains the image override.
- **fleet PR #104 (specs/docs tree split)** — gate read DONE 2026-07-24 (structural + CODEOWNERS
  travel ✓, no row semantics ✓), but the move had 19 broken relative links + a stale TRACKS
  redirect stub (lychee site gate caught it) — fixed on-branch (5de6991 + 62dfbcd, gate-read
  comment posted). ⚠ author == RasmusSoot == the sole CODEOWNER → self-approval impossible;
  release = **admin merge once CI green + bot APPROVE at head** (watcher: scratchpad
  watch-104.sh — Actions-runs + reviews REST; the jail PAT 403s on the Checks API).
- **fleet PR #106 (#82 serve: chart Deployment + HTTPRoute)** — the #105→#82 redispatch worked;
  delegated gate read DONE 2026-07-24 (digest pin enforced + negative rows ✓; comment posted):
  rides bot-review/auto-merge normally (chart/ is not CODEOWNERS-gated). Flagged on the PR: the
  `volumes[].image` corpus mount needs the **ImageVolume feature gate** (+ containerd support)
  verified on the live cluster BEFORE oracle-iac enables `mcpServer`; the ⚖ "DEP-* spec page?"
  question awaits the operator.
- **Post-corpus arc** (after serve): #83 agentic probe + #84 gap sprouts await the operator pass
  (prompt corpus + route naming) before agent-fix.
- **Standing watches to re-arm on session start** (they died with the old session): the loop
  monitor (`bash agents/meta-watch-loop.sh`) + the 2h heartbeat — see the skill's bootstrap.
