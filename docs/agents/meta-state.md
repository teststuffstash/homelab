# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid. Meta-15's full arc is in `agents/coordinator/TICK-LOG.md`.)

## Live world state (meta-15 end, 2026-07-28)

- **World ENABLED.** All three coordinators (sleep / oracle / platform) `enabled=true`; both global
  reflexes (`coordinator-reflex` + `review-reflex`) `suspend=false`. Verified live. Sleep worker =
  `claude/haiku` (sleep-iac#39). Watch haiku subscription load stays under the FU-088 gate.
- **wk-metal-04** (16GB desktop, i5-3570K, @.186) is a live kata ephemeral-tier node (BGP established,
  FU-112b reservation applied). Goose-only (no AVX2). The Playwright/Chrome gate's home when it graduates.

## In-flight operator chains (check each on every heartbeat)

- **homelab PR#70 — FU-088 per-window thresholds (7d→0.95, 5h stays 0.80).** Operator-requested
  2026-07-28: 5h is the finish-in-progress guard, 7d is the operator's personal weekly headroom.
  Platform lane; **needs OPERATOR APPROVAL** (homelab master requires a review, no bot reviewer —
  `coordinator-session.sh:129` excludes homelab). Auto-merge armed + squash. NEXT: watch it merge →
  ArgoCD sync openrouter-proxy → the loop resumes deeper into the week (once 5h eases, 7d@0.80 no
  longer blocks). Env: `ANTHROPIC_UTIL_THRESHOLD_7D=0.95` in deployment.yaml.

## Active sleep-queue watch (the operator's standing ask: "meta-coordinate all the sleep tasks")

- **#48 LANDED** (PR#72 merged, CI green — the system-test gate: k3d + MinIO + ingester + Grafana,
  graph-read assertion). This unblocked its dependents.
- **#71 (k3d→kind migration) — r1 WEDGED + deleted 2026-07-28 ~21:22.** r1 hung ~3.5h in an
  unrecoverable claude-code network-timeout loop ("Request timed out / call final_output NOW" every
  ~2min since 21:00), Running-but-not-progressing → the coordinator's `phase=Running` filter read it
  as a live worker and DEFERRED (liveness≠progress trap). Worse: the **FU-042 1-worker WIP limit**
  (no TRACKS.md lane split) meant r1 held sleep-tracking's SOLE slot, so it also blocked #42 (verified
  pre-flight-refused "FU-042 WIP limit" at 20:42). Proxy confirmed HEALTHY (other sessions 200 in
  2-19s post-roll) → r1 was individually wedged, not a proxy regression. Deleted → freed the WIP slot.
  EXPECTED NEXT (deadline ~21:35): coordinator re-dispatches #71-**r2** (in-progress, no live worker →
  redispatch clause); bounded watch `bpd755sil` reports r2 liveness. If r2 ALSO wedges → environmental,
  not transient (investigate). When #71 lands it **closes #67**; verify `kind@latest` in devbox.json
  (not a downloaded binary) + the `kind_mirror` hosts.toml. #42 waits on the WIP slot behind #71.
- **#42 / #43** (dashboard-contract bugs) + **sleep-iac#25** — **#48 now CLOSED, so unblocked**;
  watch them flow. **#42 enriched 2026-07-28** with LIVE root cause of the operator's "all panels
  blank on /d/sleep-overview": the dominant cause is a **dangling `${DS_SLEEP_DB}` datasource var**
  (dashboard JSON references it in every panel but defines NO `__inputs`/templating → Grafana can't
  resolve → "datasource not found" everywhere); live datasource uid is `sleep-notes`. PLUS #42's
  original frser contract (rawSql/epoch). Deployed dashboard = the `sleep-ingester` Helm chart copy
  (sleep-tracking), NOT the "fixed sleep-iac copy" #42/#43's premise assumed — fix the chart's JSON.
  Data is HEALTHY (45 rows sleep_nights, sidecar syncing). Operator: no rush, land it with the other
  sleep issues. Fix must BIND the datasource (hardcode uid sleep-notes) + apply frser contract.

## Standing / parked (compressed — detail in TICK-LOG or the FU)

- **FU-117** (context architecture) — DELIBERATE let-it-pile-up (operator's grow-then-refactor style).
  Interim shipped (env card carries devbox/proxies; SERVICES.md-grep removed — workers have no homelab
  clone, service context is author/coordinator-injected). Just keep noting sightings; don't refactor yet.
- **Dep-gate fragility**: a markdown-bullet `- Depends-on:` slips the `^[ \t]*depends-on:` scan regex
  (#71 ran early on it). Write Depends-on lines UNBULLETED until FU-111 (native `blockedBy`) lands.
- **FU-106 iac-lane build** parked (design settled: `docs/agents/iac-lane.md`; build list IAC-G01..G06,
  rung-0 sleep PostSync smoke first). **FU-080** (agentstack rewrite) may be another session's lane —
  observe agentstack-shaped errors, don't fix from here; flag the operator only on unnoticed real damage.
- **FU-058 retro-session** deployed SUSPENDED (hand-fire; wants idle queue + ephemeral capped key).
- **Oracle/UC-1** operator-paced (roll-2 live; #84 corpus + #160 triage are the operator's lane).

## Re-arm on a fresh session (watches die with `/clear`)

- Per the meta-coordinate skill: re-arm the loop watch (`bash agents/meta-watch-loop.sh`, persistent)
  + the 2h backstop heartbeat (each sweep runs `agents/meta-alert-crosscheck.sh`). Meta-16 session
  armed loop=`bn59ctrq2`, heartbeat=`bxdzr3d88` (both die on /clear — re-arm fresh, don't trust these ids).
- Probe hygiene (hard-won): put probes in bash SCRIPT FILES and dry-run under the real interpreter (zsh
  no-word-split bites inline Monitors AND Bash); NEVER leave a stray `devbox run -- kubectl` with no
  subcommand in a probe (it prints kubectl help into your captured var — bit me twice this session);
  watch the FAILURE signature explicitly; orphan monitors from dead sessions duplicate events — stop on sight.
