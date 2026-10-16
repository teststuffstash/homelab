# Codex Responses rail prototype

An isolated implementation experiment for
[the subscription-rail spike](../../docs/spikes/codex-subscription-rail.md#gateway-prototype--isolated-build-2026-10-16-fu-270)
(FU-270). It is not imported, deployed or tested by the active gateway build. Python's standard
library is the only dependency; use the repository's Devbox Python.

From the repository root:

```sh
devbox run -- python3 -m unittest discover -s experiments/codex-rail -v
devbox run -- python3 experiments/codex-rail/compat.py --expect-version 0.163.0
# Select another installed CLI explicitly; a version mismatch fails before the fixture runs:
devbox run -- python3 experiments/codex-rail/compat.py --codex /path/to/codex --expect-version 0.161.0
```

`adapter.py` supplies three integration seams:

- `prepare`: an already-admitted session's token/model and a trusted upstream credential turn
  into an unchanged Responses body and allowlisted headers. Caller-supplied credentials and
  account selectors do not pass through. Production admission/expiry/role checks belong to
  the gateway; the fixture's fixed dummy token is not a session service.
- `relay`: a transport supplies byte chunks and a close callback; SSE is forwarded unchanged
  while bounded, incremental parsing observes terminal outcome and usage. Missing usage is
  unknown, not zero. Failure and incomplete terminal events retain their own outcomes.
  `[DONE]` or EOF alone cannot prove success. The consumer must close the iterator on disconnect.
- `http_failure`: fixed classifications for auth, throttling and other non-200 statuses.
  A future transport must enforce timeouts, preserve safe retry headers, refuse redirects and
  map these codes onto gateway HTTP errors before sending downstream response headers.

The native CLI fixture binds only `127.0.0.1` on an ephemeral port, uses a fresh temporary
`CODEX_HOME` for the child, an empty working directory, an allowlisted environment and dummy
credentials. External HTTP proxies point to a closed loopback port; this is defense in depth,
not a network namespace. No real upstream is contacted by fixture code. Never run an untrusted
CLI binary here. Requests and CLI logs are not persisted; only an allowlisted evidence summary
is printed. Temporary configuration is deleted on exit. No tool invocation is returned by the
synthetic model. The fixture exercises native `codex exec --json`, not app-server or agent-codex
finalization, and must not be reported as a real subscription/tool-use canary.

## Acceptance evidence

`test_adapter.py` covers authentication/model/mode/input refusals, header replacement, every
byte split of a CRLF stream, multiline events, terminal usage beyond 4 MiB, duplicate terminal
accounting, failed/incomplete streams, unknown usage, malformed/oversized/truncated events,
transport-error sanitization and cancellation without draining upstream.

The native check requires the expected CLI version, a completed JSONL turn with the synthetic
answer, a correctly shaped request, no auth.json, and one adapter close per request. It prints
`live_subscription_verified: false` even when successful. Checked versions and outputs are
recorded in `evidence.json`; these are dated local evidence, not automatically maintained CI.

## Integration boundary

The prototype deliberately has no production HTTP client, OAuth refresh/store, quota polling,
retry policy, model entitlement discovery, Kubernetes manifests or gateway policy changes.
Protocol compatibility with a fake Responses endpoint does not choose between the September
Codex backend path and the newer SIWC preview. Both need backend-specific request/header
fixtures, and the SIWC restricted parameter/tool surface is not validated here.

Before extraction into `gateway/`, agree its Responses dialect and GW schema/decision rows,
replace the fixed fixture token with its session lookup, supply its managed HTTP transport,
and wire terminal outcomes into metrics/accounting. Review identity/session-affinity header
requirements explicitly: this prototype's conservative allowlist does not claim full vendor
header compatibility. Preserve stream cleanup on cancellation and never retry a generation
after bytes reach the consumer. OAuth lifecycle and fresh headroom remain the later FU-270
slices described in the owning spike; HA remains FU-271.
