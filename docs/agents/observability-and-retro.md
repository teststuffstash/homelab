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

## Today's persistence gaps (grounded 2026-07-08)

| Role | Transcript today | Survives pod? |
|---|---|---|
| coordinator | Claude Code JSONL on the `coordinator-transcripts` RWX PVC | **yes** (PVC) |
| worker (goose) | `/tmp/run.log` (tee'd stdout → Loki) + goose's own session file | **no** (Loki keeps stdout only; goose session lost) |
| reviewer | `--output-format json` single result; its `~/.claude` transcript | **no** |
| jail seat (2026-08-19) | Claude Code JSONL on the host bind-mount (`.claude-data/`), pushed by `scripts/jail-transcripts-sync.sh` (heartbeat + wind-down) to the **separate `jail-transcripts` bucket** | host + bucket — and the bucket is deliberately OUTSIDE the viewer/retro read set: jail transcripts can carry wallet VALUES, so no cluster role reads them (`agents/coordinator/jail-transcripts-workspace.yaml`) |

The irreplaceable artifact is the transcript. Everything else (dashboards, retros) can be built
*later* over captured data — **capture is the only blocker before firing more coordinators.**

## Prior art (searched 2026-07-08) — what the field converged on

- **OTel GenAI semantic conventions are the industry rail.** Claude Code itself exports
  metrics/logs via OTLP (traces in beta); Copilot/VS Code emit GenAI spans; Daytona v0.190.0
  ships an `otel-collector` app + audit logs + log streaming as its whole observability story.
  Standard spans/metrics land in any backend — for us, the existing Grafana stack.
- **Session replay is a product category** (AgentOps time-travel replay; Laminar transcript view +
  SQL-over-traces; **Langfuse** = the leading MIT self-hosted option: sessions, traces, scores,
  evals). Considered and **deliberately not adopted now**: self-hosted Langfuse needs
  Postgres + ClickHouse + Redis. Postgres is a non-issue (CNPG is LIVE — a per-app `Cluster` CR,
  SERVICES.md/ADR-046), but **ClickHouse + Redis are two new stateful platform services** for a
  one-person fleet, and transcripts' durable home should stay git+S3 (ADR-080). Bucket + viewer +
  Grafana covers the need; revisit only if analysis outgrows Grafana.
- **Turnstone** (self-hosted orchestration, Apache-2.0; assessed 2026-07-09): philosophical cousin
  (data-local, audit-in-own-DB). Adopted ideas: (1) **graduated autonomy** — advisory verdicts with
  auto-action only above a confidence threshold (their `smart_approvals`, 0.95 default) → the P3
  autonomous-merge flip becomes a dial (reviewer emits recommendation+confidence; auto-merge ≥
  threshold, low-confidence approvals route to the human); (2) **verdicts as persisted structured
  objects** stamped with the final human decision (their `intent_verdicts`) → the FU-057 ledger
  schema, incl. `llm_fallback`-style "failed judge still emits a marked verdict"; (3) their
  critical/high **heuristic rule pack** as a PreToolUse hook for bypassPermissions contexts
  (coordinator + meta-sessions), NOT workers (pod scope is the boundary). Rejected: judge-is-the-
  session-model self-consistency (weaker than our decorrelated reviewer); HRW workstream routing
  (track labels already assign deterministically, with semantics).
- **Devin productized exactly our Part B**: *Session Insights* (analyzes completed sessions →
  actionable recommendations) + *Knowledge* (org-wide lessons, **user-approved before they
  persist**) + *Playbooks* (successful sessions distilled into reusable procedures). Their
  approval flow = our PR-gate; their playbook idea is adopted below (B2.5).

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

Before optimizing, measured issue #1's ~4 wall-clock hours (Loki timestamps + AGENT_RUN_STATS +
pod lifetimes). **The assumed bottleneck — docker/nix cold-start — was NOT it**: `/nix` is
bind-mounted and warm on the node, so clone + `devbox install` was **~6s** every round after the
first. Ranked reality:

