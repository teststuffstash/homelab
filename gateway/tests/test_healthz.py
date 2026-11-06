"""GW-HEALTH — liveness and the store mode (specs/endpoints/health.md). Four tables, one question
each; header == the parametrize argnames (`name?` ⇄ `expected_name`), description == the row id.
World: policy-default (one world — declared here, not per row)."""

from __future__ import annotations

import json
import logging
import os
import re
import sqlite3

import httpx
import pytest

from agent_gateway.app import create_app
from agent_gateway.config import Settings
from agent_gateway.store import Store

from .conftest import (
    POLICY_FIXTURE,
    UPSTREAM_BASES,
    FakeUpstream,
    ObservedAsyncClient,
    RailTransport,
    bearer,
    err,
    given,
    open_session,
    quiet,
    rule,
    seed_go_catalog,
    then,
    when,
    world,
)

pytestmark = rule("GW-HEALTH")

CHAT = "/openai/v1/chat/completions"
ACTIVE_RE = re.compile(r'^gateway_sessions_active\{rail="opencode"\} (\d+)$', re.M)
UNKNOWN_TOKEN = "gws_" + "x" * 32


def _app(policy, secrets, path: str):
    """A gateway on `path` whose rails reach the in-process fakes (no live upstream, ever)."""
    settings = Settings.from_env({"GATEWAY_POLICY": str(POLICY_FIXTURE), "GATEWAY_DB": path, "OPENCODE_GO_API_KEY": "go-key-for-tests-only",
                                  "ANTHROPIC_UPSTREAM": UPSTREAM_BASES["anthropic"], "OPENROUTER_UPSTREAM": UPSTREAM_BASES["openrouter"],
                                  "OPENCODE_GO_UPSTREAM": UPSTREAM_BASES["opencode"]})
    fakes = RailTransport({rail: FakeUpstream(rail) for rail in UPSTREAM_BASES}, UPSTREAM_BASES)
    return create_app(settings, policy=policy, source=secrets, store=seed_go_catalog(Store(path)), client=httpx.AsyncClient(transport=fakes))


def _client(app) -> ObservedAsyncClient:
    return ObservedAsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://gw")


# -- Which store the gateway runs on ---------------------------------------------------------------
FAIL_OPEN = "db: memory — FAIL-OPEN, sessions do not survive a restart"
STATE_ROWS = [
    pytest.param("file", "pvc", "db: pvc", id="the PVC is mounted and writable"),
    pytest.param("missing-dir", "memory", FAIL_OPEN, id="the PVC is missing — fail open ⚖"),
    pytest.param("read-only", "memory", FAIL_OPEN, id="the PVC is read-only — fail open ⚖"),
    pytest.param("corrupt", "memory", FAIL_OPEN, id="the DB file is corrupt — fail open ⚖"),
]


@pytest.mark.parametrize(("store_state", "expected_db", "expected_log_prefix"), STATE_ROWS)
async def test_which_store_the_gateway_runs_on(tmp_path, policy, secrets, caplog, store_state, expected_db, expected_log_prefix):
    world()
    caplog.set_level(logging.INFO, logger="gateway.store")
    path = str(tmp_path / "data" / "gateway.db")
    with given(f"store_state {store_state}: the DB path (GATEWAY_DB=<tmp>/data/gateway.db)"):
        if store_state == "file":
            (tmp_path / "data").mkdir()
        elif store_state == "read-only":
            (tmp_path / "data").mkdir()
            Store(path).close()
            os.chmod(path, 0o444)
            os.chmod(tmp_path / "data", 0o555)
        elif store_state == "corrupt":
            (tmp_path / "data").mkdir()
            (tmp_path / "data" / "gateway.db").write_bytes(b"SQLite format 3\x00" + b"\xff" * 4096)
    caplog.clear()  # the arrange's own Store() logged too; the lines below are the gateway's
    with when(f"the gateway starts on the {store_state} store, then GET /healthz"):
        try:
            app = _app(policy, secrets, path)
            async with _client(app) as c:
                r = await c.get("/healthz")
        finally:
            if store_state == "read-only":
                os.chmod(tmp_path / "data", 0o755)
    lines = [rec.getMessage() for rec in caplog.records]
    line = next((ln for ln in lines if ln.startswith("db: ")), "")
    with then(f"200 {{ok: true, db: {expected_db}}}; the store log line starts {expected_log_prefix!r} and names the path",
              expected_db={"expected": expected_db, "actual": r.json().get("db")},
              expected_log_prefix={"expected": expected_log_prefix, "actual": line[: len(expected_log_prefix)], "line": line}):
        assert r.status_code == 200 and r.json() == {"ok": True, "db": expected_db}, r.text
        assert line.startswith(expected_log_prefix) and path in line, lines


