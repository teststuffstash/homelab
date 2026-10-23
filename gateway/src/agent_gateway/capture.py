"""The four-boundary capture of a codex ride (GW-CODEX-CAPTURE — the spike §Recorded live protocol
experiment, FU-270): **client request received**, **upstream request sent**, **upstream response
received** (its status, headers and every SSE event as it is relayed), **client response sent**.

Scoped: only a session whose task carries the configured prefix is recorded (`CODEX_CAPTURE_TASK_PREFIX`;
unset = the recorder is off). Sanitized BEFORE persistence, structurally — never the log formatter's
pattern matching: header VALUES are kept only for an allowlist of non-sensitive names (the rest keep
their name, value withheld); in bodies and events every string is reduced to its length except the
vocabulary keys (`type`, `status`, `role`, `name`, …) whose values are enumerations, and identifier
keys (`id`, `*_id`), which become run-local aliases equal across all four boundaries; numbers and
booleans stay; unknown keys keep their structural presence and type. The capture is bounded by
bytes; overflow marks the bundle `complete: false` (a missing record is never an observed absence).
The ride never depends on the recorder: a recorder fault is logged and the relay continues.
"""

from __future__ import annotations

import json
import logging
import threading
import time
from dataclasses import dataclass, field
from typing import Any

log = logging.getLogger("gateway.capture")

FORMAT = "codex-capture/1"
BOUNDARIES = ("client-request", "upstream-request", "upstream-response", "upstream-event", "client-response")
# Header names whose VALUES are non-sensitive by construction (content negotiation, transport, the
# account's headroom percentages the gateway already reads as a report, the vendor's plan vocabulary).
HEADER_VALUES = frozenset({
    "content-type", "content-length", "transfer-encoding", "accept", "accept-encoding", "cache-control",
    "retry-after", "user-agent", "server", "date", "cf-cache-status", "connection", "vary",
    "x-codex-primary-used-percent", "x-codex-primary-window-minutes", "x-codex-primary-reset-after-seconds",
    "x-codex-primary-reset-at", "x-codex-secondary-used-percent", "x-codex-secondary-window-minutes",
    "x-codex-secondary-reset-after-seconds", "x-codex-secondary-reset-at",
    "x-codex-primary-over-secondary-limit-percent", "x-codex-rate-limit-reached-type", "x-codex-plan-type",
    "x-codex-active-limit", "x-codex-safety-buffering-enabled", "x-codex-safety-faster-model",
})
# Keys whose string values are an enumeration or a public name, kept verbatim (bounded in length).
VOCABULARY = frozenset({
    "type", "status", "role", "name", "model", "object", "code", "param", "reason", "effort", "summary",
    "format", "truncation", "tool_choice", "service_tier", "verbosity", "phase", "kind", "store", "stream",
})
# Keys whose string values are opaque identifiers: aliased, equal across boundaries.
ID_SUFFIXES = ("id",)
MAX_VOCAB_LEN = 64
MAX_LIST = 64
MAX_DEPTH = 8


