# Spike — Codex as a ChatGPT-subscription rail

**Status:** investigation, 2026-09-21 (consumer-surrogate use case added 2026-09-22; isolated
gateway prototype added 2026-10-16, see below). No
architecture decision has been taken. This records the facts learned while bringing native Codex
into the jail, the OpenCode Go precedent, and the first
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

1. **Runtime foundation (`agent-runtime`) — landed 2026-09-22.** Pin native Codex in the shared
   image and add a deterministic, credential-free headless harness contract. This proves the
   executable and run/finalization interface without prematurely coupling runtime CI to live OAuth.
   Done as agent-runtime#145/PR#147 (Codex pinned in `agent-base`) and #146/PR#148 (`agent-codex`,
   the `codex exec --json` seam, entrypoint provenance, the `agent-finalize` JSONL adapter). A
   disposable restricted pod verified, as uid/gid 1000, that `codex` and `agent-codex` resolve and
   no `auth.json` exists. That proves the image/runtime boundary only: there is still no Codex arm
   in `agents/agent-session.sh`, no credential/proxy leg, no headroom accounting and no live
   in-cluster model call.
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

## Use case: approximating a ChatGPT consumer (2026-09-22)

Design input for a full `design-agents` session, not a decision. It came out of the Codex jail
work, in a session that could not load the whole agents corpus (see the context finding below).

