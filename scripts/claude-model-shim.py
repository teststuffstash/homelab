#!/usr/bin/env python3
"""A local model-splitting forward proxy for jail Claude Code sessions.

WHY (2026-08-13, operator direction): Claude Code's billing is process-wide — one
ANTHROPIC_BASE_URL per session — so "fable main loop + OpenCode Go subagents" cannot be
expressed with env vars alone. This shim is the split point: the session's base URL is
http://127.0.0.1:$SHIM_PORT, and each request routes by the MODEL ID in its body:

    opencode-go/<id>   → $SHIM_GO_BASE (default https://opencode.ai/zen/go), the Go
                         subscription rail — opencode-go/ prefix STRIPPED (their API takes
                         bare ids), the session's own auth REPLACED by $SHIM_GO_KEY (the
                         subscription oauth must never leak to a third party)
    opencode/<id>      → $SHIM_ZEN_BASE (default https://opencode.ai/zen), the OpenCode
                         Zen free tier as the jail's THIRD rail (issue #444) — opencode/
                         prefix STRIPPED, same $SHIM_GO_KEY + auth-style + compat scrub as
                         the Go leg, metered $0 (assumption sentinel: non-'-free' ids warn)
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

ADR-108 (homelab#438): This shim also meters its own opencode-rail usage and pushes rows to
the ingest listener at $SHIM_INGEST_URL (default http://192.168.40.30:8081/go-usage-report).
Go legs are priced via gometer; Zen legs meter $0 by operator direction (issue #444).
Token-gated: requires $SHIM_INGEST_TOKEN. On push failure OR unset token: rows spill to
~/.claude/homelab-go-usage-spool.jsonl; successful pushes opportunistically drain the spool.
Metering is fire-and-forget (daemon thread) and NEVER raises into the proxy path.

Run:  python3 scripts/claude-model-shim.py            # serve (foreground)
      python3 scripts/claude-model-shim.py --self-test # offline routing/auth/rewrite test
"""
import json
import os
import sys
import threading
import urllib.parse
import urllib.request
from http.client import HTTPConnection, HTTPSConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ADR-108: import gometer from the proxy (sys.path insert so the shim can use it).
# The shim imports it from the repo checkout at argocd/resources/openrouter-proxy/ —
# the single home. Wrapped in try/except so metering failure never breaks the jail.
_gometer = None
try:
    _SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
    _PROXY_DIR = os.path.join(os.path.dirname(_SCRIPT_DIR), "argocd", "resources", "openrouter-proxy")
    sys.path.insert(0, _PROXY_DIR)
    import gometer
    _gometer = gometer
except Exception as e:
    print(f"shim: gometer import failed ({e}) — metering disabled, proxy untouched",
          file=sys.stderr, flush=True)

PORT = int(os.environ.get("SHIM_PORT", "18091"))
GO_BASE = os.environ.get("SHIM_GO_BASE", "https://opencode.ai/zen/go")
ZEN_BASE = os.environ.get("SHIM_ZEN_BASE", "https://opencode.ai/zen")
ANTHROPIC_BASE = os.environ.get("SHIM_ANTHROPIC_BASE", "https://api.anthropic.com")
# Last-token only: a launcher once passed a key with devbox plugin noise prepended; the
# multi-line header value then crashed every Go leg AND the traceback echoed the key into the
# log. A credential is a single token — never trust the env to be clean.
GO_KEY = (os.environ.get("SHIM_GO_KEY", "").split() or [""])[-1]
# Both opencode rails (go + zen) share this one credential — same wallet key (issue #444).
GO_AUTH_STYLE = os.environ.get("SHIM_GO_AUTH_STYLE", "both")  # both|bearer|x-api-key
GO_PREFIX = "opencode-go/"
ZEN_PREFIX = "opencode/"
# SHIM_MODEL_REWRITE="old=new,old2=new2" (bare ids on BOTH opencode rails, applied after the
# prefix strip): the CLI freezes its alias→model map at LAUNCH, so when a slot model turns out
# broken mid-session (glm-5.2 422s every function tool; deepseek-* 403'd pre-opt-in — both
# found 2026-08-13), restarting the shim with a rewrite un-wedges live sessions that a slot-map
# fix can't reach.
GO_REWRITE = {k.strip(): v.strip() for k, v in
              (p.split("=", 1) for p in
               os.environ.get("SHIM_MODEL_REWRITE", "").split(",") if "=" in p)}

