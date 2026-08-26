# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid.)


## Live state (pruned 2026-08-25 evening, the sweep-pipeline session — history is TICK-LOG's; the forward plan is the ROADMAP work map)

- **⚑ NEXT SESSION = the S5 [stint](chainless-redesign.md) (operator, 2026-08-25): corpus diet — doc-heat + measured
  trimming (FU-164 is the instrument), post-closure by design.** The 2026-08-25 docs-cleanup
  deliberately left for it: the **29 remaining STALE-ARCHIVE ids** (the lint list) — most of
  their living refs are PROVENANCE names in code comments/docs (FU-088 ×51, FU-069 ×26,
  FU-057 ×20 …), the same class as the exempt TICK-LOG/ADR refs, so the scrub needs the
  **name-anchor ruling** (operator: exempt provenance refs / keep permanent one-line stubs /
  scrub-and-rename) before any mass edit; plus the deep whole-repo comb.

- **⚑ G-B #818 WEDGED on homelab#933 (found + filed by the 2026-08-25 sweep, queued):** all 5
  originals closed, 1 store finding, but the goal-checkpoint's child-set-complete trigger
  counts the OPEN post-launch bucket (#840) as an open child — assembly can never fire for a
  goal that harvested pre-assembly. The fixed clause emits the checkpoint on its first scan;
  then the morning-read items stand (assembly PR → codeowner tax → `probe-platform` first
  tick — the platform prober enablement rides the assembly, FU-102).

- **⚑ G-A #775 post-launch, 2 open descendants:** #778 (operator — Go posture RULED 2026-08-25:
  janitorial/failover permanently, P4 de-gated from Sep-13, big-pickle shadow arm = #923
  queued; FU-181 holds the post-reset hygiene legs) + #787 (container). **The FU-095 flip
  child is minted at the ~2026-09-03 paid-flash revert** (sequencing ruled A, 2026-08-25 —
  acceptance: zero chain-exhausted defers on subscription-only classes).

- **⚑ S7 (#741): the #745 cutover is COMPLETE 2026-08-26** — callers ×10 + reusable deleted,
  MP-T02 re-anchored (executed `fixtures/updater` replay), org secrets DESTROYED by the
  operator's host apply (after the bypass-actor var restore, `c3f3f5c9`). Acceptance watch:
  hosted updater runs structurally 0; no BEHIND PR >30m anywhere. Silences `a3628730` +
  `5400ed94…` self-expire 2026-09-01. (S4 #762 + #420 stint closes executed 2026-08-26.)

- **⚑ Retro (FU-058): r1 DELIVERED 2026-08-25** (PR#918; the batch = #927–#929 queued, #930
  SEAT lane: the DELIM-FIELD transport-lint signature — `scripts/` deny path; #931 OPERATOR
  lane: the `.agents/` pair). #932 queued (the silent success-push belt). **Next unattended
  Mon 08-31 05:00Z fire = the clean acceptance.**

- **⚑ GARAGE, operator-owned residue (recovery COMPLETE + env rebuilt, #884/FU-184 archived):**
  the `garage repair blocks` hold can come off (reclaims ≈nothing now) · **do NOT delete the 3
  ERT giants** (the 2026-07-12 corpus is the first delta job's stale base — rationale in
  docs/garage.md §Durability) · delete `backups/garage-meta-20260825-prerebuild/` (20 GB) +
  `backups/garage-meta-forensics/` evidence after ~2026-09-01 · **meta volume rides rf=1 on
  wk-02** — redundancy returns with the ADR-114 build-out, FU-137's ~08-31 deadline is
  load-bearing.

- **⚑ FU-168 soak read FAILED 2026-08-25:** cron-woken dispatches persist
  (`changes(agent_dispatch_cron_woken_timestamp[24h])` = 2 and 5) — #459 fires legitimately,
  a dead doorbell edge remains. The emitter hunt (the scan states wake source per dispatch)
  is the next concrete action, tracked on #459 + FU-168.

- **CI-wall trial (2026-08-18): `minRunners: 1`** on arc-runners — readout pending; revert to
  0 if no win; residual setup cost = homelab#518 (its promtool child #936 queued 2026-08-25:
  loop-health fixture = 107.6s of the 130s lint step).
- **Small live residue:** wk-metal-04 `kubernetes_labels.longhorn_bulk_zone` field-manager
  CONFLICT kills FULL tofu applies (targeted fine) — chase before the next broad apply ·
  proxy zen leg live-smoke still unrun (`opencode/nemotron-3-ultra-free` through the
  in-cluster proxy) · the openrouter-proxy FU-021 comment repoint rides the next functional
  proxy change · hp-01 `install_disk: /dev/sda` is still a NAME with two identical disks
  (repin to WWID, FU-076's neighbourhood) · stack leftovers: circles#77 ci-red triage,
  oracle-fleet#259 rework per the seat read, circles-iac deploy-bump generator fix before
  the next circles build (circles-iac#71/#68).
- **Soaks** (each owned by an FU/issue — this line is only the calendar): retro Mon 08-31
  unattended fire (FU-058 clean acceptance) · argo second backlog sweep (#521, ~due) ·
  minRunners readout · FU-148 first organic environmental-red retry · or-op#34 first
  daily-429 · renovate-approve one-approval-per-head (#114) ·
  CiDispatchStalled quiet-month window opens ~09-11 (FU-150) · **paid-flash REVERT
  ~2026-09-03 / fixup-end / OR depletion, whichever first** (PR#715; the claim comment
  carries the record; the FU-095 flip child mints at the revert; Go re-flip = FU-181).

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
