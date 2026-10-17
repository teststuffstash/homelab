"""The data plane: streaming passthrough with httpx (GW-MODEL-RESOLVE, GW-CRED-BOUNDARY, GW-RAIL-*).

Per request: authenticate the session token → check the rail serves the dialect → check the
body's `model` against the session's (403 `model-not-session`; absent = filled with the wire id;
on the anthropic rail the body is forwarded untouched after a family match) → resolve + inject
the credential → stream the upstream bytes back unchanged (SSE included) → record usage.
Typed errors (specs/endpoints/*.schema.json `errors`): 401 session-unknown / -expired /
-released / credential-unresolved, 403 model-not-session, 501 dialect-unsupported-on-rail,
503 credential-transient, 502 upstream-auth, 502 upstream-unreachable (a connect failure that is
not a timeout), 502 header-refused (the credential-shaped header tripwire), 504 upstream-timeout.
Upstream 429 passes through with `retry-after`.
"""

from __future__ import annotations

import json
import logging
import time
import zlib

import httpx
from starlette.requests import Request
from starlette.responses import Response, StreamingResponse

from . import rails
from .config import model_matches, wire_model
from .credentials import CredentialTransient, CredentialUnresolved
from .metrics import Metrics
from .sessions import SessionService, error
from .store import Session, Usage

log = logging.getLogger("gateway.proxy")

USAGE_CAPTURE_MAX = 4 * 1024 * 1024  # bytes of response kept for the best-effort usage parse
DEFAULT_RETRY_AFTER = "30"


def inbound_token(request: Request) -> str | None:
    """The bearer is consulted first; `x-api-key` second (GW-CRED-BOUNDARY)."""
    auth = request.headers.get("authorization", "")
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    return request.headers.get("x-api-key") or None


def decoded(body: bytes, encoding: str | None) -> bytes:
    """The capture as the client sees it: the upstream answers in the encoding httpx's default
    `accept-encoding` asked for (live anthropic: gzip SSE), and `aiter_raw` keeps it encoded.
    gzip/deflate via zlib's auto-detect; a truncated capture decodes as far as it goes; any other
    encoding → b"" (usage unknown, never a wrong count)."""
    enc = (encoding or "identity").strip().lower()
    if enc == "identity":
        return body
    if enc not in ("gzip", "x-gzip", "deflate"):
        return b""
    try:
        return zlib.decompressobj(zlib.MAX_WBITS | 32).decompress(body)
    except zlib.error:
        try:  # raw deflate (no zlib header), which some servers send for `deflate`
            return zlib.decompressobj(-zlib.MAX_WBITS).decompress(body)
        except zlib.error:
            return b""


def _usage_from(u: dict, prev: Usage) -> Usage:
    """One `usage` object → Usage, keeping prev's value for any class this object does not carry."""
    cached = int((u.get("prompt_tokens_details") or {}).get("cached_tokens") or 0)
    if "prompt_tokens" in u:  # openai dialect: prompt_tokens INCLUDES the cache read
        tokens_in = max(int(u.get("prompt_tokens") or 0) - cached, 0)
        cache_read = cached
    else:
        tokens_in = int(u.get("input_tokens") or 0)
        cache_read = int(u.get("cache_read_input_tokens") or 0)
    cache_write = int(u.get("cache_creation_input_tokens") or 0)
    tokens_out = int(u.get("output_tokens") or u.get("completion_tokens") or 0)
    return Usage(
        tokens_in=tokens_in or prev.tokens_in,
        tokens_cache_read=cache_read or prev.tokens_cache_read,
        tokens_cache_write=cache_write or prev.tokens_cache_write,
        tokens_out=tokens_out or prev.tokens_out,
    )


