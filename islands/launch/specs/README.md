# launch specs — the contract, and how it is worked

The spec system for the [launch island](../README.md), in the gateway island's shape
([`gateway/specs/README.md`](../../../gateway/specs/README.md) is the template): **the reviewer
reviews the result, not the diff.** Every interface the launcher exposes has a contract page here
with a sibling `<name>.schema.json`; rows are decision tables of key examples. What the launcher
*is* lives one level up; this directory is only the contract, written from the redrawn interface
([context-and-autonomy.md §Interfaces are redrawn at the cut](../../../docs/spikes/context-and-autonomy.md#interfaces-are-redrawn-at-the-cut-operator-2026-10-05)):
the launcher asks the gateway one question and names no model. Where the code still answers that
question itself, the row is a `⚑ gap`, never the contract.

> **Contract for a fresh build** ([../README.md](../README.md)): these pages specify the component
> to be written under `islands/launch/`; the "code" a row cites is the OLD member it replaces, read
> to explain a difference, never as the source ([Built from the specs](../../README.md#built-from-the-specs-never-copied)). Line citations (`file:<n>`) are against the spike's base `c34535a5`
> (2026-11-07) and have drifted on master — the `REPLAY:` sentinels and fixture dirs are the stable
> anchors. Nothing live reads this directory.

## Rules — the pinned process, and what this island adds

The numbered rules 1–11, the test & evidence conventions and the reviewer briefs live ONCE in
allure-behavior-snippets, pinned by version:
**[RULES.md @ v0.6.9](https://github.com/teststuffstash/allure-behavior-snippets/blob/v0.6.9/allure_behavior_snippets/process/RULES.md)**,
**[CONVENTIONS.md @ v0.6.9](https://github.com/teststuffstash/allure-behavior-snippets/blob/v0.6.9/allure_behavior_snippets/process/CONVENTIONS.md)**
([ADR-156](../../../docs/adr.md)). "Rule N" anywhere in this island means rule N there.

What this island adds, by rule:

- **Rule 1 (gate):** reviewer-gated, not codeowner-gated
  ([§Direction 2](../../../docs/spikes/context-and-autonomy.md#direction-operator-2026-10-05--recorded-not-decided-here)).
  The specs reviewer reads this root: homelab's claim lists it under `extraSpecs` (#3379), a rows
  review with no tests root declared and no evidence — an unproven row carries its `🚧 WIP` / `⚑ gap` mark.
- **Rule 3 (IDs):** the prefix is `LAUNCH-`; areas are `DISPATCH`, `PREFLIGHT`, `ADMIT`, `POD`,
  `BUNDLE`, `CARD`, `OUTCOME`, `BUDGET`.
- **Rule 5 (evidence):** raw Allure results are generated locally by `islands/launch/tests/` (run by
  `islands/launch/scripts/ci.sh`, gated at the worker's `pr-open` through `diff-ci` and in required
  `ci` (#3391)). A labelled case is one row of a page's table, run over the
  worlds under `specs/worlds/` against the Python component under `src/`. The replay harness
  ([`agents/replay/`](../../../agents/replay/README.md)) is the comparison (rule 4 of
  [`islands/README.md`](../README.md#built-from-the-specs-never-copied)), not the gate: a family runs
  through it unlabelled against the old member and against the component, and every difference it
  prints is ruled `spec`, `old` or `new`, the remaining ones ledgered with their ruling beside the
  comparison (`tests/compare/`), the gate failing on an unledgered difference. Nothing is published, so every row stays unproven to the specs reviewer. The Status-cell
  forms (rule 10) are the only two: a requirement an OPEN issue builds or proves says
  `🚧 WIP → #<issue>`, with what runs locally and against which target in parentheses; a gap says
  `⚑ gap (<date>, PR #<n> → work #<m>): <line>`. Every requirement carries the
  evidence shell under its tables (the fragment it would transclude).
  The replay is PR-head evidence by construction (the clause at head, stubbed `gh`/`kubectl`/`curl`)
  — there is no built artifact; the pod image is agent-runtime's.
- **Rule 7 (coupling):** each page's schema annotates its paths with `x-requirements`; no
  `spec_gate.py` runs over this root yet (⚑ gap — the gateway's gate reads `gateway/specs/` only).
- **The join (CONVENTIONS § The intent column):** a case's id is the row's description cell (a
  trailing ` ⚖` dropped); its inputs are the row's cells, read from the page's table at collection —
  `world` names a file under `specs/worlds/`, the other input cells are the case's arguments, and a
  prose cell is asserted in the case that carries the id. A table row with no case, or a case with
  no row, fails the gate.
- **Rule 9 (external facts):** GitHub REST behaviour (pagination, `author_association`,
  `user.type`, check-run conclusions, the run-list `--status failure` semantics) — each marked on
  the requirement that rests on it, read from the recorded worlds' provenance or "verify during
  implementation".
- **Rule 10 (incompleteness):** the old self-routing contract — `/route`, `/router-status`,
  `/opencode-limit`, `/anthropic-limit`, `/report`, the model literals, the strike comments as a
  store — is a `⚑ gap` row on the requirement that replaces it, with counts from the code.
- **Worlds:** every row names its world ([worlds/README.md](worlds/README.md)) — a recorded GitHub
  state, a launcher-variable state, or the gateway seam's reply.
- **Supplier contract:** the gateway's pages are cited by ID
  (`GW-SESSIONS-ADMIT`, `-PULL`, `-OUTCOME`, `-RELEASE`, `-AUTH`, `-RETRY`, `-ENV`), never restated.
  A launcher row pins what the launcher DOES with an answer; what the gateway answers is theirs.

## Contract page template

```markdown
---
id: IF-<NAME>
use-cases: [UC-1]
schema: <name>.schema.json
---
# <interface> — one-line purpose

## Interface — the machine half
<coupling table: requirement → schema paths → exit codes / error lines>

## Requirement index
<Requirement · section · Status — 🚧 WIP / ⚑ gap live here, never on a heading>

### LAUNCH-<AREA>-<NAME>
<prose: the system, never its tests (rule 11); clause cited as `file:line` / `REPLAY:<name>`>
**World:** <world> — what it fixes for every row.
#### <one question per table>
Legend: …
| description | world | inputs… | expected?… |
<details markdown="1"><summary>Evidence — latest run</summary> --8<-- "LAUNCH-<AREA>-<NAME>.md" </details>
```

## Index

Start here: **[use-cases/uc-1-platform-fix-round.md](use-cases/uc-1-platform-fix-round.md)** (the
spine) → [dispatch.md](dispatch.md) (what the scan calls) → [admission.md](admission.md) (what the
launcher asks the gateway) → [pod.md](pod.md) (what it writes) → [context.md](context.md) (what
the worker reads) → [outcome.md](outcome.md) (what it reports) · [budget.md](budget.md) ·
[glossary.md](glossary.md) · [worlds/](worlds/README.md).

| Requirement | Page | What it pins |
|---|---|---|
| [LAUNCH-DISPATCH-ARGV](dispatch.md#launch-dispatch-argv) | dispatch | the argv grammar the scan writes; an unknown flag is a usage refusal |
| [LAUNCH-DISPATCH-EXIT](dispatch.md#launch-dispatch-exit) | dispatch | the exit-code vocabulary · ⚖ two defer conventions (0 and 1) |
| [LAUNCH-PREFLIGHT-BODY](dispatch.md#launch-preflight-body) | dispatch | a malformed machine block refuses before any pod; `Base:` read through the one parser |
| [LAUNCH-PREFLIGHT-ARM](dispatch.md#launch-preflight-arm) | dispatch | auto-merge arming is derived, never passed: base, research recipe, un-armed `major` PR |
| [LAUNCH-PREFLIGHT-DUPLICATE](dispatch.md#launch-preflight-duplicate) | dispatch | one ride per (issue, round): duplicate PRs, the WIP cap, an existing pod |
| [LAUNCH-PREFLIGHT-GOAL-BUDGET](dispatch.md#launch-preflight-goal-budget) | dispatch | the goal-ancestor walk and the `Budget:` gate; one refusal comment, edited in place |
| [LAUNCH-DISPATCH-RECIPE](dispatch.md#launch-dispatch-recipe) | dispatch | `task/<class>` selects the recipe; the recipe must parse; the card is spliced at its marker |
| [LAUNCH-ADMIT-HELPER](admission.md#launch-admit-helper) | admission | `gw_admit` / `gw_admit_lane`: the return-code vocabulary and the `GW_*` outputs |
| [LAUNCH-ADMIT-BOUND](admission.md#launch-admit-bound) | admission | a bound dispatch is checked before use; an unusable one is released, never dispatched |
| [LAUNCH-ADMIT-LAUNCHER](admission.md#launch-admit-launcher) | admission | the launcher's admission: the knob, the bind, the refusals, the fallback exit · ⚑ gap: platform only |
| [LAUNCH-ADMIT-NO-MODEL](admission.md#launch-admit-no-model) | admission | the launcher names no model and holds no latch · ⚑ gap: the old self-routing path, counted |
| [LAUNCH-POD-IDENTITY](pod.md#launch-pod-identity) | pod | the pod's name is the bind's name; (task, round) is the idempotency key |
| [LAUNCH-POD-ENV-PULL](pod.md#launch-pod-env-pull) | pod | a gateway ride's pod carries a pull URL, the keys and a projected token — no credential |
| [LAUNCH-POD-CRED](pod.md#launch-pod-cred) | pod | which credential (or reference) each ride shape carries |
| [LAUNCH-POD-HARNESS-CMD](pod.md#launch-pod-harness-cmd) | pod | the harness command per harness, the model and window it runs |
| [LAUNCH-BUNDLE-DIRECTIVE](context.md#launch-bundle-directive) | context | the issue and its comments are required; unreadable defers |
| [LAUNCH-BUNDLE-TRUST](context.md#launch-bundle-trust) | context | only loop identities and collaborators reach the worker; the rest is withheld and counted |
| [LAUNCH-BUNDLE-FIX-ROUND](context.md#launch-bundle-fix-round) | context | a fix round adds the PR, its reviews and the ARBITRATE ruling |
| [LAUNCH-BUNDLE-CI-RED](context.md#launch-bundle-ci-red) | context | a ci-red round adds the failing checks and the failing run's log tail |
| [LAUNCH-BUNDLE-DELIVERY](context.md#launch-bundle-delivery) | context | the bundle rides a ConfigMap off argv; the argv fallback degrades loudly |
| [LAUNCH-CARD-GROUND-RULES](context.md#launch-card-ground-rules) | context | the ground rules are injected verbatim; missing or empty degrades loudly |
| [LAUNCH-CARD-FACTS](context.md#launch-card-facts) | context | the card's per-ride facts come from the same knobs that built the ride |
| [LAUNCH-CARD-SPECS-PROCESS](context.md#launch-card-specs-process) | context | the pinned spec process is mounted when the footprint reaches the claim's specs roots |
| [LAUNCH-OUTCOME-CLASSIFY](outcome.md#launch-outcome-classify) | outcome | how a ride's end becomes one class |
| [LAUNCH-OUTCOME-GATEWAY](outcome.md#launch-outcome-gateway) | outcome | the class reported to the gateway before release; the re-admission at the same round |
| [LAUNCH-OUTCOME-STRIKE-COMMENT](outcome.md#launch-outcome-strike-comment) | outcome | `AGENT_STRIKE:` / `KEY-RETRY:` · ⚑ gap: a comment grammar as a store |
| [LAUNCH-OUTCOME-ROUTE-RETRY](outcome.md#launch-outcome-route-retry) | outcome | the old same-round retry · ⚑ gap: `/route` + `/router-status` |
| [LAUNCH-OUTCOME-DOORBELL](outcome.md#launch-outcome-doorbell) | outcome | a tasked ride's end rings its stack's doorbell |
| [LAUNCH-OUTCOME-PHASES](outcome.md#launch-outcome-phases) | outcome | `agent_run_phase_seconds{phase}` — the two phases the launcher owns |
| [LAUNCH-BUDGET-ESTIMATE](budget.md#launch-budget-estimate) | budget | the estimate and the tier |
| [LAUNCH-BUDGET-CR](budget.md#launch-budget-cr) | budget | the ephemeral key CR · ⚑ gap: the gateway holds the credential |
