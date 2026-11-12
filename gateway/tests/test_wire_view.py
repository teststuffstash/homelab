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
from .conftest import attach_json, given, quiet, rule, when, world

pytestmark = rule("GW-WIRE-VIEW")

SCHEMA = json.loads((Path(__file__).resolve().parents[1] / "specs" / "endpoints" / "wire.schema.json").read_text(encoding="utf-8"))
REQUIRED = SCHEMA["$defs"]["provenance"]["required"]

HEADERS = ["x-wire-source", "x-wire-class", "x-wire-sha256", "x-wire-fetched-at", "x-wire-complete"]
INDEX_ANSWER = ("`sources` = one entry per source on file, each exactly source, class, url, status, bytes, sha256, fetched_at, age_s, complete, "
                "last_error, last_error_at; no body")
MEMBER_ANSWER = "body = the stored bytes; headers x-wire-source, x-wire-class, x-wire-sha256, x-wire-fetched-at, x-wire-complete"

DOOR_ROWS = [
    pytest.param("go-models-dev and go-console-config at T0", "GET /wire", 200, INDEX_ANSWER,
                 id="the index lists every source with its provenance and no body"),
    pytest.param("go-models-dev at T0", "GET /wire/go-models-dev", 200, MEMBER_ANSWER,
                 id="one member is its stored bytes, the provenance in headers ⚖"),
    pytest.param("nothing for go-docs", "GET /wire/go-docs", 404, "wire-not-recorded",
                 id="a source never read is not an empty answer"),
    pytest.param("go-models-dev at T0", "GET /wire/go-models-dev, no token", 200, "body = the stored bytes, `x-wire-class` = `public`",
                 id="the door asks for no credential ⚖"),
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
    digest = hashlib.sha256(stored).hexdigest()
    if path == "/wire":
        doc = r.json()
        names = sorted(s["source"] for s in doc["sources"])
        src = next(s for s in doc["sources"] if s["source"] == "go-models-dev")
        keysets = [sorted(s) for s in doc["sources"]]
        shape = (all(k == sorted(REQUIRED) for k in keysets) and set(doc) == {"sources"} and src["class"] == "public"
                 and src["sha256"] == digest and src["bytes"] == len(stored) and src["fetched_at"] == iso(T0) and src["age_s"] == 90
                 and src["complete"] is True and src["last_error"] is None and all("body" not in s for s in doc["sources"]))
        attach_json("compared", {"sources": names, "keys_per_source": keysets, "required": sorted(REQUIRED), "body_absent": True})
        answer, want = shape, True
    elif r.status_code == 404:
        answer, want = r.json()["error"]["code"], "wire-not-recorded"
    else:
        got_headers = [h for h in HEADERS if h in r.headers]
        attach_json("compared", {"headers": got_headers, "body_sha256": hashlib.sha256(r.content).hexdigest(), "stored_sha256": digest})
        answer = (r.content == stored and got_headers == HEADERS and r.headers["x-wire-source"] == "go-models-dev"
                  and r.headers["x-wire-class"] == "public" and r.headers["x-wire-sha256"] == digest
                  and r.headers["x-wire-fetched-at"] == iso(T0) and r.headers["x-wire-complete"] == "true")
        want = True
    verdicts(status=(r.status_code, expected_status), answer=(answer, want))
    assert expected_answer
