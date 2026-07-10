#!/usr/bin/env python3
"""openrouter-proxy — the ADR-081 egress proxy, v1 slice (FU-018 / FU-062 §M4).

Worker harnesses that cannot carry OpenRouter `provider` routing themselves (goose) send their
OpenRouter traffic here instead of to openrouter.ai directly (`OPENROUTER_HOST`, wired by homelab
agents/agent-session.sh). For every `POST …/chat/completions` whose JSON body has NO `provider`
field, the proxy injects the per-model session pin — the effective-cheapest cache-supporting,
tools-capable provider at ≥ the uptime floor, plus allow_fallbacks and a max_price guard — and
forwards. Everything else (other paths, bodies that already carry `provider`, `:free` models where
routing is $0 either way) passes through untouched. Cache lives AT the provider, so pinning per
session/model is the whole point (the $5.79 qwen autopsy: default routing = a 1/price² lottery).

v1 scope (deliberate): provider injection ONLY. The pod still holds its own OPENROUTER_API_KEY —
the Authorization header passes through unread. Credential minting/injection and the Cilium
egress lockdown are the remaining ADR-081 legs (homelab FU-018 / FU-020).

The pin math mirrors homelab agents/estimate_budget.py `pinned_provider()` (that file is the
authoritative twin — keep them in step): h-blended effective price over pools
cached+tools+uptime → tools+uptime → tools.

Stdlib only; runs on a stock python:3.13-slim from a ConfigMap (github-exporter pattern).
"""

import base64
import json
import os
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("UPSTREAM", "https://openrouter.ai")
PORT = int(os.environ.get("PORT", "8080"))
CACHE_HIT = float(os.environ.get("CACHE_HIT", "0.8"))  # h for the effective-price blend (§M3)
UPTIME_FLOOR = float(os.environ.get("UPTIME_FLOOR", "95"))
PIN_TTL_S = int(os.environ.get("PIN_TTL_S", "3600"))  # pin cache; providers/prices drift slowly
PIN_FAIL_TTL_S = int(os.environ.get("PIN_FAIL_TTL_S", "300"))  # don't hammer a failing endpoint
MAX_PRICE_FACTOR = float(os.environ.get("MAX_PRICE_FACTOR", "2.0"))  # guard vs fallback lottery
READ_TIMEOUT_S = int(os.environ.get("READ_TIMEOUT_S", "300"))  # idle timeout per upstream read
# Completion floor (0 = off). Three worker runs died to goose -32602 tool-call truncation at
# 14781/15267/16322 chars — all ≈4k tokens: a max_tokens=4096 default somewhere goose-side caps
# any file-write tool call above ~4k tokens mid-JSON (oracle-fleet#1 autopsies, TICK-LOG 2026-07-09).
# The proxy raises max_tokens to this floor (clamped to the pinned endpoint's max_completion_tokens
# when known); an explicit request value ABOVE the floor always wins.
MAX_TOKENS_FLOOR = int(os.environ.get("MAX_TOKENS_FLOOR", "16384"))
# ADR-087 / FU-018 leg A: pods hold an OPAQUE REF (`ref:<ns>/<secret>`) instead of the real
# OpenRouter key; this proxy resolves the ref via the K8s API and injects the real key upstream.
# Only Secrets carrying SESSION_KEY_LABEL are honored — the label check keeps the proxy's
# get-secret RBAC from becoming a generic secret oracle. Short cache = revocation latency.
SESSION_KEY_LABEL = "openrouter.teststuff.net/session-key"
REF_CACHE_TTL_S = int(os.environ.get("REF_CACHE_TTL_S", "60"))
_SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
_refs: dict[str, tuple[float, dict | None]] = {}  # "ns/name" -> (expires_epoch, {key,guardrail}|None)
_refs_lock = threading.Lock()


