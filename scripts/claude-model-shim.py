#!/usr/bin/env python3
"""A local model-splitting forward proxy for jail Claude Code sessions.

WHY (2026-08-13, operator direction): Claude Code's billing is process-wide — one
ANTHROPIC_BASE_URL per session — so "fable main loop + OpenCode Go subagents" cannot be
expressed with env vars alone. This shim is the split point: the session's base URL is
http://127.0.0.1:$SHIM_PORT, and each request routes by the MODEL ID in its body:

    opencode-go/<id>   → $SHIM_GO_BASE (default https://opencode.ai/zen/go), the
                         opencode-go/ prefix STRIPPED (their API takes bare ids), the
                         session's own auth REPLACED by $SHIM_GO_KEY (the subscription
                         oauth must never leak to a third party)
    anything else      → $SHIM_ANTHROPIC_BASE (default https://api.anthropic.com),
                         headers passed through VERBATIM (the CLI's oauth + beta headers)

It is also the jail-scale prototype of the multi-subscription rail split the egress proxy
grows under the chainless redesign (model-routing.md §M11; FU-127 structured rail) — the
routing rule here is deliberately the same shape: rail by model-id prefix, credential per
rail, model id translated at the boundary.

Slot mapping happens OUTSIDE this file (scripts/claude-go.sh): the CLI resolves its
haiku/sonnet/opus aliases via ANTHROPIC_DEFAULT_*_MODEL env at LAUNCH, so the body already
carries the mapped id by the time it arrives here. Per-call model choice (Agent tool
`model:` param) then selects among the mapped slots mid-session.

Auth style: Go's docs don't name the header (Bearer vs x-api-key), so both are sent by
default; narrow with SHIM_GO_AUTH_STYLE=bearer|x-api-key once observed.

Run:  python3 scripts/claude-model-shim.py            # serve (foreground)
      python3 scripts/claude-model-shim.py --self-test # offline routing/auth/rewrite test
"""
import json
import os
import sys
import threading
import urllib.parse
from http.client import HTTPConnection, HTTPSConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("SHIM_PORT", "18091"))
GO_BASE = os.environ.get("SHIM_GO_BASE", "https://opencode.ai/zen/go")
ANTHROPIC_BASE = os.environ.get("SHIM_ANTHROPIC_BASE", "https://api.anthropic.com")
# Last-token only: a launcher once passed a key with devbox plugin noise prepended; the
# multi-line header value then crashed every Go leg AND the traceback echoed the key into the
# log. A credential is a single token — never trust the env to be clean.
GO_KEY = (os.environ.get("SHIM_GO_KEY", "").split() or [""])[-1]
GO_AUTH_STYLE = os.environ.get("SHIM_GO_AUTH_STYLE", "both")  # both|bearer|x-api-key
GO_PREFIX = "opencode-go/"
# SHIM_MODEL_REWRITE="old=new,old2=new2" (bare Go ids, applied after the prefix strip): the CLI
# freezes its alias→model map at LAUNCH, so when a slot model turns out broken mid-session
# (glm-5.2 422s every function tool; deepseek-v4-pro region-locks — both found 2026-08-13),
# restarting the shim with a rewrite un-wedges live sessions that a slot-map fix can't reach.
GO_REWRITE = dict(p.split("=", 1) for p in
                  os.environ.get("SHIM_MODEL_REWRITE", "").split(",") if "=" in p)

# End-to-end and hop-by-hop headers we must own rather than forward. Content-Length is
# recomputed (the body may be rewritten); the response side is re-framed connection-close
# (SSE-safe without re-chunking).
_SKIP_REQ = {"host", "content-length", "connection", "keep-alive", "transfer-encoding",
             "proxy-connection", "accept-encoding", "expect"}
_SKIP_RESP = {"content-length", "connection", "keep-alive", "transfer-encoding"}
_AUTH = {"authorization", "x-api-key"}