@dataclass
class Capture:
    """One scoped request's records, persisted at the client-response boundary (or on refusal)."""
    session_id: str
    task: str
    request_no: int  # the session's request ordinal (concurrent requests interleave; each record carries it)
    max_bytes: int
    aliases: dict[str, str]
    lock: threading.Lock
    t0: float = field(default_factory=time.monotonic)
    persisted: bool = False
    records: list[dict] = field(default_factory=list)
    bytes: int = 0
    complete: bool = True
    events: int = 0
    client_names: tuple[str, ...] = ()
    upstream_names: tuple[str, ...] = ()

    # -- the boundaries ------------------------------------------------------------------------
    def client_request(self, method: str, path: str, headers: Any, raw: bytes, doc: Any) -> None:
        self.client_names = tuple(sorted({k.lower() for k in headers.keys()}))
        self._add("client-request", {"method": method, "path": path, "headers": self._headers(headers),
                                     "body_bytes": len(raw), "body": self._skeleton(doc)})

    def upstream_request(self, method: str, url: str, headers: dict[str, str], raw: bytes, doc: Any) -> None:
        self.upstream_names = tuple(sorted({k.lower() for k in headers.keys()}))
        added = sorted(set(self.upstream_names) - set(self.client_names))
        dropped = sorted(set(self.client_names) - set(self.upstream_names))
        host, _, path = url.partition("://")[2].partition("/")
        self._add("upstream-request", {"method": method, "host": host, "path": "/" + path, "headers": self._headers(headers),
                                       "headers_added": added, "headers_dropped": dropped,
                                       "body_bytes": len(raw), "body": self._skeleton(doc)})

    def upstream_response(self, status: int, headers: Any, refusal: str | None = None) -> None:
        self._add("upstream-response", {"status": status, "headers": self._headers(headers),
                                        "first_byte_ms": self._ms(), "refusal": refusal})

    def event(self, data: bytes) -> None:
        """One SSE event's data as relayed (the parser's split, not the gateway's): sanitized."""
        self.events += 1
        if data == b"[DONE]":
            self._add("upstream-event", {"n": self.events, "done": True})
            return
        try:
            doc = json.loads(data)
        except (ValueError, UnicodeError):
            self._add("upstream-event", {"n": self.events, "invalid": True, "bytes": len(data)})
            return
        self._add("upstream-event", {"n": self.events, "bytes": len(data), "event": self._skeleton(doc)})

    def client_response(self, status: int, headers: dict[str, str], outcome: str, relayed_bytes: int,
                        usage: dict[str, int] | None, cancelled: bool = False) -> None:
        self._add("client-response", {"status": status, "headers": self._headers(headers), "outcome": outcome,
                                      "relayed_bytes": relayed_bytes, "events": self.events, "usage": usage,
                                      "cancelled": cancelled, "elapsed_ms": self._ms()})

    # -- the sanitizers ------------------------------------------------------------------------
    def _headers(self, headers: Any) -> dict[str, Any]:
        out: dict[str, Any] = {}
        items = headers.items() if hasattr(headers, "items") else headers
        for name, value in items:
            lname = str(name).lower()
            if lname in HEADER_VALUES:
                out[lname] = str(value)[:256]
            else:
                out[lname] = {"withheld": True, "len": len(str(value))}
        return dict(sorted(out.items()))

    def _skeleton(self, value: Any, key: str = "", depth: int = 0) -> Any:
        if depth > MAX_DEPTH:
            return {"withheld": True, "depth": True}
        if isinstance(value, dict):
            return {str(k): self._skeleton(v, str(k), depth + 1) for k, v in value.items()}
        if isinstance(value, list):
            out = [self._skeleton(v, key, depth + 1) for v in value[:MAX_LIST]]
            if len(value) > MAX_LIST:
                out.append({"withheld": True, "more": len(value) - MAX_LIST})
            return out
        if isinstance(value, str):
            lkey = key.lower()
            if lkey == "id" or lkey.endswith("_id") or lkey.endswith("_ids"):
                return self._alias(lkey, value)
            if lkey in VOCABULARY and len(value) <= MAX_VOCAB_LEN:
                return value
            return {"len": len(value)}
        return value  # int, float, bool, None

    def _alias(self, key: str, value: str) -> str:
        with self.lock:  # the alias map is the SESSION's (equality across its requests), shared by concurrent captures
            if value not in self.aliases:
                stem = key[:-3] if key.endswith("_id") else key[:-4] if key.endswith("_ids") else "id"
                self.aliases[value] = f"{stem or 'id'}#{len(self.aliases) + 1}"
            return self.aliases[value]

    # -- the ledger ----------------------------------------------------------------------------
    def _ms(self) -> int:
        return int((time.monotonic() - self.t0) * 1000)

    def _add(self, boundary: str, record: dict) -> None:
        if not self.complete:
            return  # the bound tripped: the marker is the LAST record, nothing smaller slips in behind it
        line = json.dumps({"boundary": boundary, "request": self.request_no, "t_ms": self._ms(), **record},
                          separators=(",", ":"), sort_keys=True)
        if self.bytes + len(line) > self.max_bytes:
            self.complete = False
            self.records.append({"boundary": boundary, "request": self.request_no, "t_ms": self._ms(), "truncated": True,
                                 "reason": f"capture over {self.max_bytes} bytes"})
            return
        self.bytes += len(line)
        self.records.append(json.loads(line))


