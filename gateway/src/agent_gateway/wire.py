"""The wire record (GW-WIRE-RECORD) and its read-only door (GW-WIRE-VIEW; specs/endpoints/wire.md).

Every vendor read the gateway makes keeps its LATEST answer per source in the gateway's own store —
recorded BEFORE the parser sees it, so a shape the parser refuses is still on file. Two classes:

- `public` — the read sent no credential and no account header: the bytes are kept verbatim.
- `account` — anything else: sanitised structurally BEFORE persistence (capture.py's manner: structure,
  key names, numbers, booleans and nulls stay; every string becomes `{"len": n}`).

The class is decided here, not by the caller's say-so: a source declared `account` is account, and a
read whose sent headers carry a credential or an account header is account whatever its source says.
An answer that echoes a credential the gateway holds is withheld whole. Never a credential in, none
out: the door reads the store and nothing else. Latest answer only — no history. The recorder never
takes a read down: a fault is logged and the read goes on.
"""

from __future__ import annotations

import hashlib
import json
import logging
from collections.abc import Iterable, Mapping

from starlette.requests import Request
from starlette.responses import JSONResponse, Response

from .store import Store, iso

log = logging.getLogger("gateway.wire")

PUBLIC, ACCOUNT = "public", "account"
# Every vendor read the gateway makes registers its source name and class here (GW-WIRE-RECORD).
SOURCES: dict[str, str] = {
    "go-models-dev": PUBLIC,            # models.dev api.json — no header beyond the User-Agent
    "go-console-config": ACCOUNT,       # the Go console's V2 config — the Go key as a bearer
    "go-docs": PUBLIC,                  # the vendor's Go page source
    "openrouter-endpoints": PUBLIC,     # /v1/models/<id>/endpoints — the latest model's answer
    "openrouter-mcp-rankings": ACCOUNT,   # MCP tools/call list-daily-model-rankings — the account key
    "openrouter-mcp-benchmarks": ACCOUNT,  # MCP tools/call list-benchmarks — the account key
    "codex-usage": ACCOUNT,             # the account usage poll — bearer + chatgpt-account-id
}
CREDENTIAL_HEADERS = frozenset({"authorization", "proxy-authorization", "x-api-key", "api-key", "cookie",
                                "chatgpt-account-id", "openai-organization"})
DEFAULT_MAX_BYTES = 1_048_576
MAX_DEPTH = 64


def sanitise(value, depth: int = 0):
    """Structure kept; every string becomes its length (a depth past the bound collapses to its type)."""
    if isinstance(value, bool) or value is None or isinstance(value, (int, float)):
        return value
    if isinstance(value, str):
        return {"len": len(value)}
    if depth >= MAX_DEPTH:
        return {"len": 0}
    if isinstance(value, dict):
        return {str(k): sanitise(v, depth + 1) for k, v in value.items()}
    if isinstance(value, list):
        return [sanitise(v, depth + 1) for v in value]
    return {"len": 0}


def _json(value) -> bytes:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


class WireRecorder:
    def __init__(self, store: Store, clock, max_bytes: int = DEFAULT_MAX_BYTES, secrets: Iterable[str] = ()):
        self.store, self.clock, self.max_bytes = store, clock, max_bytes
        self.secrets = [s for s in secrets if s]

    def class_of(self, source: str, sent_headers: Mapping[str, str] | None) -> str:
        cls = SOURCES[source]
        if cls == PUBLIC and any(k.lower() in CREDENTIAL_HEADERS for k in (sent_headers or {})):
            return ACCOUNT  # a read that carried a credential is never public
        return cls

    def record(self, source: str, url: str, status: int | None, body: bytes | None, sent_headers: Mapping[str, str] | None = None,
               content_type: str = "", truncated: bool = False, secrets: Iterable[str] = ()) -> None:
        """One read's answer: `status` None = unreachable. Never raises."""
        try:
            self._record(source, url, status, body, sent_headers, content_type, truncated, secrets)
        except Exception:  # noqa: BLE001 — the recorder never takes a read down
            log.exception("wire: recording %s failed", source)

    def _record(self, source, url, status, body, sent_headers, content_type, truncated, secrets) -> None:
        cls = self.class_of(source, sent_headers)
        now = self.clock()
        url = url.split("@", 1)[-1] if "@" in url.split("?", 1)[0] else url
        if status is None:
            self.store.wire_fail(source, cls, url, "unreachable", now)
            return
        if status != 200 or body is None:
            self.store.wire_fail(source, cls, url, f"status {status}", now)
            return
        held = [*self.secrets, *[s for s in secrets if s]]
        if any(s.encode("utf-8") in body for s in held):
            log.warning("wire: %s answer echoes a held credential — withheld", source)
            self.store.wire_fail(source, cls, url, "withheld", now)
            return
        sha = hashlib.sha256(body).hexdigest()  # the answer as the vendor sent it (an account answer's identity, never its bytes)
        complete = not truncated
        if len(body) > self.max_bytes:
            body, complete = body[: self.max_bytes], False
        if cls == ACCOUNT:
            if not complete:
                self.store.wire_fail(source, cls, url, "over-bound", now)  # a cut document has no structure to keep
                return
            try:
                stored = _json(sanitise(json.loads(body)))
            except ValueError:
                stored = _json({"len": len(body)})
            content_type = "application/json"
        else:
            stored = body
        self.store.wire_ok(source, cls, url, status, content_type or "application/octet-stream", stored, sha, now, complete)


def _provenance(row: dict, now: float) -> dict:
    return {"source": row["source"], "class": row["class"], "url": row["url"], "status": row["status"],
            "bytes": row["bytes"], "sha256": row["sha256"], "fetched_at": iso(row["fetched_at"]),
            "age_s": None if row["fetched_at"] is None else max(0, int(now - row["fetched_at"])),
            "complete": bool(row["complete"]) if row["fetched_at"] is not None else None,
            "last_error": row["last_error"], "last_error_at": iso(row["last_error_at"])}


def _not_recorded(source: str) -> JSONResponse:
    return JSONResponse({"error": {"code": "wire-not-recorded", "message": f"no answer is recorded for {source}"}}, status_code=404)


async def wire_index(request: Request) -> JSONResponse:
    """GET /wire — every source's provenance, no body, no credential."""
    now = request.app.state.sessions.clock()
    rows = request.app.state.store.wire_all()
    return JSONResponse({"sources": [_provenance(r, now) for r in rows]})


async def wire_member(request: Request) -> Response:
    """GET /wire/<source> — the stored bytes, the provenance in `x-wire-*` headers."""
    source = request.path_params["source"]
    row = request.app.state.store.wire_get(source)
    if row is None or row["fetched_at"] is None:
        return _not_recorded(source)
    return Response(row["body"], media_type=row["content_type"], headers={
        "x-wire-source": row["source"], "x-wire-class": row["class"], "x-wire-sha256": row["sha256"],
        "x-wire-fetched-at": iso(row["fetched_at"]), "x-wire-complete": "true" if row["complete"] else "false"})
