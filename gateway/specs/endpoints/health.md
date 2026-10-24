---
id: EP-HEALTH
use-cases: [UC-1]
schema: health.schema.json
---
# GET /healthz — liveness, and which store the gateway is running on

The probe target and the one place the store mode is visible. `{ok: true, db: "pvc"}` is the
normal answer. ADR-139 keeps the gateway single-replica on SQLite at `/data/gateway.db` (a 1Gi
Longhorn PVC); when the PVC is unusable at start the gateway **fails open** to an in-memory
store, logs it loudly, and says so here (`db: "memory"`) — sessions, and the admission's capacity
marks ([GW-SESSIONS-ADMIT §Kept across a restart](sessions.md#kept-across-a-restart)), then live only
until the next restart. HA (FU-271) is a gap.

## Interface — the machine half

**[`health.schema.json`](health.schema.json)** holds the one output shape; the service
**imports it**. No error codes: the process answers 200 or is not there.

| Requirement | Governs (schema) | Error codes | Status |
|---|---|---|---|
| [GW-HEALTH](#gw-health) | `output` | — | v0 — HA (FU-271) and an alert on `db: memory` are `⚑ gap` (rows below) |

## GW-HEALTH

| description | store state at start || status | body | log |
|---|---||---|---|---|
| "the PVC is mounted and writable" | `/data/gateway.db` opens || 200 | `{"ok": true, "db": "pvc"}` | `db: pvc /data/gateway.db` |
| "the PVC is missing — fail open ⚖" | `/data` absent || 200 | `{"ok": true, "db": "memory"}` | `db: memory — FAIL-OPEN, sessions do not survive a restart` |
| "the PVC is read-only — fail open ⚖" | `/data` mounted, open for write fails || 200 | `{"ok": true, "db": "memory"}` | the same loud line |
| "the DB file is corrupt — fail open ⚖" | `/data/gateway.db` fails integrity on open || 200 | `{"ok": true, "db": "memory"}` | the same loud line, naming the file |

| description | sequence || `gateway_sessions_active` after |
|---|---||---|
| "a memory store forgets on restart" | memory mode, dispatch, restart || 0 — the pod's token is now `session-unknown` |
| "a PVC store remembers" | pvc mode, dispatch, restart || 1 — the pod's token still resolves |
| "a PVC store from before the cache columns is migrated" | pvc mode, dispatch, cache columns dropped (the 2026-10-16 schema), restart, the old token rides once || 1 — the session survives; the ride is recorded (`requests` = 1); `GET` shows `tokens_cache_read` = `tokens_cache_write` = 0 (columns added on open, additive only) |

| description | request || status | body |
|---|---||---|---|
| "no auth is required" | `GET /healthz`, no headers || 200 | the shape above |
| "no other field is served" | `GET /healthz` || 200 | exactly `ok` and `db` |

| description | input || v0 answer | the gap |
|---|---||---|---|
| "⚑ gap: a second replica" | 2 replicas || both count sessions alone — every cap doubles | HA, FU-271 (a session store + a durable store after a per-request measurement) |
| "⚑ gap: memory mode fires nothing" | `db: memory` || the log line and this field | a `gateway_db_mode` metric and its alert |

<details markdown="1"><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-HEALTH.md"

</details>