class Splitter:
    """A minimal SSE splitter for the capture tee: `feed` returns each completed event's data (the
    `data:` lines joined), never raising — an unparsable stream yields whatever events it had."""

    def __init__(self, max_event_bytes: int = 1024 * 1024):
        self.limit = max_event_bytes
        self.buf = bytearray()

    def feed(self, chunk: bytes) -> list[bytes]:
        out: list[bytes] = []
        self.buf.extend(chunk)
        if len(self.buf) > self.limit:
            self.buf.clear()
            return out
        while True:
            cut = -1
            for sep in (b"\n\n", b"\r\n\r\n"):
                i = self.buf.find(sep)
                if i != -1 and (cut == -1 or i < cut):
                    cut, width = i, len(sep)
            if cut == -1:
                return out
            block = bytes(self.buf[:cut])
            del self.buf[:cut + width]
            data = b"\n".join(ln[5:].lstrip(b" ") for ln in block.splitlines() if ln.startswith(b"data:"))
            if data:
                out.append(data)


class Recorder:
    """The recorder the codex proxy consults per request: scope by task prefix, aliases per session,
    persistence through the store (table `captures`), read-back for the bundle endpoint."""

    MAX_SESSIONS = 64  # the in-memory alias maps and ordinals are per capture session; the oldest go when full

    def __init__(self, store, task_prefix: str, max_bytes: int, clock=None):
        self.store = store
        self.task_prefix = task_prefix
        self.max_bytes = max_bytes
        self.clock = clock or time.time
        self._lock = threading.Lock()
        self._aliases: dict[str, dict[str, str]] = {}
        self._requests: dict[str, int] = {}

    @property
    def enabled(self) -> bool:
        return bool(self.task_prefix)

    def scoped(self, task: str) -> bool:
        return self.enabled and task.startswith(self.task_prefix)

    def start(self, session_id: str, task: str) -> Capture | None:
        if not self.scoped(task):
            return None
        with self._lock:
            while len(self._aliases) >= self.MAX_SESSIONS and session_id not in self._aliases:
                oldest = next(iter(self._aliases))
                self._aliases.pop(oldest, None)
                self._requests.pop(oldest, None)
            no = self._requests.get(session_id, 0) + 1
            self._requests[session_id] = no
            aliases = self._aliases.setdefault(session_id, {})
        return Capture(session_id, task, no, self.max_bytes, aliases, self._lock)

    def persist(self, cap: Capture) -> None:
        """The records go to the store in one go, their `seq` allocated NOW under the lock from the
        store's count — two requests of one session in flight persist back to back, never over each
        other (a collision is a loud INSERT failure, never a silent replace)."""
        if cap.persisted:
            return
        cap.persisted = True
        try:
            ts = self.clock()
            with self._lock:
                seq = self.store.capture_count(cap.session_id)
                for rec in cap.records:
                    self.store.record_capture(cap.session_id, seq, rec["boundary"], ts, json.dumps(rec, separators=(",", ":"), sort_keys=True))
                    seq += 1
            log.info("capture: session=%s task=%s request=%d records=%d bytes=%d complete=%s", cap.session_id, cap.task,
                     cap.request_no, len(cap.records), cap.bytes, cap.complete)
        except Exception as e:  # noqa: BLE001 — a recorder fault never reaches the ride
            log.warning("capture: persist failed session=%s: %s", cap.session_id, type(e).__name__)

    def bundle(self, session_id: str, task: str) -> dict | None:
        rows = self.store.captures(session_id)
        if not rows:
            return None
        records = [json.loads(r) for r in rows]
        return {"format": FORMAT, "session": session_id, "task": task, "records": records,
                "requests": max((r.get("request", 0) for r in records), default=0),
                "complete": not any(r.get("truncated") for r in records),
                "boundaries": sorted({r["boundary"] for r in records}, key=BOUNDARIES.index)}
