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
  **Progress:** #92 → PR#106 merged CLEAN (~100min ride). **#96 ride 1 DIED of key expiry**
  (2h window < laguna pace — TICK-LOG 2026-08-02 cont. 2; TTL default now 4h, c9d1c08);
  **ride 2 running** since 15:42Z, but its key was minted under the OLD 2h default →
  **expires 17:41Z**. Watch clause fires at ride age >100min. CONTINGENCY if still PR-less
  near 17:30Z: delete + re-apply the session-key CR (forces POST → fresh key; cred injection
  should pick the new Secret up transparently — unproven mid-ride, but a certain death
  otherwise, and a live test of operator#6's rotation seamlessness). #99/#103/#105 queued.
  Shadow `/route` keeps diverging (ling:free vs static laguna). No cooldown weather yet.
- ✅ VERIFIED: WIP-hold jq-null fix (e2fdbe7, 13:50Z tick) + fixerless probe-skip (d8f3a8e,
  15:50Z tick). Loop watch REWRITTEN for the sleep stack (was still on oracle — blind all
  session) with startTime-keyed pod state, circuit/key-window/FU-124 clauses.
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
