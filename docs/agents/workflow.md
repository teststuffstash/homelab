# Agent workflow — issue → tested PR → merge

> **Status: running hand-driven (2026-07).** The *substrate* (scoped pods, recipes, scoped tokens,
> branch protection, stats) is LIVE — see [`README.md`](README.md) and
> [`../../agents/README.md`](../../agents/README.md). The **coordinator** exists as a hand-driven
> Claude Code brief ([`../../agents/coordinator/`](../../agents/coordinator/README.md)); graduating
> it to the durable, self-running reconciler described below is FU-026. Pivotal choices → thin ADRs
> in [`../adr.md`](../adr.md).

The end-to-end goal (from [`README.md`](README.md)): a triaged issue becomes a tested, auto-merged
fix. This doc is the *control flow* that gets it there — who runs the agent, when, and how review and
CI feed back. The last leg — how an approved green PR deterministically lands on master (branch
updates, review dispatch, auto-merge; no LLM in the mechanics) — is designed separately in
[`merge-path.md`](merge-path.md) (FU-041).

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

### Triggers: polling first, webhooks as an edge-trigger on top

- **Don't build a pure-webhook system.** Deliveries get missed and the coordinator can be down.
  Build a reconciler that **periodically re-lists** open `agent-fix` issues/PRs and drives the state
  machine (level-triggered, robust). Webhooks then merely *wake it sooner* (edge-triggered) — the
  standard k8s "edge + level" wisdom.
- **Start with polling** (every 1–2 min — trivial at this volume); add webhooks when latency annoys.
  Events worth subscribing to: `pull_request` (opened/synchronize), `pull_request_review`,
  `check_suite` completed, `issues`/`issue_comment` (label/comment).
- **CI-green needs no GitHub webhook** — CI runs in-cluster on ARC, so the workflow's final step can
  ping the coordinator directly. Webhooks are really only for *human* actions originating at GitHub.
- **Delivery into the homelab** — reuse the Cloudflare Tunnel pattern (a small `cloudflared` ingress
  to an in-cluster coordinator); no inbound ports.

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
