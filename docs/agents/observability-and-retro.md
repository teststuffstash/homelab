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
CronWorkflow that is **born suspended** — see Part B. Companion to
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

## Part B — the retro loop (reflex + judgment, per the standing doctrine)

### B1. retro-facts reflex (deterministic, per terminal task — P2)

No LLM turn. When a task reaches a terminal label (`agent/done`/`agent/blocked`), compute from
manifests + stats and append one line to a durable ledger (`agent-transcripts/_ledger.jsonl`):
cost vs estimator band (**calibration error**), rounds used, retry storms (the 812×-403 class),
CI red/green sequence, review flip-flops, wall time, cache-hit %, requests, tokens/request.
Grafana dashboard over the ledger = the long-promised stats v2 (**FU-057**). These numbers are also
the KPI set the retro measures itself against: cost/issue, rounds/issue, blocked rate, estimator
error.

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

**Run-3 shape (operator direction, composition-axes frame):** two retro rides off the SAME
agent-base image and the SAME committed `BRIEF.md` — **A** = claude harness + opus (subscription
via the ADR-081 proxy, FU-088-gated), **B** = goose harness + deepseek-v4-pro (ephemeral capped
key, provider-pinned) — then cross-review with the **cells swapped** (A reviews B's report, B
reviews A's). Tooling parity is already structural: agent-base ships `claude-code@latest` alongside
goose/opencode plus the full toolkit (gh/git/jq/python/uv/kubectl/s5cmd), so retro-er and reviewer
are freely mixable. Rotating cells run-over-run separates **harness effect from model effect** on
the FU-057 ledger axes — which doubles as FU-095(b) evidence. Repo scope for the retro token = the
stack jail's REPOS boundary (`tools/stack-jail.sh`: oracle-fleet, oracle-iac,
allure-behavior-snippets), read-only, App-minted. Standing guardrails: outside the fixer ns / WIP
slot (the P3 constraint), $0.05 key floor, `GOOSE_MAX_TOKENS=16384`, reports land in
`docs/agents/retros/` via PR.

## Rollout

- **P0 (blocker)**: bucket + manifests + the three capture hooks. Fire coordinators after this —
  everything later can analyze retroactively *because* P0 captured the raw material.
- **P1**: viewer Deployment + PR-comment task link. **P2**: facts reflex + dashboard (FU-057).
- **P3**: retro brief + first hand-supervised run, then a CronWorkflow sibling of the review reflex (FU-058).