def _resolve_ref(ref: str) -> dict | None:
    """`ns/name` -> {"key": OPENROUTER_API_KEY, "guardrail": ...}, or None
    (missing/unlabeled/unreadable). guardrail feeds the FU-024 only-free enforcement."""
    now = time.time()
    with _refs_lock:
        hit = _refs.get(ref)
        if hit and hit[0] > now:
            return hit[1]
    resolved = None
    try:
        ns, name = ref.split("/", 1)
        token = open(f"{_SA_DIR}/token").read().strip()
        ctx = ssl.create_default_context(cafile=f"{_SA_DIR}/ca.crt")
        req = urllib.request.Request(
            f"https://kubernetes.default.svc/api/v1/namespaces/{ns}/secrets/{name}",
            headers={"Authorization": "Bearer " + token},
        )
        with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
            secret = json.load(resp)
        if (secret.get("metadata", {}).get("labels") or {}).get(SESSION_KEY_LABEL) == "true":
            data = secret.get("data") or {}
            b64 = data.get("OPENROUTER_API_KEY", "")
            if b64:
                resolved = {
                    "key": base64.b64decode(b64).decode(),
                    "guardrail": base64.b64decode(data.get("GUARDRAIL", "")).decode(),
                }
        else:
            log(f"ref: {ref} exists but lacks {SESSION_KEY_LABEL} — refusing (not a session key)")
    except Exception as e:  # noqa: BLE001 — a failed resolve degrades to passthrough (upstream 401s the ref)
        log(f"ref: resolve failed for {ref}: {e}")
    with _refs_lock:
        _refs[ref] = (now + REF_CACHE_TTL_S, resolved)
    return resolved


GIT_TOKEN_LABEL = "homelab.teststuff.net/agent-git-token"


def _resolve_git_token(ns: str) -> str | None:
    """ADR-087 leg B: serve the ESO-minted `agent-git-token` for a worker namespace — the pod
    stops mounting the Secret entirely and fetches per git operation (ESO keeps it fresh, so run
    duration is unbounded by token TTL). Honors only Secrets carrying GIT_TOKEN_LABEL; the same
    per-namespace RBAC as session keys. Cached briefly like refs."""
    ref = f"{ns}/agent-git-token#git"
    now = time.time()
    with _refs_lock:
        hit = _refs.get(ref)
        if hit and hit[0] > now:
            return hit[1]
    token_value = None
    try:
        sa_token = open(f"{_SA_DIR}/token").read().strip()
        ctx = ssl.create_default_context(cafile=f"{_SA_DIR}/ca.crt")
        req = urllib.request.Request(
            f"https://kubernetes.default.svc/api/v1/namespaces/{ns}/secrets/agent-git-token",
            headers={"Authorization": "Bearer " + sa_token},
        )
        with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
            secret = json.load(resp)
        if (secret.get("metadata", {}).get("labels") or {}).get(GIT_TOKEN_LABEL) == "true":
            b64 = (secret.get("data") or {}).get("token", "")
            token_value = base64.b64decode(b64).decode() if b64 else None
        else:
            log(f"git-token: {ns} secret lacks {GIT_TOKEN_LABEL} — refusing")
    except Exception as e:  # noqa: BLE001
        log(f"git-token: resolve failed for {ns}: {e}")
    with _refs_lock:
        _refs[ref] = (now + REF_CACHE_TTL_S, token_value)
    return token_value


def _inject_ref_auth(headers: dict) -> str:
    """Rewrite `Authorization: Bearer ref:<ns>/<name>` to the real key. Returns a note suffix."""
    auth = next((k for k in headers if k.lower() == "authorization"), None)
    if not auth or not headers[auth].startswith("Bearer ref:"):
        return ""
    ref = headers[auth][len("Bearer ref:"):].strip()
    resolved = _resolve_ref(ref)
    if resolved:
        headers[auth] = "Bearer " + resolved["key"]
        return "+cred"
    return "+cred-unresolved"  # forwarded as-is; upstream will 401 loudly (never fail silently)


def _guardrail_reject(self_ref: str, model: str) -> bytes | None:
    """FU-024: a `only-free` session may complete ONLY on :free model variants. Enforced here
    because the proxy already resolves the session (injection rails); direct-key sessions are
    out of scope by design — guardrailed keys are issued injected (model-scout canaries)."""
    resolved = _resolve_ref(self_ref)
    if not resolved or resolved.get("guardrail") != "only-free":
        return None
    if normalize_model(model).endswith(":free"):
        return None
    return json.dumps({
        "error": {
            "code": 403,
            "message": f"guardrail only-free: model '{model}' is not a :free variant — "
                       "this session key is restricted to free-tier models (FU-024)",
        }
    }).encode()

# Hop-by-hop (and framing) headers never forwarded either way. accept-encoding is stripped so the
# upstream answers identity — we re-frame the response as stream-until-close.
_DROP_REQ = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers",
    "transfer-encoding", "upgrade", "host", "content-length", "accept-encoding",
}
_DROP_RESP = {"connection", "keep-alive", "transfer-encoding", "content-length"}

_pins: dict[str, tuple[float, dict | None]] = {}  # model -> (expires_epoch, provider block|None)
_pins_lock = threading.Lock()


