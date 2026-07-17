# Agent workflow — issue → tested PR → merge

> **Status: running hand-driven (2026-07).** The *substrate* (scoped pods, recipes, scoped tokens,
> branch protection, stats) is LIVE — see [`README.md`](README.md) and
> [`../../agents/README.md`](../../agents/README.md). The **coordinator**
> ([`../../agents/coordinator/`](../../agents/coordinator/README.md)) now runs as the durable,
> self-running reconciler described below — Argo CronWorkflow reflexes (ADR-093, FU-026 archived),
> per-stack autonomy via the FU-080 claim knobs. Pivotal choices → thin ADRs
> in [`../adr.md`](../adr.md).

The end-to-end goal (from [`README.md`](README.md)): a triaged issue becomes a tested, auto-merged
fix. This doc is the *control flow* that gets it there — who runs the agent, when, and how review and
CI feed back. The last leg — how an approved green PR deterministically lands on master (branch
updates, review dispatch, auto-merge; no LLM in the mechanics) — is designed **and built** separately
in [`merge-path.md`](merge-path.md) (FU-041): a per-repo updater workflow keeps the head-of-line PR
current, and the **review reflex** auto-dispatches the reviewer when a PR is green + current +
unapproved — so the mechanical "trigger the reviewer" step below is now a reflex, not a coordinator turn.
Since 2026-07-17 (ADR-093) that dispatch is **event-driven**: the github-exporter POSTs the reviewable
PR to an Argo Events webhook → Sensor → `review` WorkflowTemplate (the reflexes are Argo CronWorkflows
now, not k8s CronJobs, with a `*/15` backstop) — near-instant instead of a poll.

## Two gates, not one

The most important distinction (a real run conflated them and shipped red CI):

- **Gate A — the worker's own pre-merge contract.** The agent runs `devbox run ci` to green +
  `scan-secrets` **before it opens the PR**. This is *in-session, always*, encoded in the recipe
  (`fix.yaml` `retry.checks`). An agent must never surface a PR that fails its own checks.
- **Gate B — post-PR iteration** (human review comments, or server-only CI). The worker does **not**
  block on this. It runs to a terminal state and dies. A review round is a *new invocation* of the
  same pure function: `(repo@base-sha, issue, PR + review thread + CI results) → updated branch`.

## Worker = a pure function; default fresh, not hot

The worker pod is ephemeral by design (the only seam is git: clone → branch → push). Keep it that
way — **do not** hold a session "hot" waiting for review/CI:

- **Latency mismatch** — review/human feedback arrives in minutes–hours; a pod held that long is
  idle liability that dies (and loses context) on a node reboot.
- **Context rot** — a finished session is full of dead-ends; a fresh session re-reading the PR +
  comments from clean usually produces a *better* diff (same reason we compact).
- **Determinism / boot-from-git** — each PR update being a reproducible invocation with fully
  captured inputs beats a stateful long-running brain.
- **Cold-start is the only counter-argument, and it's being eliminated** — the nix cache + baked
  toolchain (see [`../../agents/README.md`](../../agents/README.md)) make a fresh pod cheap. The
  caching investment and the "always re-invoke fresh" model reinforce each other.
- **Incremental push enables cheap resume** — the worker pushes its WIP branch after the RED commit
  and each green step (`fix.yaml`), so a mid-run failure (budget / rate-limit / crash) leaves a
  recoverable branch the next round resumes from instead of re-deriving (a real run spent $5.79 and
  left zero artifact for lack of this).

The one narrow case for "hot" — a fast server-side check that comes back red seconds after PR-open
while the pod is still up — is a deferred micro-opt (a short grace window), not a design pillar.

**The coordinator has an analogous micro-opt: the hot tick.** For a task the budget-banding
predicts as small, the coordinator session that spawned the worker MAY linger (bounded — one
CI-cycle timeout, ~30 min) and see the whole worker → CI → review → merge cycle through in the
same session, so the terminal verification runs with warm context of *why* the fix was dispatched
instead of a fresh tick re-deriving it. Two hard rules keep it an optimization instead of a second
architecture: (1) **watch and nudge, never dispatch** — the hot session may edge-trigger the
reflexes (wake the review cron early, poke the updater) but never runs mechanics itself, or the
per-repo review serialization breaks ([`merge-path.md`](merge-path.md)); (2) **correctness never
depends on the session surviving** — everything it does lands in durable state, so if it dies or
times out, the next level-triggered tick finishes identically. Waiting is cheap (a blocking watch
burns no tokens between wakeups); the real floor is CI (~8–20 min), not the worker or the review.