def parse_usage(body: bytes, streaming: bool) -> Usage:
    """Best-effort four-class usage from a JSON or SSE response body; all zero if unclear."""
    if not body:
        return Usage()
    usage = Usage()
    try:
        if not streaming:
            doc = json.loads(body)
            return _usage_from(doc.get("usage") or {}, usage)
        for line in body.decode("utf-8", errors="replace").splitlines():
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if not payload or payload == "[DONE]":
                continue
            try:
                ev = json.loads(payload)
            except ValueError:
                continue
            if not isinstance(ev, dict):
                continue
            # Anthropic: message_start carries the input + cache classes, message_delta the final
            # output (live, it repeats the input classes too); openai: a last chunk with usage.
            msg_usage = (ev.get("message") or {}).get("usage")
            if msg_usage:
                usage = _usage_from(msg_usage, usage)
            if ev.get("usage"):
                usage = _usage_from(ev["usage"], usage)
    except (ValueError, AttributeError, TypeError):
        return Usage()
    return usage


class Proxy:
    def __init__(self, sessions: SessionService, metrics: Metrics, upstreams: dict[str, str],
                 client: httpx.AsyncClient):
        self.sessions = sessions
        self.metrics = metrics
        self.upstreams = upstreams
        self.client = client

    async def forward(self, request: Request, dialect: str, op: str) -> Response:
        row, code = self.sessions.authenticate(inbound_token(request))
        if code:
            self.metrics.request("none", dialect, 401)
            log.info("%s %s → 401 %s", request.method, request.url.path, code)
            return error(401, code, "session token unknown, expired or released")
        assert row is not None
        if not rails.serves(row.rail, dialect):
            self.metrics.request(row.rail, dialect, 501)
            return error(501, "dialect-unsupported-on-rail", f"rail {row.rail} does not serve the {dialect} dialect")
        body: bytes | None = None
        streaming = False
        if request.method == "POST":
            raw = await request.body()
            try:
                doc = json.loads(raw) if raw else {}
            except ValueError:
                self.metrics.request(row.rail, dialect, 400)
                return error(400, "malformed-body", "body is not JSON")
            if not isinstance(doc, dict):
                self.metrics.request(row.rail, dialect, 400)
                return error(400, "malformed-body", "body must be a JSON object")
            wire = wire_model(row.rail, row.model)
            asked = doc.get("model")
            if asked is None:
                doc["model"] = wire
                body = json.dumps(doc, separators=(",", ":")).encode()
            elif not isinstance(asked, str) or not model_matches(
                row.rail, row.model, asked, self.sessions.policy.rails[row.rail].side_models
            ):
                log.warning("model-not-session: session=%s asked=%s session_model=%s", row.id, asked, row.model)
                self.metrics.request(row.rail, dialect, 403)
                return error(403, "model-not-session", f"this session rides {row.model}")
            else:
                body = raw  # the body already names the session's model — forwarded untouched
            streaming = bool(doc.get("stream"))
        try:
            credential = await self.sessions.resolver.resolve(row.rail, self.sessions.policy.stacks[row.stack])
        except CredentialTransient:
            self.metrics.credential(row.rail, "transient")
            self.metrics.request(row.rail, dialect, 503)
            retry = str(self.sessions.resolver.negative_cache_s)
            return error(503, "credential-transient", f"kube API failed resolving the {row.rail} credential — retry",
                         headers={"retry-after": retry})
        except CredentialUnresolved:
            self.metrics.credential(row.rail, "definitive")
            self.metrics.request(row.rail, dialect, 401)
            return error(401, "credential-unresolved", f"no usable credential for rail {row.rail}")
        self.metrics.credential(row.rail, "resolved")
        try:
            headers, note = rails.build_headers(
                row.rail, dialect, [(k.decode(), v.decode()) for k, v in request.headers.raw], credential, row.id
            )
        except rails.HeaderRefused as e:
            self.metrics.request(row.rail, dialect, 502)
            return error(502, "header-refused", str(e))
        if body is not None and "content-type" not in headers:
            headers["content-type"] = "application/json"
        url = rails.upstream_url(row.rail, self.upstreams[row.rail], dialect, op)
        if request.method == "GET" and request.url.query:
            url += "?" + request.url.query
        t0 = time.monotonic()
        try:
            req = self.client.build_request(request.method, url, headers=headers, content=body)
            resp = await self.client.send(req, stream=True)
        except httpx.TimeoutException as e:
            elapsed = time.monotonic() - t0
            self.metrics.request(row.rail, dialect, 504, elapsed)
            self.sessions.store.record_request(row.id, 504, int(elapsed * 1000), ts=self.sessions.clock())
            log.warning("upstream-timeout %s session=%s: %s", row.rail, row.id, type(e).__name__)
            return error(504, "upstream-timeout", f"rail {row.rail} upstream: {type(e).__name__}")
        except httpx.HTTPError as e:
            elapsed = time.monotonic() - t0
            self.metrics.request(row.rail, dialect, 502, elapsed)
            self.sessions.store.record_request(row.id, 502, int(elapsed * 1000), ts=self.sessions.clock())
            log.warning("upstream-unreachable %s session=%s: %s", row.rail, row.id, type(e).__name__)
            return error(502, "upstream-unreachable", f"rail {row.rail} upstream: {type(e).__name__}")
        status = resp.status_code
        if status in (401, 403):
            await resp.aclose()
            elapsed = time.monotonic() - t0
            self.metrics.request(row.rail, dialect, 502, elapsed)
            self.metrics.upstream_auth_rejected(row.rail)
            self.sessions.store.record_request(row.id, 502, int(elapsed * 1000), ts=self.sessions.clock())
            log.error("upstream-auth %s %d session=%s [%s]", row.rail, status, row.id, note)
            return error(502, "upstream-auth", f"rail {row.rail} rejected the gateway's credential (upstream {status})")
        if row.rail == "anthropic":
            self.metrics.subscription_windows(row.rail, resp.headers)
        note += self.sessions.capacity.observe(row.rail, status, resp.headers, self.sessions.clock())
        out_headers = rails.response_headers(resp.headers.multi_items())
        if status == 429 and "retry-after" not in {k.lower() for k in out_headers}:
            out_headers["retry-after"] = DEFAULT_RETRY_AFTER
        return self._stream(resp, row, dialect, status, out_headers, streaming, t0, note)

    def _stream(self, resp: httpx.Response, row: Session, dialect: str, status: int, out_headers: dict,
                streaming: bool, t0: float, note: str) -> StreamingResponse:
        captured = bytearray()
        final = [status]  # what the row and the metric record; a mid-stream timeout rewrites it to 504

        async def body_iter():
            try:
                async for chunk in resp.aiter_raw():
                    if len(captured) < USAGE_CAPTURE_MAX:
                        captured.extend(chunk)
                    yield chunk
            except httpx.TimeoutException as e:
                # Mid-stream read timeout: the status line is gone; the row and the metric say 504.
                log.warning("upstream-timeout %s session=%s mid-stream: %s", row.rail, row.id, type(e).__name__)
                final[0] = 504
                raise
            finally:
                await resp.aclose()
                elapsed = time.monotonic() - t0
                usage = (parse_usage(decoded(bytes(captured), resp.headers.get("content-encoding")), streaming)
                         if final[0] < 300 else Usage())
                self.metrics.request(row.rail, dialect, final[0], elapsed)
                self.metrics.tokens(row.rail, usage)
                self.sessions.store.record_request(row.id, final[0], int(elapsed * 1000), usage,
                                                  ts=self.sessions.clock())  # the window-draw ledger's clock
                log.info("%s rail=%s session=%s status=%d ms=%d in=%d cache_read=%d cache_write=%d out=%d [%s]",
                         dialect, row.rail, row.id, final[0], int(elapsed * 1000), usage.tokens_in,
                         usage.tokens_cache_read, usage.tokens_cache_write, usage.tokens_out, note)

        return StreamingResponse(body_iter(), status_code=status, headers=out_headers)


# -- Starlette endpoints ------------------------------------------------------------------------

async def anthropic_messages(request: Request) -> Response:
    return await request.app.state.proxy.forward(request, "anthropic", "messages")


async def openai_chat(request: Request) -> Response:
    return await request.app.state.proxy.forward(request, "openai", "chat")


async def openai_models(request: Request) -> Response:
    return await request.app.state.proxy.forward(request, "openai", "models")
