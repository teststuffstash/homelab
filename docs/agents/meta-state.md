# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid.)

## Live world state (router test 2026-08-02; session 3 resumed ~14:00Z)

- **World ENABLED.** `coordinate-sleep` + `review-sleep` CronWorkflows live (10-min cadence,
  not suspended), ticking green. Coordinator/reviewer = sonnet.
- **Chain REDIRECTED (operator, 2026-08-02 ~18:30Z): free-first test yield banked, sleep-iac#56
  MERGED 18:35Z** → `xiaomi/mimo-v2.5` primary → `tencent/hy3` → deepseek → qwen3-coder →
  claude/haiku (frees dropped off the walk; rationale in the claim comment + PR#56). Free-first
  results: #92/#96/#99 → PR#106/107/108 all merged clean on laguna:free; NO cooldown weather
  materialized. **#103 riding since 18:31Z (LAST laguna:free ride, 4h deadline); #105 next =
  the FIRST mimo dispatch — watch its estimator/pin behave.** `AGENT_ROUTER=shadow` unchanged;
  P4 flip still waits on the soak (FU-095). ⏳ `xiaomi/mimo-v2.5` model_tiers entry
  (model-classes.json — P5 rotation universe only, NOT dispatch-path) batched for the next
  proxy-roll window. GC-on-expiry = openrouter-operator#10.
- Jetify phone-home path 3 belted (18153b4): the LAUNCHER ignores the 07-22 env vars,
  refetches when the devbox-cache current-version file ages past 24h → VERSION_CACHE_TTL=1y
  in the pod template. Takes effect on newly dispatched rides (#99 onward); the
  AgentWorkerEgressDropped alert cleared 17:2xZ.
- ✅ VERIFIED: WIP-hold jq-null fix (e2fdbe7) + fixerless probe-skip (d8f3a8e). Loop watch
  REWRITTEN for the sleep stack (was still on oracle — blind all session): startTime-keyed
  pod state, circuit/key-window/FU-124 clauses, Alertmanager firing-set awareness
  (InfoInhibitor filtered; triage stays with the responder).
- ✅ homelab#22 CLOSED (91c9c29, proxy rolled 18:29Z, all four deliverables verified live —
  TICK-LOG cont. 4). Soak watch: `router_request_deadline_exceeded_total` should stay 0 on
  healthy laguna rides (306s turns ≪ 900s); a nonzero burst = the deadline is biting real
  turns → revisit the default before blaming providers.
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

- **⏳ FU-123 fix DEPLOYED** (agent-runtime#26 merged + pin homelab#75 auto-merged; #103's ride
  runs the fixed image). ACCEPTANCE PENDING: `armed_by_pod=true` on #103's AGENT_RUN_STATS
  line (PR expected ~19:5x, laguna rides ≈80-100min) → then archive FU-123.
- Open session FUs: **FU-124** (last-open-PR BEHIND → unreliable cron is the sole updater
  backstop; watch clause: armed PR BEHIND >15min).

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