1. **Broken reflexes stalling invisibly — ~2h23m** (reviewer blocked 07:13→09:36 by the
   sleep-hardcoded repo list + reviewer-token scope, both fixed live). The single biggest sink,
   and the reason the loop was un-followable — *nothing visibly happened*. **This is why monitoring
   IS the speed fix**: a "reviewer idle N min with a green PR waiting" panel turns a 2.5h silent
   stall into a glance. Highest-leverage speed work = FU-057, not caching.
2. **Orchestration latency — ~50 min** (then a 5-min review-reflex cron + manual meta-ticks + CI
   cycles). The documented levers apply: hot-tick + CI-green→coordinator ping + webhook edge-trigger
   ([workflow.md](workflow.md) §Triggers). Since ADR-093 the review path is **event-driven**
   (near-instant edge + `*/15` backstop — machinery home: [`roles.md`](roles.md) §reviewer /
   [`merge-path-fsm.md`](merge-path-fsm.md)). Real but second-order.
3. **The model — ~48 min of pod compute** (deepseek-v4-flash: 400–1170s LLM loops, and 2 of 4
   rounds *died* to truncation/retry-storms). Cheap per token but slow (many round-trips) and
   error-prone → slow AND wasteful per *successful* issue. The model-health dashboard (below) makes
   the blacklist call data-driven; FU-021 (retry hard-stop) stops the storms.
4. **Cold-start — ~0** (warm nix). The docker-image caching backlog item would not have helped
   these runs; deprioritize it relative to 1–3.

**One-line takeaway:** the loop wasn't slow because of infrastructure — it was slow because it was
*invisible* (stalls) and *dispatched to a weak model*. Both are monitoring/model problems, not
caching problems.

