# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid.)


## Live state (pruned 2026-08-19 — history is TICK-LOG's; the forward plan is the ROADMAP work map)

- **⚑ [Stint](chainless-redesign.md) S7 (#741) LAUNCHED 2026-08-23 (operator go + latch clean).** Session 1 built all
  three in-order children: #743 exporter edge MERGED (PR#757 — mergeStateStatus on the walk +
  maybe_dispatch_behind + UPDATE_PR_WEBHOOK_URL env); #742 script+replay-table (PR#755) and
  #744 manifests (PR#758, bring-up guard covers merge-order) mid-cycle at last write — finish
  their gate reads if parked. #746 QUEUED to the cluster loop (labels + doorbell rung). **#745
  cutover stays PARKED: un-park after a few days of the in-cluster leg observed servicing BOTH
  paths** — read `update-pr-edge-*` workflow logs for edge-serviced updates and the cron's
  CRON-SERVICED lines (silence there = the edge carries the load), and `gh run list` on the
  callers showing the hosted runs idle; then #745 deletes callers/reusable/org-secrets + FSM
  anchor repoint. The #698 Alertmanager silence `5400ed94…` self-expires 2026-09-01 and needs
  nothing. Label-identity decision recorded in-code: merge App stays issues-less,
  UPDATER_LABEL_TOKEN=coordinator-git.

