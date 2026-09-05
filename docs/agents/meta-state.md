# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid — and every design-agents corpus load pays it too: at 75 KB this file cost
~20k tokens per corpus session before the 2026-09-05 prune. A wind-down writes the PICKUP,
never the session's arc — that is TICK-LOG's.)


## Live state (pruned 2026-09-05, the corpus-cost sitting — every item live-verified against the board that day; history is TICK-LOG's; the forward plan is the ROADMAP work map)

- **⚑ NEXT SESSION (seat, 2026-09-05 ~08:10Z, mid-stint pickup — this corpus session may still
  be running; check `gh pr list` before acting): (1) ADR-110 codeowner reads on the seat-subagent
  PRs that park: #1399 (#1200 vendored CNP schema), #1401 (#1207 filing-door classify), #1402
  (#1308 BuildKit mirrors, both legs), the #1249 walk-retirement PR (number TBD), and #1386
  (its two codeowner-read defects fixed in-PR at 75b5ba26; re-review pending after a false
  `agent/error` was cleared — homelab#1403). (2) **After #1386 merges:** close or narrow #1069
  (its homelab half is the prefetch's required-read deferral; the finalize half is
  agent-runtime's). (3) **After #1249 merges:** drop `agent/error` from #1334 (the #1249 damper
  lifts) and re-read #1237/#1238 (they stay unqueued by intent). (4) **Apply #1308 leg 1 on
  ci-runner-01** (buildkitd.toml + the `homelab-mirrors` builder) — via the pending ci-runner
  `tofu apply` replace, or the interim SSH hand-apply of the same two artifacts; the PR body
  carries the recommendation. (5) #1393 heat trims if room remains.**
- **⚑ BOARD (09-05 ~08:10Z):** in review #1386 (re-review after the seat's fix push) ·
  riding #1378 #1392 (r1, deepseek — dispatched before the haiku flip); #1384 #518 completed r1
  → PRs in review · queued this morning by the seat: **or-op#60** (item-2 root; coordinator pod
  up 08:0xZ), **agent-runtime#119 #120** (finalize sprouts), **homelab#1297** (mirror poison
  belt), **#1403** (reviewer false-anomaly, 2 sightings) · #1300 re-scoped (Touches narrowed off
  the guarded glob, VIP 40.34, 20Gi) and stays queued · de-queued + seat-landed: #1299 (direct,
  9a0354ec), #1207 (PR#1401), #1308 (PR#1402), #1390 (direct, 1907048f), #1200 (PR#1399).
  **Platform claim = `claude/haiku`, no fallback, LIVE 07:54Z (PR#1395; operator: credits to
  burn today)** — the #715 revert clause executed. Park-watcher recipe = poll
  `github_pull_request_codeowner_park` on Prometheus (zero gh calls). Inert with owners: #1069
  (→ item 2 above) · #518 (runner infra) · #628 (container) · #857 (maintenance-session class).
