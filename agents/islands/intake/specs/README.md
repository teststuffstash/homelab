# intake island specs — the contract, and how it is worked

The spec system for the [intake island](../README.md) (responder + deep dig + island intake), in
the gateway's shape ([`gateway/specs/README.md`](../../../../gateway/specs/README.md) is the
template): every interface a consumer calls or reads has a contract page here with a sibling
`<name>.schema.json`; rows are decision tables of key examples. What the island *is* lives one
level up; this directory is only the contract. Written 2026-11-07 as a spike (draft PR #3147):
**no row here carries evidence yet** — see Rule 5.

## Rules — the pinned process, and what this island adds

The numbered rules 1–11, the test & evidence conventions and the reviewer briefs live ONCE in
allure-behavior-snippets
([ADR-156](../../../../docs/adr.md#adr-156--one-portable-specevidence-process-homed-in-allure-behavior-snippets-one-reviewer-runs-two-briefs-2026-10-16)),
pinned by version: **[RULES.md @ v0.6.9](https://github.com/teststuffstash/allure-behavior-snippets/blob/v0.6.9/allure_behavior_snippets/process/RULES.md)**,
**[CONVENTIONS.md @ v0.6.9](https://github.com/teststuffstash/allure-behavior-snippets/blob/v0.6.9/allure_behavior_snippets/process/CONVENTIONS.md)**.
"Rule N" anywhere in this island means rule N there.

What this island adds, by rule:

- **Rule 1 (gate):** reviewer-gated in intent
  ([context-and-autonomy.md §Direction 2](../../../../docs/spikes/context-and-autonomy.md#direction-operator-2026-10-05--recorded-not-decided-here)),
  ⚑ gap today: the claim's `specs` field admits one root pair per repo and homelab's names the
  gateway's (`agents/specs-reviewer-session.sh` `pack_roots`), so a PR touching
  `agents/islands/intake/specs/` gets the "mechanical: no specs path" approval
  ([§C8](../../../../docs/spikes/context-and-autonomy.md#c8-the-agent-loop-island-re-measured-on-the-october-window-second-jail-2026-11-01)).
  Until the field is a list, the gate for these rows is the code reviewer + the ADR-110 seat read
  (`agents/**` is `codeowner-merge`, [`docs/intake/agent-loop.md`](../../../../docs/intake/agent-loop.md)).
- **Rule 3 (IDs):** prefix `INTAKE-`, areas `SELECT` (the selector), `ADMIT` (the sitting's
  writes), `RUN` (the wired CronWorkflow), `LANE` (cross-cutting over the three lanes), `DIG`
  (the deep dig), `RESP` (the responder).
- **Rule 5 (evidence) — none yet, and honestly so.** The island's proof today is the replay
  harness (`agents/replay/run.sh`, action streams) and three bash harnesses
  (`agents/deep-dig-test.sh`, `agents/island-intake-test.sh`,
  `agents/coordinator/responder-behaviour-test.sh`). None emits Allure results, none labels a
  case with a rule ID, none stamps a commit. So every requirement's Status says
  `🚧 WIP — no evidence pipeline yet (fixture: <dir>)` and names the fixture dir(s) or harness
  section that already proves its rows; a requirement whose behaviour is an LLM sitting's judgment
  (the `ADMIT` area) names the record that exists instead (the dry-run report, the receipt). The
  `fixture` column in the decision tables is that mapping, row by row: it is the island's join
  key until a pipeline exists (a `rule("INTAKE-…")` label on a replay family would make the
  fixture dir the case id). Built-image evidence does not apply — the pods run master's scripts
  from a clone, so PR-head evidence IS deploy evidence for this island.
- **Rule 7 (coupling):** each page has its schema; `x-requirements` annotate the paths. No
  `spec_gate.py` runs here (⚑ gap — the gateway's gate reads `gateway/specs/` only).
- **Rule 9 (external facts):** GitHub REST/search behaviour, Alertmanager's `/api/v2/alerts`,
  Argo's CronWorkflow/retry/semaphore semantics and s5cmd's answer to an empty prefix are linked
  where a row rests on them; the ones read off the wire name where (`island-intake-argo.yaml`'s
  2026-10-28 note on s5cmd), the rest say "verify during implementation".
- **Rule 10 (incompleteness):** the `⚑ gap` rows name what the redrawn contract wants and the code
  does not do — chiefly the self-routing fallback every lane still carries beside `POST /sessions`
  ([INTAKE-LANE-ADMISSION](intake-receipt.md#intake-lane-admission)), the island table living in a
  shell `case`, the issue pile not wired into the CronWorkflow, the graduation dial with no consumer.
- **Worlds:** [worlds/README.md](worlds/README.md) — the pinned clocks and file seams the
  harnesses use, and each replay fixture's own recorded `world/`.
- **Table shape:** description | world | inputs… | `fixture` | expected?… — expected columns end
  in `?`; ⚖ in the description cell for judgment rows.
- **Page shape:** the gateway's — front matter, Interface (coupling table), Flow overview (one
  Mermaid flowchart whose nodes `click` into their requirement), Requirement index (Status cell
  carries the marks), then one section per requirement.

## Index

Start here: **[use-cases/uc-1-key-rows-to-fixtures.md](use-cases/uc-1-key-rows-to-fixtures.md)**
(a janitor filing → an intake `queue` ruling with four key rows → a ride → four fixture dirs) →
[intake-select](intake-select.md) → [intake-ruling](intake-ruling.md) →
[intake-receipt](intake-receipt.md) → [dig-digest](dig-digest.md) →
[dig-finding](dig-finding.md) → [responder-gates](responder-gates.md) →
[responder-verdict](responder-verdict.md) · [glossary.md](glossary.md) · [worlds/](worlds/README.md).

| Requirement | Page | What it pins |
|---|---|---|
| [INTAKE-SELECT-MEMBERSHIP](intake-select.md#intake-select-membership) | intake-select | the island table: first title row, else every `Touches` entry under one island's longest prefix — one island per issue · `⚑ gap`: the table is a shell `case`, not data |
| [INTAKE-SELECT-CANDIDATE](intake-select.md#intake-select-candidate) | intake-select | what is never a candidate: an `agent/*` label, `task/goal`, a container title, an `intake:` ruling |
| [INTAKE-SELECT-ATTRIBUTION](intake-select.md#intake-select-attribution) | intake-select | a bot-filed issue no island claims goes to the agent-loop sitting as `kind: attribution`; a human-filed one goes nowhere |
| [INTAKE-SELECT-FIRE](intake-select.md#intake-select-fire) | intake-select | fire at ≥ `--min` or the oldest ≥ `--age-h`; exit 0 / 1 / 2, a failed read is never an empty answer |
| [INTAKE-SELECT-DIG](intake-select.md#intake-select-dig) | intake-select | the dig source: `cause-found` findings naming the island, inside the lookback, not ruled by an APPLY receipt, island precedence, the daily cap, fail-closed reads |
| [INTAKE-ADMIT-OUTCOME](intake-ruling.md#intake-admit-outcome) | intake-ruling | one outcome per input, and the ONE loop-readable state it leaves the item in · `⚑ gap`: `split` and `file` have no receipt-side twin |
| [INTAKE-ADMIT-MARKER](intake-ruling.md#intake-admit-marker) | intake-ruling | the `intake: <outcome> — <reason>` first line, `blocked-on: human` on a `seat`, one comment per ruling, idempotent re-read |
| [INTAKE-ADMIT-QUEUE-BODY](intake-ruling.md#intake-admit-queue-body) | intake-ruling | the queue-ready body: machine block through the parser, one deliverable, the key rows, the fixture dir in `Touches` for a clause edit |
| [INTAKE-ADMIT-LIMITS](intake-ruling.md#intake-admit-limits) | intake-ruling | never close a human-filed issue; ≤ 3 `queue` per sitting; a Goal is never queued, its budget ≤ the ceiling |
| [INTAKE-RUN-RECEIPT](intake-receipt.md#intake-run-receipt) | intake-receipt | the `INTAKE-RULED:` line protocol and the shell-owned receipt: only this run's ids, only known outcomes |
| [INTAKE-RUN-HOLD](intake-receipt.md#intake-run-hold) | intake-receipt | a hold is a hold only when the selector wrote a selection saying so; a failed selection retries |
| [INTAKE-LANE-ADMISSION](intake-receipt.md#intake-lane-admission) | intake-receipt | every session of the island is admitted by `POST /sessions` (role, task, tier per lane); a defer retries · `⚑ gap`: the rc-4 fallback still picks a rail and a model itself |
| [INTAKE-RUN-BELT](intake-receipt.md#intake-run-belt) | intake-receipt | gauges on every exit path, the staleness alerts, one `/coordinate` ring when something was queued · `⚑ gap`: no detector of harm |
| [INTAKE-DIG-CANDIDATE](dig-digest.md#intake-dig-candidate) | dig-digest | `triage: dig` ∧ (standing ≥ 6 h ∨ ≥ 3 of 7 days); triage resolved from the relabel map for a Prometheus-only name |
| [INTAKE-DIG-EXPLAINED](dig-digest.md#intake-dig-explained) | dig-digest | what explains a candidate — a live window, a prior finding of the same episode, an open issue naming alert and object, an open follow-up, a `dig-explained:` line — recorded, not dropped silently |
| [INTAKE-DIG-GROUP](dig-digest.md#intake-dig-group) | dig-digest | onset bucket × host is one story, for the dig AND the responder (`group-keys`); the cap defers by name |
| [INTAKE-DIG-PROBE](dig-digest.md#intake-dig-probe) | dig-digest | an unreadable Alertmanager is no digest; a missing Prometheus day under-counts; never an empty digest on exit 0 |
| [INTAKE-DIG-FINDING](dig-finding.md#intake-dig-finding) | dig-finding | harvest: a block validates or is dropped loudly; `members` stamped from the run's own digest |
| [INTAKE-DIG-OUTPUT](dig-finding.md#intake-dig-output) | dig-finding | findings go to the bucket, never to issues; a PR only for a mechanical, bot-mergeable fix · `⚑ gap`: the board does not surface findings |
| [INTAKE-RESP-BUDGET](responder-gates.md#intake-resp-budget) | responder-gates | the daily cap counted from write-once `spawn-<date>-<fp>` keys, fail-closed, gauges on both paths |
| [INTAKE-RESP-DECIDED-ONCE](responder-gates.md#intake-resp-decided-once) | responder-gates | an open issue naming the alert with a `fix-verdict:` is decided — one `still-firing:` line, no session; a human close decides for 14 days |
| [INTAKE-RESP-SUBJECT](responder-gates.md#intake-resp-subject) | responder-gates | the subject is the failing object, never the exporter; the cascade both lanes share |
| [INTAKE-RESP-WINDOW](responder-gates.md#intake-resp-window) | responder-gates | a named alert inside a declared window: claimed or cleared → no session, unclaimed → triage with the window in the brief |
| [INTAKE-RESP-SELFREF](responder-gates.md#intake-resp-selfref) | responder-gates | `platform_machinery: "true"` makes the triage self-referential: the never-auto-merge cap in the brief |
| [INTAKE-RESP-FIX-VERDICT](responder-verdict.md#intake-resp-fix-verdict) | responder-verdict | the verdict read back across every claimed repo; `fix` → `agent-fix` (inert) + `/fix-verdict` ring; a reopened record is stripped of its lifecycle labels |
| [INTAKE-RESP-CAUSE-LINE](responder-verdict.md#intake-resp-cause-line) | responder-verdict | a `Cause: #<n>` line binds the filed issue as a native sub-issue of a same-repo cause, or logs why not |
| [INTAKE-RESP-RESOLVE](responder-verdict.md#intake-resp-resolve) | responder-verdict | a cleared alert closes only a bots-only report-only thread; a `fix` thread or a human-engaged one gets one rewritten `last-cleared:` line |
| [INTAKE-RESP-FINDING](responder-verdict.md#intake-resp-finding) | responder-verdict | `responder-finding/v1` per triage, its `remediation_would` harvested from the marker lines; capture never breaks the lane |
| [INTAKE-RESP-TOUCHES-CLASSIFY](responder-verdict.md#intake-resp-touches-classify) | responder-verdict | the filing brief classifies its `Touches` and says a `codeowner-author` verdict in the body |
| [INTAKE-RESP-GRADUATION](responder-verdict.md#intake-resp-graduation) | responder-verdict | the claim-gated `spec.responder` Role, default off · `⚑ gap`: no consumer reads the grant |