# ── #448: the OpenAI-surface translator leg (LiteLLM) ──────────────────────────
# Some opencode models are unreachable from their Anthropic-compat surface — the zen
# surface DROPS tool-bearing bodies (400 "Input required"), and opencode-go/gpt-5.6-luna
# 400s even on plain text — but tool-call cleanly on their OpenAI /chat/completions
# surface (docs/spikes/opencode-model-matrix.md, 2026-08-17). Those legs are served
# through LiteLLM's Anthropic-format unified call (litellm.anthropic.messages.create):
# Anthropic-shaped params in, Anthropic-shaped response/SSE out, translation internal.
# LiteLLM is imported LAZILY from a pip-venv OUTSIDE the repo (the jail pip-venv
# pattern); when it is missing the affected legs fail LOUDLY with 501 naming the venv —
# never a silent fallback to the broken compat surface, never a crash on the other rails.
# The venv is created once:  python3 -m venv <LITELLM_VENV> && <LITELLM_VENV>/bin/pip install litellm
LITELLM_VENV = os.environ.get("SHIM_LITELLM_VENV", os.path.expanduser("~/.claude/venvs/litellm"))
# The opencode-go ids whose Anthropic-compat surface is broken (probed 2026-08-17) and
# MUST take the translator. The verified trio + flash keep the existing compat path.
# Env-extendable (PR#465 review): SHIM_GO_OPENAI_ONLY adds comma-separated bare ids so the
# NEXT broken model is a live-session env change, not a code edit — the SHIM_MODEL_REWRITE
# pattern. Merged in, never replacing (the probed baseline must not be un-settable by env).
GO_OPENAI_ONLY = {"gpt-5.6-luna"} | {
    m.strip() for m in os.environ.get("SHIM_GO_OPENAI_ONLY", "").split(",") if m.strip()}
_litellm = None  # lazy cache for _litellm_import()


def _litellm_import():
    """#448: lazily import litellm (from the dedicated venv if not on system python).

    Returns the litellm module, or None if unavailable. Never raises — a missing or
    broken litellm degrades ONLY the translator legs (the caller 501s them).
    Sets litellm's global routing flags once: opencode's OpenAI surface is a plain
    /chat/completions server, so force litellm away from its openai-provider default
    (the Responses API) and drop params the models reject (thinking->reasoning_effort)
    instead of erroring the whole request.
    """
    global _litellm
    if _litellm is not None:
        return _litellm
    litellm = None
    try:
        litellm = __import__("litellm")
    except Exception:
        litellm = None
    if litellm is None:
        # Not on the system python — try the dedicated venv's site-packages.
        site = os.path.join(LITELLM_VENV, "lib",
                            f"python{sys.version_info.major}.{sys.version_info.minor}",
                            "site-packages")
        if os.path.isdir(site):
            sys.path.insert(0, site)
            try:
                litellm = __import__("litellm")
            except Exception:
                litellm = None
    if litellm is not None:
        litellm.use_chat_completions_url_for_anthropic_messages = True
        litellm.drop_params = True
    _litellm = litellm
    return litellm


def _rail_and_translate(model: str, resolved: str) -> tuple:
    """#448: (rail, translate) — which rail a model id rides and whether it takes the
    OpenAI-surface translator. translate is True for EVERY zen id (the compat surface is
    broken for tools everywhere there) and for opencode-go ids in GO_OPENAI_ONLY.
    `resolved` is the bare id AFTER the rewrite (the model actually served upstream), so
    a frozen slot rewritten AWAY from a broken id keeps the compat path, and a rewrite
    ONTO a broken id still takes the translator.
    """
    if model.startswith(GO_PREFIX):
        return "go", resolved in GO_OPENAI_ONLY
    if model.startswith(ZEN_PREFIX):
        return "zen", True
    return "anthropic", False


