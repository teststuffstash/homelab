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

GW-WIRE-PROBE: the declarations file (`GATEWAY_WIRE`) is the ONE home of a probe — a GET of a vendor
endpoint the gateway does not call yet, read through the rail's own credential lifecycle — and of the
account class's key allowlist (the string values under those keys are kept verbatim). No file, or an empty
one, means no probe and no kept string. An allowlist can never name an identity key.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import re
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass, field
from pathlib import Path

import httpx
from starlette.requests import Request
from starlette.responses import JSONResponse, Response

from .logging import redact
from .oauth import Failure
from .responses import USER_AGENT
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


def sanitise(value, depth: int = 0, keep: frozenset[str] = frozenset(), key: str | None = None):
    """Structure kept; every string becomes its length (a depth past the bound collapses to its type) —
    except a string directly under a key in `keep` (or in a list under one), kept verbatim unless it is
    credential-shaped (GW-REDACT's patterns), which stays a length."""
    if isinstance(value, bool) or value is None or isinstance(value, (int, float)):
        return value
    if isinstance(value, str):
        if key is not None and key in keep and redact(value) == value:
            return value
        return {"len": len(value)}
    if depth >= MAX_DEPTH:
        return {"len": 0}
    if isinstance(value, dict):
        return {str(k): sanitise(v, depth + 1, keep, str(k)) for k, v in value.items()}
    if isinstance(value, list):
        return [sanitise(v, depth + 1, keep, key) for v in value]
    return {"len": 0}


def _json(value) -> bytes:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


class WireRecorder:
    def __init__(self, store: Store, clock, max_bytes: int = DEFAULT_MAX_BYTES, secrets: Iterable[str] = (),
                 declarations: Declarations | None = None):
        self.store, self.clock, self.max_bytes = store, clock, max_bytes
        self.secrets = [s for s in secrets if s]
        self.declarations = declarations or Declarations()
        # A declared probe is an account source by construction; the registry is per recorder, never the module's.
        self.sources = {**SOURCES, **{name: ACCOUNT for name in self.declarations.probes}}

    def class_of(self, source: str, sent_headers: Mapping[str, str] | None) -> str:
        cls = self.sources[source]
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
                stored = _json(sanitise(json.loads(body), keep=self.declarations.keep_keys.get(source, frozenset())))
            except ValueError:
                stored = _json({"len": len(body)})
            content_type = "application/json"
        else:
            stored = body
        self.store.wire_ok(source, cls, url, status, content_type or "application/octet-stream", stored, sha, now, complete)


# ── GW-WIRE-PROBE: the declarations file ───────────────────────────────────────────────────────
class WireDeclarationError(ValueError):
    """The declarations file is malformed or names something it may not — the gateway refuses to start."""


IDENTITY_KEYS = frozenset({"email", "account_id", "accountid", "user_id", "userid", "organization_id", "org_id"})
IDENTITY_FRAGMENTS = ("token", "cookie", "secret", "password", "credential", "authorization", "email")
INFERENCE_PATHS = ("/responses", "/chat/completions", "/completions", "/messages", "/embeddings")
PROBE_RAILS = ("codex",)  # the rails whose credential lifecycle a probe can ride
PROBE_KEYS = {"rail", "path", "query", "interval_s"}
FILE_KEYS = {"probes", "keep_keys"}
NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
MIN_INTERVAL_S = 60
PROBE_TIMEOUT_S = 10.0
PROBE_OUTCOMES = ("ok", "no-credential", "fetch-failed")


def is_identity_key(key: str) -> bool:
    k = key.lower()
    return k in IDENTITY_KEYS or any(f in k for f in IDENTITY_FRAGMENTS)


@dataclass(frozen=True)
class Probe:
    name: str
    rail: str
    path: str
    query: tuple[tuple[str, str], ...]
    interval_s: int


@dataclass(frozen=True)
class Declarations:
    probes: dict[str, Probe] = field(default_factory=dict)
    keep_keys: dict[str, frozenset[str]] = field(default_factory=dict)


