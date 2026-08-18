# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid.)


## Live state (2026-08-11 end-of-pipeline consolidation — history is TICK-LOG's)

- **2026-08-17 overnight pickup (the all-day session's tail — full story in TICK-LOG):**
  (1) **PRs in flight, all machine-owned:** #475 (⏸ inventory re-word — a jail watch applies the
  operator's standing codeowner approval when the bot re-approves; if the session died, approve
  it by hand after the bot does) · #490 (board, TRIAGE-disjointness fix pushed, re-review →
  auto-merge) · #496 (reviewer currency gate, seat PR, bot approval completes it).
  (2) **#491 queued** (argo ttlStrategy/podGC — the #487 durable fix): its footprint hold
  released when #487 merged; **its ride should be the FIRST organic Go-flash worker ride** —
  morning check: the ride pod's `homelab.teststuff.net/rail=opencode-go` label (the dogfood's
  outstanding confirmation, still unobserved after a queue-held day).
  (3) **Morning sweep = `devbox run board`** (post-#490; until then `bash agents/board.sh` off
  the branch) — REVIEW should be empty, BACKLOG = #493 (+#289 oracle).
  (4) Go meter re-check against the console after ~a day of the restarted shim (drift should
  stay ≈0; ⚠ any future shim-code metering fix requires a shim RESTART — the running process
  is the meter). (5) FU-155's oomactions capture after hp-01's next pressure event (#485's
  marker-limit thesis). (6) The churn fixes' first quiet proof: next busy-master day should
  show near-zero unstrand updates of unmergeable PRs and near-zero standing-asides.

- **minutark.ee LIVE + DNSSEC COMPLETE**; oracle-iac#351 OPEN — deliverable = the bootstrap AS
  IaC, **UNBLOCKED 2026-08-12** (the host-side token session ran: two-zone ingress token minted +
  stored) but oracle is PARKED (operator 2026-08-11) — pick up at unpark; acceptance =
  drift-free re-plan through the two-zone token. FU-157 opportunistic. ⚠ `dig +short` wraps
  long DS digests — `tr -d ' '` before grepping.
- **HA #221 (meta lane)**: probe RAN 2026-08-13 — protocol_version hypothesis REFUTED (entries
  match negotiation); real defect = tuya_local receive loop dies silently, no retry (RECURRED
  2026-08-17 per the thread). **All 4 plugs REVIVED** by per-entry REST reload while the device
  answers. Remaining (operator, 2026-08-17): **tuya_local 2026.7.2→2026.8.0 upgrade = a
  DEDICATED FUTURE SESSION** (operator does it; HA config is imperative-apply per runbook) —
  the receive-loop death is the bug it may fix; **gaas is HARD-WIRED, no plug to cycle** — a
  power cycle means finding its breaker (operator, someday; if post-cycle 914 persists → key
  rotated, re-extract via the tuya-egress.py door); the 9-static-sensor alert exclusion is
  QUEUED as homelab#478 (machine lane owns it now).
- **ADR-107 / Go-rail chain (charter = [`chainless-redesign.md`](chainless-redesign.md) — its
  §Rollout status is current): PART 1 COMPLETE 2026-08-14 02:25Z** — all chunks merged+live
  (PRs #429/#433–#437/#440–#443; every chunk issue closed w/ evidence; #420 = the status
  comment). PICKUP, in order: (1) **#439 leg 2** — agent-session.sh:1407 adopts the
  `--pick-rail` ladder via the PR#407 `_claude_model` plumbing; retro inherits it with zero
  retro changes — land BEFORE retro's first unattended fire 2026-08-17; PR body must flag the
  worker-ride widening. (2) **Post-weekly-reset sonnet re-reviews**: `bash agents/re-review.sh
  --project homelab` (3 snapshot sets banked: pr-437 ×2, pr-441 — the r6 approval snapshotted
  itself). (3) **The wave's ledger PR** — rows in the session scratchpad
  (`ledger-draft.md`); if this session is gone, reconstruct from TICK-LOG 08-13/14: new classes
  = fabrication-in-transcription, deferred-verification coverage shadow, self-defeating-fix,
  explain-away/false-completeness reports. ⚠ the running jail shim predates chunk G — jail
  subagent burn is unmetered until the next `claude-go` launch (self-resolving; the cluster
  meter + account console disagree by exactly that traffic meanwhile). Go 5h window economics:
  review rounds ≈$1 each — a 6-round PR cycle is the biggest single draw. Build mode unchanged:
  clone subagents, double review, misses →
  [`../spikes/subagent-handover-misses.md`](../spikes/subagent-handover-misses.md).
  Pending verifies: PR#407 (next platform ride's OTLP model), elastic shadow cells (#408).
