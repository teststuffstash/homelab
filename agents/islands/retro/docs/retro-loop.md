# The retro loop — design and history

**Owner: the retro island** ([`../README.md`](../README.md)); its contract is [`../specs/`](../specs/README.md).
This is the design prose of the platform retro, moved here 2026-11-07 from
[`docs/agents/observability-and-retro.md`](../../../../docs/agents/observability-and-retro.md)
Part B (the activity half of §B1, all of §B2 and its multi-model pilot subsection; the old headings
stay there as pointers). What stays in that doc is the shared observability substrate the retro
CONSUMES: session capture (§A1), the task ledger's row schema (§B1's ledger half — `agents/ledger.py`,
the emitter), and the emit channels. Where this prose and the code disagree, the island's spec pages
mark the disagreement (⚖); this page keeps the rulings and their history.

## The activity collector

No LLM turn. Collect new activity every 30 minutes, including ongoing issues and their linked
PRs, reviews, check runs and dated machine-summary entries (`agents/retro_activity.py`). Issue creation or closure is not the selection
boundary: an issue can contribute new activity to multiple periods. Preserve stable event IDs,
event time and collection time so retries deduplicate and late observations remain visible.
The activity state lives at `agent-transcripts/_retro/activity.json`. The task ledger
(`agent-transcripts/_ledger.jsonl`, emitted by `agents/ledger.py`) is **windowed, never ranked
all-time**: the bundle's `ledger` section carries only the rows *emitted* inside the window (the
latest emit per task supersedes a mid-flight snapshot), population counters (exit statuses, error
classes, first-touch model) computed before its worst-K sample — the per-round facts the activity
feed cannot see. The all-time pain rank was the r4–r6 failure: the same August tasks (#913,
#625, #778…) filled every deep-dive set while a 9-round task emitted that week never ranked. The
guard's `minWindowTasks` floor counts these window tasks; a refused window is not published, so it
rolls into the next. Its intended statistics include:
cost vs estimator band (**calibration error**), rounds used, retry storms (the 812×-403 class),
CI red/green sequence, review flip-flops, wall time, cache-hit %, requests, tokens/request.
Grafana dashboard over the ledger = the long-promised stats v2 (**FU-057**). These numbers are also
the KPI set the retro measures itself against: cost/issue, rounds/issue, blocked rate, estimator
error.

## The weekly session


A budget-capped full session runs Monday at **05:00 UTC**, with a seeded brief:

1. Freeze one evidence bundle for both model cells. Its half-open activity window is
   `[previous covered cutoff, Monday 00:00 UTC)`. Advance coverage only after successful report
   publication; a missed run therefore extends the next window. Compute population KPIs over
   all eligible activity, then select bounded worst-K deep dives by cost/harm incurred within
   the window (and one *good* run as contrast). Historical trails explain the selected events;
   their older rounds never enter the period totals.
2. Read the selected GitHub trails (transcript MCP remains unbuilt, [observability-and-retro.md §A2](../../../../docs/agents/observability-and-retro.md)); root-cause each: where did the agent loop, misread,
   lack a fact the issue should have carried, fight a tool, retry into a wall?
3. Emit ONLY through existing seams:
   - a dated **retro report in git** (`docs/agents/retros/<date>.md`) — durable, reviewable;
   - **PRs editing the process files** — `fix.yaml` instructions, `review.md`, the coordinator
     `TICK_PROMPT`, `estimate_budget.py` bands, issue templates. These paths are human-gated, so
     the system proposing changes to its own process stays behind a human read — the "spec is
     grown" principle applied to the process itself;
   - follow-up issues for platform gaps.
4. **Score the previous retro first**: each report opens by checking the ledger KPIs across its
   predecessor's deployed changes (did rounds/issue actually drop?). Score post-deployment
   opportunities; a merge alone is not evidence of effectiveness. Say "insufficient evidence"
   when no suitable opportunities occurred.
5. **Distill wins, not just failures (the Devin-playbook move).** When a run lands notably under
   estimate / first-round-approved, the retro may extract the reusable procedure into the recipe
   or a skill file — same PR gate. Codifying what worked compounds faster than only patching what
   broke.

### Coverage and freshness

**Coverage and freshness.** Persist the cutoff and source revision with the immutable bundle;
issue numbers, report merge dates and “eight new tasks” are not time filters. An inbound
reference to an old issue is new reference activity, not a replay of that issue's worker rounds.
Late-collected events appear as labelled corrections to their original period and are not
counted twice. Carry standing stalls separately, accruing only their overlap with this window;
quiet waiting must not disappear merely because nobody commented. Missing timestamps or
incomplete sources reduce confidence explicitly instead of manufacturing weekly totals.

### Findings disposition

**Findings disposition (FU-058).** Each report emits structured candidate findings using the
[brief's output contract](../../../../docs/agents/retros/BRIEF.md); [cross-review](../../../../docs/agents/retros/CROSS-REVIEW.md) checks their
evidence and combines duplicates across cells by mechanism and affected surface. Preserve the
historical occurrence separately from current action status. Reconcile at human acceptance,
immediately before queueing, and in a lightweight daily pass: a Tuesday fix can satisfy a
Monday recommendation without erasing last week's failure. Compare the substance of linked
fixes, not just issue titles or closure labels. Dispositions distinguish new work needed,
existing work, implemented, disproved and insufficient evidence. A recurrence after deployment
extends the existing finding and reassesses that fix.

Report publication does not approve a finding or authorize queueing. Human acceptance remains
explicit under [issue-authoring's launch policy](../../../../docs/agents/issue-authoring.md); separate authorized
execution queues accepted work through the existing lanes. Daily reconciliation updates
pending findings without dispatching another full-model retro or silently accepting them.
The round container remains a `retro-batch` stint (below), never an automatically launched Goal.
Report publication, findings disposition and execution are separate completion signals.

### Operating the cadence

**Operating the cadence.** `agents/retro_pipeline.py` owns bucket persistence and the cutoff.
`agents/coordinator/retro-activity-argo.yaml` collects at `*/30` and reconciles daily at
07:30 UTC; `retro-argo.yaml` prepares one artifact at 05:00 Monday, passes it to both cells,
and advances the checkpoint after publishing the report PR. A retry reuses the same bundle.
State and reports persist below `_retro/<series>/`; the shared activity state is `_retro/activity.json`.
The new collector reads live claims over the committed mirror and reports when that read failed.

The initial bootstrap covers the preceding complete week. Subsequent windows start at the
published checkpoint, even after missed runs. Collection failures leave state unchanged and
prevent a new bundle claiming incomplete coverage. The bundle exposes all-population counts,
its sampled event/task counts, and late-arrival counts. The current collector does not join S3
session manifests or legacy commit statuses: unknown run/cost coverage stays unknown, and
machine stats records on an issue and PR are not assumed to be distinct worker attempts.
Ranking uses observed CI/review failures, direct activity and standing idle exposure; total
role-cost ranking awaits the existing FU-058 emitter work. Old undated ledger totals are never
substituted for missing weekly measurements.

### Accepting work

**Accepting work.** After cross-review, supply a separate JSON decisions file keyed by finding
ID. A decision carries `disposition`, evidence URLs and `matched_work` URLs for substantively
matched fixes. `accepted_by` and `accepted_at` explicitly record the seat's acceptance;
model candidate JSON cannot carry these fields. Use `canonical_issue` for existing work, or an
`issue` object with `repo`, `title`, a machine-block `body` (`Touches`, `Base: master`) and
`labels` (a `task/*` classification) for new work. New standalone work needs an existing open
`retro-batch` passed as `--batch`; origin-derived findings use `origin_issue` instead.

```bash
# Bucket credentials as for the collector; default only reads and prints the action plan.
python3 agents/retro_pipeline.py accept --decisions /tmp/accepted.json --batch https://github.com/OWNER/REPO/issues/N
# Explicit acceptance act: persist decisions, recheck current work, file/bind, then queue.
python3 agents/retro_pipeline.py accept --decisions /tmp/accepted.json --batch https://github.com/OWNER/REPO/issues/N --apply
```

The standalone `agents/retro_queue.py` takes `--state`, `--decisions`, `--receipts` and the
same `--batch`/`--apply` options for a local rehearsal. Scheduled reconciliation performs
GETs only against GitHub and never calls acceptance. A related PR merged after acceptance
requires renewed substance checking; a closed issue does not prove a fix. Receipts and exact
finding markers prevent retry duplicates. Existing lifecycle holds are preserved.


### Guardrails and ownership

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

### The split

**⚖ THE SPLIT (operator ruling, 2026-08-17, from the r4 evidence): the retro divides into the
PLATFORM retro and per-stack retros — built in that order.**

1. **The platform retro FIRST — BUILT 2026-08-19 (the #587 [stint](../../../../docs/agents/chainless-redesign.md), legs on #588/#589/#590/#591).**
   r4 ("oracle r4", PR#454) proved the shape: the pain-rank reads the WHOLE `_ledger.jsonl` with
   no stack filter, the worst-K landed on circles/homelab/openrouter-operator/sleep rows while
   oracle sat quiet, and every finding targets a PLATFORM artifact. That is correct, not a bug —
   **structural problems require looking into the stack repos; no way around it** (operator).
   As built: the workflow's `stack` param defaults `platform` (series `platform-rN`, ride ns =
   [the platform stack](../../../../docs/agents/agentstack.md)'s fixer ns via `agents/retro-project.sh` — the ONE stack→ns map, shared
   with the guard, whose busy-probe now checks only the ride namespace: WIP-slot locality);
   ACCESS tracks the questions — a fleet-wide READ-ONLY `retro-git` token (App-minted, delivered
   by the FU-080 (a) mirror pattern, never as manifest text — PR#619) reaches the ride as
   `RETRO_GH_TOKEN`; the jail-$/day KPI LEFT the brief (route-or-drop ruled DROP — its home is
   the operator's Grafana subscription/gometer dashboards, and the query was dark from the pod
   on every run).
2. **Stack retros SECOND, their briefs authored AGAINST the platform retro's coverage** —
   deliberately non-overlapping: stack-local concerns only (recipe quality, spec adherence,
   the stack's own model cells); the cross-cutting classes the platform retro owns are
   ESCALATED from a stack retro (ADR-146), never fixed there. Every stack runs one by default
   since ADR-146 (the claim knob is an opt-out, not a graduation gate); the escalation contract
   is authored INTO the stack brief template with the platform reports in hand.
   **Stack series (ADR-146, accepted 2026-10-04).** The same workflow with `stack=<name>`:
   ride ns = the stack's fixer ns (`agents/retro-project.sh`), git identity = the stack's own
   worker token (its repos + the public platform repos — the platform series alone mounts
   `retro-git`, #2215; a NAMED series (#3140) holds only the stack repo's worker token, since it writes its
   rules PR and issues there — `retro-session.sh` `retro-series-identity`), bundle + ledger guard scoped to the claim's repos, its own weekly slot
   (platform Mon 05:00Z; stacks on later days — the subscription semaphore and the ride-ns
   busy-probe serialize them); the guard's event floor gates every fire, which is what makes
   default-on safe. Context = `BRIEF.md` rendered for the stack + whatever the stack repo gives
   every ride (its CLAUDE.md, `.agents/`); a stack may replace the brief wholesale with its own
   `.agents/retro.md` — the placeholders and the report markers the harvest self-check reads
   stay the platform's. The brief asks for attribution with evidence (platform cause vs the
   stack's own; unseen-from-the-stack = platform), not a rubric. Platform-attributed findings
   target homelab with `Origin:` = the stack item and ride the acceptance act (`retro_queue.py`
   takes a per-finding repo; the seat adds the cross-repo `blockedBy` edge; board intake, or
   INTO a covering platform Goal per ADR-122 (4)). The platform series keeps the bundle's
   fleet-wide population counters and narrows its deep-dive set to the platform claim's repos.
   Build = FU-058's next; oracle first, hand-fired after platform r7.
   **Named series (homelab#3140, operator ruling 2026-11-02).** A stack may run MORE than its
   loop retro on this mechanism: `retro-argo.yaml` is one WorkflowTemplate and one CronWorkflow
   per *(stack, series)* — the platform series (`retro-session`, Mondays) and the first named
   series, oracle's `feedback-triage` (`retro-feedback-triage`, Wednesdays, born suspended): the
   batched read of the `give_feedback` rows no FB-RULES rule decides, ending in one rules PR on
   oracle-fleet. What a named series owns and what it reuses: its **brief** is the stack repo's
   `.agents/<series>.md`, reached through the platform's pointer
   [`retros/SERIES-BRIEF.md`](../../../../docs/agents/retros/SERIES-BRIEF.md) (which fixes the run's coordinates and the
   report contract — markers, content floor, one `retro-findings-json` block, usually empty); its
   **guard** is a PromQL instant query (`guardExpr`, parsed by `agents/retro_guard_expr.py`: > 0
   fires, 0 is a quiet week, an EMPTY result or a dead Prometheus FAILS the run — an absent gauge
   is a broken exporter, never a quiet week), with `retro_pipeline.py prepare --no-ledger`
   freezing the run's coordinates and no ledger read; its **state** is `_retro/<series>/`, its
   reports `docs/agents/retros/<date>-<series>-rN-<model>.md`, its belt group
   `series=<series>` (RetroReportOverdue reads `max by (series)`, so a fresh platform push never
   hides a stale sibling); its **cell** is ONE (`harnessB` empty — two cells would open two PRs),
   carries `pr-open` on PATH (ADR-157; agent-session.sh's `AGENT_PR_OPEN`) and, when the brief
   reads a database, the basic-auth Secret `cellPgSecret` as `PGUSER`/`PGPASSWORD` — a NAME
   rendered to in-namespace secretKeyRefs, the RETRO_GH_SECRET shape; reach is the stack's
   (`fixer.egress.ownServices`). Data a series reads is caller text: counts and rule predicates
   travel, row text never does — not into the report, the PR or an issue.
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

### The round container

**A round's process-change batch binds under ONE round container — stint-kind (operator
ruling 2026-08-26, homelab#949 is the shape).** A retro round is epic-shaped: a bounded
original set (the report's batch), a possible defect tail, and a natural closeout moment.
Whoever files the batch (the seat today; the harvest shell if the lane ever self-files)
mints a label-inert parent (`retro-batch: <series>-rN` — never `task/goal`, never `agent/*`)
and binds each filed issue as a native sub-issue; the children still ride their own lanes
individually. The lineage contract's rules apply unchanged
([issue-authoring.md](../../../../docs/agents/issue-authoring.md) §The lineage contract) — a defect in a batch fix
binds to the round, and close = tree-empty at a sweep. The closeout READ is free by
construction: the next report's predecessor-scoring (step 4 above) already judges the batch,
so the sweep after it is the earliest close. r1's batch was bound retroactively (#949);
"standalone (retro process-change batch)" body lines are superseded by the container from r2 on.

### Cadence status

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
DELIVERED platform r1 2026-08-25 (PR#918; batch #927–#932); the series has run weekly since —
r2 2026-08-31 through r9 2026-10-19, both cells each round ([`retros/`](../../../../docs/agents/retros/)). Remaining
FU-058 legs: ledger emitter gaps (brief-v2(b) + r4's three blind spots), MCP transcript slices,
stack retros second (§The split point 2) — the tracker item holds the current next step.

## The multi-model pilot — what runs 1–3 taught


The retro was chosen as the **first multi-large-model tryout** (operator direction 2026-07-25): N
models over the SAME worst-K ledger slice in parallel, then a **cross-review** round where each
critiques the others' reports and the human reads the critiques. It is the safest arena for it —
read-only inputs, human-gated outputs — and the task shape is the FU-095 reasoning/audit tier.
Runs 1+2 are in [`retros/`](../../../../docs/agents/retros/); the brief they produced is
[`retros/BRIEF.md`](../../../../docs/agents/retros/BRIEF.md) + [`retros/CROSS-REVIEW.md`](../../../../docs/agents/retros/CROSS-REVIEW.md), driven
by `agents/retro-session.sh`. The routing evidence harvested for FU-095:

| Cell | Verdict |
|---|---|
| deepseek-v4-pro, hy3 | the **audit tier** — opus-adjacent grounding at $0.02–0.08 |
| kimi | useful **wide-net second reader** |
| gpt-oss-120b, nemotron-super | **fabricators** on evidence work — do not use for audit |

Three lessons that still bind the brief:

- **Fix the emitter before adding tools.** The cross-run "could not verify" items were mostly
  **ledger gaps, not access gaps** (`reviewer_rounds=0` despite real rounds, `wall_time_s` not
  decomposed active/idle, an undefined `retry_storms` taxonomy, $0.00-vs-untracked cost
  ambiguity). Prometheus/Grafana access was never the blocker — no report was blocked on metrics.
- **Give the retro read access to the harness source it is asked to improve.** 6/9 models flagged
  naming targets they could not read, and the fabricators invented APIs exactly there.
- **Ask about task GRANULARITY** — which worst-K tasks should have been ONE bigger-model task (or
  a subagent fan-out) instead of chunks, and which chunks needed rework at integration.

**The run-3 shape is the standing design** (composition-axes frame; as-run 2026-08-11 only cell A
executed, homelab#248): two rides off the SAME agent-base image and the SAME committed `BRIEF.md`
— one claude-harness subscription cell, one goose-harness OpenRouter cell — then cross-review with
the **cells swapped**, so rotating them run-over-run separates **harness effect from model effect**
on the FU-057 ledger axes (which doubles as FU-095(b) evidence). Tooling parity is structural:
agent-base ships every harness plus the full toolkit, so retro-er and reviewer are freely mixable.
Standing guardrails: outside the fixer namespace and WIP slot, bounded output tokens, reports land
in `docs/agents/retros/` via PR, the retro token is the stack jail's read-only REPOS boundary, and
**each OpenRouter cell rides an ephemeral key it mints itself** — `retro-session.sh` applies an
`xs`/$0.50 `OpenRouterKey` per (run, cell) and refuses the ride if the operator does not stamp it
(homelab#270). The cap is the lane's own measurement (an audit cell costs $0.02–0.08) × the
estimator's ×2.0 buffer, NOT `estimate_budget.py`'s band — that band models a fixer round and would
cap nothing at ~$0.54. Before #270 the key was an operator step with a warning behind it, and the
ride fell back to the stack FIXER's standing budget key — which is what run 3's dead cell-b spent
a provider retry against.

**On the gateway (FU-270, operator ruling 2026-11-01): the cells stop naming models.** A cell is a
harness (`retro-argo.yaml` `harnessA=claude`, `harnessB=goose` — the ride command is
harness-literal, so the harness narrows each admission to its dialect); on the platform stack each
is ONE `POST /sessions` admission for role `retro` (caller `agent-coordinator:agent-coordinator`,
bound into the ride namespace), and the gateway picks the model per role/tier. The harvest names
each report after the model its session was SERVED — read off the cell's ride log, from the
admission's dispatch line — so the report filename and the published ledger key carry it. The
controlled two-model comparison above is given up: two admissions may be served one model, and the
report names record that instead of forcing them apart. Off-platform stacks, and a platform
admission refused before any request or failed closed (FU-270: transition fallback), ride the old
proxy on the harness's transition model (claude → opus, goose → deepseek-v4-pro;
`agents/retro-session.sh`).
