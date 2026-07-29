# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid. Meta-15's full arc is in `agents/coordinator/TICK-LOG.md`.)

## Live world state (meta-15 end, 2026-07-28)

- **⏹ BOUNDED RUN (operator directive 2026-07-29 ~05:05Z):** stop meta-coordination after **16h
  (≈2026-07-29 21:05Z)** OR when the dispatchable queue drains, whichever first. Then **close cleanly**:
  suspend all 3 coordinators + both reflexes, NO `agent/queued`/`agent/in-progress` labels left anywhere,
  no running worker pods, watches TaskStop'd, TICK-LOG+meta-state pushed. `agent/blocked` = human-owned
  (not dispatchable) so it's an OK parked state. Dispatchable queue to drain = sleep **#71** + **#43**
  (oracle is operator-paced/quiet; harvested follow-ups are unlabeled operator-triage — do NOT queue new
  work). Progress tracked in the session task list.
- **World ENABLED** (must be DISABLED at shutdown). All three coordinators (sleep / oracle / platform)
  `enabled=true`; both global reflexes (`coordinator-reflex` + `review-reflex`) `suspend=false`. Sleep
  worker = `claude/haiku` (sleep-iac#39). Watch haiku subscription load stays under the FU-088 gate.
- **FU-088 gate is now PER-WINDOW** (PR#70 merged+live 2026-07-28): 5h@0.80 (finish-in-progress guard),
  **7d@0.95** (operator weekly-headroom pref, `ANTHROPIC_UTIL_THRESHOLD_7D`). So 7d sitting at ~0.81 no
  longer freezes dispatch (it would under the old single-0.80 gate). Verify live: proxy
  `/anthropic-limit` `.thresholds`.
- **wk-metal-04** (16GB desktop, i5-3570K, @.186) is a live kata ephemeral-tier node (BGP established,
  FU-112b reservation applied). Goose-only (no AVX2). The Playwright/Chrome gate's home when it graduates.

## Active sleep-queue watch (the operator's standing ask: "meta-coordinate all the sleep tasks")

THE DRAIN CHAIN (meta-16 cont., 2026-07-29) — sleep stack shares ONE WIP slot (FU-042 per-stack):
- **#42 ✅ CLOSED (was a FALSE `agent/done`).** PR#76 set `queryType:"time series"` on 3/6 panels →
  frser can't serve the wide SQL → blank. Meta-coord PR#78 (all 6 → `table`) proven GREEN via a
  `require-green=true` dispatch, admin-merged 2026-07-29. (Root demo: gate positive-control uses `table`
  and returns the ~511 value; `time series` returns none.)
- **#43 ✅ CLOSED.** Was mis-dispatched to a worker (only real work = a `.github/workflows/` edit, worker
  token-forbidden). Operator-lane PR#79: `REQUIRE_GREEN` now forced `true` on the `pull_request` trigger
  (`github.event_name=='pull_request' && 'true' || …`). Its own enforced gate self-proved GREEN,
  admin-merged. **Follow-up for a human: mark `integration / system-test` a REQUIRED check in branch
  protection** to make it a hard merge gate (repo-admin, outside my note — flagged in the PR).
- **#71 (k3d→kind) — UNBLOCKED + `agent/queued` 2026-07-29.** Decision (mine): FU-119 (rides have the
  docker socket but no docker CLI) is NOT a migration blocker — the `homelab-ephemeral` ARC runner HAS
  docker (gate builds a real k3d cluster) so **CI is the check**; #43's now-enforced gate means the kind
  PR is GREEN-or-blocked. Instructions posted on the issue (by-hand devbox.json k3d removal, no
  `devbox add`, rewrite test-integration.sh→kind with `containerdConfigPatches`/hosts.toml mirror for
  #67, no local verify). Loop dispatches next scan (~10min). Lands → closes #67. If not done by 21:05Z →
  park `agent/blocked`.
- **snore-recorder #12 (`agent/queued`, enhancement) — behind #71 on the shared sleep WIP slot.** LED
  solid on backstop/auto recording. Starved 2 days by continuous sleep-tracking work (not un-laned —
  coordinate-sleep DOES cover snore-recorder). Drains after #71; park `agent/blocked` if it can't land.
- **#77 (unlabeled harvest) = the DOMINANT prod blank-cause** the gate can't see: provisioning
  `grafana/provisioning/datasources/sleep-notes.yaml` pins NO `uid:` → Grafana auto-gens one, panels'
  hardcoded `"uid":"sleep-notes"` won't resolve → all-blank. Fix = pin `uid: sleep-notes`. NOT done here
  (needs cross-repo confirmation of WHERE prod provisions the datasource — the chart has no datasource
  template). Left for the operator; my #42/#43 work does NOT clear the blank symptom alone. **Flag at handoff.**
- **#77 (unlabeled harvest, operator-triage) = the DOMINANT prod blank-cause** the gate can't see: the
  provisioning datasource `grafana/provisioning/datasources/sleep-notes.yaml` pins NO `uid:`, so
  Grafana auto-generates one and the panels' hardcoded `"uid":"sleep-notes"` won't resolve → all panels
  blank. Fix = pin `uid: sleep-notes` there. NOT done here (needs cross-repo confirmation of WHERE the
  prod datasource is provisioned — the chart has no datasource template). Left for the operator; my #42
  fix + #43 gate do NOT clear the blank symptom alone. **Flag prominently at handoff.**

## Standing / parked (compressed — detail in TICK-LOG or the FU)

- **FU-117** (context architecture) — DELIBERATE let-it-pile-up (operator's grow-then-refactor style).
  Interim shipped (env card carries devbox/proxies; SERVICES.md-grep removed — workers have no homelab
  clone, service context is author/coordinator-injected). Just keep noting sightings; don't refactor yet.
- **Dep-gate fragility**: a markdown-bullet `- Depends-on:` slips the `^[ \t]*depends-on:` scan regex
  (#71 ran early on it). Write Depends-on lines UNBULLETED until FU-111 (native `blockedBy`) lands.
- **CORRECTION (2026-07-29): worker git tokens CAN push `.github/workflows/*`.** The homelab-agents App
  has `workflows:write` (operator granted it — TICK-LOG ~1007/1233), PROVEN live: PR#80 (a worker ride)
  pushed an `integration.yaml` change. So the role note "workflows changes = operator-lane, tokens forbid
  them" is STALE — workflow-only issues ARE worker-doable; don't reflexively pull them operator-lane.
  (Taking #43 operator-lane was still a fine call — the require-green expression is subtle + false-done
  risk — just not forced by a token limit.) Branch-protection RULE edits remain repo-admin/tofu, though.
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
