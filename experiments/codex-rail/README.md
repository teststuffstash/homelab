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

The prototype deliberately has no production HTTP client, OAuth transport/store backend, quota polling,
retry policy, model entitlement discovery, Kubernetes manifests or gateway policy changes.
Protocol compatibility with a fake Responses endpoint does not choose between the September
Codex backend path and the newer SIWC preview. Both need backend-specific request/header
fixtures, and the SIWC restricted parameter/tool surface is not validated here.

Before extraction into `gateway/`, agree its Responses dialect and GW schema/decision rows,
replace the fixed fixture token with its session lookup, supply its managed HTTP transport,
and wire terminal outcomes into metrics/accounting. Review identity/session-affinity header
requirements explicitly: this prototype's conservative allowlist does not claim full vendor
header compatibility. Preserve stream cleanup on cancellation and never retry a generation
after bytes reach the consumer. OAuth lifecycle and headroom are offline components described below; production integration
remains under FU-270 in the owning spike. HA remains FU-271.


## Offline lifecycle and headroom (FU-270)

`lifecycle.py` takes a clock, exchange callback and `Store` interface. Credentials never
appear in record reprs or boundary exception messages/chains. This is not a general-purpose
logging scrubber: consumers must never serialize the credential object or log callback locals.
`test_lifecycle.py` uses dummy strings and a shared memory store to exercise multiple owners,
rotation, owner restart, process interruption, ambiguous persistence, revocation and redaction.
It proves state-machine behavior, not disk durability or distributed fencing.

The proposed store contract is one account per store, an exclusive lock across **all** owners,
and atomic durable replacement. Hold the lock across load, refresh and save. Before contacting
upstream, persist `refreshing`; return a rotated access token only after saving `ready` with the
replacement credentials. Fresh credentials bypass refresh. Expiry margin defaults to 30 seconds.
A refresh callback must return the complete validated replacement record for the same account;
authoritative revocation raises `Revoked`. There is no automatic exchange retry.

| Durable state / failure | Result on next acquire |
|---|---|
| `ready`, still fresh | Return access credential |
| `ready`, near expiry | Persist marker, exchange once, persist rotation |
| `refreshing`, including crash or uncertain exchange | `credential-recovery-required`; no exchange |
| `revoked` | `credential-revoked`; no cached access |
| Save acknowledges failure after committing | Reload authoritative state on next call |

If the exchange rotates the token and the process dies before persistence, the marker cannot
recover the lost replacement. The prototype fails closed. Recovery needs an authoritative
replacement credential through a future, explicitly designed recovery operation; blindly clearing
the marker or replaying the old refresh token is forbidden. Store exceptions produce
`credential-store-unavailable`; exchange uncertainty produces `credential-refresh-uncertain`;
invalid replacements produce `credential-invalid`. A failed save never returns new access.
Infisical write-back, cross-process lock/fencing, timeouts and revocation transport are unresolved
production choices. No Kubernetes Secret or Infisical implementation is supplied.

`headroom.py` owns one account's immutable snapshot. Its explicit ingress schema is:

```json
{"observed_at": 990, "source": "poll", "limited": false,
 "windows": [{"used_percent": 20, "resets_at": 2000, "window_minutes": 300},
             {"used_percent": 64, "resets_at": 9000, "window_minutes": 10080}]}
```

Timestamps are epoch seconds supplied by an authenticated, account-bound producer. Source is
one of `poll`, `upstream`, or `jail`; it is provenance, not an authorization claim. Authenticating
reports and translating vendor payloads are future integration responsibilities. The two window
durations are an explicit **fixture profile**, not discovered account entitlements. Percentages
normalize to ratios. Non-finite numbers, bool-as-number, missing/duplicate windows, expired reset
times, unknown sources, stale/future observations and non-increasing timestamps are rejected
without replacing the last accepted snapshot. Equal timestamps are rejected even across sources;
this prototype assumes synchronized clocks and gives no source preferential authority.

Verdicts are `admit`, `quota-unknown`, `quota-stale`, or `quota-limited`. Fixture policy uses a
120-second freshness limit and a 95% utilization ceiling, both configurable. Any exhausted
window or explicit limit blocks admission. Reaching freshness expiry or a reset timestamp requires
a new observation; reset time passing does not imply replenished capacity. Clock rollback is
stale. Restart starts unknown. Reports do not reserve capacity, meter concurrent requests, or
provide an entitlement guarantee; admission must still compose with the gateway's session and
concurrency controls. No Prometheus queries or production policy changes are involved.

Run all offline tests with the existing unittest command above. The original Responses and
native CLI fixtures remain unchanged and are regression checks for this extension.
