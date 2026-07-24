# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).

_Session handoff 2026-07-24 ~16:00 (operator break; FU-015 in a fresh session):_

- **FU-015 (CI speedup)** — THE NEXT SESSION'S OPENING TASK, operator-directed. Measured:
  454s of a 610s ci job is devbox install. Order: custom ARC runner image (xz/gh/nix/devbox +
  nixcache-VIP substituter) first, warm-store layer second. arc-runners.yaml currently runs the
  stock image; the scale set template gains the image override.
- **Post-corpus arc — serve chart LANDED, operator pass now due.** #104 (specs/docs split) +
  #106 (#82 serve chart) both merged 2026-07-24 (TICK-LOG meta-9 cont.8 has the session detail;
  MP-T08 carries the author==sole-codeowner no-park lesson). Open-PR set empty. Waiting on the
  OPERATOR: (a) #82 deliverable 3 — manual acceptance, UC-1 over the real corpus via
  MCP-inspector, after the cross-lane bring-up items in the #106 body (CORPUS_DB in the server,
  a serving image; ImageVolume is verified-live, not a blocker); (b) the ⚖ "DEP-* spec page?"
  question from #106; (c) the reviewer's non-blocking digest-regex tightening (prefix-only
  sha256: check) — surface via the C6/FU-090 issue gate; (d) then #83 agentic probe + #84 gap
  sprouts (prompt corpus + route naming) before agent-fix.
- **Standing watches to re-arm on session start** (they died with the old session): the loop
  monitor (`bash agents/meta-watch-loop.sh`) + the 2h heartbeat — see the skill's bootstrap.
