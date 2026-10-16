---
id: GW-ACCESS-INVENTORY
use-cases: [UC-1]
---
# Access — the role × stack × service inventory

Operator ruling (2026-10-15): the role × stack × service access inventory is P2 scope. **One
table**: rows are roles, columns are services, cells are `allowed` / `denied` / `🚧 WIP`. v0
enforces **only the rail columns** (`roles.<role>.rails` in the policy —
[GW-SESSIONS-ADMIT](endpoints/sessions.md#gw-sessions-admit)); every other column documents
today's reality as the launchers render it (`agents/agent-session.sh`, `agents/stacks.json`,
`agents/reviewer-session.sh`, `agents/coordinator-session.sh`, `agents/coordinator/responder-argo.yaml`,
`agents/retro-session.sh`, `agents/research-fanout.sh`, the AgentStack composition's prober,
`agents/specs-reviewer-session.sh`) and is marked unenforced. Read 2026-10-15 (specs reviewer row
added 2026-10-16); a cell is what the launcher does, not what a doc says it should.

## The inventory (today, by launcher)

| role | rail `anthropic` | rail `opencode` | rail `openrouter` | git identity | stack MCP (`spec.mcp`) | browser MCP |
|---|---|---|---|---|---|---|
| worker | allowed — claude harness, `ref:<ns>/claude-session` | allowed — `opencode-go/*` models on the claude harness | allowed — goose/opencode, `ref:<ns>/<project>-openrouter` (session key) | broker — `GIT_CRED_BROKER_URL` per-op token, no standing Secret (FU-089) | allowed when the claim sets `spec.mcp.endpoint` (`stack-mcp`, #1041/#1276) | denied — no pod renders it (jail sidecar only) |
| reviewer | allowed — `ref:agent-coordinator/coordinator-claude`, review class first | allowed — failover when the subscription is latched (`opencode-go/qwen3.7-plus`, homelab#424) | denied — the class lists it second, the FU-188 incident pin keeps reviews on the subscription | standing — `reviewer-git` Secret `GH_TOKEN` (the homelab-reviewer App) | allowed when the claim sets it (`--mcp-config`) | denied |
| specs reviewer (gateway role `reviewer`) | allowed — the FIRST launcher admitted through `POST /sessions` (ADR-155, FU-270 dogfood): `env` exported verbatim, no ref rail | allowed — the role's failover, as the gateway walks it | denied — the role's list | standing — `specs-reviewer-git` Secret `GH_TOKEN` (the homelab-specs-reviewer App; absent = shadow, no verdicts) | denied — none rendered (inputs are a diff, a body, a CI log) | denied |
| coordinator | allowed — `ref:agent-coordinator/coordinator-claude` | allowed — platform's `coordinatorModel: opencode-go/deepseek-v4-flash` | denied — class `dispatch` rails = subscription only | standing — `coordinator-git` Secret `GH_TOKEN` (ESO) | denied — none rendered | denied |
| responder | allowed — `ref:agent-coordinator/coordinator-claude` | allowed — an `opencode-go/*` rail case in the triage step | denied — class `dispatch` | standing — `coordinator-git` `GH_TOKEN` | denied — none rendered | denied |
| retro | allowed — cell A `claude:opus` on the subscription | denied — "add when its retro cell is first used" (`retro-session.sh`) | allowed — cell B `goose:deepseek/deepseek-v4-pro` on an ephemeral xs key | standing, read-only — `RETRO_GH_TOKEN` file mount (retro-git.yaml, #2171); the broker URL is not rendered | inherits the worker launcher's knob | denied |
| prober | allowed — `ref:<loopns>/claude-session` | denied — not rendered | denied — not rendered | broker — the loop git token fetched with the pod's SA token | denied — none rendered | denied |
| researcher | allowed — `claude/<alias>` draws on the claude harness | denied — class `research` rails = openrouter only | allowed — goose, pool draws on the stack key | broker — inherits the worker launcher | inherits the worker launcher's knob | denied |

| column | enforced by v0? | enforcement point | what "enforced" would mean later |
|---|---|---|---|
| rail `anthropic` / `opencode` / `openrouter` | **yes** | `POST /sessions` — `roles.<role>.rails`; a rail not listed is `defer: role-rail-denied`, and no session means no data-plane credential | — |
| git identity | no | the launchers render it; the broker is `openrouter-proxy`'s `/git-token` today and leaves for its own service (FU-269, ADR-139 step 1) | the broker consults the session's role before minting |
| stack MCP | no | the launcher reads the claim knob and renders the harness config | the gateway's `env` carries the MCP config; the knob moves into the policy |
| browser MCP | no (and not reachable) | the browser sidecar is a jail-host network (`jail-browser`); no cluster pod joins it | a decision, not a wiring — `🚧 WIP` until one exists |

## Per stack

The service set is the same for every stack; what differs per stack is which credential each
rail resolves to and which rail the coordinator rides today (`agents/stacks.json`, the
committed mirror of the cluster claims — the cluster wins at runtime).

| stack | `coordinatorModel` (mirror) | coordinator rail today | openrouter credential | `spec.mcp` |
|---|---|---|---|---|
| sleep | `sonnet` | anthropic | the stack's session key (`<project>-openrouter`) | cluster claim only — not mirrored, `🚧 WIP` to read |
| platform | `opencode-go/deepseek-v4-flash` | opencode | the stack's session key | `🚧 WIP` |
| oracle | `sonnet` | anthropic | the stack's session key | `🚧 WIP` |
| circles | `sonnet` | anthropic | the stack's session key | `🚧 WIP` |

## GW-ACCESS

v0 enforces the rail columns and nothing else: a role's allowed rails are exactly
`roles.<role>.rails` in the policy, consulted in that order by
[GW-SESSIONS-ADMIT](endpoints/sessions.md#gw-sessions-admit); a rail outside the list is never
walked, even when explicitly requested (`defer: role-rail-denied`). The `policy-default` world
encodes the inventory above with one deliberate difference, flagged ⚖: the **worker** loses the
`anthropic` rail (the brief's example policy; the subscription's slots are the review and
coordination lanes' safety net — `model-routing.md` M10) even though today's launcher lets a
haiku-tier worker ride it. Every non-rail column is unenforced and documented only.

| description | role || allowed rails (set, in order) | denied rails (set) |
|---|---||---|---|
| "worker: Go first, then OpenRouter; the subscription is not a worker rail ⚖" | worker || opencode, openrouter | anthropic |
| "reviewer: the subscription first, Go as failover" | reviewer || anthropic, opencode | openrouter |
| "coordinator: the subscription first, Go second" | coordinator || anthropic, opencode | openrouter |
| "responder: as the coordinator" | responder || anthropic, opencode | openrouter |
| "retro: the subscription cell and the API cell" | retro || anthropic, openrouter | opencode |
| "prober: the subscription only" | prober || anthropic | opencode, openrouter |
| "researcher: OpenRouter draws, subscription draws" | researcher || openrouter, anthropic | opencode |

| description | role | explicit `rail` || decision | reason |
|---|---|---||---|---|
| "an explicit rail inside the role's set" | reviewer | opencode || dispatch | — |
| "an explicit rail outside the role's set" | prober | openrouter || defer | role-rail-denied |
| "an explicit rail outside the set, even with capacity and a credential" | worker | anthropic || defer | role-rail-denied |

| description | column || v0 effect of the inventory cell |
|---|---||---|
| "the git column changes nothing here" | git identity || none — the gateway mints no git token |
| "the MCP column changes nothing here" | stack MCP || none — `env` carries no MCP var |
| "the browser column changes nothing here" | browser MCP || none |

<details><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-ACCESS.md"

</details>