def _upstream(base: str):
    u = urllib.parse.urlsplit(base)
    conn = (HTTPSConnection if u.scheme == "https" else HTTPConnection)(u.netloc, timeout=600)
    return conn, u.path.rstrip("/")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "claude-model-shim"

    def log_message(self, *_):  # one structured line per request instead (below)
        pass

    def _route(self, body: bytes):
        """(base, body, go_leg) — routing is by the body's model id, nothing else."""
        model = ""
        if body:
            try:
                parsed = json.loads(body)
                model = str(parsed.get("model") or "")
            except (ValueError, AttributeError):
                parsed = None
        if model.startswith(GO_PREFIX):
            bare = model[len(GO_PREFIX):]
            parsed["model"] = GO_REWRITE.get(bare, bare)
            # Go's Anthropic-compat layer mishandles the STRING shorthand for message content on
            # some models (probed 2026-08-13: glm-5.2 dropped the prompt and free-associated,
            # 12 input tokens counted; the array-of-blocks form answered correctly). claude-code
            # always sends blocks, but normalize here so shorthand clients can't hit it.
            for msg in parsed.get("messages") or []:
                if isinstance(msg, dict) and isinstance(msg.get("content"), str):
                    msg["content"] = [{"type": "text", "text": msg["content"]}]
            # Go rejects Anthropic SERVER tools (bisected 2026-08-13: claude-code's WebSearch
            # entry 422s the whole request — `tools.0…WebSearchTool.type`). Client tools are
            # function-shaped (input_schema present / type "custom"); server tools carry a
            # versioned `type` and cannot be served by Go's models anyway — drop only those,
            # so Bash/Edit/MCP tools keep working and the model simply isn't offered WebSearch.
            tools = parsed.get("tools")
            if isinstance(tools, list):
                kept = [t for t in tools if isinstance(t, dict)
                        and (t.get("input_schema") is not None or t.get("type") in (None, "custom"))]
                if len(kept) != len(tools):
                    print(f"shim: go-leg dropped {len(tools) - len(kept)} server tool(s)",
                          file=sys.stderr, flush=True)
                parsed["tools"] = kept
            return GO_BASE, json.dumps(parsed).encode(), True, model
        return ANTHROPIC_BASE, body, False, model

    def _forward(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        base, body, go_leg, model = self._route(body)

        conn, prefix = _upstream(base)
        headers = {}
        for k, v in self.headers.items():
            lk = k.lower()
            if lk in _SKIP_REQ or (go_leg and lk in _AUTH):
                continue
            headers[k] = v
        if go_leg:
            if not GO_KEY:
                self._reply(502, b'{"error":"SHIM_GO_KEY is not set - the Go rail has no credential"}')
                print(f"shim: DENY go-leg (no key) model={model}", file=sys.stderr, flush=True)
                return
            if GO_AUTH_STYLE in ("both", "x-api-key"):
                headers["x-api-key"] = GO_KEY
            if GO_AUTH_STYLE in ("both", "bearer"):
                headers["Authorization"] = f"Bearer {GO_KEY}"
        headers["Connection"] = "close"
        headers["Accept-Encoding"] = "identity"

        path = self.path
        if go_leg:
            # Go's compat endpoint 422s on claude-code's decorations (probed 2026-08-13, empty
            # body): send it a plain Anthropic request — no ?beta=true query, no anthropic-beta
            # feature headers. The Anthropic leg keeps both untouched.
            path = path.split("?", 1)[0]
            headers = {k: v for k, v in headers.items() if k.lower() != "anthropic-beta"}
        if os.environ.get("SHIM_DEBUG_BODY") and go_leg:
            dbg = os.path.join(os.environ.get("TMPDIR", "/tmp"),
                               f"shim-go-body-{threading.get_ident()}-{os.getpid()}.json")
            with open(dbg, "ab") as f:
                f.write(body + b"\n")
            print(f"shim: DEBUG go body -> {dbg} ({len(body)}b)", file=sys.stderr, flush=True)
        try:
            conn.request(self.command, prefix + path, body=body or None, headers=headers)
            resp = conn.getresponse()
        except OSError as e:
            self._reply(502, json.dumps({"error": f"upstream unreachable: {e}"}).encode())
            print(f"shim: 502 {base} model={model} err={e}", file=sys.stderr, flush=True)
            return

        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() not in _SKIP_RESP:
                self.send_header(k, v)
        self.send_header("Connection", "close")
        self.end_headers()
        n = 0
        while True:
            chunk = resp.read(8192)
            if not chunk:
                break
            n += len(chunk)
            self.wfile.write(chunk)
            self.wfile.flush()  # SSE latency: relay each chunk as it lands
        conn.close()
        self.close_connection = True
        rail = "go" if go_leg else "anthropic"
        print(f"shim: {rail} {resp.status} model={model or '-'} path={self.path} bytes={n}",
              file=sys.stderr, flush=True)

    def _reply(self, status: int, body: bytes):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    do_POST = _forward
    do_GET = _forward
    do_DELETE = _forward
    do_PUT = _forward


def serve():
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"shim: listening on 127.0.0.1:{PORT} "
          f"(anthropic={ANTHROPIC_BASE}, go={GO_BASE}, go-key={'set' if GO_KEY else 'ABSENT'}"
          + (f", rewrite={GO_REWRITE}" if GO_REWRITE else "") + ")",
          file=sys.stderr, flush=True)
    srv.serve_forever()


