"""The data plane: streaming passthrough with httpx (GW-MODEL-RESOLVE, GW-CRED-BOUNDARY, GW-RAIL-*).

Per request: authenticate the session token → check the rail serves the dialect → check the
body's `model` against the session's (403 `model-not-session`; absent = filled with the wire id;
on the anthropic rail the body is forwarded untouched after a family match) → resolve + inject
the credential → stream the upstream bytes back unchanged (SSE included) → record usage.
Typed errors (specs/endpoints/*.schema.json `errors`): 401 session-unknown / -expired /
-released / credential-unresolved, 403 model-not-session, 501 dialect-unsupported-on-rail,
503 credential-transient, 502 upstream-auth, 504 upstream-timeout — plus two the schemas do not
list yet: 502 upstream-unreachable (connect error) and 502 header-refused (the credential-shaped
header tripwire). Upstream 429 passes through with `retry-after`.
"""

from __future__ import annotations

import json
import logging
import time

import httpx
from starlette.requests import Request
from starlette.responses import Response, StreamingResponse

from . import rails
from .config import model_matches, wire_model
from .credentials import CredentialTransient, CredentialUnresolved
from .metrics import Metrics
from .sessions import SessionService, error
from .store import Session

log = logging.getLogger("gateway.proxy")

USAGE_CAPTURE_MAX = 4 * 1024 * 1024  # bytes of response kept for the best-effort usage parse
DEFAULT_RETRY_AFTER = "30"


def inbound_token(request: Request) -> str | None:
    """The bearer is consulted first; `x-api-key` second (GW-CRED-BOUNDARY)."""
    auth = request.headers.get("authorization", "")
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    return request.headers.get("x-api-key") or None


def parse_usage(body: bytes, streaming: bool) -> tuple[int, int]:
    """Best-effort (input, output) token counts from a JSON or SSE response body; (0, 0) if unclear."""
    if not body:
        return 0, 0
    tokens_in = tokens_out = 0
    try:
        if not streaming:
            doc = json.loads(body)
            u = doc.get("usage") or {}
            tokens_in = int(u.get("input_tokens") or u.get("prompt_tokens") or 0)
            tokens_out = int(u.get("output_tokens") or u.get("completion_tokens") or 0)
            return tokens_in, tokens_out
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
            # Anthropic: message_start carries input_tokens, message_delta the final output_tokens.
            msg_usage = (ev.get("message") or {}).get("usage")
            if msg_usage:
                tokens_in = int(msg_usage.get("input_tokens") or 0) or tokens_in
            u = ev.get("usage")
            if u:
                tokens_in = int(u.get("input_tokens") or u.get("prompt_tokens") or 0) or tokens_in
                tokens_out = int(u.get("output_tokens") or u.get("completion_tokens") or 0) or tokens_out
    except (ValueError, AttributeError, TypeError):
        return 0, 0
    return tokens_in, tokens_out


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
            elif not isinstance(asked, str) or not model_matches(row.rail, row.model, asked):
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
            self.sessions.store.record_request(row.id, 504, int(elapsed * 1000), 0, 0)
            log.warning("upstream-timeout %s session=%s: %s", row.rail, row.id, type(e).__name__)
            return error(504, "upstream-timeout", f"rail {row.rail} upstream: {type(e).__name__}")
        except httpx.HTTPError as e:
            self.metrics.request(row.rail, dialect, 502, time.monotonic() - t0)
            log.warning("upstream-unreachable %s session=%s: %s", row.rail, row.id, type(e).__name__)
            return error(502, "upstream-unreachable", f"rail {row.rail} upstream: {type(e).__name__}")
        status = resp.status_code
        if status in (401, 403):
            await resp.aclose()
            elapsed = time.monotonic() - t0
            self.metrics.request(row.rail, dialect, 502, elapsed)
            self.sessions.store.record_request(row.id, 502, int(elapsed * 1000), 0, 0)
            log.error("upstream-auth %s %d session=%s [%s]", row.rail, status, row.id, note)
            return error(502, "upstream-auth", f"rail {row.rail} rejected the gateway's credential (upstream {status})")
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
                tokens_in, tokens_out = parse_usage(bytes(captured), streaming) if final[0] < 300 else (0, 0)
                self.metrics.request(row.rail, dialect, final[0], elapsed)
                self.metrics.tokens(row.rail, tokens_in, tokens_out)
                self.sessions.store.record_request(row.id, final[0], int(elapsed * 1000), tokens_in, tokens_out)
                log.info("%s rail=%s session=%s status=%d ms=%d in=%d out=%d [%s]", dialect, row.rail, row.id,
                         final[0], int(elapsed * 1000), tokens_in, tokens_out, note)

        return StreamingResponse(body_iter(), status_code=status, headers=out_headers)


# -- Starlette endpoints ------------------------------------------------------------------------

async def anthropic_messages(request: Request) -> Response:
    return await request.app.state.proxy.forward(request, "anthropic", "messages")


async def openai_chat(request: Request) -> Response:
    return await request.app.state.proxy.forward(request, "openai", "chat")


async def openai_models(request: Request) -> Response:
    return await request.app.state.proxy.forward(request, "openai", "models")
