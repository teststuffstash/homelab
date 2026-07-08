# Agent observability & the retro loop — see every session, improve the process from evidence

> **Status: design (2026-07-08), pre-implementation.** Written before scaling coordinator use to
> the oracle stack. Companion to [`workflow.md`](workflow.md) (control flow) and
> [`../../agents/README.md`](../../agents/README.md) (launcher + stats). Absorbs **FU-023**
> (stats v2 / cross-run dashboard). New FU ids: assign in [`../follow-ups.md`](../follow-ups.md)
> when picked up.

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
  Coordinator + reviewer sessions render natively. **Goose worker sessions are a different
  format** — v1 keeps the existing Grafana deep-link + the raw `run.log` in the bucket (linked
  from the manifest); a goose→claude-jsonl converter is a later nice-to-have, not a blocker.
- **Task-centric entry**: the bucket prefix *is* the "all sessions for issue #N" view; add the
  prefix URL to the existing PR stats comment (one line next to the Grafana link).
- **LLM access**: an MCP toolset on the homelab Type-1 MCP —
  `list_sessions(project, task)` · `get_manifest(session)` · `grep_transcript(session, pattern)` ·
  `fetch_segment(session, from, to)` — so an analysis session pulls *slices*, never whole
  transcripts into context.

## Part B — the retro loop (reflex + judgment, per the standing doctrine)

### B1. retro-facts reflex (deterministic, per terminal task — P2)

No LLM turn. When a task reaches a terminal label (`agent/done`/`agent/blocked`), compute from
manifests + stats and append one line to a durable ledger (`agent-transcripts/_ledger.jsonl`):
cost vs estimator band (**calibration error**), rounds used, retry storms (the 812×-403 class),
CI red/green sequence, review flip-flops, wall time, cache-hit %, requests, tokens/request.
Grafana dashboard over the ledger = the long-promised **FU-023 stats v2**. These numbers are also
the KPI set the retro measures itself against: cost/issue, rounds/issue, blocked rate, estimator
error.

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

## Rollout

- **P0 (blocker)**: bucket + manifests + the three capture hooks. Fire coordinators after this —
  everything later can analyze retroactively *because* P0 captured the raw material.
- **P1**: viewer Deployment + PR-comment task link. **P2**: facts reflex + dashboard (FU-023).
- **P3**: retro brief + first hand-supervised run, then a CronJob sibling of the review reflex.
