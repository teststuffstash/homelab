# Agent observability & the retro loop — see every session, improve the process from evidence

**This doc owns seeing what the agents did, and improving the process from that evidence** —
session capture, the durable store and browser, the facts ledger, and the retro loop.

**Where the machinery lives:** OTLP collector (`argocd/resources/otel-collector/`), the
`agent-transcripts` bucket (`agents/coordinator/garage-workspace.yaml`), three capture hooks
(worker `agent-finalize` + reviewer/coordinator launcher traps + the nightly `transcripts-sync`
CronJob), the viewer (`transcripts.local.teststuff.net`,
`agents/coordinator/transcripts-viewer.yaml`), the exit_status/error_class classifier +
pushgateway `agent_run_*` metrics + dashboards, and the `ledger-reflex` Argo CronWorkflow
(30-min cadence, `agents/coordinator/reflexes-argo.yaml`). The retro session itself is a
CronWorkflow that self-fires Mondays 05:00 UTC (unsuspended 2026-08-03; first END-TO-END run
2026-08-11 — see Part B). Companion to
[`workflow.md`](workflow.md) (control flow) and
[`../../agents/README.md`](../../agents/README.md) (launcher + stats).

Two needs, one substrate:

1. **Visibility** — browse any session (coordinator, reviewer, worker) per task, human GUI + LLM
   access, without hunting through three storage systems.
