"""SQLite sessions + requests (GW-SESSIONS-TOKEN, GW-SESSIONS-RELEASE, GW-HEALTH).

Single replica on a Longhorn PVC (ADR-139). If the file cannot be opened the store falls open to
`:memory:` and says so loudly — a gateway that cannot persist still admits sessions; `/healthz`
reports `db: memory` so the belt sees it.
"""

from __future__ import annotations

import datetime as _dt
import logging
import sqlite3
import threading
import time
from dataclasses import dataclass

log = logging.getLogger("gateway.store")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL UNIQUE,
  stack TEXT NOT NULL,
  role TEXT NOT NULL,
  task TEXT NOT NULL,
  round INTEGER NOT NULL DEFAULT 0,
  rail TEXT NOT NULL,
  harness TEXT NOT NULL,
  model TEXT NOT NULL,
  created_at REAL NOT NULL,
  expires_at REAL NOT NULL,
  released_at REAL,
  requests INTEGER NOT NULL DEFAULT 0,
  tokens_in INTEGER NOT NULL DEFAULT 0,
  tokens_out INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS sessions_active ON sessions (rail, released_at, expires_at);
CREATE TABLE IF NOT EXISTS requests (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  ts REAL NOT NULL,
  status INTEGER NOT NULL,
  upstream_ms INTEGER NOT NULL,
  tokens_in INTEGER NOT NULL DEFAULT 0,
  tokens_out INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS requests_session ON requests (session_id, ts);
"""

def iso(ts: float | None) -> str | None:
    """Epoch seconds → RFC 3339 UTC (the schemas' `timestamp`)."""
    if ts is None:
        return None
    return _dt.datetime.fromtimestamp(ts, tz=_dt.UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


_SESSION_COLS = (
    "id", "token_hash", "stack", "role", "task", "round", "rail", "harness", "model",
    "created_at", "expires_at", "released_at", "requests", "tokens_in", "tokens_out",
)


@dataclass(frozen=True)
class Session:
    id: str
    token_hash: str
    stack: str
    role: str
    task: str
    round: int
    rail: str
    harness: str
    model: str
    created_at: float
    expires_at: float
    released_at: float | None
    requests: int
    tokens_in: int
    tokens_out: int

    def state(self, now: float | None = None) -> str:
        """`active` | `released` | `expired` — the OLDER fact wins: a session that expired before
        its DELETE stays `expired` on the data plane (GW-SESSIONS-RELEASE ⚖)."""
        now = time.time() if now is None else now
        expired = self.expires_at <= now
        if self.released_at is not None and (not expired or self.released_at < self.expires_at):
            return "released"
        if expired:
            return "expired"
        return "active"

    def public(self) -> dict:
        """The GET /sessions/{id} row — exactly the schema's fields; never the token, never its hash."""
        return {
            "id": self.id,
            "stack": self.stack,
            "role": self.role,
            "task": self.task,
            "round": self.round,
            "rail": self.rail,
            "harness": self.harness,
            "model": self.model,
            "created_at": iso(self.created_at),
            "expires_at": iso(self.expires_at),
            "released_at": iso(self.released_at),
            "requests": self.requests,
            "tokens_in": self.tokens_in,
            "tokens_out": self.tokens_out,
        }


class Store:
    def __init__(self, path: str):
        self.path = path
        self.mode = "memory" if path == ":memory:" else "pvc"
        self._lock = threading.RLock()
        try:
            self._db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
            if self.mode == "pvc":
                self._db.execute("PRAGMA journal_mode=WAL")
                (integrity,) = self._db.execute("PRAGMA quick_check").fetchone()
                if integrity != "ok":
                    raise sqlite3.DatabaseError(f"quick_check: {integrity}")
            self._db.executescript(_SCHEMA)
        except sqlite3.Error as e:
            if self.mode == "memory":
                raise
            log.error("db: memory — FAIL-OPEN, sessions do not survive a restart (%s unusable: %s)", path, e)
            self.mode = "memory"
            self._db = sqlite3.connect(":memory:", check_same_thread=False, isolation_level=None)
            self._db.executescript(_SCHEMA)
        else:
            log.info("db: %s %s", self.mode, path)
        self._db.row_factory = sqlite3.Row

    # -- sessions -------------------------------------------------------------------------------
    def create_session(self, **fields) -> Session:
        cols = [c for c in _SESSION_COLS if c in fields]
        with self._lock:
            self._db.execute(
                f"INSERT INTO sessions ({', '.join(cols)}) VALUES ({', '.join('?' for _ in cols)})",
                [fields[c] for c in cols],
            )
        return self.get_session(fields["id"])  # type: ignore[return-value]

    def get_session(self, session_id: str) -> Session | None:
        with self._lock:
            row = self._db.execute("SELECT * FROM sessions WHERE id = ?", (session_id,)).fetchone()
        return Session(**dict(row)) if row else None

    def get_by_token_hash(self, token_hash: str) -> Session | None:
        with self._lock:
            row = self._db.execute("SELECT * FROM sessions WHERE token_hash = ?", (token_hash,)).fetchone()
        return Session(**dict(row)) if row else None

    def release(self, session_id: str, now: float | None = None) -> Session | None:
        now = time.time() if now is None else now
        with self._lock:
            self._db.execute(
                "UPDATE sessions SET released_at = ? WHERE id = ? AND released_at IS NULL", (now, session_id)
            )
        return self.get_session(session_id)

    def active_count(self, rail: str, now: float | None = None) -> int:
        now = time.time() if now is None else now
        with self._lock:
            (n,) = self._db.execute(
                "SELECT COUNT(*) FROM sessions WHERE rail = ? AND released_at IS NULL AND expires_at > ?",
                (rail, now),
            ).fetchone()
        return int(n)

    def active_counts(self, now: float | None = None) -> dict[str, int]:
        now = time.time() if now is None else now
        with self._lock:
            rows = self._db.execute(
                "SELECT rail, COUNT(*) AS n FROM sessions WHERE released_at IS NULL AND expires_at > ? GROUP BY rail",
                (now,),
            ).fetchall()
        return {r["rail"]: int(r["n"]) for r in rows}

    # -- requests -------------------------------------------------------------------------------
    def record_request(
        self, session_id: str, status: int, upstream_ms: int, tokens_in: int, tokens_out: int, ts: float | None = None
    ) -> None:
        ts = time.time() if ts is None else ts
        with self._lock:
            self._db.execute(
                "INSERT INTO requests (session_id, ts, status, upstream_ms, tokens_in, tokens_out) VALUES (?,?,?,?,?,?)",
                (session_id, ts, status, upstream_ms, tokens_in, tokens_out),
            )
            self._db.execute(
                "UPDATE sessions SET requests = requests + 1, tokens_in = tokens_in + ?, tokens_out = tokens_out + ? WHERE id = ?",
                (tokens_in, tokens_out, session_id),
            )

    def requests_for(self, session_id: str) -> list[dict]:
        with self._lock:
            rows = self._db.execute(
                "SELECT * FROM requests WHERE session_id = ? ORDER BY id", (session_id,)
            ).fetchall()
        return [dict(r) for r in rows]

    def ping(self) -> bool:
        try:
            with self._lock:
                self._db.execute("SELECT 1").fetchone()
            return True
        except sqlite3.Error:
            return False

    def close(self) -> None:
        with self._lock:
            self._db.close()
