"""GW-HEALTH — liveness and the store mode (specs/endpoints/health.md).

| description | store state at start | status | body | log |
|---|---|---|---|---|
| the PVC is mounted and writable | /data/gateway.db opens | 200 | {"ok": true, "db": "pvc"} | db: pvc <path> |
| the PVC is missing — fail open | /data absent | 200 | {"ok": true, "db": "memory"} | db: memory — FAIL-OPEN, sessions do not survive a restart |
| the PVC is read-only — fail open | /data mounted, open for write fails | 200 | {"ok": true, "db": "memory"} | the same loud line |
| the DB file is corrupt — fail open | /data/gateway.db fails integrity on open | 200 | {"ok": true, "db": "memory"} | the same loud line, naming the file |

| description | sequence | gateway_sessions_active after |
|---|---|---|
| a memory store forgets on restart | memory mode, dispatch, restart | 0 — the pod's token is now session-unknown |
| a PVC store remembers | pvc mode, dispatch, restart | 1 — the pod's token still resolves |

| description | request | status | body |
|---|---|---|---|
| no auth is required | GET /healthz, no headers | 200 | the shape above |
| no other field is served | GET /healthz | 200 | exactly ok and db |
"""

from __future__ import annotations

import logging
import os
import re

import httpx
import pytest

from agent_gateway.app import create_app
from agent_gateway.config import Settings
from agent_gateway.store import Store

from .conftest import POLICY_FIXTURE, bearer, err, open_session, rule

pytestmark = rule("GW-HEALTH")


def _app(policy, secrets, path: str):
    settings = Settings.from_env({"GATEWAY_POLICY": str(POLICY_FIXTURE), "GATEWAY_DB": path, "OPENCODE_GO_API_KEY": "go-key-for-tests-only"})
    return create_app(settings, policy=policy, source=secrets, store=Store(path), client=httpx.AsyncClient())


async def _get(app, path: str, **kw):
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://gw") as c:
        return await c.get(path, **kw)


ROWS = [
    ("the PVC is mounted and writable", "file", "pvc"),
    ("the PVC is missing — fail open", "missing-dir", "memory"),
    ("the PVC is read-only — fail open", "read-only", "memory"),
    ("the DB file is corrupt — fail open", "corrupt", "memory"),
]


@pytest.mark.parametrize(("state", "mode"), [r[1:] for r in ROWS], ids=[r[0] for r in ROWS])
async def test_store_state(tmp_path, policy, secrets, caplog, state, mode):
    caplog.set_level(logging.INFO, logger="gateway.store")
    path = str(tmp_path / "data" / "gateway.db")
    if state == "file":
        (tmp_path / "data").mkdir()
    elif state == "read-only":
        (tmp_path / "data").mkdir()
        Store(path).close()
        os.chmod(path, 0o444)
        os.chmod(tmp_path / "data", 0o555)
    elif state == "corrupt":
        (tmp_path / "data").mkdir()
        (tmp_path / "data" / "gateway.db").write_bytes(b"SQLite format 3\x00" + b"\xff" * 4096)
    try:
        app = _app(policy, secrets, path)
        r = await _get(app, "/healthz")
    finally:
        if state == "read-only":
            os.chmod(tmp_path / "data", 0o755)
    assert r.status_code == 200 and r.json() == {"ok": True, "db": mode}
    lines = [rec.getMessage() for rec in caplog.records]
    if mode == "pvc":
        assert any(line.startswith(f"db: pvc {path}") for line in lines), lines
    else:
        assert any(line.startswith("db: memory — FAIL-OPEN, sessions do not survive a restart") and path in line for line in lines), lines


async def _restart_roundtrip(policy, secrets, path: str) -> tuple[int, int]:
    app1 = _app(policy, secrets, path)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app1), base_url="http://gw") as c:
        doc = await open_session(c)
    app1.state.store.close()
    app2 = _app(policy, secrets, path)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app2), base_url="http://gw") as c:
        text = (await c.get("/metrics")).text
        active = int(re.search(r'^gateway_sessions_active\{rail="opencode"\} (\d+)$', text, re.M).group(1))
        r = await c.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))
    return active, (r.status_code, err(r) if r.status_code != 200 else None)


async def test_memory_forgets(policy, secrets):
    """row: a memory store forgets on restart"""
    active, verdict = await _restart_roundtrip(policy, secrets, ":memory:")
    assert active == 0 and verdict == (401, "session-unknown")


async def test_pvc_remembers(tmp_path, policy, secrets, upstreams):
    """row: a PVC store remembers"""
    active, verdict = await _restart_roundtrip(policy, secrets, str(tmp_path / "gateway.db"))
    assert active == 1 and verdict[0] in (200, 502)  # 502: the fresh app has no fake transport — the session resolved either way


async def test_no_auth_required(gw):
    """row: no auth is required"""
    r = await gw.get("/healthz")
    assert r.status_code == 200 and r.json()["ok"] is True


async def test_no_other_field(gw):
    """row: no other field is served"""
    r = await gw.get("/healthz")
    assert set(r.json()) == {"ok", "db"} and r.json()["db"] == "pvc"
