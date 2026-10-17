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
  tokens_out INTEGER NOT NULL DEFAULT 0,
  tokens_cache_read INTEGER NOT NULL DEFAULT 0,
  tokens_cache_write INTEGER NOT NULL DEFAULT 0,
  bind_namespace TEXT,
  bind_serviceaccount TEXT,
  bind_pod TEXT,
  env_delivered_at REAL,
  caller TEXT
);
CREATE INDEX IF NOT EXISTS sessions_active ON sessions (rail, released_at, expires_at);
CREATE TABLE IF NOT EXISTS requests (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  ts REAL NOT NULL,
  status INTEGER NOT NULL,
  upstream_ms INTEGER NOT NULL,
  tokens_in INTEGER NOT NULL DEFAULT 0,
  tokens_out INTEGER NOT NULL DEFAULT 0,
  tokens_cache_read INTEGER NOT NULL DEFAULT 0,
  tokens_cache_write INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS requests_session ON requests (session_id, ts);
CREATE INDEX IF NOT EXISTS requests_ts ON requests (ts);
"""
# Columns added after the first PVC database was created: `CREATE TABLE IF NOT EXISTS` never adds
# them to an existing table, so _migrate() does (idempotent, additive only). The bind columns
# (GW-SESSIONS-PULL) are nullable: NULL = an unbound session, whose env went out in the dispatch.
# `caller` (GW-SESSIONS-AUTH) is the admitting caller's ServiceAccount username; NULL = admitted
# with no authenticated identity (the `observe` knob), or before the column existed.
_COUNTER = "INTEGER NOT NULL DEFAULT 0"
_ADDED_COLUMNS = {
    "sessions": {"tokens_cache_read": _COUNTER, "tokens_cache_write": _COUNTER, "bind_namespace": "TEXT",
                 "bind_serviceaccount": "TEXT", "bind_pod": "TEXT", "env_delivered_at": "REAL",
                 "caller": "TEXT"},
    "requests": {"tokens_cache_read": _COUNTER, "tokens_cache_write": _COUNTER},
}
# A bound session's token is minted at the PULL, not the dispatch: until then its token_hash
# column (NOT NULL UNIQUE) holds this prefix + the id, which no sha256 hex digest can equal.
UNMINTED_PREFIX = "unminted:"


@dataclass(frozen=True)
class Usage:
    """One response's token usage in four classes (the old router's gometer split). `tokens_in` is
    UNCACHED input on every rail: anthropic's `input_tokens` already excludes the cache; the openai
    dialect's `prompt_tokens` includes it, so the parser subtracts `cached_tokens` there."""
    tokens_in: int = 0
    tokens_cache_read: int = 0
    tokens_cache_write: int = 0
    tokens_out: int = 0


def iso(ts: float | None) -> str | None:
    """Epoch seconds → RFC 3339 UTC (the schemas' `timestamp`)."""
    if ts is None:
        return None
    return _dt.datetime.fromtimestamp(ts, tz=_dt.UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


_SESSION_COLS = (
    "id", "token_hash", "stack", "role", "task", "round", "rail", "harness", "model",
    "created_at", "expires_at", "released_at", "requests", "tokens_in", "tokens_out",
    "tokens_cache_read", "tokens_cache_write", "bind_namespace", "bind_serviceaccount", "bind_pod",
    "env_delivered_at", "caller",
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
    tokens_cache_read: int = 0
    tokens_cache_write: int = 0
    # GW-SESSIONS-PULL: the identity a bound session's env is pulled by (NULL = unbound) and when it was.
    bind_namespace: str | None = None
    bind_serviceaccount: str | None = None
    bind_pod: str | None = None
    env_delivered_at: float | None = None
    # GW-SESSIONS-AUTH: who admitted it (`system:serviceaccount:<ns>:<sa>`); None = no authenticated caller.
    caller: str | None = None

    @property
    def bound(self) -> bool:
        return self.bind_serviceaccount is not None

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
            "tokens_cache_read": self.tokens_cache_read,
            "tokens_cache_write": self.tokens_cache_write,
            "caller": self.caller,
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
            self._migrate()
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

    def _migrate(self) -> None:
        for table, cols in _ADDED_COLUMNS.items():
            have = {r[1] for r in self._db.execute(f"PRAGMA table_info({table})").fetchall()}
            for col, decl in cols.items():
                if col not in have:
                    self._db.execute(f"ALTER TABLE {table} ADD COLUMN {col} {decl}")
                    log.info("db: migrated %s.%s", table, col)

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

    def deliver_env(self, session_id: str, token_hash: str, now: float) -> bool:
        """GW-SESSIONS-PULL's at-most-once write: store the freshly minted token's hash and stamp
        `env_delivered_at` — only on a bound row not yet delivered. False = someone pulled first
        (one conditional UPDATE, so two racing pulls cannot both win)."""
        with self._lock:
            cur = self._db.execute(
                "UPDATE sessions SET token_hash = ?, env_delivered_at = ? WHERE id = ? AND env_delivered_at IS NULL"
                " AND bind_serviceaccount IS NOT NULL",
                (token_hash, now, session_id),
            )
            return cur.rowcount == 1

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
        self, session_id: str, status: int, upstream_ms: int, usage: Usage | None = None, ts: float | None = None
    ) -> None:
        ts = time.time() if ts is None else ts
        u = usage or Usage()
        with self._lock:
            self._db.execute(
                "INSERT INTO requests (session_id, ts, status, upstream_ms, tokens_in, tokens_out, tokens_cache_read,"
                " tokens_cache_write) VALUES (?,?,?,?,?,?,?,?)",
                (session_id, ts, status, upstream_ms, u.tokens_in, u.tokens_out, u.tokens_cache_read, u.tokens_cache_write),
            )
            self._db.execute(
                "UPDATE sessions SET requests = requests + 1, tokens_in = tokens_in + ?, tokens_out = tokens_out + ?,"
                " tokens_cache_read = tokens_cache_read + ?, tokens_cache_write = tokens_cache_write + ? WHERE id = ?",
                (u.tokens_in, u.tokens_out, u.tokens_cache_read, u.tokens_cache_write, session_id),
            )

    def rail_usage_since(self, rail: str, since: float) -> list[tuple[float, str, int, int, int, int]]:
        """The rail's metered (2xx) requests since `since`, ascending: (ts, session model, tokens_in,
        cache_read, cache_write, tokens_out) — the window-draw ledger (GW-SESSIONS-ADMIT)."""
        with self._lock:
            rows = self._db.execute(
                "SELECT r.ts, s.model, r.tokens_in, r.tokens_cache_read, r.tokens_cache_write, r.tokens_out"
                " FROM requests r JOIN sessions s ON s.id = r.session_id"
                " WHERE s.rail = ? AND r.ts >= ? AND r.status BETWEEN 200 AND 299 ORDER BY r.ts",
                (rail, since),
            ).fetchall()
        return [(float(r[0]), r[1], int(r[2]), int(r[3]), int(r[4]), int(r[5])) for r in rows]

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