def _translator_target(rail: str, model: str) -> tuple:
    """#448: (api_base, openai_model) for the OpenAI-surface translator.

    api_base is the opencode OpenAI surface (the compat base + /v1 — litellm appends
    /chat/completions); openai_model is the `openai/<bare>` id litellm strips the
    provider prefix from before sending, so upstream sees the RESOLVED bare id.
    """
    base = (GO_BASE if rail == "go" else ZEN_BASE).rstrip("/")
    prefix = GO_PREFIX if rail == "go" else ZEN_PREFIX
    return f"{base}/v1", f"openai/{model[len(prefix):]}"

# ADR-108: self-metering config — ingest VIP + token; spool for failure fallback.
INGEST_URL = os.environ.get("SHIM_INGEST_URL", "http://192.168.40.30:8081/go-usage-report")
INGEST_TOKEN = os.environ.get("SHIM_INGEST_TOKEN")  # unset -> spool-only
SPOOL_FILE = os.path.expanduser("~/.claude/homelab-go-usage-spool.jsonl")

# End-to-end and hop-by-hop headers we must own rather than forward. Content-Length is
# recomputed (the body may be rewritten); the response side is re-framed connection-close
# (SSE-safe without re-chunking).
_SKIP_REQ = {"host", "content-length", "connection", "keep-alive", "transfer-encoding",
             "proxy-connection", "accept-encoding", "expect"}
_SKIP_RESP = {"content-length", "connection", "keep-alive", "transfer-encoding"}
_AUTH = {"authorization", "x-api-key"}

# ADR-108: spool helpers — write on push failure, drain on success.
# One lock over BOTH spool operations: append during a drain's read-then-rewrite would be
# silently wiped otherwise (bot review, PR#442). Held across the drain's pushes deliberately —
# they are 1s-timeout and the only contender is another daemon metering thread; brief blocking
# beats a lost row.
_SPOOL_LOCK = threading.Lock()


def _spool_append(row: dict) -> None:
    """Append one JSON line to the spool file (mkdir -p, tolerate failures)."""
    try:
        with _SPOOL_LOCK:
            os.makedirs(os.path.dirname(SPOOL_FILE), exist_ok=True)
            with open(SPOOL_FILE, "a") as f:
                f.write(json.dumps(row) + "\n")
    except Exception as e:
        print(f"shim: spool append failed: {e}", file=sys.stderr, flush=True)

def _spool_drain() -> None:
    """Opportunistically push spooled rows; keep survivors on failure."""
    with _SPOOL_LOCK:
        if not os.path.exists(SPOOL_FILE):
            return
        survivors = []
        try:
            with open(SPOOL_FILE, "r") as f:
                lines = f.readlines()
            for line in lines:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue  # skip corrupt line
                if _push_usage(row):  # success
                    continue
                survivors.append(line)  # keep for next time
        except Exception as e:
            print(f"shim: spool drain failed: {e}", file=sys.stderr, flush=True)
            return
        # Rewrite with survivors
        try:
            with open(SPOOL_FILE, "w") as f:
                for line in survivors:
                    f.write(line + "\n")
            if not survivors:
                os.remove(SPOOL_FILE)  # clean up empty file
        except Exception as e:
            print(f"shim: spool rewrite failed: {e}", file=sys.stderr, flush=True)

def _push_usage(row: dict) -> bool:
    """POST one row to the ingest endpoint. Returns True on success, False on failure."""
    if not INGEST_TOKEN:
        return False  # token unset -> spool-only
    try:
        data = json.dumps(row).encode()
        req = urllib.request.Request(
            INGEST_URL, data=data, method="POST",
            headers={"Content-Type": "application/json",
                     "X-Ingest-Token": INGEST_TOKEN,
                     "User-Agent": "claude-model-shim/1.0"}
        )
        with urllib.request.urlopen(req, timeout=1) as resp:
            if 200 <= resp.status < 300:
                return True
    except Exception:
        pass  # any failure -> spool
    return False

