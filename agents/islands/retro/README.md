# retro — the platform's weekly self-improvement island

The retro reads what the agent fleet did last week and proposes how the process should change. A
deterministic half collects GitHub activity every 30 minutes and windows the task ledger; once a week
per **series** (the platform's own on Mondays, oracle's `feedback-triage` on Wednesdays) a guard
freezes one evidence bundle, one or two LLM cells — each a harness, its model served by the
agent-gateway for role `retro` — write reports, and a harvest files them in git and advances the
series' published window. Each report carries candidate findings; they are deduplicated and
reconciled against live GitHub daily, and become issues only through the seat's explicit acceptance
act. History goes to git and the bucket; GitHub gets only actionable work. Design and its rulings:
[docs/retro-loop.md](docs/retro-loop.md). The contract: [specs/](specs/README.md).

## Membership

Code stays where it is; this list is the island.

| kind | files |
|---|---|
| scripts | `agents/retro_activity.py` (collector + score), `agents/retro_pipeline.py` (store, window, bundle, publish, reconcile/accept entry), `agents/retro_findings.py` (candidates → finding state), `agents/retro_queue.py` (acceptance act), `agents/retro_guard_expr.py` (PromQL verdict), `agents/retro-session.sh` (cell launcher), `agents/retro-project.sh` (stack → ride namespace), `agents/retro-report-floor.sh` (the report definition), `agents/retro-rank.py` (legacy ranker — no live caller, [RETRO-RANK-LEGACY](specs/activity.md#retro-rank-legacy)) |
| tests | `agents/retro-activity-test.py`, `agents/retro-pipeline-test.py`, `agents/retro-findings-test.py`, `agents/retro-cadence-test.sh` (runs the three), `agents/retro-rank-test.sh`; `devbox.json` task `retro-test`; `scripts/diff-ci.sh` row `retro-test` |
| manifests | `agents/coordinator/retro-argo.yaml` (WorkflowTemplate `retro-session` + CronWorkflows `retro-session`, `retro-feedback-triage`), `agents/coordinator/retro-activity-argo.yaml` (`retro-activity` + `retro-activity-collect` */30 + `retro-findings-reconcile` 07:30), `agents/coordinator/retro-git.yaml` (the read-only fleet token) — all listed in `agents/coordinator/kustomization.yaml` |
| runtime-read templates (stay in place) | `docs/agents/retros/BRIEF.md`, `docs/agents/retros/CROSS-REVIEW.md`, `docs/agents/retros/SERIES-BRIEF.md` — `retro-session.sh` substitutes them; the rest of `docs/agents/retros/` is the series' output, historical, never edited |
| detector | `RetroReportOverdue` in `argocd/resources/pushgateway/prometheusrule.yaml` (a shared file — the retro owns that one rule) + `argocd/resources/pushgateway/retro-report.promtool-{rules,test}` |
| replay fixtures | `agents/replay/fixtures/retro-quiet-guard`, `retro-gateway-cell`, `retro-key/*`, `retro-cell-report/*`, `retro-harvest`, `retro-harvest-push`, `retro-push-belt`, `retro-activity-window`, `retro-rank-snapshot-exclusion` |
| fixtures it shares with the launch island | `retro-gh-token-env/*`, `retro-pg-env` (pin `agent-session.sh`'s rendering of `RETRO_GH_SECRET` / `RETRO_PG_SECRET`), `argv-payload/retro-handoff` (pins the argv ceiling at the retro hand-off) — the code is the launch island's |

Not members, though named alike: `agents/ledger.py` + the `ledger-reflex` (the emitter the retro
reads — shared observability, `docs/agents/observability-and-retro.md` §B1), the `skill-retro` jail
skill, `agents/meta-needs-attention.sh`'s `retro-batch` container rule.

## Contracts

**Consumes**

| what | from | how |
|---|---|---|
| `POST /sessions` for role `retro` (caller `agent-coordinator:agent-coordinator`, bind into the ride namespace) | the gateway island — [`gateway/specs/endpoints/sessions.md`](../../../gateway/specs/endpoints/sessions.md), [`access.md`](../../../gateway/specs/access.md) | through `agent-session.sh` + `agents/gateway-admit.sh` (`AGENT_GATEWAY=sessions`); the served model comes back on the ride log's dispatch line |
| the ride itself (pod, env rendering, `RETRO_GH_TOKEN`, `PGUSER`/`PGPASSWORD`, `pr-open`) | the launch island — `agents/agent-session.sh` | `--harness`, `--task`, `--run`; the old-proxy branch also `--model`, `--openrouter-secret` |
| the task ledger `s3://agent-transcripts/_ledger.jsonl` | the ledger emitter — `agents/ledger.py` | read whole, windowed by `ts` ([RETRO-LEDGER-WINDOW](specs/pipeline.md#retro-ledger-window)) |
| GitHub activity (issues, timelines, reviews, check runs, agent-summary markers) | GitHub via `retro-git` (read-only) | [RETRO-ACTIVITY-COLLECT](specs/activity.md#retro-activity-collect) |
| repo scope | the AgentStack claims (live) over `agents/stacks.json` | `kubectl get agentstacks` |
| a series' guard gauge | Prometheus (`oracle_feedback_untriaged_oldest_age_seconds`, oracle's exporter) | [RETRO-GUARD-EXPR](specs/guard.md#retro-guard-expr) |
| the machine-block parser | `agents/issue_body.py` (ADR-122) | `parse_block`, `get` |

**Exposes**

| what | to | contract |
|---|---|---|
| reports `docs/agents/retros/<date>-<series>-rN-<model>.md` via a PR | the operator, the next run's numbering | [harvest.md](specs/harvest.md) |
| `_retro/<series>/{checkpoint,findings,decisions,…}.json`, `_retro/activity.json` | the seat, the next run | [pipeline.md](specs/pipeline.md), [findings.md](specs/findings.md) |
| `retro_report_last_success_timestamp{job="platform-retro",series,outcome?}` | `RetroReportOverdue` | [RETRO-BELT](specs/harvest.md#retro-belt) |
| accepted findings as issues (`agent-fix` + `agent/queued`, bound to `retro-batch: <series>-rN`) | the stack loops | [RETRO-ACCEPT-QUEUE](specs/findings.md#retro-accept-queue) |
| a named series' PR on its stack repo (e.g. oracle-fleet's rules PR) | the stack | its brief, `pr-open` (ADR-157) |

## Read set

A session working on this island loads: this README, [specs/](specs/README.md) (≈ 60 KB with
schemas), [docs/retro-loop.md](docs/retro-loop.md) (≈ 26 KB), and the one member file it touches.
Then, only if the change reaches them: `gateway/specs/endpoints/sessions.md` §GW-SESSIONS-ADMIT (a
cell-path change), `docs/agents/issue-authoring.md` §The lineage contract (a queue/batch change),
`docs/adr.md` ADR-103 (the KPI), ADR-146 (stack series), ADR-157 (a series PR). Not
`docs/agents/` wholesale.

## Revert class

Every member runs from a fresh `git clone --depth 1 -b master` inside the pod (the cells then check
out the bundle's `source_revision`), so a bad change reverts by a **revert PR** — there is no pin to
roll back. The image `ghcr.io/teststuffstash/agent-coordinator` is referenced **untagged** in all
four templates (it floats); a bad image reverts only by rebuilding it. The detector is
`RetroReportOverdue` (silence > 7 d + 3 h per series); a failed run is otherwise visible only as a
Failed workflow.

## Open

- The specs reach no specs reviewer: the claim's `specs` field holds one pair per repo (§C8).
- No evidence pipeline: the fixtures prove clauses, nothing renders them as stories (specs §Rule 5).
- The old-proxy transition path — 13 self-routing sites, the key mint, `retroKeySecret` and the
  `subscription-capacity` semaphore — deletes with the old proxy; the retro-cell's `subscription`
  input is declared and read by nothing.
- `retro-rank.py`, its suite and fixture have no caller; the fixture's text still says the workflow
  calls it.
- The bucket-A count is estimated per cell, computed nowhere; the cells disagree.
- `retro_queue.py` finds its own issues by scanning every issue of the target repo (`state=all`, all
  pages) — a large read against the shared GitHub pool on every acceptance.
- The harvest template's header says "auto-merge NOT armed — a human reads"; the PRs are armed and
  bot-merged (ruling 2026-10-15) — the comment is stale.
- The cells still ride the stack's fixer namespace and may hold its WIP slot (the guard refuses when
  it is busy); "outside the fixer namespace" remains future work in the design doc.
