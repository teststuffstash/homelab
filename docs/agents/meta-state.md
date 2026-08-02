# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid.)

## Live world state (router test 2026-08-02; session 3 resumed ~14:00Z)

- **World ENABLED.** `coordinate-sleep` + `review-sleep` CronWorkflows live (10-min cadence,
  not suspended), ticking green. Coordinator/reviewer = sonnet.
- **ADR-096 router LIVE TEST in flight (2026-08-02, operator-directed):** sleep worker chain is
  **FREE-FIRST** (`laguna:free` primary — sleep-iac#53; deliberately failure-prone: the
  cooldown/recovery loop needs weather). `AGENT_ROUTER=shadow` fleet default — watch proxy logs
  for `POST /route` + `cooldown tripped/cleared`, decisions in `/router-status`. P4 flip waits
  on the shadow soak (FU-095). Revert the chain via sleep-iac when the test has yielded enough.
  **Progress:** #92 → PR#106 merged CLEAN end-to-end on laguna:free (~100min ride, 306s turns,
  zero failures — no cooldown weather yet); **#96 riding** (r1 dispatched 13:24Z on laguna:free,
  pod `agent-sleep-tracking-issue-96-r1` ns sleep-tracking); #99/#103/#105 queued behind it.
  Shadow `/route` divergence continues: both #96 route calls picked `ling-3.0-flash:free` vs
  static laguna. No cooldowns active; expect PR ≈15:00-15:30Z (100min #92 baseline), then
  review edge → merge → next queue item.
- ✅ WIP-hold jq-null fix (e2fdbe7) VERIFIED live 13:50Z: tick during the #96 ride printed
  `⏳ project WIP busy` ×3 + "no LLM woken", no coordinator pod spawned.
- **⏳ PENDING VERIFICATION:** scan probe-skip for fixerless repos (d8f3a8e) — next
  coordinate-sleep tick must NOT print `[snore-recorder] ⚠ WIP pod probe FAILED` (root: no
  fixer block → no ns RBAC; probe now skipped for non-dispatchable repos).
- **⏳ PENDING BUILD (ride-gap only — single proxy Recreate roll):** the homelab#22 batch, notes
  on the issue: `REQUEST_DEADLINE_S≈900`, model-labeled in-flight gauge, harvest
  `generation_time` (store's `latency`=TTFT only — unlocks decode-tok/s, the §M8 free-band
  tie-break), `activeDeadlineSeconds` on ride pods (no total-session bound exists today).
- Platform queue residue: homelab#22 (above); sleep-tracking#104 (datasource naming — touches
  the #77-stabilized uid gate, needs steering if queued) + #16 dep-dashboard, both unlabeled.
- **Shadow-soak review checklist (run before the P4 flip; collect ≥1wk of decisions):**
  (1) divergence table — `decisions` where shadow model ≠ dispatched model: would the router's
  pick have done better/worse (join run_reports outcomes)? (2) defer audit — every `defer`
  reason correct + retry_after honored by callers? (3) cooldown episodes — trips/half-open
  re-picks/escalations from `router_cooldown*` + circuit events: any flapping? (4) latency —
  needs homelab#22's `generation_time` harvest first; then check the free-band tie-break case
  (laguna 306s/turn, ~9× verbosity vs deepseek — model-routing §M8 ¶latency). (5) jitter-pool
  health — is exploration actually spreading picks across the band (`jitter_pool` in decision
  detail)? (6) `--help`-class junk rows excluded from the analysis (guard shipped e2fdbe7).
- **Infra hardening landed TODAY (07-31, operator session)** — `devbox run ci` + `devbox run
  test-integration` now work both in-ride and in CI for sleep; sleep's agent-stack ≈ oracle-fleet.
  FU-118/119/120 done. No structural blockers outstanding. (Detail: TICK-LOG 2026-07-31 entry.)

## Standing / parked (compressed — detail in TICK-LOG or the FU)

- Open session FUs: **FU-123** (in-pod arm-auto-merge fails, hypothesis needs an agent-finalize
  read) + **FU-124** (last-open-PR BEHIND → unreliable cron is the sole updater backstop; watch
  clause: armed PR BEHIND >15min).

- **FU-117** (context architecture) — DELIBERATE let-it-pile-up (operator's grow-then-refactor).
  Note sightings; don't refactor yet.
- **Dep-gate fragility**: a markdown-bullet `- Depends-on:` slips the `^[ \t]*depends-on:` scan
  regex. Write Depends-on lines UNBULLETED until FU-111 (native `blockedBy`) lands.
- Worker git tokens CAN push `.github/workflows/*` (homelab-agents App has `workflows:write`, proven
  PR#80). Workflow-only issues ARE worker-doable. Branch-protection RULE edits stay repo-admin/tofu.
- **FU-058 retro-session** deployed SUSPENDED (hand-fire). **Oracle/UC-1** operator-paced (its lane).

## Re-arm on a fresh session (watches die with `/clear`)

- Loop watch (`bash agents/meta-watch-loop.sh`, persistent) + 2h backstop heartbeat (each sweep runs
  `agents/meta-alert-crosscheck.sh`). Re-arm fresh; don't trust old monitor ids.
- Probe hygiene: probes in SCRIPT FILES, dry-run under the real interpreter; never a bare
  `devbox run -- kubectl` with no subcommand (prints help into the captured var); watch the FAILURE
  signature explicitly; stop orphan monitors from dead sessions on sight.
