# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).

_Session handoff 2026-07-24 ~16:00 (operator break; FU-015 in a fresh session):_

- **FU-015 (CI speedup)** — THE NEXT SESSION'S OPENING TASK, operator-directed. Measured:
  454s of a 610s ci job is devbox install. Order: custom ARC runner image (xz/gh/nix/devbox +
  nixcache-VIP substituter) first, warm-store layer second. arc-runners.yaml currently runs the
  stock image; the scale set template gains the image override.
- **fleet PR #104 (specs/docs tree split)** — riding CI/bot-review; touches specs/ → will PARK
  on the delegated-codeowner gate: READ the diff (structural move + link rewrites ONLY, no row
  semantics; CODEOWNERS extension travels in it), approve, C6 nothing (no issue).
- **fleet PR #105 (devbox.lock skopeo pin)** — armed; on merge the loop's C4/C5 auto-redispatches
  the #82 serve ride (it struck on the unlocked dep). The serve PR that eventually lands needs
  the codeowner gate (chart + digest-pinned corpus image per the #82 comment).
- **Post-corpus arc** (after serve): #83 agentic probe + #84 gap sprouts await the operator pass
  (prompt corpus + route naming) before agent-fix.
- **Standing watches to re-arm on session start** (they died with the old session): the loop
  monitor (`bash agents/meta-watch-loop.sh`) + the 2h heartbeat — see the skill's bootstrap.
