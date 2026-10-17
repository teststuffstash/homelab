# 2026-10-17 — the OpenCode Go rail ran ~2 h on an expired key, and a later probe self-latched it

**Tracked by:** FU-313 (the 30-day key, expires 2026-11-16; the service-account move). The
detector and the latch fix shipped the same day (below).

**Impact.** 2026-10-17 17:12:49Z → ~19:21Z (~2 h 08 min): every OpenCode Go call on BOTH egress
paths (the old `openrouter-proxy` and the parallel `agent-gateway`) returned `401
api_key_expired`. Go-rail consumers failed: platform worker rides (`deepseek-v4-flash`), the
coordinator's Go model, the reviewer's Go fallback. No alert named it; `AgentLoopWorkflowsFailing`
(from 17:28Z) was the only symptom. It was found by accident: a free-model experiment's Go cells
started failing ([gateway-free-models cells](../spikes/gateway-free-models-2026-10-17/cells.tsv)).

**Timeline (UTC).**

- 17:12:49 the Go key expires upstream. Secret `agent-egress/opencode-go-key` is unchanged since
  2026-08-13; ESO shows it synced, and no expiry was recorded anywhere.
- ~19:05 the seat confirms the expiry from the live gateway pod, then tries two probes that got a
  Cloudflare 1010 (Python's default UA) and a 400 for a missing `x-opencode-session` before the
  real 401.
- ~19:20 the operator mints a 30-day key and updates the wallet entry `opencode-go-api-key`. The
  seat probes it upstream (200), writes Infisical `OPENCODE_GO_API_KEY`, force-syncs the
  ExternalSecret (6 s) and restarts both deployments, because both read the key as env at start.
  Both pods then answer Go with 200.
- Later, during #2694's live check, a probe client's `Python-urllib` UA was FORWARDED upstream.
  Cloudflare answered 403 `error code: 1010`. The gateway read that as a credential rejection and
  marked the opencode rail credential-down. Only a 2xx could clear the mark, and admission refused
  every new session, so it was a permanent self-latch. Cleared by a gateway restart; fixed in
  #2699.

**Root cause.** (1) A credential with an upstream expiry and nothing tracking that expiry. The
vendor exposes no key-expiry API (see [`opencode-go-catalog.md`](../spikes/opencode-go-catalog.md)).
(2) The gateway's first credential-down rule, from failure-ownership PR 1 (#2692), treated any
unparsable 403 as a credential verdict. It also forwarded the caller's User-Agent and had no way
to recover without traffic.

**What changed.**

- A Go-credential detector on both paths: the agent's PR, with promtool tests and a replay over
  17:12–19:20Z.
- #2699: credential-down only on a credential-shaped 401/403. An edge 403 becomes
  `upstream-edge-refused`, scoped to the request. The gateway sends its own UA on the opencode
  rail, re-probes a rejected rail on a backoff, and a changed Secret value clears the mark.
- FU-313: the expiry date plus the move to an OpenCode service-account key.

**Findings.** A credential with a known lifetime needs its expiry written down when it is minted.
A latch whose only release is the traffic it blocks is a deadlock; every latch needs a release
that does not depend on admission.