def _meter_usage(model: str, rail: str, head: bytes, tail: bytes) -> None:
    """ADR-108: extract opencode-leg usage and push to ingest (daemon thread, never block response).

    On push failure OR unset token: append to spool file.
    On successful push: opportunistically drain spool.
    Wrapped in try/except — metering MUST NOT raise into the proxy path.
    Short-circuits if gometer import failed (None) — proxy untouched.
    """
    if _gometer is None:
        return  # gometer import failed — proxy must not be affected
    try:
        merged = _gometer.extract_usage(head, tail)
        if not (merged.get("input_tokens") or merged.get("output_tokens")):
            return  # no usage to report
        prefix = GO_PREFIX if rail == "go" else ZEN_PREFIX
        bare_model = model.removeprefix(prefix).split(":")[0]
        if rail == "go":
            usd, warning = _gometer.price(bare_model, merged)
            if warning:
                print(f"shim: METER {warning}", file=sys.stderr, flush=True)
            # The subscription window draws at LIST price on raw tokens, badge-halved —
            # window_draw(), NOT the cache-discounted price() (2026-08-17 reconciliation).
            draw = _gometer.window_draw(bare_model, merged)
        else:
            # Zen rail (issue #444): every opencode/ call is assumed FREE-tier by operator
            # direction, so the row is metered $0 — deliberately NOT gometer.price, which would
            # fall to the most-expensive fallback for these never-priced free ids. The bare id
            # is expected to end in "-free" (or be big-pickle); anything else warns — the
            # assumption sentinel, never a block.
            usd = 0.0
            draw = 0.0  # the zen free rail never draws against the Go subscription window
            if not (bare_model.endswith("-free") or bare_model == "big-pickle"):
                print(f"shim: METER zen-rail assumption sentinel — {bare_model!r} not '-free'/big-pickle, metered $0",
                      file=sys.stderr, flush=True)
        row = {"ts": __import__("time").time(), "stack": "jail", "model": bare_model,
               "usd": usd, "usd_draw": draw,
               "tokens_in": merged.get("input_tokens", 0),
               "tokens_out": merged.get("output_tokens", 0)}
        if _push_usage(row):
            # Success — drain spool opportunistically
            threading.Thread(target=_spool_drain, daemon=True).start()
        else:
            # Push failed or token unset -> spool
            _spool_append(row)
    except Exception as e:
        print(f"shim: metering failed: {e}", file=sys.stderr, flush=True)
        # Never raise — best-effort metering


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
        """(base, body, rail, model, translate) — routing is by the body's model id.

        rail is "go" | "zen" | "anthropic"; translate is the #448 OpenAI-surface
        translator flag. The two opencode prefixes (opencode-go/, opencode/) are disjoint
        strings — the longer is matched FIRST anyway, so a future prefix that IS a strict
        prefix of another still resolves to the right rail.
        """
        model = ""
        if body:
            try:
                parsed = json.loads(body)
                model = str(parsed.get("model") or "")
            except (ValueError, AttributeError):
                parsed = None
        if model.startswith(GO_PREFIX):
            prefix, base, rail = GO_PREFIX, GO_BASE, "go"
        elif model.startswith(ZEN_PREFIX):
            prefix, base, rail = ZEN_PREFIX, ZEN_BASE, "zen"
        else:
            return ANTHROPIC_BASE, body, "anthropic", model, False
        bare = model[len(prefix):]
        # The RESOLVED id is what upstream serves and bills — return it (not the inbound
        # alias), or metering prices a slot alias that GO_PRICES has never heard of and
        # falls to the most-expensive fallback on every row (bot review, PR#442). Applies to
        # both opencode rails (Go priced; Zen metered $0).
        resolved = GO_REWRITE.get(bare, bare)
        parsed["model"] = resolved
        _, translate = _rail_and_translate(model, resolved)
        # OpenCode's Anthropic-compat layer mishandles the STRING shorthand for message content
        # on some models (probed 2026-08-13: glm-5.2 dropped the prompt and free-associated,
        # 12 input tokens counted; the array-of-blocks form answered correctly). claude-code
        # always sends blocks, but normalize here so shorthand clients can't hit it.
        for msg in parsed.get("messages") or []:
            if isinstance(msg, dict) and isinstance(msg.get("content"), str):
                msg["content"] = [{"type": "text", "text": msg["content"]}]
        # OpenCode rejects Anthropic SERVER tools (bisected 2026-08-13: claude-code's WebSearch
        # entry 422s the whole request — `tools.0…WebSearchTool.type`). Client tools are
        # function-shaped (input_schema present / type "custom"); server tools carry a
        # versioned `type` and cannot be served by opencode models anyway — drop only those,
        # so Bash/Edit/MCP tools keep working and the model simply isn't offered WebSearch.
        tools = parsed.get("tools")
        if isinstance(tools, list):
            kept = [t for t in tools if isinstance(t, dict)
                    and (t.get("input_schema") is not None or t.get("type") in (None, "custom"))]
            if len(kept) != len(tools):
                print(f"shim: {rail}-leg dropped {len(tools) - len(kept)} server tool(s)",
                      file=sys.stderr, flush=True)
            parsed["tools"] = kept
        return base, json.dumps(parsed).encode(), rail, prefix + resolved, translate

    def _forward(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        base, body, rail, model, translate = self._route(body)
        if translate:
            self._translate(rail, model, body)
            return

        conn, prefix = _upstream(base)
        headers = {}
        for k, v in self.headers.items():
            lk = k.lower()
            if lk in _SKIP_REQ or (rail in ("go", "zen") and lk in _AUTH):
                continue
            headers[k] = v
        if rail in ("go", "zen"):
            if not GO_KEY:
                # Both opencode rails share the one credential (issue #444: same wallet key).
                self._reply(502, b'{"error":"SHIM_GO_KEY is not set - the opencode rails have no credential"}')
                print(f"shim: DENY {rail}-leg (no key) model={model}", file=sys.stderr, flush=True)
                return
            if GO_AUTH_STYLE in ("both", "x-api-key"):
                headers["x-api-key"] = GO_KEY
            if GO_AUTH_STYLE in ("both", "bearer"):
                headers["Authorization"] = f"Bearer {GO_KEY}"
        headers["Connection"] = "close"
        headers["Accept-Encoding"] = "identity"

        path = self.path
        if rail in ("go", "zen"):
            # OpenCode's compat endpoint 422s on claude-code's decorations (probed 2026-08-13,
            # empty body): send it a plain Anthropic request — no ?beta=true query, no
            # anthropic-beta feature headers. The Anthropic leg keeps both untouched.
            path = path.split("?", 1)[0]
            headers = {k: v for k, v in headers.items() if k.lower() != "anthropic-beta"}
        if os.environ.get("SHIM_DEBUG_BODY") and rail in ("go", "zen"):
            dbg = os.path.join(os.environ.get("TMPDIR", "/tmp"),
                               f"shim-{rail}-body-{threading.get_ident()}-{os.getpid()}.json")
            with open(dbg, "ab") as f:
                f.write(body + b"\n")
            print(f"shim: DEBUG {rail} body -> {dbg} ({len(body)}b)", file=sys.stderr, flush=True)
        try:
            conn.request(self.command, prefix + path, body=body or None, headers=headers)
            resp = conn.getresponse()
        except OSError as e:
            self._reply(502, json.dumps({"error": f"upstream unreachable: {e}"}).encode())
            print(f"shim: 502 {base} rail={rail} model={model} err={e}", file=sys.stderr, flush=True)
            return

        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() not in _SKIP_RESP:
                self.send_header(k, v)
        self.send_header("Connection", "close")
        self.end_headers()
        n = 0
        head = b""  # ADR-108: first 16KB for usage extraction (opencode-leg 2xx)
        tail = b""  # ADR-108: rolling last 16KB for usage extraction (opencode-leg 2xx)
        while True:
            chunk = resp.read(8192)
            if not chunk:
                break
            n += len(chunk)
            self.wfile.write(chunk)
            self.wfile.flush()  # SSE latency: relay each chunk as it lands
            # ADR-108: capture head+tail for opencode-leg 2xx responses
            if rail in ("go", "zen") and 200 <= resp.status < 300:
                if len(head) < 16384:
                    head += chunk
                tail = (tail + chunk)[-16384:]
        conn.close()
        self.close_connection = True
        print(f"shim: {rail} {resp.status} model={model or '-'} path={self.path} bytes={n}",
              file=sys.stderr, flush=True)
        # ADR-108: meter opencode-leg 2xx responses (daemon thread, never block response path)
        if rail in ("go", "zen") and 200 <= resp.status < 300:
            threading.Thread(target=_meter_usage, args=(model, rail, head, tail), daemon=True).start()

    # ── #448: OpenAI-surface translator legs (litellm.anthropic.messages.*) ─────────
    # The _route scrub (content-string normalization, server-tool drop) has ALREADY run on
    # the ANTHROPIC-shaped inbound body — that ordering is FU-172 residue (4), which used
    # to drop OpenAI-shaped tools; litellm owns EVERYTHING after this point. Metering
    # mirrors the native opencode legs: head+tail of the bytes we emit -> _meter_usage.
    def _translate(self, rail: str, model: str, body: bytes):
        # Same refusal order as the compat path: a missing key is the louder, more
        # fundamental failure and must win over a missing translator.
        if not GO_KEY:
            self._reply(502, b'{"error":"SHIM_GO_KEY is not set - the opencode rails have no credential"}')
            print(f"shim: DENY {rail}-leg translator (no key) model={model}", file=sys.stderr, flush=True)
            return
        litellm = _litellm_import()
        if litellm is None:
            err = (f"{rail}-leg model {model} needs the OpenAI-surface translator, but litellm is not "
                   f"importable. Create the venv: python3 -m venv {LITELLM_VENV} && "
                   f"{LITELLM_VENV}/bin/pip install litellm")
            self._reply(501, json.dumps({"error": err}).encode())
            print(f"shim: 501 {rail}-leg translator (litellm missing) model={model}", file=sys.stderr, flush=True)
            return
        if os.environ.get("SHIM_DEBUG_BODY") and rail in ("go", "zen"):
            dbg = os.path.join(os.environ.get("TMPDIR", "/tmp"),
                               f"shim-{rail}-trans-body-{threading.get_ident()}-{os.getpid()}.json")
            with open(dbg, "ab") as f:
                f.write(body + b"\n")
            print(f"shim: DEBUG {rail} translator body -> {dbg} ({len(body)}b)", file=sys.stderr, flush=True)
        parsed = json.loads(body)
        api_base, openai_model = _translator_target(rail, model)
        # Deliberately NOT forwarded: `thinking` — litellm routes it to the OpenAI
        # Responses API (responses/<model>), which opencode's /chat/completions surface
        # does not speak, and these models don't take Anthropic extended thinking anyway
        # (they emit their own reasoning content blocks). `metadata` IS forwarded; the
        # other params pass through as-is.
        kwargs = {k: v for k, v in {
            "model": openai_model,
            "api_base": api_base,
            "api_key": GO_KEY,
            "max_tokens": parsed.get("max_tokens") or 4096,
            "messages": parsed.get("messages") or [],
            "system": parsed.get("system"),
            "tools": parsed.get("tools"),
            "tool_choice": parsed.get("tool_choice"),
            "temperature": parsed.get("temperature"),
            "top_p": parsed.get("top_p"),
            "stop_sequences": parsed.get("stop_sequences"),
            "metadata": parsed.get("metadata"),
            "stream": parsed.get("stream", False),
        }.items() if v is not None}
        if parsed.get("stream", False):
            self._stream_translated(kwargs, rail, model)
        else:
            self._reply_translated(kwargs, rail, model)

    def _reply_translated(self, kwargs: dict, rail: str, model: str):
        litellm = _litellm_import()
        try:
            resp = litellm.anthropic.messages.create(**kwargs)
            # Serialization stays INSIDE the guard (PR#465 review): an unexpected success-value
            # shape used to throw uncaught here — no reply ever sent, a silent connection reset
            # instead of the loud 502 every other path holds.
            if not isinstance(resp, dict):
                resp = resp.model_dump(mode="json") if hasattr(resp, "model_dump") else dict(resp)
            out = json.dumps(resp, default=str).encode()
        except Exception as e:
            self._reply(502, json.dumps({"error": f"translator upstream failed: {e}"}).encode())
            print(f"shim: 502 {rail}-leg translator model={model} err={e}", file=sys.stderr, flush=True)
            return
        self._reply(200, out)
        print(f"shim: {rail}-leg(translated) 200 model={model} bytes={len(out)}", file=sys.stderr, flush=True)
        if rail in ("go", "zen"):
            threading.Thread(target=_meter_usage,
                             args=(model, rail, out[:16384], out[-16384:]),
                             daemon=True).start()

    def _stream_translated(self, kwargs: dict, rail: str, model: str):
        litellm = _litellm_import()
        first = None
        try:
            gen = litellm.anthropic.messages.create(**kwargs)  # sync, stream=True -> Iterator[bytes]
            # PRIME the stream before committing 200 (PR#465 review): a lazy stream client fires
            # its upstream call/auth on the first next(), so without this an upstream failure
            # landed AFTER the committed 200 as a silently truncated stream. Pulling the first
            # event here keeps that whole class on the loud-502 path; StopIteration (an honestly
            # empty stream) is not an error and falls through with first=None.
            it = iter(gen)
            try:
                first = next(it)
            except StopIteration:
                it = iter(())
        except Exception as e:
            self._reply(502, json.dumps({"error": f"translator upstream failed: {e}"}).encode())
            print(f"shim: 502 {rail}-leg translator stream model={model} err={e}", file=sys.stderr, flush=True)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        head = b""
        tail = b""
        n = 0
        try:
            from itertools import chain as _chain
            for chunk in (_chain([first], it) if first is not None else it):
                if not isinstance(chunk, bytes):  # litellm yields raw SSE bytes; be defensive
                    chunk = json.dumps(chunk, default=str).encode() if isinstance(chunk, dict) \
                        else str(chunk).encode()
                n += len(chunk)
                self.wfile.write(chunk)
                self.wfile.flush()  # SSE latency: relay each event as it lands
                if rail in ("go", "zen"):
                    if len(head) < 16384:
                        head += chunk
                    tail = (tail + chunk)[-16384:]
        except Exception as e:
            print(f"shim: {rail}-leg translator stream aborted model={model} err={e}",
                  file=sys.stderr, flush=True)
        self.close_connection = True
        print(f"shim: {rail}-leg(translated stream) 200 model={model} bytes={n}", file=sys.stderr, flush=True)
        if rail in ("go", "zen"):
            threading.Thread(target=_meter_usage, args=(model, rail, head, tail), daemon=True).start()

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
          f"(anthropic={ANTHROPIC_BASE}, go={GO_BASE}, zen={ZEN_BASE}, "
          f"key={'set' if GO_KEY else 'ABSENT'}"
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

    global GO_BASE, ZEN_BASE, ANTHROPIC_BASE, GO_KEY, PORT
    ANTHROPIC_BASE, GO_BASE, ZEN_BASE, GO_KEY, PORT = \
        "http://127.0.0.1:18191", "http://127.0.0.1:18192/zen/go", "http://127.0.0.1:18193/zen", \
        "go-test-key", 18190
    stubs = [stub("anthropic", 18191), stub("go", 18192), stub("zen", 18193)]
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

    # ── #448: OpenAI-surface translator routing (offline — no network) ──────────
    # The zen-leg compat self-test block (200 + prefix strip + auth swap + path join) is
    # GONE by design: #448 makes EVERY opencode/ (zen) id take the OpenAI-surface
    # translator, so the zen compat path no longer exists. Its auth-isolation guarantee
    # (session oauth never reaches opencode) is preserved STRUCTURALLY — the translator
    # hands litellm only api_key=GO_KEY, never the inbound Authorization header. The
    # translator-target assertions below carry the routing coverage; the wire-level tool
    # round-trip is the acceptance test against a live shim.
    check(_rail_and_translate("opencode/nemotron-3-ultra-free", "nemotron-3-ultra-free") == ("zen", True),
          "#448: every opencode/ (zen) id takes the OpenAI-surface translator")
    check(_rail_and_translate("opencode-go/gpt-5.6-luna", "gpt-5.6-luna") == ("go", True),
          "#448: opencode-go/gpt-5.6-luna (GO_OPENAI_ONLY) takes the translator")
    check(_rail_and_translate("opencode-go/kimi-k3", "kimi-k3") == ("go", False),
          "#448: opencode-go/kimi-k3 keeps the Anthropic-compat path (not in GO_OPENAI_ONLY)")
    check(_rail_and_translate("opencode-go/frozen-luna-slot", "kimi-k3") == ("go", False),
          "#448: a rewrite AWAY from a GO_OPENAI_ONLY id keeps the compat path")
    check(_rail_and_translate("claude-haiku-4-5", "claude-haiku-4-5") == ("anthropic", False),
          "#448: the anthropic leg is never translated")
    zbase, zmodel = _translator_target("zen", "opencode/nemotron-3-ultra-free")
    check(zbase == "http://127.0.0.1:18193/zen/v1" and zmodel == "openai/nemotron-3-ultra-free",
          "#448: zen translator targets the OpenAI surface base + resolved bare id")
    gbase, gmodel = _translator_target("go", "opencode-go/gpt-5.6-luna")
    check(gbase == "http://127.0.0.1:18192/zen/go/v1" and gmodel == "openai/gpt-5.6-luna",
          "#448: go translator targets the OpenAI surface base + resolved bare id")

    # 501-when-litellm-missing: force the lazy import to fail; the translator legs must
    # refuse loudly (501), never silently fall back to the broken compat surface, and the
    # other rails must be untouched. No network — litellm never actually runs.
    _real_litellm_import = _litellm_import
    globals()["_litellm_import"] = lambda: None
    try:
        st, _ = call("opencode/nemotron-3-ultra-free")
        check(st == 501, "#448: zen leg 501s when litellm is missing (never the broken compat surface)")
        st, _ = call("opencode-go/gpt-5.6-luna")
        check(st == 501, "#448: go leg (luna) 501s when litellm is missing (never the broken compat surface)")
        st, data = call("opencode-go/kimi-k3")
        check(st == 200 and (seen.get("go") or {}).get("model") == "kimi-k3",
              "#448: kimi-k3 compat path still serves when litellm is missing")
        st, _ = call("claude-haiku-4-5")
        check(st == 200, "#448: anthropic passthrough still serves when litellm is missing")
    finally:
        globals()["_litellm_import"] = _real_litellm_import

    # zen rewrite: the rewritten id stays on the translator (resolved id is what's served).
    GO_REWRITE = {"broken-zen-model": "nemotron-3-ultra-free"}
    check(_rail_and_translate("opencode/broken-zen-model", "nemotron-3-ultra-free") == ("zen", True)
          and _translator_target("zen", "opencode/nemotron-3-ultra-free")[1] == "openai/nemotron-3-ultra-free",
          "#448: zen SHIM_MODEL_REWRITE remaps a frozen slot id onto the translator target")
    GO_REWRITE = {}

    GO_KEY = ""
    st, _ = call("opencode-go/kimi-k3")
    check(st == 502, "go leg without a key: refused loudly (502), never forwarded")
    st, _ = call("opencode/nemotron-3-ultra-free")
    check(st == 502, "zen leg without a key: refused loudly (502), never forwarded")

    for s in stubs:  # stop the stub accept loops so nothing races the exit (homelab#486)
        s.shutdown()
    print(("self-test: PASS" if not fails else f"self-test: {len(fails)} FAILURES"))
    return 0 if not fails else 1


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        rc = self_test()
        # homelab#486: the self-test exits through os._exit, NOT sys.exit — CPython's
        # interpreter finalization races the buffered-stderr lock still held by the
        # self-test's daemon threads (stub servers, the shim's own serve loop, the
        # fire-and-forget metering threads), aborting _enter_buffered_busy AFTER
        # "self-test: PASS" and making the CI gate exit 134. os._exit skips
        # finalization entirely. Deliberately self-test-only: the serve() path keeps
        # sys.exit so the interpreter stays in charge of its own shutdown.
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(rc)
    sys.exit(serve())