- **Zen free rail: SHIPPED on both surfaces (2026-08-14).** #446 = jail shim+launcher (merged
  07:08Z, 1-round approved; shim-self-test CI-gated 9e97d5d) · #447 = proxy both ingress
  surfaces (OPERATOR-merged 08:11Z direct to master — "subscription latch gates review" was
  the operator's account of the dispatch gap; pod rolled <1 min, ConfigMap-shipped). Interim:
  reviewer Go-failover model = **deepseek-v4-flash** (665cf64 — a $6.33 k3 review in the
  balance regime; the proper model is decided next week). **#448 SHIPPED 2026-08-17**
  (PR#465, the LiteLLM SDK leg — luna's Anthropic-compat surface is broken even for text). PICKUP: (1) live smoke the
  proxy zen leg (`opencode/nemotron-3-ultra-free` through the in-cluster proxy — NOT verified
  post-merge); (2) the #448 dispatch call; (3) FU-172 residues; (4) cleanup: the subagent
  worktrees (`.claude/worktrees/agent-*`) + merged branches fix/opencode-zen-rail, fix/zen-rail.
  Open: FU-170 (balance blindness), FU-171 (token refresh). Zen tool-compat: free tier is
  text-only through Anthropic-compat; the translator is the unlock (evidence in the matrix row).
- **⚑ GOAL LANE PAUSED (operator ruling, 2026-08-13):** the Goal type is too expensive to run —
  the v1.1 pilot took expensive jail meta-coordination that still did not stop the 46 sprouts,
  plus ~16h hands-on the operator will not repeat, and the weekly Anthropic pool is BLOWN (7d
  ~0.87–0.89). No new Goal until the v1.2 machinery (ADR-106 checkpoints + FU-168 famine fixes)
  is complete AND the budget recovers; Bucket B's launch gate inherits this as a further
  precondition. Current mode instead: fast double-reviewed subagent chunks (bullet above).
- **Soaks**: iac-sentinel shadow (FU-106); router shadow (FU-095); retro first UNATTENDED fire
  2026-08-17 (FU-058); FU-148 acceptance (first organic env-red self-retry); FU-149 datum
  ~08-20; or-op#34 (first daily-429); renovate-approve fix (#114) = next Renovate wave shows
  ONE approval per head; check-#3 shadow warnings stay zero.

## NEXT SESSION — the worklog (updated 2026-08-12 wind-down: BUCKET A COMPLETE)

⚑ **Fresh-session pickup (2026-08-12 ~19:10Z stand-down):** re-arm per §Re-arm (the meta-events
monitor died with this session). Then the order is: (1) **circles#81** — the §Maturity
disposition-mapping PR awaits the OPERATOR codeowner read (armed, bot will approve); (2)
**homelab#365** — the one stack-sweep leftover (promote the #349 bridge bound to the class
block); (3) **Bucket B launch gate** — the pre-Goal issue sweep (the inert 🌱 set: #280/#292/
#295/#297/#303/#329/#354/#360-364/#369 — operator wants them decided BEFORE the next Goal) +
launch criteria (A0 ✓ green; Pending gauge flat = watch post-A2; v1.2 legs replay-pinned ✓);
then the Goal per Bucket B. Small residuals: 4b′ label flap · FU-051 E2E = organic watch ·
circles deploy-bump generator fix before the next circles build (item 6) · A5 pile grows in
iac-lane.md §governance checkpoint.

0. **THE PLATFORM PLAN (chartered 2026-08-12) — two buckets.**
   ⚑ **Session-type bootstrap rule (operator, 2026-08-12): a BUILD session reads THIS section +
   §Re-arm and nothing heavy** — no design-agents corpus (145k; pay it only for a DESIGN sitting
   like A3/v1.2), no full /meta-coordinate (pay it only to resume the coordination ROLE). The
   charter carries the decisions; chunks name their files; CLAUDE.md/memory carry the process.
   **Bucket A (pre-goal, PR-lane with the bot reviewer — the seat stops accumulating unreviewed
   debt):** A0 ✅ VERIFIED 2026-08-12: the soak IS observable — reading rule: `iac_sentinel_violations`
   no-series + FRESH `iac_sentinel_engine_seconds` (all 4 engines, per-repo, 786s at probe) =
   genuinely ZERO violations; stale engine rows = blind. `probe_failed` absent. Gap noted:
   `SENTINEL_REPOS` defaults to sleep-iac+oracle-iac only — circles-iac joins when unparked
   · A1 FU-167 moves 1–3 (replay world registry, table-mode pilot, generated register) — FIRST,
   everything else rides its lock · A2 ✅ DONE 2026-08-12 (#393): receiver-side collapse
   (absorb-pending, zero lost edges) + FU-144 fan-out + `--detach` mutex scoping; the 017790c
   wake metrics + `AgentDispatchCronWoken` are live — the "cron-woken ≈ 0" acceptance now SOAKS
   under FU-168 — ⚖ rail move REJECTED (workers stay subscription; ruling in
   model-routing.md §M12) · A3 ✅ DONE 2026-08-12 (the same-session sitting) → **ADR-106** (PR#389): single-mode
   feature goals (master-lane variant RETIRED — not a Goal), origin lineage (bucket back to
   ADR-102's strays-only role), findings store + checkpoints, fence → metadata + MECHANICAL
   governance lint, mutex scoped to the deterministic phase, stack scope ·
   A4 ✅ ALL FOUR LEGS DONE 2026-08-12: governance lint (direct) + merge doorbell (#396) +
   the core (#398, 3 review rounds): findings store (goal-findings.sh, CI self-test) +
   goal-checkpoint clause + harvest=store + burn-down demotion; FSM IL-T12/T15 rewritten · A5 RULED 2026-08-12 (mapping session): leg 1 SHIPPED (#401 — sentinel shadows homelab; the
   tier-1 scaffold line drops when IAC-G04 enforces there or on the operator's trust call);
   further ownership/gate changes now BATCH into the governance-checkpoint pile
   (iac-lane.md §The platform lane — one /design-agents sitting per batch, never per-event
   one-liners); full narrowing stays blocked on an assembly single-tax replacement · A6: #377 class ✅ (#402, 4 rounds — 27 :-null guards + goal-budget bash guard; ⚠ lesson:
   a mechanical sweep regex corrupted 4 printf sites, bot caught the regression) · FU-166 ✅
   WHOLE (#403 + archived: park/reflex split series, CodeownerParkWaiting, Prometheus-first
   watch w/ collector-liveness key, the Goal-run cockpit — dashboard tf-APPLIED) · inert 🌱
   triage → Bucket B (operator: decide with the pre-Goal issue sweep). FU-168's design half = DELIVERED by ADR-106; its build half rides A2/A4.
   Jail latency fix (meta-events.sh, FU-166(b)) DONE first, direct to master.
   **Subagent trial RUN 1 recorded 2026-08-12** (goal-ancestor table-mode, PR#392 merged):
   defects by catch-point seat 0 / bot 0 / post-merge = watch with lag; 148.5k subagent tokens;
   9m11s authoring, ~20m dispatch→merged. One data point, no adoption verdict — next comparable
   chunk continues the A/B (harvest-goal or c4c5 conversions are the named candidates).
   **Next-session shape (operator, 2026-08-12, calibrated): worktree-subagent TRIAL first, not
   adoption.** Suitability test = "would it need the design-agents corpus?" — if yes, it is
   design mislabeled as build → SEAT work (doorbell collapse is seat work by this test; today's
   chunks all had mid-build design calls). Suitable subset = mechanical-with-established-pattern,
   loud verification: the remaining table-mode family conversions (harvest-goal, goal-ancestor,
   c4c5), per-fixture `requires:` diagnosis, doc/register sweeps. Protocol: ONE subagent, ONE
   family (goal-ancestor, 4 fixtures), **pre-push seat review of the worktree diff** (bounce via
   SendMessage; only the seat opens the PR), then bot review — two decorrelated reads, zero
   codeowner touches. Measure: defect rate by catch-point (seat/bot/post-merge), tokens vs
   seat-does-it, wall-clock. ⚠ The corpus-read test is a PRIOR, not a classifier (operator):
   the dangerous class is context-poverty defects that pass BOTH reviews and surface later —
   invisible to one run by construction. So this is an A/B over MULTIPLE comparable chunks
   (seat-authored vs subagent-authored), post-merge defects tracked with a time lag, no
   adoption verdict from run 1. Exploratory: better than speculation, decided by accumulation.
   Width if adopted ≤2-3 (subscription burn is the limiter).
   **Bucket B (the next Goal, launches on v1.2):** FU-095 pilots (task-class routing legs a/c +
   strike-policy data) · FU-106 G01 flip chain (conditional on A0; the flip = the goal's
   `Production-leg:`) · G06 advisory lens + SLO error-budget teeth (roles.md; ex-FU-104) ·
   FU-090(b) janitor spec-drafts · cross-repo children by design (agent-runtime#36, or-op items).
   Goal-body skeleton: Verdict-authority: human · Production-leg: sentinel ENFORCING on the -iac
   repos + pilot evidence in the ledger · KPI: sprouts-per-ride < 1.2 (the debt-drain
   prediction) · Budget: subscription-window capped (subscription budgets = later work).
   **Launch criteria:** doorbell Pending gauge flat under load · v1.2 legs replay-pinned ·
   7d utilization headroom (74% at charter) · A0 green · **the single-tax boundary designed**
   (operator, 2026-08-12: codeowner-touch count is THE objective — assembly merge = one tax
   per feature; the master-lane variant dissolved it and must not recur).

1. **PR queue DRAINED 2026-08-11 (~11:30Z)**: #250/#251/#254/#255/#260 all merged (findings
   harvested; residues: FSM dup keys + fixture registration + FU-106 third residue — all in the
   same-day jail batch). The day's "FU-130 WAN class" reds were actually **wk-metal-02 losing
   its IPv4 default route** — postmortem
   [`docs/incidents/2026-08-11-wk-metal-02-default-route-loss.md`](../incidents/2026-08-11-wk-metal-02-default-route-loss.md);
   node rebooted + verified, ARC runner spread/requests shipped (arc-runners.yaml).
2. **Board CLEAN per operator directive** (queue/fix/close all agents/infra issues; HA may
   remain): closed #107/#131/#223(→#231)/#241; #235/#240/#244/#245 closed by merges; QUEUED
   #242/#248 (+ already-queued #249/#252/#253/#256-259) — the loop drains them. Remaining open
   by sanction: #221 (HA, meta chain above), #231 (single Cloudflare anchor — host session).
3. **snore-recorder#15**: CI GREEN after the m02 fix (the "environmental red" was the route
   loss). Remaining: address the review verdict (FU-051 deploy-pin enablement).
4. **GOAL #278 CLOSED VALIDATED (2026-08-12 08:40:37Z — first VALIDATED terminal; 41s
   label→close, zero descendant writes, report-first sweep as pinned).** Bucket #295 left OPEN
   (sweep proposed "close with the goal" — operator's call); #289 park-deferred; 14 inert
   sprouts = ordinary triage. The v1.2 design dossier is
   [`docs/spikes/goal-lane-v1.1-fu165-pilot.md`](../spikes/goal-lane-v1.1-fu165-pilot.md) +
   the version register (issue-authoring.md §Goal lane versions); FU-166/167/168 UNBLOCKED at
   the verdict. Small fix-round candidates before the next platform Goal: doorbell fixed-name
   collapse, stream/mutex scope, platform-worker rail/semaphore, goal-budget.sh dash fail-open
   (one-shebang #377 class, named in the 06:24Z ruling), #379 triage (hold as FU-168 evidence).
   Rail-aware budget summation rides post-FU-131 (cap-phantom $76/$60 at close, ~$0 real).
4a. **Post-goal INERT 🌱 residue (deliberately unqueued; ordinary triage):** #280 (replay-README
   FSM wording — verdict posted), #292 (retro byte-identical cells), #297 (ratchet → model-scout),
   #303 (generate.py currency check), #329 (5 non-hermetic fixtures — sandbox-only, CI green),
   #354 (agents/** tier rationale question — operator-shaped), #360/#362/#364 (doc staleness),
   #363 (FU-039 absorbs CloudflareEdge5xx), #365 (promote the #349 bound to the class block),
   #369 (FU-042 pre-flight mention-widening).
4c. **Pending verifies/soaks from the goal (post-sweep 2026-08-12):** FU-161 = read the digest
   of hand-fire `model-scout-2psl6` (fired at the sweep; settles the `arguments` envelope), then
   legs 3–4 · FU-150 = quiet-month window opens ~2026-09-11 · FU-146/FU-147 soaks unchanged ·
   #289 launches at oracle unpark · snore#15 = FU-051 verdict work. (FU-140/145/158/160/162/165
   ARCHIVED by the sweep — crash-net proven 297/0, phase metrics live, pilot validated.)
4b′. ⚠ NEW small drift: `kubernetes_labels.longhorn_bulk_zone["wk-metal-04"]` flaps in the
   plan (applied, then reads changed again — something node-side rewrites it); chase when next
   in tofu, not urgent.
4b. ✅ DRIFT APPLIED 2026-08-12 (attended): wk-metal-04 ephemeral taint verified on the node;
   ci-runner-01 REPLACED and verified up (guest agent: .55 on eth0, docker0 up, SSH over TCP —
   ⚠ ICMP from the jail lies here, probe TCP).
5. **docs-cleanup residue** (the comb ran + ~55 findings APPLIED 2026-08-11; what remains):
   (a) ✅ merged 2026-08-12 (#395); (b) ✅ re-captured 2026-08-12 (operator cabling: wk-metal-01/02+hp-01 on the core 10-port,
   wk-metal-03/04 on the office 5-port; ci-runner-01 on vmbr0); (c) FU-001 ref scrubs when its archive entry
   expires (~08-13); (d) the openrouter-proxy.py FU-021 comment repoint — rides the NEXT
   functional proxy change (a comment-only sync restarts the proxy and resets every for:
   window); (e) the five EXPIRY-HELD archive ids (FU-014/021/022/025/041) need their own
   scrub pass or a ruling that foundational shorthand keeps its archive residue.
6. **Standing from 08-10** (⚠ PARKS LIFTED 2026-08-12: the circles/oracle parks were
   goal-v1.1-window only (operator) — stack PRs run ARMED again. Residuals now live:
   circles#77 ci-red triage · oracle-fleet#259 codeowner read (seat read posted 2026-08-12:
   decline the .agents/ carve-out, de-dup the recipes' shared rules) · oracle-fleet#225 ERT
   snapshot re-run · ⚠ circles deploy-bump generator writes the app CalVer into the -iac GIT
   targetRevision (broke circles-infra; fix the workflow before the next circles build —
   circles-iac#71/#68)):
   oracle-fleet#255 rework (attended-download constraint stands). The HOST-SIDE 4-step
   jail-read-all sequence: ✅ ALL DONE 2026-08-12 (argo verdict → PR#394; jail-read-all minted,
   verified from the jail, legacy token DELETED; #231's blind leg settled + annotated —
   **#231 is probably closeable now, operator's call**).

## Durable warnings — re-read before touching these files

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
  claim change until the doorbells read the cluster too — that is the real repair, not done.
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

- **meta-events loop (REQUIRED, replaces the standalone needs-meta arm)**: `Monitor` (persistent)
  `bash agents/meta-events.sh` — the FU-166(b) consolidated 120s edge-detected loop (needs-meta
  absorbed as a source via `--once`, + goal-thread User comments, aggregated alert set, doorbell
  famine gauge). Cold state re-emits the standing set = the fresh-session bootstrap view.
- **needs-meta watch (legacy standalone — do NOT double-arm beside meta-events)**: `Monitor` (persistent) `bash agents/meta-needs-attention.sh`
  — unreviewed platform PRs, `agent/blocked` issues, unlabeled>24h, AND (clause 4, 2026-08-08)
  stack-repo codeowner parks (bot-approved+green+REVIEW_REQUIRED on oracle-fleet/circles — it
  caught circles PR#54 on its first pass; oracle PR#217 had sat 17h). ⚠ verify by process AFTER arming
  (`ps aux | grep NEEDS-META` for an inline variant, the script name for the script one — an
  absence is a claim about your grep, proven again 2026-08-08 05:00Z).
- Backstop heartbeat: `Monitor` (persistent) `while true; do sleep 7200; echo "META-HEARTBEAT:
  sweep due"; done` — every sweep runs `bash agents/meta-throughput.sh` FIRST (queue-vs-movement;
  a THROUGHPUT-STALL line is an incident, not calm — 2026-08-09 operator catch), then
  `bash agents/meta-alert-crosscheck.sh` + the board/chain check against this file.
- Handoff watch is NOT standing (operator 2026-08-09: special case) — arm `bash
  agents/meta-handoff-watch.sh` only on rollout days / when a stack jail is known active;
  `/handoff` processes the inbox on demand.
- Loop watches (`agents/meta-watch-loop.sh` per stack) are OPTIONAL rollout-time tools now —
  expect ~10 routine events per real signal (operator 2026-08-08: "too many monitors").
- Probe hygiene: probes in SCRIPT FILES, dry-run under the real interpreter; watch the FAILURE
  signature explicitly; `PROBE-FAIL` over silent empty state. Monitors survive `/clear` and are
  invisible to TaskList — find leftovers by process and kill before re-arming.
