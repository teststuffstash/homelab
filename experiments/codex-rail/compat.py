"""Run an explicitly selected, version-checked Codex CLI through the REAL gateway, offline.

The native-CLI half of GW-RAIL-CODEX / GW-SESSIONS-ENV (gateway/specs/endpoints/openai-responses.md):
the gateway app (gateway/src/agent_gateway, `policy-codex` world, the FAKE credential store from
gateway/tests/_codex_world.py) is served by uvicorn on 127.0.0.1; a loopback fake Responses
upstream stands in for the ChatGPT backend. The CLI asks nothing of the operator's config: a fresh
CODEX_HOME holds only the provider block RENDERED FROM THE DISPATCH ANSWER's env (the wrapper's
job, GW-SESSIONS-ENV ⚖), and the child env carries PATH, CODEX_HOME, the session token as
OPENAI_API_KEY and closed loopback proxies (defence in depth, not a network namespace).

Dummy credentials only; no OAuth exchange, real model, shell tool call or external upstream.
Never run an untrusted CLI binary here. Only an allowlisted evidence summary is printed. Run from
the gateway island so its locked environment is used:

    cd gateway && uv run --frozen python ../experiments/codex-rail/compat.py \\
        --codex /path/to/codex --expect-version 0.161.0 [--probe-bare-env]
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

GATEWAY = Path(__file__).resolve().parents[2] / "gateway"
sys.path.insert(0, str(GATEWAY))  # tests._codex_world: the FAKE store, the fixture stream

import httpx  # noqa: E402
import uvicorn  # noqa: E402

from agent_gateway.app import create_app  # noqa: E402
from agent_gateway.codex import CodexBackend  # noqa: E402
from agent_gateway.config import Policy, Settings  # noqa: E402
from agent_gateway.credentials import StaticSecrets  # noqa: E402
from agent_gateway.store import Store  # noqa: E402
import tests.conftest  # noqa: E402,F401 — first: _codex_world and conftest import each other
from tests._codex_world import ACCOUNT, CODEX_POLICY, TEXT, Exchange, MemoryStore, completion, creds  # noqa: E402

PROMPT = "Return the fixture response."


class _Now:
    """`creds()` reads `.t` — the wall clock at fixture start."""

    def __init__(self):
        self.t = time.time()


@contextmanager
def fake_upstream(rotated_access: str, request_observer=None, response_factory=None):
    seen = {"requests": 0, "auth_ok": [], "shape": []}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            doc = json.loads(body) if body else {}
            if request_observer is not None:
                request_observer(doc, dict(self.headers))
            seen["requests"] += 1
            seen["auth_ok"].append(self.path == "/responses"
                                   and self.headers.get("Authorization") == "Bearer " + rotated_access
                                   and self.headers.get("ChatGPT-Account-ID") == ACCOUNT
                                   and self.headers.get("Cookie") is None)
            seen["shape"].append({"model": doc.get("model"), "stream": doc.get("stream"), "store": doc.get("store"),
                                  "input_is_array": isinstance(doc.get("input"), list)})
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            # A hostile redirect hint must never be followed (the gateway never follows redirects).
            self.send_header("Location", "http://127.0.0.1:1/never-follow")
            extra, chunks = response_factory(seen["requests"]) if response_factory else ({}, completion())
            for key, value in extra.items():
                self.send_header(key, value)
            self.end_headers()
            for chunk in chunks:
                self.wfile.write(chunk)
                self.wfile.flush()

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}", seen
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@contextmanager
def gateway(upstream: str, tmp: Path):
    clock = time.time
    old, new = creds(_Now())
    mstore = MemoryStore(old)
    exchange = Exchange(mstore, new)
    port = _free_port()
    settings = Settings.from_env({"GATEWAY_POLICY": str(CODEX_POLICY), "GATEWAY_DB": str(tmp / "gateway.db"),
                                  "GATEWAY_SELF_URL": f"http://127.0.0.1:{port}", "CODEX_UPSTREAM": upstream})
    client = httpx.AsyncClient(trust_env=False, follow_redirects=False, timeout=httpx.Timeout(30, connect=5))
    app = create_app(settings, policy=Policy.load(CODEX_POLICY), source=StaticSecrets(), store=Store(settings.db_path),
                     client=client, clock=clock, codex_backend=CodexBackend(mstore, exchange))
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning", lifespan="on"))
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    deadline = time.time() + 10
    while not server.started:
        if time.time() > deadline:
            raise RuntimeError("gateway did not start")
        time.sleep(0.05)
    try:
        yield app, f"http://127.0.0.1:{port}", exchange, new.access_token
    finally:
        server.should_exit = True
        thread.join(10)


def _child_env(codex_home: Path, token: str, extra: dict | None = None) -> dict:
    return {"PATH": os.environ["PATH"], "CODEX_HOME": str(codex_home), "OPENAI_API_KEY": token,
            "NO_PROXY": "127.0.0.1,localhost", "HTTP_PROXY": "http://127.0.0.1:1",
            "HTTPS_PROXY": "http://127.0.0.1:1", **(extra or {})}


def _provider_block(env: dict) -> str:
    """The wrapper's rendering of the dispatch env (GW-SESSIONS-ENV ⚖): base_url and model from env
    VALUES, the token read by the CLI through env_key."""
    return f'''model = "{env['CODEX_MODEL']}"
model_provider = "agent-gateway"
cli_auth_credentials_store = "file"
[model_providers.agent-gateway]
name = "agent-gateway"
base_url = "{env['OPENAI_BASE_URL']}"
wire_api = "responses"
env_key = "OPENAI_API_KEY"
requires_openai_auth = false
supports_websockets = false
request_max_retries = 0
stream_max_retries = 0
'''


def _exec(executable: str, env: dict, work: Path, timeout: float):
    return subprocess.run([executable, "exec", "--json", "--ephemeral", "--skip-git-repo-check",
                           "--sandbox", "read-only", "-C", str(work), PROMPT],
                          env=env, cwd=work, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)


def run(binary: str, expected_version: str, probe_bare_env: bool = False, request_observer=None,
        response_factory=None) -> dict:
    executable = shutil.which(binary)
    if executable is None:
        raise RuntimeError("codex executable not found")
    version = subprocess.check_output([executable, "--version"], text=True, timeout=10).strip()
    if version != "codex-cli " + expected_version:
        raise RuntimeError("CLI version differs from --expect-version; select the intended binary explicitly")
    evidence: dict = {"cli_version": version, "live_subscription_verified": False}
    with tempfile.TemporaryDirectory(prefix="codex-gw-compat-") as tmpdir:
        tmp = Path(tmpdir)
        with fake_upstream(creds(_Now())[1].access_token, request_observer, response_factory) as (upstream, seen), gateway(upstream, tmp) as (app, url, exchange, _):
            now = time.time()
            app.state.codex.headroom.observe({"observed_at": now - 1, "source": "poll", "limited": False, "windows": [
                {"used_percent": 20, "resets_at": now + 3600, "window_minutes": 300},
                {"used_percent": 64, "resets_at": now + 86400, "window_minutes": 10080}]})
            with httpx.Client(base_url=url, trust_env=False) as gw:
                doc = gw.post("/sessions", json={"stack": "platform", "role": "prober", "task": "codex-compat",
                                                 "harness": "codex"}).json()
                if doc.get("decision") != "dispatch" or doc.get("rail") != "codex":
                    raise RuntimeError(f"admission did not dispatch on codex: {doc.get('decision')} {doc.get('reason')}")
                env = doc["env"]
                evidence["dispatch_env_keys"] = sorted(env)
                work = tmp / "work"
                work.mkdir()
                if probe_bare_env:
                    # GW-SESSIONS-ENV ⚖: the bare vars with NO provider block — does the CLI reach the gateway?
                    bare = tmp / "bare"
                    bare.mkdir()
                    (bare / "config.toml").write_text(f'model = "{env["CODEX_MODEL"]}"\n')
                    before = seen["requests"]
                    try:
                        _exec(executable, _child_env(bare, env["OPENAI_API_KEY"], {"OPENAI_BASE_URL": env["OPENAI_BASE_URL"]}), work, 20)
                    except subprocess.TimeoutExpired:
                        pass
                    rows = app.state.store.get_session(doc["session"]["id"]).requests
                    evidence["bare_env_reached_gateway"] = bool(rows or seen["requests"] != before)
                home = tmp / "codex-home"
                home.mkdir()
                (home / "config.toml").write_text(_provider_block(env))
                result = _exec(executable, _child_env(home, env["OPENAI_API_KEY"]), work, 60)
                row = app.state.store.get_session(doc["session"]["id"])
                gw.delete(f"/sessions/{doc['session']['id']}")
            # Never print process logs or captured bodies: the evidence is allowlisted.
            records = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
            evidence.update({
                "exit": result.returncode,
                "turn_completed": any(r.get("type") == "turn.completed" for r in records),
                "synthetic_text_seen": TEXT in result.stdout,
                "auth_json_written": (home / "auth.json").exists(),
                "upstream_requests": seen["requests"],
                "upstream_auth_replaced": all(seen["auth_ok"]) and bool(seen["auth_ok"]),
                "upstream_shape": seen["shape"],
                "oauth_exchanges": exchange.calls,
                "session_row": {"requests": row.requests, "tokens_in": row.tokens_in,
                                "tokens_cache_read": row.tokens_cache_read, "tokens_out": row.tokens_out},
            })
    ok = (evidence["exit"] == 0 and evidence["turn_completed"] and evidence["synthetic_text_seen"]
          and not evidence["auth_json_written"] and evidence["upstream_requests"] >= 1
          and evidence["upstream_auth_replaced"] and evidence["oauth_exchanges"] == 1
          and evidence["session_row"]["requests"] == evidence["upstream_requests"]
          and not evidence.get("bare_env_reached_gateway", False))
    evidence["passed"] = ok
    if not ok:
        raise RuntimeError("compat fixture failed: " + json.dumps(evidence))
    return evidence


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--codex", default="codex")
    parser.add_argument("--expect-version", required=True)
    parser.add_argument("--probe-bare-env", action="store_true",
                        help="first check that bare OPENAI_BASE_URL/OPENAI_API_KEY without a provider block do NOT reach the gateway")
    args = parser.parse_args()
    print(json.dumps(run(args.codex, args.expect_version, args.probe_bare_env), indent=2))
