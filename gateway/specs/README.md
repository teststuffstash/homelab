# agent-gateway specs — the contract, and how it is worked

> Browsable, with the evidence tables rendered in place: **[gateway-specs.homelab.teststuff.net](https://gateway-specs.homelab.teststuff.net)**
> (a PR's preview lives at `/pr-<N>/` while it is open) — `../mkdocs.yml`, published by homelab CI.

The spec system for this island, in the oracle-fleet shape: **the reviewer reviews the
result, not the diff.** Every endpoint has a contract page in [endpoints/](endpoints/) with a
sibling `<name>.schema.json`; rows are decision tables of key examples; tests prove the rows
against the built service and stamp the image digest. What the gateway *is* lives one level up
([../README.md](../README.md)); this directory is only the contract.

## Rules

1. **Specs are REVIEWER-gated, not codeowner-gated** (operator ruling —
   [context-and-autonomy.md §Direction 2](../../docs/spikes/context-and-autonomy.md)). A
   second reviewer — the specs lens, reading ONLY `specs/` + evidence, never implementation
   code — gates spec rows; its brief is `agents/lenses/specs.md`. The operator reads ⚖ rows as a
   digest and does not block. Agents *propose* changes freely in the same PR as the
   implementation, **flagged in the PR body** (`Spec changes:`). Rows encode *intent*; never
   adjust a row to match observed behaviour without flagging it as a judgment change — a row
   golden-mastered from the diff is the lens's #1 failure.
2. **Grown, not pre-written.** An issue carries a handful of key rows (happy path + the failure
   modes worth a conversation). The implementing agent adds boundary rows as it finds them, splits
   a requirement when it accretes too many tests, and proposes glossary terms. Spec refactoring is
   routine work.
3. **One ID namespace.** Requirement IDs (`GW-…`) are spec-page headings, test labels
   (`@rule("GW-…")`), error codes, and log fields. IDs are stable coordinates; a heading is its
   anchor, so it is never decorated (phase, WIP and gap flags live in the page's index table);
   splitting leaves an alias on the old anchor.
4. **Rows that encode judgment** (policy, anything with a plausible alternative) are flagged
   `⚖` in the table's description column; mechanical boundary rows are not.
5. **Evidence** under each table is generated from test runs against the built image and carries
   `image digest · date`. Missing/stale evidence = unverified requirement. Verified-ness is
   derived, never declared.
6. **Glossary terms** ([glossary.md](glossary.md)) are used in rows instead of repeating
   definitions; new terms take the same review path as rows.
7. **Requirement ⇄ schema coupling is mechanical.** Every endpoint page
   `endpoints/<name>.md` has a sibling `<name>.schema.json` — the machine half (input/output/error
   shapes) that the service **imports**, never re-declares. Requirement IDs annotate the schema via
   `x-requirements`; `scripts/spec_gate.py` (inside `devbox run ci`) fails on orphans in either
   direction and on `errors` keys the page never mentions. The page owns *why/when* (rows); the
   schema owns *shape*. A cross-cutting requirement has ONE heading (rule 3) and may be annotated
   from several schemas — the gate resolves an annotation against every page under `specs/`,
   and the annotating page's coupling table links the heading it does not own.
8. **Use-case first.** [use-cases/](use-cases/) pins end-to-end key examples with committed
   walk-through data (launcher request → pod env → per-rail wire pairs → release), so every stage
   has its goalposts before it is built. Endpoint pages cite the use cases that exercise them; an
   endpoint or field no use case needs is a candidate for deletion, not documentation.
9. **External facts are linked with maximal precision.** A row that rests on a vendor's wire
   behaviour names where it was read (`docs/agents/chainless-redesign.md §Proved on the wire`,
   OpenRouter's `openapi.json` path list) and the date; a vendor fact nobody read is marked
   "verify during implementation", never asserted.
10. **The spec is always master; incompleteness is rendered, not hidden in branches.**
    - A requirement MAY land before its implementation, marked `🚧 WIP → #<issue>` in the page's
      requirement index table (never on the heading line — heading text == anchor == ID).
    - **Known implementation gaps are rendered too** (`⚑ gap`, the dual of `🚧 WIP`): when a PR is
      merged forward despite falling short of a requirement, the shortfall is flagged in the
      index row as `⚑ gap (YYYY-MM-DD, PR #N → work #M): <one line>`; the fixing PR deletes it.
      `git log` on the spec file is the audit trail. Flags carry no sequential id — identity is
      (requirement anchor, date, PR#).
    - Removed requirements keep a one-cycle tombstone (~~struck heading~~ + the removing PR).
    - Everything the brief lists as OUT of v0 is a `⚑ gap` row on the requirement it would
      belong to — the ADR-096 ladder, the FU-088 latches, the capacity doorbell, `/route`
      compatibility, the git broker (FU-269), the codex and Zen rails, the cost ledger, HA
      (FU-271). A spec that looks complete but is not strands the worker at the first gap.

## Table shape (the operator's reviewer-shape trial, 2026-09-29)

- A table answers **one question**; rows vary along the same axes. A column that is constant for
  most rows is a mixed question — split the table.
- **One value per cell**: no `{k: v}` records, no lists unless the value IS a set.
- Values are spelled out; no invented notation. The one inherited mark: `||` separates the
  input columns from the expected columns (oracle's shape); `⚖` marks a judgment row (rule 4).
- Size is a smell, not a limit: the gate reports split candidates (> ~6 columns, > ~12 rows, a
  constant column) and never fails on them.
- Every row names its **world** ([worlds/README.md](worlds/README.md)) — a policy state plus a
  fake-upstream behaviour; a row that does not name its fixture is lying by omission.

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
<details><summary>Evidence</summary> --8<-- "GW-<REQ>.md" </details>
```

## Index

Start here: **[use-cases/uc-1-worker-ride.md](use-cases/uc-1-worker-ride.md)** (the spine) →
[endpoints/sessions.md](endpoints/sessions.md) (the control plane) →
[endpoints/anthropic-messages.md](endpoints/anthropic-messages.md) +
[endpoints/openai-chat.md](endpoints/openai-chat.md) (the data plane) →
[endpoints/metrics.md](endpoints/metrics.md) · [endpoints/health.md](endpoints/health.md) ·
[access.md](access.md) (the role × stack × service inventory) ·
[glossary.md](glossary.md) · [worlds/](worlds/README.md).

| Requirement | Page | What it pins |
|---|---|---|
| [GW-SESSIONS-ADMIT](endpoints/sessions.md#gw-sessions-admit) | sessions | may this unit run now, on which rail |
| [GW-SESSIONS-ENV](endpoints/sessions.md#gw-sessions-env) | sessions | the pod's complete LLM env per harness |
| [GW-SESSIONS-TOKEN](endpoints/sessions.md#gw-sessions-token) | sessions | the session token's shape, storage, lifetime |
| [GW-SESSIONS-RELEASE](endpoints/sessions.md#gw-sessions-release) | sessions | release and expiry refuse the token |
| [GW-CRED-RESOLVE](endpoints/sessions.md#gw-cred-resolve) | sessions | credential ref → Secret read, caches, verdict classes |
| [GW-REDACT](endpoints/sessions.md#gw-redact) | sessions | no credential value in any log line |
| [GW-RAIL-ANTHROPIC](endpoints/anthropic-messages.md#gw-rail-anthropic) | anthropic-messages | the subscription OAuth rail's wire |
| [GW-RAIL-OPENCODE](endpoints/anthropic-messages.md#gw-rail-opencode) | anthropic-messages | the Go rail's wire, both dialects |
| [GW-MODEL-RESOLVE](endpoints/anthropic-messages.md#gw-model-resolve) | anthropic-messages | the body's model is the session's model |
| [GW-CRED-BOUNDARY](endpoints/anthropic-messages.md#gw-cred-boundary) | anthropic-messages | inbound auth stops here; the upstream credential starts here |
| [GW-RAIL-OPENROUTER](endpoints/openai-chat.md#gw-rail-openrouter) | openai-chat | the per-stack OpenRouter rail's wire |
| [GW-METRICS](endpoints/metrics.md#gw-metrics) | metrics | the `gateway_*` families and their bounded labels |
| [GW-HEALTH](endpoints/health.md#gw-health) | health | liveness and the store mode |
| [GW-ACCESS](access.md#gw-access) | access | role × service: allowed / denied / unenforced |
