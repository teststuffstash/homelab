# Glossary — the retro island's ubiquitous language

One definition per term; pages reference terms instead of repeating them. Platform-wide terms keep
their homelab definitions in [`docs/glossary.md`](../../../../docs/glossary.md) — **retro**
(cluster) itself, [the platform stack](../../../../docs/agents/agentstack.md), stint, Goal, role —
and the gateway's terms (session, rail, harness, defer) keep theirs in
[`gateway/specs/glossary.md`](../../../../gateway/specs/glossary.md). This file defines only what the
retro coins or narrows.

## series

One scheduled retro: a *(stack, series)* pair with its own CronWorkflow, guard, brief, state prefix
and report numbering, all riding the one `retro-session` WorkflowTemplate
([`retro-argo.yaml`](../../../coordinator/retro-argo.yaml)). An empty `series` parameter means the
stack's own loop retro, whose series name equals the stack name.

| series | CronWorkflow | slot | guard | cells | brief |
|---|---|---|---|---|---|
| `platform` | `retro-session` | Mon 05:00 UTC | ledger (`minWindowTasks` 8) | 2 (`claude`, `goose`) | `docs/agents/retros/BRIEF.md` |
| `feedback-triage` | `retro-feedback-triage` | Wed 05:00 UTC | PromQL (`guardExpr`) | 1 (`claude`) | oracle-fleet `.agents/feedback-triage.md` via `SERIES-BRIEF.md` |

## window

The half-open interval `[since, until)` one run accounts for. `until` is the most recent Monday
00:00 UTC at or before `--now`; `since` is the series' published checkpoint `until`, or seven days
before `until` on a first run. A window that is refused or never published is not skipped: the next
run's window starts at the same checkpoint and is longer.

## checkpoint

`_retro/<series>/checkpoint.json` — `{until, covered_at, bundle_id, run_id, report_pr}`. Written only
by `retro_pipeline.py publish`; it never moves backwards and never moves on a refused window. The
oldest checkpoint across all series is the prune floor of the shared activity state.

## frozen bundle

`_retro/<series>/runs/<until-stamp>/bundle.json` — the one immutable evidence document every cell and
the harvest of a run read: window, population counters, the bounded worst-K sample, late arrivals,
prior findings, `run_id`, `source_revision`, `prepared_at`, and `bundle_id` (sha256 of the rest). A
retry of the same window reuses it byte for byte; at most 60 000 serialized bytes.

## quiet week

The guard's third verdict beside *fire* and *fail*: there is evidence, but not enough to be worth a
ride. A quiet week is not published (the window rolls forward), rides nothing, and pushes the overdue
belt under its own `outcome=quiet` group. Zero evidence is **not** a quiet week — it is a broken
source and fails the run.

## cell

One ride of a run, named by its **harness** (`claude`, `goose`), never by a model on the platform
stack. On the platform stack a cell is one gateway admission for role `retro`; the gateway serves the
model. Off-platform (and on a refused platform admission) a cell rides the old proxy on its
harness's **transition model**.

## served model

The model a cell's session was dispatched on, read from the cell's own ride log — the first
`→ gateway(sessions): dispatch <model> [` line, else the old-proxy line `→ <stack> rN cell
<harness>:<model> —` — scanning stops at the report's `BEGIN-RETRO-REPORT`. A cell with neither line
is `<harness>:unserved`.

## report

The text between the LAST complete `BEGIN-RETRO-REPORT` / `END-RETRO-REPORT` pair of a ride log,
holding at least 20 **content lines** (lines that are neither blank nor start with `#`). A ride log
with zero or one marker has no report, however long it is.

## candidate finding

One object in a report's single fenced `retro-findings-json` block: `{mechanism, surface, summary,
evidence[], related_work[]}`. A candidate is evidence, never a decision: it cannot carry acceptance,
disposition or queue fields. ⛔ Not the **findings store** of ADR-106 (the Goal's typed machine
comment) — different owner, different record.

## finding

A deduplicated candidate in `_retro/<series>/findings.json`, identified by `rf-` + the first 16 hex
characters of sha256 over its normalized `[mechanism, surface]`. It accumulates **occurrences**
(model, report hash, summary, evidence) across reports and runs and carries a current
**disposition**.

| disposition | entered when |
|---|---|
| `insufficient_evidence` | the default — no evidence-backed decision, or matched work unreadable/closed without a merge |
| `covered_by_existing_work` | the decision's `matched_work` includes an open item and evidence is given |
| `implemented_unverified` | a `matched_work` PR merged; deployment and effect not yet shown |
| `new_work_needed` | the decision asks for it with evidence and no related PR merged after acceptance |
| `verified` / `disproved` | the decision says so explicitly, with evidence |

## decision

The seat's record for one finding, kept apart from the reports in `_retro/<series>/decisions.json`:
`{disposition, evidence[], matched_work[], canonical_issue | issue{repo,title,body,labels},
origin_issue?, accepted_by, accepted_at}`. Only a decision with `accepted_by` + `accepted_at` can
lead to a GitHub write.

## acceptance act

`retro_pipeline.py accept --decisions … [--batch <retro-batch issue>] --apply` — the only path from a
finding to an issue write. Without `--apply` it prints the plan and writes nothing.

## retro-batch

The round container: a label-inert parent issue titled `retro-batch: <series>-rN`, never `task/goal`,
never `agent/*`; each filed finding binds to it as a native sub-issue (the stint shape —
[`docs/glossary.md`](../../../../docs/glossary.md)).

## bucket-A count

ADR-103 (3)'s weekly platform KPI: distinct platform-logic failure events (coordinator / reflex /
prompt / scan defects) in the window. Today a cell counts it in prose under the report's
`## Platform KPIs` heading; no code computes or stores it
([findings.md#retro-kpi-bucket-a](findings.md#retro-kpi-bucket-a)).
