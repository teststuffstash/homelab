"""Recorded worlds: the strict reader and the recorder (unlabelled — proves no requirement row)."""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from retro_island import record, worlds

ENTRIES = sorted(p.stem for p in (worlds.WORLDS / "prom-instant").glob("*.json"))


def _valid() -> dict:
    return json.loads((worlds.WORLDS / "prom-instant" / "1.json").read_text())


def test_the_five_entries_are_committed():
    assert ENTRIES == ["0", "1", "absent", "down", "error"]


@pytest.mark.parametrize("name", ENTRIES)
def test_committed_entry_loads(name):
    e = worlds.load("prom-instant", name)
    assert e.surface == "prometheus" and e.request.path == "/api/v1/query"
    assert (e.status is None) == (e.body is None) == (name == "down")


def test_field_removed_raises():
    d = _valid()
    del d["recorded_by"]
    with pytest.raises(worlds.EntryError, match="missing"):
        worlds.parse(json.dumps(d))


def test_field_added_raises():
    d = _valid()
    d["extra"] = 1
    with pytest.raises(worlds.EntryError, match="unknown"):
        worlds.parse(json.dumps(d))


def test_null_status_beside_body_raises():
    d = _valid()
    d["status"] = None
    with pytest.raises(worlds.EntryError):
        worlds.parse(json.dumps(d))


def test_wrong_type_raises():
    d = _valid()
    d["status"] = "200"
    with pytest.raises(worlds.EntryError):
        worlds.parse(json.dumps(d))


@pytest.mark.parametrize("status", [200, 400])
def test_recorder_writes_an_entry_the_reader_loads(tmp_path, status):
    served = b'{"status":"x","q":"\xc3\xa5"}'

    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(status)
            self.end_headers()
            self.wfile.write(served)

        def log_message(self, *a):
            pass

    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    out = tmp_path / "e.json"
    try:
        rc = record.main(["--base-url", f"http://127.0.0.1:{srv.server_port}", "--query", "max(", "--out", str(out), "--recorded-by", "test"])
    finally:
        srv.shutdown()
    assert rc == 0
    e = worlds.load_path(out)
    assert e.status == status and e.body == served.decode() and e.request.query == {"query": "max("}


def test_transport_failure_writes_nothing(tmp_path):
    out = tmp_path / "e.json"
    rc = record.main(["--base-url", "http://127.0.0.1:1", "--query", "q", "--out", str(out), "--recorded-by", "t"])
    assert rc != 0 and not out.exists()
