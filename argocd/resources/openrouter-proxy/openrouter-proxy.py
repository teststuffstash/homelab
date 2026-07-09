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

import json
import os
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
                "order": [best["slug"] or best["provider"]],
                "allow_fallbacks": True,
                "max_price": max_price,
            }
    return None


def pin_for(model: str) -> dict | None:
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
        self._forward(None, "passthrough")

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        note = "passthrough"
        if self.path.rstrip("/").endswith("/chat/completions") and body:
            try:
                payload = json.loads(body)
                # An explicit `provider` (a harness/opencode.json that CAN carry prefs, or a
                # hand-crafted request) always wins — never overwrite policy already in the body.
                if isinstance(payload, dict) and "provider" not in payload and payload.get("model"):
                    pin = pin_for(str(payload["model"]))
                    if pin:
                        payload["provider"] = pin
                        body = json.dumps(payload).encode()
                        note = f"injected:{pin['order'][0]}"
            except ValueError:
                pass  # not JSON — forward untouched
        self._forward(body, note)


def main() -> int:
    log(f"openrouter-proxy: listening :{PORT} → {UPSTREAM} "
        f"(h={CACHE_HIT}, uptime≥{UPTIME_FLOOR}, max_price×{MAX_PRICE_FACTOR})")
    ThreadingHTTPServer(("", PORT), Proxy).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
