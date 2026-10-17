# Codex rail — the native-CLI compat harness

The Codex Responses rail prototype (FU-270, #2625/#2642) has been **ported into the gateway**:
the Responses adapter, the OAuth lifecycle and the headroom component live in
[`gateway/src/agent_gateway/`](../../gateway/src/agent_gateway/) (`responses.py`, `oauth.py`,
`headroom.py`, `codex.py`), and their tests are GW rows —
[`GW-RAIL-CODEX`, `GW-CODEX-HEADROOM`, `GW-CODEX-OAUTH`](../../gateway/specs/endpoints/openai-responses.md)
plus the codex rows of [`GW-SESSIONS-ENV`](../../gateway/specs/endpoints/sessions.md#gw-sessions-env).
The rail ships dark: the deployed policy declares no codex rail and production wires no credential
store. Design and history: [the spike](../../docs/spikes/codex-subscription-rail.md#gateway-prototype--isolated-build-2026-10-16-fu-270).

What remains here is the one thing CI cannot run: the **pinned native Codex CLI** against the
real gateway. [`compat.py`](compat.py) serves the gateway app (uvicorn on `127.0.0.1`, the
`policy-codex` world, the FAKE store from `gateway/tests/_codex_world.py`) in front of a loopback
fake Responses upstream, asks `POST /sessions` for a codex dispatch, renders the Codex provider
block FROM the dispatch `env` (the harness wrapper's job), and runs `codex exec --json` in a fresh
`CODEX_HOME` with only `PATH`, `CODEX_HOME`, the session token and closed loopback proxies:

```sh
cd gateway   # the island's locked environment (httpx, uvicorn, the gateway itself)
devbox run -- uv run --frozen python ../experiments/codex-rail/compat.py \
    --codex /path/to/codex --expect-version 0.161.0 --probe-bare-env
```

A version mismatch fails before anything runs. It passes only when the CLI completes the synthetic
turn, no `auth.json` is written, the upstream saw the rotated access token and the credential's
account header (never the caller's), the FAKE lifecycle exchanged exactly once, and the session
row counted the one request with its usage. `--probe-bare-env` first checks that the bare
`OPENAI_BASE_URL` / `OPENAI_API_KEY` without a provider block do **not** reach the gateway (the
observation behind the GW-SESSIONS-ENV ⚖ rows). It prints `live_subscription_verified: false`
even when it passes. Results: [`evidence.json`](evidence.json) — dated local evidence, not CI.

Dummy credentials only; no real upstream, OAuth exchange, model or tool call. Never run an
untrusted CLI binary here. Process logs and request bodies are never printed — only the
allowlisted summary. This proves the client seam through the gateway, not subscription access,
the deployed agent-runtime image, tool use or the live canary (spike step 4, separately authorized).

## Upstream-profile observation

FU-270's [upstream investigation](../../docs/spikes/codex-subscription-rail.md#upstream-profile-investigation--2026-10-17-fu-270)
compares the native backend with SIWC. `profile_probe.py` adds an observer to the compat harness,
reporting a fixed set of request-shape checks against the SIWC preview documentation. The fake
upstream still accepts the request: a completed fixture is NOT a successful SIWC inference.
There is no real OAuth exchange, backend call or entitlement test. It observes only the first
synthetic turn with `fixture-model`, not every real-model tool configuration or a tool continuation.

```sh
# From gateway/, using its locked environment; the binary must be trusted and version matched.
devbox run -- uv run --frozen python ../experiments/codex-rail/profile_probe.py \
    --codex /path/to/codex --expect-version 0.161.0
# From the repo root, pure observer checks (no CLI/network/dependencies):
devbox run -- python3 -m unittest discover -s experiments/codex-rail -p 'test_profile_probe.py'
```

The observer exports fixed names, booleans and counts only. It never emits raw prompts, tool
names/arguments, unknown fields, credentials or header values. Unknown tool structures are
reported as unverified; passing the partial checks never proves complete profile compatibility.
[`profile-evidence.json`](profile-evidence.json) records the dated 0.161.0/0.163.0 observations:
both contain seven ungrouped function tools, a documented SIWC mismatch. The runtime provenance,
source references and remaining acceptance work live in the spike. This probe is explicitly run,
not added to active CI, and does not close #2650.
