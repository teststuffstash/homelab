# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid.)


## Live state (pruned 2026-08-19 — history is TICK-LOG's; the forward plan is the ROADMAP work map)

- **⚑ #628 attention-layer program (operator ratified 2026-08-24, seat sitting):** leg 5 =
  homelab#892 QUEUED (fixer lane — the scan derived-class series + `board --machine` + the one
  standing belt; gate reads land it). Leg 6 = SEAT-LANE after leg 5 (board webservice page +
  goal_graph trees with links; carries the bucket/hostname provisioning). Leg 7 after 6
  (meta-events BOARD source, needs-meta arms retire). Design record: #628 body + #892;
  companion defect agent-runtime#87 (finalize weak-link check — the #833 8h hold's cause) QUEUED.

- **⚑ [Stint](chainless-redesign.md) S7 (#741) LAUNCHED 2026-08-23 (operator go + latch clean).** Session 1 built all
  three in-order children: #743 exporter edge MERGED (PR#757 — mergeStateStatus on the walk +
  maybe_dispatch_behind + UPDATE_PR_WEBHOOK_URL env); #742 script+replay-table (PR#755) and
  #744 manifests (PR#758, bring-up guard covers merge-order) mid-cycle at last write — finish
  their gate reads if parked. #746 QUEUED to the cluster loop (labels + doorbell rung). **#745
  cutover stays PARKED: un-park after a few days of the in-cluster leg observed servicing BOTH
  paths** — read `update-pr-edge-*` workflow logs for edge-serviced updates and the cron's
  CRON-SERVICED lines (silence there = the edge carries the load), and `gh run list` on the
  callers showing the hosted runs idle; then #745 deletes callers/reusable/org-secrets + FSM
  anchor repoint. ⚠ EVIDENCE READ CHANGED 2026-08-23 ~15:10Z: the private-repo hosted minutes
  ran OUT (3000/3000, overage OFF per #698) — every hosted caller run on the 4 private repos
  fails at job start until Sep-1, so the in-cluster leg is their SOLE server now; the un-park
  read becomes "no BEHIND stalls on private repos over a few days" (hosted-idle is no longer
  evidence, it is forced). Silence `a3628730` (GithubWorkflowRunFailed × update-pr-branch, ends
  Sep-1) mutes the failure noise — sibling of `5400ed94…` (both self-expire 2026-09-01). Label-identity decision recorded in-code: merge App stays issues-less,
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
  persistence landed (#618→#621) AFTER the first fire — **VERIFIED 2026-08-23 ~13:47Z: the
  PR#784 proxy roll came and `router_go_capacity_latched` stayed 1 on the fresh pod, no new
  429 burned** (the GoCapacityLatched ALERT's `for:` clock resets on a roll — cosmetic
  firing→pending flap, the deploy-silences-`for:` class; gauge is the truth). #420 + #540 CLOSED (operator, 2026-08-19) — the post-reset readout
  (parity on a clean window, the 5h refusal shape, latch-survives-roll) is **FU-181**, actionable
  after Sep-13.
- **⚑ PRIORITY ORDER (operator ruling, 2026-08-18): OPEN ISSUES FIRST → then follow-ups/corpus
  buildout → then stacks.** The forward plan lives in **ROADMAP §The platform work map**
  (stints S1–S5 → Goals G-A–G-D; supersedes the old Bucket A/B worklog that sat here).
- **⚑ G-B LAUNCHED OVERNIGHT-AUTONOMOUS 2026-08-23 ~20:48Z — the v1.2 cluster-decompose proof.
  MORNING READ (after the retro post-fire read): homelab#818.** Goal #818 (assurance; Budget 25,
  `Base: goal/818-assurance` — branch cut+protected, ci triggers on goal/** since the same-day
  trigger fix), decomposing IN-CLUSTER on **fable** via the routed `goal-decompose` class
  (chain_head PR#813; smoke FABLE-OK; decompose pod Running clean at wind-down). What the
  morning verifies: children authored+queued with inherited Base + corpus grounding named ·
  rides into the protected goal branch · FU-143 C6 closing goal-merges · findings store +
  checkpoints · assembly PR parked codeowner-gated. **Launch-night defect trail (all fixed or
  filed):** queued Goals were ADR-097-held as exclusive (#818 carries the replay-exempt no-op
  `Touches:` as the ruled workaround; structural fix = #822, queued, + 3 findings on its
  thread: unit-fast-path is reviewer-shaped only · priority starvation by the self-regenerating
  changes-requested stream · the PR#801 adoption passed the FULL routed id to `claude --model`
  — decompose DOA, fixed PR#824, its replay pin rides #822's wave). ⚠ needs-meta source
  flapped twice (empty-read → clear+re-emit burst ~19:09/20:21) — a hold-on-failed-read gap in
  `agents/meta-events.sh`'s NEEDSMETA arm, next session's 5-min fix. #818's body-vs-Touches
  lint flag (#821's new belt) is the workaround's expected noise. Loki incident closed
  (quota 16Gi, recovered+verified); retention decision parked on #811 for TOMORROW.
- **⚑ G-A DAY-1 CLOSE (launched + 5 children DONE in one session, 2026-08-23; retro post-fire
  read Mon 08-24 05:00Z stays the next session's FIRST item).** Goal = **homelab#775**
  (`Budget: 17` = the loaded OR credit; #278 shape: master-lane children, jail-decomposed,
  never queued; bucket #787 auto-created). DONE: #776 (carrier, PR#784), agent-runtime#81
  (PR#82 + #785 pin), #777 (accounting, PR#786), #782 (wiring, PR#788 — a REAL FU-088
  dual-rail regression caught+fixed in review), #778's pilot half, **#779 capacity doorbell
  (PR#789 gate-read + merged 2026-08-23 16:26Z; proxy rolled, Go latch held 1 through the roll —
  organic doorbell wake on a real latch clear stays a soak watch)**, PR#794 (#778 salvage,
  merged). IN CYCLE: PR#793 (ADR-107-addendum docs — round-3 restructure pushed 2026-08-23
  ~16:29Z: the reviewer caught the addendum reversing decision 3 against adr.md rule 2, so it is
  now **ADR-112** + Superseded-by marker on ADR-107 (3); awaiting re-review, self-merges on bot
  approval) · #516/PR#797 + #792/PR#800 in machine fix rounds (changes-requested at head —
  cluster loop owns; gate reads land when they park). QUEUED: #780, #781 (wiring), #791 (proxy
  OR-translation); #778 residue re-rides the normal lane. **HARNESS MATRIX ruling (operator,
  in-session): claude+opencode full-support, scout probes 3 harnesses/candidate with a ~1h/2h
  retry ladder — recorded as ADR-112 (PR#793 round 3), not an ADR-107 addendum.** **Fan-out pilot RAN +
  CLOSED (operator): findings ledger = the #778 thread** (recipe path dispatcher-side ·
  rounds-as-arms · ephemeral-tier toleration needed · FU-042 wedge on pending arms · opencode
  bare `-m` = the dead-canary root cause (A/B-proven) · nemotron fabricates delivery (salvaged
  PR#794) · citation-forced briefs for cheap reviewers · time-delta = fan-out viable).
  OPERATOR-PENDING: the #783 strike ruling (memo posted: proposal = retire the env) · the A5
  second-reviewer-App question (evidence route = shadow re-reviews, `--rail` flag on
  re-review.sh unbuilt). Harvest strays #795/#796 await the goal checkpoint. laguna r4 pod was
  left running to natural terminal (~$0, 4h key). **OR-budget ruling stands (paid-flash
  through G-A, revert ~09-03/fixup-end/depletion); Go latched til Sep-13 (roll-persistence
  VERIFIED).** claude-jail#2 filed: mono per-session env block + wallet-reach + forgejo SSH.
- **⚑ GARAGE TIER-3 (widened carve) RUNNING since 2026-08-25 ~06:24Z (homelab#884, operator: widen
  to loki/allure/oracle-`parsed/`/sleep).** Tier-2 (the transcripts delta) is DONE and verified —
  detail in TICK-LOG 2026-08-24 evening + incident §Tier-2. Tier-3 carved the WHOLE store from the
  same frozen layer: **956,600 objects, 0 orphan versions**, and the **bucket_alias table survived**
  (14 names → old ids, `wide/aliases.json`) so nothing had to be identified by key shape. Live-key
  filtered → **544,548 objects / 17.1 GB**. First 182,000 landed, then **the restore filled the
  meta volume and took Garage down** (503 on every write, ~08:24–09:27Z — see the incident doc
  §Tier-3). Resumed 09:29Z **sorted by (bucket, key)** and running in pod `garage-forensics`
  (detached, survives this session): `/tmp/work2.jsonl` → `/tmp/report3.jsonl`, log
  `/tmp/restore3.log`, ~23 obj/s, **362,823 remaining, ETA ~14:00Z**. Then the **3 giant ERT
  objects (6+6+42 GB, multipart, 2 071 parts)** via the part-replay path →
  `/tmp/giants.report.jsonl`. **`/tmp/chain.sh` (verified running) starts the giants when the bulk
  exits** — SEQUENTIAL by measurement: Garage's commit path is serialized, so run together they
  trade throughput (bulk 37→13 obj/s), not add it.
  ⚠ **Insert ORDER is the whole story on space**: page order cost 3.52 GiB of LMDB for 182k objects
  (~20.3 KB/obj, ~8× the pre-wipe store); sorted cost **no measurable growth** over 19,750. Now the
  default (PR#905). A `Monitor` guard kills the run if meta free < 3Gi.
  **PICKUP if this session is gone:** wait for both reports (`/tmp/chain.log` marks each stage),
  then `verify-restored.py` from the jail over `https://s3.teststuff.net` with the temp key
  `forensics-wide`, then **delete the key (`/garage key delete forensics-wide`) and the pod**;
  earlier reports `/tmp/report2.jsonl` + `/tmp/report3.jsonl` both count toward the tally.
  Manifest: `backups/garage-meta-forensics/wide/`. Tooling PRs: #900/#901/#902/#904 merged, #905 in
  flight.
  **Live changes made during the outage (all verified, cluster state otherwise restored):**
  `meta-garage-0` **10Gi→30Gi**, `numberOfReplicas` **2→1 on wk-02**, `dataLocality`
  best-effort→**disabled** (unsatisfiable — garage-0 runs on wk-01, which has no Longhorn disk, and
  it was blocking every rebuild). The `std` tier could not host a grown 2-replica volume at all:
  hp-01 sits at 22.5 GB free vs Longhorn's 31.4 GB floor, so it rejected ANY expansion. The rf=1
  debt is on **FU-137**; the broken auto-snapshot control is **FU-184**. ⚠ the replica shuffling
  pushed the **pve pool 69→84%**; `fstrim` via `kubectl debug node/wk-02 … -- fstrim -v /host/var`
  returned it to 69.17% — the batch form silently did only part of the job, run it per node and
  READ the byte count.
  **STILL OPERATOR-OWNED: the `garage repair blocks` hold** — but it now reclaims ≈nothing, because
  re-adopting the ERT giants re-refs ~47 GB of the 54 GB on the data volume. **DO NOT delete those
  3 keys to reclaim it (operator ruling, 2026-08-25):** the 2026-07-12 corpus is the stale base the
  first delta job must run against, and a re-ingest fetches TODAY's register — it moves the window
  instead of restoring it. Rationale + the ghcr-image-is-not-a-substitute finding now live in
  `docs/garage.md` §Durability (PR#902); ert-snapshots is no longer tiered cheap-to-lose, which
  makes FU-137's ~08-31 deadline load-bearing. Verified against the carve: every delta-base input
  (`latest.json`, the `build/`+`publish/` manifests, 252,354 `parsed/`) is in ert-snapshots and the
  deployed workflow pins `S3_ARTIFACT_BUCKET=ert-snapshots`, so base resolution never leaves the
  bucket; nothing in the job reads S3 `LastModified`, so the restore's new mtimes cost no realism.
  Evidence stays frozen (`backups/garage-meta-forensics/` + the
  `pre-restore-2026-08-24-meta-wipe` Longhorn snapshot). ⚠ watch `lvs pve/data` during the run
  (68.2% at start).
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

- **⚑ S4 STINT #762: TREE EMPTY 2026-08-23 ~11:52Z, closeout 1 RUN — close ARMED, executes at
  a sweep ≥2026-08-26** (same calendar as #420's recheck). All 5 originals + 2 sprouts closed
  in ONE session (vs `Size: 2 sessions`); FU-117 + FU-163 archived. The jail composition is
  LIVE both classes (claude-jail#1; operator ran `docker compose build` — sessions in
  containers started PRE-merge still predate the composed seat card until restarted, this one
  included). Fleet CLAUDE.md slim-down: inventoried + tiered on claude-jail#1, executable on
  the operator's word (tier 1+2 pointer drops now unblocked; oracle-fleet's tier-3 moves ride
  the stack env card, already live).
  S6 #716 + S3 #711 CLOSED this session (quiet windows; #716's Container-findings disposed via
  PR#761, deploy verified in-cluster). #420 open (#575 closed 08-23 09:50Z reset its window —
  ≥08-26). Remaining S6 acceptance watches: unbound-sprout belt quiet; responder `Cause:`
  organic use; Mon 08-24 05:00Z retro fire (next session's first read). **S5 deliberately
  LAST; next stint queue: S7's #745 cutover un-park read (edge-serviced evidence).**

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
