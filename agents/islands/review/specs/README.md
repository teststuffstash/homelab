# review specs — the contract, and how it is worked

The spec system for the [review island](../README.md), in the gateway island's shape
([`gateway/specs/README.md`](../../../../gateway/specs/README.md)): **the reviewer reviews the
result, not the diff.** Every interface this island exposes or consumes has a contract page here
with a sibling `<name>.schema.json`. Rows are decision tables of key examples, and the evidence is
the island's replay fixtures and self-tests. What the island *is* (membership, read set, revert
class) lives one level up. This directory holds only the contract.

## Rules — the pinned process, and what this island adds

The numbered rules 1–11, the test & evidence conventions and the reviewer briefs are NOT kept here.
They live ONCE in [allure-behavior-snippets](https://github.com/teststuffstash/allure-behavior-snippets)
([ADR-156](../../../../docs/adr.md#adr-156--one-portable-specevidence-process-homed-in-allure-behavior-snippets-one-reviewer-runs-two-briefs-2026-10-16)),
pinned by version: **[RULES.md @ v0.6.9](https://github.com/teststuffstash/allure-behavior-snippets/blob/v0.6.9/allure_behavior_snippets/process/RULES.md)**,
**[CONVENTIONS.md @ v0.6.9](https://github.com/teststuffstash/allure-behavior-snippets/blob/v0.6.9/allure_behavior_snippets/process/CONVENTIONS.md)**,
**[briefs/rows.md @ v0.6.9](https://github.com/teststuffstash/allure-behavior-snippets/blob/v0.6.9/allure_behavior_snippets/process/briefs/rows.md)**.
"Rule N" anywhere in this island means rule N there. This island is also the pin's *reader*: the
specs reviewer's `SNIPPETS_VERSION` ([`specs-reviewer-session.sh`](../../../specs-reviewer-session.sh))
is the version every spec island's pack is judged against ([REVIEW-SPECS-PACK](specs-gate.md#review-specs-pack)).

What this island adds, by rule:

- **Rule 1 (gate):** these rows are reviewer-gated, not codeowner-gated
  ([context-and-autonomy.md §Direction 2](../../../../docs/spikes/context-and-autonomy.md)). The
  gate is the specs reviewer, which is this island's own second identity. That is the island's
  circularity, and it is spelled out in the next bullet. `.agents/review.md` stays the code
  reviewer's rubric, and no spec row restates it.
- **⚑ The gate does not reach this directory yet.** The claim's `repos[].specs` is ONE
  `{root, tests}` pair per repo, and homelab's names `gateway/specs`. A PR that edits this
  directory matches the trigger, and `touched-rules` over `gateway/specs` finds no rule in it, so
  the PR is approved mechanically ([REVIEW-SPECS-ROOTS](specs-gate.md#review-specs-roots)). Until
  the field is a list, every row here lands with only the code reviewer's read.
- **Rule 3 (IDs):** the prefix is `REVIEW-`. The areas are `DISPATCH`, `ADMIT`, `VERDICT`, `LENS`,
  `SPECS`, `SENTINEL` and `REREVIEW`.
- **Rule 5 (evidence) — none is generated.** No requirement here carries rendered evidence. A
  requirement whose case already has a replay fixture or a self-test check names it in its index
  Status cell (`🚧 WIP — no evidence pipeline yet (fixture: <dir>)`). The replay harness
  ([`agents/replay/`](../../../replay/README.md)) runs those fixtures in `ci`, but it emits no
  Allure stories and no `<ID>.md` fragments, so nothing transcludes. Each rule section therefore
  carries the explicit marker line `_Evidence: none yet — unverified._` (CONVENTIONS § Evidence
  blocks). Where a tabular fixture exists (`rows:` in its `fixture.yaml`), the table's description
  cells are its row ids verbatim and its other columns are the `rows.psv` columns. That makes the
  later join a rename, not a rewrite. The specs reviewer's `--self-test` checks are named the same
  way, by their check strings.
- **Rule 7 (coupling):** every page has a sibling schema whose `x-requirements` names the
  requirements its paths serve. No spec gate runs over this directory yet (the gateway's
  `spec_gate.py` is wired to `gateway/specs` only), so orphans are caught by reading, not by `ci`
  (`⚑ gap`, the same root-pair limit).
- **Rule 9 (external facts):** GitHub's review/approval and commit-status semantics, Argo Events'
  data filters, and the OWASP ASVS / Helm / k8s-production sources the lenses pin. Each is linked
  where it is used. A fact nobody re-read during this spike says "verify during implementation".
- **Rule 10 (incompleteness):** the redrawn contracts that are not built yet (the `specs` LIST, the
  island-root spec gate, gateway admission for every stack, the legacy routing's deletion) are
  `🚧 WIP` or `⚑ gap` rows in the index below, never asserted.
- **Worlds:** the replay worlds the rows run in ([worlds/README.md](worlds/README.md)). The review
  fixtures' worlds are family-local, and the harness's one shared world (`circles-29-tree`) is not
  used here.

## Contract page template

The gateway's endpoint template, with "operation" read as *interface* (a script's argv + its
output, an Argo parameter set, a GitHub write, a metric family):

```markdown
---
id: IF-<NAME>
use-cases: [UC-1]
schema: <name>.schema.json
---
# <interface> — one-line purpose

## Interface — the machine half
<coupling table: requirement → schema paths → refusals/exit codes → Status>

## Requirement index
<Requirement · section · Status (🚧 / ⚑ marks live here)>

### REVIEW-<AREA>-<NAME>
<prose: the system, never its tests (rule 11); unproven facts marked in place>
Legend: …
<decision table: description | world | inputs… | expected?…>
_Evidence: none yet — unverified._
```

## Index

Start here: **[use-cases/uc-1-code-then-specs-verdict.md](use-cases/uc-1-code-then-specs-verdict.md)**
(the spine: one platform PR from the code reviewer's dispatch to the specs reviewer's mechanical
approval) → [dispatch.md](dispatch.md) (the launcher's argv, its gates, its admission) →
[verdict.md](verdict.md) (what the code reviewer writes to GitHub) → [lenses.md](lenses.md) →
[specs-gate.md](specs-gate.md) (the second identity) → [sentinel.md](sentinel.md) (IAC-G04) →
[re-review.md](re-review.md) · [glossary.md](glossary.md) · [worlds/](worlds/README.md).

| Requirement | Page | What it pins | Status |
|---|---|---|---|
| [REVIEW-DISPATCH-CLI](dispatch.md#review-dispatch-cli) | dispatch | the launcher's argv, its quiet exits and its FATAL exits | 🚧 WIP — no evidence pipeline yet (no fixture) |
| [REVIEW-DISPATCH-OPTOUT](dispatch.md#review-dispatch-optout) | dispatch | `reviewer.enabled: false` refuses before any GitHub call; an unreadable claim refuses (fail closed); an unclaimed repo is reviewed | 🚧 WIP — no evidence pipeline yet (fixture: reviewer-optout) |
| [REVIEW-DISPATCH-CURRENCY](dispatch.md#review-dispatch-currency) | dispatch | a closed PR or a DIRTY head is skipped at spawn; BEHIND proceeds; a failed probe proceeds | 🚧 WIP — no evidence pipeline yet (fixture: reviewer-currency) |
| [REVIEW-DISPATCH-TOUCHES](dispatch.md#review-dispatch-touches) | dispatch | the `TOUCHES-ESCAPES` fact handed to the model: `none` / `undeclared` / `unavailable` / the escaped paths, `[GOVERNANCE]`-marked | 🚧 WIP — no evidence pipeline yet (fixture: reviewer-touches) |
| [REVIEW-DISPATCH-EDGE](dispatch.md#review-dispatch-edge) | dispatch | the `review` event → global or per-stack Workflow, by `loop_ns` | 🚧 WIP — no evidence pipeline yet (no fixture) |
| [REVIEW-ADMIT-GATEWAY](dispatch.md#review-admit-gateway) | dispatch | the code reviewer's `POST /sessions`, what a dispatch / defer / refusal does to the launcher | 🚧 WIP — no evidence pipeline yet (fixture: reviewer-gateway-admit); `⚑ gap`: platform stack only |
| [REVIEW-ADMIT-LEGACY](dispatch.md#review-admit-legacy) | dispatch | the old-proxy path is a fallback only, and the island names no model | `⚑ gap (2026-11-07, spike → work: the old proxy's retirement)`: 2 model literals + 3 old-proxy routing reads + the subscription-latch ladder still in `reviewer-session.sh` |
| [REVIEW-VERDICT-TERMINAL](verdict.md#review-verdict-terminal) | verdict | one terminal at the content commit, or the pod exits non-zero | 🚧 WIP — no evidence pipeline yet (fixture: reviewer-exit-contract) |
| [REVIEW-VERDICT-ASIDE](verdict.md#review-verdict-aside) | verdict | precondition vs anomaly; the standing-aside marker grammar and its five `pre` slugs | 🚧 WIP — no evidence pipeline yet (the model's half has no fixture; detection: reviewer-exit-contract) |
| [REVIEW-VERDICT-BODY](verdict.md#review-verdict-body) | verdict | `Follow-ups:` only inside a container; `Operator-lane (no container):`; `LENS(<lens>):`; the migration headings | 🚧 WIP — no evidence pipeline yet (fixtures: reviewer-epic-container, reviewer-sprout-depth, reviewer-depth-lane-split) |
| [REVIEW-VERDICT-TOOLGAP](verdict.md#review-verdict-toolgap) | verdict | the TOOL_GAP channel set is the reader's declaration, interpolated | 🚧 WIP — no evidence pipeline yet (fixture: tool-gap-surfaces) |
| [REVIEW-VERDICT-DOORBELL](verdict.md#review-verdict-doorbell) | verdict | only a live verdict rings `/specs-review`; a missed ring changes no exit | 🚧 WIP — no evidence pipeline yet (fixture: reviewer-exit-contract) |
| [REVIEW-LENS-SELECT](lenses.md#review-lens-select) | lenses | which lens a diff selects, deterministically, from the default branch's facts | 🚧 WIP — no evidence pipeline yet (fixture: asvs — the asvs predicate only); `⚑ gap (2026-11-07, spike → work: unfiled)`: the migration lens's lockfile-only-major arm is in the lens text, not the predicate |
| [REVIEW-LENS-POSTURE](lenses.md#review-lens-posture) | lenses | advisory unless the claim says blocking; migration + gate-change pinned blocking; a failed fetch is loud | 🚧 WIP — no evidence pipeline yet (fixture: lens-posture); `⚑ gap`: a repo in no claim loses the pinned-blocking line |
| [REVIEW-SPECS-CLASSIFY](specs-gate.md#review-specs-classify) | specs-gate | one word per open PR, in precedence order | 🚧 WIP — no evidence pipeline yet (self-test: specs-review-self-test) |
| [REVIEW-SPECS-MECHANICAL](specs-gate.md#review-specs-mechanical) | specs-gate | no specs/rule-test path, or no touched rule → the fixed-body approval, no model | 🚧 WIP — no evidence pipeline yet (self-test: specs-review-self-test) |
| [REVIEW-SPECS-ROOTS](specs-gate.md#review-specs-roots) | specs-gate | where a repo's rules and their tests live: the claim's `repos[].specs`, else the table | 🚧 WIP — no evidence pipeline yet (self-test: specs-review-self-test); `⚑ gap`: one root pair per repo; `🚧 WIP`: `specs` as a list incl. `agents/islands/*/specs` |
| [REVIEW-SPECS-PACK](specs-gate.md#review-specs-pack) | specs-gate | the context pack's inputs, its fail-closed builds, the confined model | 🚧 WIP — no evidence pipeline yet (self-test: specs-review-self-test) |
| [REVIEW-SPECS-ADMIT](specs-gate.md#review-specs-admit) | specs-gate | the tick's `POST /sessions`, its outcome classes, the attempt loop | 🚧 WIP — no evidence pipeline yet (self-test: specs-review-self-test) |
| [REVIEW-SPECS-VERDICT](specs-gate.md#review-specs-verdict) | specs-gate | the `Verdict:` line, the head-pinned submit, the partial read | 🚧 WIP — no evidence pipeline yet (self-test: specs-review-self-test) |
| [REVIEW-SPECS-BELTS](specs-gate.md#review-specs-belts) | specs-gate | `specs_review_*`: the heartbeat and every kind every tick | 🚧 WIP — no evidence pipeline yet (no fixture) |
| [REVIEW-SENTINEL-STATUS](sentinel.md#review-sentinel-status) | sentinel | the `iac-sentinel` status per open head: success / failure / error | 🚧 WIP — no evidence pipeline yet (no fixture) |
| [REVIEW-SENTINEL-PATHRULE](sentinel.md#review-sentinel-pathrule) | sentinel | a worker PR touching the CI gate files is a violation; master's own edits and the chain's revert are not | 🚧 WIP — no evidence pipeline yet (no fixture) |
| [REVIEW-SENTINEL-ENGINES](sentinel.md#review-sentinel-engines) | sentinel | Kyverno over the PR tree's k8s docs + gitleaks; hostile content is data, never executed | 🚧 WIP — no evidence pipeline yet (smoke: sentinel-smoke) |
| [REVIEW-SENTINEL-SMOKE](sentinel.md#review-sentinel-smoke) | sentinel | `--smoke`'s exit 0 / 1 / 2 over the local tree, the repo identity from the remote | 🚧 WIP — no evidence pipeline yet (smoke: sentinel-smoke) |
| [REVIEW-REREVIEW-SNAPSHOT](re-review.md#review-rereview-snapshot) | re-review | a Go-served review leaves its exact input state in S3 | 🚧 WIP — no evidence pipeline yet (no fixture) |
| [REVIEW-REREVIEW-SHADOW](re-review.md#review-rereview-shadow) | re-review | a shadow re-review never writes to the PR; the model id passes verbatim | 🚧 WIP — no evidence pipeline yet (fixture: harness-run-cmd/re-review-shadow) |
| [REVIEW-REREVIEW-IDEMPOTENT](re-review.md#review-rereview-idempotent) | re-review | one comparison comment per snapshot, keyed by its tag | 🚧 WIP — no evidence pipeline yet (fixture: harness-run-cmd/re-review-shadow-skip-tag) |
