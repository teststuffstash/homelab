---
id: UC-1
interfaces: [EP-ACTIVITY, EP-PIPELINE, EP-GUARD, EP-CELL, EP-HARVEST, EP-FINDINGS]
status: spine            # the use case the island is built and tracked around
---
# UC-1 — one week of the platform series: collect → guard → two cells → harvest → accept

**Persona:** the `retro-session` CronWorkflow, Monday 2026-11-09 05:00 UTC, series `platform`
([`uc-1/guard-params.json`](uc-1/guard-params.json) — the template's defaults). **Its one question:**

> *What hurt the fleet last week, which of it is new work, and who decides that?*

The answer is two reports in git, a published window in the bucket, an updated finding state — and
an issue only after the seat accepts a finding. No model is named by the retro: the gateway serves
one per cell.

## Flow

```mermaid
sequenceDiagram
  participant AC as retro-activity-collect (*/30)
  participant S3 as bucket _retro/
  participant G as guard
  participant C as cell (×2)
  participant GW as agent-gateway
  participant H as harvest
  participant GH as GitHub
  actor SEAT as the seat
  AC->>GH: ⓪ read activity (retro-git, read-only) — RETRO-ACTIVITY-COLLECT
  AC->>S3: activity.json (collected_until ≥ Mon 00:00)
  G->>G: ① ride ns openrouter-operator idle? — RETRO-GUARD-BUSY
  G->>S3: prepare: window [11-02, 11-09), 11 ledger tasks ≥ 8 → bundle frozen — RETRO-GUARD-LEDGER, RETRO-BUNDLE-FROZEN
  C->>GW: ② POST /sessions role retro, harness claude / goose — RETRO-CELL-PATH
  GW-->>C: dispatch claude/sonnet · dispatch opencode-go/kimi-k3.1-pro
  C->>C: ③ ride; self-check: report ≥ 20 content lines — RETRO-CELL-SELFCHECK
  H->>H: ④ served models → slugs sonnet, kimi-k3.1-pro — RETRO-HARVEST-NAME
  H->>GH: branch retro/2026-11-09-platform-r11 + PR — RETRO-HARVEST-PR
  H->>S3: ⑤ publish: findings parsed, checkpoint → 11-09 — RETRO-PUBLISH-CHECKPOINT
  H->>H: push retro_report_last_success_timestamp — RETRO-BELT
  Note over S3: ⑥ daily 07:30 reconcile (GET only) — RETRO-FINDINGS-RECONCILE
  SEAT->>S3: ⑦ accept --decisions … --batch retro-batch: platform-r11 --apply — RETRO-ACCEPT-QUEUE
  S3->>GH: issue filed, bound to the batch, agent-fix + agent/queued
```

## The walk, with its data

| step | what happens | data | rules |
|---|---|---|---|
| ⓪ | the collector has read every fleet repo through Monday 00:00 | (`_retro/activity.json`, not committed — large) | [RETRO-ACTIVITY-COLLECT](../activity.md#retro-activity-collect) |
| ① | the guard finds `openrouter-operator` idle and 11 ledger tasks in the window; `prepare` freezes run `r11` | [`uc-1/bundle.json`](uc-1/bundle.json) | [RETRO-GUARD-BUSY](../guard.md#retro-guard-busy), [RETRO-GUARD-LEDGER](../guard.md#retro-guard-ledger), [RETRO-WINDOW-CUTOFF](../pipeline.md#retro-window-cutoff), [RETRO-BUNDLE-FROZEN](../pipeline.md#retro-bundle-frozen), [RETRO-LEDGER-WINDOW](../pipeline.md#retro-ledger-window), [RETRO-ACTIVITY-SCORE](../activity.md#retro-activity-score) |
| ② | cell A (`claude`) and cell B (`goose`) each ask the gateway once for role `retro`; the gateway serves `claude/sonnet` and `opencode-go/kimi-k3.1-pro` | [`uc-1/ride-log-excerpt.txt`](uc-1/ride-log-excerpt.txt) (cell A) | [RETRO-CELL-PATH](../cell.md#retro-cell-path), [RETRO-CELL-RUNID](../cell.md#retro-cell-runid), [RETRO-CELL-PAYLOAD](../cell.md#retro-cell-payload) |
| ③ | each ride ends with a report and one findings block; each cell judges its own log | [`uc-1/report-findings.json`](uc-1/report-findings.json) | [RETRO-REPORT-FLOOR](../cell.md#retro-report-floor), [RETRO-CELL-SELFCHECK](../cell.md#retro-cell-selfcheck), [RETRO-FINDINGS-BLOCK](../findings.md#retro-findings-block) |
| ④ | the harvest names the files `2026-11-09-platform-r11-sonnet.md` and `…-kimi-k3.1-pro.md` and opens the PR | — | [RETRO-HARVEST-NAME](../harvest.md#retro-harvest-name), [RETRO-HARVEST-PARTIAL](../harvest.md#retro-harvest-partial), [RETRO-HARVEST-PR](../harvest.md#retro-harvest-pr) |
| ⑤ | publish parses both blocks: one finding, two occurrences; the checkpoint moves to 11-09; the belt is pushed | [`uc-1/findings.json`](uc-1/findings.json) | [RETRO-PUBLISH-CHECKPOINT](../pipeline.md#retro-publish-checkpoint), [RETRO-FINDINGS-IDENTITY](../findings.md#retro-findings-identity), [RETRO-BELT](../harvest.md#retro-belt) |
| ⑥ | the daily reconcile keeps it `insufficient_evidence` — no decision yet | (same file) | [RETRO-FINDINGS-RECONCILE](../findings.md#retro-findings-reconcile) |
| ⑦ | the seat cross-reviews, writes a decision, and runs the acceptance act; the plan is `create-and-queue` | [`uc-1/decisions.json`](uc-1/decisions.json) → [`uc-1/plan.json`](uc-1/plan.json) | [RETRO-ACCEPT-QUEUE](../findings.md#retro-accept-queue) |
| — | the reports' `## Platform KPIs` carry each cell's own bucket-A estimate | — | [RETRO-KPI-BUCKET-A](../findings.md#retro-kpi-bucket-a) `⚑ gap` |

The walk-through data are illustrative fixture values (issue numbers 9001/9002, a zero source
revision), shaped by the schemas; `findings.json` is what `retro_findings.combine` + `reconcile`
produce for the two candidates with live reads disabled.

## Variants

- **A quiet week** (1–7 ledger tasks): ① ends with `quiet=true`, the quiet push, nothing rides, the
  window rolls into next Monday — [RETRO-GUARD-QUIET](../guard.md#retro-guard-quiet).
- **A dead cell**: ③ fails one cell; ④ files the surviving report and names the dead cell in the PR
  body — [RETRO-HARVEST-PARTIAL](../harvest.md#retro-harvest-partial).
- **A named series** (`feedback-triage`, Wednesdays): ① is the PromQL guard and `prepare --no-ledger`;
  one cell; the brief is oracle-fleet's `.agents/feedback-triage.md` and its output is one rules PR on
  oracle-fleet plus the harvested report — [RETRO-GUARD-EXPR](../guard.md#retro-guard-expr).
