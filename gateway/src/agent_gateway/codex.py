"""The codex rail (GW-RAIL-CODEX, GW-CODEX-HEADROOM, GW-CODEX-OAUTH) — the ChatGPT subscription,
spoken by the `codex` harness in the `responses` dialect at `POST /openai/v1/responses`.

Lit 2026-10-22 (FU-270) as the explicit canary cell: the deployed policy declares the rail for the
`prober` role only (last in its list — only `harness: codex` speaks responses, so nothing lands on it
by default). `create_app` wires a backend only when it is handed a credential `Store` + refresh
`exchange` AND `CODEX_UPSTREAM` is set — production: the SQLite store seeded from the gateway's own
login (`devbox run codex-seed`), the native refresh. Without a backend the rail is a definitive
credential miss: admission skips it (`credential-unresolved`) and the data plane answers 401
`credential-unresolved`.

Per admission (`SessionService.admit`, on the codex rail): backend present → headroom verdict →
the lifecycle's durable state. Per request: session → dialect → body (model, mode, input) →
`Lifecycle.acquire()` (off the event loop: the store lock may wait on another owner's refresh) →
the allowlisted upstream headers → stream with the bounded parser → one accounting record.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from collections.abc import Callable
from dataclasses import dataclass

import httpx
from starlette.requests import Request
from starlette.responses import Response, StreamingResponse

from . import responses
from .config import RailPolicy, model_matches, wire_model
from .headroom import Headroom, Verdict
from .metrics import Metrics
from .oauth import Code, Credential, Failure, Lifecycle, Store
from .proxy import inbound_token  # one token rule for every dialect (GW-CRED-BOUNDARY)
from .sessions import SessionService, error
from .store import Usage
from .turn_state import HEADER, TurnStates

log = logging.getLogger("gateway.codex")

DIALECT = "responses"
UPSTREAM_PATH = "/responses"

# Lifecycle failure → data-plane answer. A store that does not answer may answer next time (503,
# retry); every other code is a durable state only an operator act changes (401, typed).
FAILURE_STATUS = {Code.STORE: 503, Code.RECOVERY: 401, Code.REVOKED: 401, Code.REFRESH: 401, Code.INVALID: 401}
# The live-canary capture (spike §Recorded live protocol experiment, the "upstream response received"
# boundary): a 200 that is not an event stream, or a typed non-2xx, is the vendor telling us something
# the fixtures never saw — the first live ride (2026-10-22 21:54Z) answered 200 with a non-SSE body and
# the log said only "upstream 200". Bounded read, response header NAMES only, a short preview with
# non-printables escaped; the formatter (GW-REDACT) scrubs the rendered line, so no credential shape
# survives even if the vendor echoed one. Never the request, never a stream (a 200 SSE is relayed, not read).
PREVIEW_BYTES = 512
PREVIEW_READ_BYTES = 4096
# Stream outcome → the status the request row and gateway_requests_total record. The client got
# 200 + bytes in every case; a broken stream is recorded as the gateway's 502, a client that went
# away as 499 (⚖ GW-RAIL-CODEX).
OUTCOME_STATUS = {"completed": 200, "failed": 200, "incomplete": 200, "truncated": 502,
                  "protocol-error": 502, "transport-error": 502, "cancelled": 499, "pending": 499}


@dataclass(frozen=True)
class CodexBackend:
    """What production does not have yet: the credential store and the refresh exchange."""
    store: Store
    exchange: Callable[[Credential], Credential]


class CodexRail:
    def __init__(self, policy: RailPolicy, clock: Callable[[], float], backend: CodexBackend | None, upstream: str):
        assert policy.headroom is not None and policy.refresh_margin_s is not None  # config._codex_policy
        self.policy = policy
        self.headroom = Headroom(clock, policy.headroom)
        self.upstream = upstream
        self.lifecycle = (Lifecycle(backend.store, backend.exchange, clock, policy.refresh_margin_s)
                          if backend is not None and upstream else None)
        if self.lifecycle is None:
            log.warning("codex rail declared but dark: %s", "no credential store wired (gap: production write-back)"
                        if backend is None else "CODEX_UPSTREAM unset (gap: upstream profile unselected)")

    def admission(self, default_retry_s: int) -> tuple[str, int] | None:
        """None = admissible now; else (reason, retry_after_s). `credential-unresolved` and
        `credential-transient` are the credential classes GW-CRED-RESOLVE already names."""
        if self.lifecycle is None:
            return "credential-unresolved", default_retry_s
        verdict = self.headroom.verdict()
        if verdict != Verdict.ADMIT:
            return verdict.value, self.headroom.retry_after(default_retry_s)
        code = self.lifecycle.status()
        if code is Code.STORE:
            return "credential-transient", default_retry_s
        if code is not None:
            log.warning("codex: credential %s — not admissible", code.value)
            return "credential-unresolved", default_retry_s
        return None


def usage_of(obs: responses.Observation) -> Usage:
    """The four classes from a Responses usage: `input_tokens` INCLUDES `cached_tokens`, so `in` =
    the difference; no cache-write class exists on this wire. Unknown input → nothing counted."""
    if obs.input_tokens is None:
        return Usage(tokens_out=obs.output_tokens or 0)
    cached = min(obs.cached_tokens or 0, obs.input_tokens)
    return Usage(tokens_in=obs.input_tokens - cached, tokens_cache_read=cached, tokens_out=obs.output_tokens or 0)


async def _preview(resp: httpx.Response) -> str:
    """At most PREVIEW_READ_BYTES of a refused answer's body, rendered as PREVIEW_BYTES of printable
    text (non-printables escaped) with a `…(+N bytes)` tail when cut. Read errors yield `<unreadable>`."""
    try:
        body = bytearray()
        async for chunk in resp.aiter_bytes():
            body += chunk
            if len(body) >= PREVIEW_READ_BYTES:
                break
    except httpx.HTTPError:
        return "<unreadable>"
    text = bytes(body[:PREVIEW_BYTES]).decode("utf-8", "replace")
    text = "".join(c if c.isprintable() else f"\\x{ord(c):02x}" for c in text)
    return text + (f"…(+{len(body) - PREVIEW_BYTES} bytes)" if len(body) > PREVIEW_BYTES else "")


class CodexProxy:
    def __init__(self, sessions: SessionService, metrics: Metrics, rail: CodexRail | None, client: httpx.AsyncClient):
        self.sessions, self.metrics, self.rail, self.client = sessions, metrics, rail, client
        self.turn_states = TurnStates()

    def _refuse(self, rail: str, status: int, code: str, message: str, headers: dict | None = None) -> Response:
        self.metrics.request(rail, DIALECT, status)
        return error(status, code, message, headers)

    async def forward(self, request: Request) -> Response:
        row, code = self.sessions.authenticate(inbound_token(request))
        if code:
            log.info("%s %s → 401 %s", request.method, request.url.path, code)
            return self._refuse("none", 401, code, "session token unknown, expired or released")
        assert row is not None
        if row.rail != "codex":
            return self._refuse(row.rail, 501, "dialect-unsupported-on-rail", f"rail {row.rail} does not serve the responses dialect")
        raw = await request.body()
        try:
            doc = json.loads(raw) if raw else None
        except ValueError:
            doc = None
        if not isinstance(doc, dict):
            return self._refuse(row.rail, 400, "malformed-body", "body must be a JSON object")
        wire = wire_model(row.rail, row.model)
        asked = doc.get("model")
        if asked is None:
            doc["model"] = wire
            raw = json.dumps(doc, separators=(",", ":")).encode()
        elif not isinstance(asked, str) or not model_matches(row.rail, row.model, asked):
            log.warning("model-not-session: session=%s asked=%s session_model=%s", row.id, asked, row.model)
            return self._refuse(row.rail, 403, "model-not-session", f"this session rides {row.model}")
        try:
            responses.check_body(doc)
        except responses.Refused as e:
            return self._refuse(row.rail, 400, str(e), "the codex rail serves streaming Responses with store=false and array input")
        if self.rail is None or self.rail.lifecycle is None:
            self.metrics.credential(row.rail, "definitive")
            return self._refuse(row.rail, 401, "credential-unresolved", "the codex rail has no credential backend")
        try:
            credential = await asyncio.to_thread(self.rail.lifecycle.acquire)
        except Failure as f:
            self.metrics.credential(row.rail, "transient" if f.code is Code.STORE else "definitive")
            log.warning("codex: credential %s session=%s", f.code.value, row.id)
            return self._refuse(row.rail, FAILURE_STATUS[f.code], f.code.value, f"the codex credential is not usable: {f.code.value}",
                                headers={"retry-after": str(self.sessions.policy.defer_retry_s)} if f.code is Code.STORE else None)
        self.metrics.credential(row.rail, "resolved")
        try:
            headers = responses.upstream_headers(credential.access_token, credential.account_id)
        except responses.Refused:
            return self._refuse(row.rail, 401, "credential-invalid", "the codex credential is not usable: credential-invalid")
        try:
            turn_key = self.turn_states.request(row.id, credential.account_id, doc, request.headers.get(HEADER))
        except ValueError:
            return self._refuse(row.rail, 400, "turn-state-invalid", "routing state is not bound to this session and turn")
        if request.headers.get(HEADER) is not None:
            headers[HEADER] = request.headers[HEADER]
        del credential
        t0 = time.monotonic()
        try:
            req = self.client.build_request("POST", self.rail.upstream + UPSTREAM_PATH, headers=headers, content=raw)
            resp = await self.client.send(req, stream=True)
        except httpx.TimeoutException as e:
            return self._upstream_error(row, 504, "upstream-timeout", type(e).__name__, t0)
        except httpx.HTTPError as e:
            return self._upstream_error(row, 502, "upstream-unreachable", type(e).__name__, t0)
        status = resp.status_code
        refusal = responses.http_failure(status)
        ctype = resp.headers.get("content-type", "").split(";")[0].strip()
        if refusal is None and status == 200 and ctype != "text/event-stream":
            refusal = "upstream-content-type"
        if refusal:
            # An auth refusal's body is never read (GW-RAIL-CODEX: 401/403 never relay a body — not into a log either).
            preview = await _preview(resp) if refusal != "upstream-auth" else "<not read: auth>"
            await resp.aclose()
            log.error("%s codex %d session=%s content-type=%r length=%s headers=[%s] body=%r", refusal, status, row.id,
                      ctype, resp.headers.get("content-length", "?"), ",".join(sorted(set(resp.headers.keys()))), preview)
            if refusal == "upstream-auth":
                self.metrics.upstream_auth_rejected(row.rail)
            return self._upstream_error(row, 502, refusal, f"upstream {status}", t0)
        if status == 429:
            body = await resp.aread()
            await resp.aclose()
            elapsed = time.monotonic() - t0
            self.metrics.request(row.rail, DIALECT, 429, elapsed)
            self.sessions.store.record_request(row.id, 429, int(elapsed * 1000))
            out = {"content-type": resp.headers.get("content-type", "application/json"),
                   "retry-after": resp.headers.get("retry-after", "30")}
            return Response(body, status_code=429, headers=out)
        state = self.turn_states.response(row.id, turn_key, resp.headers.get(HEADER))
        return self._stream(resp, row, t0, {HEADER: state} if state else {})

    def _upstream_error(self, row, status: int, code: str, detail: str, t0: float) -> Response:
        elapsed = time.monotonic() - t0
        self.metrics.request(row.rail, DIALECT, status, elapsed)
        self.sessions.store.record_request(row.id, status, int(elapsed * 1000))
        log.warning("%s codex session=%s: %s", code, row.id, detail)
        return error(status, code, f"rail codex upstream: {detail}")

    def _stream(self, resp: httpx.Response, row, t0: float, headers: dict) -> StreamingResponse:
        obs = responses.Observation()
        closed = [False]

        async def close():
            if not closed[0]:
                closed[0] = True
                await resp.aclose()
                elapsed = time.monotonic() - t0
                status = OUTCOME_STATUS[obs.outcome]
                usage = usage_of(obs)
                self.metrics.request(row.rail, DIALECT, status, elapsed)
                self.metrics.tokens(row.rail, usage)
                self.sessions.store.record_request(row.id, status, int(elapsed * 1000), usage)
                log.info("responses rail=codex session=%s outcome=%s status=%d ms=%d in=%d cache_read=%d out=%d",
                         row.id, obs.outcome, status, int(elapsed * 1000), usage.tokens_in, usage.tokens_cache_read,
                         usage.tokens_out)

        return StreamingResponse(responses.relay(resp.aiter_raw(), obs, close), status_code=200,
                                 media_type="text/event-stream", headers=headers)


async def openai_responses(request: Request) -> Response:
    return await request.app.state.codex_proxy.forward(request)