## The coordinator = a level-triggered reconciler

The coordinator holds **state, never agent context** — workers are disposable hands. Same shape as
the `openrouter-operator` (kopf): reconcile "an issue being worked" toward "merged." It reads
freely (`gh`, `kubectl get`, Grafana/MCP — discovery is not mutation) and is the **tie-breaker**
when worker and reviewer disagree; its own writes are coordination state only (labels, comments,
issue/PR lifecycle). Code, approvals, and merges are always delegated (ADR-079), and decision-free
transitions run as deterministic reflexes without an LLM turn
([`merge-path.md`](merge-path.md) §Reflexes vs judgment).

```
triaged (labelled, has repro + synthetic data table)  → spawn worker (round 1)
pr-open                                                → await CI + review
pr-behind-master                                       → updater reflex brings it current  (merge-path.md)
ci-green + current + unapproved                        → review reflex dispatches the reviewer  (merge-path.md)
ci-red | changes-requested                            → spawn worker (round N+1, fresh, PR+comments in)
ci-green + current + approved                          → GitHub auto-merge completes  (the NL→auto-merge goal)
cant-repro | max-rounds-exceeded | review flip-flop    → coordinator tie-breaks / escalates to a human
```

Spawning a round = the existing `agents/agent-session.sh` mechanism (→ an `agent-sandbox` `Sandbox`
CR once that lands, ADR-078/081).

### Capacity gates — a tick vs a hot subscription (FU-088, 2026-07-17)