# -- What survives a restart -----------------------------------------------------------------------
async def _restart(policy, secrets, path: str, store: str, migrate: bool = False) -> tuple[int, httpx.Response, dict]:
    """Two gateways on one GATEWAY_DB in turn: the first dispatches a worker session and closes;
    the second reads /metrics, lets the old token ride once, and (when asked) shows the session."""
    with given(f"a gateway on the {store} store dispatched a worker session (opencode), then its store closed"):
        app1 = _app(policy, secrets, path)
        async with _client(app1) as c:
            doc = await open_session(c)
        app1.state.store.close()
    if migrate:
        db = sqlite3.connect(path)
        for table in ("sessions", "requests"):
            for col in ("tokens_cache_read", "tokens_cache_write"):
                db.execute(f"ALTER TABLE {table} DROP COLUMN {col}")
        db.commit()
        cols = [r[1] for r in db.execute("PRAGMA table_info(sessions)")]
        db.close()
        with given(f"schema_at_restart 2026-10-16: tokens_cache_read / tokens_cache_write dropped from sessions and requests — sessions columns now {cols}"):
            pass
    with when(f"a second gateway starts on the same {store} store: GET /metrics, then the old token rides POST {CHAT}"):
        app2 = _app(policy, secrets, path)
        async with _client(app2) as c:
            with quiet():  # the exposition is bulk; the verdict carries the one sample it judged
                text = (await c.get("/metrics")).text
            active = int(ACTIVE_RE.search(text).group(1))
            r = await c.post(CHAT, json={"messages": []}, headers=bearer(doc))
            row = (await c.get(f"/sessions/{doc['session']['id']}")).json() if migrate else {}
    return active, r, row


RESTART_ROWS = [
    pytest.param("memory", 0, "401 session-unknown", id="a memory store forgets on restart"),
    pytest.param("pvc", 1, "200", id="a PVC store remembers"),
]


@pytest.mark.parametrize(("store", "expected_active_after", "expected_ride_after"), RESTART_ROWS)
async def test_what_survives_a_restart(tmp_path, policy, secrets, store, expected_active_after, expected_ride_after):
    world()
    path = ":memory:" if store == "memory" else str(tmp_path / "gateway.db")
    active, r, _ = await _restart(policy, secrets, path, store)
    ride = str(r.status_code) + (f" {err(r)}" if r.status_code != 200 else "")
    with then(f"active_after = {expected_active_after}, ride_after = {expected_ride_after}",
              expected_active_after={"expected": expected_active_after, "actual": active},
              expected_ride_after={"expected": expected_ride_after, "actual": ride}):
        assert active == expected_active_after and ride == expected_ride_after, (active, ride)


# -- An older schema is migrated on open -----------------------------------------------------------
MIGRATION_ROWS = [
    pytest.param("pvc", "2026-10-16", 1, 1, 0, 0, id="a PVC store from before the cache columns is migrated"),
]


@pytest.mark.parametrize(("store", "schema_at_restart", "expected_active_after", "expected_requests", "expected_tokens_cache_read", "expected_tokens_cache_write"),
                         MIGRATION_ROWS)
async def test_an_older_schema_is_migrated_on_open(tmp_path, policy, secrets, store, schema_at_restart, expected_active_after, expected_requests,
                                                   expected_tokens_cache_read, expected_tokens_cache_write):
    world()
    assert schema_at_restart == "2026-10-16"  # the one older schema this row knows how to build
    active, r, row = await _restart(policy, secrets, str(tmp_path / "gateway.db"), store, migrate=True)
    got = {"expected_active_after": active, "expected_requests": row.get("requests"),
           "expected_tokens_cache_read": row.get("tokens_cache_read"), "expected_tokens_cache_write": row.get("tokens_cache_write")}
    want = {"expected_active_after": expected_active_after, "expected_requests": expected_requests,
            "expected_tokens_cache_read": expected_tokens_cache_read, "expected_tokens_cache_write": expected_tokens_cache_write}
    with then(f"active_after = {expected_active_after}; the ride is recorded: requests = {expected_requests}, "
              f"tokens_cache_read = {expected_tokens_cache_read}, tokens_cache_write = {expected_tokens_cache_write}",
              **{k: {"expected": want[k], "actual": got[k]} for k in want}):
        assert r.status_code == 200, r.text  # the write is the probe: an unmigrated table reads fine and breaks on the UPDATE
        assert got == want


# -- The probe needs no credential -----------------------------------------------------------------
BODY = '{"ok": true, "db": "pvc"}'
PROBE_ROWS = [
    pytest.param("none", 200, BODY, id="no auth is required"),
    pytest.param("an unknown session token", 200, BODY, id="a bearer changes nothing — the probe reads no credential"),
]


@pytest.mark.parametrize(("authorization", "expected_status", "expected_body"), PROBE_ROWS)
async def test_the_probe_needs_no_credential(gw, authorization, expected_status, expected_body):
    world()
    headers = {} if authorization == "none" else {"authorization": f"Bearer {UNKNOWN_TOKEN}"}
    with given(f"authorization {authorization}: headers {headers}"):
        pass
    with when(f"GET /healthz, authorization {authorization}"):
        r = await gw.get("/healthz", headers=headers)
    with then(f"status = {expected_status}, body = {expected_body}",
              expected_status={"expected": expected_status, "actual": r.status_code},
              expected_body={"expected": json.loads(expected_body), "actual": r.json()}):
        assert r.status_code == expected_status and r.json() == json.loads(expected_body), r.text
