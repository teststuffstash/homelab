# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).

_Session handoff 2026-07-24 ~16:00 (operator break; FU-015 in a fresh session):_

- **FU-015 (CI speedup)** — THE NEXT SESSION'S OPENING TASK, operator-directed. Measured:
  454s of a 610s ci job is devbox install. Order: custom ARC runner image (xz/gh/nix/devbox +
  nixcache-VIP substituter) first, warm-store layer second. arc-runners.yaml currently runs the
  stock image; the scale set template gains the image override.
- **Serve bring-up — THREE chart bugs found live, fix #3 riding.** #107/#108/#110/#113 merged;
  flip done (oracle-iac#157) + two values overrides (#158 phantom image repo, #159 wrong
  Gateway parentRef — stack routes attach to `oracle-gateway` in-ns, NOT cilium/gateway).
  Bug #3: the corpus data image nests payload under `corpus/` → flat mount ≠ CORPUS_DB contract
  path → server exits fatal (SRV-CORPUS-DB no-fallback working as spec'd) → envoy 503.
  Fix = `subPath: corpus` (fleet#114, auto-merge armed) → chart build → iac auto-bump →
  rollout. Watcher: endpoint-200 probe (initialize at mcp.oracle.teststuff.net). THEN the UC-1
  acceptance (PS date-travel canonical calls, assert citations) → post on fleet#82. Wins so
  far: ImageVolume's first production pull (215MB/22s) ✓; both no-fallback + digest guards
  fired exactly as spec'd.
- **Post-corpus arc — operator pass EXECUTED 2026-07-24 evening** (rulings received in-session;
  TICK-LOG meta-9 cont.8): bring-up issues **fleet#107** (server CORPUS_DB) + **fleet#108**
  (serving image) filed + armed (agent-fix, md budget) — the loop dispatches them; when BOTH
  close, the oracle-iac `mcpServer.enabled=true` flip PR runs the UC-1 MCP-inspector acceptance
  (#82 deliverable 3 — operator DELEGATED, no ceremony to wait for). Pre-wiring merged/riding:
  **oracle-iac#147** (mcpServer values, digest-pinned, disabled) + **fleet#110** (DEP-SERVE spec
  page + full-digest render guard — the #106 review catch), both auto-merge-armed. #83 got the
  operator direction on-issue: kind-cluster first, NOT in `devbox run ci` (flaky-tolerant
  separate task). **fleet#109** = the unarmed specs-cleanup bundle (UC-1→named world,
  real-corpus worlds beyond põhiseadus, DEP-page disposition) — operator's later work alongside
  the allure-snippets generator. #84 still awaits the operator prompt-corpus/route-naming pass.
- **Standing watches to re-arm on session start** (they died with the old session): the loop
  monitor (`bash agents/meta-watch-loop.sh`) + the 2h heartbeat — see the skill's bootstrap.
