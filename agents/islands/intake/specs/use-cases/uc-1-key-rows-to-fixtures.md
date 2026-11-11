---
id: UC-1
pages: [intake-select, intake-ruling]
status: spine            # the use case the island is tracked around
---
# UC-1 — a bot filing becomes a queued issue whose key rows become fixture dirs

**Persona:** the agent-loop island's intake sitting, ruling one bot-filed issue on the platform
repo. **Its one question:**

> *Can one ride finish homelab#3048 — and if so, what must the ride prove, row by row?*

The janitor tick filed homelab#3048 (2026-10-31 05:53Z: the scan's fleet-fault un-latch holds a
PR-less issue latch forever). Nobody labelled it. The seat-run `/intake` pass gave it to the
agent-loop sitting, which ruled it `queue` at 21:16Z: it rewrote the body to one deliverable, four
acceptance lines and a `## Key rows` table of four rows, and applied `agent-fix` + `task/fix` +
`agent/queued`. The scan dispatched it; the ride's PR #3096 merged 2026-11-01 with **one replay
fixture dir per key row** — three new, the fourth row naming a fixture that already existed. The
island already writes rows; no spec page held them and no reader joined them to what shipped
([§C8](../../../../../docs/spikes/context-and-autonomy.md#c8-the-agent-loop-island-re-measured-on-the-october-window-second-jail-2026-11-01)).
This use case is that join, made explicit. Terms: [glossary.md](../glossary.md).

## Flow

```mermaid
sequenceDiagram
  actor J as janitor tick (bot)
  participant GH as GitHub (homelab issues)
  participant S as intake-select.sh --island agent-loop
  participant I as the agent-loop sitting (gateway/intake.md + docs/intake/agent-loop.md)
  participant SC as scan → launch (a ride)
  participant R as replay harness (agents/replay/)
  J->>GH: ① files #3048, no labels — title "scan: …"
  S->>GH: ② gh issue list --json number,title,body,labels,createdAt,author,comments
  S-->>I: #3048 · 15h · app/homelab-agents-1234 · kind member (title row ^scan) — INTAKE-SELECT-MEMBERSHIP, INTAKE-SELECT-CANDIDATE
  I->>GH: ③ live-verify: the HOLD at coordinator-scan.sh ~L5788; no fleet-fault-unlatch-* fixture covers a PR-less issue
  I->>GH: ④ body rewritten (machine block via issue_body.py; Deliverable; Acceptance 1–4; Key rows ×4; Out of scope) — INTAKE-ADMIT-QUEUE-BODY
  I->>GH: ⑤ comment "intake: queue — …" + labels agent-fix, task/fix, agent/queued — INTAKE-ADMIT-OUTCOME, INTAKE-ADMIT-MARKER
  SC->>GH: ⑥ dispatches #3048 (agent/queued) — the scan's, not this island's
  SC->>R: ⑦ PR #3096: one fixture dir per key row — the join this page states
```

## Walk-through data (the golden thread)

The data lives in [`uc-1/`](uc-1/). It is READ BACK from GitHub on 2026-11-07, not constructed —
except stage ①'s age, which is computed from the issue's `createdAt` and the comment's time.

| Stage | Input | Expected output | Requirements |
|---|---|---|---|
| ② select | the open-issue list (live) | [`uc-1/select-candidate.json`](uc-1/select-candidate.json) | INTAKE-SELECT-MEMBERSHIP, INTAKE-SELECT-CANDIDATE |
| ④–⑤ rule `queue` | #3048 as filed | [`uc-1/writes.json`](uc-1/writes.json) · the body [`uc-1/queue-body.md`](uc-1/queue-body.md) · the comment [`uc-1/ruling-comment.md`](uc-1/ruling-comment.md) | INTAKE-ADMIT-OUTCOME, INTAKE-ADMIT-MARKER, INTAKE-ADMIT-QUEUE-BODY |
| ⑦ key rows → fixtures | the body's `## Key rows` | [`uc-1/key-rows-to-fixtures.tsv`](uc-1/key-rows-to-fixtures.tsv) | INTAKE-ADMIT-QUEUE-BODY |

### The join — key row → fixture dir

| row | key row (verbatim description) | fixture dir | shipped |
|---|---|---|---|
| 1 | PR-less strike latch, cause closed ⇒ un-latch ⚖ | `fleet-fault-unlatch-issue-no-pr` | #3096, new |
| 2 | PR-less strike latch, cause still open ⇒ hold | `fleet-fault-unlatch-issue-no-pr-cause-open` | #3096, new |
| 3 | PR list unreadable ⇒ hold | `fleet-fault-unlatch-issue-no-pr-list-unreadable` | #3096, new |
| 4 | issue with a referencing PR ⇒ today's CI leg | `fleet-fault-unlatch-issue-cause-closed-green` | existed; unchanged |

Acceptance 3 of the body asked for ONE new fixture and the five existing ones byte-identical; the
ride shipped one per new key row. The rows are the scan's (the fixtures replay
`block:fleet-fault-unlatch` of `agents/coordinator-scan.sh`), so they belong on the scan island's
page for that clause when it exists; what this island owns is that its `queue` body carried them
in a shape a ride could turn into fixtures without a second round.

### Canonical calls

| # | Call | Expected |
|---|---|---|
| Q1 | `intake-select.sh --island agent-loop --json` over the 2026-10-31 21:00Z pile | #3048 is a `kind: member` candidate (title `^scan\b`), age 15 h |
| Q2 | the same call after ⑤ | #3048 is absent (it carries `agent/queued` AND an `intake:` comment — either alone removes it) |
| Q3 | `python3 agents/issue_body.py json < uc-1/queue-body.md` | exit 0; `Touches` = the clause file, the first fixture dir, `agents/replay/run.sh`; `Class` = `fix`; `Origin` = the issue itself (verify during implementation — not re-run in this spike) |
| Q4 | the four key rows, joined to `agents/replay/families.tsv` | every row's fixture dir is a `fleet-fault-unlatch` family member (`families.tsv` lines 67–70) |

## What this use case does not cover (so nobody infers it)

The `goal`, `seat`, `fold`, `close`, `standing`, `split` and `file` outcomes (rows on
[INTAKE-ADMIT-OUTCOME](../intake-ruling.md#intake-admit-outcome)); the dig source and the wired
CronWorkflow ([intake-select §dig](../intake-select.md#intake-select-dig),
[intake-receipt](../intake-receipt.md)) — #3048 was ruled by the seat-run pass, so no receipt
exists for it; the responder and the deep dig, which feed intake but did not feed this item. A
`⚑ gap` belongs here: no reader checks the join in Q4 — a PR could ship fewer fixtures than the
body has key rows and nothing would say so.
