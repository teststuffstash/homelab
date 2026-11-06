# agent-gateway specs — the contract, and how it is worked

> Browsable, with the evidence joined into the decision tables: **[gateway-specs.homelab.teststuff.net](https://gateway-specs.homelab.teststuff.net)**
> (a PR's preview lives at `/pr-<N>/` while it is open) — `../mkdocs.yml`, published by homelab CI;
> the run's Allure report the rows link into is at [`report/index.html`](https://gateway-specs.homelab.teststuff.net/report/index.html).

The spec system for this island, in the oracle-fleet shape: **the reviewer reviews the
result, not the diff.** Every endpoint has a contract page in [endpoints/](endpoints/) with a
sibling `<name>.schema.json`; rows are decision tables of key examples; tests prove the rows
and stamp the commit they ran at (rule 5 below). What the gateway *is* lives one level up
([../README.md](../README.md)); this directory is only the contract.

## Rules — the pinned process, and what this island adds

The numbered rules 1–11, the test & evidence conventions and the reviewer briefs are NOT kept here:
they live ONCE in [allure-behavior-snippets](https://github.com/teststuffstash/allure-behavior-snippets)
([ADR-156](../../docs/adr.md#adr-156--one-portable-specevidence-process-homed-in-allure-behavior-snippets-one-reviewer-runs-two-briefs-2026-10-16)),
pinned by version: **[RULES.md @ v0.6.9](https://github.com/teststuffstash/allure-behavior-snippets/blob/v0.6.9/allure_behavior_snippets/process/RULES.md)**,
**[CONVENTIONS.md @ v0.6.9](https://github.com/teststuffstash/allure-behavior-snippets/blob/v0.6.9/allure_behavior_snippets/process/CONVENTIONS.md)**.
"Rule N" anywhere in this island means rule N there. The pins: `../scripts/lib/snippets.sh` (CI
evidence) and `agents/specs-reviewer-session.sh` (the reviewer's context pack); bump them together.

What this island adds, by rule:

- **Rule 1 (gate):** reviewer-gated, not codeowner-gated (operator ruling,
  [context-and-autonomy.md §Direction 2](../../docs/spikes/context-and-autonomy.md)): the specs
  reviewer ([docs/agents/specs-reviewer.md](../../docs/agents/specs-reviewer.md)) is the island's
  second required approval; ⚖ rows reach the operator as a digest, never as a blocker.
- **Rule 3 (IDs):** the prefix is `GW-`; tests label rows with `rule("GW-…")`.
- **Rule 5 (evidence):** the suite runs in-process against the PR head's source (fake upstreams),
  so `environment.properties` carries `git.commit` and `artifact=pr-head`, never `image.digest`.
  This is PR-head evidence; built-image evidence is an open question
  ([specs-reviewer.md §Open questions](../../docs/agents/specs-reviewer.md#open-questions) 2).
- **Rule 7 (coupling):** enforced by `../scripts/spec_gate.py` inside `devbox run ci` (orphans both
  ways, error codes the page never mentions, a rule with no evidence and no `🚧`/`⚑` mark, a ghost
  rule, a policy world ≠ its fixture twin).
- **The lint gate (CONVENTIONS § The lint gate), this island's commands — all inside `devbox run ci`:**
  the **join ratchet** `../scripts/spec-join-ratchet.py` (item 6 — per rule, `row-unkeyed`,
  `header-unthreaded`, `cell-mismatch`, `case-unspecified` and `row-unproven` — ⚖ the half-join
  hazard, a `∅` row inside a table that joins — held against `../scripts/spec-join-baseline.json`:
  exceeding is red, equal passes, lower prints "lowered"; the fixing PR re-records with
  `devbox run join-ratchet -- --write-baseline` from a FULL run; the join is the pinned tool's own,
  through `allure_snippets_python` in `../scripts/lib/snippets.sh`); the **hygiene ratchet**
  `../scripts/spec-hygiene-ratchet.py` (the digest's hygiene codes as the SET of
  (rule · world · case · code) identities against `../scripts/spec-hygiene-baseline.json` — a new
  identity is red with the case named, fix-one-break-one is red, a renamed case is a new identity;
  `devbox run hygiene-ratchet -- --write-baseline` re-records; declaring it here is what lets the
  evidence brief's repeat belt stop at the cases a PR added or changed, v0.6.9); **lychee** over the
  built site (item 3 — every link and `#anchor` resolves, the joined rows' links into
  `report/index.html` included); the **flowchart gates** — `../tests/test_specs_site_links.py`
  (static: every Mermaid `click … href "#anchor" … _self` lands on an anchor of its page, every
  flowchart on an endpoint page carries one) and `devbox run specs-site-e2e`
  (`../scripts/e2e-specs-site.sh`: the rendered site in the pinned playwright image — every
  diagram renders, every node link navigates to its heading; the repo-root diff-ci row
  `gateway-specs-site-e2e`). Checks 1, 2, 4 and 5 of the gate are `rule()` (a label with no
  heading fails collection), `spec_gate.py` and the `ids=` discipline of every row module.
- **Rule 9 (external facts):** the wire facts this island rests on are read in
  `docs/agents/chainless-redesign.md §Proved on the wire` and OpenRouter's `openapi.json`.
- **Rule 10 (incompleteness):** everything OUT of v0 is a `⚑ gap` row on the requirement it would
  belong to — the ADR-096 ladder past its capacity half, the FU-088 latches the admission rows do
  not cover, the capacity doorbell, `/route`
  compatibility, the git broker (FU-269), the Zen rail, the codex rail's production credential
  write-back / upstream profile / report ingress, the cost ledger, HA (FU-271).
- **Worlds:** every row names its world ([worlds/README.md](worlds/README.md)) — a policy state
  plus a fake-upstream behaviour; tests carry it as the `world` label.
- **Table shape:** the rows brief's checklist is a CANDIDATE under the operator's iteration and
  advisory only; `spec_gate.py` reports split candidates and never fails on them. **Expected
  columns end in `?`** (CONVENTIONS § The intent column, v0.6.3): `decision?` is the argname
  `expected_decision`; inputs first, expected last, every input a cell (the world names what the
  world already fixes; a prose "Inputs:" line is a cell that was not written). The older `||`
  divider is still read by the pinned join and remains on the pages not yet migrated; a page that
  migrates drops it — the join ratchet's lines are what mark the migration's progress per rule.
- **Page shape (the oracle-fleet ingestion pages, 2026-11):** a contract page opens with a
  **flow overview** (one Mermaid flowchart whose every node `click`s into the requirement that owns
  it — the page's navigation, gated above), then a **requirement index** table (Requirement ·
  section · Status — the `🚧 WIP` / `⚑ gap` marks of rule 10 live in its Status cell, where the
  gates read them), then one section per step with its own flowchart, then the rules. A rule that
  outgrows one question (the split candidates `spec_gate.py` prints) is split, the old anchor kept
  as `<a id="…"></a>` on the line above the new heading (rule 3's alias — never an attribute on the
  heading, which the gates read bare).

## Endpoint contract page template

```markdown
---
id: EP-<NAME>
use-cases: [UC-1]
schema: <name>.schema.json
---
# <METHOD> <path> — one-line purpose

## Interface — the machine half
<coupling table: requirement → schema paths → error codes → status (🚧 WIP / ⚑ gap marks here)>

## Flow overview
<one mermaid flowchart; every node: click <node> href "#gw-<req>" "<tooltip>" _self>

## <step> — one-line purpose (`GW-<STEP>-*`)
<the step's own flowchart, nodes linking into its rules>

### GW-<REQ>
<prose constraint — the system, never its tests (rule 11); unproven facts marked in place>
**World: [<world>](../worlds/README.md#…)** — what the world fixes for every row below.
#### <one question per table>
Legend: `<col>` = …; `<col>?` = … (short literals decoded once, here).
<decision table: description | world | inputs… | expected?… — header == the proving test's argnames>
<details markdown="1"><summary>Evidence — latest run</summary> --8<-- "GW-<REQ>.md" </details>
```

## Index

Start here: **[use-cases/uc-1-worker-ride.md](use-cases/uc-1-worker-ride.md)** (the spine) →
[endpoints/sessions.md](endpoints/sessions.md) (the control plane) →
[endpoints/anthropic-messages.md](endpoints/anthropic-messages.md) +
[endpoints/openai-chat.md](endpoints/openai-chat.md) +
[endpoints/openai-responses.md](endpoints/openai-responses.md) (the data plane; the last is the codex rail, lit 2026-10-22) →
[endpoints/metrics.md](endpoints/metrics.md) · [endpoints/health.md](endpoints/health.md) ·
[endpoints/catalog.md](endpoints/catalog.md) (the Go rail's vendor facts; the tier evidence) ·
[access.md](access.md) (the role × stack × service inventory) ·
[glossary.md](glossary.md) · [worlds/](worlds/README.md).

| Requirement | Page | What it pins |
|---|---|---|
| [GW-SESSIONS-ADMIT](endpoints/sessions.md#gw-sessions-admit) | sessions | may this unit run now, on which rail · `⚑ gap (2026-11-01, PR #3105 → work #3108)`: Go account headroom unread |
| [GW-SESSIONS-ENV](endpoints/sessions.md#gw-sessions-env) | sessions | the pod's complete LLM env per harness |
| [GW-SESSIONS-TOKEN](endpoints/sessions.md#gw-sessions-token) | sessions | the session token's shape, storage, lifetime |
| [GW-SESSIONS-RELEASE](endpoints/sessions.md#gw-sessions-release) | sessions | release and expiry refuse the token |
| [GW-SESSIONS-PULL](endpoints/sessions.md#gw-sessions-pull) | sessions | a bound dispatch carries no credential; the bound pod pulls its env once, TokenReview'd |
| [GW-SESSIONS-AUTH](endpoints/sessions.md#gw-sessions-auth) | sessions | the control plane's caller: its projected token, its `callers` entry, the observe/enforce knob |
| [GW-SESSIONS-OUTCOME](endpoints/sessions.md#gw-sessions-outcome) | sessions | the consumer's outcome, the one vocabulary, the strike store |
| [GW-SESSIONS-LIVENESS](endpoints/sessions.md#gw-sessions-liveness) | sessions | a session whose pod is gone is reaped; GET's `state` / `release_reason` |
| [GW-CRED-RESOLVE](endpoints/sessions.md#gw-cred-resolve) | sessions | credential ref → Secret read, caches, verdict classes |
| [GW-REDACT](endpoints/sessions.md#gw-redact) | sessions | no credential value in any log line |
| [GW-RAIL-ANTHROPIC](endpoints/anthropic-messages.md#gw-rail-anthropic) | anthropic-messages | the subscription OAuth rail's wire |
| [GW-RAIL-OPENCODE](endpoints/anthropic-messages.md#gw-rail-opencode) | anthropic-messages | the Go rail's wire, both dialects |
| [GW-MODEL-RESOLVE](endpoints/anthropic-messages.md#gw-model-resolve) | anthropic-messages | the body's model is the session's model |
| [GW-CRED-BOUNDARY](endpoints/anthropic-messages.md#gw-cred-boundary) | anthropic-messages | inbound auth stops here; the upstream credential starts here |
| [GW-RAIL-OPENROUTER](endpoints/openai-chat.md#gw-rail-openrouter) | openai-chat | the per-stack OpenRouter rail's wire; the provider axis — every answer attributed to its provider, the provider selected from the endpoint snapshot and the gateway's own clean-ride evidence, a failed provider relaunched before the first byte |
| [GW-RAIL-CODEX](endpoints/openai-responses.md#gw-rail-codex) | openai-responses | the ChatGPT-subscription rail's Responses wire |
| [GW-CODEX-HEADROOM](endpoints/openai-responses.md#gw-codex-headroom) | openai-responses | account headroom as the codex rail's admission |
| [GW-CODEX-OAUTH](endpoints/openai-responses.md#gw-codex-oauth) | openai-responses | the OAuth lifecycle behind the persistence interface (gateway-local SQLite in production, a FAKE store in tests) |
| [GW-METRICS](endpoints/metrics.md#gw-metrics) | metrics | the `gateway_*` families and their bounded labels |
| [GW-HEALTH](endpoints/health.md#gw-health) | health | liveness and the store mode |
| [GW-CATALOG-GO](endpoints/catalog.md#gw-catalog-go) | catalog | the Go rail's models, prices and per-model plan limits, read from the vendor on a schedule; the last good snapshot |
| [GW-CATALOG-OR](endpoints/catalog.md#gw-catalog-or) | catalog | the OpenRouter rail's registry — the weekly ranking ∩ AA-benched, each candidate's endpoints, the persisted snapshot; a cell enters the order only after a clean, budget-capped entry canary |
| [GW-MODEL-TIERS](endpoints/catalog.md#gw-model-tiers) | catalog | the deployed per-(rail, tier) model lists are derived from benchmark evidence (AA intelligence bands of the rail's best, cheapest per CLEAN ride first, capped) — a committed snapshot, its staleness alert, an equality check; and the admission's rail choice between a model's twin cells on two rails |
| [GW-ACCESS](access.md#gw-access) | access | role × service: allowed / denied / unenforced |
| [GW-CODEX-REFRESH](endpoints/openai-responses.md#gw-codex-refresh) | openai-responses | native Codex OAuth HTTP refresh transport (injectable; production wires it beside the SQLite store) |
| [GW-CODEX-CAPTURE](endpoints/openai-responses.md#gw-codex-capture) | openai-responses | the scoped four-boundary capture of a codex ride and its bundle, `GET /sessions/{id}/capture` |
