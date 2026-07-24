# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).

_Session handoff 2026-07-24 ~16:00 (operator break; FU-015 in a fresh session):_

- **FU-015 (CI speedup)** — THE NEXT SESSION'S OPENING TASK, operator-directed. Measured:
  454s of a 610s ci job is devbox install. Order: custom ARC runner image (xz/gh/nix/devbox +
  nixcache-VIP substituter) first, warm-store layer second. arc-runners.yaml currently runs the
  stock image; the scale set template gains the image override.
- **fleet PR #104 (specs/docs tree split)** — ✅ MERGED 2026-07-24 17:48 (3d8b0ad). Gate read
  done pre-merge; move defects (19 broken links + stale TRACKS redirect stub) fixed on-branch
  (5de6991 + 62dfbcd). Lesson recorded in merge-path-fsm MP-T08: author==sole-codeowner PRs
  never park (GitHub waives the codeowner review for the author) → on meta-authored spec PRs the
  delegated read must land BEFORE the bot verdict. FU-088 note: headroom gate deferred both
  reviews ~1h at utilization 0.93 — worked as designed, backstop re-dispatched.
- **fleet PR #106 (#82 serve: chart Deployment + HTTPRoute)** — the #105→#82 redispatch worked;
  delegated gate read DONE 2026-07-24 (digest pin enforced + negative rows ✓; comment posted):
  rides bot-review/auto-merge normally (chart/ is not CODEOWNERS-gated). ImageVolume
  ✅ VERIFIED live 2026-07-24 (canary on wk-02: k8s 1.36.1 default gates + containerd 2.2.3
  mount an OCI image volume fine — comment on the PR; no Talos change needed before oracle-iac
  enables `mcpServer`). The ⚖ "DEP-* spec page?" question awaits the operator.
- **Post-corpus arc** (after serve): #83 agentic probe + #84 gap sprouts await the operator pass
  (prompt corpus + route naming) before agent-fix.
- **Standing watches to re-arm on session start** (they died with the old session): the loop
  monitor (`bash agents/meta-watch-loop.sh`) + the 2h heartbeat — see the skill's bootstrap.