# ── self-test: two stub upstreams, assert routing / auth swap / model rewrite ───────────────────
def self_test() -> int:
    import http.client

    seen = {}

    class Stub(BaseHTTPRequestHandler):
        name = ""
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            seen[self.name] = {"path": self.path,
                              "auth": self.headers.get("Authorization"),
                              "x_api_key": self.headers.get("x-api-key"),
                              "model": json.loads(body).get("model")}
            out = b'data: {"ok":true}\n\ndata: [DONE]\n\n'
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

    def stub(name, port):
        h = type(f"Stub_{name}", (Stub,), {"name": name})
        s = ThreadingHTTPServer(("127.0.0.1", port), h)
        threading.Thread(target=s.serve_forever, daemon=True).start()
        return s

    global GO_BASE, ANTHROPIC_BASE, GO_KEY, PORT
    ANTHROPIC_BASE, GO_BASE, GO_KEY, PORT = \
        "http://127.0.0.1:18191", "http://127.0.0.1:18192/zen/go", "go-test-key", 18190
    stub("anthropic", 18191)
    stub("go", 18192)
    threading.Thread(target=serve, daemon=True).start()
    import time
    time.sleep(0.3)

    def call(model):
        c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
        c.request("POST", "/v1/messages", body=json.dumps({"model": model, "messages": []}),
                  headers={"Content-Type": "application/json",
                           "Authorization": "Bearer OAUTH-SECRET",
                           "anthropic-version": "2023-06-01"})
        r = c.getresponse()
        data = r.read()
        c.close()
        return r.status, data

    fails = []

    def check(cond, msg):
        (fails.append(msg) if not cond else None)
        print(("  ok " if cond else "  FAIL ") + msg)

    st, data = call("claude-haiku-4-5")
    a = seen.get("anthropic") or {}
    check(st == 200 and b"[DONE]" in data, "anthropic leg: 200 + streamed body relayed")
    check(a.get("model") == "claude-haiku-4-5", "anthropic leg: model untouched")
    check(a.get("auth") == "Bearer OAUTH-SECRET", "anthropic leg: oauth passed through verbatim")
    check(a.get("path") == "/v1/messages", "anthropic leg: path preserved")

    st, data = call("opencode-go/kimi-k3")
    g = seen.get("go") or {}
    check(st == 200 and b"[DONE]" in data, "go leg: 200 + streamed body relayed")
    check(g.get("model") == "kimi-k3", "go leg: opencode-go/ prefix stripped")
    check(g.get("auth") == "Bearer go-test-key" and g.get("x_api_key") == "go-test-key",
          "go leg: session auth REPLACED by the Go key (both header styles)")
    check("OAUTH-SECRET" not in json.dumps(g), "go leg: the oauth token never reaches Go")
    check(g.get("path") == "/zen/go/v1/messages", "go leg: base path joined")

    global GO_REWRITE
    GO_REWRITE = {"broken-slot-model": "kimi-k3"}
    st, _ = call("opencode-go/broken-slot-model")
    check(st == 200 and (seen.get("go") or {}).get("model") == "kimi-k3",
          "go leg: SHIM_MODEL_REWRITE remaps a frozen slot id")
    GO_REWRITE = {}

    GO_KEY = ""
    st, _ = call("opencode-go/kimi-k3")
    check(st == 502, "go leg without a key: refused loudly (502), never forwarded")

    print(("self-test: PASS" if not fails else f"self-test: {len(fails)} FAILURES"))
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(self_test() if "--self-test" in sys.argv else serve())