- **⚑ PICKUP (2026-08-20 ~06:00Z wind-down, night session closed on operator feedback — see the
  session-winddown memory):** in flight, all machine-owned: PR#705 (fixes #674, STRUCK_MODEL
  chain-id) + PR#704 (fixes #676, poll_forever fixture) mid-cycle — they will park bot-approved
  at the codeowner gate for the NEXT corpus session's read; #701 + #707 queued behind them.
  Watch items: the hourly iac-sentinel backstop's CRON-SERVICED detector (silence over weeks =
  retire the cron; any firing names a dead edge); #459 re-read `changes(agent_dispatch_cron_
  woken_timestamp[24h])` post-#669/#672/#679 before hunting emitters; hosted-minutes ruling on
  #698 = tolerated updater stalls until Sep-1 (overage stays OFF). S2 DONE (stint #661 closed,
  #354 acceptance PASSED); S3 DONE (FU-176 archived + sentinel push/tool-error/edge chain);
  next stints: S4, S5 (ROADMAP work map).

- **⚑ FU-058 stint DONE (2026-08-19, one session — #587 at final closeout; closes when docs
  PR#624 lands). WATCH: the Mon 2026-08-24 05:00 UTC retro cron = the platform series' first
  unattended fire, the build wave's organic acceptance** (full report per cell, content floor
  holding, distinct files for identical cells, no false RetroReportOverdue). Post-fire read =
  next session's first item; a failed fire is a defect on FU-058's Next.
- **⚑ Board close-out afternoon (2026-08-19, operator-driven): the ring-heavy day's residue.**
  Landed: #631 (exit-3 absorption + FU-121 drain — the famine class fix; watch the Failed pile
  STOP growing and TTL out by ~Aug-22), #626 (blind-ride abort), #634+#633 (marker anchoring +
  env-card rule), #632 (meta-events NEWISSUE source — per-repo REST walk, act rule: platform
  repos only), #628 re-scoped as the throughput CONTAINER (legs #636 queued/#637 filed; leg 3 =
  generalize agent-goals machinery, operator pointer in body). At session end: #641(#635)+#642(#639)
  merged via gate reads; #643 (fixes #629 — strike model field) in its review cycle, #640
  riding, #636 queued behind it — all machine-owned; the next session's gate reads finish them. Lineage: #629→#622→#607→
  #600→#420 now fully native (#607's missing edge was the break). GithubRateLimitLow +
  AgentRunInfraDeathBurst today = demand bursts, both self-resolved/accounted.
- **⚑ Go rail EXHAUSTED for the month (console 100%/30d, resets Sep-13 ~11:30Z; weekly 99% →
  Mon 00Z).** The 429→same-round-haiku belt is LIVE and organically proven (#607→PR#615); latch
  persistence landed (#618→#621) AFTER the first fire, so the NEXT Go dispatch burns one 429 to
  latch and the hold now survives proxy rolls — verify `router_go_capacity_latched` stays 1
  across the next deploy. #420 + #540 CLOSED (operator, 2026-08-19) — the post-reset readout
  (parity on a clean window, the 5h refusal shape, latch-survives-roll) is **FU-181**, actionable
  after Sep-13.
- **⚑ PRIORITY ORDER (operator ruling, 2026-08-18): OPEN ISSUES FIRST → then follow-ups/corpus
  buildout → then stacks.** The forward plan lives in **ROADMAP §The platform work map**
  (stints S1–S5 → Goals G-A–G-D; supersedes the old Bucket A/B worklog that sat here).
- **⚑ Goal lane pause (operator, 2026-08-13):** no new Goal until v1.2 machinery + budget
  recovery. As of 2026-08-19 the conditions read met (work map) — the unpause is the operator's
  call at G-A launch; Goal budgets on [the platform stack](agentstack.md) stay cap-phantom until FU-180.
- **minutark.ee / oracle-iac#351** — OPEN, oracle parked (operator 2026-08-11); pick up at
  unpark. Acceptance = drift-free re-plan through the two-zone token. ⚠ `dig +short` wraps long
  DS digests — `tr -d ' '` before grepping.
- **CI-wall trial (2026-08-18): `minRunners: 1`** on arc-runners — measure run-pickup deltas
  for a few days, revert to 0 if no win; the residual setup cost is homelab#518.
- **Small live residue (compressed 2026-08-19):** wk-metal-04
  `kubernetes_labels.longhorn_bulk_zone` field-manager CONFLICT kills FULL tofu applies
  (targeted fine) — chase before the next broad apply · proxy zen leg live-smoke still unrun
  (`opencode/nemotron-3-ultra-free` through the in-cluster proxy) · docs-cleanup residue legs:
  FU-001 archive-expiry ref scrub (overdue), the openrouter-proxy FU-021 comment repoint (rides
  the next functional proxy change), the five EXPIRY-HELD archive ids ruling · stack leftovers:
  circles#77 ci-red triage, oracle-fleet#259 rework per the seat read, circles-iac deploy-bump
  generator fix before the next circles build (circles-iac#71/#68).
- **Soaks** (each owned by an FU/issue — this line is only the calendar): platform-retro first unattended fire Mon 08-24 05:00Z (FU-058 acceptance) · argo second backlog
  sweep ~2026-08-25 (#521) · minRunners readout · iac-sentinel first real RED + FU-176 ·
  router shadow/elastic cells (FU-095, PR#408) · FU-148 acceptance · FU-149 datum ~08-20 ·
  or-op#34 first daily-429 · renovate-approve one-approval-per-head (#114) · stint
  quiet-window closes (rule 2026-08-20, chainless §The jail stint): #420 (waits on #710) +
  #711 — close at a sweep ≥72h after each tree's last event · **platform workers on PAID OR
  flash (PR#715, operator 2026-08-20 — fixup window): REVERT to claude/haiku primary
  ~2026-09-03 / fixup-wave end / OR depletion, whichever first** (claim comment carries the
  full record; Go re-flip stays FU-181).

- **⚑ S4 STINT #762 LAUNCHED + largely executed 2026-08-23 (session 1).** Done: #765 eviction,
  #766 rename (FU-163 archived), #767 check-3 flip, sprout #769 shipped, #770 closed as
  duplicate-of-#332. In flight at last write: **PR#768** (#763 ground rules — was BEHIND,
  updater-owned) + **PR#774** (#769) riding their review cycles; a fresh session finishes their
  gate reads if parked. **OPERATOR DECISION PARKED: PR#773** (#764 — CLAUDE.md facts vs
  `agents/jail-seat-card.md`, reworked to separate-files on the operator's mid-session
  direction; un-armed, awaiting their read; claude-jail#1 carries the bootstrap-composition
  spec). Stint closeout 1 fires when #768 lands + the operator rules on #773.
  S6 #716 + S3 #711 CLOSED this session (quiet windows passed; #716's Container-findings
  disposed via PR#761, deploy verified in-cluster). #420 stays open (#575 closed 08-23 09:50Z
  reset its window — next check ≥08-26). Remaining S6 acceptance watches: unbound-sprout belt
  quiet; responder `Cause:` organic use; Mon 08-24 retro fire. **S5 deliberately LAST.**

## Durable warnings — EVICTED (S4 #765, 2026-08-23)

The section's content moved to its proper homes; this pointer is all that remains:

- Probe & triage discipline (absence-is-fake, deploy-silences-`for:`, info-suppressed,
  counter-vs-throughput, green-surface, bypass actors, written-is-not-applied,
  one-spec-page, operator-lane PRs) → **`docs/runbook.md` §Meta-session probe & triage
  discipline**.
- Shell/tool gotchas (zsh word-split, `--body-file`, `gh --jq`, `gh pr view` merged, python3
  yaml) → **`agents/jail-subagent-card.md`** (applies to the seat too); pipe-filter-push →
  CLAUDE.md §lanes; apostrophe-in-jq → mechanized in `prompt-transport-lint`.
- goal/-prefix arming → `docs/agents/issue-authoring.md` §Base (was a duplicate);
  label caps + branch-rename-closes-PR → same doc; two-readers → **FU-178**; the
  agent-runtime-fixer-lane status note was stable news and is dropped (the
  reviewer.enabled platform trap survives in the runbook bullet).

## Re-arm on a fresh session

⚑ **Per-SESSION-TYPE since 2026-08-19 (operator direction, the watches-for-codeowner-sessions
sitting).** Both jail session types — the mechanical MAINTENANCE session and the CORPUS session
(design-agents corpus loaded: codeowner reads + FU build + subagent waves) — arm the SAME
standing set below; what differs is cadence and the act rule:

- **ONE STINT PER CORPUS SESSION (operator rule, 2026-08-20).** The corpus bootstrap
  (~470k-equiv cache write) costs only ~6–10 turns' worth of high-ctx re-reads, while every turn
  re-reads the WHOLE context at 0.1× — so at ctx ≥ ~500k a NEW stint always starts a FRESH
  session (break-even turns ≈ 470k / ((ctx−400k)×0.1): 500k→~47, 600k→~23, 800k→~12; a real
  stint is 150–300+ turns and stints EXPAND). Trailing work of a few dozen turns may stay warm.
  Measured basis: the 2026-08-19 night session — 459 turns, 275.8M cache-read = ~92% of spend.
- **Ctx wind-down (operator, 2026-08-19): end ~50k tokens BEFORE the context cap — never ride
  into compaction** (a compacted corpus session is no longer a corpus session; a fresh one
  bootstraps from this file + TICK-LOG by design, mid-stint included). Measure with
  `bash scripts/session-ctx.sh` at heartbeats once past ~½ window; at the threshold run the full
  wind-down ritual regardless of in-flight work.
- **Cadence**: the corpus session's heartbeat runs UNDER the ~1h Anthropic cache TTL —
  **2700s**, not 7200 — so the belt that catches a stall is also what keeps the big context
  cache-warm (a wake within TTL is a ~0.1× cache read; past it, a full re-read — the Part A″
  arithmetic, [observability-and-retro.md](observability-and-retro.md) §Part A″). Maintenance
  sessions keep 7200s (light context, cold wakes are cheap). An expected wait past the TTL with
  nothing in flight = WIND DOWN deliberately (write the pickup, kill monitors by process, exit).
- **Act rule**: a watch event outside the session's type is RECORDED for the other type (board /
  a meta-state row), never acted on — design-shaped events don't get improvised without the
  corpus (the /design ruling applied to watch events); agents-lane events don't derail a
  mechanical sweep.
- **Subagent waves**: the standing set is the level-triggered layer; ad-hoc per-PR watches are
  edge triggers on top and must cover EVERY terminal (new changes-requested, CI-red, breaker
  labels — not just merge). A subagent granted the PR flow owns its own cycle
  (`agents/jail-subagent-card.md`); the seat hears terminals only.

- **meta-events loop (REQUIRED, replaces the standalone needs-meta arm)**: `Monitor` (persistent)
  `bash agents/meta-events.sh` — the FU-166(b) consolidated 120s edge-detected loop (needs-meta
  absorbed as a source via `--once`, + goal-thread User comments, aggregated alert set, doorbell
  famine gauge). Cold state re-emits the standing set = the fresh-session bootstrap view. The
  SEATPR source is the anti-stall piece for seat PRs (PR#568 sat changes-requested overnight on
  2026-08-18 with only an ad-hoc watch armed — the standing set would have surfaced it in ≤120s).
- **needs-meta watch (legacy standalone — do NOT double-arm beside meta-events)**: `Monitor` (persistent) `bash agents/meta-needs-attention.sh`
  — unreviewed platform PRs, `agent/blocked` issues, unlabeled>24h, AND (clause 4, 2026-08-08)
  stack-repo codeowner parks (bot-approved+green+REVIEW_REQUIRED on oracle-fleet/circles — it
  caught circles PR#54 on its first pass; oracle PR#217 had sat 17h). ⚠ verify by process AFTER arming
  (`ps aux | grep NEEDS-META` for an inline variant, the script name for the script one — an
  absence is a claim about your grep, proven again 2026-08-08 05:00Z).
- Backstop heartbeat: `Monitor` (persistent) `while true; do sleep 7200; echo "META-HEARTBEAT:
  sweep due"; done` — **2700 on a corpus session** (the per-type cadence rule above) — every
  sweep runs `bash agents/meta-throughput.sh` FIRST (queue-vs-movement; a THROUGHPUT-STALL line
  is an incident, not calm — 2026-08-09 operator catch), then
  `bash agents/meta-alert-crosscheck.sh` + the board/chain check against this file, then
  `bash scripts/jail-transcripts-sync.sh` (the §A1 jail leg, PR#580 — best-effort, loud skip
  while unreconciled; also run it once at wind-down).
- Handoff watch is NOT standing (operator 2026-08-09: special case) — arm `bash
  agents/meta-handoff-watch.sh` only on rollout days / when a stack jail is known active;
  `/handoff` processes the inbox on demand.
- Loop watches (`agents/meta-watch-loop.sh` per stack) are OPTIONAL rollout-time tools now —
  expect ~10 routine events per real signal (operator 2026-08-08: "too many monitors").
- Probe hygiene: probes in SCRIPT FILES, dry-run under the real interpreter; watch the FAILURE
  signature explicitly; `PROBE-FAIL` over silent empty state. Monitors survive `/clear` and are
  invisible to TaskList — find leftovers by process and kill before re-arming.
