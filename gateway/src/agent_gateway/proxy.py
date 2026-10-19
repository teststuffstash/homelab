"""The data plane: streaming passthrough with httpx (GW-MODEL-RESOLVE, GW-CRED-BOUNDARY, GW-RAIL-*).

Per request: authenticate the session token → check the rail serves the dialect → check the
body's `model` against the session's (403 `model-not-session`; absent = filled with the wire id;
on the anthropic rail the body is forwarded untouched after a family match) → resolve + inject
the credential → stream the upstream bytes back unchanged (SSE included) → record usage.
Typed errors (specs/endpoints/*.schema.json `errors`): 401 session-unknown / -expired /
-released / credential-unresolved, 403 model-not-session, 501 dialect-unsupported-on-rail,
503 credential-transient, 424 upstream-auth (an upstream 401/403 with a credential reason — 4xx so
no harness retries it; the credential is marked rejected), 403 upstream-refused (an upstream 403
that is a policy refusal, not a credential verdict), 502 upstream-unreachable (a connect failure
that is not a timeout), 502 header-refused (the credential-shaped header tripwire), 504
upstream-timeout. Upstream 429 passes through with `retry-after` and cools the session's cell.
A 200 whose stream ends without its terminal event is recorded INCOMPLETE (GW-RAIL-*), never a
clean 200.
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
from .providers import UNATTRIBUTED, Endpoint, attribute, pin, provider_error
from .sessions import SessionService, error
from .store import Session, Usage

log = logging.getLogger("gateway.proxy")

USAGE_CAPTURE_MAX = 4 * 1024 * 1024  # bytes of response kept for the best-effort usage parse
DEFAULT_RETRY_AFTER = "30"
ERROR_BODY_MAX = 64 * 1024  # an upstream 401/403 body is read (never relayed) to classify it

# An upstream 401 is always a credential verdict. A 403 is one ONLY when its JSON error object names
# a credential reason. A 403 with a JSON error object that names none is a POLICY refusal (the
# upstream refused this model/request — OpenRouter's "only available on agentic harnesses", the
# 2026-10-17 experiment). A 403 with NO readable JSON error object (an HTML / plain-text page, a
# Cloudflare `error code: 1010`) is an EDGE refusal: a proxy in front of the vendor judged THIS
# request's client signature, which says nothing about the key (2026-10-17: a Python-urllib caller's
# 403 1010 was read as a credential verdict and self-latched the Go rail until a restart) ⚖.
CREDENTIAL_ERROR_TYPES = frozenset({"authentication_error", "permission_error"})
CREDENTIAL_ERROR_CODES = frozenset({"api_key_expired", "invalid_api_key", "unauthorized", "invalid_x_api_key"})
# The terminal event of a complete stream, per dialect (decoded bytes): openai `data: [DONE]`,
# anthropic `message_stop`.
TERMINAL_MARKERS = {"openai": (b"[DONE]",), "anthropic": (b"message_stop",)}
# A 2xx body the dialect can read: JSON, or SSE for a stream. Anything else on a PINNED attempt (an
# edge's HTML page behind a 200) is a pre-byte transport failure the gateway fails over on.
BODY_TYPES = ("application/json", "text/event-stream")
# The pre-byte failure classes (GW-RAIL-OPENROUTER §Failover): outcome label → the strike class the
# cell takes (None = a 429 cools the cell instead).
FAILOVER_STRIKE = {"5xx": "provider-5xx", "unreachable": "provider-5xx", "timeout": "timeout", "content-type": "provider-5xx",
                   "provider-error": "refused", "429": None}


def classify_auth_failure(status: int, body: bytes) -> str:
    """`credential` | `refused` | `edge` for an upstream 401/403 (the body is read, never relayed)."""
    if status == 401:
        return "credential"
    try:
        doc = json.loads(body)
    except ValueError:
        return "edge"
    e = doc.get("error") if isinstance(doc, dict) else None
    if not isinstance(e, dict):
        return "edge"
    if str(e.get("type") or "") in CREDENTIAL_ERROR_TYPES or str(e.get("code") or "") in CREDENTIAL_ERROR_CODES:
        return "credential"
    return "refused"


class StreamWatch:
    """Incremental completeness check over the bytes as the client sees them (gzip decoded on the
    fly, a small tail kept so a marker split across chunks is still seen) — independent of the
    usage capture's 4 MiB cap."""

    def __init__(self, dialect: str, encoding: str | None):
        self.markers = TERMINAL_MARKERS.get(dialect, ())
        enc = (encoding or "identity").strip().lower()
        self._z = zlib.decompressobj(zlib.MAX_WBITS | 32) if enc in ("gzip", "x-gzip", "deflate") else None
        self._opaque = enc not in ("identity", "gzip", "x-gzip", "deflate")
        self._tail = b""
        self.terminal = False

    def feed(self, chunk: bytes) -> None:
        if self.terminal or self._opaque or not self.markers:
            return
        if self._z is not None:
            try:
                chunk = self._z.decompress(chunk)
            except zlib.error:
                self._opaque = True
                return
        buf = self._tail + chunk
        if any(m in buf for m in self.markers):
            self.terminal = True
        self._tail = buf[-64:]

    def complete(self, streaming: bool) -> bool:
        """A non-streamed body is complete when it was read to its end; a stream needs its
        terminal event (an encoding the watch cannot read counts as complete — unknown, not broken)."""
        return (not streaming) or self._opaque or not self.markers or self.terminal


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
                row.rail, dialect, [(k.decode(), v.decode()) for k, v in request.headers.raw], credential, row.id,
                user_agent=self.sessions.policy.rails[row.rail].user_agent,
            )
        except rails.HeaderRefused as e:
            self.metrics.request(row.rail, dialect, 502)
            return error(502, "header-refused", str(e))
        if body is not None and "content-type" not in headers:
            headers["content-type"] = "application/json"
        url = rails.upstream_url(row.rail, self.upstreams[row.rail], dialect, op)
        if request.method == "GET" and request.url.query:
            url += "?" + request.url.query
        # The provider axis (GW-RAIL-OPENROUTER §Selection / §Failover): on the openrouter rail a POST
        # rides pinned to ONE provider per attempt (`provider.order` + `allow_fallbacks: false`) when the
        # endpoint snapshot covers the model; a typed failure BEFORE any byte is relayed reissues the
        # same request to the next provider, bounded by the policy; after a byte, never.
        attempts: list[Endpoint | None] = [None]
        if row.rail == "openrouter" and body is not None and row.canary_provider and self.sessions.providers is not None:
            # GW-CATALOG-OR: a canary session rides exactly its cell — pinned, no failover, whatever the cell's state
            cell = [e for e in (self.sessions.providers.endpoints(wire_model(row.rail, row.model)) or ()) if e.slug == row.canary_provider]
            if cell:
                attempts = [sorted(cell, key=lambda e: (e.service_tier is not None, len(e.tag)))[0]]
                note += f"+canary[{row.canary_provider}]"
        elif row.rail == "openrouter" and body is not None:
            verdict, plan = self.sessions.provider_plan(row.rail, row.model, row.harness, row.stack, row.task,
                                                       self.sessions.clock())
            if verdict == "pinned":
                attempts = list(plan[: self.sessions.policy.rails[row.rail].providers.max_providers_per_request])
                note += "+pin[" + ",".join(e.slug for e in attempts) + "]"
            else:
                log.info("providers: %s %s session=%s rides unpinned — %s: %s", row.rail, row.model, row.id, verdict, plan)
        wire = wire_model(row.rail, row.model)
        for i, ep in enumerate(attempts):
            last = i == len(attempts) - 1
            nxt = attempts[i + 1] if not last else None
            content = pin(body, ep.slug) if ep is not None else body
            t0 = time.monotonic()
            try:
                req = self.client.build_request(request.method, url, headers=headers, content=content)
                resp = await self.client.send(req, stream=True)
            except httpx.TimeoutException as e:
                elapsed = time.monotonic() - t0
                if ep is not None and nxt is not None:
                    self._fail_over(row, dialect, wire, ep, nxt, "timeout", 504, elapsed, {}, type(e).__name__)
                    continue
                self.metrics.request(row.rail, dialect, 504, elapsed)
                self._provider_outcome(row, wire, ep, "timeout")
                self.sessions.store.record_request(row.id, 504, int(elapsed * 1000), ts=self.sessions.clock(),
                                                   provider=ep.slug if ep else "")
                self.sessions.outcomes.transport(row, "timeout", ep.slug if ep else "")
                log.warning("upstream-timeout %s session=%s: %s", row.rail, row.id, type(e).__name__)
                return error(504, "upstream-timeout", f"rail {row.rail} upstream: {type(e).__name__}")
            except httpx.HTTPError as e:
                elapsed = time.monotonic() - t0
                if ep is not None and nxt is not None:
                    self._fail_over(row, dialect, wire, ep, nxt, "unreachable", 502, elapsed, {}, type(e).__name__)
                    continue
                self.metrics.request(row.rail, dialect, 502, elapsed)
                self._provider_outcome(row, wire, ep, "unreachable")
                self.sessions.store.record_request(row.id, 502, int(elapsed * 1000), ts=self.sessions.clock(),
                                                   provider=ep.slug if ep else "")
                self.sessions.outcomes.transport(row, "provider-5xx", ep.slug if ep else "")
                log.warning("upstream-unreachable %s session=%s: %s", row.rail, row.id, type(e).__name__)
                return error(502, "upstream-unreachable", f"rail {row.rail} upstream: {type(e).__name__}")
            status = resp.status_code
            prefetched: bytes | None = None
            if ep is not None:
                kind, prefetched = await self._prebyte_failure(resp, streaming)
                if kind is not None:
                    elapsed = time.monotonic() - t0
                    if nxt is not None:
                        await resp.aclose()
                        self._fail_over(row, dialect, wire, ep, nxt, kind, status, elapsed, resp.headers, f"upstream {status}")
                        continue
                    if kind == "content-type":  # the order exhausted on an unreadable 2xx: the typed error
                        await resp.aclose()
                        self.metrics.request(row.rail, dialect, 502, elapsed)
                        self._provider_outcome(row, wire, ep, kind)
                        self.sessions.store.record_request(row.id, 502, int(elapsed * 1000), ts=self.sessions.clock(), provider=ep.slug)
                        self.sessions.outcomes.transport(row, "provider-5xx", ep.slug)
                        log.warning("upstream-content-type %s session=%s @%s: %s", row.rail, row.id, ep.slug,
                                    resp.headers.get("content-type"))
                        return error(502, "upstream-content-type",
                                     f"rail {row.rail} provider {ep.slug} answered {status} with {resp.headers.get('content-type', '?')}, not a body this dialect reads")
                    # the last provider failed the same way: its answer passes through as the typed outcome
            break
        provider = ep.slug if ep is not None else ""
        if status in (401, 403):
            try:
                raw_err = await resp.aread()
            except httpx.HTTPError:
                raw_err = b""
            finally:
                await resp.aclose()
            elapsed = time.monotonic() - t0
            kind = classify_auth_failure(status, raw_err[:ERROR_BODY_MAX])
            if kind == "edge":
                self.metrics.request(row.rail, dialect, 403, elapsed)
                self._provider_outcome(row, wire, ep, "edge")
                self.sessions.store.record_request(row.id, 403, int(elapsed * 1000), ts=self.sessions.clock(), provider=provider)
                log.warning("upstream-edge-refused %s %d session=%s — a non-JSON refusal (an edge judged this request's client), "
                            "no credential verdict [%s]", row.rail, status, row.id, note)
                return error(403, "upstream-edge-refused",
                             f"an edge in front of rail {row.rail} refused this request (upstream {status}, not a credential verdict)")
            if kind == "refused":
                self.metrics.request(row.rail, dialect, 403, elapsed)
                self._provider_outcome(row, wire, ep, "refused")
                self.sessions.store.record_request(row.id, 403, int(elapsed * 1000), ts=self.sessions.clock(), provider=provider)
                self.sessions.outcomes.transport(row, "refused", provider)
                log.warning("upstream-refused %s %d session=%s model=%s [%s]", row.rail, status, row.id, row.model, note)
                return error(403, "upstream-refused", f"rail {row.rail} refused this request for {row.model} (upstream {status}, a policy refusal — not the credential)")
            self.metrics.request(row.rail, dialect, 424, elapsed)
            self.metrics.upstream_auth_rejected(row.rail)
            self._provider_outcome(row, wire, ep, "auth")
            self.sessions.store.record_request(row.id, 424, int(elapsed * 1000), ts=self.sessions.clock(), provider=provider)
            self.sessions.capacity.reject_credential(row.rail, credential, self.sessions.clock(), row.stack)
            self.sessions.outcomes.transport(row, "auth-storm", provider)
            log.error("upstream-auth %s %d session=%s [%s]", row.rail, status, row.id, note)
            return error(424, "upstream-auth", f"rail {row.rail} rejected the gateway's credential (upstream {status}) — not retryable")
        if row.rail == "anthropic":
            self.metrics.subscription_windows(row.rail, resp.headers)
        note += self.sessions.capacity.observe(row.rail, status, resp.headers, self.sessions.clock(),
                                               model=row.model, credential=credential, provider=provider)
        out_headers = rails.response_headers(resp.headers.multi_items())
        if status == 429 and "retry-after" not in {k.lower() for k in out_headers}:
            out_headers["retry-after"] = DEFAULT_RETRY_AFTER
        return self._stream(resp, row, dialect, status, out_headers, streaming, t0, note, ep, wire, prefetched)

    @staticmethod
    async def _prebyte_failure(resp: httpx.Response, streaming: bool) -> tuple[str | None, bytes | None]:
        """A pinned attempt's answer, judged before any byte is relayed (GW-RAIL-OPENROUTER §Failover):
        `5xx`, `429`, `content-type` (a 2xx the dialect cannot read), `provider-error` (a 4xx whose JSON
        error names the provider that produced it — a refused tool call among them); None = relay it.
        A 4xx body is read to classify it; it comes back so the relay can still send it."""
        status = resp.status_code
        if status >= 500:
            return "5xx", None
        if status == 429:
            return "429", None
        ctype = (resp.headers.get("content-type") or "").split(";")[0].strip().lower()
        if 200 <= status < 300:
            return (None if ctype in BODY_TYPES else "content-type"), None
        if status in (401, 403):
            return None, None  # the credential / refusal / edge classification below owns these
        try:
            raw = await resp.aread()
        except httpx.HTTPError:
            raw = b""
        return ("provider-error" if provider_error(raw[:ERROR_BODY_MAX]) else None), raw

    def _fail_over(self, row: Session, dialect: str, wire: str, ep: Endpoint, nxt: Endpoint, kind: str, status: int,
                   elapsed: float, headers, why: str) -> None:
        """Record the failed attempt on its cell — the request row, the strike (or the cooldown for a
        429), the two families — and move on; the harness sees nothing of it."""
        now = self.sessions.clock()
        self.sessions.store.record_request(row.id, status, int(elapsed * 1000), ts=now, provider=ep.slug)
        self._provider_outcome(row, wire, ep, kind)
        klass = FAILOVER_STRIKE[kind]
        if klass is None:
            self.sessions.capacity.observe(row.rail, 429, headers, now, model=row.model, provider=ep.slug)
        else:
            self.sessions.outcomes.transport(row, klass, ep.slug)
        self.metrics.failover(wire, ep.slug, nxt.slug)
        log.warning("failover %s %s session=%s: %s → %s (%s: %s)", row.rail, wire, row.id, ep.slug, nxt.slug, kind, why)

    def _provider_outcome(self, row: Session, wire: str, ep: Endpoint | None, outcome: str, attributed: str | None = None) -> None:
        """`gateway_provider_requests_total` — the openrouter rail only; the cell's provider is the
        attributed slug, else the pin, else `unattributed`."""
        if row.rail != "openrouter":
            return
        self.metrics.provider_request(row.rail, wire, attributed or (ep.slug if ep else UNATTRIBUTED), outcome)

    async def reprobe(self) -> int:
        """Re-verify every rejected credential whose probe is due (sessions.md §Capacity): re-resolve it
        through the stack that saw it (a changed value = a new credential → cleared), then send the
        rail's policy `credential_probe` with it. 2xx → cleared; a credential verdict → backoff
        doubles; anything else (5xx, an edge refusal, unreachable) → no verdict, retried at the same
        backoff. Returns the number of probes sent."""
        cap = self.sessions.capacity
        now = self.sessions.clock()
        sent = 0
        for rail, fp, mark in cap.due_probes(now):
            stack = self.sessions.policy.stacks.get(mark.stack)
            if stack is None:
                cap.clear_credential(rail, fp, "its stack left the policy")
                continue
            try:
                credential = await self.sessions.resolver.resolve(rail, stack)
            except CredentialUnresolved:
                cap.clear_credential(rail, fp, "the ref no longer resolves (admission says credential-unresolved)")
                continue
            except CredentialTransient:
                cap.probe_result(rail, fp, None, now)
                continue
            from .capacity import fingerprint
            if fingerprint(credential) != fp:
                cap.clear_credential(rail, fp, "the credential changed")
                continue
            probe = self.sessions.policy.rails[rail].credential_probe
            dialect = "anthropic" if rail == "anthropic" else "openai"
            headers, _ = rails.build_headers(rail, dialect, [], credential, "gateway-credential-probe",
                                             user_agent="fixed")
            ok: bool | None = None
            try:
                resp = await self.client.request(probe.method, self.upstreams[rail] + probe.path, headers=headers,
                                                 json=probe.body if probe.method == "POST" else None, timeout=20)
                sent += 1
                if 200 <= resp.status_code < 300:
                    ok = True
                elif resp.status_code in (401, 403) and classify_auth_failure(resp.status_code, resp.content[:ERROR_BODY_MAX]) == "credential":
                    ok = False
            except httpx.HTTPError:
                ok = None
            self.metrics.credential_probe(rail, {True: "cleared", False: "rejected", None: "inconclusive"}[ok])
            cap.probe_result(rail, fp, ok, now)
        return sent

    def _stream(self, resp: httpx.Response, row: Session, dialect: str, status: int, out_headers: dict,
                streaming: bool, t0: float, note: str, ep: Endpoint | None = None, wire: str = "",
                prefetched: bytes | None = None) -> StreamingResponse:
        captured = bytearray()
        final = [status]  # what the row and the metric record; a mid-stream timeout rewrites it to 504
        # A body already read (a 4xx classified before the relay) is DECODED: it goes out as identity.
        encoding = None if prefetched is not None else resp.headers.get("content-encoding")
        if prefetched is not None:
            for k in [k for k in out_headers if k.lower() == "content-encoding"]:
                del out_headers[k]
        watch = StreamWatch(dialect, encoding)
        cut: list[str] = []  # why the body stopped before its end: timeout | transport-error | client-closed

        async def body_iter():
            try:
                if prefetched is not None:
                    captured.extend(prefetched[:USAGE_CAPTURE_MAX])
                    watch.feed(prefetched)
                    yield prefetched
                    return
                async for chunk in resp.aiter_raw():
                    if len(captured) < USAGE_CAPTURE_MAX:
                        captured.extend(chunk)
                    watch.feed(chunk)
                    yield chunk
            except httpx.TimeoutException as e:
                # Mid-stream read timeout: the status line is gone; the row and the metric say 504.
                log.warning("upstream-timeout %s session=%s mid-stream: %s", row.rail, row.id, type(e).__name__)
                final[0] = 504
                cut.append("timeout")
                raise
            except httpx.HTTPError as e:
                log.warning("upstream-transport-error %s session=%s mid-stream: %s", row.rail, row.id, type(e).__name__)
                cut.append("transport-error")
                raise
            except BaseException:  # the client went away (the task is cancelled) — the stream never ended
                cut.append("client-closed")
                raise
            finally:
                await resp.aclose()
                elapsed = time.monotonic() - t0
                plain = decoded(bytes(captured), encoding)
                usage = parse_usage(plain, streaming) if final[0] < 300 else Usage()
                # Attribution (GW-RAIL-OPENROUTER): the answer's own `provider` names the cell; the
                # snapshot joins the display name to the slug `provider.order` uses; a pinned attempt
                # whose answer names another provider is recorded as the answer says, and logged.
                provider = ep.slug if ep is not None else ""
                display = attribute(plain, streaming) if row.rail == "openrouter" else None
                if display and self.sessions.providers is not None:
                    attributed = self.sessions.providers.slug_for(wire, display)
                    if ep is not None and attributed != ep.slug:
                        log.warning("attribution: %s session=%s pinned %s, the answer names %s (%r)", row.rail, row.id,
                                    ep.slug, attributed, display)
                    provider = attributed
                incomplete = None
                if 200 <= status < 300:
                    if cut:
                        incomplete = cut[0]
                    elif not watch.complete(streaming):
                        incomplete = "no-terminal"
                self.metrics.request(row.rail, dialect, final[0], elapsed)
                self.metrics.tokens(row.rail, usage)
                if incomplete:
                    self.metrics.request_incomplete(row.rail, dialect, incomplete)
                # The gateway's own transport classes as strikes (GW-SESSIONS-OUTCOME): a relayed upstream
                # 5xx, a cut stream. A client that hung up is the consumer's to classify ⚖.
                if status >= 500:
                    self.sessions.outcomes.transport(row, "provider-5xx", provider)
                elif incomplete == "timeout":
                    self.sessions.outcomes.transport(row, "timeout", provider)
                elif incomplete in ("no-terminal", "transport-error"):
                    self.sessions.outcomes.transport(row, "stream-incomplete", provider)
                self._provider_outcome(row, wire, ep, ("5xx" if status >= 500 else "429" if status == 429 else
                                                       "incomplete" if incomplete else "ok" if status < 300 else
                                                       "provider-error" if provider_error(plain) else "other"),
                                       attributed=provider or None)
                self.sessions.store.record_request(row.id, final[0], int(elapsed * 1000), usage,
                                                  ts=self.sessions.clock(),  # the window-draw ledger's clock
                                                  incomplete=incomplete, provider=provider)
                log.info("%s rail=%s session=%s status=%d ms=%d in=%d cache_read=%d cache_write=%d out=%d%s%s [%s]",
                         dialect, row.rail, row.id, final[0], int(elapsed * 1000), usage.tokens_in,
                         usage.tokens_cache_read, usage.tokens_cache_write, usage.tokens_out,
                         f" provider={provider}" if provider else "",
                         f" INCOMPLETE={incomplete}" if incomplete else "", note)

        return StreamingResponse(body_iter(), status_code=status, headers=out_headers)


# -- Starlette endpoints ------------------------------------------------------------------------

async def anthropic_messages(request: Request) -> Response:
    return await request.app.state.proxy.forward(request, "anthropic", "messages")


async def openai_chat(request: Request) -> Response:
    return await request.app.state.proxy.forward(request, "openai", "chat")


async def openai_models(request: Request) -> Response:
    return await request.app.state.proxy.forward(request, "openai", "models")
