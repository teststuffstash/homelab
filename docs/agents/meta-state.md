# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid — and every design-agents corpus load pays it too: at 75 KB this file cost
~20k tokens per corpus session before the 2026-09-05 prune. A wind-down writes the PICKUP,
never the session's arc — that is TICK-LOG's.)


## Live state (pruned 2026-09-24 by the fu-sweep — every bullet re-verified against GitHub/the cluster that day; history is TICK-LOG's; the forward plan is the ROADMAP work map)

- **⚑ PICKUP (2026-09-25 — STINT S9 homelab#1985 OPEN, Renovate through the lanes).** Subagents were dispatched
  on #1990 (workflow-pin lint third shape, PR parks on the codeowner) and #1987 (agent-runtime finalize +
  `agents/major-handoff.sh`, two PRs); read their terminals first (`gh pr list --search "Implements #1990"`
  etc.), seat-read + merge. **Seat-owed operator-direct hunks** (never a worker's): #1990's CODEOWNERS
  unown of `/.github/workflows/` + `pin-only.reusable.yml` + the ci.yaml step (land AFTER the lint merges,
  agent-coordinator → openrouter-operator → agent-runtime → homelab, drill first: merge a deliberately bad
  pin on agent-coordinator and let the chain revert it); #1988's `renovate-global.json` blast-class rules;
  #1989's `.agents/review.md` edit (the migration lens paragraph + the FU-097 intent-review draft below,
  ONE operator-direct change). Platform `coordinatorModel` rides `opencode-go/deepseek-v4-flash` while the
  Anthropic 7d window sits at the latch — **revert to `opus` when the window resets** (claim +
  stacks.json mirror). The reviewer needs nothing (legacy ladder self-serves Go past 0.95; #1986 closed).
- **⚑ PICKUP (2026-09-24 — registry2 / FU-280 CUT OVER).** `registry.teststuff.net` → `registry-fs` on
  the `registry-data` volume since 14:50Z (#1961/#1962); the S3 Deployment runs unrouted as the rollback.
  Next steps + the operator's disk-tag question are on **FU-280**. **FU-286:** PR#1963 (talosctl from a
  nixpkgs rev at 1.14.1) was in flight at the sweep. Once it merges, `MgmtBeltCheckFailing{check="talos"}`
  should clear on the box's next pull. If it still fires, read the box's devbox resolution.
- **⚑ RESPONDER UN-PAUSE (FU-249, due 2026-09-23 — on the operator list).** When it is re-enabled, run
  this read-list in order. First delete the never-matching `alert-dep` filter in
  `agents/coordinator/responder-argo.yaml`, which reverts #1746. Then:
  (a) `responder_triage_sessions_today` for a day should sit well under the 09-11→16 ceiling of
  11–12/day.
  (b) `responder-seen` should gain `none-`/`window-`/`humandecided-`/`decided-` markers.
  (c) The `agent-transcripts/homelab/` prefix should exist (FU-210's acceptance: a report-only session
  still leaves a readable decision).
  (d) One real `node-maintenance` window should cost no session (FU-230 leg b).
  Known one-time cost: the FU-232 re-key files ONE fresh issue per affected (alert, object). That burst
  is not a regression.
- **⚑ GOAL #1906 (retro r5 batch, themed).** #1908/#1909/#1911 done. **#1910 is authored and UNQUEUED
  on purpose.** The operator reads Goal pin 3, then either queues it or rules it deferred on the store.
  Theme #1907's assembly (`goal/1906-scan → master`) is the one codeowner read, and it has not been
  opened yet. **#1651** (under retro r2 #1101) closes by hand once #1908 reaches master via that
  assembly. After that, #1101 closes ≥72 h later.
- **⚑ OPEN GOALS / CONTAINERS (verdicts are the operator's):** #818 G-B HELD (4-clause verdict posted).
  #1302 G-G post-launch: check 3 = the RUM residual, #1311/#1334. The consumer Workspace stays red on it,
  and that is **FU-250**. #1640 router Goal. #1769 rails Goal. #1418 S8 [stint](chainless-redesign.md): #1649 landed 09-14, so it
  is due to close at a sweep.
- **⚑ OPERATOR-OWED (one list, verified open 2026-09-24):**
  (1) **FU-097's intent-review instruction** for `.agents/review.md` is operator-direct. Draft, proposed
  under "Judge these carefully": *"On a surface the box
  applies on its own (management-box.md §The capability ledger: the main-root allowlist, Talos
  versions, Talos config), your read replaces the codeowner read, so review INTENT: does the plan +
  install-impact line do what the linked issue asked, given what the fleet and the box already run
  (a version skipping the canary type, a config that needs a reboot under `no_reboot`, a CP change
  while the CP toggle is off)? Intent and plan disagreeing is BLOCKING even when every check is green."*
  (1b) Same file, a second operator-direct fix: `.agents/review.md` ~L92 still frames ADR-128's narrowed gate as
  "the trial week (2026-09-11 → 09-18)"; FU-233 ruled it standing. A live reviewer brief with a lapsed range can
  mislead the reviewer. Its path list also omits `/scripts/` + `/nixos/`, which are in CODEOWNERS.
  (2) claude-jail `6f90815` (`DEVBOX_USE_VERSION=0.18.3`, FU-240) is still unpushed in `/workspace`.
  It needs your push + a jail rebuild, and the host profile wants the same export.
  (3) pop-os `~/.talos/config` may still hold the pre-rotation identity (FU-264 rotated the CA 09-22).
  #1882's "3 flagged choices" were never recorded.
  (4) pve's CMOS clear reset "Restore on AC Power Loss". Read it next time a card is fitted, or pve stays
  dark after a power cut.
  (5) Human-next-mover PRs: **circles-iac#108** (claim egress `none → python`, un-armed; flipping enforce
  under `none` hangs every uv call), sleep-iac#80, sleep-tracking#143.
  (6) Operator/seat sittings, open: #1237 (E1), #1238 (E2), #1224 (parts-coverage), #1280 (held for
  kind-timing evidence), #1370 (FU-171 resight), #1713 (pin-only-lint, operator lane), #1627 (unqueued),
  #1669 (blocked until theme 1 deploys).
  (7) Cloudflare `Cache Purge` onto tofu-apply vs relying on oracle-fleet#414's Cache-Control: undecided.
