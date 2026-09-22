# Spike — Codex as a ChatGPT-subscription rail

**Status:** investigation, 2026-09-21. No architecture decision has been taken. This records the
facts learned while bringing native Codex into the jail, the OpenCode Go precedent, and the first
implementation slices. The question is: how can cluster agents use the operator's ChatGPT
subscription without placing its refreshable credential in worker pods, while exposing account
headroom in the existing subscription dashboard?

## What exists today

The Anthropic path is the working reference:

```text
Claude Code pod
  -> ANTHROPIC_BASE_URL=openrouter-proxy/.../anthropic
  -> Authorization: Bearer ref:<namespace>/claude-session
  -> proxy resolves the reference and injects the real subscription credential
  -> Anthropic
```

The worker sees only an opaque reference. The proxy owns the credential boundary, observes the
subscription rate-limit headers, and exports `anthropic_subscription_*`. Grafana dashboard UID
`claude-subscription` (`dashboard-subscription.json`, titled “Agent subscriptions — headroom”)
shows its 5-hour and 7-day utilization, reset time, observation age, latch/dispatch state,
semaphore, and 429s. Cluster Claude use updates those series. Native Claude in the recovery jail
bypasses the proxy, so its use becomes visible only when a later proxied response refreshes the
account-global headers; a jail-side 429 is not observed by the proxy.

OpenCode Go established the second relevant pattern (ADR-107, ADR-108, ADR-112 and
[`chainless-redesign.md`](../agents/chainless-redesign.md)): a rail has an explicit identity,
harness/model cells, self-metered windows, a semaphore and latch, canaries, routing and dashboard
surfaces. Jail use must not depend on the cluster, so its meter pushes best-effort reports to the
token-gated `openrouter-proxy-ingest` LoadBalancer (`192.168.40.30:8081`); routing-critical code
does not query Prometheus. The existing endpoint is `POST /go-usage-report`.

Native Codex is now present in the rebuilt jail. It authenticates with ChatGPT, syncs transcripts
to Garage below `jail-transcripts/codex/homelab-codex/sessions/`, and sends OTLP logs and metrics
to the in-cluster collector at `192.168.40.29:4318`. Prometheus therefore has native operational
metrics such as `codex_conversation_turn_count_total`, tool counts, and latency. Those metrics do
**not** contain subscription headroom. Codex `rate_limits` events do: the observed payload carries
`limit_id`, `plan_type`, credit/limit flags, and primary/secondary windows with `used_percent`,
`window_minutes`, and `resets_at` (currently the familiar 5-hour and 7-day windows). The first live
observation was Plus, 22% / 64%; it is an example, not configuration or a promised limit.

## Public ChatGPT/Codex OAuth contract

This is public implementation knowledge rather than a single end-user API contract. Official
Codex source defines the token record as:

- `access_token` — bearer sent on inference and usage requests;
- `account_id` — sent as `ChatGPT-Account-ID`;
- `refresh_token` — exchanged at `https://auth.openai.com/oauth/token` with the public Codex
  client id and `grant_type=refresh_token`;
- `id_token` — identity/plan/account claims used locally, not an inference credential.

The surrounding `auth.json` also records `auth_mode` and `last_refresh`; those select the login
mode and support refresh bookkeeping. The practical ChatGPT backend request is a bearer-authenticated
Responses call at `https://chatgpt.com/backend-api/codex/responses`, with the account header above.
The account quota snapshot is available from `https://chatgpt.com/backend-api/wham/usage` (clients
also carry a legacy `/api/codex/usage` fallback). In other words, an access token alone is enough
only until it expires: durable unattended service requires the account id and refresh token too.

Official Codex already supports a useful isolation seam: a custom `model_providers.<id>` can set a
base URL and use command-backed bearer authentication (`auth.command`, `args`, optional `cwd`,
`timeout_ms`, and `refresh_interval_ms`, default five minutes). The command prints the bearer value
to stdout. A pod can therefore print only `ref:<namespace>/codex-session`; the proxy can resolve it,
refresh centrally, add `ChatGPT-Account-ID`, and rewrite `/responses` to the ChatGPT backend. No
worker needs an `auth.json`.

Public reference implementations corroborate the wire behavior. The OpenCode
`opencode-codex-auth` plugin persists the same OAuth fields, refreshes them, injects bearer/account
headers, rewrites requests, and handles account rotation. Its own warning matters: this is a
personal-development subscription path, not the supported production multi-user OpenAI API. This
homelab is a single operator's agents, but upstream changes and subscription terms remain explicit
operational risks.

Sources:

- [Codex authentication](https://developers.openai.com/codex/auth)
- [Codex configuration reference](https://developers.openai.com/codex/config-reference)
- [Codex `TokenData`](https://github.com/openai/codex/blob/main/codex-rs/login/src/token_data.rs)
- [Codex auth storage](https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/storage.rs)
- [OpenCode OAuth persistence](https://github.com/iam-brain/opencode-codex-auth/blob/main/lib/codex-native/oauth-persistence.ts)
- [OpenCode request routing](https://github.com/iam-brain/opencode-codex-auth/blob/main/lib/codex-native/request-routing.ts)
- [OpenCode fetch orchestration](https://github.com/iam-brain/opencode-codex-auth/blob/main/lib/fetch-orchestrator.ts)

## Candidate shape

```text
Codex worker                         openrouter-proxy                  OpenAI
custom provider base URL  ------->  /codex/responses  ------------>  /backend-api/codex/responses
auth command prints ref:...          resolve Secret reference          bearer access token
                                     refresh OAuth centrally            ChatGPT-Account-ID
                                     observe 429 + poll usage
                                               |
                                               +--> codex_subscription_* --> Prometheus/Grafana

Codex jail rate_limits event --best-effort/token-gated--> /codex-limit-report
```

The OAuth record belongs in a dedicated `codex-session` Secret sourced through the existing
Infisical/ESO credential path. `auth.json` is a full, refreshable account credential and must never
be mounted into arbitrary workers. The proxy resolver should retain the namespace/reference and
service-account authorization boundary used by the Anthropic leg. Refresh writes need one owner
or concurrency control so replicas cannot race token rotation.

The proxy should persist the newest account-global quota snapshot and export, at minimum:

- `codex_subscription_utilization{window="5h|7d"}` as a 0–1 ratio;
- `codex_subscription_reset_timestamp_seconds{window="5h|7d"}`;
- `codex_subscription_report_age_seconds`;
- `codex_subscription_limited` and a 429 counter;
- optionally `codex_subscription_info{plan="plus"} 1` (bounded label values only).

The existing subscription dashboard should gain Codex panels rather than creating a second
dashboard. The eventual authoritative refresh is proxy-side observation or the account usage
endpoint. A jail `POST /codex-limit-report` on the existing ingest listener is a complementary,
best-effort snapshot so jail-only use is promptly visible. Give it a dedicated token and accept
only the small normalized schema above. Do not create Pushgateway groups per session: FU-182
already records the unbounded-group failure mode.

Routing and alerts should follow the Go/Anthropic shape only after the proxy can make a reliable,
fresh `/codex-limit` verdict. ADR-108 still forbids reading Prometheus in dispatch paths; the proxy's
own persisted state supplies the verdict and Prometheus merely observes it.

## Build order

1. **Runtime foundation (`agent-runtime`, first queued issue).** Pin native Codex in the shared
   image and add a deterministic, credential-free headless harness contract. This proves the
   executable and run/finalization interface without prematurely coupling runtime CI to live OAuth.
2. **Credential/proxy leg (`homelab`).** Add `codex-session`, opaque-reference authorization,
   refresh ownership, ChatGPT request rewrite, explicit egress, and fixture tests with a fake
   upstream. Never log bearer, refresh, id token, or the full auth record.
3. **Headroom (`homelab`).** Add usage polling/response observation, jail ingest, normalized
   metrics, freshness and limit endpoints, promtool fixtures, alerts, and panels in UID
   `claude-subscription`.
4. **Harness matrix (`homelab`).** Teach `agent-session.sh` and the AgentStack composition the
   Codex cell, then add credential-free launcher replay plus one bounded live canary. Add routing,
   semaphore, budget policy, and role eligibility only after the canary and fresh-limit behavior
   are evidenced.

The runtime issue is intentionally first because `agent-runtime` owns the artifact and harness
binary; proxy and platform configuration do not belong in that repository. Each later slice should
be its own issue when its prerequisite lands, not one cross-repository mega-change.

## What would settle the spike

- A fake-upstream contract fixture proves request path, bearer replacement, account header,
  refresh, retry, redaction, and 401/429 behavior.
- A worker pod contains only an opaque `ref:` and completes `codex exec --json` through the proxy.
- Killing/restarting the proxy does not lose the durable refresh credential and does not race it.
- A jail-originated quota snapshot and a cluster-originated snapshot converge on one bounded set of
  `codex_subscription_*` series; stale data is visibly stale and never presented as fresh capacity.
- The Grafana dashboard shows Codex 5-hour/7-day headroom and resets, while the dispatch verdict is
  computed without Prometheus.
- A bounded live canary proves tool use, git changes, finalize output, and no credential appears in
  pod env, files, logs, transcript export, or Kubernetes events.

Open questions before an ADR: whether the subscription terms tolerate this single-operator cluster
use; whether quota polling is stable enough to be primary or only advisory; the refresh-token
rotation/replica ownership mechanism; and whether Codex becomes a full-support harness under
ADR-112 or begins as a canary-only cell.