**Both measurements above are ARCHAEOLOGY**, reconstructed after the fact from Loki timestamps and
pod lifetimes, and the second one ([`spikes/ride-latency-breakdown.md`](../spikes/ride-latency-breakdown.md),
2026-08-09) hit the wall that shape always hits: its most useful question — was that pod's image
node-cached? — was unanswerable, because the events had aged out. Since 2026-08-11 the launcher
emits `agent_run_phase_seconds{phase=dispatch-gates|pod-spinup}` per ride to the
same pushgateway as `agent_run_*` (FU-160, homelab#287), and `agent-finalize` adds the ride's
interior to the same metric under `source="in-pod"` (agent-runtime#66), with a breakdown panel on
the `agent-issue` dashboard and the `AgentRunPhaseSlow` deviation alert behind it. The launcher's
list ends at pod-Ready because the launcher itself usually does not outlive the ride (homelab#324).
Phase list, what each one covers and what it deliberately does not live in the spike; this
paragraph is the pointer.

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
- **`AgentCoordinateScanWedged` measures the wrong thing** (FU-145 points here). It keys on scan-pod
  LIFETIME, but the pod blocks on the item session it dispatched, which STREAMS THE RIDE
  SYNCHRONOUSLY: verified live inside `coordinator-081840`, **PID 512 = `kubectl -n circles logs -f
  agent-circles-issue-30-r1`** (the session's own log: *"the dispatch call itself streams the full
  worker run synchronously"*). Measured: scan pod 18m32s, session 18m03s, alert at 15m.
  So it fires on any dispatch whose ride runs >15m, on every stack — seen twice in one hour (the
  decompose, then #30's ride), both healthy, both self-resolving.
  ⚠ Say "streams the ride", not "waits for the whole ride": `coordinator-081840` EXITED at 08:36:44
  with `agent-circles-issue-30-r1` still Running (~16m of ride left). The session rings its doorbell
  on ITS OWN completion, so nothing is orphaned — but it means the alert's duration tracks the
  session's stream, not the ride, and the two are not the same. Why the stream ends early is still
  open; it did no harm here because the ride finished, the PR opened, and the reviewer's own
  doorbell carried the chain forward.
  **A pod-lifetime probe cannot measure a phase that blocks on downstream work** — Part A′ finding
  #1's class again: an alert whose subject is not the thing it names.
  **Fix:** key it on the deterministic scan phase. ⚠ Not by raising the threshold (blinds ordinary
  ticks) and ⚠ not by special-casing `goal-decompose` — that was the first diagnosis here, made
  from the pod's lifetime before the blocking `logs -f` was found, and it is wrong: the cause is
  lane-independent. ⚠ The p99=302s / 1-in-2474 calibration behind `fc7e9fb` measured lifetimes
  from before the alert existed; it is not evidence that long scans are rare.
  **SHIPPED 2026-08-11 (homelab#283).** `coordinator-scan.sh` publishes the phase it is in —
  `scan_phase dispatch` immediately before each `coordinator-session.sh` call and
  `scan_phase deterministic` on the way back — as two pushgateway gauges
  (`agent_scan_phase_start_timestamp`, `agent_scan_in_deterministic`; job `agent_scan_phase`,
  grouped by NAMESPACE with the pod as a metric label, so a group cannot leak per scan and the
  `coordinator-scan` mutex is what keeps one writer per namespace). The alert became two branches:
  no marker → pod lifetime, which is still exactly right *because* the phase has not ended yet and
  is the branch that catches a wedge dying before the script runs (the 2026-08-05 clone shape);
  marker saying deterministic → the clock restarts at the phase, never at the pod. The threshold
  stays 900s — the subject moved, not the calibration. Behaviour is pinned as an executed replay
  (`agents/scan-wedge-alert-test.sh` + `agents/replay/fixtures/scan-{wedge-alert,phase-marker}`),
  which reds on the pre-#283 expr; the two remedies above stayed ruled out.
  **Second symptom of the SAME cause, and the more consequential one (2026-08-06):** the
  `coordinate-<stack>` CronWorkflow is `concurrencyPolicy: Forbid`, so a long-lived scan pod
  SUPPRESSES the cron tick. Measured: `lastScheduled=09:00:00Z` produced no pod, because
  `coordinate-perstack-9sltw` had been Running since 08:59:37. **The level-triggered backstop is
  therefore disabled exactly while a ride is in flight** — i.e. whenever a doorbell failing would
  actually cost something. Edges have been reliable so far, so nothing is broken today; but this is
  what would turn ONE missed doorbell into an indefinite stall instead of a ≤30-minute one, and it
  is the same silent-in-three-directions shape as FU-143. Fixing the alert's key (scan phase, not
  pod lifetime) does NOT fix this half — the pod really is alive; the dispatch would have to stop
  holding the scan pod open, or the cron stop being `Forbid`.
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
arithmetic that actually gates a dispatch, prices that same state *fail-conservatively* at the
child's full cap. A panel printing 0% for precisely the state the gate prices at maximum would put
the two in contradiction on one screen. The goal still appears in the registry **table** (that
reads `goal_budget_usd` directly); it is only the derived gauge that has nothing to say.

**Panel:** `agent-goals` (Grafana uid `agent-goals`), shipped as a ConfigMap beside the collector
in `argocd/resources/github-exporter/` — not in `tofu/dashboards/`, which needs a `for_each` entry
and an operator `tofu apply` per dashboard. Registry table → the goal issue; tree table → the
existing per-issue `$` drill-down.

**Two honesty signals, on the panel by design.** `goal_tree_truncated=1` means that repo has more
issues than the exporter's `GOAL_ISSUE_WINDOW`, so a long-untouched descendant can be missing from
the counts; `goal_query_supported=0` means the exporter fell back to its pre-#209 GraphQL query and
the goal series are **absent rather than wrong** (that fallback exists because the goal fields ride
a load-bearing query — losing the panel is a degradation, losing review dispatch would be an
outage). A page that hid either would report a partial tree as a whole one, which is the
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

**The gates:** `agents/replay/fixtures/summary-comment-{first-touch,append}` pin the create-vs-edit
split and the append-only body; `fixtures/ci-red-rounds-two-channels` pins the mixed-channel round
count (one old-shape comment + two new-shape markers → `attempts=3`, not 1).

## Part B — the retro loop (reflex + judgment, per the standing doctrine)

### B1. retro-facts reflex (deterministic, per terminal task — P2)

No LLM turn. When a task reaches a terminal label (`agent/done`/`agent/blocked`), compute from
manifests + stats and append one line to a durable ledger (`agent-transcripts/_ledger.jsonl`):
cost vs estimator band (**calibration error**), rounds used, retry storms (the 812×-403 class),
CI red/green sequence, review flip-flops, wall time, cache-hit %, requests, tokens/request.
Grafana dashboard over the ledger = the long-promised stats v2 (**FU-057**). These numbers are also
the KPI set the retro measures itself against: cost/issue, rounds/issue, blocked rate, estimator
error.

**Row schema (r4 F4/F5, homelab PR#454 — `agents/ledger.py`):** `rounds` is the per-round ARRAY
`[{model, exit_status, error_class, ci}]`, round-ordered and strike-only entries included; the flat
`models` / `worker_exit_statuses` / `ci_sequence` fields are DERIVED from it order-preservingly
(older rows carried `models` as a de-duplicated set, which made `zip(models, exit_statuses)`
unsound — do not re-derive a set from the array). A row stamped while the issue was still OPEN
carries `snapshot: true`; the retro's pain-rank excludes those rows and counts the exclusion
(`agents/retro-rank.py`). Historical rows lack both fields.

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

A budget-capped scheduled session (weekly, or every N terminal tasks) with a seeded brief:

1. Read the ledger; pick the worst-K tasks by cost-over-estimate / blocked / max-rounds (and one
   *good* run as contrast).
2. Pull transcript slices via the MCP tools; root-cause each: where did the agent loop, misread,
   lack a fact the issue should have carried, fight a tool, retry into a wall?
3. Emit ONLY through existing seams:
   - a dated **retro report in git** (`docs/agents/retros/<date>.md`) — durable, reviewable;
   - **PRs editing the process files** — `fix.yaml` instructions, `review.md`, the coordinator
     `TICK_PROMPT`, `estimate_budget.py` bands, issue templates. These paths are human-gated, so
     the system proposing changes to its own process stays behind a human read — the "spec is
     grown" principle applied to the process itself;
   - follow-up issues for platform gaps.
4. **Score the previous retro first**: each report opens by checking the ledger KPIs across its
   predecessor's merged changes (did rounds/issue actually drop?). Self-improvement that measures
   itself; no vibes.
5. **Distill wins, not just failures (the Devin-playbook move).** When a run lands notably under
   estimate / first-round-approved, the retro may extract the reusable procedure into the recipe
   or a skill file — same PR gate. Codifying what worked compounds faster than only patching what
   broke.

Guardrails: own budget-capped OpenRouterKey; read-only everywhere + PR-only writes; max-K
transcripts per run; may touch **process files only** — never product repos' `specs/` (spec
evolution belongs to the fixer/human loop, not the retro).

Why not per-tick: the tick must stay cheap and decision-free (level-triggered reconciler);
retro insight has no latency requirement; batching amortizes the context cost of reading
transcripts. The per-task hook is only the deterministic B1 reflex.

**Ownership (ruled 2026-07-25, operator): the retro is a PLATFORM capability, initially
homelab-resident, graduating per-stack like the rest of AgentStack.** Mechanism = platform:
the brief template (`docs/agents/retros/BRIEF.md`), the cross-review contract
(`CROSS-REVIEW.md`), the launcher (`agents/retro-session.sh`), and the output/report
conventions are homelab-owned; reports land in `docs/agents/retros/` via PR. Policy = stack:
which ledger slice, cadence, and model cells. Today running (or skipping) a stack's retro is
an operator/platform decision; the graduation target is an AgentStack claim knob (e.g.
`retro.enabled` + cadence), at which point a stack opts in/out in its own `-iac` repo and its
reports move stack-side — the standard mechanism/policy split (platform-and-stacks.md).
teststuff (Forgejo) is NOT in the retro's access set — no Forgejo key minting exists and none
is needed for this.

**⚖ THE SPLIT (operator ruling, 2026-08-17, from the r4 evidence): the retro divides into the
PLATFORM retro and per-stack retros — built in that order.**

1. **The platform retro FIRST — BUILT 2026-08-19 (the #587 [stint](chainless-redesign.md), legs on #588/#589/#590/#591).**
   r4 ("oracle r4", PR#454) proved the shape: the pain-rank reads the WHOLE `_ledger.jsonl` with
   no stack filter, the worst-K landed on circles/homelab/openrouter-operator/sleep rows while
   oracle sat quiet, and every finding targets a PLATFORM artifact. That is correct, not a bug —
   **structural problems require looking into the stack repos; no way around it** (operator).
   As built: the workflow's `stack` param defaults `platform` (series `platform-rN`, ride ns =
   [the platform stack](agentstack.md)'s fixer ns via `agents/retro-project.sh` — the ONE stack→ns map, shared
   with the guard, whose busy-probe now checks only the ride namespace: WIP-slot locality);
   ACCESS tracks the questions — a fleet-wide READ-ONLY `retro-git` token (App-minted, delivered
   by the FU-080 (a) mirror pattern, never as manifest text — PR#619) reaches the ride as
   `RETRO_GH_TOKEN`; the jail-$/day KPI LEFT the brief (route-or-drop ruled DROP — its home is
   the operator's Grafana subscription/gometer dashboards, and the query was dark from the pod
   on every run).
2. **Stack retros SECOND, their briefs authored AGAINST the platform retro's coverage** —
   deliberately non-overlapping: stack-local concerns only (recipe quality, spec adherence,
   the stack's own model cells), never the cross-cutting classes the platform retro already
   owns. Graduation stays the AgentStack claim knob (`retro.enabled` + cadence + slice) as
   ruled 2026-07-25; the non-overlap contract is authored INTO the stack brief template when
   the first stack graduates, with the platform reports in hand.
   **⚖ PRIORITY FLIPPED (operator, 2026-09-01): stack retros are wanted MORE than further
   platform rounds** — stack goals carry the deeper business logic and kind-e2e testing
   complexity, and their dynamic differs from the platform's machinery-defect stream. The
   platform series continues on its cron as the baseline; build effort goes to the first
   stack graduation. Same-ruling cost note: reviews cost more than worker rounds
   (chainless-redesign.md cost-rethink direction 4's ROI sequencing), so retro attention
   ranks by the cost model (PR#1127), not by worker-round counts.
   **Seeded headline for the first stack brief (same sitting):** does the cheap-worker tier
   create more CHURN on stack work than on platform work — review rounds + seat-fix
   interventions per merged issue, total-cost ranked? The hypothesis's shape, stated for the
   brief to test rather than assume: platform work is mostly jail-built on strong
   pre-existing context (argo/k8s — mainstream, well-documented); stack workers do custom
   NEW development, wiring components without the big picture in their build context — and
   the seat has already fixed defects neither worker nor reviewer caught (unmeasured;
   teething-era instructions). Second seeded question, from the riigiteataja sighting
   (research-and-specs.md §Research precedes the Goal): how much of the ranked pain is
   UPSTREAM of the workers entirely — contract-unknowns a recon mission would have removed?

The two r4 lane defects shipped with the same wave (PR#620): the cell report-marker self-check
now runs a ≥20-content-line floor via `agents/retro-report-floor.sh` (ONE helper, three callers
— self-check, harvest, `--review`; caller-declared `log|report` mode so a marker-less raw
transcript can never pass as a report), and the swapped-cell cross-review refuses an
under-floor report before dispatching a paid ride at it.

**A retro process change with a platform half and a per-repo half files as one issue PER
repo, never as a clause delegated to "the next recipe touch" (r4 F3).** The contrast is
measured: every r3 change that got its own per-repo issue landed within a day (circles#77/
#78); the one delegated to "the next recipe touch" was missed by that very touch (#257's
recipe half — commit 8bc4ecb edited the exact file and did not carry it).

**A round's process-change batch binds under ONE round container — stint-kind (operator
ruling 2026-08-26, homelab#949 is the shape).** A retro round is epic-shaped: a bounded
original set (the report's batch), a possible defect tail, and a natural closeout moment.
Whoever files the batch (the seat today; the harvest shell if the lane ever self-files)
mints a label-inert parent (`retro-batch: <series>-rN` — never `task/goal`, never `agent/*`)
and binds each filed issue as a native sub-issue; the children still ride their own lanes
individually. The lineage contract's rules apply unchanged
([issue-authoring.md](issue-authoring.md) §The lineage contract) — a defect in a batch fix
binds to the round, and close = tree-empty at a sweep. The closeout READ is free by
construction: the next report's predecessor-scoring (step 4 above) already judges the batch,
so the sweep after it is the earliest close. r1's batch was bound retroactively (#949);
"standalone (retro process-change batch)" body lines are superseded by the container from r2 on.

**Cadence status (corrected 2026-08-11):** unsuspended 2026-08-03 — but the lane had NEVER run
end-to-end until 2026-08-11: five latent bugs (guard busy-probe read kubectl's stderr as pods;
missing `AWS_REGION` in tsenv; harvest artifacts root-owned; a whole-ledger 146KB brief blew the
128KiB per-argv cap; `tee` ate cell death), each one step deeper, each invisible until the prior
one fell — the "unsuspended ≠ ever ran" class, caught by the FU-058 belt's first firing. Run 3
delivered 2026-08-11 (hand-fired, SINGLE cell — cell-b died pre-ride misclassified clean,
homelab#248; report merged: `retros/2026-08-11-oracle-r3-context.md`; its process-change batch
filed+queued: homelab#256-259, circles#77/#78, oracle-fleet#258). **2026-08-17 = the first
unattended fire, and it FIRED** (PR#454: the opus cell delivered a full report — predecessor
scoring, three new ledger blind spots, a proposed replay gate; the deepseek cell delivered an
empty template, the self-check gap in §The split); the swapped-cell cross-review is still
unrun and must skip the empty report. Standing lane bounds from the
first real pass: the brief is a bounded worst-K ledger slice (never the whole ledger), and the
cell pipeline runs `pipefail`. **The platform-series build wave landed 2026-08-19** (the #587
stint: rename + ride-ns guard #623, fleet read token + KPI drop #619, content floor #620,
RetroReportOverdue restart-gap hardening #623). The first unattended platform fire (Mon
2026-08-24) FAILED (the 529 storm + the #861 cell-model collapse, fixed PR#864); the re-fire
DELIVERED platform r1 2026-08-25 (PR#918; batch #927–#932) — the clean unattended acceptance
is the Mon 2026-08-31 cron (FU-058). Remaining FU-058 legs: ledger emitter gaps (brief-v2(b) +
r4's three blind spots), MCP transcript slices, stack retros second (§The split point 2).

#### The multi-model pilot — runs 1+2 (2026-07-25) and what they taught

The retro was chosen as the **first multi-large-model tryout** (operator direction 2026-07-25):
N models over the SAME worst-K ledger slice in parallel, then a **cross-review** round where each
critiques the others' reports and the human reads the critiques. It is the safest arena for it —
read-only inputs, human-gated outputs — and the task shape is the FU-095 reasoning/audit tier,
where dual-model spend is ruled worth it. v1 needed **no MCP transcript tools**: ledger + issue/PR
stats + strike comments sufficed, reusing model-scout's ephemeral capped-key mint.

**Runs 1+2 are done** (`retros/2026-07-25-*`): mechanism proven, 9 models compared repo-verified,
cross-review landed with a deepseek-v4-pro critic. Routing data harvested for FU-095:

| Cell | Verdict |
|---|---|
| deepseek-v4-pro, hy3 | the **audit tier** — opus-adjacent grounding at $0.02–0.08 |
| kimi | useful **wide-net second reader** |
| gpt-oss-120b, nemotron-super | **fabricators** on evidence work — do not use for audit |

**Brief v2, from runs 1+2 evidence:**

- **(a) ✅ done 2026-07-25** — run-1's brief was recovered verbatim from the transcript bucket and
  committed as [`retros/BRIEF.md`](retros/BRIEF.md) (v3 template: ledger-blind-spots block,
  harness-source excerpts, task-granularity / wins / predecessor-score sections), plus
  [`retros/CROSS-REVIEW.md`](retros/CROSS-REVIEW.md) and `agents/retro-session.sh` (assembles
  per-cell, delegates to `agent-session.sh --harness/--model`).
- **(b)** The cross-run "could not verify" items are mostly **ledger gaps, not access gaps** —
  `reviewer_rounds=0` despite real review rounds, `wall_time_s` not decomposed active/idle
  (contradicted by PR lifetimes), `retry_storms` taxonomy undefined, haiku cost $0.00-vs-untracked
  ambiguity. **Fix the emitter before adding tools.**
- **(c)** Give the retro **read access to the harness source it is asked to improve**
  (`coordinator-scan.sh`, `estimate_budget.py` excerpts in the brief, or a homelab checkout): 6/9
  models flagged naming-targets-they-cannot-read, and the fabricators invented APIs exactly there.
- **(d)** Add a **task-granularity** section to the report contract: *"which of these worst-K tasks
  should have been ONE bigger-model task (or a subagent fan-out) instead of chunks; which chunks
  needed rework at integration."* Operator hypothesis to test either way: a large model + subagents
  might one-shot a project this size in ~48h.

Prometheus/Grafana access is **not** needed yet — no report was blocked on metrics.

**Run-3 shape (operator direction, composition-axes frame — AS DESIGNED; as-run 2026-08-11 only
cell A executed, homelab#248):** two retro rides off the SAME
agent-base image and the SAME committed `BRIEF.md` — **A** = claude harness + opus (subscription
via the ADR-081 proxy, FU-088-gated), **B** = goose harness + deepseek-v4-pro (ephemeral capped
key, provider-pinned) — then cross-review with the **cells swapped** (A reviews B's report, B
reviews A's). Tooling parity is already structural: agent-base ships `claude-code@latest` alongside
goose/opencode plus the full toolkit (gh/git/jq/python/uv/kubectl/s5cmd), so retro-er and reviewer
are freely mixable. Rotating cells run-over-run separates **harness effect from model effect** on
the FU-057 ledger axes — which doubles as FU-095(b) evidence. Repo scope for the retro token = the
stack jail's REPOS boundary (`tools/stack-jail.sh`: oracle-fleet, oracle-iac,
allure-behavior-snippets), read-only, App-minted. Standing guardrails: outside the fixer ns / WIP
slot (the P3 constraint), `GOOSE_MAX_TOKENS=16384`, reports land in `docs/agents/retros/` via PR,
and **each OpenRouter cell rides an ephemeral key it mints itself** — `retro-session.sh` applies an
`xs`/$0.25 `OpenRouterKey` per (run, cell) and refuses the ride if the operator does not stamp it
(homelab#270). The cap is the lane's own measurement (an audit-tier cell costs $0.02–0.08, table
above) × the estimator's ×2.0 buffer, not `estimate_budget.py`'s band — that band models a fixer
round and sizes a retro brief at ~$0.54/tier `lg`, which would cap nothing. The `$0.05 key floor`
run 1 taught is subsumed: $0.25 is the smallest tier there is. Before #270 the key was an operator
step with a warning behind it, and the ride fell back to the stack FIXER's standing budget key —
which is what run 3's dead cell-b spent 8 seconds of a provider retry against (homelab#248).

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
