"""GW-WIRE-QUARRY — scripts/wire-quarry.py reads the wire door and cuts a fixture (specs/endpoints/wire.md §GW-WIRE-QUARRY).

World: policy-codex · the door holding `go-models-dev` (the `catalog-ok` bytes, T0). The door is the real
gateway's `/wire` answers (recorded through the fake vendor), served over a loopback socket by a stdlib
thread so the tool runs as a subprocess, exactly as a worker pod runs it. The tables are the spec's,
verbatim; the header is the parameter list.
"""

from __future__ import annotations

import hashlib
import json
import socket
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest
from starlette.responses import JSONResponse

from ._catalog_rows import T0, iso
from ._catalog_world import catalog_doc, gw_client
from ._codex_rows import row, verdicts
from .conftest import attach_json, given, quiet, rule, when, world

pytestmark = rule("GW-WIRE-QUARRY")

TOOL = Path(__file__).resolve().parents[1] / "scripts" / "wire-quarry.py"
MODEL = "opencode-go.models.deepseek-v4-pro"


class Door:
    """The `/wire` answers of one gateway, snapshotted and served from a loopback port."""

    def __init__(self, routes: dict[str, tuple[int, dict[str, str], bytes]]):
        routes_ = routes

        class H(BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802
                status, headers, body = routes_.get(self.path, (404, {}, b'{"error":{"code":"wire-not-recorded"}}'))
                self.send_response(status)
                for k, v in headers.items():
                    self.send_header(k, v)
                self.send_header("content-length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


async def snapshot(app) -> dict[str, tuple[int, dict[str, str], bytes]]:
    routes = {}
    async with gw_client(app) as c:
        with quiet():
            idx = await c.get("/wire")
            routes["/wire"] = (idx.status_code, {"content-type": "application/json"}, idx.content)
            for s in idx.json()["sources"]:
                r = await c.get("/wire/" + s["source"])
                routes["/wire/" + s["source"]] = (r.status_code, dict(r.headers), r.content)
    return routes


def silent_url() -> str:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return f"http://127.0.0.1:{port}"


def quarry(url: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-I", str(TOOL), *args], capture_output=True, env={"WIRE_DOOR_URL": url},
                          timeout=60, check=False)


def stored_bytes() -> bytes:
    return JSONResponse(catalog_doc("catalog-ok")).body


async def run_door(cworld, vendor, clock, door_state: str, call: str, tmp_path: Path, *, max_bytes: int = 1048576):
    """Record the world's door, then run the tool against it; returns (result, door url, the digest)."""
    app = cworld.build()
    app.state.wire.max_bytes = max_bytes
    clock.t = T0
    with given(f"door = {door_state}"):
        if door_state.startswith("go-models-dev"):
            with quiet():
                await app.state.catalog.refresh_source("config")
    clock.t = T0 + 90
    routes = {} if door_state == "unreachable" else await snapshot(app)
    door = Door(routes)
    url = silent_url() if door_state == "unreachable" else door.url
    argv = [a.replace("<dir>", str(tmp_path)) for a in call.split()]
    with when(f"wire-quarry.py {call}"):
        res = quarry(url, *argv)
    door.close()
    attach_json("the tool's exit and streams", {"exit": res.returncode, "stdout_bytes": len(res.stdout), "stderr": res.stderr.decode()})
    return res, url


READ_ROWS = [
    pytest.param("go-models-dev at T0", "show go-models-dev", 0, "the stored bytes, byte-identical",
                 "`wire: source=go-models-dev class=public sha256=<…> fetched_at=T0`",
                 id="`show` prints one member verbatim and one provenance line"),
    pytest.param("go-models-dev at T0", "list", 0, "one line per source: name, class, status, age", "—",
                 id="`list` prints the index"),
    pytest.param("go-models-dev at T0", "find --key cost", 0, "`go-models-dev` and each JSON path ending in `cost`", "—",
                 id="`find` names the sources that have a key, with its path ⚖"),
    pytest.param("go-models-dev at T0", "show codex-models", 4, "nothing", "`wire: codex-models not recorded`",
                 id="a source nobody recorded is an error, never an empty answer"),
    pytest.param("go-models-dev at T0", "find --key nothing-has-this", 0, "nothing", "—",
                 id="a key no source has is an empty answer, not an error"),
    pytest.param("nothing recorded", "list", 0, "nothing", "—",
                 id="a door with no record lists nothing"),
    pytest.param("unreachable", "show go-models-dev", 3, "nothing", "`wire: door unreachable: <url>`",
                 id="a silent door is an error that names the door ⚖"),
]


@pytest.mark.parametrize(("door", "command", "expected_exit", "expected_stdout", "expected_stderr"), READ_ROWS,
                         ids=[p.id for p in READ_ROWS])
async def test_reading_the_door(cworld, vendor, clock, tmp_path, door, command, expected_exit, expected_stdout, expected_stderr):
    world("policy-codex", upstream=door)
    row(door=door, command=command)
    res, url = await run_door(cworld, vendor, clock, door, command, tmp_path)
    digest = hashlib.sha256(stored_bytes()).hexdigest()
    out, err = res.stdout, res.stderr.decode().strip()
    if door == "unreachable":
        stdout = "nothing" if not out else f"MISMATCH {out!r}"
        stderr = "`wire: door unreachable: <url>`" if err == f"wire: door unreachable: {url}" else f"MISMATCH {err}"
    elif command.startswith("show go-models-dev"):
        stdout = "the stored bytes, byte-identical" if out == stored_bytes() else f"MISMATCH {len(out)} bytes"
        stderr = ("`wire: source=go-models-dev class=public sha256=<…> fetched_at=T0`"
                  if err == f"wire: source=go-models-dev class=public sha256={digest} fetched_at={iso(T0)}" else f"MISMATCH {err}")
    elif command == "list" and door == "nothing recorded":
        stdout = "nothing" if not out else f"MISMATCH {out!r}"
        stderr = "—" if not err else err
    elif command == "find --key nothing-has-this":
        stdout = "nothing" if not out else f"MISMATCH {out!r}"
        stderr = "—" if not err else err
    elif command == "list":
        lines = out.decode().splitlines()
        names = [ln.split("\t")[0] for ln in lines]
        ok = (all(len(ln.split("\t")) == 4 for ln in lines) and len(set(names)) == len(names)
              and "go-models-dev\tpublic\t200\t90s" in lines)
        stdout = "one line per source: name, class, status, age" if ok else f"MISMATCH {lines}"
        stderr = "—" if not err else err
    elif command.startswith("find"):
        lines = out.decode().splitlines()
        paths = [ln.split("\t")[1] for ln in lines if ln.split("\t")[0] == "go-models-dev"]
        ok = bool(paths) and all(p.rsplit(".", 1)[-1] == "cost" for p in paths) and f"{MODEL}.cost" in paths
        stdout = "`go-models-dev` and each JSON path ending in `cost`" if ok else f"MISMATCH {lines}"
        stderr = "—" if not err else err
    elif command == "show codex-models":
        stdout = "nothing" if not out else f"MISMATCH {out!r}"
        stderr = "`wire: codex-models not recorded`" if err == "wire: codex-models not recorded" else f"MISMATCH {err}"
    else:
        raise AssertionError(f"no verdict for row {command!r}")
    verdicts(exit=(res.returncode, expected_exit), stdout=(stdout, expected_stdout), stderr=(stderr, expected_stderr))


CUT_ROWS = [
    pytest.param("go-models-dev at T0", f"cut go-models-dev --path {MODEL} --out <dir>/m.json", 0,
                 "that subtree, values and key order as recorded",
                 "`<dir>/m.provenance.json`: source, class, url, sha256 of the whole answer, fetched_at, path",
                 id="`cut` writes the fragment's values unchanged and a sidecar ⚖"),
    pytest.param("go-models-dev at T0", "cut go-models-dev --path opencode-go.models.nope --out <dir>/m.json", 5, "no file", "no file",
                 id="a path the answer does not have writes nothing"),
    pytest.param("go-models-dev, complete: false", "cut go-models-dev --path opencode-go --out <dir>/m.json", 6, "no file", "no file",
                 id="a truncated record is never cut"),
    pytest.param("unreachable", "cut go-models-dev --path opencode-go --out <dir>/m.json", 3, "no file", "no file",
                 id="a silent door writes nothing"),
]


@pytest.mark.parametrize(("door", "command", "expected_exit", "expected_fixture", "expected_sidecar"), CUT_ROWS,
                         ids=[p.id for p in CUT_ROWS])
async def test_cutting_a_fixture(cworld, vendor, clock, tmp_path, door, command, expected_exit, expected_fixture, expected_sidecar):
    world("policy-codex", upstream=door)
    row(door=door, command=command)
    truncated = "complete: false" in door
    state = "unreachable" if door == "unreachable" else "go-models-dev"
    res, url = await run_door(cworld, vendor, clock, state, command, tmp_path, max_bytes=600 if truncated else 1048576)
    fixture, sidecar = tmp_path / "m.json", tmp_path / "m.provenance.json"
    if expected_exit == 0:
        want = catalog_doc("catalog-ok")["opencode-go"]["models"]["deepseek-v4-pro"]
        got = json.loads(fixture.read_text(encoding="utf-8")) if fixture.exists() else None
        fx = ("that subtree, values and key order as recorded"
              if got == want and list(got) == list(want) else f"MISMATCH {got!r}")
        prov = json.loads(sidecar.read_text(encoding="utf-8")) if sidecar.exists() else {}
        digest = hashlib.sha256(stored_bytes()).hexdigest()
        ok = (set(prov) == {"source", "class", "url", "sha256", "fetched_at", "path"} and prov["source"] == "go-models-dev"
              and prov["class"] == "public" and prov["sha256"] == digest and prov["fetched_at"] == iso(T0)
              and prov["path"] == MODEL and prov["url"].startswith("http"))
        sc = ("`<dir>/m.provenance.json`: source, class, url, sha256 of the whole answer, fetched_at, path"
              if ok else f"MISMATCH {prov}")
    else:
        fx = "no file" if not fixture.exists() else "MISMATCH a fixture was written"
        sc = "no file" if not sidecar.exists() else "MISMATCH a sidecar was written"
    verdicts(exit=(res.returncode, expected_exit), fixture=(fx, expected_fixture), sidecar=(sc, expected_sidecar))
    assert url