Every subscription spawn is preceded by a deterministic probe (`agents/subscription-latch.sh` →
the egress proxy's `GET /anthropic-limit`). **Schedules always fire; capacity only turns the
spawn into a report-only line.** Concretely — the coordinator cron fires while the 5h window sits
at 85%:

1. The `*/10` CronWorkflow runs the deterministic scan normally (`gh` reads — no LLM, no
   subscription traffic, so the scan itself can never worsen the situation).
2. When the scan decides a stack needs an LLM tick, `coordinator-session.sh` probes the proxy
   *before* creating the pod. 85% ≥ the 80% threshold (`ANTHROPIC_UTIL_THRESHOLD`) →
   `{limited: true, reason: "utilization-5h"}` → the launcher prints
   `→ coordinator tick deferred — subscription rate-limited (FU-088)` and exits 0. No pod, no
   session burned, nothing to clean up.
3. There is no state to unwind: the verdict is recomputed on every probe from the last-harvested
   `anthropic-ratelimit-unified-*` headers, and a window whose reset epoch has passed is dead
   data by construction. The next cron firing re-probes; once the 5h window resets (or usage
   drops back under the threshold) dispatch resumes by itself — level-triggered, no human step.
4. The review path gates harder: the reflex tick exits at its step 0a *before any GraphQL
   spend*, and the Sensor (edge-trigger) path defers inside `reviewer-session.sh` via the same
   probe — a parked review loses nothing, the `*/15` backstop re-lists the PR later.
5. In-flight sessions are never killed by the gates. If one drives the window over the top
   anyway, the proxy's 429 latch (Retry-After or 900s, any 2xx clears early) catches the next
   dispatch — and on this account overage is org-disabled, so a hot window hard-429s rather
   than spilling to paid.

Two more gates ride the same probe script: the **concurrency semaphore** (≥
`SUBSCRIPTION_MAX_RUNNING`, default 3, Running pods labelled
`homelab.teststuff.net/subscription-session=claude` → defer — the proactive half that prevents
the burst which *causes* a 429) and, for OpenRouter workers, the **account-credit floor** in
`agent-session.sh` (FU-088b, `OPENROUTER_MIN_CREDIT`). Observability: Grafana
`claude-subscription` (utilization vs threshold, data age, deferral state) + the
`SubscriptionDispatchLimited` (deferring >15m) and `SubscriptionWeeklyPoolLow` alerts.

**The Argo-native layer (2026-07-17):** the three subscription-holding workflows (review-reflex
tick, coordinator tick, the Sensor-submitted `review` Workflow — each holds its container for
the session's whole duration) also declare a native Argo `synchronization` semaphore
(`subscription-capacity` ConfigMap, key `claude: "3"`). An over-cap submission **queues**
("waiting for lock" in the Argo UI, priority-ordered) instead of being deferred-and-rediscovered
— work waits in line rather than relying on the next level-triggered pass. Deliberate layering,
not redundancy: Argo counts only Argo-run *workflows* (interactive rides and jail launches are
invisible to it, and one reflex tick can hold two reviewer pods on a single slot), while the
probe script's proxy verdict + pod-label count see all subscription traffic — Argo provides
queueing semantics, the latch provides ground truth. ConfigMap semaphores are namespace-scoped,
so the FU-080 per-stack world needs the DB-backed lock flavor or per-stack pools (decide there).
Never suspend a schedule for capacity — `suspend: true` is state that rots.

### Triggers: polling first, webhooks as an edge-trigger on top

- **Don't build a pure-webhook system.** Deliveries get missed and the coordinator can be down.
  Build a reconciler that **periodically re-lists** open `agent-fix` issues/PRs and drives the state
  machine (level-triggered, robust). Webhooks then merely *wake it sooner* (edge-triggered) — the
  standard k8s "edge + level" wisdom. The **review path already runs this way** (2026-07-17, ADR-093):
  the github-exporter POST is the edge-trigger into an Argo Events webhook, backed by a `*/15`
  CronWorkflow that re-lists — see [`merge-path.md`](merge-path.md).
- **Start with polling** (every 1–2 min — trivial at this volume); add webhooks when latency annoys.
  Events worth subscribing to: `pull_request` (opened/synchronize), `pull_request_review`,
  `check_suite` completed, `issues`/`issue_comment` (label/comment).
- **CI-green needs no GitHub webhook** — CI runs in-cluster on ARC, so the workflow's final step can
  ping the coordinator directly. Webhooks are really only for *human* actions originating at GitHub.
- **Delivery into the homelab** — reuse the Cloudflare Tunnel pattern (a small `cloudflared` ingress
  to an in-cluster coordinator); no inbound ports.

#### The coordinator Sensor (design 2026-07-17; build = FU-085)

Nothing wakes the coordinator early today — the `*/10` `coordinator-reflex` CronWorkflow is the only
thing that runs `coordinator-scan.sh --spawn` (live sting: the oracle-fleet#29 C4/C5 re-tick sat
waiting on cron minutes after its `AGENT_STRIKE` comment landed). The next increment mirrors the
review edge on the SAME machinery — one more endpoint on the existing `agent-loop` webhook
EventSource, a `coordinator` Sensor, a `coordinate` WorkflowTemplate
([`../../agents/coordinator/review-argo.yaml`](../../agents/coordinator/review-argo.yaml) is the
shape; EventBus, sensor-SA pattern, and backstop doctrine all exist):

- **The event is a doorbell, never a work item.** The Sensor submits a Workflow that re-runs the
  deterministic scan, which re-lists GitHub and applies the FULL predicate — including the C4/C5
  kubectl probe and the FU-080 `coordinator.enabled` knob. Payloads *scope* (`{repo}`), they never
  carry state (at-least-once, missable — the review-path rule). A false wake costs a scan run (a
  handful of `gh` calls), **not** an LLM tick: the scan gate is what protects the subscription, so
  emitters may over-approximate freely.
- **Pick emitters per transition** — the review-path insight generalizes: *almost every actor that
  CAUSES a scan-actionable transition already runs in-cluster*, so the sharpest emitter is one curl
  at the moment it acts (instant, exact, no new polling). That includes **ARC**: any workflow on
  `runs-on: homelab-ephemeral` is an in-cluster actor and can end with the ADR-084 one-line POST —
  but move a workflow in-cluster for its own reasons, never just to emit; the one deliberately
  GitHub-hosted job (`update-pr-branch.reusable.yml` — "the merge path must not depend on the
  self-hosted tier being awake") stays on `ubuntu-latest`, and the github-exporter piggyback
  (rider on the one-poller doctrine) covers what off-cluster actors touch:

  | scan clause (transition) | who causes it | edge emitter | latency (today: ≤10 min) |
  |---|---|---|---|
  | C4/C5: worker terminal, no PR (incl. `AGENT_STRIKE`) | `agent-session.sh` launcher — it *posts* the strike comment | launcher curls `/coordinate` right after | instant — the #29 case |
  | PR → `CHANGES_REQUESTED` (round N+1) | reviewer pod (`reviewer-session.sh` verdict) | reviewer curls after posting the verdict | instant |
  | `merge-conflict` label appears | `update-pr-branch` — GitHub-hosted **by design** (see above); don't move it for this | exporter piggyback: labels are already in its 120 s poll; conflict-resolution latency is non-critical | ≤2 min |
  | un-armed `major` PR appears | Renovate + `devbox-update.yaml` — **both self-hosted on ARC**, centralized in homelab `.github/workflows/` (not N repos) | one curl at the end of those two runs; exporter piggyback as belt | instant |
  | issue gains `agent/queued` | a **jail LLM session** authoring issues from specs (rarely a hand-labelling human) | the authoring session rings the doorbell itself: mono jail → `devbox run coordinate-now` (`scripts/reflex-now.sh`, live); stack jails → curl `/coordinate` once it exists — the webhook needs **no RBAC into `agent-coordinator`**, exactly the FU-080 airlock shape | instant, author-fired |

- **Serialization + storm safety.** Edge-triggering removes the cron's implicit 10-min damping, so
  the existing guards carry the load: the scan gate, bounded rounds + the strike chain, the
  `agent/error` breaker (excluded from every clause), and the `(issue, base-sha, round)` job-name
  test-and-set. Add mechanically: one `synchronization.mutex` (`coordinator-scan`) shared by the
  Sensor-submitted Workflow AND the CronWorkflow — the Cron's `concurrencyPolicy: Forbid` does
  **not** see Sensor submissions — plus a Sensor trigger `rateLimit` as the dumb outer belt.
- **Refactor that falls out:** extract the cron's inline scan container into the `coordinate`
  WorkflowTemplate and have both the CronWorkflow and the Sensor `workflowTemplateRef` it (exactly
  the review-argo shape). A `--repo <r>` scope arg on the scan makes an event cheaper than a full
  tick; v1 may skip it — an unscoped scan is just an early cron tick.
- **After it proves out:** relax the coordinator cron `*/10 → */30` (the review reflex's own
  `*/5 → */15` move) — less GraphQL burn (FU-084). Red-beyond-T (FU-050 v3) stays cron-only by
  nature (a timer is level-triggered). Under FU-080's per-stack move the Composition renders the
  Sensor/trigger per stack like the rest of the loop.

End state: the whole loop is edge-driven — queued issue → tick → worker → green PR → review Sensor
→ verdict → coordinator Sensor → round N+1 → merge — with cron sweeping behind as the
level-triggered backstop.

### Hazards to bake in from day one

- **Bounded rounds** — max review rounds (e.g. 3) then escalate; a flaky reviewer/CI otherwise burns
  the per-project budget forever.
- **Idempotency** — webhook delivery is at-least-once; key a worker off `(issue, base-sha, round)` so
  a redelivered event doesn't spawn two pods. Enforce it mechanically, not by convention: the key
  IS the Job name (`fix-<repo>-<issue>-r<round>`) — `kubectl create` with a deterministic name is
  an atomic test-and-set, so racing dispatchers can't double-spawn
  ([`merge-path.md`](merge-path.md) §Failure modes, "Concurrent triggers / locking").
- **Concurrency** — one active worker per PR; never open round N+1 while N is in flight.
- **Budget** — per-issue cap riding on the per-project budget-capped OpenRouter key
  (`<project>/infra/openrouter-key.yaml`); note the cap is *soft* (see operational findings).
- **Human seam** — "changes requested by human" vs "by agent" are both just inputs to the next round;
  the coordinator only distinguishes *needs-another-round* from *needs-human* (escalation — merges
  themselves are auto once the reviewer approves; humans review only the fixer — the operating
  model).

## MVP

A reconcile loop (cron + on-demand) that lists open `agent-fix` issues/PRs, runs the state machine,
and spawns a **fresh** worker per round via `agent-session.sh`. **Polling only.** Webhooks + the
fast-CI grace window are phase 2. Each round's cost/outcome already lands on the PR (stats comment)
and in Loki — the coordinator consumes the same signals.

Related: [`README.md`](README.md) · [`../adr.md`](../adr.md) · [`../../ROADMAP.md`](../../ROADMAP.md)
· [`../../agents/README.md`](../../agents/README.md)