def _check_path(name: str, path) -> None:
    if (not isinstance(path, str) or not path.startswith("/") or path.startswith("//") or "://" in path or "?" in path
            or "#" in path or ".." in path.split("/") or "\\" in path):
        raise WireDeclarationError(f"wire: probe {name}: path {path!r} must be a relative GET path on the rail's upstream (no host, query or fragment)")
    low = path.lower().rstrip("/")
    if any(low == p or low.startswith(p + "/") for p in INFERENCE_PATHS):
        raise WireDeclarationError(f"wire: probe {name}: path {path!r} is an inference path — a probe never starts inference")


def parse_declarations(doc, rails: Iterable[str]) -> Declarations:
    """Validate a declarations document against the policy's rails. `_`-prefixed keys are comments."""
    if not isinstance(doc, dict):
        raise WireDeclarationError("wire: the declarations file's top level must be an object")
    extra = sorted(k for k in doc if not k.startswith("_") and k not in FILE_KEYS)
    if extra:
        raise WireDeclarationError(f"wire: unknown key(s) {', '.join(extra)} (known: {', '.join(sorted(FILE_KEYS))})")
    rails = tuple(rails)
    probes: dict[str, Probe] = {}
    raw_probes = doc.get("probes") or {}
    if not isinstance(raw_probes, dict):
        raise WireDeclarationError("wire: probes must be an object {source: probe}")
    for name, p in raw_probes.items():
        if name.startswith("_"):
            continue
        if not NAME.match(name) or name in SOURCES:
            raise WireDeclarationError(f"wire: probe name {name!r} must be a new lower-case source name (not one the gateway already reads)")
        if not isinstance(p, dict):
            raise WireDeclarationError(f"wire: probe {name} must be an object")
        bad = sorted(k for k in p if not k.startswith("_") and k not in PROBE_KEYS)
        if bad:
            raise WireDeclarationError(f"wire: probe {name} has unknown key(s) {', '.join(bad)} — a probe is a GET: rail, path, query, interval_s")
        rail = p.get("rail")
        if rail not in rails:
            raise WireDeclarationError(f"wire: probe {name}: rail {rail!r} is not declared by the policy (declared: {', '.join(rails)})")
        if rail not in PROBE_RAILS:
            raise WireDeclarationError(f"wire: probe {name}: rail {rail!r} has no credential lifecycle a probe can ride (supported: {', '.join(PROBE_RAILS)})")
        _check_path(name, p.get("path"))
        query = p.get("query") or {}
        if not isinstance(query, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in query.items()):
            raise WireDeclarationError(f"wire: probe {name}: query must be an object of strings")
        interval = p.get("interval_s")
        if isinstance(interval, bool) or not isinstance(interval, int) or interval < MIN_INTERVAL_S:
            raise WireDeclarationError(f"wire: probe {name}: interval_s must be an integer >= {MIN_INTERVAL_S}")
        probes[name] = Probe(name, rail, p["path"], tuple(sorted(query.items())), interval)
    keep: dict[str, frozenset[str]] = {}
    raw_keep = doc.get("keep_keys") or {}
    if not isinstance(raw_keep, dict):
        raise WireDeclarationError("wire: keep_keys must be an object {source: [key, ...]}")
    known = {**SOURCES, **{n: ACCOUNT for n in probes}}
    for source, keys in raw_keep.items():
        if source.startswith("_"):
            continue
        if known.get(source) != ACCOUNT:
            raise WireDeclarationError(f"wire: keep_keys names source {source!r}, which is not an account source (a public source keeps its bytes whole)")
        if not isinstance(keys, list) or not all(isinstance(k, str) and k for k in keys):
            raise WireDeclarationError(f"wire: keep_keys.{source} must be a list of key names")
        for k in keys:
            if is_identity_key(k):
                raise WireDeclarationError(f"wire: keep_keys.{source} names {k!r} — an identity key can never be allowlisted")
        keep[source] = frozenset(keys)
    return Declarations(probes, keep)


def load_declarations(path: str, rails: Iterable[str]) -> Declarations:
    """No path, a missing-name or an empty file = no declarations. A malformed one raises (refuse to start, like the policy)."""
    if not path:
        return Declarations()
    text = Path(path).read_text(encoding="utf-8")
    if not text.strip():
        return Declarations()
    try:
        doc = json.loads(text)
    except ValueError as e:
        raise WireDeclarationError(f"wire: {path} is not JSON: {e}") from e
    return parse_declarations(doc, rails)


