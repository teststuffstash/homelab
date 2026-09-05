# Agent workflow — issue → tested PR → merge

**This doc owns the fixer control flow** — the worker's gates, why it's a pure function, the
coordinator as a level-triggered reconciler, the trigger model, and the hazards to bake in. The
coordinator that executes it is [`../../agents/coordinator/README.md`](../../agents/coordinator/README.md);
its per-role machinery is [`roles.md`](roles.md); pivotal choices are thin ADRs in
[`../adr.md`](../adr.md).

The end-to-end target (from [`README.md`](README.md)): a triaged issue becomes a tested, auto-merged
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
  The `base` in that signature is **declarable** since 2026-08-05: an issue carrying a
  `Base: <branch>` body line dispatches against that branch instead of master, and its PR is
  never armed for auto-merge ([issue-authoring.md](issue-authoring.md) §Base). Absent ⇒ master.

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

The state machine itself is maintained in ONE place — **[`merge-path-fsm.md`](merge-path-fsm.md)**
(generated, lint-anchored; transitions MP-T01…T13 + gap register). The coordinator's two
entry/exit arcs around it: `triaged` (labelled, repro + synthetic data table) → spawn worker
round 1; `cant-repro | max-rounds | flip-flop` → tie-break/escalate to a human. Spawning a
round = `agents/agent-session.sh` (→ an `agent-sandbox` `Sandbox` CR once that lands,
ADR-078/081).

### Capacity gates — a tick vs a hot subscription (FU-088, 2026-07-17)

