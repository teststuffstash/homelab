---
id: IF-ADMISSION
use-cases: [UC-1]
schema: admission.schema.json
---
# `gw_admit` · `gw_admit_lane` · `gw_release` — asking the gateway, once

*May this ride run now, with which harness, and what goes in the pod's env?* The launcher's
answer is the gateway's: it sends `(stack, role, task, round, attempt)` and the pod it is about to
create, and takes `dispatch` or `defer` back. The supplier contract is
[`POST /sessions`](../../../../gateway/specs/endpoints/sessions.md) —
[GW-SESSIONS-ADMIT](../../../../gateway/specs/endpoints/sessions.md#gw-sessions-admit),
[GW-SESSIONS-PULL](../../../../gateway/specs/endpoints/sessions.md#gw-sessions-pull),
[GW-SESSIONS-AUTH](../../../../gateway/specs/endpoints/sessions.md#gw-sessions-auth),
[GW-SESSIONS-RELEASE](../../../../gateway/specs/endpoints/sessions.md#gw-sessions-release),
[GW-SESSIONS-RETRY](../../../../gateway/specs/endpoints/sessions.md#gw-sessions-retry) — and is
not restated here. This page pins what the launcher island does with the answer: the shared helper
every admitted launcher sources ([`agents/gateway-admit.sh`](../../../gateway-admit.sh)), and the
worker launcher's own use of it. The caller names no model; that is the redrawn contract, and every
place the code still names one is counted under [LAUNCH-ADMIT-NO-MODEL](#launch-admit-no-model).

## Interface — the machine half

| requirement | schema path | return / exit | stderr line |
|---|---|---|---|
| [LAUNCH-ADMIT-HELPER](#launch-admit-helper) | `gw_admit.args`, `gw_admit.rc`, `gw_admit.outputs`, `gw_admit_lane.rc` | rc 0 · 1 · 2 · 3; lane rc 0 · 1 · 4 | `→ gateway(sessions): dispatch …`, `→ gateway(sessions): defer — [<reason>] retry_after=<s>s …` |
| [LAUNCH-ADMIT-BOUND](#launch-admit-bound) | `gw_admit.outputs.defer_reason` (`dispatch-unusable: …`) | rc 3 + one DELETE | `… FAIL CLOSED, releasing and not dispatching.` |
| [LAUNCH-ADMIT-LAUNCHER](#launch-admit-launcher) | `launcher.knobs`, `launcher.bind` | exit 1 · 2 · `AGENT_GATEWAY_FALLBACK_EXIT` | `PREFLIGHT REFUSED: --model … under AGENT_GATEWAY=sessions …` |
| [LAUNCH-ADMIT-NO-MODEL](#launch-admit-no-model) | `launcher.request` (no model field) | — | — |

## Requirement index

| Requirement | section | Status |
|---|---|---|
| [LAUNCH-ADMIT-HELPER](#launch-admit-helper) | the helper | 🚧 WIP — no evidence pipeline yet (fixture: `gateway-admit`); the lane (`gw_admit_lane`) has no replay row — `agents/deep-dig-test.sh` and `agents/island-intake-test.sh` drive it, unverified as evidence |
| [LAUNCH-ADMIT-BOUND](#launch-admit-bound) | the helper | 🚧 WIP — no evidence pipeline yet (fixtures: `gateway-admit`, `gateway-sessions`) · ⚑ gap: the seam answers are not validated against `sessions.schema.json` |
| [LAUNCH-ADMIT-LAUNCHER](#launch-admit-launcher) | the worker launcher | 🚧 WIP — no evidence pipeline yet (fixture: `gateway-sessions`) · ⚑ gap: admission is platform-only and the request's stack is the literal `platform` (FU-270) |
| [LAUNCH-ADMIT-NO-MODEL](#launch-admit-no-model) | the worker launcher | ⚑ gap: every non-platform ride takes the old path — 1 `/route`, 2 `/router-status`, 1 `/opencode-limit`, 1 `--pick-rail`, 2 `/report` + 1 report URL, 3 `model_id.py` parses, 7 model-literal lines in `agent-session.sh` (fixtures pinning the OLD behaviour: `route-request`, `rail-degrade`, `go-rail-latch`, `fu088-ladder`, `model-id-carrier`, `pick-rail`, `strike-retry`, `router-report-*`) |

## The helper

### LAUNCH-ADMIT-HELPER

`gw_admit` speaks `POST /sessions` for its caller and never exits or traps: every outcome is a
return code, and the caller decides what it means (`agents/gateway-admit.sh` header, :12–58).
**rc 0** — `dispatch`: `GW_SESSION_ID`, `GW_RAIL`, `GW_HARNESS`, `GW_MODEL`, `GW_WIRE_MODEL` (the
model with its rail prefix stripped — the harness invocation's id), `GW_CONTEXT_TOKENS`,
`GW_ENV_KEYS` are set; from here the caller owns the release (`trap gw_release EXIT`).
**rc 1** — `defer`: `GW_DEFER_REASON` and `GW_RETRY_AFTER` are the gateway's, no session exists.
**rc 3** — fail closed: unreachable, non-200 (the error envelope, redacted by the supplier, is
quoted; a 200 that is neither verdict is never printed, since it could carry a token), or an
unusable dispatch ([LAUNCH-ADMIT-BOUND](#launch-admit-bound)). **rc 2** — refused before any
request: `--stack`, `--role`, `--task` missing, neither or both of `--bind` / `--env-file`, a bind
that is not `<ns>/<sa>/<pod>`, a non-integer round, an attempt < 1. Optional fields reach the
request only when given; `attempt` only when > 1. The caller's identity is a fresh token per call
(the projected file, or — jail canary only — a 10-minute minted token for
`AGENT_GATEWAY_CALLER_SA`), never kept in a variable, carried by `curl -H @<(…)` so it never rides
argv (GW-SESSIONS-AUTH). `gw_release` is idempotent: one DELETE however often it is called, a
failed one warns and leaves the slot to the session TTL.

`gw_admit_lane <env-file> …` is the unbound shape for a workflow pod that runs its own claude: the
knob check (`AGENT_GATEWAY=sessions`), the platform gate, the caller preflight and `gw_admit
--harnesses claude --env-file` in one call; **rc 0** puts the dispatch env in the array
`GW_LLM_ENV` and removes the file; **rc 1** is the gateway's defer; **rc 4** is "take the old
proxy" — the knob is off (silent), the stack is not platform (one line), or a refusal / fail-closed
became the transition fallback (one loud line, FU-270).

**World:** `launcher-vars` + the gateway seam; every row runs under `set -u`.

#### What a call returns

Legend: `args` = the `gw_admit` argv beyond `--stack platform`; `reply` = the seam's answer
(world); `rc?` = the return code; `outputs?` = the `GW_*` values that matter for the row (`—` =
all empty).

| description | world | args | reply | rc? | outputs? |
|---|---|---|---|---|---|
| bound-dispatch | gw-dispatch-bound | `--role coordinator --round 0 --tier strong --bind platform-agents/agentstack-loop/coordinator-platform-1` | dispatch `claude/opus` on anthropic | 0 | `GW_WIRE_MODEL=opus`, `GW_ENV_KEYS=ANTHROPIC_BASE_URL,ANTHROPIC_AUTH_TOKEN,ANTHROPIC_MODEL`, `GW_PULL_URL=…/sessions/s-coord-1/env`, prelude set |
| unbound-dispatch | gw-dispatch-unbound | `--role responder --env-file F` | dispatch `claude/sonnet` with a token and env | 0 | env written 0600 to F; no `GW_*` holds the token |
| defer | gw-defer | `--role coordinator --round 3 --attempt 2 --bind …/p1` | `defer subscription-sessions-full 120` | 1 | `GW_DEFER_REASON=subscription-sessions-full`, `GW_RETRY_AFTER=120` |
| http-503 | gw-error | `--role responder --env-file F` | 503 `tokenreview-transient` | 3 | `GW_DEFER_REASON=gateway-http 503: {…}` |
| no-mode | launcher-vars | `--role responder --task t` | — | 2 | — |
| both-modes | launcher-vars | `--env-file F --bind a/b/c` | — | 2 | — |
| bad-bind | launcher-vars | `--bind platform-agents/p1` | — | 2 | — |
| bad-round | launcher-vars | `--round x --bind a/b/c` | — | 2 | — |
| missing-role | launcher-vars | `--task t --env-file F` | — | 2 | — |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-ADMIT-HELPER.md"

</details>

### LAUNCH-ADMIT-BOUND

A dispatch is checked before anything is built on it; once a session exists, every refusal
releases it before returning rc 3 with `GW_DEFER_REASON=dispatch-unusable: <what>` (:212–268). The
session id must match `^[A-Za-z0-9_-]{1,64}$`. **Bound** (`--bind`): the answer carries no
credential — a `session.token` or an `env` map means the gateway ignored the bind, and the launcher
refuses rather than hold a token (GW-SESSIONS-PULL); `env_keys` is a non-empty list of shell names
(each becomes an in-pod `export`); `pull_url` is `http(s)://<host>/…/sessions/<id>/env` for THIS
id. **Unbound** (`--env-file`): `env` is a non-empty map of shell names to single-line strings (a
newline cannot be a `KEY=VALUE` line), written 0600 and never sourced. **Both**: `model` is
present; the harness is one the caller runs (`--harnesses`, default all four) and its model key is
among the env keys — `ANTHROPIC_MODEL` (claude), `OPENCODE_CONFIG_CONTENT` (opencode),
`GOOSE_MODEL` (goose), `CODEX_MODEL` (codex), matching
[GW-SESSIONS-ENV](../../../../gateway/specs/endpoints/sessions.md#gw-sessions-env).

**World:** the gateway seam (`gw-dispatch-bound` / `gw-dispatch-unbound` with one field changed).

#### An unusable dispatch

Legend: `defect` = what is wrong with the answer; `released?` = one DELETE of the session;
`defer_reason?` = `GW_DEFER_REASON` after `dispatch-unusable: `.

| description | world | defect | released? | rc? | defer_reason? |
|---|---|---|---|---|---|
| credential-in-answer ⚖ | gw-dispatch-bound | `session.token` + `env` in a bound answer, no `env_keys` / `pull_url` | yes | 1 (exit) | `a credential in a bound answer, env_keys, pull_url, env_keys lacks OPENCODE_CONFIG_CONTENT` |
| bad-pull-url | gw-dispatch-bound | `pull_url` not this session's env URL | yes | 1 (exit) | `pull_url` |
| unusable-env | gw-dispatch-bound | `env_keys` lacks the opencode model key | yes | 1 (exit) | `env_keys, env_keys lacks OPENCODE_CONFIG_CONTENT` |
| harness-not-run | gw-dispatch-bound | harness `opencode`, caller runs `claude` only | yes | 3 | `harness 'opencode' (this launcher runs claude)` |
| unbound-answer-bound | gw-dispatch-unbound | an unbound call answered without `env` | yes | 3 | `env` |
| unbound-env-newline | gw-dispatch-unbound | an `env` value with a newline | yes | 3 | `env` |
| unknown-decision | gw-dispatch-unbound | `decision: maybe` (with a token) | no session kept | 1 (exit) | `gateway-http 200, unknown decision 'maybe'` (body never printed) |

The `(exit)` rows run through the worker launcher, which maps rc 3 to exit 1
([LAUNCH-ADMIT-LAUNCHER](#launch-admit-launcher)).

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-ADMIT-BOUND.md"

</details>

## The worker launcher

### LAUNCH-ADMIT-LAUNCHER

The worker launcher admits through the gateway when the dispatching pod carries
`AGENT_GATEWAY=sessions` (the Composition sets it on the platform loop pod) **and** the repo's
stack row is `platform`; any other stack takes [the old path](glossary.md#the-old-path) with one
`WARN` line (`agents/agent-session.sh` `REPLAY:gateway-sessions`, :272–345). Before any request it
refuses (exit 2, no session, no pod): `--model` (the gateway owns the model — a contradiction, not
an override), an interactive ride with neither `--run` nor `--recipe` (the pod pulls its env in its
command, and an interactive pod has none), a non-integer round, an attempt < 1, and a missing
caller token. The bind is the pod it is about to create — namespace = the repo, ServiceAccount
`agentstack-worker`, name `agent-<repo>-<task>-r<round>` (the pod-name block reuses it verbatim,
[LAUNCH-POD-IDENTITY](pod.md#launch-pod-identity)). `--harness` reaches the request only when
explicit (it narrows the walk to that dialect); `AGENT_GATEWAY_RAIL`, `AGENT_GATEWAY_ROLE`,
`AGENT_GATEWAY_CANARY` are operator knobs; `AGENT_GATEWAY_ATTEMPT` is set only by the launcher's
own re-admission ([LAUNCH-OUTCOME-GATEWAY](outcome.md#launch-outcome-gateway)). A defer or a
fail-closed is exit 1 — the dispatcher's requeue path; the session is released on every exit from
here on. On dispatch the harness and model are the gateway's: claude runs `GW_WIRE_MODEL`, opencode
runs `gateway/<GW_WIRE_MODEL>`.

`AGENT_GATEWAY_FALLBACK_EXIT=<n>` (a wrapper that keeps an old-proxy path, FU-270's transition)
turns a refusal before the request and a fail-closed into exit `<n>`; a `defer` and a `--model`
refusal are unchanged by it.

⚑ gap (FU-270): the request's `stack` is the literal `platform`, not the row's name, and every
other stack is refused admission by the launcher, not by the gateway's policy — the redrawn contract
sends the repo's own stack and lets
[GW-SESSIONS-AUTH](../../../../gateway/specs/endpoints/sessions.md#gw-sessions-auth)'s `callers`
decide (unverified — expected once the policy names the other stacks).

**World:** `stack-platform` unless the row says otherwise; the gateway seam answers.

#### Admission through the launcher

Legend: `knobs` = the row's `env` column + `vars.sh` flags; `request?` = what the POST body carries
beyond `{stack: platform, role, task, round}`; `harness?` / `model?` = what the launcher runs.

| description | world | knobs | request? | harness? | model? | rc? |
|---|---|---|---|---|---|---|
| off | launcher-vars | `AGENT_GATEWAY` unset | no request | opencode (old path) | `openrouter/deepseek/deepseek-v4-flash` | — |
| other-stack | stack-other | `AGENT_GATEWAY=sessions`, stack `circles` | no request (WARN) | opencode (old path) | `openrouter/deepseek/deepseek-v4-flash` | — |
| model-refused | stack-platform | `--model opencode-go/deepseek-v4-flash` | no request | — | — | 2 |
| round-refused | stack-platform | `--round r2` | no request | — | — | 2 |
| attempt-refused | stack-platform | `AGENT_GATEWAY_ATTEMPT=0` | no request | — | — | 2 |
| interactive-refused | stack-platform | no `--run`, no `--recipe` | no request | — | — | 2 |
| no-caller-token | stack-platform | token file absent, no canary SA | no request | — | — | 2 |
| caller-sa-malformed | stack-platform | `AGENT_GATEWAY_CALLER_SA=agentstack-loop` | no request | — | — | 2 |
| caller-mint-fails | stack-platform | canary SA, mint fails | no request | — | — | 2 |
| caller-minted | stack-platform · gw-dispatch-bound | canary SA `platform-agents/agentstack-loop`, `AGENT_GATEWAY_RAIL=opencode` | `rail: opencode`, bind, minted bearer | opencode | `opencode-go/deepseek-v4-flash` | 0 |
| dispatch-opencode | stack-platform · gw-dispatch-bound | `AGENT_GATEWAY_RAIL=opencode` | `rail: opencode`, bind | opencode | `opencode-go/deepseek-v4-flash` | 0 |
| dispatch-claude-explicit | stack-platform · gw-dispatch-bound | `--harness claude`, `issue-42` r2 | `harness: claude`, bind | claude | `opencode-go/deepseek-v4-flash` | 0 |
| dispatch-claude-subscription | stack-platform · gw-dispatch-bound | `--harness claude` | `harness: claude`, bind | claude | `claude/sonnet` | 0 |
| dispatch-goose | stack-platform · gw-dispatch-bound | `--harness goose`, `AGENT_GATEWAY_URL` overridden | `harness: goose`, bind | goose | `deepseek/deepseek-v4-flash` | 0 |
| dispatch-codex | stack-platform · gw-dispatch-bound | `--harness codex`, `AGENT_GATEWAY_ROLE=prober` | `role: prober`, `harness: codex`, bind | codex | `codex/gpt-6-astra` | 0 |
| dispatch-attempt-2 | stack-platform · gw-dispatch-bound | `AGENT_GATEWAY_ATTEMPT=2` | `attempt: 2`, bind | opencode | `opencode-go/deepseek-v4-flash` | 0 |
| dispatch-canary | stack-platform · gw-dispatch-bound | `AGENT_GATEWAY_ROLE=prober`, `AGENT_GATEWAY_CANARY=deepseek/deepseek-v4.1-flash@deepinfra` | `canary: {model, provider}`, bind | opencode | `deepseek/deepseek-v4.1-flash` | 0 |
| defer | stack-platform · gw-defer | — | bind | — | — | 1 |
| http-503 | stack-platform · gw-error | — | bind | — | — | 1 |
| unreachable | stack-platform · gw-error | — | bind | — | — | 1 |
| fallback-unreachable ⚖ | stack-platform · gw-error | `AGENT_GATEWAY_FALLBACK_EXIT=75` | bind | — | — | 75 |
| fallback-no-caller-token ⚖ | stack-platform | `AGENT_GATEWAY_FALLBACK_EXIT=75`, no token | no request | — | — | 75 |
| fallback-defer | stack-platform · gw-defer | `AGENT_GATEWAY_FALLBACK_EXIT=75` | bind | — | — | 1 |
| fallback-model-refused | stack-platform | `AGENT_GATEWAY_FALLBACK_EXIT=75`, `--model …` | no request | — | — | 2 |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-ADMIT-LAUNCHER.md"

</details>

### LAUNCH-ADMIT-NO-MODEL

**The launcher names no model and holds no latch.** Model, rail, harness, capacity and the context
window are the gateway's answer to one request; the launcher's request carries
`(stack, role, task, round, attempt, bind)` and optionally an explicit harness — no model, no chain,
no deny list, no labels, no urgency, no key reference
([context-and-autonomy.md §Interfaces](../../../../docs/spikes/context-and-autonomy.md#interfaces-are-redrawn-at-the-cut-operator-2026-10-05):
"the consumer's real question is may this unit run now, with which harness, and what goes in the
pod's env"). On a gateway ride the old region is skipped whole: the router consult, the rail
degrade, the chainless guard, the model-id parse and the FU-088 gates (:256–262, :347–715).

⚑ gap — **the old path still runs for every ride the gateway does not admit**, and its sites are
the launcher choosing for itself. Counted on non-comment lines of the island's members on this
branch (method: `grep -v '^\s*#'` then the endpoint or literal; §Interfaces' 33 for the launcher
is a different method — it counted every routing-shaped statement, these count call sites):

| site | where | count | replaced by |
|---|---|---|---|
| `POST /route` (9-field body: stack, task, role, session, key_ref, chain, deny, labels, urgency) | `agent-session.sh` :368–402 (`REPLAY:route-request`) | 1 call + 1 request assembly (+ 1 `gh issue view` for the labels) | GW-SESSIONS-ADMIT |
| `GET /router-status` (credit floor, capacity down, serving classes) | `agent-session.sh` :496 (`REPLAY:rail-degrade`), :3903 (`REPLAY:strike-retry`) | 2 | GW-SESSIONS-CAPACITY's defer; GW-SESSIONS-RETRY |
| `GET /opencode-limit` (Go window latch) | `agent-session.sh` :2822 (`REPLAY:fu088-gates`); `subscription-latch.sh` :62– | 1 + 1 | GW-SESSIONS-CAPACITY |
| `subscription-latch.sh --pick-rail` → `GET /anthropic-limit` | `agent-session.sh` :2922 | 1 | GW-SESSIONS-CAPACITY |
| `POST /report` + the pod's `AGENT_REPORT_URL` | `agent-session.sh` :3735, :3738 (`REPLAY:router-report`), :3159 | 2 + 1 | GW-SESSIONS-OUTCOME ([LAUNCH-OUTCOME-GATEWAY](outcome.md#launch-outcome-gateway)) |
| `model_id.py --shell` parse of a launcher-held model id | `agent-session.sh` :686, :689, :692 (`REPLAY:model-id-resolution`) | 3 | GW-MODEL-RESOLVE (the gateway strips the rail prefix) |
| model literals (`openrouter/deepseek/deepseek-v4-flash` default, `claude/haiku` fallback ×2, the Go 1 000 000-token window ×2, the claude-default swap ×2) | `agent-session.sh` :101, :590, :1599, :2208, :2213, :2854, :2956 | 7 lines | the policy's tier lists; `context_tokens` (GW-SESSIONS-ENV) |
| model literals (the Go fallback rail's model) | `subscription-latch.sh` :79, :80 | 2 lines | GW-SESSIONS-ADMIT |
| the chainless guard (a stack without `workerModel` must be routed authoritatively) | `agent-session.sh` :631 (`REPLAY:chainless-guard`) | 1 | nothing — no chain exists to guard |
| claim knobs read for routing (`workerModel`, `workerModelFallbacks`, `routerMode`, `modelDeny`, `subscriptionFallback`) | `agent-session.sh` `_srow` reads | 9 reads | the claim's `modelDeny` projected into the gateway policy (§Interfaces "Claim") |
| the pricing table (`_MODEL_PRICE`, 10 ids) + the default `--model` | `estimate_budget.py` :89–100, :666 | 11 | [LAUNCH-BUDGET-CR](budget.md#launch-budget-cr)'s ⚑ gap |

The old path's behaviour is still pinned by replay — so that it keeps working until it is deleted,
not as the contract: `route-request/*`, `rail-degrade` (`agents/rail-degrade-replay.sh`),
`go-rail-latch`, `fu088-ladder`, `model-id-carrier`, `pick-rail/*`, `strike-retry`,
`router-report-*`. The launcher's half of the old routing rules is
[../docs/launcher-routing.md](../docs/launcher-routing.md).

_Evidence: none yet — unverified._
