---
id: IF-POD
use-cases: [UC-1]
schema: pod.schema.json
---
# The worker pod — its identity, its env per harness, its command

*What runs, as whom, holding what.* The launcher writes one Pod (`kubectl create`, never `apply`)
in the repo's namespace and follows it. Three consumers read it: agent-runtime's entrypoint and
finalize (the command, the env), the gateway (the pod's projected token at its env pull —
[GW-SESSIONS-PULL](../../../../gateway/specs/endpoints/sessions.md#gw-sessions-pull)), and
monitoring (the labels). The env contract below is the launcher's half; the LLM env's *values* are
the gateway's ([GW-SESSIONS-ENV](../../../../gateway/specs/endpoints/sessions.md#gw-sessions-env)),
pulled by the pod itself.

## Interface — the machine half

| requirement | schema path | exit codes |
|---|---|---|
| [LAUNCH-POD-IDENTITY](#launch-pod-identity) | `metadata.name`, `metadata.labels`, `spec.serviceAccountName`, `spec.activeDeadlineSeconds` | 3 (a live holder, a lost race) |
| [LAUNCH-POD-ENV-PULL](#launch-pod-env-pull) | `env.gateway`, `volumes.gateway-token`, `command.prelude` | the pod exits 97 before the harness |
| [LAUNCH-POD-CRED](#launch-pod-cred) | `env.OPENROUTER_API_KEY`, `env.GIT_CRED_BROKER_URL`, `env.claude` | — |
| [LAUNCH-POD-HARNESS-CMD](#launch-pod-harness-cmd) | `command.harness` | — |

## Requirement index

| Requirement | section | Status |
|---|---|---|
| [LAUNCH-POD-IDENTITY](#launch-pod-identity) | identity | 🚧 WIP — no evidence pipeline yet; no fixture (the reap / refuse / race arms of the atomic gate are unpinned) |
| [LAUNCH-POD-ENV-PULL](#launch-pod-env-pull) | env | 🚧 WIP — no evidence pipeline yet (fixture: `gateway-env-pull`) |
| [LAUNCH-POD-CRED](#launch-pod-cred) | env | 🚧 WIP — no evidence pipeline yet (fixtures: `cred-inject-unconditional/*`) · ⚑ gap: the git token still comes from the old proxy's `/git-token` (FU-269) |
| [LAUNCH-POD-HARNESS-CMD](#launch-pod-harness-cmd) | command | 🚧 WIP — no evidence pipeline yet (fixtures: `harness-run-cmd/{claude,claude-gateway,claude-mcp,go,goose,goose-mcp,opencode,codex-mcp}`, `harness-enforce-default/*`) |

## Identity

### LAUNCH-POD-IDENTITY

A tasked ride's pod is named `agent-<repo>-<task>-r<round>` (non-`[a-z0-9]` characters of the task
become `-`); an untasked one `agent-<repo>-<HHMMSS>` (`agents/agent-session.sh` :1645–1650). On a
gateway ride the name is computed once, before admission, and sent as the bind's `pod`; the
pod-name block reuses it verbatim, so the pod that pulls is the pod the gateway admitted
([LAUNCH-ADMIT-LAUNCHER](admission.md#launch-admit-launcher)). The name is the (task, round)
idempotency key: a terminal holder (`Succeeded`/`Failed`) is reaped, a live holder refuses with exit
3, and `create` — never `apply` — makes a lost race a refusal too (:3005–3049). The pod runs as
ServiceAccount `agentstack-worker` (the Composition renders it per fixer namespace; its projected
token is what both the gateway's env pull and the old proxy's `/git-token` TokenReview), with
`restartPolicy: Never`, `activeDeadlineSeconds` = `AGENT_POD_DEADLINE_S` (default 14 400 — the
deadline a `timeout` outcome is classified from), and labels `app=agent-session`,
`project=<repo>`, `ride-size=<class>`, plus `homelab.teststuff.net/gateway-session=<session id>` on
a gateway ride.

**World:** `launcher-vars` + a `kubectl get pod` answer.

#### The atomic gate

Legend: `holder` = the phase of an existing pod of that name (`none` = no pod); `create?` = the
`kubectl create` result.

| description | world | task | holder | create? | rc? |
|---|---|---|---|---|---|
| a fresh key | launcher-vars | issue-42 r1 | none | created | — (ride proceeds) |
| a terminal holder is reaped | launcher-vars | issue-42 r1 | Succeeded | created after the delete | — |
| a live holder refuses | launcher-vars | issue-42 r1 | Running | not attempted | 3 |
| a lost race refuses atomically ⚖ | launcher-vars | issue-42 r1 | none, then created by another dispatcher | AlreadyExists | 3 (the bundle is kept) |

_Evidence: none yet — unverified._

## Env

### LAUNCH-POD-ENV-PULL

A gateway ride's pod carries **no LLM credential, literal or by reference**: its LLM env slot is
`AGENT_GATEWAY_PULL_URL` (the dispatch's `pull_url`) and `AGENT_GATEWAY_ENV_KEYS` (the dispatch's
`env_keys`, comma-joined); a projected ServiceAccount token with audience `agent-gateway` and the
shortest expiry the API allows (600 s) is mounted read-only at `/var/run/secrets/agent-gateway`;
and the helper's pull prelude runs first in the pod command, ahead of the harness and outside its
log tee (`agents/agent-session.sh` `REPLAY:gateway-env-pull`, :3029–3042;
`agents/gateway-admit.sh` `_GW_PULL_PRELUDE_TEXT`). The prelude reads the token, `POST`s the pull
URL (30 s, three retries), exports exactly the listed keys from the answer's `env`, drops its
locals, and exits **97** before the harness starts if the pull fails or the answer lacks a key — at
most once, because the pod never restarts. Off the gateway, the slot is the old
`GOOSE_PROVIDER=openrouter` + `GOOSE_MODEL`.

**World:** `launcher-vars`.

#### The LLM env slot

Legend: `gw` = a gateway dispatch (`GW_PULL_URL`, `GW_ENV_KEYS` set); `llm_env?` = the env names
the slot renders; `token_volume?` = the projected-token volume.

| description | world | gw | llm_env? | token_volume? | label? |
|---|---|---|---|---|---|
| off | launcher-vars | no | `GOOSE_PROVIDER`, `GOOSE_MODEL` | none | none |
| on | launcher-vars | yes, keys `OPENCODE_CONFIG_CONTENT` | `AGENT_GATEWAY_PULL_URL`, `AGENT_GATEWAY_ENV_KEYS` | audience `agent-gateway`, 600 s, `/var/run/secrets/agent-gateway` | `homelab.teststuff.net/gateway-session` |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-POD-ENV-PULL.md"

</details>

### LAUNCH-POD-CRED

What the pod holds for git and for the model, by ride shape (`REPLAY:cred-inject`, :2244–2287).
A gateway ride holds no OpenRouter key or reference; git tokens are fetched per operation from the
proxy's broker (`GIT_CRED_BROKER_URL=<proxy>/git-token?ns=<ns>`, FU-089). A claude ride on the old
path holds no OpenRouter key (the subscription is its only model credential) and the same broker
URL. A goose or opencode ride on the old path holds `OPENROUTER_API_KEY=ref:<ns>/<secret>` — a
reference the proxy resolves, never the key — and opencode is pointed at the proxy. Injection is
unconditional while a proxy is configured: `AGENT_CRED_INJECT=0` is ignored (FU-251). The one path
that renders a real key (a `secretKeyRef`) is no proxy at all — the break-glass.

⚑ gap (FU-269): the git broker is still the old proxy's `/git-token`, so a gateway ride depends on
the old proxy for git; the redrawn contract has the gateway (or its git broker) answer it.

**World:** `launcher-vars` with `PROXY_URL` set unless the row says otherwise.

#### Credentials by ride shape

Legend: `shape` = harness and path; `or_key?` = the `OPENROUTER_API_KEY` rendering; `git_broker?` =
`GIT_CRED_BROKER_URL`; `oc_inject?` = opencode pointed at the proxy.

| description | world | shape | or_key? | git_broker? | oc_inject? |
|---|---|---|---|---|---|
| cred-inject-unconditional/gateway | stack-platform | any harness, gateway ride | none | set | unset |
| cred-inject-unconditional/claude-opt-out-ignored | launcher-vars | claude, old path, `AGENT_CRED_INJECT=0` | none | set | unset |
| cred-inject-unconditional/opt-out-ignored ⚖ | launcher-vars | goose, old path, `AGENT_CRED_INJECT=0` | `ref:oracle-fleet/oracle-fleet-openrouter` | set | unset |
| cred-inject-unconditional/no-proxy-breakglass ⚖ | launcher-vars | goose, no proxy | real (`secretKeyRef`) | unset | unset |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-POD-CRED.md"

</details>

## Command

### LAUNCH-POD-HARNESS-CMD

The launcher builds the pod command from the recipe — never a caller-assembled `--run` for a recipe
ride (`REPLAY:harness-run-cmd`, :1530–1621). Every arm first writes the carded recipe (base64,
[LAUNCH-DISPATCH-RECIPE](dispatch.md#launch-dispatch-recipe)) to `/tmp/fix-recipe.yaml`, after the
context-repo clones and the bundle prelude. **claude**: `claude -p --model <m>` with the recipe as an
appended system prompt, `--max-turns ${CLAUDE_MAX_TURNS:-200}`, an MCP config when the claim
declares one, and `CLAUDE_CODE_MAX_CONTEXT_TOKENS` set from the dispatch's `context_tokens` on a
gateway ride (absent = the harness default, never a guess). **goose**: `goose run --recipe … --params
issue=<N>` with `GOOSE_MAX_TOKENS=16384` and the MCP flag. **opencode**: `opencode run -m <m>` with
stdin closed (`</dev/null` — opencode ≥2 waits for EOF on a piped stdin). **codex**: the image's
`agent-codex` seam with `CODEX_MCP_URL` when MCP is declared. On a gateway ride `<m>` is
`GW_WIRE_MODEL` (claude) or `gateway/<GW_WIRE_MODEL>` (opencode).

The harness is the gateway's on a gateway ride. On the old path an enforced-egress ride whose
harness is the baked default (opencode) runs goose instead — opencode's SDK-init fetches wedge
under enforcement (homelab#990); an explicit `--harness` wins, and on a gateway ride the flip is
announced and NOT applied, because the pulled env is opencode's (`REPLAY:harness-enforce-default`,
:923–941).

**World:** `launcher-vars` (`RECIPE_B64='UkVDSVBF'`, the recipe text `RECIPE`).

#### The command per harness

Legend: `harness` / `model` = what the ride runs; `ctx` = the declared context window;
`command_head?` = the command after the recipe write (truncated at the prompt).

| description | world | harness | model | ctx | command_head? |
|---|---|---|---|---|---|
| harness-run-cmd/claude | launcher-vars | claude | haiku | — | `claude -p --model haiku --dangerously-skip-permissions --max-turns 200 --append-system-prompt-file /tmp/fix-recipe.yaml …` |
| harness-run-cmd/claude-gateway | stack-platform | claude | `deepseek-v4-flash` (wire) | 1000000 | `CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000 claude -p --model deepseek-v4-flash …` |
| harness-run-cmd/go | launcher-vars | claude | `opencode-go/deepseek-v4-flash` | 1000000 (old path literal) | `CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000 claude -p --model opencode-go/deepseek-v4-flash …` |
| harness-run-cmd/claude-mcp | launcher-vars | claude | haiku | — | the MCP config written to `/tmp/mcp-config.json`, then `claude … --mcp-config /tmp/mcp-config.json …` |
| harness-run-cmd/goose | launcher-vars | goose | — | — | `GOOSE_MAX_TOKENS=16384 goose run --recipe /tmp/fix-recipe.yaml --params issue=<N>` |
| harness-run-cmd/goose-mcp | launcher-vars | goose | — | — | the goose arm with the MCP extension flag |
| harness-run-cmd/opencode | launcher-vars | opencode | `openrouter/deepseek/deepseek-v4-flash` | — | `opencode run -m openrouter/deepseek/deepseek-v4-flash '…Issue: 19.' </dev/null` |
| harness-run-cmd/codex-mcp | launcher-vars | codex | — | — | `CODEX_MCP_URL=… agent-codex --dangerously-bypass-approvals-and-sandbox '…'` |

#### The enforced-egress default

Legend: `egress` = the claim's `fixer.egress.enforce`; `explicit` = `--harness` passed; `harness?`
= what runs.

| description | world | egress | explicit | gw | harness? |
|---|---|---|---|---|---|
| harness-enforce-default/flip | launcher-vars | enforced | no | no | goose |
| harness-enforce-default/explicit-wins | launcher-vars | enforced | `opencode` | no | opencode |
| harness-enforce-default/monitor-untouched | launcher-vars | monitor | no | no | opencode |
| harness-enforce-default/gateway ⚖ | stack-platform | enforced | no | yes (opencode) | opencode (announced, not flipped) |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-POD-HARNESS-CMD.md"

</details>
