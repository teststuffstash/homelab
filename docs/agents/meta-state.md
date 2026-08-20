# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid.)


## Live state (pruned 2026-08-19 — history is TICK-LOG's; the forward plan is the ROADMAP work map)

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
  call at G-A launch; Goal budgets on the platform stack stay cap-phantom until FU-180.
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
  or-op#34 first daily-429 · renovate-approve one-approval-per-head (#114).

## Durable warnings — re-read before touching these files

> ⚠ This section is NON-transient content squatting in a transient file (a big share of its
> read cost). Eviction to proper homes (CLAUDE.md, the jail-subagent-card, owning docs, FUs)
> rides stint S4 (FU-117's context dedup) — until then it stays, unduplicated: pipe-filter-push
> and the zsh trap already live in CLAUDE.md/the card; two-readers is FU-178 now.

- **⚠ ABSENCE IS THE EASIEST THING TO FAKE — three self-inflicted probe errors in one night, all
  the same shape: query a NARROWER view than the question, then read the empty result as fact.**
  (1) `ls ~/.claude/homelab-github-reviewer/ | head -5` hid `private-key.pem` → I reported the
  reviewer credential missing and nearly sent the operator hunting a non-existent blocker.
  (2) `spec.fixer` on an AgentStack returned `null` → I reported "circles has no fixer block"; it
  is **per-repo**, `spec.repos[].fixer`, and carried `docker: true` all along.
  (3) `.spec.containers` on a ride pod showed only `agent` → I reported "no dind"; a **native
  sidecar is an initContainer with `restartPolicy: Always`**, and it was there with kata +
  `DOCKER_HOST`. Each time the operator supplied the counter-evidence.
  **Rule: when a probe returns empty/absent and that absence would CHANGE a conclusion, re-query
  the whole object before believing it** — `-o json` and read the structure, never `get X -o
  jsonpath=…` for a field whose path you are inferring, and never `| head` a listing you are about
  to call complete. An empty result is a claim about your query, not about the world.
- **⚠ A DEPLOY CAN SILENCE AN ALERT FOR ITS WHOLE `for:` WINDOW.** `SubscriptionWeeklyPoolLow`
  dropped out of the firing set at 06:41Z on 2026-08-07 — not because utilization fell (it was
  **0.92**, fresh, single series) but because deploying `router.py` restarted the proxy
  (`8574bd8d9-r42tx` → `cdc58fc45-wm8kr`). The old per-pod series ended, a new one began, and the
  **`for: 1800s`** timer restarted from zero. Any ArgoCD sync touching the proxy buys 30 minutes of
  silence on a real capacity problem. ⚠ **I read the firing-set change as "cleared" and reported it
  as such without re-querying the gauge** — the operator caught it. A firing-set transition is an
  event, not a measurement: re-read the metric before claiming a condition ended.
  Candidate fix (unshipped, needs a decision): `max_over_time(...[10m])` so a restart gap cannot
  reset the window — aggregating away `pod` alone does NOT help at one replica, where the gap is
  real. Same class as the day-gate bug: the alert's identity was tied to something that churns.
- **⚠ `severity: info` alerts are SILENTLY SUPPRESSED in this cluster.** kube-prometheus-stack
  ships a stock inhibit_rule (`alertname=InfoInhibitor` → `severity=info`, equal `namespace`) and
  `values/kube-prometheus-stack.yaml` does not override `inhibit_rules`. An info alert reaches
  Prometheus and fires correctly, then sits `state: suppressed` in Alertmanager and is dispatched
  to NOTHING — not the responder, not the Home Assistant webhook. Shipped one on 2026-08-06; it was
  live for ~10 minutes as pure decoration. **Use `warning`.** Tell: all 27 other alerts here are
  warning/critical. Check with
  `curl -s 'http://192.168.40.14:9093/api/v2/alerts?inhibited=true' | jq '.[].status'` — Prometheus
  saying `firing` is NOT evidence anyone was told.
- **⚠ A steady-state COUNTER cannot separate "at capacity" from "cannot work."** `running: 4,
  pending: 0` reads identically either way. Capacity claims need a THROUGHPUT signal: a saturated
  pool has jobs RUNNING, a broken one has workers WAITING. Made twice on 2026-08-06 — by me and,
  independently, by a responder session. Now in the responder prompt (`ecb74bb`).
- **⚠ A green surface is not a green outcome.** A workflow "failure" that had already shipped its
  artifact; a ride pod `Succeeded` with its harness dead (`exit_status=harness-death`, nothing
  committed). The status field often answers a different question than the one being asked. The
  durable signal for a ride is the `AGENT_STRIKE:` comment on the issue — `meta-watch-loop.sh`'s
  clause is best-effort only (ride pods are GC'd within minutes, so **its silence proves nothing**).
- **⚠ Check the bypass ACTORS before calling anything a human gate.** A `required-approval` ruleset
  whose only bypass is `OrganizationAdmin: always` is NOT a human gate — **the jail credentials ARE
  that admin**; `gh pr merge --admin` is yours to run. Applies to every platform-lane repo
  (agent-runtime, agent-coordinator, homelab, openrouter-operator) where `reviewer.enabled=false`
  means no bot will ever approve. ⚠ Do NOT "fix" that by flipping `reviewer.enabled=true` for the
  `platform` stack — it would also point the bot at homelab and `agent-coordinator`, both tier-3.
- **⚠ agent-runtime now HAS a fixer lane** — PR#37 merged 2026-08-07 03:48Z, superseding the
  2026-08-06 "no `.agents/` by design" ruling. It ships `.agents/fix.yaml`, `tests/` + a `unit` CI
  job over `agent-finalize`, and a CODEOWNERS owning the governor paths (`.github/`, Dockerfile,
  lockfiles, `.agents/`) while leaving the fixer's lane unowned. Its recipe uses `Fixes #n`, which
  genuinely closes since these PRs target master. ⚠ CORRECTED 2026-08-08 (~15:00Z): **"no bot
  reviewer on platform repos" is STALE for FIXER-ENABLED ones** — reviewer coverage follows the
  fixer block, and agent-runtime PR#40 went worker→bot-APPROVE→auto-merge with no human, which is
  the DESIGN on the unowned lane paths (agent-base/*): the codeowner gate guards only the governor
  paths there. homelab/agent-coordinator PRs still need the meta read + OrgAdmin merge (homelab's
  gate is whole-repo by operator ruling). ⚠ First `unit` run took **16m** on a cold nix cache;
  that is not a hang.
- **⚠ Arming is keyed on the `goal/` PREFIX** (`agent-session.sh` + `review-reflex.sh` C9). NEVER
  widen to "any non-default base": the prefix is the only thing carrying the ruleset, and arming
  into an unprotected base merges ON OPEN.
- **⚠ An operator-lane PR has NO machine owner.** `changes-requested` is scoped to `WORKER_AUTHOR`,
  so a human-authored PR is skipped by design and the coordinator announces that to nobody.
  oracle-fleet#166 sat blocked three days on a real, correct, twice-repeated finding. Only a board
  sweep across EVERY active repo finds these — not just the stack in flight.
- **⚠ Two readers, one mirror.** `coordinator-scan.sh` reads the LIVE CLUSTER claim; the DOORBELLS
  (`coordinator-session.sh`, `agent-session.sh`) read `agents/stacks.json`. Sync the file on every
  claim change until the doorbells read the cluster too — the repair is **FU-178** (2026-08-19).
- **⚠ "Written is not applied" — the tell is always the CALLER, not the config.** A label
  description >100 chars that never reached GitHub; a required check on a branch pattern no workflow
  triggered on; a `units` entry no gate could reach; a router class whose only caller is the worker
  launcher; a review reflex that ran, matched nothing, and said so in a log nobody read until a
  deadline fired. **A deadline is what turns a plausible reading into a checked one.**
- **⚠ A reviewer that verifies CODE against ONE spec page is not verifying it against the
  CONTRACT.** Two agents reasoned correctly inside `render/colors.md` and reached a remedy
  `data/status-resolution.md` forbids (circles#32, ruled 2026-08-06).
- **⚠ The jail's Bash tool runs ZSH, which does NOT word-split unquoted variables.** The repo's
  `K="devbox run -- kubectl …"` … `$K get pod` idiom is a BASH idiom: in an ad-hoc Bash-tool probe
  it becomes ONE command word, fails, and behind `2>/dev/null` yields an empty capture that a `-z`
  test reads as "the object is gone". Wrap ad-hoc probes in `bash -c '…'`, or call the binary
  directly. Scripts under `agents/` are safe only because they are invoked as `bash <script>`.
- **⚠ NEVER pipe-filter `git push`; verify pushes by fetch-compare.** `push -q | grep | head`
  swallowed 11 consecutive non-fast-forward rejections (2026-08-08 — PR#123's squash had moved
  master) while the shared host/jail worktree kept every apply working, so nothing LOOKED wrong
  until ArgoCD couldn't see new files. After each push: `git fetch -q && [ "$(git rev-parse
  HEAD)" = "$(git rev-parse origin/master)" ]`. Auto-merge makes mid-session master movement
  routine.
- **⚠ Shell/API traps that each cost real time:** `gh --jq` takes NO `--arg/--argjson`; an
  APOSTROPHE inside a jq program kills review-reflex FLEET-WIDE and `bash -n` cannot see it
  (EXECUTE the block — stub the expensive callee and assert the assembled string); `gh pr view` has
  no `merged` field (use `state == "MERGED"`); GitHub caps label descriptions at 100 chars; a branch
  rename CLOSES the PR whose HEAD it is; `python3` in the jail has NO `yaml` module (use the pinned
  `devbox run -- yq`).

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
