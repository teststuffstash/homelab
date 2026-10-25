# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid — and every design-agents corpus load pays it too: at 75 KB this file cost
~20k tokens per corpus session before the 2026-09-05 prune. A wind-down writes the PICKUP,
never the session's arc — that is TICK-LOG's.)

**`dig-explained: <Alert>[, <Alert>…] — <reason>`** is the ONLY line here the [deep dig](roles.md) (ADR-148,
`agents/deep-dig-select.sh`) reads as "this alert is explained"; a bare mention — the standing-alerts
list every wind-down writes — does NOT count (#2526, 2026-10-12: `RegistryMirrorDanglingLinks` hid from the
dig for days by being listed). Write the marker only when the cause is known; the reason rides into the dig's record.


(No marker standing. 2026-10-24: the `RouterRunModelUnverifiable` marker was REMOVED by the fu-sweep — the alert now
fires on 8 series incl. openrouter-rail models (kimi-k3, glm-5.3-flash, mimo) its reason did not cover, so the dig re-reads it.)

## Live state (pruned 2026-10-24 — every bullet re-verified against GitHub/the cluster/the box that day; history is TICK-LOG's; the forward plan is the ROADMAP work map)

- **⚑ PICKUP (2026-10-24 12:30Z — S9 Renovate sweep; TICK-LOG 10-24).** Verify next session: homelab#2819 regrouped
  (chart 2.4.3 + digest) after #2886; sleep-tracking#203 rebuilt by Renovate after the 12:01Z hand-back; allure#11
  regrouped with tests/Dockerfile after allure#35 (`ArmedBehindNoApprovalStranded` fires on it, no dig yet).
  Python 3.15 wave PARKED org-wide (#2610 / oracle-fleet#883 ruling + `Un-park:` line; circles#124 stack-side): un-park
  when `devbox search python@3.15` resolves the final (rc2 today). Residual list: #1985 comment 6383963515; FU-316.
- **⚑ MORNING READS (2026-10-26, operator) — two HELD PRs + one direct push landed overnight (TICK-LOG 10-25):**
  (1) **homelab#2902** Kargo prod install @ 8444efd4 — all three shape questions settled (git token → `kargo-shared-resources`;
  API plain HTTP :80; startup `list secrets` accepted → FU-318a), PSS restricted + namespace labels fixed, CI green, sentinel red
  until the exceptions baseline lands on master (#2403 precedent). Pre-merge after the read: exceptions baseline on master →
  two Infisical keys (`KARGO_ADMIN_*`) → CRD maintenance window (FU-304/315) → `mgmt-tf` plan/apply (+1 repo entry) → merge →
  the PR body's apply plan. The checker's new library rules add 38 Kargo rows (SA automount, wildcard verbs in the CHART's
  ClusterRoles, ro-rootfs, probes) — a read: fix before merge or accept as the platform-wide debt they are (322 on master).
  (2) **homelab#2911** component checker @ 1b720e68 (CI in progress at wind-down) — `scripts/component-check.sh` renders every
  Application + runs kyverno: PSS restricted from the `kyverno-policies` chart 3.9.2, 21 rules vendored from kyverno/policies
  `release-1.19` via `scripts/vendor-kyverno-policies.sh` (partial-vs-legacy choices in each header), SERVICES.md check;
  report-only; diff-ci gate; master control 322 findings. Arming it brings the reviewer. Its Renovate lanes (git-refs digest +
  postUpgradeTasks, chart regex) are ON MASTER already (direct, operator-ordered, this push) — inert until #2911 merges.
  Residuals in the PR body: no `ci.yaml` step (operator-direct), sentinel v2 integration next, legacy ClusterPolicy API deprecation.
  (3) The #918 spec read (oracle-fleet) — still the operator's; steps 1, 4, #919, oracle-iac#1140 wait on it.
- **⚑ DELIVERY LOOP / KARGO (oracle-fleet docs/delivery-loop.md).** Oracle gaps filed unqueued: oracle-fleet #926–#930,
  oracle-iac#1140 (held for #918). Residuals: FU-317, FU-318. Kind e2e not re-run since (jail has no Docker; the one open
  proof for #2902 is `runAsNonRoot` end-to-end — the image is User 65532, so a first prod sync is an acceptable test).
- **⚑ GATEWAY (FU-270 is the pointer — its Next is the seat's list).** Each 6 h refresh: `devbox run -- bash
  gateway/scripts/canary-entrants.sh --max 3 < /dev/null` → `benchmarks-snapshot.sh` → `cd gateway && devbox run tiers --
  apply` → PR when the lists move (a key NEW to the loader ships AFTER its image, #2812). Watch: the jail's codex REFRESH
  ~10-26 (`logs_2.sqlite` of `.codex-jail/homelab-codex`, status codes only). Watch Go-rail worker strikes: mimo-v2.6-flash
  4/7, glm-5.3-flash 0/3 clean (#2903 re-cut). opencode 2.0 hold stands (facts: TICK-LOG 10-18). Operator-only: FU-313,
  #2768, the baseline forwarder's 4 forks (TICK-LOG 10-24 evening). **Oracle prober on codex BUILT (10-24, rulings A/B/C):**
  #2904 + #2905 live (agent-base prober, `prober.childRail`); codeowner read oracle-fleet#933 → then ARM oracle-iac#1141
  (unarmed on purpose until #933 lands). Seat: read the first cron tick with a codex child after that.
- **⚑ ADR-156 step 5** — measure tokens / worker rounds / invalid findings / coordinator interventions per completed PR
  ([`specs-reviewer.md`](specs-reviewer.md) §The portable process; next = the #2867/#2868 PRs). oracle-fleet stays on its
  own process until the operator says the gateway has proven it.
- **⚑ ESCALATED → operator (board-sweep 10-24):** homelab#2588 `agent/error` 9 d (shared rate-pool strikes; class fix
  #2601 unqueued); #2808 + #2757 unqueued (#2757 blocks circles#129). #2589 must land before stint #1418 can close.
- **⚑ wk-metal-04 `intel0` DEAD-ISH (found 2026-10-24 by docs-cleanup):** Longhorn disk Ready=False/NoDiskInfo since
  10-20 15:07Z (WriteFile EIO); `nvme0` (eui …410f6) logs `Identify namespace failed (-5)` every minute; SMART "passed";
  0 replicas on it, bulk tier one disk short. Detector `LonghornDiskNotReady` PR in flight (detector first). **OPERATOR:**
  reseat / swap slot or drive on Big Data, then `longhorn-tag-disks.sh` re-registers it.
  `LonghornDiskNotReady` (#2898, `triage: dig`) also catches **wk-02 `default-disk-080500000000`** (DiskFilesystemChanged since
  09-14 — the std-tier exit left the Longhorn node record's disk entry behind). **Next (seat):** once it FIRES (~15:53Z
  10-24), remove that stale entry in a maintenance window, through the script that owns disk records.
- **⚑ wk-metal-04 on Big Data (#2758, 2026-10-20).** Watch the MX500's 34 % lifetime used (attr 202). **OPERATOR:** the
  switch-port row (docs/network-physical.md) + whether `sensor.plug_opnsense_power` still meters the box
  (router-move.md:62 retires it).
- **⚑ RESPONDER — ADR-148 lanes LIVE since 10-04 (#2212); "disabled" = the OLD per-blip lane only.** Gaps + owners:
  FU-249 / FU-230. Still to PROVE in a window: #2418's claims-by-silence (grace / claim / no-session). Reader =
  `/board-sweep`.
- **⚑ GOAL #1906 (retro r5 batch, themed).** #1908/#1909/#1911 done. **#1910 is authored and UNQUEUED
  on purpose.** The operator reads Goal pin 3, then either queues it or rules it deferred on the store.
  Theme #1907's assembly (`goal/1906-scan → master`) is the one codeowner read, and it has not been
  opened yet. **#1651** (under retro r2 #1101) closes by hand once #1908 reaches master via that
  assembly. After that, #1101 closes ≥72 h later.
- **⚑ OPEN GOALS / CONTAINERS (verdicts are the operator's):** #818 G-B HELD (4-clause verdict posted).
  #1302 G-G post-launch: check 3 = the RUM residual, #1311/#1334 — **FU-250**. #1640 router Goal (#1669 standing,
  coordinator ASK done 10-24). #1769 rails Goal. #2273 post-launch (#2300): verdict after the Production-leg window
  (bucket-A count vs 38); to read with it — the seat's `Budget: 30 → 36` and #2324 (the scan clears `agent/error` on
  an `AGENT_INFEASIBLE:` park). #1418 S8 [stint](chainless-redesign.md): closes after #2589.
- **⚑ OPERATOR-OWED (one list, re-verified 2026-10-24):**
  (1) the claude-jail HOST REBUILD — the Dockerfile reads the stamp (claude-jail#10); `VersionSetMembersDisagree` +
  `VersionSetBehindPin` (seat 2.1.301) still fire and clear on it.
  (2) RULING: the Argo half of 10-11 — Garage's own image has no Renovate lane (vendored chart `appVersion`,
  `argocd/charts/garage/Chart.yaml`); shape if ruled: regex customManager on `appVersion` → docker
  `dxflrs/amd64_garage`, patch/minor mechanical, majors human, re-vendor stays a hand step. Arms unattended restarts of
  the one unrecoverable release, and `.github/renovate-global.json` is operator-gated — not a seat call.
  (3) Reads owed: #2183's three calls (`MgmtApplyDeferredByWindow` at 6 h; reconciler node windows hold the apply loop;
  `--admit-apply` apart from `--admit-reconciler` — the DEFERRED path is proven live 10-05); the `fu-mint-gate` trial
  verdict (replace it if it doesn't change behaviour); the ADR-142 re-read **2026-10-28** (gate-change PRs, lens
  verdicts, DIFFERS lines, weakened gates; revert = `/scripts/` in CODEOWNERS + governance-lint GOVERNANCE); the r8
  reports (#2522, merged on the bot by ruling — read after).
  (4) Prod routers on 26.7.5 with 26.7.6 pending on the official path (39 packages, no reboot) — an attended window.
  (5) pop-os `~/.talos/config` may still hold the pre-rotation identity (FU-264 rotated the CA 09-22).
  #1882's "3 flagged choices" were never recorded.
  (6) pve's CMOS clear reset "Restore on AC Power Loss" — UNREADABLE headless: a monitor/GPU visit or a deliberate
  plug-pull test; until then pve may stay dark after a power cut. The pve x16 NVMe test-fit also rides a pve visit.
  (7) Human-next-mover PRs: **circles-iac#108** (claim egress `none → python`, un-armed), sleep-iac#80.
  (8) Operator/seat sittings, open: #1237 (E1), #1238 (E2), #1224 (parts-coverage), #1280 (kind-timing evidence),
  #1370 (FU-171 resight).
  (9) Cloudflare `Cache Purge` onto tofu-apply vs relying on oracle-fleet#414's Cache-Control: undecided.
  (10) Whether the 10 `cronjob-needs-priority` Audit-warned CronJobs get a PriorityClass each (10-09).
  (11) HA plugs laptop3/laptop4/pve offline since 10-03 (`HomeAssistantPowerSensorStale` ×6, Tuya — not platform).
- **⚑ UNOBSERVED FIRSTS (read when they happen; no action until then):**
  `fixer.imageVolumes` (#1808, ADR-135): the first ride with `/corpus` mounted. The first oracle
  closeout under `.agents/closeout.md` (#1806, ADR-134). The first real `CronJobNotSucceeding` fire on a weekly job:
  is the 21-day threshold tolerable? The origin mark's SERVE-TIME check (#1942), owed by oracle: a null `origin`
  column means the header does not survive the tunnel hop. Also check whether our platform-stack deny on
  `deepseek/deepseek-v4-flash-0731` was meant to cover the permaslug-spelled cell, against which it is INERT.
  r8 F1 (0aaa6898): the first `goal/**` PR's ratchet step (none opened since 10-13). The first provider MAJOR merged
  on the lens's APPROVED alone (rule e1748261). The FU-143 goal-child closeout on the next goal child (#2280 never got it).
- **⚑ UNBUILT, NO HOME YET (single sightings — detector-first on a second):** `fstrim-guard-<node>`
  is nodeName-pinned ON PURPOSE (the manifest: "must still run when cordoned") — so while a node is
  OFF in a window its guard sits Pending and `CronJobNotSucceeding` fires (2026-09-27, wk-04): a window
  consequence for GAPS maintenance-window-G5's EXPECTED class, not a skip-on-cordon change. `KubeJobFailed`
  fired 45 series during the 09-16 window, and adding it to `DECLARED_ALERTS` was rejected as too broad.
  Separately, the registry exposes no scraped metric, so push throughput has no belt. The OPNsense firmware
  daily-check belt (official path, no Renovate). The reviewer exit-contract keys a merge head differently from the
  reviewer's standing-aside (false NO TERMINAL).
- **⚑ HYGIENE:** stale agent branches (10-24: homelab 11, agent-runtime 1, circles 3): delete or resume. The ZOMBIE
  hosted runs 32217689970 and 34748702282 (still `queued`) cannot be cancelled by API: operator UI, or ignore. Phantom
  closes: oracle-fleet #25 #24 #22 #7 closed still `agent/review`, sleep-tracking #7 closed `agent/blocked` — relabel.
  Platform `coordinatorModel` still `opencode-go/deepseek-v4-flash` (live AgentStack 10-24; the 09-25 temporary — back
  to the subscription when ruled). Stack-side: inert `:dependencyDashboard` lines; agent-runtime's `deps-pin-guard.sh`
  pre-#83; dead `update-pr-branch.reusable.yml` callers. #1988 closes when its base-image half has its own home.
- **⚑ DESIGN INPUTS WITH NO OTHER HOME (operator: deliberately not FUs — pick up in a
  design-agents sitting; re-ruled 2026-10-15):**
  - **Drainage economics RULING (2026-08-31, operator-confirmed; TICK-LOG 2026-08-31 has the arc)** — STANDS
    (re-confirmed 2026-10-15: batching works). (1) blocking defects (incoming blockedBy from a stuck stack issue /
    live wedge / 🚨) queue immediately, master-lane, hotfix-class, every filing door wires the edge; (2) the
    nice-to-have pile is corpus-session batch work — no new machinery; (3) the Touches classifier survives as a
    LINT (#1102). Clause 2's premise (gate reads are the binding resource) is revisited by the next admission
    spike, not by an ADR today (operator 2026-10-15). Banked, operator's own "not yet": an AUTOMATED design-agents
    corpus read on codeowner-parked BLOCKING issues — revisit if parked-PR volume freezes dispatch.
  - **v1.3.1 BANKED** (PR#1220, "deserves a place when it works"): `Origin:` line + typed defer/release +
    checkpoint theme-FORMATION are S8 originals — do not build piecemeal ahead of S8; delta 1 (park economics)
    landed independently (PR#1375/#1376/#1352).
  - Ruled 2026-10-15 and removed from this list: the role×stack×service access inventory (stack-transcript
    reads, jail `TOOL_GAP:`) is **P2 scope** (the gateway island); goal/**-fix-protects-nothing and
    long-lived-runner-state are DROPPED (dissolved by ADR-126 themes + hotfix master lane / runner cloud-init +
    replace); the dispatch-declared `requires:` FU is NOT filed (MCP on every harness was built to avoid the matrix).

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
