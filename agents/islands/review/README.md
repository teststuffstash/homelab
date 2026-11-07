# review — the island that turns a green PR head into a gate verdict

The review island answers one question for the merge path: *may this PR head merge?* It answers
it three times, with three identities that never collapse into one. The **code reviewer**
(`homelab-reviewer[bot]`) runs one model session per PR head in a scoped pod and posts a native
GitHub review (approve or request changes) or one of its quiet terminals. The **specs reviewer**
(`homelab-specs-reviewer[bot]`, [ADR-155](../../../docs/adr.md#adr-155--the-specs-reviewer-is-a-second-app-identity-and-the-island-repo-requires-two-approvals-2026-10-16))
is a level-triggered tick that gates spec rows and their evidence, never code. It posts the island
repo's second required approval. The **IaC sentinel** (IAC-G04,
[`iac-lane.md`](../../../docs/agents/iac-lane.md)) is deterministic and has no model. It posts the
`iac-sentinel` commit status on every open head of the covered repos. The first two are meant to
get their model and harness from the agent gateway (`POST /sessions`, `role: reviewer`), so the
island names no model of its own. The specs reviewer already does this. The code reviewer does it
only for the platform stack, and the old-proxy sites that remain are `⚑ gap` rows
([specs/dispatch.md](specs/dispatch.md#review-admit-legacy)). The contract is
[`specs/`](specs/README.md). The design prose is [`docs/`](docs/specs-reviewer.md).

## Membership

The code stays where it is; this list is the island. A path not listed here is not the island's,
even when its name says `review`.

| Kind | Path | Note |
|---|---|---|
| launcher | [`agents/reviewer-session.sh`](../../reviewer-session.sh) | the code reviewer: dispatch gates → gateway admission → pod (PREP + TOUCHESPART + RUNPART) → exit contract |
| tick | [`agents/specs-reviewer-session.sh`](../../specs-reviewer-session.sh) | the specs reviewer: classify → mechanical approve or one LLM pass; `--shadow`, `--self-test` |
| gate read | [`agents/reviewer-optout.sh`](../../reviewer-optout.sh) | THE read of `spec.reviewer.enabled`, the lens posture map (`--lens-map`), the MCP knob (`--mcp-knob`) |
| tool | [`agents/re-review.sh`](../../re-review.sh) | the time-travel re-review of Go-served review snapshots (jail-run; no dispatcher) |
| replay suites | [`agents/reviewer-optout-replay.sh`](../../reviewer-optout-replay.sh), [`agents/lens-posture-replay.sh`](../../lens-posture-replay.sh), [`agents/asvs-replay.sh`](../../asvs-replay.sh) | `mode: suite` runners registered in the replay index |
| lenses (runtime-read) | [`agents/lenses/*.md`](../../lenses/) | fetched from master's raw URL at review time (`LENS_BASE`); **never moved** |
| rubric (governance, cited only) | [`.agents/review.md`](../../../.agents/review.md) | the project rubric, appended to the code reviewer's system prompt; **never edited by an agent** |
| manifests | [`agents/coordinator/review-argo.yaml`](../../coordinator/review-argo.yaml), [`specs-review-argo.yaml`](../../coordinator/specs-review-argo.yaml), [`sentinel-argo.yaml`](../../coordinator/sentinel-argo.yaml) | the `review` Sensor + WorkflowTemplate, the `specs-review` CronWorkflow + Sensor + shadow template, the `iac-sentinel` WorkflowTemplate |
| identities | [`agents/coordinator/reviewer-git.yaml`](../../coordinator/reviewer-git.yaml), [`specs-reviewer-git.yaml`](../../coordinator/specs-reviewer-git.yaml), [`sentinel-git.yaml`](../../coordinator/sentinel-git.yaml) | the three ESO token chains (one App per writing role, [ADR-130](../../../docs/adr.md#adr-130--one-github-app-per-writing-role-and-every-required-status-context-pinned-to-its-poster-2026-09-13)) |
| sentinel | [`scripts/iac-sentinel.sh`](../../../scripts/iac-sentinel.sh), [`policy/iac/`](../../../policy/iac/) | the IAC-G04 evaluation (path rule + Kyverno + gitleaks) and its policies + exceptions |
| fixtures | `agents/replay/fixtures/` — `reviewer-exit-contract`, `reviewer-gateway-admit`, `tool-gap-surfaces` (tabular `rows:`); `reviewer-optout`, `lens-posture`, `asvs` (suites); `reviewer-currency/*`, `reviewer-touches/*`, `reviewer-create-refusal/*`, `reviewer-epic-container`, `reviewer-sprout-depth`, `reviewer-depth-lane-split`, `reviewer-mcp-prep/*`, `loop-fetch-guard/reviewer-fetch-retry`, `harness-run-cmd/re-review-shadow*` (actions); `reviewer-go-failover/*`, `reviewer-route-carrier/*`, `reviewer-rail-label/*` (the legacy routing path) | the island's evidence today; the harness is shared ([`agents/replay/`](../../replay/README.md)) |
| self-tests | `devbox run specs-review-self-test`, `devbox run sentinel-smoke` | predicates on fixtures; not replay |
| design prose | [`docs/specs-reviewer.md`](docs/specs-reviewer.md), [`docs/spec-gate-tiering.md`](docs/spec-gate-tiering.md) | moved here; the old `docs/agents/` paths are pointers |

**Not members (named because they look like members).**
- The image-pin stream. `sentinel-argo.yaml` carries the arc-runner image pin. Renovate bumps it
  17 times in the October window, which makes the pin stream §C8's "top partner"
  ([context-and-autonomy.md §C8](../../../docs/spikes/context-and-autonomy.md)). A pin line is
  not review logic. The pins belong to the dependency-upgrade stream (`agents/images.env`, the
  runner manifests). A pin bump is not a review-island change.
- `agents/review-reflex.sh` and its fixtures (`review-pick/*`, `reflex-*`, `decorrelate-resolution/*`,
  `assembly-review-dispatch/*`, `c9-rearm`, `changes-requested-body-edit`). The reflex decides
  *which* PR is reviewed and *when*. It is the scan island's dispatcher. This island's contract
  starts at the launcher's argv ([specs/dispatch.md](specs/dispatch.md#review-dispatch-cli)).
- `review-flip-belt`, `review-phantom-belt`, `review-only-label-combinations`,
  `stale-stamp-repair-lens-verdict-untouched`: these are `coordinator-scan.sh` clauses, so they
  are scan's.
- `agents/major-handoff.sh`, the harvest of `Follow-ups:` bullets (coordinator brief §The janitor
  tick), and the TOOL_GAP inventory belong to scan. They READ this island's verdict body
  ([specs/verdict.md](specs/verdict.md)).
- `agents/gateway-admit.sh` is the launch island's shared helper. This island calls it.
  `agents/issue_body.py`, `agents/touches-check.sh` and `agents/footprint.sh` are the shared
  parsers. The pod fetches them from master.
- `agents/slo-teeth.sh` and `agents/subscription-latch.sh` are gates this launcher calls and does
  not own.

## Consumer contracts

**Exposes (what other islands read):**

| Interface | Reader | Page |
|---|---|---|
| the code verdict — a native review by `homelab-reviewer`, or a standing-aside comment, or `agent/error` + one `AGENT_ERROR:` comment | GitHub auto-merge (the ruleset's approval count), scan (reflex breaker, ci-red / merge-conflict clauses), the specs gate | [verdict.md](specs/verdict.md) |
| the verdict body grammar — `Follow-ups:`, `Operator-lane (no container):`, `LENS(<lens>):`, `TOOL_GAP:`, the four migration headings | scan's harvest, `major-handoff.sh`, the TOOL_GAP inventory | [verdict.md](specs/verdict.md#review-verdict-body) |
| the specs doorbell `POST /specs-review {repo, number}` | the `specs-review` Sensor | [verdict.md](specs/verdict.md#review-verdict-doorbell) |
| the specs verdict — `## Specs review` + `Verdict:` line, pinned to the reviewed head | the island repo's ruleset (`required_approvals = 2`) | [specs-gate.md](specs/specs-gate.md) |
| the `iac-sentinel` commit status | the protected repos' rulesets | [sentinel.md](specs/sentinel.md) |
| the `specs_review_*` / `iac_sentinel_*` metric families | the pushgateway alert rules | [specs-gate.md](specs/specs-gate.md#review-specs-belts), [sentinel.md](specs/sentinel.md#review-sentinel-status) |

**Consumes:**

| Interface | From | Page |
|---|---|---|
| `POST /sessions` (`role: reviewer`, `harness: claude`), `DELETE`, `/outcome`, the env pull | the gateway island ([sessions.md](../../../gateway/specs/endpoints/sessions.md)) | [dispatch.md](specs/dispatch.md#review-admit-gateway) |
| the launcher argv `<project> <pr> [--round N] [--loop-ns NS] [--decorrelate-from M]` | scan (review-reflex.sh, the Composition's `review-<stack>` cron, the `review` Sensor) | [dispatch.md](specs/dispatch.md#review-dispatch-cli) |
| the AgentStack claim's `reviewer.enabled`, `lenses`, `mcp`, `repos[].specs` | the claim island (`argocd/resources/agentstack/xrd.yaml`) | [dispatch.md](specs/dispatch.md#review-dispatch-optout), [lenses.md](specs/lenses.md), [specs-gate.md](specs/specs-gate.md#review-specs-roots) |
| the pinned snippets process (wheel v0.6.9: RULES, CONVENTIONS, briefs, `touched-rules`, `evidence-pack`) | allure-behavior-snippets | [specs-gate.md](specs/specs-gate.md#review-specs-pack) |
| the head's evidence pack in the `gateway-specs` / `oracle-specs` bucket | each spec island's CI | [specs-gate.md](specs/specs-gate.md#review-specs-pack) |
| the janitor brief's `TOOL_GAP_SURFACES:` line | scan (`agents/coordinator/README.md`) | [verdict.md](specs/verdict.md#review-verdict-toolgap) |

## Read set

A session that works on this island loads only these:

1. this README and [`specs/`](specs/README.md), which holds the contract and the ⚑ gaps;
2. the touched script's own header and its replay clause markers;
3. for the specs gate, [`docs/specs-reviewer.md`](docs/specs-reviewer.md) §Wiring and the pinned
   process (RULES / CONVENTIONS / briefs @ v0.6.9);
4. for the sentinel, [`iac-lane.md`](../../../docs/agents/iac-lane.md) §L0b, which owns IAC-G04;
5. for the code reviewer's judgment, `.agents/review.md` and the lens that the diff selects.

It loads no `docs/agents/` corpus, no coordinator brief beyond the one `TOOL_GAP_SURFACES:` line,
and no gateway internals beyond `sessions.md`.

## Revert class

- The code reviewer and the specs reviewer run from a **master clone** at every dispatch (the
  workflow pod clones `homelab`). The lenses are fetched from master's raw URL. A bad change is
  undone by a **revert PR**, and it takes effect at the next dispatch.
- The sentinel runs `scripts/iac-sentinel.sh` from the master clone inside the pinned arc-runner
  image. Logic is reverted with a revert PR. A tool regression in the image (the #1131 kyverno
  class) is reverted with a **pin revert** in `sentinel-argo.yaml`. `sentinel-smoke` in `ci` reds
  the lock bump's own PR first.
- `.agents/review.md` and `.github/workflows/**` are operator-direct governance. Neither a revert
  PR nor the reviewer can gate a change to them (the reviewer refuses to review its own rubric).

## Open

- **The second gate reads nothing on this island.** `pack_roots` admits ONE `{root, tests}` pair
  per repo, and homelab's names `gateway/specs`. An edit under `agents/islands/*/specs/` matches
  the trigger (`(^|/)specs/`), so it reaches the LLM pass. There `touched-rules` over
  `gateway/specs` finds no rule, and the PR is approved mechanically. These specs are therefore
  ungated until the claim's `specs` field becomes a list
  ([specs-gate.md](specs/specs-gate.md#review-specs-roots), `⚑ gap`).
- **Legacy routing still lives in the launcher.** The code reviewer still carries 2 model
  literals, 3 old-proxy routing reads and a subscription-latch ladder. All of them sit behind the
  gateway's fallback, and they are deleted when the old proxy retires
  ([dispatch.md](specs/dispatch.md#review-admit-legacy)).
- **Gateway admission covers only the platform stack.** Every other stack's code review still
  takes the old-proxy path ([dispatch.md](specs/dispatch.md#review-admit-gateway)).
- **The shared EventBus lives in this island's manifest.** `review-argo.yaml` carries the
  JetStream EventBus and the `agent-loop` EventSource, and these serve `/coordinate`, `/alert`,
  `/specs-review` and the deploy-revert edge too. That is a seam this island hosts for everyone.
  It should move to a shared manifest when the islands split.
- **The sentinel cron backstop lives in `reflexes-argo.yaml`.** That file is pin-only guarded and
  shared with scan's reflexes, so the sentinel is not wholly inside its own manifests.
- No evidence pipeline: every requirement's proof today is a replay fixture or a self-test, and
  nothing renders evidence into these pages ([specs/README.md §Rule 5](specs/README.md#rules--the-pinned-process-and-what-this-island-adds)).
