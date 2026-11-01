---
id: GW-ACCESS-INVENTORY
use-cases: [UC-1]
---
# Access — the role × stack × service inventory

Operator ruling (2026-10-15): the role × stack × service access inventory is P2 scope. **One
table**: rows are roles, columns are services, cells are `allowed` / `denied` / `🚧 WIP`. v0
enforces **only the rail columns** (`roles.<role>.rails` in the policy —
[GW-SESSIONS-ADMIT](endpoints/sessions.md#gw-sessions-admit)), plus who may call the control plane
for which stack and role ([GW-SESSIONS-AUTH](endpoints/sessions.md#gw-sessions-auth) — per caller
ServiceAccount, not per role, so it is a row of the enforcement table below, not a column); every other column documents
today's reality as the launchers render it (`agents/agent-session.sh`, `agents/stacks.json`,
`agents/reviewer-session.sh`, `agents/coordinator-session.sh`, `agents/coordinator/responder-argo.yaml`,
`agents/retro-session.sh`, `agents/research-fanout.sh`, the AgentStack composition's prober,
`agents/specs-reviewer-session.sh`) and is marked unenforced. Read 2026-10-15 (specs reviewer row
added 2026-10-16); a cell is what the launcher does, not what a doc says it should.

## The inventory (today, by launcher)

| role | rail `anthropic` | rail `opencode` | rail `openrouter` | git identity | stack MCP (`spec.mcp`) | browser MCP |
|---|---|---|---|---|---|---|
| worker | allowed — claude harness, `ref:<ns>/claude-session`; under the opt-in below: denied (the policy's worker rails) | allowed — `opencode-go/*` models on the claude harness; **opt-in `AGENT_GATEWAY=sessions` (FU-270, platform stack only, ⚖ env knob, no claim field yet):** admitted through `POST /sessions` with `bind` (the pod's namespace, ServiceAccount and name), authenticated as the dispatcher's ServiceAccount (`platform-agents:agentstack-loop`; the jail canary mints that SA's token — [GW-SESSIONS-AUTH](endpoints/sessions.md#gw-sessions-auth)) — the launcher never sees the token: the pod pulls its `env` from `POST /sessions/{id}/env` with its projected ServiceAccount token (audience `agent-gateway`, TokenReview'd, at most once — [GW-SESSIONS-PULL](endpoints/sessions.md#gw-sessions-pull)); no Secret, no ref rail, the gateway's model and harness | allowed — goose/opencode, `ref:<ns>/<project>-openrouter` (session key); under the opt-in: the gateway's walk past a full [Go rail](../../docs/agents/chainless-redesign.md), the stack key resolved gateway-side (no ref in the pod) | broker — `GIT_CRED_BROKER_URL` per-op token, no standing Secret (FU-089) | allowed when the claim sets `spec.mcp.endpoint` (`stack-mcp`, #1041/#1276) | denied — no pod renders it (jail sidecar only) |
| reviewer | allowed — `ref:agent-coordinator/coordinator-claude`, review class first; **platform stack (FU-270, `AGENT_GATEWAY=sessions` from its review dispatchers):** admitted through `POST /sessions` as `platform-agents:agentstack-loop`, `harness: claude` (the pod runs claude only), bound to the reviewer pod, which pulls its env — no ref; a refused admission falls back to the ref (transition fallback) | allowed — failover when the subscription is latched (`opencode-go/qwen3.7-plus`, homelab#424); platform: the gateway's walk onto an anthropic-dialect Go cell | denied — the class lists it second, the FU-188 incident pin keeps reviews on the subscription; platform: the policy's reviewer rails list no openrouter, and `harness: claude` skips cells this pod cannot speak | standing — `reviewer-git` Secret `GH_TOKEN` (the homelab-reviewer App) | allowed when the claim sets it (`--mcp-config`) | denied |
| specs reviewer (gateway role `reviewer`) | allowed — the FIRST launcher admitted through `POST /sessions` (ADR-155, FU-270 dogfood), as the caller `agent-coordinator:specs-review` — the tick's own SA, #2685 (GW-SESSIONS-AUTH): `env` exported verbatim, no ref rail | allowed — the role's failover, as the gateway walks it | denied — the role's list | standing — `specs-reviewer-git` Secret `GH_TOKEN` (the homelab-specs-reviewer App; absent = shadow, no verdicts) | denied — none rendered (inputs are a diff, a body, a CI log) | denied |
| coordinator | allowed — `ref:agent-coordinator/coordinator-claude`; **the platform stack's headless sessions (FU-270):** admitted through `POST /sessions` IN the session pod, unbound, as that pod's own ServiceAccount (the loop's `platform-agents:agentstack-loop`; a jail-launched pod `agent-coordinator:agent-coordinator`) via `agents/gateway-admit.sh` — the dispatch `env` exported to claude, the gateway's model; a refusal before any request or a fail-closed answer falls back to the ref rail (the transition fallback, deleted with the old proxy) | allowed — a stack whose `coordinatorModel` is `opencode-go/*` (none today: platform's `opencode-go/deepseek-v4-flash` went back to `opus` on 2026-10-27, #2960) | denied — class `dispatch` rails = subscription only | standing — `coordinator-git` Secret `GH_TOKEN` (ESO) | denied — none rendered | denied |
| responder | allowed — `ref:agent-coordinator/coordinator-claude` | allowed — an `opencode-go/*` rail case in the triage step | denied — class `dispatch` | standing — `coordinator-git` `GH_TOKEN` | denied — none rendered | denied |
| retro | allowed — cell A `claude:opus` on the subscription | denied — "add when its retro cell is first used" (`retro-session.sh`) | allowed — cell B `goose:deepseek/deepseek-v4-pro` on an ephemeral xs key | standing, read-only — `RETRO_GH_TOKEN` file mount (retro-git.yaml, #2171); the broker URL is not rendered | inherits the worker launcher's knob | denied |
| prober | allowed — `ref:<loopns>/claude-session` | denied — not rendered | denied — not rendered; **under the opt-in: the entry canary** ([GW-CATALOG-OR](endpoints/catalog.md#the-entry-canary)) — `gateway/scripts/canary-entrants.sh` admits one prober ride per candidate cell (`canary: {model, provider}`, harness opencode) as the dispatcher's ServiceAccount, whose `callers` entry grants `prober` beside `worker` ([GW-SESSIONS-AUTH](endpoints/sessions.md#gw-sessions-auth), 2026-10-20) — unbound | broker — the loop git token fetched with the pod's SA token | denied — none rendered | denied |
| researcher | allowed — `claude/<alias>` draws on the claude harness | denied — class `research` rails = openrouter only | allowed — goose, pool draws on the stack key | broker — inherits the worker launcher | inherits the worker launcher's knob | denied |

| column | enforced by v0? | enforcement point | what "enforced" would mean later |
|---|---|---|---|
| rail `anthropic` / `opencode` / `openrouter` | **yes** | `POST /sessions` — `roles.<role>.rails`; a rail not listed is `defer: role-rail-denied`, and no session means no data-plane credential | — |
| control-plane caller (who may call `/sessions`, for which stack, role and bind namespace; who may list and judge) | **yes** (`enforce` since 2026-10-17) | `POST /sessions`, `GET` / `DELETE /sessions/{id}`, `GET /sessions?task=` — the policy's `callers`, keyed by the caller's reviewed ServiceAccount ([GW-SESSIONS-AUTH](endpoints/sessions.md#gw-sessions-auth)); a known caller outside its entry is refused in both modes, a caller with no valid token is counted under `observe` and refused under `enforce` | — |
| git identity | no | the launchers render it; the broker is `openrouter-proxy`'s `/git-token` today and leaves for its own service (FU-269, ADR-139 step 1) | the broker consults the session's role before minting |
| stack MCP | no | the launcher reads the claim knob and renders the harness config | the gateway's `env` carries the MCP config; the knob moves into the policy |
| browser MCP | no (and not reachable) | the browser sidecar is a jail-host network (`jail-browser`); no cluster pod joins it | a decision, not a wiring — `🚧 WIP` until one exists |

**Role × caller.** Which CALLER may ask for which role is the policy's `callers` map, per
ServiceAccount ([GW-SESSIONS-AUTH](endpoints/sessions.md#gw-sessions-auth)): the platform loop's
dispatcher SA (`platform-agents:agentstack-loop`) `worker` + `prober` — its graduated workers and the
entry canary's rides — and `coordinator` + `reviewer` (bind namespace `platform-agents`) for the loop's coordinator and
reviewer pods — the coordinator session admits unbound from its own pod (operator ruling 2026-11-01: the platform lanes move onto the
gateway; granted ahead of the launchers, which adopt the shared admission helper
`agents/gateway-admit.sh` one PR at a time — until then the inventory rows above stay as they are; the coordinator row has);
the coordinator namespace's shared SA (`agent-coordinator:agent-coordinator`) `coordinator` +
`responder`, no bind — the responder, deep dig, island intake and fix-debounce lanes, each one
unbound session (the fix-debounce set-pass's `dispatch-unit` class maps to `coordinator`); the oracle loop's SA (`oracle-agents:agentstack-loop`) `prober` only, no bind —
the `probe-oracle` tick's nested mission child on the codex rail (operator ruling 2026-10-24); the specs reviewer's SA (`agent-coordinator:specs-review`) `reviewer` +
`worker` — the tick and its shadow cell; the [judge](glossary.md#judge)'s SA
(`agent-coordinator:outcome-judge`, the deploy-revert chain's judge step, FU-270 (b)) no role at
all — `outcome: any`, so it lists a task's sessions and reports `wrong-verdict` on them
([GW-SESSIONS-OUTCOME](endpoints/sessions.md#gw-sessions-outcome)). No other caller, no wildcard;
the deployed map is `argocd/resources/agent-gateway/policy.json` (`kustomization.yaml` comments it).

## Per stack

The service set is the same for every stack; what differs per stack is which credential each
rail resolves to and which rail the coordinator rides today (`agents/stacks.json`, the
committed mirror of the cluster claims — the cluster wins at runtime).

| stack | `coordinatorModel` (mirror) | coordinator rail today | openrouter credential | `spec.mcp` |
|---|---|---|---|---|
| sleep | `sonnet` | anthropic | the stack's session key (`<project>-openrouter`) | cluster claim only — not mirrored, `🚧 WIP` to read |
| platform | `opus` | anthropic | the stack's session key | `🚧 WIP` |
| oracle | `sonnet` | anthropic | the stack's session key | `🚧 WIP` |
| circles | `sonnet` | anthropic | the stack's session key | `🚧 WIP` |

## GW-ACCESS

v0 enforces the rail columns and nothing else of this table (the caller check is GW-SESSIONS-AUTH's, per ServiceAccount): a role's allowed rails are exactly
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

<details markdown="1"><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-ACCESS.md"

</details>
