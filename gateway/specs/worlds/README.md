# worlds/ — named fixture states

A **world** is a named, human-readable fixture state: expected behaviour is a function of
(system, world), so a row that does not name its world is lying by omission. For the gateway a
world has two halves — a **policy document** and an **upstream behaviour** — and a row names
both when a requirement's evidence spans more than one of either (`"policy-default · upstream-429: …"`);
a single-world module declares it once in its docstring and omits it from row ids.

## Policy worlds

| world | file | what it is |
|---|---|---|
| `policy-default` | [policy-default.json](policy-default.json) | the test policy: two stacks (`platform`, `oracle`), all seven roles, three rails with the model ids copied from `model-classes.json`; caps small enough to fill in a test (`anthropic` 5, `opencode` 3, `openrouter` 20); the anthropic rail's `side_models` = `claude/haiku` (claude-code's side-call family, [GW-MODEL-RESOLVE](../endpoints/anthropic-messages.md#gw-model-resolve) ⚖) |

Names in the test policy (namespaces, Secret names) are **fixture names**, not production
ones; the production policy is the ConfigMap in `argocd/resources/agent-gateway/`. Model ids
are the exception: they are copied verbatim from
`argocd/resources/openrouter-proxy/model-classes.json` (`models.*.ids` per rail, the `coding`
class's `chain_head` order) so the fixture never names a model the fleet does not run.

## Upstream behaviours (fake upstreams)

Each rail's upstream is an in-process fake mounted per test — offline, deterministic, no network.
A behaviour is what the fake does with the next request; tests assert on the **request the fake
received** (URL, headers, body) as much as on the response the gateway returned.

| behaviour | the fake answers | exercised by |
|---|---|---|
| `upstream-ok` | 200, a complete JSON body with `usage` (`input_tokens`/`output_tokens` on the anthropic dialect, `prompt_tokens`/`completion_tokens` on openai) | the happy rows on every rail; usage accounting |
| `upstream-stream` | 200, `text/event-stream`, a final usage event (anthropic: `message_delta` with `usage`; openai: a last chunk with `usage`) | byte-unchanged SSE passthrough; streaming usage best-effort |
| `upstream-stream-gzip` | `upstream-stream`'s anthropic events, `content-encoding: gzip`, flushed per event — the live shape (2026-10-16) | usage parsed from the decoded capture while the bytes pass through encoded |
| `upstream-429` | 429 with `retry-after: 30` | 429 passthrough with `retry-after` |
| `upstream-401` | 401 with a body mentioning the key | 502 `upstream-auth`, body never forwarded |
| `upstream-slow` | holds the response past the read timeout | timeout rows (connect 10 s / read 600 s) — 🚧 WIP, clock-faked only |
| `upstream-down` | the connection fails before any byte is sent (refused / DNS / reset — not a timeout) | 502 `upstream-unreachable` rows on every rail |

## The credential source (`FakeSecrets`)

The kube API is a seam (`CredentialSource` protocol). `FakeSecrets` holds `namespace/name →
{labels, data}` and can be told to answer any ref with a definitive miss (404/403), an
unlabeled Secret, or a transient fault (5xx / unreachable) — the three verdict classes of
[GW-CRED-RESOLVE](../endpoints/sessions.md#gw-cred-resolve). Values in fixtures are
obviously-fake strings that still match the redaction patterns (`sk-ant-oat-FAKE…`,
`sk-or-v1-FAKE…`) so [GW-REDACT](../endpoints/sessions.md#gw-redact) rows have something to catch.