class WireProbe:
    """GW-WIRE-PROBE: each declared probe is one GET on its rail's upstream, authenticated with the rail's own
    credential lifecycle (the one refresh owner — a probe never refreshes on its own), recorded as an account
    source BEFORE anything reads it. The bytes are opaque here: no parser, no shape assumed."""

    def __init__(self, declarations: Declarations, rails: Mapping[str, object], upstreams: Mapping[str, str], client: httpx.AsyncClient,
                 wire: WireRecorder, clock: Callable[[], float]):
        self.decl, self.rails, self.upstreams, self.client, self.wire, self.clock = declarations, rails, upstreams, client, wire, clock
        self.counts: dict[tuple[str, str], int] = {}

    @property
    def enabled(self) -> bool:
        return bool(self.decl.probes)

    def render(self) -> list[str]:
        out = ["# HELP gateway_wire_probe_total Declared wire probes by source and outcome (GW-WIRE-PROBE); source is a name the declarations file declares.",
               "# TYPE gateway_wire_probe_total counter"]
        out += [f'gateway_wire_probe_total{{source="{n}",outcome="{o}"}} {self.counts.get((n, o), 0)}' for n in self.decl.probes for o in PROBE_OUTCOMES]
        return out

    def due_at(self, probe: Probe) -> float:
        """The next read: the last attempt (answer or failure) + the interval; a source never read is due now."""
        row = self.wire.store.wire_get(probe.name)
        last = max((t for t in ((row or {}).get("fetched_at"), (row or {}).get("last_error_at")) if t is not None), default=None)
        return self.clock() if last is None else last + probe.interval_s

    async def tick(self) -> dict[str, str]:
        """Probe every due probe once; the outcomes by source."""
        out: dict[str, str] = {}
        for probe in self.decl.probes.values():
            if self.due_at(probe) <= self.clock():
                out[probe.name] = await self.probe(probe)
        return out

    async def run(self) -> None:
        while True:
            try:
                await self.tick()
            except Exception:  # noqa: BLE001 — the schedule outlives any one pass's failure
                log.exception("wire probe: one pass failed")
            nxt = min((self.due_at(p) for p in self.decl.probes.values()), default=self.clock() + MIN_INTERVAL_S)
            await asyncio.sleep(max(1.0, nxt - self.clock()))

    def _count(self, name: str, outcome: str) -> None:
        self.counts[(name, outcome)] = self.counts.get((name, outcome), 0) + 1

    async def probe(self, probe: Probe) -> str:
        outcome = await self._probe(probe)
        self._count(probe.name, outcome)
        (log.info if outcome == "ok" else log.warning)("wire probe %s: %s", probe.name, outcome)
        return outcome

    async def _probe(self, probe: Probe) -> str:
        rail = self.rails.get(probe.rail)
        lifecycle = getattr(rail, "lifecycle", None)
        upstream = self.upstreams.get(probe.rail, "")
        if lifecycle is None or not upstream:
            return "no-credential"
        try:
            credential = await asyncio.to_thread(lifecycle.acquire)
        except Failure:
            return "no-credential"
        headers = {"authorization": "Bearer " + credential.access_token, "chatgpt-account-id": credential.account_id,
                   "accept": "application/json", "user-agent": USER_AGENT}
        held = (credential.access_token,)
        del credential
        url = upstream + probe.path
        try:
            req = self.client.build_request("GET", url, params=dict(probe.query), headers=headers, timeout=PROBE_TIMEOUT_S)
            full_url = str(req.url)
            resp = await self.client.send(req, stream=True)
        except httpx.HTTPError:
            self.wire.record(probe.name, url, None, None, headers, secrets=held)
            return "fetch-failed"
        try:
            if resp.status_code != 200:
                self.wire.record(probe.name, full_url, resp.status_code, None, headers, secrets=held)
                return "fetch-failed"
            body, truncated = bytearray(), False
            async for chunk in resp.aiter_bytes():
                body += chunk
                if len(body) > self.wire.max_bytes:
                    truncated = True
                    break
        except httpx.HTTPError:
            self.wire.record(probe.name, full_url, None, None, headers, secrets=held)
            return "fetch-failed"
        finally:
            await resp.aclose()
        self.wire.record(probe.name, full_url, 200, bytes(body), headers, resp.headers.get("content-type", ""), truncated, secrets=held)
        return "ok"


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
