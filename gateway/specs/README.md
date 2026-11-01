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
pinned by version: **[RULES.md @ v0.6.7](https://github.com/teststuffstash/allure-behavior-snippets/blob/v0.6.7/allure_behavior_snippets/process/RULES.md)**,
**[CONVENTIONS.md @ v0.6.7](https://github.com/teststuffstash/allure-behavior-snippets/blob/v0.6.7/allure_behavior_snippets/process/CONVENTIONS.md)**.
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
- **Rule 7 (coupling):** enforced by `../scripts/spec_gate.py` inside `devbox run ci`.
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
  advisory only; `spec_gate.py` reports split candidates and never fails on them. The `||`
  divider separates input columns from expected columns.

## Endpoint contract page template

```markdown
---
id: EP-<NAME>
use-cases: [UC-1]
schema: <name>.schema.json
---
# <METHOD> <path> — one-line purpose

## Interface — the machine half
<coupling table: requirement → schema paths → error codes → status>

## GW-<REQ>
<prose constraint>
<decision table: description | inputs || expected>
<details markdown="1"><summary>Evidence</summary> --8<-- "GW-<REQ>.md" </details>
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
