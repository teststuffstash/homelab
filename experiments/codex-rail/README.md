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