Every subscription spawn is preceded by a deterministic probe (`agents/subscription-latch.sh` →
the egress proxy's `GET /anthropic-limit`). **Schedules always fire; capacity only turns the
spawn into a report-only line.** Concretely — the coordinator cron fires while the 5h window sits
at 85%:

1. The `*/30` CronWorkflow runs the deterministic scan normally (`gh` reads — no LLM, no
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
`SUBSCRIPTION_MAX_RUNNING` — the script default is 3 but the AUTHORITY is the proxy
Deployment's explicit env, **5 since 2026-08-08** (the Max 5x→20x upgrade; the Argo
`subscription-capacity` ConfigMap mirrors it and says so) — Running pods labelled
`homelab.teststuff.net/subscription-session=claude` → defer — the proactive half that prevents
the burst which *causes* a 429) and, for OpenRouter workers, the **account-credit floor** in
`agent-session.sh` (FU-088b, `OPENROUTER_MIN_CREDIT`, default $0.25). That floor reads the balance
from the proxy's `GET /router-status` → `.openrouter_capacity.credit_usd` (unauthenticated,
in-cluster; sourced operator-gauge → proxy → launcher), **not** from OpenRouter's `/api/v1/credits`,
which is management-key-only and 403'd every dispatch until homelab#190 — the floor did not exist
for the whole of 2026-07/08 and nothing said so. It is deliberately **fail-open** when no fresh
balance is available (unreachable proxy, dead credit leg, or a value held past the proxy's
`credit_max_age_s`), and since #190 it says so in one line on the dispatch path naming the URL, so
"no floor right now" is never again indistinguishable from a healthy account. Full mechanism:
[`model-routing.md`](model-routing.md) §M12. Observability: Grafana
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
so per-stack workflows carry the latch only (decided with FU-080: per-stack capacity =
subscription-latch, no cross-ns semaphore — the Composition's rendered crons rely on the probe).
Never suspend a schedule for capacity — `suspend: true` is state that rots.
**The [Go rail](chainless-redesign.md) runs the same pattern (ADR-107/FU-170, 2026-08-17).** Go-rail rides
(`rail=opencode-go` pods) gate on `GET /opencode-limit`: self-metered usage-value windows
($12/5h · $30/wk · $60/mo, epoch-anchored grids — gometer, PR#481; drawn at LIST price on raw
tokens, badge-halved) plus the FU-088-pattern **concurrency semaphore** — the proxy counts
Running `rail=opencode-go` pods cluster-wide, `OPENCODE_MAX_RUNNING` (explicit 5 in the
deployment, mirroring the anthropic bound), composed into the endpoint's top-level `limited`
so every consumer (worker gate, reviewer failover) inherits it with zero launcher changes
(PR#484). Fail-open on an unreadable count, like every capacity gate here. Jail Go burn
self-meters into the same ledger via the shim's token-gated ingest (ADR-108) — ⚠ the metering
code rides the RUNNING shim process, so a shim started before a metering fix keeps under-counting
until relaunched (the 2026-08-17 drift: six hours at ~7% of true draw).

**This section is the ONE home of the FU-088 capacity story** — README/merge-path link here.

### Triggers: polling first, webhooks as an edge-trigger on top

- **Don't build a pure-webhook system.** Deliveries get missed and the coordinator can be down.
  Build a reconciler that **periodically re-lists** open `agent-fix` issues/PRs and drives the state
  machine (level-triggered, robust). Webhooks then merely *wake it sooner* (edge-triggered) — the
  standard k8s "edge + level" wisdom. Both paths run this way today (ADR-093): the
  github-exporter POST is the edge into the in-cluster Argo Events webhook (no external
  delivery, no tunnel needed), the CronWorkflows re-list behind it. (The original
  polling-first/GitHub-webhook design considerations: git history, pre-2026-07-17.)

#### The coordinator Sensor (design 2026-07-17; BUILT same day — FU-085 archived, coordinate-argo.yaml)

LIVE since 2026-07-17: the `/coordinate` doorbell endpoint on the `agent-loop` webhook
EventSource, the `coordinator` Sensor, and the `coordinate` WorkflowTemplate
([`../../agents/coordinator/coordinate-argo.yaml`](../../agents/coordinator/coordinate-argo.yaml));
the per-stack `coordinate-<stack>` CronWorkflows are the level-triggered BACKSTOP (the design
sting that motivated the edge: oracle-fleet#29's C4/C5 re-tick sat waiting on cron minutes after
its `AGENT_STRIKE` comment landed). **The GLOBAL cron (`coordinator-reflex`) retired 2026-08-31
(ADR-120)** — with every stack graduated it caught nothing by construction (dispatch skipped every
stack; fan-out is edge-wakes-only), and the global Sensor surface was rebranded the
**switchboard**: a resolver that patches repo-dumb rings through to their stack and fans capacity
transitions out, never a board scan. The design, as built:

- **The event is a doorbell, never a work item.** The Sensor submits a Workflow that re-runs the
  deterministic scan, which re-lists GitHub and applies the FULL predicate — including the C4/C5
  kubectl probe and the FU-080 `coordinator.enabled` knob. Payloads *scope* (`{repo}`), they never
  carry state (at-least-once, missable — the review-path rule). A false wake costs a scan run (a
  handful of `gh` calls), **not** an LLM tick: the scan gate is what protects the subscription, so
  emitters may over-approximate freely.
- ⚑ **ALL EVENTS HAVE DOORBELLS — a rule with NO exceptions (operator, 2026-08-12).** No
  convenience carve-outs ("it's weekly", "it's human-gated", "the cron covers it"): each one is
  individually defensible and their SUM was the goal-#278 famine — 14.5h of wall clock for ~4.5h
  of work, 361 minutes of a non-empty queue with zero pods, assembled one tolerated dead edge at
  a time. The cron is a FAILURE DETECTOR, not a coverage mechanism: a dispatch the cron serviced
  is a defect with an id, full stop (Part A″'s accounting rule, now universal). Enforcement is
  MEASURED, not promised: the scan states its wake source per dispatch (a ring-to-scan phase row
  exists ⇔ edge-woken), so "% of dispatches edge-woken" is a number and a recurring cron-woken
  dispatch is an alert, not an anecdote — the A2 chunk's acceptance criterion.
- **Pick emitters per transition** — the review-path insight generalizes: *almost every actor that
  CAUSES a scan-actionable transition already runs in-cluster*, so the sharpest emitter is one curl
  at the moment it acts (instant, exact, no new polling). That includes **ARC**: any workflow on
  `runs-on: homelab-ephemeral` is an in-cluster actor and can end with the ADR-084 one-line POST —
  but move a workflow in-cluster for its own reasons, never just to emit; the github-exporter
  piggyback (rider on the one-poller doctrine) covers what off-cluster actors touch. ⚠ The one
  deliberately GitHub-hosted job this paragraph used to name (`update-pr-branch.reusable.yml` —
  "the merge path must not depend on the self-hosted tier being awake") is **RETIRED — ADR-111,
  cutover executed 2026-08-26 (homelab#745)**: the independence was per-leg while CI and review
  are cluster-resident, and the GitHub cron backstop was 91–96% of the hosted-minutes burn — the
  updater runs in-cluster (stint S7, homelab#741; `agents/update-pr-branch.sh` +
  `agents/coordinator/update-pr-argo.yaml`):

  | scan clause (transition) | who causes it | edge emitter | latency (today: ≤10 min) |
  |---|---|---|---|
  | C4/C5: worker terminal, no PR (incl. `AGENT_STRIKE`) | `agent-session.sh` launcher — it *posts* the strike comment | launcher curls `/coordinate` right after | instant — the #29 case |
  | PR → `CHANGES_REQUESTED` (round N+1) | reviewer pod (`reviewer-session.sh` verdict) | reviewer curls after posting the verdict | instant |
  | `merge-conflict` label appears | the in-cluster updater (`agents/update-pr-branch.sh` armed∧DIRTY labeler, leg 3 — ADR-111, cutover 2026-08-26; the 422 leg stopped labeling at homelab#986/PR#1005, so a conflict surfaces one pass later as DIRTY rather than immediately) | exporter piggyback, BUILT 2026-08-11 (#285): `maybe_dispatch_conflict` rings `/coordinate` with `{stack, loop_ns}` — the label was already in the 120 s poll, nothing read it (PR#275 waited out the cron) | ≤2 min |
  | un-armed `major` PR appears | Renovate + `devbox-update.yaml` — **both self-hosted on ARC**, centralized in homelab `.github/workflows/` (not N repos) | one curl at the end of those two runs — `{repo}`-only, which is now ENOUGH: the switchboard (ADR-120; was the global scan) resolves repo → {stack, loop_ns} and re-rings the stack's own loop (FU-144 receiver-side fan-out, built with A2) | instant (one resolver hop) |
  | issue gains `agent/queued` | whoever applies the label — a **jail LLM session** authoring issues from specs, or a hand-labelling human | **two emitters.** The authoring session rings the doorbell itself: mono jail → `bash scripts/reflex-now.sh coordinate-<stack> <stack>-agents`; stack jails → curl `/coordinate` once it exists — the webhook needs **no RBAC into `agent-coordinator`**, exactly the FU-080 airlock shape. **Plus** exporter piggyback, BUILT 2026-08-18 (#505): `maybe_dispatch_queued` rings `/coordinate` with a repo-dumb `{repo, number}` on the appearance edge of `agent-fix` ∧ `agent/queued` ∧ ¬`direction-change` ∧ ¬`agent/error` (`queued_dispatchable` mirrors the scan clause label for label) — a hand-applied label rings too (the #459 gap: sleep-tracking#121; homelab#478/479/491) | instant, author-fired; exporter piggyback ≤2 min |
  | a PR MERGES (merged-closeout / the goal chain / sibling platform repos) | GitHub auto-merge — off-cluster by nature, minutes after the last in-cluster actor exited | exporter piggyback, BUILT 2026-08-12 (ADR-106 (6)): `maybe_dispatch_merged` — a number leaving the poll's open set is REST-checked once (`merged` authoritative) and rings with {stack, loop_ns}; before this NOTHING rang on merge anywhere (the v1.1 spike's finding 6 named the sibling repos; the gap was fleet-wide) | ≤2 min |

⚠ **That last row said `devbox run coordinate-now` until 2026-08-06 and was WRONG for every
graduated stack** — `coordinate-now` fired the GLOBAL reflex, which skipped graduated stacks
entirely, so the promised edge woke a run that printed `skipped ×4`; a queued issue simply waited
for the `*/30` per-stack cron: **8m35s**, measured on circles#29. **CLOSED by FU-144 (ruled +
built 2026-08-12, the A2 chunk): the receiver resolves.** An edge-woken global scan maps a
repo-dumb ring to {stack, loop_ns} off `stacks_json()` (the claims merged over the mirror — the
one stack source it already trusts) and re-rings `/coordinate` with the resolved pair, so the
per-stack trigger fires (`coordinator-scan.sh` §doorbell-fanout; latch-gated like every ring,
cron wakes never fan out, and the re-ring's own `loop_ns` is the loop-break). Emitters stay
repo-dumb by design — that is the honest payload for anything that edits a repo. The lesson the
old warning carried stands: a table row naming a mechanism that cannot reach the stack is worse
than an empty row, because it stops anyone looking.

**Emitter inventory (2026-08-18, checked against `master`).** Everything that rings `/coordinate`
from this repo's own code now carries `{stack, loop_ns}` for a graduated repo:
[`agents/agent-session.sh`](../../agents/agent-session.sh),
[`agents/reviewer-session.sh`](../../agents/reviewer-session.sh),
[`scripts/coordinate-ring.sh`](../../scripts/coordinate-ring.sh) (`devbox run ring <stack>`),
`fix-debounce-argo.yaml` (from birth, `83907ea`), `.github/workflows/coordinate-doorbell.yaml`,
and the github-exporter's five dispatchers — review (FU-100), CI-red (FU-115), `merge-conflict`
(#285), since 2026-08-12 PR-merge (ADR-106 (6)) and, since 2026-08-18, the queued-label edge
(#505; repo-dumb, grouped below). The `{repo}`-only emitters — `.github/workflows/renovate.yaml`
(`{"repo":"all"}`), `.github/workflows/devbox-update.yaml` (`{"repo":"<matrix.repo>"}`) and
`maybe_dispatch_queued` (`{repo, number}`) — are **served by the FU-144 receiver-side fan-out
since 2026-08-12** (the ⚠ block above): repo-dumb payloads are the SUPPORTED shape now, and new
emitters should prefer them over learning stack mechanics. The operator-lane note stands for the
files themselves (`.github/**` executes from a PR's own branch, so the fixer lane may not edit
them). `devbox run coordinate-now` retired with the global cron (ADR-120) — wake a stack via
`devbox run ring <stack>` or `scripts/reflex-now.sh coordinate-<stack> <stack>-agents`.
The old two-readers trap (emitters read the mirror, the scan reads the live claim) is CLOSED for
this path by construction: the resolver runs inside the scan and reads the same `stacks_json()`
merge (claim wins) the skip decision itself uses — one reader, one source. `coordinate-ring.sh`
still derives `loop_ns` from the stack name jail-side; that convention (`<stack>-agents`) is the
Composition's own naming and moves only if the Composition's does.

- **Serialization + storm safety.** Edge-triggering removes the cron's implicit 10-min damping, so
  the existing guards carry the load: the scan gate, bounded rounds + the strike chain, the
  `agent/error` breaker (excluded from every clause), and the `(issue, base-sha, round)` job-name
  test-and-set. Add mechanically: one `synchronization.mutex` (`coordinator-scan`) shared by the
  Sensor-submitted Workflow AND the CronWorkflow — the Cron's `concurrencyPolicy: Forbid` does
  **not** see Sensor submissions — plus a Sensor trigger `rateLimit` as the dumb outer belt.
  **ADR-106 (5) re-scoped both halves after the goal-#278 famine** (361 min starved, 56 Pending
  workflows at 03:15 — the spike's finding 5): the mutex now spans ONLY the deterministic pass —
  `coordinator-session.sh --detach` exits at pod-Ready and the session pod uploads, pushes its
  own phase row, and rings the completion doorbell itself — and a starting full scan ABSORBS all
  Pending sibling `coordinate*` workflows before its re-list (`coordinator-scan.sh`
  §doorbell-collapse: delete-then-list ordering means an absorbed ring's cause is always visible
  to the re-list — the ADR-093 fixed-name collapse's effect without its dropped-ring race).
- **Refactor (done):** the cron's inline scan container was extracted into the `coordinate`
  WorkflowTemplate; CronWorkflow and Sensor both `workflowTemplateRef` it (the review-argo shape).
  Scoping went further than the planned `--repo`: ADR-094 item-scoped dispatch (FU-086) — the
  scan emits `(clause, repo, item)` units and the session judges ONE unit via
  `coordinator-session.sh --item`. **Since ADR-125 the scan's clause priority walk runs once per
  LANE — a (repo, base) pair — so up to one unit per lane is dispatched per pass** (the fleet
  ceiling is still the subscription latch, probed before every spawn; per-lane slots were
  rejected). Within a lane the priority is a preference rather than an absolute: a `queued-dispatch`
  or `goal-decompose` unit that has lost `SCAN_AGING_N` (3) consecutive lane dispatches escalates
  to the front of that lane's walk, with the loss count DERIVED from GitHub state — the newest
  `agent/queued` labeled event versus the `<!-- agent-event … -->` markers on the lane's other
  in-flight items — and never held in the scan's head (homelab#829). The lane also labels the
  famine gauges: `agent_item_class{…,base=…}` and the cron/edge wake series, so
  `AgentDispatchCronWoken` counts a dead doorbell per lane instead of per stack.
- **Proven out; residue SHIPPED (FU-086, archived complete):** the coordinator cron relaxed
  `*/10 → */30` 2026-08-02 (the review reflex's own `*/5 → */15` move — less GraphQL burn), and
  the FU-085 compound shipped 2026-08-03 — reviewer verdicts carry their unit → Sensor
  `body.unit` → scan fast-path, with the cron sweeping only the missed units.
  Red-beyond-T stays cron/poller-territory by nature (a timer is level-triggered; the
  github-exporter's CI metrics carry the out-of-band half). Per-stack routing landed the OTHER
  way (decided with FU-080/FU-100): Sensors/EventBus stay GLOBAL (a per-stack JetStream is 3×1Gi
  for near-zero volume) and route graduated events INTO `<stack>-agents` data-driven
  (`body.loop_ns` — coordinate doorbell AND the review edge).

End state: the whole loop is edge-driven — queued issue → tick → worker → green PR → review Sensor
→ verdict → coordinator Sensor → round N+1 → merge — with cron sweeping behind as the
level-triggered backstop.

### Footprint hold — parallel dispatch without lanes (ADR-097, BUILT 2026-08-03)

Supersedes per-lane label counting as the write-conflict guard. The scan's dispatchability
predicate gains footprint intersection in place of `lane-free`:

- **Declared footprint** = the issue's machine-readable `Touches:` body line (paths/globs,
  comma-separated, unbulleted), authored once at issue creation
  ([issue-authoring.md](issue-authoring.md) §Touches). **No line = exclusive**: an undeclared
  issue conflicts with everything in its repo — legacy issues keep WIP=1 semantics, and the
  migration needs no backfill.
- **The hold**: a queued unit is held iff its footprint intersects the footprint of ANY
  `agent/in-progress` issue in the repo. Intersection is prefix-overlap on normalized entries
  (`chassis/**` ∩ `chassis/api.py` = conflict) — set logic in the scan, zero tokens, testable.
  Live footprints come from the in-progress ISSUES (the scan already lists them for the old
  lane hold); the `wip_busy` pod probe stays as the liveness belt underneath, now counting
  against the raised limit rather than 1.
- **Ceilings stack**: scan sets `AGENT_WIP_LIMIT` = concurrent dispatches (launcher pre-flight
  belt matches); hard per-repo max (default 3) and the ≤3-open-PR bound (updater churn is
  O(open PRs × merges) — oracle TRACKS rule 1) hold regardless of footprints; FU-088 capacity
  semaphore caps globally.
- **The COMPELLED-COUNTERPART classes are EXEMPT from footprint semantics on both sides** —
  `agents/replay/**`, top-level `agents/*-test.sh`/`*-replay.sh` suite pins, and
  `docs/agents/*-fsm.{yaml,md}` (ADR-097 addendum 2, 2026-08-19/homelab#601 widening the
  2026-08-18 — the FU-167/FU-168 joint call, operator-ruled): declared replay entries are
  stripped from the intersection (a replay-only footprint holds nothing and is held by nothing),
  and changed replay paths are never `Touches:` escapes, governance or otherwise. One predicate
  (`fp_replay_exempt`, [`agents/footprint.sh`](../../agents/footprint.sh)), consumed by the scan
  hold and by `touches-check.sh` — which both the scan and the reviewer source, so the two
  readers cannot diverge. Why: the ADR-103 ratchet COMPELS a replay touch on every clause PR, so
  requiring its declaration was ceremony — it manufactured the unsatisfiable-footprint class
  (homelab#270/PR#275) and a governance block on a compelled edit (PR#547), against zero real
  replay conflicts measured over 41 PRs. Content safety stays with the review rubric's
  worlds-are-extraordinary rule, the ratchet, and git blame.
- **Residual risk**: a worker escaping its declaration. Belt: the reviewer flags diff paths
  outside the issue's `Touches:` (a narrow-blocking case, reviewer rubric); TRACKS rule 2 still
  routes shared-file work through its owning concern as a separate issue.
- **Second, static intersection — the pin-only GUARDED set** (homelab#309, BUILT 2026-08-11): the
  same predicate run against the files `scripts/pin-only-lint.sh` guards, which a PR may write
  nothing but a pin line into. A hit is **undeliverable by any PR** (the required `ci` check is red
  before the worker starts) and its route is an operator push to master, so the scan reports
  `⛔ pin-only GUARDED path` and does not dispatch — report-only, no label, because the overlap may
  be only part of the issue's scope. The set is READ from the lint (one definition, two readers —
  the other is the ADR-103 ratchet step); an unreadable set holds rather than dispatching blind,
  scoped to the repo the set belongs to. The `*` sentinel is not a hit: it conflicts with
  everything by construction, and reading it as guarded would stop dispatching every unfootprinted
  issue in the repo. Cost before the check: one burned round per hit (#299).

### Replay harness — the ADR-103 ratchet, executed

A changed coordinator clause, prompt-assembly path or reflex ships **only with an executed replay**
(ADR-103 rule 1): recorded API state in, expected dispatch/label/comment out. Prose warnings were
tried and every prose-warned class recurred; every executable gate held. The harness that makes
writing one cheap is [`agents/replay/`](../../agents/replay/README.md) (homelab#206).

```sh
devbox run -- bash agents/replay/run.sh                            # every fixture
devbox run -- bash agents/replay/run.sh -v agents/replay/fixtures/state-fp
```

**Fixture layout.** One directory per replayed condition:

```
agents/replay/fixtures/<name>/
  fixture.yaml            name / mode / parts / env / expect
  world/gh/pr-view.json   RECORDED responses, keyed by the invocation they answer
  expected/actions.txt    the action stream the clause must emit
  bridge.sh, post.sh      parts that are not clause code (see below)
```

`fixture.yaml` is a deliberately tiny YAML subset — `key: value`, and `key:` followed by `- item`
lines. No nesting, and anything outside the subset is a parse error rather than a silent skip; the
harness everything else leans on depends on nothing but bash and awk.

- `mode: actions` — the declarative mode. `parts:` composes the clause at run time from
  `block:<sentinel>` (extracted out of `source:` by its `# >>>REPLAY:<name>>>>` markers) and
  `file:<name.sh>` (fixture-local bridge and observation-point code). Blocks are **extracted, never
  transcribed**: a transcribed clause pins a copy and goes green while the original drifts (#166).
  A bridge may be shared with a sibling fixture by relative path (`file:../other/bridge.sh`).
- `mode: suite` — an existing self-asserting replay (`entrypoint:`), registered rather than
  rewritten. `state-fp` is the one today; its file, its devbox script and its required CI status are
  untouched.
- `expect: fail` + `expect_detail:` — a PROBE-FAIL fixture (the check's-author rule, #168). It must
  red, **and for the declared reason**; if it goes green the run fails loudly. There is one per
  detector the runner owns: the diff, the missing sentinel, the unrecorded read.

**Recording a world.** Capture the real payload once, commit it, and never call out again — CI runs
offline (the e2e-cold-cache lesson), and a replay that can reach the network is a replay that goes
green for the wrong reason:

```sh
gh pr view 234 --repo teststuffstash/oracle-fleet \
   --json headRefOid,reviewDecision,statusCheckRollup,reviews,comments \
   | tee agents/replay/fixtures/<name>/world/gh/pr-view-234.json
```

The key is the invocation's **bare words** — command path plus positionals, flags dropped — tried
longest-first (`pr-view-234.json` → `pr-view.json` → `pr.json`). So record once per call *shape*,
and only pin a positional when two different answers are needed for it. A read with no recording is
**fatal and loud**, never an empty body: an empty payload usually parses, and the clause then
asserts on nothing. Writes (`pr comment`, `issue edit`, `kubectl create -f -`) are recorded into the
action stream instead of served — they are the output under test.

**What it asserts on.** The action stream only — the calls a clause makes and the lines it emits —
never internal variables, so a clause stays refactorable. `expected/actions.txt` is the `CALL`
stream, then `OUT`, then `ERR`, then `RC`; each in its own order. Interleaving *between* the streams
is deliberately not asserted (stdio buffering makes it non-deterministic, and no clause's contract
rests on whether a log line landed before or after the call it describes). Leave
`expected/actions.txt` out on a first run and the harness prints the stream it observed — review
that, then commit it.

**The ratchet.** A fixture that reds is the contract talking. If the behaviour change was
deliberate, the fixture is updated **in the same PR** — a changed clause ships with its replay or it
does not ship. Backfilling the older hand-rolled replays onto this harness follows fix-density, not
big-bang (ADR-103).

**Ratchet v2 is file-co-change; the FSM-keyed half is the ORPHAN GATE (landed 2026-08-10).**
ADR-103's text described a lint "keyed on the FSM's `replay:` fields"; what shipped first was the
weaker CI co-change check (clause file touched ∧ no replay-tree touch → red; since 2026-08-11 a
pin-only diff to a pin-guarded clause file is EXEMPT — regexes eval'd from `pin-only-lint.sh`,
one home, PR#236's collision — it forces the author
to look, it does not prove coverage). The promised half now lives in `merge-path-lint`: every
`guarded` transition in the three FSM YAMLs declares `replay:` (paths must exist) or an explicit
`unreplayed: "<reason>"`, both rendered in the generated views — coverage is a rendered fact, the
oracle evidence-lint's "covered or explicitly unverified" rule transposed. One boundary is
deliberate and permanent: **the LLM-play layer (the coordinator brief's plays) sits outside the
replay harness** — a play's output is judgment, not an action stream, so its gates are the anchor
lint (the lint greps play passages), ADR-094's launcher-owned orders shrinking the judgment
surface, and the one-ride-per-state debounces bounding a bad judgment's cost.

**What the pin-vacuity gate proves — and does not (homelab#1107, refined #1215/#1225,
2026-09-02).** It proves red-on-base for actions-mode fixtures on default-branch PRs. It
deliberately does NOT judge: `mode: suite` fixtures (self-asserting — they resolve the PR's own
sources), comment/blank-only diffs to commentable fixture files (documentation, not a pin claim
— #1215), or PRs onto **stacked bases** (`goal/**`: the fix may predate the PR there; those get
a "cannot prove vacuity" warning, never a verdict). And a **pure-absence contract** cannot red
on any base — author such fixtures to pin a positive instead (the exactly-one-CALL pattern,
PR#1272's repair). Whether the fixture REACHES the changed lines is #1224's parts-coverage leg,
not this gate.

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

Related: [`README.md`](README.md) · [`roles.md`](roles.md) · [`merge-path-fsm.md`](merge-path-fsm.md)
· [`../adr.md`](../adr.md) · [`../../ROADMAP.md`](../../ROADMAP.md)
· [`../../agents/README.md`](../../agents/README.md)
