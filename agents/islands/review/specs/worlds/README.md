# worlds/ — the named states the review rows run in

A **world** is a named, human-readable fixture state. Expected behaviour is a function of (system,
world), so a row that does not name its world is lying by omission (CONVENTIONS § Evidence row
identity, v0.6.9). This island's worlds are the replay harness's recorded or constructed worlds
([`agents/replay/README.md`](../../../../replay/README.md)). Every one of them is **family-local**:
it lives under its fixture dir, and no other family reads it. Nothing is copied here. This page
names each world and links its files, so a row's `world` cell resolves to something a reader can
open.

## Replay worlds (exist)

| world | files | what it is | rows |
|---|---|---|---|
| `clean` | [`reviewer-exit-contract/worlds/clean/`](../../../../replay/fixtures/reviewer-exit-contract/worlds/clean/) | one open PR #42, one non-merge commit `abc1234d`, no reviews, no bot comments, no `agent/error`. A row adds the terminal it wants through a `patches/*.jq` overlay, so a row that adds nothing is the no-terminal arm | [REVIEW-VERDICT-TERMINAL](../verdict.md#review-verdict-terminal), [REVIEW-VERDICT-DOORBELL](../verdict.md#review-verdict-doorbell) |
| `platform-mirror` | [`reviewer-gateway-admit/rows/`](../../../../replay/fixtures/reviewer-gateway-admit/rows/) (`vars.sh` per row) + the fixture's claims mirror | a claims mirror in which `homelab` belongs to stack `platform`; `curl` is the gateway seam (the POST body is the observed request, the DELETE is the release); the loop ns `platform-agents`, the SA `agentstack-loop` | [REVIEW-ADMIT-GATEWAY](../dispatch.md#review-admit-gateway) |
| `brief-declares` (unnamed in `rows.psv`) | [`tool-gap-surfaces/`](../../../../replay/fixtures/tool-gap-surfaces/) (the fixture's default brief) | the janitor brief carrying `TOOL_GAP_SURFACES: issue comments, PR bodies, PR review bodies` | [REVIEW-VERDICT-TOOLGAP](../verdict.md#review-verdict-toolgap) |
| `base-brief` | [`tool-gap-surfaces/worlds/base-brief/`](../../../../replay/fixtures/tool-gap-surfaces/worlds/base-brief/) | the brief before homelab#1776: the declaration without PR review bodies | REVIEW-VERDICT-TOOLGAP |
| `no-line` | [`tool-gap-surfaces/worlds/no-line/`](../../../../replay/fixtures/tool-gap-surfaces/worlds/no-line/) | a brief that lost the `TOOL_GAP_SURFACES:` line | REVIEW-VERDICT-TOOLGAP |
| `epic-tree` | [`reviewer-epic-container/world/`](../../../../replay/fixtures/reviewer-epic-container/world/) | one constructed issue tree: an open Goal (#10, label `task/goal`) with child #11, a `theme:` under it (#80 → #81), an open `stint:` ([stint](../../../../../docs/glossary.md), #50 → #51), a CLOSED Goal (#60 → #61), a plain work item (#70 → #71), a `  POST-LAUNCH:` title (#90 → #91), a label-keyed Goal with a non-Goal title (#100 → #101) | [REVIEW-VERDICT-BODY](../verdict.md#review-verdict-body) |
| `claims` (per suite case) | [`reviewer-optout/`](../../../../replay/fixtures/reviewer-optout/), [`lens-posture/`](../../../../replay/fixtures/lens-posture/) | AgentStack claim lists served by a kubectl shim; each suite case builds its own (a stack with `reviewer.enabled: false`, a `lenses:` block, a failing read) | [REVIEW-DISPATCH-OPTOUT](../dispatch.md#review-dispatch-optout), [REVIEW-LENS-POSTURE](../lenses.md#review-lens-posture) |
| `pr-state` (per row dir) | [`reviewer-currency/*/`](../../../../replay/fixtures/reviewer-currency/), [`reviewer-touches/*/`](../../../../replay/fixtures/reviewer-touches/) | one recorded `gh pr view` / issue body per row dir (the head's `mergeStateStatus`; the issue's `Touches:` block) | [REVIEW-DISPATCH-CURRENCY](../dispatch.md#review-dispatch-currency), [REVIEW-DISPATCH-TOUCHES](../dispatch.md#review-dispatch-touches) |
| `snapshot` | [`harness-run-cmd/re-review-shadow*/`](../../../../replay/fixtures/harness-run-cmd/) | a recorded review-state snapshot (pr.json, diff.patch, manifest) plus an `opencode` / `claude` stub reply | [REVIEW-REREVIEW-SHADOW](../re-review.md#review-rereview-shadow), [REVIEW-REREVIEW-IDEMPOTENT](../re-review.md#review-rereview-idempotent) |

## Self-test worlds (exist, not replay)

| world | files | what it is | rows |
|---|---|---|---|
| `self-test` | `agents/specs-reviewer-session.sh` `self_test()` (inline JSON) | hermetic: `CLAIMS_JSON` preset (a homelab claim with `specs: {gateway/specs, gateway/tests}`, a moved repo, malformed fields), `gh` recorded instead of executed, `current_head` overridden | every [specs-gate.md](../specs-gate.md) row |
| `local-tree` | the checkout `devbox run sentinel-smoke` runs in | the repo's own tracked files and `policy/iac/exceptions/<repo>.yaml` | [REVIEW-SENTINEL-SMOKE](../sentinel.md#review-sentinel-smoke) |

## Named worlds with no files (rows marked 🚧)

A row whose world is listed here describes the intended case. No fixture constructs that world
yet, and the row is the request for one.

| world | what it would fix |
|---|---|
| `pr-green-armed` | an open, non-draft PR on a platform repo, CI green at the content commit, auto-merge armed, no reviews |
| `sentinel-heads` | three open PRs on a covered repo: one clean, one worker-authored touching `.github/workflows/`, one whose tree carries a Kyverno violation |
| `argo-review-event` | the `agent-loop` EventSource receiving `POST /review` bodies with and without `loop_ns` |
