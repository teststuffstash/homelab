"""GW-WIRE-VIEW — the read-only door: GET /wire and GET /wire/<source> (specs/endpoints/wire.md §GW-WIRE-VIEW).

World: policy-codex · the fake vendor's `catalog-ok` read recorded at T0 (the config source refreshed once).
The table is the spec's, verbatim; the header is the parameter list.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import pytest
from starlette.responses import JSONResponse

from ._catalog_rows import T0, iso
from ._catalog_world import catalog_doc, gw_client
from ._codex_rows import row, verdicts
from .conftest import given, quiet, rule, when, world

pytestmark = rule("GW-WIRE-VIEW")

SCHEMA = json.loads((Path(__file__).resolve().parents[1] / "specs" / "endpoints" / "wire.schema.json").read_text(encoding="utf-8"))
REQUIRED = SCHEMA["$defs"]["provenance"]["required"]

DOOR_ROWS = [
    pytest.param("go-models-dev at T0", "GET /wire", 200, "per source: class, url, status, bytes, sha256, fetched_at, age_s, complete",
                 id="the index lists every source with its provenance and no body"),
    pytest.param("go-models-dev at T0", "GET /wire/go-models-dev", 200,
                 "body = the stored bytes; x-wire-source, x-wire-class, x-wire-sha256, x-wire-fetched-at",
                 id="one member is its stored bytes, the provenance in headers ⚖"),
    pytest.param("nothing for codex-models", "GET /wire/codex-models", 404, "wire-not-recorded",
                 id="a source never read is not an empty answer"),
    pytest.param("go-models-dev at T0", "GET /wire/go-models-dev, no token", 200, "as above", id="the door asks for no credential ⚖"),
    pytest.param("go-models-dev at T0", "GET /wire", 200, "exactly the schema's required keys", id="the view's shape is the schema's"),
]


@pytest.mark.parametrize(("recorded", "call", "expected_status", "expected_answer"), DOOR_ROWS, ids=[p.id for p in DOOR_ROWS])
async def test_the_door(cworld, vendor, clock, recorded, call, expected_status, expected_answer):
    world("policy-codex", upstream=recorded)
    row(recorded=recorded, call=call)
    app = cworld.build()
    with given(f"recorded = {recorded}"):
        if recorded.startswith("go-models-dev"):
            with quiet():
                await app.state.catalog.refresh_source("config")
    clock.t = T0 + 90
    path = call.removeprefix("GET ").split(",")[0]
    with when(f"{call} (no Authorization header is sent)"):
        async with gw_client(app) as c:
            r = await c.get(path)
    stored = JSONResponse(catalog_doc("catalog-ok")).body
    if path == "/wire":
        doc = r.json()
        src = next(s for s in doc["sources"] if s["source"] == "go-models-dev")
        shape = (sorted(src) == sorted(REQUIRED) and set(doc) == {"sources"} and src["class"] == "public"
                 and src["sha256"] == hashlib.sha256(stored).hexdigest() and src["bytes"] == len(stored)
                 and src["fetched_at"] == iso(T0) and src["age_s"] == 90 and src["complete"] is True and "body" not in src)
        answer = shape
        want = True
    elif r.status_code == 404:
        answer, want = r.json()["error"]["code"], "wire-not-recorded"
    else:
        answer = (r.content == stored and r.headers["x-wire-source"] == "go-models-dev" and r.headers["x-wire-class"] == "public"
                  and r.headers["x-wire-sha256"] == hashlib.sha256(stored).hexdigest() and r.headers["x-wire-fetched-at"] == iso(T0))
        want = True
    verdicts(status=(r.status_code, expected_status), answer=(answer, want))
    assert expected_answer