2. **Self-improvement** — what has been done by hand (reading transcripts where an agent got stuck
   or burned tokens, then editing recipes/briefs — e.g. fix.yaml's "read the issue FIRST" and the
   coordinator's "learned live on #18" notes) becomes a scheduled, evidence-based loop that
   *proposes* process changes through the existing human gates.

## Persistence per role (the 2026-07-08 gap table, current since §A1 shipped)

| Role | Transcript today | Survives pod? |
|---|---|---|
| coordinator | Claude Code JSONL on the `coordinator-transcripts` RWX PVC, mirrored to `agent-transcripts` by the exit trap + nightly sync (§A1) | **yes** (PVC + bucket) — 2026-07-08: PVC only |
| worker (goose/opencode/claude) | `run.log` + the harness session store, uploaded by `agent-finalize` (§A1) | **yes** (bucket) — 2026-07-08: **no**, Loki kept stdout only |
| reviewer | result JSON + `~/.claude/projects`, uploaded by the `reviewer-session.sh` trap (§A1) | **yes** (bucket) — 2026-07-08: **no** |
| responder (2026-09-17) | per firing alert: `alert.json` + `triage.log` + the `*.jsonl` + an A1 manifest + a typed `finding.json`, under `homelab/alert-<fp>/responder-r1-<ts>/` (FU-210 / FU-231, `agents/coordinator/responder-argo.yaml`) | **yes** (bucket) — before 2026-09-17 it was the one role with NO capture at all, and a triage that filed no issue therefore left nothing: the 2026-09-03 forgejo-pg-1 session marked the subject triaged, filed nothing, and the probe lane deferred to it as COVERED while the alert stood 8 h |
| deep dig (2026-10-04) | per daily run: `digest.json` + `brief.md` + `dig.log` + the `*.jsonl` + an A1 manifest + one `finding-N.json` (`dig-finding/v1`) PER GROUP, under `homelab/dig-<date>/dig-r1-<ts>/` (ADR-148, `agents/coordinator/deep-dig-argo.yaml`) | **yes** (bucket) — and, unlike the responder, the pod READS the bucket back with the reader key: a finding for the same (alert, subject) within 7 d is what stops a daily re-dig |
| jail seat (2026-08-19) | Claude Code JSONL on the host bind-mount (`.claude-data/`), pushed by `scripts/jail-transcripts-sync.sh` (heartbeat + wind-down) to the **separate `jail-transcripts` bucket** | host + bucket — and the bucket is deliberately OUTSIDE the viewer/retro read set: jail transcripts can carry wallet VALUES, so no cluster role reads them (`agents/coordinator/jail-transcripts-workspace.yaml`) |

The irreplaceable artifact is the transcript. Everything else (dashboards, retros) can be built
*later* over captured data — **capture is the only blocker before firing more coordinators.**

## Prior art (searched 2026-07-08) — what the field converged on

The survey is history; the four decisions it produced are not:

- **OTel GenAI semantic conventions are the industry rail** — Claude Code exports metrics/logs
  over OTLP natively, so standard spans land in the existing Grafana stack for free. That is why
  A0 below is "turn on the standard rail", not "build one".
- **Session replay is a product category, and we deliberately did not adopt one.** Langfuse is
  the leading MIT self-hosted option, but it needs Postgres **+ ClickHouse + Redis** — two new
  stateful platform services for a one-person fleet — and transcripts' durable home should stay
  git + S3 (ADR-080). Bucket + viewer + Grafana covers the need; revisit only if analysis
  outgrows Grafana.
- **Turnstone** (self-hosted orchestration, Apache-2.0) contributed three adopted ideas:
  **graduated autonomy** (advisory verdicts with auto-action only above a confidence threshold —
  which is what makes the autonomous-merge flip a *dial* rather than a switch), **verdicts as
  persisted structured objects** stamped with the final human decision (the FU-057 ledger schema,
  including "a failed judge still emits a marked verdict"), and a critical/high **heuristic rule
  pack** as a PreToolUse hook for bypassPermissions contexts — coordinator and meta-sessions
  only, never workers, because the pod scope is the boundary. Rejected from it:
  judge-is-the-session-model self-consistency (weaker than a decorrelated reviewer) and
  workstream routing (track labels already assign deterministically, with semantics).
- **Devin productized exactly Part B** — Session Insights, org-wide Knowledge that is
  user-approved before it persists (our PR gate), and Playbooks distilled from successful
  sessions (adopted below as B2.5).

## Part A — one durable session store + a browser

### A0. Turn on the standard rail (cheap, do with P0)

Claude-code roles (coordinator, reviewer, jail sessions) get **OTLP export enabled** →
an in-cluster collector → Loki/Prometheus now (Tempo when traces GA). This gives cross-run
token/cost/latency metrics on the standard schema for free and feeds the B1 ledger; it does NOT
replace transcripts (replay + LLM root-cause need the raw JSONL). Goose workers stay
manifest-only until goose grows OTel.

Since ADR-093 the loop reflexes run as **Argo CronWorkflows**, so Argo also emits
`argo_workflows_*` orchestration metrics to Prometheus (workflow/step duration, phase, retries) and
every run shows in the argo-server UI — orchestration visibility "for free." This is an *additional*
layer alongside the agent-domain rails (pushgateway `agent_run_*`, the github-exporter, OTLP); Argo
adds orchestration observability, it does not replace the domain layer, and the transcripts/ledger
machinery is unchanged.

### A1. Capture (P0 — the blocker)

Extend ADR-080's "durable = git + S3": **every agent session persists, before pod exit, to the
Garage bucket `agent-transcripts`** under

```
<project>/<task>/<role>-r<round>-<ts>/     task = issue-<n> | pr-<n> | tick-<ts>
  manifest.json     role, project, issue/PR, round, model, session-key name, AGENT_RUN_STATS,
                    exit status, links (PR, Grafana query, transcript files)
  <native transcript(s)>                   claude-code *.jsonl | goose session file + run.log
```

Hook points (all existing seams, small diffs):
- **worker**: `agent-finalize` (agent-runtime) already parses `/tmp/run.log` for stats — add
  "write manifest + upload run.log + goose session dir to S3" (S3 creds: a write-only key for this
  bucket, injected like the stats context; worker's data-cred story stays "none" — this bucket is
  its own exhaust, not platform data).
- **reviewer**: `reviewer-session.sh` uploads the result JSON + `~/.claude/projects` at exit
  (trap, so failures upload too).
- **coordinator**: PVC stays as the live/interactive cache; an exit trap in
  `coordinator-session.sh` (+ a nightly sync CronJob for crashed sessions) mirrors new session
  files to the bucket with a manifest per tick.
- **responder** (FU-210, 2026-09-17): the respond WorkflowTemplate uploads PER ALERT, inline in
  the loop rather than from an exit trap — its alert loop runs in a `while read` SUBSHELL, so a
  parent trap could not see which alert was in flight. Two calls: `_ts_session` immediately after
  the model returns (input + transcript + manifest, so a failure in the reopen/verdict belts
  cannot cost the record) and `_ts_finding` at the end of the iteration, when the verdict and the
  filed issue are known. The key is the same WRITE-ONLY bucket key the worker holds, which is
  also the ceiling on what the record may become — the pod cannot read its own findings back, so
  the lane's dedup state stays in GitHub + the `responder-seen` ConfigMap (FU-231).
- **deep dig** (ADR-148, 2026-10-04): the CronWorkflow uploads once per run from launcher-owned
  shell — the digest and brief BEFORE the session, the transcript + manifest + per-group
  `dig-finding/v1` records straight after it (`agents/deep-dig-select.sh harvest` extracts the
  `BEGIN-DIG-FINDING`/`END-DIG-FINDING` blocks and validates each one; an invalid block is
  dropped loudly, never uploaded as a record). This is FU-231's consumer leg: findings are the
  deliverable, issues are not written at all, and the bucket is READ by the next run (reader
  key, `agent-transcripts-s3`) for the "already dug" gate — the one lane whose state may live
  in the bucket, because its key can read.

### A2. Browse (P1)

- **GUI**: [claude-code-history-viewer](https://github.com/jhlee0409/claude-code-history-viewer)
  **server-mode WebUI** as one in-cluster Deployment behind internal ingress
  (`transcripts.local.teststuff.net` — transcripts contain repo content; never public). A small
  sync container mirrors the bucket's *claude-format* JSONL into the directory layout it expects.
  Coordinator + reviewer sessions render natively. **Goose workers ARE renderable (corrected
  2026-07-09)** — the viewer natively reads Goose's
  `~/.local/share/goose/sessions/sessions.db` (SQLite sessions+messages) and OpenCode's
  `~/.local/share/opencode/`. The earlier "converter needed" caveat was wrong: the fix is to
  **upload the goose `sessions.db` alongside run.log** (agent-finalize) and register the goose
  source in the viewer sync — then worker sessions render turn-by-turn like the rest. This is the
  direct answer to "the loop was hard to follow" (the #1 pain from the first hand-driven runs).
- **Task-centric entry**: the bucket prefix *is* the "all sessions for issue #N" view; add the
  prefix URL to the existing PR stats comment (one line next to the Grafana link).
- **LLM access (not built)**: a transcript MCP toolset —
  `list_sessions(project, task)` · `get_manifest(session)` · `grep_transcript(session, pattern)` ·
  `fetch_segment(session, from, to)` — so an analysis session pulls *slices*, never whole
  transcripts into context. This is the retro's (FU-058) standing want and the **only** concrete
  consumer that would justify standing up an in-cluster MCP server at all; the retro runs without
  it today by reading the ledger.

## Part A′ — what actually took time (measured from the first oracle runs, 2026-07-09)

**One-line takeaway: the loop wasn't slow because of infrastructure — it was slow because it was
*invisible* (stalls) and *dispatched to a weak model*.** Measuring issue #1's ~4 wall-clock hours
put the assumed bottleneck last: `/nix` is bind-mounted and warm on the node, so clone +
`devbox install` was **~6 s** every round after the first, and cold-start contributed ~0. The
ranking was **broken reflexes stalling invisibly ~2h23m** (nothing visibly happened — which is why
monitoring IS the speed fix, and why FU-057 outranked caching), **orchestration latency ~50 min**
(now near-instant on the ADR-093 edge, `*/15` backstop — machinery home: [`roles.md`](roles.md)
§reviewer), and **~48 min of pod compute on a cheap-but-slow model** that died to
truncation/retry-storms in 2 of 4 rounds.

**Both measurements were ARCHAEOLOGY**, reconstructed from Loki timestamps and pod lifetimes, and
the second ([`spikes/ride-latency-breakdown.md`](../spikes/ride-latency-breakdown.md), 2026-08-09)
hit the wall that shape always hits: its most useful question — was that pod's image node-cached?
— was unanswerable, because the events had aged out. **So the phases are emitted now, not
reconstructed:** the launcher pushes `agent_run_phase_seconds{phase=dispatch-gates|pod-spinup}`
per ride (FU-160, homelab#287) and `agent-finalize` adds the ride's interior under
`source="in-pod"`, with a breakdown panel on the `agent-issue` dashboard and the
`AgentRunPhaseSlow` deviation alert behind it. The launcher's list ends at pod-Ready because the
launcher usually does not outlive the ride (homelab#324). The phase list and its deliberate
omissions live in the spike; this paragraph is the pointer.

## Part A″ — the goal-lane ledger: WORK vs PLATFORM WAIT (circles#29, 2026-08-06)

Operator direction, 2026-08-06: *"keep a log of work vs platform wait time … ring doorbells if the
platform is missing one, don't let the process wait 30 minutes — meta-coordination context is also
a cost that the waiting burns."* Part A′ measured a WORKER's issue; this measures the **goal
lane**, where the hops multiply (decompose → child → merge → closeout → re-judge → next child) and
each missing edge costs a full `*/30` cron.

Two costs, not one. Wall-clock is the obvious one; the second is that a meta session **holds
context while it waits**, and that context is billed against a 1-hour cache TTL. A 30-minute
platform wait is not free even when nothing is being ridden.

**Accounting rule:** ⚙ WORK = a pod is executing (scan, session, ride, CI). ⏳ WAIT = the platform
knows something happened and nothing is running. Every ⏳ row names the missing edge, and a ⏳ row
that a doorbell could have collapsed is a **defect with an FU id**, not a fact of life.

| span (UTC) | what | dur | class |
|---|---|---|---|
| 07:51:25 → 08:00:00 | `agent/queued` applied → first scan sees it | **8m35s** | ⏳ no emitter on the label transition — FU-144 |
| 08:00:00 → 08:18:03 | scan + `goal-decompose` (opus; session 17m32s) | 18m03s | ⚙ |
| 08:18:03 → 08:18:14 | decompose done → next scan | **11s** | ✅ doorbell (session rings on completion) |
| 08:18:14 → 08:18:41 | scan → first child dispatched | 27s | ⚙ |
| 08:18:41 → 08:21:32 | item session → ride pod `issue-30-r1` up | 2m51s | ⚙ |
| 08:21:32 → 08:52:48 | #30's ride → PR #36 open, **armed into `goal/**`** | 31m16s | ⚙ |
| 08:36:44 → 08:37 | session completes → its doorbell → scan | ~20s | ✅ doorbell |
| 08:52:48 → 08:59:37 | reviewer reads #36, posts CHANGES_REQUESTED, rings | 6m49s | ⚙ |
| 08:59:37 → 08:59:42 | scan → `changes-requested` fix round dispatched | 5s | ✅ |

Through the first child, **⏳ 8m35s against ~68m of ⚙** — and only the very first row is wait. The
edge-triggered hops (session→scan 20s, verdict→scan 5s) are effectively free; `ci` on the goal
branch passed in 1m42s.

**Second child (#31), and a third wait class the ledger did not have: CAPACITY.**

| span (UTC) | what | dur | class |
|---|---|---|---|
| 09:39 → 09:47 | deferred item session re-rings `/coordinate` → scan re-dispatches #31 → defers again, ×3 | ~8m | 🔥 SPIN — the ring-while-latched defect, guard `8740767` |
| 09:47 → 10:43:03 | #31 PARKED (`agent/queued` removed); 5h subscription window draining 0.82 → reset | **56m** | 🧊 CAPACITY — not a missing edge |
| 10:43:03 → 10:43:20 | `agent/queued` re-added → stack doorbell rung → scan | ~17s | ✅ doorbell (`scripts/reflex-now.sh coordinate-circles circles-agents`) |
| 10:43:20 → 10:44 | scan → `issue-31 (queued-dispatch, class build, child of goal #29, sonnet, wip 1)` | ~40s | ⚙ |

⚠ **🧊 CAPACITY is a THIRD class and must not be logged as ⏳.** ⏳ means the platform knew and
nothing ran — a defect with an FU id. Here the platform knew, correctly refused, and the only
honest fix is more capacity or less demand. Filing an FU against it would be filing one against
arithmetic. What IS a defect is the 🔥 row above it: the loop spent the very capacity it was
waiting for, because a deferred session still rang the doorbell. Guard shipped; the park was belt.

⚠ **The park had no owner but a human.** Removing `agent/queued` stops the spin and also removes
the only thing that would ever re-queue the issue — so the containment silently became a
human-blocking step, and the whole lane sat behind it (#32 waits #31; #18/#19 wait #32). It was
restored from `meta-state.md`'s explicit RESTORE STEP, which is the only reason it did not sit
overnight. **A park is not complete until its un-park is written down with a trigger**, and a
latch-clear waiter that probes the real endpoint beats an estimated wall-clock deadline: the
estimate said ~10:40Z, the probe said 10:43:03, and the alert (`SubscriptionDispatchLimited`
clearing) fired before the utilization header caught up — the header was 57m stale and still read
0.82 after release. Trust the reset epoch, not the utilization number.

⚠ **A measured gap is not a missing edge — check what filled it.** The probe flagged 6m33s between
PR-open and scan-wake as a candidate ⏳ and the hypothesis under test was that
`agent-session.sh`'s end-of-run doorbell had been orphaned (its launcher runs inside the item-session
pod, which exited at 08:36:44 with the ride still Running). **Both halves were wrong**: the session
DOES ring on completion (`→ coordinator doorbell rung (/coordinate …)` is the last line of
`coordinator-081840`), and the 6m33s was the REVIEWER working, then ringing. Time attributable to a
worker or a reviewer is ⚙ no matter how quiet the logs are — the ⏳ column is for *nothing running*.

**Findings from the first two hops:**

- **The edges that exist are excellent (11s); the edges that are missing cost ~8–30 min each.**
  This is the same shape as Part A′ finding #1 — the sink is never compute, it is a transition
  nobody emits on. The goal lane just has more transitions.
- **`devbox run coordinate-now` does not wake a graduated stack** (FU-144, third dead edge). The
  documented mono-jail remedy for exactly this transition was stale. Use
  `bash scripts/reflex-now.sh coordinate-<stack> <stack>-agents`.
- **`AgentCoordinateScanWedged` measured the wrong thing** (FU-145). It keyed on scan-pod
  LIFETIME, but the pod blocks on the item session it dispatched, which **streams the ride
  synchronously** — so it fired on any dispatch whose ride ran >15 min, on every stack (seen twice
  in one hour, both healthy, both self-resolving; scan pod 18m32s vs an 18m03s session against a
  15m alert). The generalization is Part A′ finding #1's class again: **a pod-lifetime probe
  cannot measure a phase that blocks on downstream work — an alert whose subject is not the thing
  it names.** ⚠ Say "streams the ride", not "waits for the whole ride": the scan pod exits with
  the ride still Running, and the session rings its own doorbell on ITS completion, so nothing is
  orphaned — but the alert's duration tracked the stream, not the ride, and the two differ.
  **Fixed by keying on the deterministic scan phase** (SHIPPED 2026-08-11, homelab#283): the scan
  publishes the phase it is in as two pushgateway gauges, and the alert branches — no marker → pod
  lifetime (still exactly right, and the branch that catches a wedge dying before the script runs);
  marker saying deterministic → the clock restarts at the phase. The threshold stayed 900s: **the
  subject moved, not the calibration.** Mechanism + the metric/group keying live in
  `agents/coordinator-scan.sh`; the behaviour is pinned by
  `agents/replay/fixtures/scan-{wedge-alert,phase-marker}`, which red on the pre-#283 expr. Both
  tempting remedies stayed ruled out: ⚠ raising the threshold blinds ordinary ticks, and ⚠
  special-casing `goal-decompose` is wrong because the cause is lane-independent (that was the
  first diagnosis, made from the pod's lifetime before the blocking `logs -f` was found).
  ⚠ The p99 calibration behind the original threshold measured lifetimes from before the alert
  existed; it is not evidence that long scans are rare.
  **Second symptom of the SAME cause, still open and the more consequential one:** the
  `coordinate-<stack>` CronWorkflow is `concurrencyPolicy: Forbid`, so a long-lived scan pod
  SUPPRESSES the cron tick (measured: a `lastScheduled` that produced no pod because the previous
  scan was still Running). **The level-triggered backstop is therefore disabled exactly while a
  ride is in flight** — i.e. whenever a doorbell failing would actually cost something. Edges have
  been reliable, so nothing is broken today; but this is what turns ONE missed doorbell into an
  indefinite stall instead of a ≤30-minute one. Fixing the alert's key does NOT fix this half —
  the pod really is alive; either the dispatch stops holding the scan pod open, or the cron stops
  being `Forbid`.
- ⚠ **Do not "optimise" the 18m decompose.** It read 15 spec pages, a 52-entry ⚖ register and 91
  requirement ids, and produced a coverage map with three explicit deferrals. That is the work.
  The measurable waste is in the ⏳ rows.

**Note — planned `∥`, actual serial, and why that is FINE here** (operator, 2026-08-06: *"I don't
expect the first issues on the project to be parallel — not enough exists to work in parallel
yet"*). #29 plans *bake → page → (evidence ∥ kind gate)*; #18/#19 both declare `tests/**`,
`scripts/**`, `devbox.*`, so the ADR-097 prefix-overlap hold serializes them. **This is not a
decomposition defect and wants no fix.** A greenfield repo has one small surface, so nearly any
two children intersect — the honest declaration and the serialization are both correct, and the
`∥` in the plan costs nothing when it does not materialise.

The measurement only becomes interesting **once the surface is large enough that disjoint
footprints are achievable**. Until then, do not read serialization as lost parallelism, and do not
add a rule forcing decomposers to declare disjoint `Touches:` — on a young repo that pressures
them into declaring footprints narrower than the truth, which is far worse than running one child
at a time. Revisit if a LATER goal, on a populated tree, plans `∥` and still serializes.

## Part A‴ — the goal registry & convergence panel (ADR-102, homelab#209)

ADR-102's *"convergence is a number"*, built. Supersedes IL-G04's unbuilt gauge. Where Part A′/A″
measure one ride and one goal's hops, this measures **whether a goal is converging at all** — and
doubles as the goal REGISTRY, the answer to "what goals ran, with what verdicts, at what cost"
(the operator could not find circles#17 by search; the panel is a query, not archaeology).

**Series** — emitted by `github-exporter` (`collect_goals`), which is the ONE GitHub poller; the
goal fields ride the existing `collect_open_prs` GraphQL walk, so the whole family costs **zero
extra API calls** against the pool that drained on 2026-07-17.

| series | what |
|---|---|
| `goal_budget_usd` | the goal's machine-parsed `Budget:` line, parsed exactly as the launcher gate parses it. **Absent** when no line parses — unfunded-unknown is not funded-zero |
| `goal_descendants_open` / `_closed` | the native sub-issue tree at ANY depth (post-launch bucket included). Never label-derived |
| `goal_sprouts_filed_total` | descendants at **depth ≥ 2** — review harvests and post-launch children, the inflow that makes a goal diverge |
| `goal_descendant_info` | one series per (goal, descendant, depth), goal itself at depth 0 — the membership the money joins against |
| `goal_verdict` | state enum: `open`, ADR-102's `validated`/`reverted`/`abandoned` when a `goal/*` label carries one, else the GitHub-native close reason |
| `goal_tree_truncated`, `goal_query_supported` | the read-honesty pair (below) |

**Spend is a join, not a poll.** The exporter holds GitHub tokens only — it has no bucket
credentials and must not grow an S3 read of `_ledger.jsonl` to restate a series Prometheus already
has. Worker spend is already pushed per run as `agent_run_cost_usd{project,issue,…}`, so
`goal_spent_usd` is a **recording rule** (`argocd/resources/github-exporter/prometheusrule.yaml`,
group `agent-goals`) joining cost to membership on `(project, issue)`. The membership side is
deliberately the "many" side of the match, so a goal nested under another goal attributes its spend
to **both** ancestors instead of failing the rule.

`goal_budget_ratio` and `goal_budget_remaining_usd` follow from it — **but only across an explicit
join, and that is not a detail**. `goal_spent_usd` is the aggregate above and carries exactly
`(owner, project, stack, goal)`; `goal_budget_usd` is *scraped*, so it also carries the seven
target labels (`pod`, `instance`, `job`, …). A plain binary operator matches on the FULL label set
of both sides, so the two never paired: both derived rules evaluated to **nothing, for every goal,
from #209 until homelab#348** — while the registry table beside the gauge, which reads the two
families separately, looked healthy. Silent in the #312/#330 way, because an expr that evaluates
to nothing is indistinguishable from a condition that is not happening. Both rules now collapse the
scraped side with `max by (owner, project, stack, goal) (goal_budget_usd)` — preferred over an
explicit `group_left ()` because a single-replica rollout **surges** to two Ready pods, and two
series in one match group would be a duplicate-match error that records nothing at all. Behaviour
is pinned in `agent-goals.promtool-test` (with the pre-#348 exprs kept runnable as a regression
witness and asserted empty), and the fixture's copy of the three rules is drift-pinned by
`devbox run exporter-self-test`.

**A budgeted goal with no ledgered spend stays ABSENT from both derived series** — decided in
#348, not inherited. homelab#278 is the live case: a `$60` budget and no `goal_spent_usd` at all,
because every one of its rides was `claude/haiku` on the subscription rail, which pushes
`agent_run_total` but no `agent_run_cost_usd`. An `or vector(0)` default would render that as 0%
burn, and this rule cannot tell a subscription-rail goal from one whose cost pushes were **lost**
(the FU-131 harvest gap) — while [`agents/goal-budget.sh`](../../agents/goal-budget.sh), the
arithmetic that actually gates a dispatch, prices the LOST-push state *fail-conservatively* at
the child's full cap. (Since retro r8 F2, 2026-10-12, the gate itself does tell the two apart:
a ride that pushed `agent_run_turns`/`agent_run_tokens_in` and no cost series is a subscription
ride, settled at $0; only a ridden child with nothing in the ledger is cap-charged.) A panel
printing 0% for a state the gate may price at maximum would put the two in contradiction on one
screen. The goal still appears in the registry **table** (that reads `goal_budget_usd`
directly); it is only the derived gauge that has nothing to say.

**Panel:** `agent-goals` (Grafana uid `agent-goals`), shipped as a ConfigMap beside the collector
in `argocd/resources/github-exporter/` — not in `tofu/dashboards/`, which needs a `for_each` entry
and an operator `tofu apply` per dashboard. Registry table → the goal issue; tree table → the
existing per-issue `$` drill-down.

**Two honesty signals, on the panel by design.** `goal_tree_truncated=1` means that repo has more
issues than the exporter's `GOAL_ISSUE_WINDOW`, so a long-untouched descendant can be missing from
the counts; `goal_query_supported=0` means GraphQL rejected the goal walk and the exporter latched it
off for the process, so the goal series are **absent rather than wrong**. The goal walk is its own
request, separate from the load-bearing PR walk (split 2026-09-25 after the combined query hit
GitHub's per-query resource ceiling and took the PR series down), so a goal-side failure costs the
panel, never review dispatch. A page that hid either would report a partial tree as a whole one, which is the
FU-125/FU-108 failure class this platform keeps paying for.

**The gate:** `python3 argocd/resources/github-exporter/github-exporter.py --self-test` — the
descendant walk, budget parse, verdict precedence and membership emission against a recorded tree
(goal-174's 3-generation shape + circles#17), inside the shipped module, the `router-self-test`
pattern.

## Part A⁗ — channel separation: what belongs on a timeline (ADR-103 rule 2, homelab#210)

The 2026-08-09 census found **~2/3 of issue-timeline comments on oracle-fleet/circles were machine
residue**, and the two biggest per-PR offenders were the run-stats table and the "picking this up"
dispatch notice — each posting a *new* comment every round. The bar ADR-103 sets: **a new PR shows
the review verdict plus at most ONE machine comment.**

Three channels, and which one a fact belongs on is decided by **who reads it**:

| channel | carries | why there |
|---|---|---|
| `agent-ride` **check-run** (`neutral`, on the PR head SHA) | the run-stats table, the cost line, the Grafana logs link, the transcripts pointer | markdown output, the checks tab a reviewer already opens, and nothing competing with human conversation. Chosen over a commit status: a status carries no body |
| ONE `<!-- agent-summary -->` **comment** per issue/PR, edited in place | one appended line per machine event — dispatch, stats, deferral | the index. History is append-only *inside* one comment, so round 2 edits what round 1 wrote |
| **stores** — `AGENT_STRIKE:` comments, the `state-fp:` debounce marker | load-bearing state other clauses grep | explicitly NOT residue. They move later, replay-first; a line a reader would break on is not residue |
| ONE `<!-- agent-budget-refusal -->` **comment** per GOAL, edited in place | the launcher pre-flight's goal-budget refusal — Σ(spend + reservations) vs `Budget:`, and the per-child cap table under it | it fits neither channel above: the index takes one appended LINE per event and this refusal is level-triggered (a line per scan), and the check-run needs a head SHA that does not exist yet — the pre-flight refuses before any branch. So: its own marker, re-edited as the numbers move, and **no write at all** when they have not (homelab#361, `fixtures/goal-budget-refusal-*`) |

One implementation for the first two: **`agents/machine-comment.sh`** (`mc_event`, `mc_check_run`),
called by `agent-session.sh`'s fallback bookkeeping and by the coordinator brief's claim step. Two
copies would drift, and drift here is silent.

**The appended entry carries a machine marker** — `<!-- agent-event kind=<kind> ts=<iso> -->`,
invisible in rendered markdown. It exists because *"one completed round = one more comment"* was
load-bearing for three readers in `coordinator-scan.sh` (the no-op predicate, the per-PR `attempts`
counter, the issue-keyed ceiling) and one in `meta-throughput.sh`. Moving the table without moving
them would have counted **zero rounds**: the ci-red clause would never reach `RED_ROUNDS_MAX`, never
escalate to arbitrate, and re-dispatch the same red input forever — the FU-115 livelock, re-opened
from three files away. That is the standing trap: **enumerate the readers before you move a shape,
and state the negative for the ones you checked and cleared.**

The scan's `stats_ts` def reads **both** channels — a union, not a replacement — because the
primary emitter (`agent-finalize`, in-pod) converts in agent-runtime#62 while only the launcher
fallback converts here, so one PR can legitimately carry rounds in both shapes. Same reason
`meta-throughput.sh` matches both signature eras, and reads `updated_at`: an edited summary
comment's `created_at` is frozen at the first machine touch, so the old field would peg every later
round to the age of round 1 and manufacture a `THROUGHPUT-STALL` on a fleet that is riding fine.

**The gates:** `agents/replay/fixtures/summary-comment` (rows first-touch, append) pin the create-vs-edit
split and the append-only body; `fixtures/ci-red-rounds-two-channels` pins the mixed-channel round
count (one old-shape comment + two new-shape markers → `attempts=3`, not 1).

## Part B — the retro loop (reflex + judgment, per the standing doctrine)

### B1. retro-facts reflex (deterministic, every 30 minutes — P2)

Moved to [agents/islands/retro/docs/retro-loop.md#the-activity-collector](../../agents/islands/retro/docs/retro-loop.md#the-activity-collector) (the 30-minute activity collector and the windowed ledger slice; the retro island owns it — contract in [`agents/islands/retro/specs/`](../../agents/islands/retro/specs/README.md)).

What stays below is the ledger EMITTER contract the retro consumes (`agents/ledger.py`, shared with the scan and the dashboards).

**Row schema (r4 F4/F5, homelab PR#454 — `agents/ledger.py`):** `rounds` is the per-round ARRAY
`[{model, exit_status, error_class, ci}]`, round-ordered and strike-only entries included; the flat
`models` / `worker_exit_statuses` / `ci_sequence` fields are DERIVED from it order-preservingly
(older rows carried `models` as a de-duplicated set, which made `zip(models, exit_statuses)`
unsound — do not re-derive a set from the array). A row stamped while the issue was still OPEN
carries `snapshot: true`; this describes its observation time, not a reason to exclude ongoing
work. Neither snapshot status nor a later merge excludes activity within the coverage window.
The legacy ranker still excludes snapshots for its historical callers; the new activity selector
does not use that ranker. Historical rows lack both fields; never silently treat undated
historical rounds as new events.

**Two additions from the 2026-07-09 runs (extend the AGENT_RUN_STATS schema, feed FU-057):**
- **`exit_status` + `error_class`** per run — clean / ci-failed / **harness-death** (goose
  `-32602` truncation) / **auth-storm** (401/403) / budget-403 / timeout. Without this the ledger
  sees cost+duration but not *why a run failed*, and the model-blacklist call is blind.
- **The model-health dashboard** is then a pivot over the ledger: **rows = model, columns =
  {success-rate, harness-death-rate, avg-duration, $/successful-issue}**. deepseek-v4-flash's 2/4
  death rate becomes one red cell — the blacklist signal, evidence not vibes. Pair with the
  live **running-agents** panel (pods by role×phase, from kube-state-metrics — already scraped) so
  "what's active + is anything stalled" is one screen.
- Worker **`cost_usd` must reach Prometheus** (today only in the Loki stats line) — cheapest path:
  agent-finalize pushes a labelled metric to the pushgateway, or the collector scrapes a textfile.
  Coordinator/reviewer cost is already in Prometheus via A0's OTLP `claude_code_cost` metrics.

### B2. retro session (LLM, batched async — P3; NOT per-tick)

Moved to [agents/islands/retro/docs/retro-loop.md#the-weekly-session](../../agents/islands/retro/docs/retro-loop.md#the-weekly-session) (the weekly session: window, findings disposition, cadence, acceptance, the split, the round container, cadence status; the retro island owns it — contract in [`agents/islands/retro/specs/`](../../agents/islands/retro/specs/README.md)).

#### The multi-model pilot — what runs 1–3 taught
Moved to [agents/islands/retro/docs/retro-loop.md#the-multi-model-pilot--what-runs-13-taught](../../agents/islands/retro/docs/retro-loop.md#the-multi-model-pilot--what-runs-13-taught) (the pilot cells, the run-3 shape, the gateway cells; the retro island owns it — contract in [`agents/islands/retro/specs/`](../../agents/islands/retro/specs/README.md)).

## Part C — the attention layer v1: derived-class export, board --machine, standing belt (#892)

**Leg 5 of container #628.** The scan classifies every issue/PR it sees; that classification was
consumed only as ephemeral report lines in workflow logs. This leg makes it consumable state.

### C1. Item class series (emitter)

`coordinator-scan.sh` now includes `item_class_push()` — a function that pushes
`agent_item_class{repo,item,class,who} = 1` and
`agent_item_class_since_timestamp_seconds{...}` to the pushgateway (job `agent_board`),
grouped per namespace exactly like `agent_scan_phase_*` (homelab#283). Group-replace per
tick: closed items drop off at the next tick, and a quiet tick emptying the group is not a
health signal.

**Class taxonomy (v1, low-cardinality enum):**

| class | who | meaning |
|---|---|---|
| `riding` | machine | A worker pod is actively riding this issue |
| `phantom` | operator | `agent/in-progress` with no live pod — reconciliation pending |
| `strike-held` | operator | C4/C5 goal-child held on strike evidence — undecidable state |
| `parked-blocked` | operator | `agent/blocked` — human-gated |
| `parked-infeasible` | operator | `AGENT_INFEASIBLE` — re-scope needed |
| `arbitrate-standing` | operator | Escalated to human — `agent/arbitrate` |
| `queued-held` | machine | Held by in-progress footprint |
| `queued-held-by-ghost` | operator | Held by a phantom/infeasible blocker — the blocker's liveness is the question |
| `queued-ready` | machine | Dispatchable — next tick |
| `deferred-capacity` | machine | Held by WIP ceiling |
| `footprint-held` | operator | Queued issue held by an in-progress issue's `Touches` (ADR-097 intersection) |
| `cap-held` | operator | Queued issue held by the per-base PR budget cap (`REPO_PR_CAP`, machine-flowing PRs only) |
| `blockpark` | operator | Queued issue held by the codeowner-parked PR budget (`REPO_BLOCKPARK_CAP`) |
| `ci-red-held` | machine | Armed red PR held by the ci-red clause's fleet-class hold — the red is master's or a sibling-ruled infra/environment fault (homelab#1909); releases when master greens / the 24 h window lapses |
| `guarded-path` | operator | Pin-only guarded path — operator push needed |
| `orphan-unarmed` | operator | Open PR not on merge path — arm or park |
| `container` | none | Post-launch bucket, container issue |
| `backlog-aggregate` | operator | Suitable-unqueued backlog (ADR-109: count + oldest, never per-issue) |

**Hold-chain propagation rule:** a `queued-held` item whose blocking item is itself
`who=operator` (ghost / merged-held / parked) becomes `queued-held-by-ghost`,
`who=operator`. A hold is only as legitimate as its blocker's liveness.

### C2. board.sh --machine mode

`board.sh --machine` renders the key=value line grammar from the derived classes in
Prometheus (never re-derives them board-side — the one-computer rule):

```
board v1 scope=stack:platform ts=<iso> sources=labels:live pods:live derived:tick@<iso>
who=operator class=strike-held id=homelab#833 pod=none since=7h30m next="verify goal branch, then close or re-queue"
who=operator class=queued-held-by-ghost id=homelab#834 since=7h30m note="held by phantom/infeasible blocker"
who=machine  class=riding id=homelab#889 age=6m
who=none     class=container id=homelab#840 note="post-launch bucket, container"
who=operator class=backlog-aggregate id=homelab/aggregate note="suitable-unqueued backlog"
```

**Rules:**
- One line per item; anchored key=value tokens (the `AGENT_STRIKE:` culture)
- Rows carry the join verdict + next action so no follow-up query is needed
- Stable sort: who, class, repo, item
- Freshness header is line 1
- `--scope goal:<n>` resolves tree membership from the exporter's `goal_descendant_info`
  series — never a fresh recursive API walk

**Prometheus endpoint:** in-cluster `http://kube-prometheus-stack-prometheus.monitoring.svc:9090`;
from the jail `https://prometheus.teststuff.net` — the script must work in both (env-picked,
the responder-runbook pattern).

### C3. The belt: AgentAttentionStanding

PrometheusRule `AgentAttentionStanding` — `who="operator"` rows standing > **4h**. Slow by
design: an active seat drains the board long before it fires; this exists only for the no-seat
case. The annotation links to the BIG PICTURE (the Grafana attention table, or
`board.teststuff.net` once leg 6 lands) — **never an individual issue**. Description is a
symptom, not a guessed cause. The `for: 1h` window is reset by deployments (pushgateway
redeploy silences the timer), accepted because the design is slow enough that a reset window
is tolerable.

### C4. Replay-pinned fixtures

Two fixtures commit the behaviour:

- **`item-class`** (actions mode): pins the `item_class_push()` function — the curl call,
  the metric names and labels, the group-replace URL, and the three degenerate paths (no
  gateway, no pod identity, gateway refuses). The fixture's bridge exercises the #833
  counterfactual (`held-merged-unlinked who=operator`), the #834 scenario
  (`queued-held-by-ghost`), a riding row, a container row, and a backlog-aggregate row.
- **`board-machine`** (suite mode): pins the `--machine` output grammar against a synthetic
  Prometheus response carrying the same five classes. Asserts the stable sort, the header
  line, and the absence of human board sections.

## Rollout

- **P0 (blocker)**: bucket + manifests + the three capture hooks. Fire coordinators after this —
  everything later can analyze retroactively *because* P0 captured the raw material.
- **P1**: viewer Deployment + PR-comment task link. **P2**: facts reflex + dashboard (FU-057).
- **P3**: retro brief + first hand-supervised run, then a CronWorkflow sibling of the review reflex (FU-058).