- **⚑ UNOBSERVED FIRSTS (read when they happen; no action until then):** #1621 is open for its live
  acceptance: the next oracle corpus publish should ring `/corpus-published` → `release-corpus.yaml`.
  `fixer.imageVolumes` (#1808, ADR-135): the first ride with `/corpus` mounted. The first oracle
  closeout under `.agents/closeout.md` (#1806, ADR-134). The first real `CronJobNotSucceeding` fire:
  is a weekly job's 21-day threshold tolerable? The origin mark's SERVE-TIME check (#1942), which is
  owed by oracle: a null `origin` column means the header does not survive the tunnel hop. Also check
  whether our platform-stack deny on `deepseek/deepseek-v4-flash-0731` was meant to cover the
  permaslug-spelled cell, against which it is INERT.
- **⚑ UNBUILT, NO HOME YET (single sightings — detector-first on a second):** `fstrim-guard-*` should
  skip a cordoned node. `KubeJobFailed` fired 45 series during the 09-16 window, and adding it to
  `DECLARED_ALERTS` was rejected as too broad. Separately, the registry exposes no scraped metric, so
  push throughput has no belt.
- **⚑ HYGIENE:** stale agent branches (homelab 11 as of 09-05, plus agent-runtime 1, oracle-fleet 4,
  circles 4, sleep 1): delete or resume. The ZOMBIE hosted runs 32217689970 and 34748702282 cannot be
  cancelled by API: operator UI, or ignore. Phantom `agent/done` closes: confirm or relabel
  oracle-fleet #25 #24 #22 #7, sleep #7.
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