**The workload.** [oracle-fleet#562](https://github.com/teststuffstash/oracle-fleet/issues/562),
the class-2 oracle prober (routing: FU-102, the Prober role). Its successor is meant to ask real
consumer questions and exercise the oracle across models and harnesses. The target is not a pure
model benchmark but, approximately, "a normal ChatGPT subscriber asks this and gets this answer";
most consumers neither pick model IDs nor know the tiers.

That makes native Codex relevant: it is probably the closest legitimate, automatable, headless
client of an OpenAI subscription (ChatGPT auth, OpenAI's subscription backend, model policy and
orchestration). It is **not** the ChatGPT app and must not be labelled equivalent without
evidence: it has a coding-agent system prompt, terminal/repository assumptions, its own tool loop,
explicit model controls, its own context/compaction policy, and none of ChatGPT's UI, memory or
personalization.

**Candidate experiment.** Three arms over the same frozen missions, each cell a fresh session so
accumulated context is not a confounder:

1. *Real ChatGPT calibration* — a small manual gold set run through the actual consumer ChatGPT
   connection flow (not oracle output pasted into chat). Record normalized answer, citations,
   tool outcome and pass/fail — never credentials or user data.
2. *Codex subscription canary (`chatgpt-surrogate`)* — the same missions as isolated in-cluster
   Codex sessions, with native context/compaction left as is. Codex earns "surrogate" only from
   measured correlation with arm 1, not from architectural resemblance.
3. *Controlled OpenRouter matrix* — Luna, Terra, Sol and Astra through one fixed harness/provider
   path ([`opencode-model-matrix.md`](opencode-model-matrix.md) is the existing matrix): diagnostic
   model+harness coverage, not a stand-in for the consumer product.

Reading it: all OpenRouter cells fail → suspect the oracle/query contract; API cells pass and
Codex fails → suspect the product/harness path; ChatGPT passes and Codex fails → Codex is not a
faithful surrogate for that behavior. Each cell records requested and actually served
model/provider, token and cache usage, MCP result sizes, tool sequence, elapsed time and cost, the
exposed context limit, any compaction/truncation, deterministic oracle assertions, answer and
citations.

**Context-window finding.** The local Codex model catalog gives the same values for
`gpt-6-astra`, `gpt-5.6-sol`, `gpt-5.6-terra` and `gpt-5.6-luna`: `context_window = 272000`,
`effective_context_window_percent = 95` (258,400 usable in session telemetry),
`max_context_window = 872000`. API listings advertise far larger windows for these families (Sol
around 1.05M), so 272k is a Codex product/runtime choice, not an intrinsic model limit, and it is
independent of reasoning effort. Upstream:
[openai/codex#28852](https://github.com/openai/codex/issues/28852) asks for 1M effective context
(open); [#27522](https://github.com/openai/codex/issues/27522) (an API-provider session asks for
1M and gets ~258k), [#27743](https://github.com/openai/codex/issues/27743) (catalog knows a larger
max; one user reports a CLI override worked on an API provider) and
[#27275](https://github.com/openai/codex/issues/27275) (frequent compaction at the smaller window)
are user reports, not maintainer explanations. That 272k matches the long-prompt price threshold
is plausible but **unconfirmed**; no official page found says Plus is capped at 272k or why Codex
picks it. Do not repeat it as fact, and do not assume an API-provider override works on the
subscription rail. For one fresh consumer question 272k may suffice, but large MCP results can
cross it (#562 already recorded one three-hit search response of 140,119 characters). Crossing
the cap is evidence about suitability: report it, never let compaction hide it in a comparison.
Context overrides do not belong in the surrogate arm unless the real ChatGPT product behaves the
same way: they would improve a benchmark while making it less representative.

**Open questions this adds** (to the list at the end):

- Build the credential/proxy leg narrowly for the prober first, or as a general rail straight
  away? Current recommendation: a prober-only canary first.
- What correlation with arm 1 lets Codex graduate from candidate surrogate to a useful automated
  proxy for ChatGPT behavior?
- Is the real ChatGPT consumer connection's MCP/tool surface close enough to the oracle's for the
  calibration to mean anything?

**For delegation.** The design session must hand workers exact model IDs, the provider/harness
choice, the endpoint and opaque-ref contract, limits, a report schema, fixtures and live-canary
acceptance. Cluster agents can implement matrix expansion, launcher/composition wiring,
deterministic assertions, reports, fixtures and metrics; they must not be asked to invent OAuth
semantics, choose representative models, or decide what counts as ChatGPT-product equivalence
from an underspecified issue. Per [author at the last moment](../agents/issue-authoring.md) (§Author at
the last moment, queue at once), the successor Goal is not
minted just to park this: the corpus-loaded session judges the design first and authors the Goal
when #562 reaches its verdict.

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

## Gateway prototype — isolated build (2026-10-16, FU-270)

Operator-authorized scope: extend this investigation and build the Responses adapter plus a
credential-free native Codex compatibility fixture. The current target is the
[`gateway/` island](../../gateway/README.md), not the old proxy. The earlier build order and
consumer-surrogate investigation remain context; this section records the changed boundary.

The prototype lives in [`experiments/codex-rail/`](../../experiments/codex-rail/README.md), with
its own standard-library tests and no imports from the gateway. It changes no gateway source,
contract, dependency lock, CI workflow, launcher, deployed policy or live credential. Work is
kept on a separate branch/PR. These are proposed contracts, not new enforced GW requirements.

| Concern | Proposed gateway integration |
|---|---|
| Worker identity | Admit through `POST /sessions`; the worker holds only `gws_…`. Credential references stay inside the gateway. |
| Protocol | Add Responses as an explicit dialect; today's `openai` means Chat Completions. Codex is a harness, subscription is a rail, and Responses is the wire protocol. |
| Model | Pin from session policy; reject a mismatching request before upstream contact. The fixture uses a synthetic model, not an entitlement claim. |
| Streaming | Forward SSE bytes unchanged, observe bounded individual events incrementally, count terminal `response.usage` once, and distinguish failed/incomplete/truncated streams from completion. |
| Cancellation | Close upstream on downstream cancellation; never replay a partially delivered generation. |
| OAuth | Central refresh with one owner per account, durable rotation and restart recovery. The current read-only Secret resolver is insufficient. |
| Headroom | Account-wide observations with source/time/reset, freshness and out-of-order checks; gateway state drives admission, Prometheus observes. |
| Initial eligibility | Explicit canary cell before general role routing; no implicit paid fallback. |

Refresh persistence is an unresolved implementation decision: Infisical remains the source of
truth under [the secrets doctrine](../secrets.md). Updating only its ESO-generated Kubernetes
Secret risks restoring an obsolete refresh token. The offline lifecycle component now uses fake
credentials and a persistence interface to exercise concurrent refresh, write failure,
revocation and restart before choosing the production write-back mechanism. Recovery from a
crash after upstream rotation but before durable persistence must be specified, not assumed.

There is a second upstream option to evaluate alongside the September Codex-backend findings:
[Sign in with ChatGPT](https://developers.openai.com/siwc/token-sharing-open-source) now documents
ChatGPT-plan Responses access for open-source/local apps, including a
[Codex app-server configuration](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server).
This is not evidence that our account, cluster deployment or pinned CLI is eligible.
[Preview restrictions](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
include streaming, no server-side conversation storage over HTTP, and a restricted tool/parameter
surface. Keep the upstream profile explicit; do not mix client registrations or infer that
existing Codex OAuth credentials authorize the SIWC route. The prototype selects neither live
backend and performs no OAuth exchange.

Acceptance order under FU-270:

1. Offline adapter tests: session/model boundary, header replacement, chunked SSE, terminal
   usage, failure/truncation, bounded buffering, cancellation and HTTP failure mapping.
2. Native Codex fixture: isolated configuration, dummy session token, loopback server,
   synthetic Responses completion; record the exact CLI version and observed request shape.
   This proves the client seam, not subscription access or the deployed agent-runtime pin.
3. Offline lifecycle/headroom: fake OAuth state machine and local freshness verdicts (see
   the extension below); then gateway spec/schema/test integration and launcher replay. Preserve the existing runtime work rather than rebuilding it.
4. A separately authorized maintenance-window canary proves real subscription access, tool use,
   finalization and credential absence before general routing. No production wiring is part of
   this prototype PR. FU-271's HA measurement remains separate.

Prototype evidence (2026-10-16): 10 offline contract tests pass; native Codex 0.161.0
(the agent-runtime lock at `d10904baa8fac8c66e49cd86510277ee9ef508f1`) and the jail CLI
0.163.0 both complete the loopback fixture. Both send streaming Responses with `store: false`
and array input; terminal usage and upstream cleanup are observed. Exact summaries live in
`experiments/codex-rail/evidence.json`. This checks the pinned executable, not the deployed
container, wrapper finalization, real credentials, subscription headroom or real model access.


### Offline lifecycle/headroom extension (2026-10-16, FU-270)

The prototype contracts and failure table (now the [GW-CODEX-OAUTH and GW-CODEX-HEADROOM rows](../../gateway/specs/endpoints/openai-responses.md#gw-codex-oauth))
now cover a fake-credential OAuth state machine and account-local headroom component. The storage
interface requires atomic durable writes plus exclusive ownership across refresh. A persisted
in-progress marker makes a crash after rotation fail closed after restart; it does **not** recover
a replacement token lost before persistence. Production recovery and Infisical write-back remain
unselected. Tests exercise shared-owner serialization, rotation, ambiguous write acknowledgement,
revocation, restart and secret-free boundary failures.

Quota fixtures normalize both windows, reject stale/future/out-of-order input, and return typed
local verdicts. Freshness, utilization thresholds and window durations are experimental fixtures,
not adopted gateway policy. Restart needs a fresh report; reset time passing alone grants nothing.
The prototype remains outside gateway source/specs/locks/CI and uses no live credentials. This
extends #2625; real backend eligibility, store durability/fencing, authenticated report ingress,
gateway integration and the separately authorized live canary remain unproven under FU-270.

### Composed offline verification (2026-10-16, FU-270)

The composed fixture (now the gateway itself — see the port below)
connects native Codex, dummy session validation, headroom admission, fake OAuth rotation and the
Responses adapter to a loopback HTTP upstream. Combined tests check rejection before upstream
contact, freshness after a blocked refresh, concurrent rotation, terminal usage, cancellation,
HTTP failures and redaction. A disposable POSIX file backend adds subprocess lock/restart tests,
including termination after exchange and exit after durable replacement. It is an experimental
plaintext store for dummy credentials, not a production persistence choice. This strengthens the
local evidence without changing gateway code, specs, dependency locks, CI, launchers, policies,
credentials or deployments. Physical durability, distributed fencing, Infisical write-back and
real-backend canary evidence remain outside this experiment under FU-270.

### Ported into the gateway, dark (2026-10-16, FU-270)

Acceptance step 3's gateway half: the adapter, lifecycle and headroom modules moved into
[`gateway/src/agent_gateway/`](../../gateway/README.md) and their tests became GW rows on
[`openai-responses.md`](../../gateway/specs/endpoints/openai-responses.md) — a `responses`
dialect at `/openai/v1/responses` (`openai` stays Chat Completions), the `codex` rail, headroom as
`POST /sessions` admission (`quota-unknown` / `quota-stale` / `quota-limited` defers), the OAuth
lifecycle behind its persistence interface with the FAKE store only, and the codex harness's
`GW-SESSIONS-ENV` rows. The rail **ships dark**: the deployed policy declares no codex rail and
production wires no credential store, so the production write-back (Infisical), the upstream
profile (Codex backend vs SIWC), authenticated report ingress, cross-process fencing and the
live canary stay `⚑ gap` rows there. One finding the port made: codex-cli 0.161.0 does **not**
take its base URL from a bare `OPENAI_BASE_URL` — the provider block must be rendered (the
wrapper's job), so the env carries values, not a CLI-read base URL. The
[experiment directory](../../experiments/codex-rail/README.md) keeps only the native-CLI compat
harness, re-pointed at the real gateway (dated local evidence; the CLI is not in CI). The
`file_store.py` POSIX backend and its subprocess tests were not ported — a disposable local
backend is not a production persistence choice; their evidence is in git history.

## Upstream profile investigation — 2026-10-17 (FU-270)

**Recommendation, not a deployment decision:** retain the native Codex backend as the first
canary candidate for the current runtime. Evaluate Sign in with ChatGPT (SIWC) as a distinct
profile; changing `CODEX_UPSTREAM` alone is insufficient. Neither profile is production-ready
or selected by this investigation. Account eligibility and actual model access remain untested.
The [gateway's named gaps](../../gateway/specs/endpoints/openai-responses.md#named-gaps-and-local-evidence)
remain open. This section refines the upstream-profile gap under FU-270; it does not add a rail.

### Evidence and its limits

The runtime repository's current master was `d10904baa8fac8c66e49cd86510277ee9ef508f1`:
[`agent-base/devbox.lock`](https://github.com/teststuffstash/agent-runtime/blob/d10904baa8fac8c66e49cd86510277ee9ef508f1/agent-base/devbox.lock)
pins Codex **0.161.0**. Its `agent-codex` wrapper invokes `exec --json` and expects runtime-supplied
configuration; it does not render the gateway provider block. Native source inspected at the
`rust-v0.161.0` tag, commit `979011409de0a60b52f179721948e65531d26144` (links below).

The new [profile probe](../../experiments/codex-rail/README.md#upstream-profile-observation)
runs that pinned executable and the jail's 0.163.0 through the real gateway with a fresh home,
dummy credentials and a loopback upstream. Both complete the synthetic turn and emit **seven
ungrouped top-level function tools**, alongside one namespace containing five functions and one
web-search tool. Neither request emits the checked forbidden fields or `tool_search`.
[Recorded evidence](../../experiments/codex-rail/profile-evidence.json) contains only structural
observations, not prompts, token/header values or raw bodies.

This is a documented SIWC request-shape mismatch: its
[preview contract](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
requires function/custom tools in namespaces or `additional_tools` input items. The fake server
accepts the request, so fixture success is **not** SIWC success. It uses `fixture-model` and the
fixture's default tool configuration: it proves neither that every real-model configuration has
this mismatch nor that any untested configuration avoids it. It executes no tool and proves no
live subscription access. Grouping tools requires client/tool-call compatibility evidence, not
silent gateway rewriting. Web-search availability also depends on the actual account and model.

### The two credential and wire profiles

| Concern | Native Codex backend (pinned source) | SIWC ChatGPT-plan route (official docs checked 2026-10-17) |
|---|---|---|
| Inference base | `https://chatgpt.com/backend-api/codex` | `https://api.openai.com/v1`; SIWC explicitly excludes the backend-api route |
| Refresh | `https://auth.openai.com/oauth/token`, JSON grant, native client's registered ID, no resource field | `https://auth.openai.com/api/accounts/oauth/token`, form grant, saved issued client ID, `resource=https://api.openai.com/v1`, omit scope to retain grant |
| Credential identity | Native OAuth token set and ChatGPT account ID | Issued client registration plus validated identity, scopes, expiry and stable host ID; do not substitute the native client ID/token set |
| Inference auth | Native bearer/account context; gateway injects the account header | Documented bearer token; the documented token metadata is opaque, not a source for manufacturing a native account ID |
| Model evidence | Complete a real turn on the explicitly selected account/model | Account catalog at `/v1/models`, then completed inference; bundled app-server catalogs are not entitlement evidence |
| Quota evidence | Pinned client has a native usage endpoint; real payload still needs observation | Reviewed SIWC docs specify usage errors and app limits, but no machine-readable headroom polling contract |

Native sources: [provider base](https://github.com/openai/codex/blob/979011409de0a60b52f179721948e65531d26144/codex-rs/model-provider-info/src/lib.rs),
[refresh exchange and client ID](https://github.com/openai/codex/blob/979011409de0a60b52f179721948e65531d26144/codex-rs/login/src/auth/manager.rs),
[usage URL selection](https://github.com/openai/codex/blob/979011409de0a60b52f179721948e65531d26144/codex-rs/backend-client/src/client/rate_limit_resets.rs).
These describe the client implementation, not a public commitment to arbitrary gateway use.
SIWC sources: [registration](https://developers.openai.com/siwc/token-sharing-open-source/sign-in),
[refresh](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions#refreshing-tokens),
[token fields](https://developers.openai.com/siwc/token-sharing-open-source/token-reference),
[inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference),
[Codex app-server](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server).
The app-server example documents a different invocation from our pinned `exec` wrapper; neither
replacing the runtime nor interpreting its model catalog as access is justified by that example.

SIWC's [self-hosted VM procedure](https://developers.openai.com/siwc/token-sharing-open-source/self-hosted-vms)
does describe a remote runtime owning subsequent refreshes after protected credential transfer.
That is evidence for a self-hosted flow, not proof that this Kubernetes deployment or account is
eligible. A gateway host identity must persist across pod recreation. Do not copy the jail's
renewable session into a second independent refresher. Any future browser consent is the
**third-party console** class under [the minting doctrine](../secrets.md#minting-doctrine--a-tokens-scope-is-config-not-a-secret),
with configuration and credential delivery still managed as code.

### Native header compatibility is a multi-request test

The pinned [Responses client](https://github.com/openai/codex/blob/979011409de0a60b52f179721948e65531d26144/codex-rs/codex-api/src/endpoint/responses.rs)
adds session/thread/request identifiers; the
[core client](https://github.com/openai/codex/blob/979011409de0a60b52f179721948e65531d26144/codex-rs/core/src/client.rs)
defines `x-codex-turn-state` as an upstream-issued routing value reused within a turn and cleared
between turns. The gateway's fixed six-header set drops it. The current one-response fixture
cannot establish compatibility with this behavior.

FU-270's vendor-header gap therefore needs a fake two-request tool turn: return a synthetic
turn-state header, verify reuse on the continuation and clearing on a new turn, and keep account
identity gateway-owned. Specify validation, length limits and session/turn binding before any
allowlist change; this finding does not authorize blindly forwarding worker headers. Source
inspection establishes the missing client behavior, not that the live backend always requires
every client header.

### Refresh and headroom implications for the gateway build

The current [OAuth record](../../gateway/src/agent_gateway/oauth.py) requires a native account ID
and has no SIWC registration/grant metadata. A production store must preserve the selected
profile's identity and token set atomically. Its existing `refreshing` marker is useful, but it
cannot recover a rotated token lost before durable persistence. The next exchange implementation
must use the chosen profile's exact encoding/client/resource, serialize owners, bound response
reads/timeouts, redact failures and never replay an uncertain rotation. Keep the
[Infisical source of truth](../secrets.md#boundaries); ESO is read-only, so updating only its Secret
is insufficient. Single-replica ownership comes first; HA/fencing remains FU-271.

SIWC [errors](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery)
distinguish unsupported capability, ineligible user, temporary usage-service failure, usage limit,
and terminal refresh failure. A 401/403 by itself is not evidence that the refresh token was
revoked. A limit may arrive inside `response.failed` after HTTP 200; HTTP-429 counting alone misses
it. A usage-limit code does not identify a reset time or prove the whole subscription is empty.
The gateway currently classifies failed streams but does not turn those errors into a profile-specific
admission state. The existing two-window headroom fixture cannot represent these facts by guessing
zero usage or inventing resets. Native jail quota reports alone do not prove SIWC app capacity.

### Bounded continuation under FU-270

1. **Native first-canary candidate:** finish the header-continuation fixture and native refresh
   transport against fake endpoints, then the platform-owned durable write-back/recovery path.
   Resolve backend-use eligibility before supplying a real credential. The explicit model comes
   from account-specific evidence; neither this synthetic model nor a documentation example is a pin.
2. **SIWC alternative:** prove a pinned runtime configuration with the documented tool shape,
   preserve registration/grant metadata, and settle an admission policy with an evidenced quota
   source. If no usable observation exists, retain `quota-unknown`; do not weaken freshness just
   to enable the route. Registration and a completed real turn would still be needed.
3. **Production acceptance:** use the existing separately authorized maintenance-window canary
   to prove actual runtime tool use/finalization, renewal/restart behavior and credential isolation.
   Offline native-CLI CI remains [#2650](https://github.com/teststuffstash/homelab/issues/2650).

No live credential was read, refreshed or transferred for this investigation. No model call,
deployment, gateway rule, launcher, policy, runtime pin or credential backend was changed.

### Native continuation measurement — 2026-10-17 (FU-270)

The [continuation fixture](../../experiments/codex-rail/README.md#native-tool-continuation) now
compares a synthetic tool-result request directly and through the gateway. Both runtime-pinned
Codex 0.161.0 and jail 0.163.0 return the fake upstream's `x-codex-turn-state` on the direct
continuation; neither returns it through the gateway. Both gateway turns nevertheless complete.
This isolates the documented header gap: the current gateway suppresses the response header
and has no inbound allowance to return it. A completed first-turn fixture is insufficient evidence
for the native profile. The fixture uses `get_goal` (read-only), dummy credentials and temporary
homes; it is not a real-model tool-use canary or a deployed-runtime test.

The next FU-270 header change must explicitly define the opaque state round trip and its
session/account boundaries in [GW-RAIL-CODEX](../../gateway/specs/endpoints/openai-responses.md#gw-rail-codex),
then run this comparison again. No passthrough exception is introduced by this measurement.

## Canary preparation evidence — 2026-10-19 (FU-270)

Operator decisions supersede the investigation's earlier candidates: native backend selected,
gateway-local SQLite owns rotation, Infisical holds only the hash-gated seed, and enrollment
uses a separate gateway login. SIWC is unselected. The deployed policy still omits Codex.

The [loopback continuation record](../../experiments/codex-rail/continuation-evidence.json)
was rerun with runtime-pinned 0.161.0 and this jail's 0.163.0, isolated homes and dummy credentials.
Both send `stream: true`, `store: false`, array input, seven ungrouped function tools plus
one namespace with five functions and one web-search tool. Direct headers (names only):
`accept`, `authorization`, `content-length`, `content-type`, `host`, `originator`, `session-id`,
`thread-id`, `user-agent`, `x-client-request-id`, `x-codex-beta-features`, `x-codex-turn-metadata`,
`x-codex-window-id`; the continuation adds `x-codex-turn-state`. The body carries a turn ID.
The gateway replaces auth/account identity, forwards only its base headers plus validated
turn state, and both CLI versions now replay the issued value on the tool continuation.
This is a synthetic native CLI observation, not a capture of this conversation's transport.

Pinned source at `rust-v0.161.0` / `979011409de0a60b52f179721948e65531d26144`:
[refresh manager](https://github.com/openai/codex/blob/979011409de0a60b52f179721948e65531d26144/codex-rs/login/src/auth/manager.rs)
uses a JSON refresh grant at `auth.openai.com/oauth/token`, native client ID, no resource;
omitted replacement refresh tokens retain the old value. Reused/expired/invalidated tokens
have terminal classifications. This is client behavior, not proof of server grace periods.
[Core client](https://github.com/openai/codex/blob/979011409de0a60b52f179721948e65531d26144/codex-rs/core/src/client.rs)
keeps turn state in a per-turn OnceLock. The gateway follows first-value-wins.

[Usage endpoint](https://github.com/openai/codex/blob/979011409de0a60b52f179721948e65531d26144/codex-rs/backend-client/src/client/rate_limit_resets.rs)
is GET `https://chatgpt.com/backend-api/wham/usage` for the ChatGPT path style.
[Window schema](https://github.com/openai/codex/blob/979011409de0a60b52f179721948e65531d26144/codex-rs/codex-backend-openapi-models/src/models/rate_limit_window_snapshot.rs)
has integer `used_percent`, `limit_window_seconds`, `reset_after_seconds`, `reset_at`.
`rate_limit` holds boolean `allowed`/`limit_reached` and nullable `primary_window`/
`secondary_window`. The native client uses absolute `reset_at`, not a countdown reconstructed
from `reset_after_seconds`; the gateway must require a fresh observation after that reset.
These fields are **source-derived; the real endpoint response remains unverified**. A loopback
fixture cannot establish what a live account actually returns.

[Official authentication documentation](https://learn.chatgpt.com/docs/auth) describes automatic
refresh and file storage under CODEX_HOME, and treats the cached login as sensitive. Neither
that page nor the inspected client source establishes whether a second device login on the
same account invalidates the first login's refresh token. **Unverified:** independent-login
revocation semantics, server refresh replay grace, account eligibility, real usage window
availability and reset behavior. The separate gateway login avoids sharing a rotation chain;
it does not prove those server properties. Verify them during the separately authorized canary.

## Lighting the rail — 2026-10-19 (FU-270)

Operator rulings (seat session, 2026-10-19) that end the "unselected" state of the gateway half:

1. **Upstream profile = the native Codex backend** (`https://chatgpt.com/backend-api/codex`, the
   native refresh transport of PR #2677). SIWC stays a named, unselected gap.
2. **Credential store = gateway-local, durable** (`GATEWAY_DB` SQLite on the PVC; single replica,
   `Recreate`; FU-271 keeps HA deferred). Infisical holds the **seed only** (`CODEX_SEED_RECORD`
   → ESO → `agent-egress/codex-seed`, key `record`), imported once and re-read only when its bytes
   change; a re-seed IS the lost-rotation recovery operation. No write-back.
3. **The gateway gets its own login** — never the homelab-codex jail's `auth.json`: native refresh
   rotates with reuse detection, so two refreshers on one token set revoke each other. Whether a
   second device login on the same account invalidates the first is **unverified** (Codex's own
   read of the pinned source left it open); the seed recipe must settle it before the mint.

The five legs (Codex authored A–C in the jail until its usage limit; the seat finished the
specs-review rounds):

| Leg | What | State |
|---|---|---|
| A | `SqliteStore` + hash-gated seed import + `__main__` wiring + deploy manifests (ExternalSecret, env, optional mount) | **merged #2734**; the ExternalSecret switched to `dataFrom.find` the same hour (an absent Infisical key had kept the ArgoCD app Degraded) |
| B | `x-codex-turn-state` round trip bound to session, account and `client_metadata.turn_id`; `turn-state-invalid` | **merged #2735** (19:35Z) |
| C | same-pod token-only re-read on `POST /sessions/{id}/env` (the `auth.command` seam) | **merged #2736** (19:5xZ) |
| D | headroom from the gateway's own usage poll → `gateway_subscription_*{rail="codex"}` + panels on UID `claude-subscription` | not started |
| E | the seed recipe as code: `codex login` into a throwaway `CODEX_HOME` → `infisical-secret` → delete; runbook entry (third-party-console class) | **recipe landed 2026-10-22**: `scripts/codex-seed-bootstrap.sh` (`devbox run codex-seed`) + [runbook §Enrol the gateway's own Codex login](../runbook.md#enrol-the-gateways-own-codex-login-the-codex-seed--fu-270-leg-e) — login in a throwaway home, usage-endpoint probe (structure only), Infisical → force-sync → readback hash check, shred. **Minted 2026-10-22 ~20:00Z** on the host (`store` verified the Secret's record hash `a1e1523e…`; the seeded access JWT expires 2026-11-01T20:00Z — a 10-day native access-token lifetime, observed). The `login` probe's live usage payload shape is below. Open: the second-login revocation question (watch the jail's codex for a re-login prompt) |

### Live usage payload shape — 2026-10-22 (FU-270 leg E)

The leg-E `login` probe (one `GET https://chatgpt.com/backend-api/wham/usage` with the fresh seed
token + `ChatGPT-Account-ID`, Plus account) answered **200**. Field/type structure only — no values
were captured — so this verifies the source-derived window schema above and nothing about limits:

```text
account_id: str            email: str            user_id: str            plan_type: str
rate_limit: {allowed: bool, limit_reached: bool,
             primary_window:   {used_percent: int, limit_window_seconds: int, reset_after_seconds: int, reset_at: int},
             secondary_window: {same four}}
rate_limit_reached_type: null        additional_rate_limits: null        code_review_rate_limit: null
rate_limit_reset_credits: {applicable_available_count: int, available_count: int}
credits: {balance: str, has_credits: bool, unlimited: bool, overage_limit_reached: bool,
          approx_cloud_messages: [2], approx_local_messages: [2]}
model_usage: {gpt-6-astra: {available: bool, available_at: null, credits_would_enable: bool}}
spend_control: {individual_limit: null, reached: bool}        promo: null
```

What this settles for `GW-CODEX-HEADROOM`: both windows are present on this account with integer
`used_percent` and absolute `reset_at` (the native client's basis), `allowed`/`limit_reached` are
booleans, and `rate_limit_reached_type` is a field the gateway's admission can map (null here).
What it does not: `account_id`/`email`/`user_id` are identity values the poll must never persist or
export; `model_usage` keys are **account-specific model evidence** (one key, `gpt-6-astra`, on this
Plus account) — a hint for the explicit canary model, not a pin or an entitlement proof; the
`credits`/`spend_control` blocks are unmodelled. The window values themselves were not read.

After E: the codex rail block in the deployed policy (tier lists derived — `benchmarks.json` needs
`codex/<id>` spellings), the `codex` cell in the launcher, the agent-runtime `agent-codex` wrapper
rendering the provider block from the dispatch env, and the live canary in a declared maintenance
window (step 4 above). The mint and the window are the operator's.

**Built 2026-10-22/23 (seat, unattended):** leg D's poll half — the gateway polls the usage
endpoint itself (`GW-CODEX-HEADROOM §Poll`, two alerts; #2828); the policy block, prober-only,
with the codex list derived from the enrolled account's one model (`CODEX_CANDIDATES`, the
usage probe's `model_usage`; stacked on #2828); the launcher's `codex` cell (`--harness codex` →
`agent-codex --dangerously-bypass-approvals-and-sandbox …`, the key-ref / subscription-arm
exemptions) + `gateway/scripts/canary-codex.sh`, the one-ride canary verb for the window; the
runtime wrapper rendering the provider block from the pulled env
([agent-runtime#179](https://github.com/teststuffstash/agent-runtime/pull/179)). The canary
itself waits for all four to land and for a declared window.

## Recorded live protocol experiment — 2026-10-22 (FU-270)

**Plan, not implemented or live evidence.** The operator asked for captured requests/responses
from in-cluster Codex to improve the requirements, beyond a canary that merely completes.
This extends FU-270's existing vendor-header and live-canary gaps; it does not enable the rail
or authorize enrollment in this documentation session. The native profile selected above stays
selected. The [gateway spec process](../../gateway/specs/README.md) and
[Responses requirements](../../gateway/specs/endpoints/openai-responses.md) own the resulting
contract; the [existing CLI probes](../../experiments/codex-rail/README.md) are the starting point.

### Credential ownership and experiment boundary

Use leg E's **separate gateway login**, imported through `CODEX_SEED_RECORD` → Infisical → ESO
→ the gateway's durable SQLite store. The worker receives only its gateway session token;
the gateway alone owns upstream renewal. Never copy the active jail's renewable login to a
second refresher. A short-lived access token can establish inference behavior, but cannot
establish renewal/recovery. Independent-login revocation semantics remain unverified as noted
above; enrollment must record that uncertainty and the observed effect on the existing login.
The login's browser consent is the third-party-console class under the
[minting doctrine](../secrets.md#minting-doctrine--a-tokens-scope-is-config-not-a-secret);
credential transfer and cleanup belong to the coded enrollment recipe.

Run a bounded experiment with a pinned agent-runtime image, an explicitly selected model,
synthetic prompts and a disposable workspace containing only experiment fixtures. Scope capture
to the experiment's sessions, with duration/byte limits and an explicit completion or truncation
marker. Declare the [maintenance window](../../.claude/skills/maintenance-window/SKILL.md) before
deploying/running the live experiment. Ordinary fleet traffic is outside this capture scope.

### Capture before and after gateway transformations

Record four correlated boundaries: **client request received**, **upstream request sent**,
**upstream response received**, and **client response sent**. Egress-only capture cannot show
what the gateway discarded; ingress-only capture cannot show what the backend actually saw.
The observer must preserve streaming and cancellation behavior, avoid whole-response buffering,
and never replay a request as a side effect of recording. Recorder loss/overflow is explicit
in the evidence; a missing capture is not an observed absence of a header or event.

| Capture | Evidence retained |
|---|---|
| HTTP request/response at each boundary | method, destination/path, status, header names and approved non-sensitive values; added/dropped/rewritten fields |
| Request JSON and ordered SSE events | sanitized bodies for the synthetic task, tool definitions/calls/results, continuation inputs, terminal status, error codes and usage; event order and relative times |
| Opaque identifiers and routing state | run-local aliases preserving equality across all four boundaries, turn boundaries and retries; no account or routing-state values in published evidence |
| Lifecycle | request/turn/session correlation, attempt count, cancellation, disconnect, EOF, parser failure and capture completeness |
| Usage polling and refresh | separately instrumented gateway-owned calls: sanitized field/type structure, status, timing, window/reset observations and replacement-token presence; never token values |
| Provenance | runtime image digest, Codex version, gateway revision/image digest, model, provider/transport configuration, scenario, timestamp and capture format version |

Sanitize **before persistence**, including error paths: remove authorization, cookies, session
tokens, OAuth token values, account identifiers and sensitive URL/query values. Use structured
capture sanitization, not the existing log formatter's token-pattern matching. Unknown fields
must not silently become public attachments: retain their structural presence/type and mark
their values withheld until a safe export rule exists. Synthetic prompts/tool results can be
retained after checking them; redaction must preserve the structures the requirement relies on.
Prove these rules with dummy secret canaries before introducing a real credential.

Keep the sanitized experiment bundle in restricted storage with bounded retention; log only its
reference and summary. The anonymously readable gateway-specs site receives only reviewed,
sanitized evidence exports. Replay fixtures replace opaque IDs/state consistently and retain
the event/body structure needed to exercise the gateway. Do not replay credentials or refresh
calls against the real backend. Sanitization and any normalization must be described alongside
the fixture, so the artifact never claims byte-for-byte fidelity it does not have.

### Establish a baseline, then test the gateway's choices

First record a native-client baseline through an isolated recording forwarder that preserves
the native request semantics. Verify the pinned client's supported routing configuration before
choosing the capture mechanism; a custom provider can itself change emitted headers/tools.
Document that configuration and any deviation from the native path. The baseline's credential
ownership must be explicit and exclusive too: no baseline client and gateway refreshing the
same token chain concurrently. This baseline is an experiment, not a production passthrough
exception to the gateway's credential/header boundary.

Then run the same scenario/configuration through the gateway and compare all four boundaries.
**Observed is not required:** seeing a header establishes presence; successful inference with
it establishes compatibility for that run. Necessity requires a controlled comparison changing
one header/behavior at a time, repeated where variability matters. Keep inconclusive results
inconclusive. Never infer native-backend requirements from SIWC documentation alone.

| Scenario | Observation needed | Requirement home |
|---|---|---|
| Tool turn, then another turn | actual tool call, result submission, terminal completion; state reuse within the turn and clearing between turns | `GW-RAIL-CODEX` |
| Cancellation/interrupted stream | client cancellation propagation, upstream closure, partial events and distinct terminal/transport outcomes | `GW-RAIL-CODEX`, `GW-METRICS` |
| Natural renewal, then gateway restart | one refresh owner, persisted replacement before use, subsequent use after restart; no credential in artifacts | `GW-CODEX-OAUTH`, `GW-CODEX-REFRESH`, `GW-REDACT` |
| Real account usage observation | payload field types, available windows, absolute reset semantics and freshness; missing/unknown windows remain unknown | `GW-CODEX-HEADROOM` |
| Observed limit/auth/backend failure | HTTP status plus SSE error/terminal data, resulting admission/accounting behavior; HTTP 200 alone is not success | `GW-RAIL-CODEX`, `GW-CODEX-HEADROOM`, `GW-SESSIONS-ADMIT`, `GW-METRICS` |

Do not burn through account quota or revoke a working login to manufacture a failure. A failure
not encountered live stays unobserved. Exercise such paths offline with explicitly synthetic
faults; distinguish them from captured vendor behavior. In particular, OpenAI's
[Responses events](https://developers.openai.com/api/reference/resources/responses/streaming-events)
distinguish failed, incomplete and completed responses; preserve that distinction through
capture, the gateway ledger and metrics instead of treating every HTTP 200 as completion.

### Build order and acceptance

Under FU-270: specify the capture/export contract and prove sanitization offline; implement
the scoped observer and coded enrollment recipe; run the baseline and gateway scenarios in the
maintenance window; review the bundle; then derive requirement rows and deterministic offline
replay fixtures. Leg D's gauges landed in #2786; the real usage poll is still part of this work.
Do not inject fake healthy headroom into a live run to bypass the missing poll. Establish the
account-bound observation path before claiming production admission has been exercised.

Acceptance is an **evidence bundle linked to requirement rows**, not a successful CLI exit.
Each row identifies its provenance as official documentation, pinned client-source behavior,
live observation, controlled comparison, replay evidence or synthetic fault. It states the
tested version/configuration and remaining uncertainty. Captured failures count as findings,
not failed experiments to discard. The built-image run complements the existing PR-head fake
tests; its sanitized fixtures must replay offline without credentials or external requests.
Header-policy or lifecycle changes discovered here land through the normal spec/review lane;
unobserved cases remain named gaps. No new tracker item is needed for this FU-270 extension.