def log(msg: str) -> None:
    print(f"{time.strftime('%H:%M:%S', time.gmtime())} {msg}", flush=True)


def _mtok(pricing: dict, key: str) -> float | None:
    """OpenRouter $/token strings → $/M floats (None = not offered)."""
    value = pricing.get(key)
    if value is None:
        return None
    try:
        return float(value) * 1e6
    except (TypeError, ValueError):
        return None


def normalize_model(model: str) -> str:
    """Bare vendor/model id; keep openrouter/<cloaked> (same rule as estimate_budget.py)."""
    stripped = model.removeprefix("openrouter/")
    return stripped if "/" in stripped else model


def compute_pin(model: str) -> dict | None:
    """The M4 session pin as an OpenRouter `provider` routing block, or None (no eligible
    provider). Raises on fetch failure (caller caches the failure briefly)."""
    url = f"{UPSTREAM}/api/v1/models/{model}/endpoints"
    req = urllib.request.Request(url, headers={"User-Agent": "homelab-openrouter-proxy"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.load(resp)
    endpoints = []
    for e in (data.get("data") or {}).get("endpoints") or []:
        pricing = e.get("pricing") or {}
        endpoints.append(
            {
                "provider": e.get("provider_name") or e.get("name"),
                # provider.order matches the endpoint tag's base slug ("deepinfra/fp4" →
                # "deepinfra"), NOT the display provider_name (measured 2026-07-09: display
                # names silently no-op under allow_fallbacks).
                "slug": (e.get("tag") or "").split("/")[0] or None,
                "prompt": _mtok(pricing, "prompt") or 0.0,
                "completion": _mtok(pricing, "completion"),
                "cache_read": _mtok(pricing, "input_cache_read"),
                "uptime": e.get("uptime_last_30m"),
                "tools": "tools" in (e.get("supported_parameters") or []),
                "max_completion": e.get("max_completion_tokens"),
            }
        )

    tooled = [e for e in endpoints if e["tools"]]

    def eff(e: dict) -> float:
        if e["cache_read"] is not None:
            return (1.0 - CACHE_HIT) * e["prompt"] + CACHE_HIT * e["cache_read"]
        return e["prompt"]

    for pool in (
        [e for e in tooled if e["cache_read"] is not None and (e["uptime"] or 0.0) >= UPTIME_FLOOR],
        [e for e in tooled if (e["uptime"] or 0.0) >= UPTIME_FLOOR],
        tooled,
    ):
        if pool:
            best = min(pool, key=eff)
            max_price = {"prompt": round(best["prompt"] * MAX_PRICE_FACTOR, 4)}
            if best["completion"] is not None:
                max_price["completion"] = round(best["completion"] * MAX_PRICE_FACTOR, 4)
            return {
                "provider": {
                    "order": [best["slug"] or best["provider"]],
                    "allow_fallbacks": True,
                    "max_price": max_price,
                },
                "max_completion": best["max_completion"],
            }
    return None


def pin_for(model: str) -> dict | None:
    """{"provider": <routing block>, "max_completion": int|None} for the model, or None
    (free model / no eligible endpoint / fetch failure)."""
    model = normalize_model(model)
    if model.endswith(":free"):
        return None  # $0 either way — free models sidestep M4 (model-routing.md)
    now = time.time()
    with _pins_lock:
        hit = _pins.get(model)
        if hit and hit[0] > now:
            return hit[1]
    try:
        pin = compute_pin(model)
        ttl = PIN_TTL_S
    except Exception as e:  # noqa: BLE001 — any failure degrades to passthrough
        log(f"pin: endpoints fetch failed for {model}: {e} — passthrough")
        pin, ttl = None, PIN_FAIL_TTL_S
    with _pins_lock:
        _pins[model] = (now + ttl, pin)
    return pin


class Proxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "openrouter-proxy"

    def log_message(self, fmt, *args):  # default logger writes to stderr with client noise
        pass

    def _forward(self, body: bytes | None, note: str) -> None:
        started = time.time()
        url = UPSTREAM + self.path
        headers = {k: v for k, v in self.headers.items() if k.lower() not in _DROP_REQ}
        note += _inject_ref_auth(headers)  # ADR-087: opaque-ref -> real key, every method/path
        req = urllib.request.Request(url, data=body, headers=headers, method=self.command)
        try:
            resp = urllib.request.urlopen(req, timeout=READ_TIMEOUT_S)
        except urllib.error.HTTPError as e:
            resp = e  # an HTTPError IS the response — forward its status/body verbatim
        except OSError as e:
            log(f"{self.command} {self.path} → 502 upstream unreachable: {e}")
            self.send_response(502)
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(f"openrouter-proxy: upstream unreachable: {e}".encode())
            self.close_connection = True
            return

        status = resp.getcode()
        self.send_response(status)
        for k, v in resp.headers.items():
            if k.lower() not in _DROP_RESP:
                self.send_header(k, v)
        # Stream-until-close framing: correct for both SSE (stream:true) and plain JSON, and it
        # sidesteps re-computing Content-Length for a rewritten request's response.
        self.send_header("Connection", "close")
        self.send_header("X-Openrouter-Proxy", note)
        self.end_headers()
        sent = 0
        try:
            while chunk := resp.read(8192):
                self.wfile.write(chunk)
                self.wfile.flush()
                sent += len(chunk)
        except OSError as e:
            log(f"{self.command} {self.path} → client/upstream dropped mid-stream: {e}")
        finally:
            resp.close()
        self.close_connection = True
        log(f"{self.command} {self.path} → {status} [{note}] {sent}B {time.time() - started:.1f}s")

    def do_GET(self) -> None:
        if self.path == "/healthz":
            payload = b"ok"
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path.startswith("/git-token"):
            # ADR-087 leg B — GET /git-token?ns=<worker-namespace> → the live App token, plaintext
            # body. In-cluster only; FU-020's NetworkPolicy narrows callers to worker pods.
            from urllib.parse import parse_qs, urlparse
            ns = (parse_qs(urlparse(self.path).query).get("ns") or [""])[0]
            token_value = _resolve_git_token(ns) if ns else None
            if token_value:
                payload = token_value.encode()
                self.send_response(200)
                log(f"GET /git-token ns={ns} → served")
            else:
                payload = b"unresolvable"
                self.send_response(404)
                log(f"GET /git-token ns={ns} → 404")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self._forward(None, "passthrough")

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        note = "passthrough"
        if self.path.rstrip("/").endswith("/chat/completions") and body:
            try:
                payload = json.loads(body)
                if isinstance(payload, dict) and payload.get("model"):
                    # FU-024 only-free enforcement (before any forwarding spend)
                    auth_hdr = self.headers.get("Authorization", "")
                    if auth_hdr.startswith("Bearer ref:"):
                        reject = _guardrail_reject(
                            auth_hdr[len("Bearer ref:"):].strip(), str(payload["model"]))
                        if reject:
                            log(f"POST {self.path} → 403 [guardrail only-free] model={payload['model']}")
                            self.send_response(403)
                            self.send_header("Content-Type", "application/json")
                            self.send_header("Content-Length", str(len(reject)))
                            self.send_header("Connection", "close")
                            self.end_headers()
                            self.wfile.write(reject)
                            self.close_connection = True
                            return
                    notes = []
                    pin = pin_for(str(payload["model"]))
                    # An explicit `provider` (a harness/opencode.json that CAN carry prefs, or a
                    # hand-crafted request) always wins — never overwrite policy already in the body.
                    if pin and "provider" not in payload:
                        payload["provider"] = pin["provider"]
                        notes.append(f"injected:{pin['provider']['order'][0]}")
                    # max_tokens floor (goose -32602 truncation class): raise a missing/low
                    # max_tokens to MAX_TOKENS_FLOOR, clamped to the pinned endpoint's
                    # max_completion_tokens when known. An explicit value ABOVE the floor wins.
                    floor = MAX_TOKENS_FLOOR
                    if pin and isinstance(pin.get("max_completion"), int):
                        floor = min(floor, pin["max_completion"])
                    current = payload.get("max_tokens")
                    if floor > 0 and (not isinstance(current, int) or current < floor):
                        payload["max_tokens"] = floor
                        notes.append(f"max_tokens:{floor}")
                    if notes:
                        body = json.dumps(payload).encode()
                        note = "+".join(notes)
            except ValueError:
                pass  # not JSON — forward untouched
        self._forward(body, note)


def main() -> int:
    log(f"openrouter-proxy: listening :{PORT} → {UPSTREAM} "
        f"(h={CACHE_HIT}, uptime≥{UPTIME_FLOOR}, max_price×{MAX_PRICE_FACTOR}, "
        f"max_tokens_floor={MAX_TOKENS_FLOOR})")
    ThreadingHTTPServer(("", PORT), Proxy).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