- **⚑ OPERATOR-ONLY — from the four `coordinate-<stack>-1788589800` logs (2026-09-05 06:30Z,
  read out of Loki; every item live-verified the same hour). The machine will never act on
  these; the next session picks them up in this order:**
  1–4. **DONE 2026-09-05 (this sitting):** the five undeliverable queue items re-scoped or
     seat-landed (BOARD above); or-op#60 queued (the #57/#58 ghost-hold root — oracle-fleet#361's
     hold is oracle-iac#485, dispositioned DELIVERED, closes on the oracle jail's side); the
     FU-090 gate adopted #119/#120/#1297, commented #1069 (resolves with #1386), left #857 /
     agent-runtime none / or-op#34 (needs a real 429) as they were; #1249 rides as a seat PR.
     Still theirs: stack sprouts (oracle-fleet 11 + UNBLOCKED #416/#176/#84, sleep 2, circles 5)
     — relay, don't triage.
  5. **Phantom `agent/done` HELD (closed with no merged PR — confirm the close or relabel):**
     homelab **#913 #903**; oracle-fleet #25 #24 #22 #7; sleep #7.
  6. **PRs where a human is the next mover:** sleep-iac **PR#80** (merge conflict,
     seat-authored — the seat's own push); oracle-fleet **#425/#426** un-armed research PRs
     (the operator's `specs/` read, by design); circles **PR#25** un-armed (specs contract —
     arm or park); sleep-tracking **PR#143** ci-red held because #141 is `agent/blocked`.
  7. **Hygiene:** stale agent branches, delete or resume — homelab 11
     (`agent/20260824-104524 …-132129 20260825-171429 20260830-233803 20260901-165514`,
     `fix/cost-rethink fix/issue-126-… fix/issue-500-… fix/issue-721-…
     fix/reviewer-app-statuses-… fix/window-shares`), agent-runtime 1, oracle-fleet 4,
     circles 4, sleep 1 · oracle-fleet#84 carries a RETIRED `Depends-on:` line → native edge.
  8. **Backlog queue calls (suitable-unqueued, `devbox run board -- <stack> --full`):**
     homelab **read 09-05 (operator: "queue the infra now")** — 14 = 3 goal containers
     (#1302 #1231 #1162, not units) + **4 QUEUED from the seat: #1384 #1378 #518 (image half
     only) #1392 (+Touches authored)** + #1316 CLOSED (self-resolved 09-02, residual is
     oracle-fleet's allure-publish timeout) + 6 that stay: #1200 (scripts/** = operator-lane,
     hand-do) · #1370 (needs a cluster diagnosis first — FU-171) · #1280 + #829 (design-shaped,
     corpus sitting) · #1237 #1238 (operator/seat-run spikes) · oracle-fleet 20 (oldest #212,
     08-08) · circles 3 · sleep 1 · or-op 1 (#60 — item 2's root).
  9. **Loop health, unexamined:** three `coordinate-perstack-*` runs FAILED 09-04 (platform
     12:45Z exit 128, platform 12:58Z + oracle 20:59Z exit 141); every cron tick since is
     green — read the Loki lines before calling it transient.
- **⚑ OPERATOR-OWED (one list):** (#1200 → PR#1399, #1249 → seat PR, both 09-05; residual
  from #1200: no ArgoCD sync-failed/OutOfSync alert exists — a belt to add) · **#1308 leg-1
  APPLY on ci-runner-01** (NEXT SESSION item 4) · #1370
  (FU-171 resight) · or-op#34 (needs a real 429) · seat sittings #946 (A5 seed) / #1224
  (parts-coverage) / #1237 (E1) / #1238 (E2) · #1308 (BuildKit mirrors queue call) · FU-205
  design pass (WAN accounting) · #1280 held-for-evidence (kind-timing distribution first) ·
  Cloudflare: mint `Cache Purge` onto tofu-apply, or rely on oracle-fleet#414's
  Cache-Control (decision open) · `REGISTRY_PUSH_TOKEN` repo Actions secret on oracle-fleet
  (console step, value in Infisical; until set, release-corpus dual-push loud-skips) ·
  `tofu plan` (main root) shows ci-runner-01 "must be replaced" (cloud-init snippet drift) —
  re-adopt the live snippet or accept the replace at a quiet moment; apply TARGETED until
  then · Garage: delete `backups/garage-meta-20260825-prerebuild/` (20 GB) +
  `garage-meta-forensics/` (due since ~09-01); meta volume rides rf=1 on wk-02 (FU-137's
  ~08-31 deadline PAST — an infra sitting); the 3 ERT giants STAY (docs/garage.md
  §Durability).
- **⚑ GOALS — verdicts are the operator's, the seat recommends:**
  - **#818 G-B — HELD with a posted 4-clause verdict condition** (teeth drills deferred to
    oracle's production launch; lens posture advisory-steady-state; responder shadow; prober
    = oracle-fleet#344 class-1 pilot, open). The bar is exercised-in-a-stack (GAPS G5), not
    shipped.
  - **#1162 wave 1 — `goal/validated` when the egress soak reads clean** (#1247 closed; drops
    0/4h at 09-02 06:30Z); its close sweep disposes store entries 28–30 + bucket #1170/#1200
    and mints wave 2 (#1211 #1212 FU-199 residue #1198 #1199; #1224/#1225 operator-lane),
    AFTER #1231.
  - **#1231 router-first — machine set G1–G5 all landed 09-02**; remaining = E1 #1237 + E2
    #1238 (operator/seat sittings) → tree-empty → operator's validated read. STRIKE_ENFORCE
    stays OFF (recording precedes policy); hold G4↔G2 coherent at review.
  - **#1302 G-G — post-launch; verdict #1334: checks 1+2 OBSERVED** (api-profile 429 on
    Free; apex `cf-cache-status: HIT`), **check 3 = the RUM residual** — no Web Analytics
    WRITE permission group exists for a user token, so the consumer profile's RUM half is
    undeliverable through `homelab-ingress-write` (design residual for #1311: dashboard RUM /
    account-owned token / drop RUM from the profile; the Workspace stays Synced=False on it).
    #1334 wears `agent/error` until the #1249 damper lifts. Edge legs still platform-side:
    **FU-206** (ops paths blocked at the edge — one more rule in the custom-phase ruleset,
    both profiles, dry-run through the proxy first), cloudflare.md completion rows S4/S5
    (Free managed WAF / ddos_l7 outside the Skip — verify), the `CTR-ACCESSLOG` contract row
    (proposed). oracle-iac#485 (mcp api claim) is the oracle jail's. Operator read, not owned
    here: public `/metrics` on the api hostname (fleet).
  - G-A #775 + G-F #1039 VALIDATED and closed — nothing left here.
- **⚑ CONTAINERS TO CLOSE:** **#979 S5** [stint](chainless-redesign.md) — quiet window passed 09-02, but a FIFTH original
  (**#1393**, the post-S5 heat-cited trims, filed 2026-09-05 from this sitting's measurement) re-opens
  the tree; close ≥72h after it lands · **#741 S7 closeout-1 OVERDUE since ~08-29** (5/5
  originals done, cutover 08-26, no closeout comment ever posted) — needs the closeout
  sitting (docs-cleanup over merge-path.md/FSM + `agents/update-pr-branch.sh`, FU sweep,
  built-vs-left comment), then its window · **#949 + #1101** retro batches close at the
  post-r3 sweep (r3 fires Mon 09-07 unattended under the PR#1127 cost-model ranking;
  predecessor-scoring is the closeout read).
- **⚑ ORACLE (the platform's half only):** Goal #418 — #432/#433/#428/#429 done; research
  PRs #425/#426 wait on the operator's `specs/` read (by design); #416 regeneration is
  operator-attended (blockers closed). #414 inert (operator queues). **homelab#1381 in
  review** (the arbitrate door files goal children inert with no reader; fix = carry
  `harvest=store` like merged-closeout). Bucket #386 / Goal #176 are the oracle jail's; ⚠
  #176 carries a stale blockedBy on stint #269 (holds nothing; misleads) — un-wire when
  touched. **Handoff inbox (oracle) holds two older tasks**:
  `20260903-1245-ci-red-data-point-391…` (data point + suggestions, "not an ask" — read for
  a new class, answer) and `20260903-1815-in-pod-kind-unrunnable-issue-399-r1` (kind node
  segfault in a kata pod + mirror pull path; needs the ride's transcripts) — next
  `/handoff`. or-op#57/#58 queued (harvested, inert — ordinary board flow).
- **⚑ INFRA / INCIDENT PICKUPS:**
  - **FU-072 soak = two legs**: Service-VIP leg PROVEN (oracle PR#434, zero drops); the
    **dind/kind leg is UNEXERCISED** — needs the first in-pod `devbox run e2e` (a
    `task/build` ride), which also carries the #399-r1 kind segfault above. Regression
    signature: `AgentWorkerEgressDropped` with a bare pod IP; revert `773ad63e`.
  - **pve thin pool 82.2 % — `PveThinPoolFillingUp` FIRING since 09-05 morning** (read 07:40Z);
    `LonghornDiskBelowSchedulingFloor` firing on wk-02 `default-disk` (56 GB free) too — the
    Garage forensic-backup deletion owed above is the lever — the answer is fstrim (twice daily since 09-04) + FU-093's next
    act (Longhorn filesystem-trim), not a threshold bump. Read `pve_lvm_thin_pool_data_percent`
    before/after a 03:17Z fstrim to size the cadence.
  - **Git-throttle watch**: every loop clone is preemptively authenticated since PR#1333; a
    recurrence with zero anonymous requests = FU-007 push-mirror becomes the next
    deliverable (incident record §Recurrence; memory `git-preemptive-auth`).
  - **Sentinel latency fix (`cfb98bbb`)**: verify the next runs' bootstrap ≈ 0
    `copying path` lines and the iac-sentinel status floor ≈ scan+queue.
  - **FU-168 soak FAILED 08-25** (cron-woken dispatches persist; #459 closed) — the emitter
    hunt is the next concrete action, tracked on FU-168.
  - Small residue: wk-metal-04 `longhorn_bulk_zone` field-manager conflict on FULL tofu
    applies (unreproducible read-only; verdict = the next full apply) · hp-01
    `install_disk: /dev/sda` is a NAME with two identical disks (repin to WWID, FU-076's
    neighbourhood) · OTLP trace-export spam (`localhost:4318 refused`) in registry + 3
    mirrors — add an `OTEL_SDK_DISABLED`-class env · garage resync worker tuning is
    EPHEMERAL (resets on garage-0 restart) · FU-073/084/089/098 stale-archive entries, 41d old (next
    docs-cleanup).
- **⚑ WATCH-NOISE candidates (next meta-events touch):** FAMINE emits per count-delta not
  threshold-crossing; "unlabeled >24h" false-flags containers (wants the
  sprout-report-skips-buckets exclusion); gh `--jq` takes NO `--arg`; reviewDecision never
  changes across CR→CR re-verdicts (key on newest-verdict timestamp); reviewer STEP-0 false
  anomaly on update-branch re-pointed review commit_ids — **FILED homelab#1403 (queued) at the
  2nd sighting (PR#1289, PR#1386)**; NEW sighting 09-05: the in-cluster updater merged master
  into bot-approved + REVIEW_REQUIRED PR#1386 FOUR times in 31 min (07:06–07:37Z) — the #887
  park-skip clause did not hold it; read `agents/update-pr-branch.sh`'s predicate before filing.
  Also: GitHub RE-POINTS a review's commit_id on update-branch (approvals survive updater
  merges — the 2026-09-05 merges of #1388/#1389 confirm; the merge-path.md dismiss-on-push
  worry applies to CONTENT pushes only).
- **⚑ DESIGN INPUTS WITH NO OTHER HOME (operator: deliberately not FUs — pick up in a
  design-agents sitting):**
  - **Drainage economics RULING (2026-08-31, operator-confirmed; TICK-LOG has the arc)** —
    the drainage round/branch/triage design is BANKED (measured 1 stack-blocking : 16
    nice-to-have on the live pile; the seat gate-reads every diff anyway, ADR-110 is the
    binding resource). Standing policy: (1) blocking defects (incoming blockedBy from a stuck
    stack issue / live wedge / 🚨) queue immediately, master-lane, hotfix-class, and every
    filing door wires the edge; (2) the nice-to-have pile is corpus-session batch work —
    no new machinery; (3) the Touches classifier survives as a LINT (#1102, done). The jail
    watches blocking-class parks actively (meta-events BLOCKPARK). Banked, operator's own
    "not yet": an AUTOMATED design-agents corpus read on codeowner-parked BLOCKING issues —
    revisit if parked-PR volume freezes dispatch. Post-launch goal fixes target MASTER (v1.2
    stands). **This ruling has no record beyond this bullet + issue-authoring.md's one
    clause-1 reference — it is ADR-shaped (decision + rejected alternatives).**
  - **Stack→platform routing (2026-08-30) — instances 3+4 undischarged by ADR-119:** (3)
    stack ACCESS/SERVICE gaps have no tracked inventory — no role×stack×service matrix
    exists (grep negative FU/ADR/GAPS); the oracle jail had no read on its own transcripts
    (no coordinator anywhere holds transcript read; the brief's "reads freely … transcripts"
    has no built mechanism — A2 MCP slices unbuilt, FU-058 leg); Loki (ADR-118) is the ONE
    stack-scoped read and the donor shape; TOOL_GAP markers exist only for cluster sessions,
    the jail lane has no channel. Direction to weigh: generate any matrix from grant sources
    (never hand-author — FU-049's pattern), consumer-card + grants file per LIVE service,
    TOOL_GAP extended to jail sessions, the capability-request lane as the routing. (4) a
    fix landed on a `goal/**` branch protects NOTHING on master until assembly (oracle
    PR#280 → master PR#293 hit the same class next day); long-lived RUNNER state is
    untracked platform surface (ci-runner-01 dockerd insecure-registries, stale devbox
    venvs — the y/n prompt class).
  - **v1.3.1 BANKED** (PR#1220, "deserves a place when it works"): `Origin:` line + typed
    defer/release + checkpoint theme-FORMATION are S8 originals — do not build piecemeal
    ahead of S8; delta 1 (park economics) landed independently (PR#1375/#1376/#1352).
  - **The dispatch-declared `requires:` FU is sanctioned to file** (operator's conditional
    after the harness matrix closed on all three arms, 09-02) — not yet filed.
- **Soaks** (each owned by an FU/issue — this line is only the calendar): retro r3 Mon 09-07
  · FU-148 first organic environmental-red retry · or-op#34 first daily-429 ·
  renovate-approve one-approval-per-head (#114) · CiDispatchStalled quiet-month window opens
  ~09-11 (FU-150) · FU-192 per-tenant ingest sizing (due ~09-03, PAST) · **paid-flash REVERT EXECUTED 2026-09-05 07:54Z** (PR#1395 — none of #715's three
  triggers had fired; operator-ordered; the FU-095 flip child, if wanted, mints from here;
  Go re-flip = FU-181) · opencode.ai
  rails PARKED behind `OPENCODE_RAIL_DISABLED` since 09-04 (FU-213; the vendor's 09-06
  header deadline; the jail shim stays live as the test bench).

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
  (measured 300–350k cache-creation tokens per load, 2026-09-03/04 — `session-ctx.sh --big`)
  costs only ~6–10 turns' worth of high-ctx re-reads, while every turn re-reads the WHOLE
  context at 0.1× — so at ctx ≥ ~500k a NEW stint always starts a FRESH session (break-even
  turns ≈ 470k / ((ctx−400k)×0.1): 500k→~47, 600k→~23, 800k→~12; a real stint is 150–300+
  turns and stints EXPAND). Trailing work of a few dozen turns may stay warm. Measured basis:
  the 2026-08-19 night session — 459 turns, 275.8M cache-read = ~92% of spend.
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
  nothing in flight = WIND DOWN deliberately (write the pickup, **push the batched direct
  commits — ONE master push through the githooks/pre-push lint gate, the 2026-08-30 batch
  rule (seat card §How changes land)** — kill monitors by process, run jail-transcripts-sync,
  exit).
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
- **oracle-specs quota** (either jail; oracle-iac#446 merged): verify `garage bucket info
  oracle-specs` shows 5Gi, then any fleet CI re-publish re-materializes the specs sites;
  close-purge of dead pr-*/ prefixes tracked oracle-fleet#318.
