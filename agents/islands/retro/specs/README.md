# retro specs — the contract, and how it is worked

The spec system for the retro island, in the gateway island's shape
([`gateway/specs/README.md`](../../../../gateway/specs/README.md)): **the reviewer reviews the result,
not the diff.** Every interface a consumer calls or reads has a contract page here with a sibling
`<name>.schema.json`; rows are decision tables of key examples. What the retro *is* and which files
it owns lives one level up ([../README.md](../README.md)); the design rulings and their history in
[../docs/retro-loop.md](../docs/retro-loop.md).

## Rules — the pinned process, and what this island adds

The numbered rules 1–11, the test & evidence conventions and the reviewer briefs live once in
allure-behavior-snippets, pinned:
**[RULES.md @ v0.6.9](https://github.com/teststuffstash/allure-behavior-snippets/blob/v0.6.9/allure_behavior_snippets/process/RULES.md)**,
**[CONVENTIONS.md @ v0.6.9](https://github.com/teststuffstash/allure-behavior-snippets/blob/v0.6.9/allure_behavior_snippets/process/CONVENTIONS.md)**.
"Rule N" here means rule N there.

What this island adds, by rule:

- **Rule 1 (gate):** intended reviewer-gated, not codeowner-gated
  ([context-and-autonomy.md §Direction 2](../../../../docs/spikes/context-and-autonomy.md)). ⚑ Not
  wired: the claim's `specs` field admits ONE `{root, tests}` pair per repo and homelab's names the
  gateway's (§C8), so a retro spec change today reaches no specs reviewer — until the field becomes a
  list, or the island moves, the codeowner read is the only gate.
- **Rule 3 (IDs):** prefix `RETRO-`; areas `GUARD`, `WINDOW`, `BUNDLE`, `LEDGER`, `PUBLISH`, `STORE`,
  `ACTIVITY`, `RANK`, `CELL`, `REPORT`, `HARVEST`, `BELT`, `FINDINGS`, `ACCEPT`, `KPI`.
- **Rule 5 (evidence):** **no evidence is generated yet** — this island has no Allure run and no
  `rule()` decorator. Its proofs today are the replay harness's fixtures
  ([`agents/replay/`](../../../replay/README.md) — the island's tests root candidate, P4/P5 of
  [§The plan](../../../../docs/spikes/context-and-autonomy.md)) and three in-process unittest suites
  (`agents/retro-{activity,pipeline,findings}-test.py`, run by the replay suite fixture
  `retro-activity-window` via `agents/retro-cadence-test.sh`). A requirement whose clause has a
  table/actions fixture (`retro-quiet-guard`, `retro-gateway-cell`, `retro-key`, `retro-cell-report`,
  `retro-harvest`, `retro-harvest-push`, `retro-push-belt`) carries the evidence shell; its fragment
  does not exist until a pipeline renders the fixture results as Allure stories. Requirements proven
  only by the unittest suites carry no shell: those suites call module functions with fakes, which
  CONVENTIONS § Allure taxonomy counts as unit tests (unlabelled, not evidence). Every index row
  therefore reads `🚧 WIP — no evidence pipeline yet (fixture: …)` or `⚑ gap` — verified-ness is
  derived, and nothing here is verified in that sense.
- **The header is the parameter list (CONVENTIONS § The intent column):** for a psv-backed table the
  description cell is the fixture row's `id` verbatim (with `⚖` prepended where the row is a
  judgment — the psv ids would need to carry it for a join to key them), and the input headers are
  the row's `env` variable names (`PREP_RC`, `CURL_RC_1`, `HANDOFF_RC`, `LOG_A_NAME`, …) — the
  bridge's real argnames. Tables over the unittest suites are written in words and are **unkeyed**
  until those cases become parametrized rows.
- **Rule 7 (coupling):** six pages, six schemas; every heading below is annotated by at least one
  `x-requirements`. No spec gate runs it (the gateway's `scripts/spec_gate.py` is the template); the
  island's `devbox run` has none yet.
- **Rule 9 (external facts):** Linux `MAX_ARG_STRLEN`
  ([cell.md#retro-cell-payload](cell.md#retro-cell-payload)); s5cmd-on-Garage's missing-key wording
  ([pipeline.md#retro-store-read](pipeline.md#retro-store-read)); kubectl's empty-list stderr
  ([guard.md#retro-guard-busy](guard.md#retro-guard-busy)); Argo's `continueOn` failed/error split
  and GitHub's sub-issues API — verify during implementation.
- **Rule 10 (incompleteness) — the gaps this island carries:** the old-proxy self-routing on the
  transition path (13 sites, [cell.md](cell.md#self-routing-left-on-the-transition-path)); the key
  mint that leaves with it ([RETRO-CELL-KEY](cell.md#retro-cell-key)); the queue's label grammar
  ([findings.md](findings.md#grammar-sites-outside-the-shared-parser)); the bucket-A count no code
  computes ([RETRO-KPI-BUCKET-A](findings.md#retro-kpi-bucket-a)); the legacy ranker with no caller
  ([RETRO-RANK-LEGACY](activity.md#retro-rank-legacy)); the busy probe with no fixture.
- **Worlds:** every row names its world ([worlds/README.md](worlds/README.md)) — a replay fixture dir
  or an in-process suite.
- **Coupling:** the island consumes the gateway's `POST /sessions` (role `retro`), the launch
  island's `agent-session.sh` + `gateway-admit.sh`, the ledger emitter's `_ledger.jsonl`
  (`agents/ledger.py`), `agents/issue_body.py` (the ADR-122 machine-block parser) and the AgentStack
  claims (repo scope). It exposes reports in git, `_retro/` state, two metric groups and — through
  the acceptance act only — issues.
- **Page shape:** the gateway's — front matter, Interface table (Status cell carries 🚧/⚑), one
  Mermaid flow overview whose nodes link to the rules, then one section per requirement.

## Contract page template

Identical to the gateway's ([`gateway/specs/README.md` § Endpoint contract page template](../../../../gateway/specs/README.md)),
with `EP-<INTERFACE>` ids, `RETRO-<AREA>-<NAME>` headings, and a `world` column naming a world from
[worlds/](worlds/README.md).

## Index

Start here: **[use-cases/uc-1-weekly-series.md](use-cases/uc-1-weekly-series.md)** (the spine) →
[activity.md](activity.md) → [pipeline.md](pipeline.md) → [guard.md](guard.md) → [cell.md](cell.md)
→ [harvest.md](harvest.md) → [findings.md](findings.md) · [glossary.md](glossary.md) ·
[worlds/](worlds/README.md).

| Requirement | Page | What it pins |
|---|---|---|
| [RETRO-ACTIVITY-COLLECT](activity.md#retro-activity-collect) | activity | the 30-minute transactional pass, event identity, corrections vs new events, transient retries |
| [RETRO-ACTIVITY-SCORE](activity.md#retro-activity-score) | activity | the pain score: weights, cancellation classes, PR → issue crediting, population before sampling |
| [RETRO-ACTIVITY-PRUNE](activity.md#retro-activity-prune) | activity | what a published window lets the shared state forget — below the OLDEST series floor only |
| [RETRO-RANK-LEGACY](activity.md#retro-rank-legacy) | activity | the whole-ledger ranker · `⚑ gap`: no live caller |
| [RETRO-WINDOW-CUTOFF](pipeline.md#retro-window-cutoff) | pipeline | Monday cutoffs, windows from the checkpoint, missed weeks folded in, per-series state |
| [RETRO-BUNDLE-FROZEN](pipeline.md#retro-bundle-frozen) | pipeline | one immutable bundle per window: contents, hash, 60 KB budget, the `--no-ledger` shape |
| [RETRO-LEDGER-WINDOW](pipeline.md#retro-ledger-window) | pipeline | the ledger windowed, never ranked all-time; latest emit wins |
| [RETRO-PUBLISH-CHECKPOINT](pipeline.md#retro-publish-checkpoint) | pipeline | findings parsed before coverage moves; contiguous, never backwards; a partial is recorded |
| [RETRO-STORE-READ](pipeline.md#retro-store-read) | pipeline | missing = first run, unreadable = fail; never a reset |
| [RETRO-GUARD-BUSY](guard.md#retro-guard-busy) | guard | the ride namespace's WIP slot; a failed probe is busy · 🚧 no fixture |
| [RETRO-GUARD-LEDGER](guard.md#retro-guard-ledger) | guard | the ledger guard's three verdicts; zero tasks fails |
| [RETRO-GUARD-EXPR](guard.md#retro-guard-expr) | guard | the PromQL guard of a named series; an absent gauge fails |
| [RETRO-GUARD-QUIET](guard.md#retro-guard-quiet) | guard | a quiet week: skipped cells, no publication, the `outcome=quiet` push |
| [RETRO-CELL-PATH](cell.md#retro-cell-path) | cell | the gateway admission for role `retro`, the rc-75 fallback, the off-platform old proxy · `⚑ gap`: 13 self-routing sites |
| [RETRO-CELL-KEY](cell.md#retro-cell-key) | cell | the old-proxy cell's own xs key; no fallback to the fixer's · `⚑ gap`: leaves with the old proxy |
| [RETRO-CELL-PAYLOAD](cell.md#retro-cell-payload) | cell | the argv ceiling refused before any pod |
| [RETRO-CELL-RUNID](cell.md#retro-cell-runid) | cell | the frozen run id wins; the task key per series |
| [RETRO-REPORT-FLOOR](cell.md#retro-report-floor) | cell | what a report is — the one helper, three callers |
| [RETRO-CELL-SELFCHECK](cell.md#retro-cell-selfcheck) | cell | a cell with no report fails itself; siblings keep running |
| [RETRO-HARVEST-NAME](harvest.md#retro-harvest-name) | harvest | reports named after the served model; collision passes |
| [RETRO-HARVEST-PARTIAL](harvest.md#retro-harvest-partial) | harvest | a dead cell named in the PR body; no report fails the harvest |
| [RETRO-HARVEST-PR](harvest.md#retro-harvest-pr) | harvest | PR reuse on retry; the merge ruling the body states |
| [RETRO-BELT](harvest.md#retro-belt) | harvest | the success push and `RetroReportOverdue` per series |
| [RETRO-FINDINGS-BLOCK](findings.md#retro-findings-block) | findings | the candidate envelope; reports cannot authorize themselves |
| [RETRO-FINDINGS-IDENTITY](findings.md#retro-findings-identity) | findings | identity by mechanism + surface; occurrences accumulate |
| [RETRO-FINDINGS-RECONCILE](findings.md#retro-findings-reconcile) | findings | dispositions derived from decisions + live GETs |
| [RETRO-ACCEPT-QUEUE](findings.md#retro-accept-queue) | findings | the acceptance act: plan, file, bind, queue — idempotent, holds preserved · `⚑ gap`: 7 grammar sites |
| [RETRO-KPI-BUCKET-A](findings.md#retro-kpi-bucket-a) | findings | ADR-103's weekly count · `⚑ gap`: estimated in prose, computed nowhere |
