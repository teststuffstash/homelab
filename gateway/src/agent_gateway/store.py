"""SQLite sessions + requests (GW-SESSIONS-TOKEN, GW-SESSIONS-RELEASE, GW-HEALTH).

Single replica on a Longhorn PVC (ADR-139). If the file cannot be opened the store falls open to
`:memory:` and says so loudly — a gateway that cannot persist still admits sessions; `/healthz`
reports `db: memory` so the belt sees it.
"""

from __future__ import annotations

import datetime as _dt
import json
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
  caller TEXT,
  requests_incomplete INTEGER NOT NULL DEFAULT 0,
  attempt INTEGER NOT NULL DEFAULT 1,
  live_namespace TEXT,
  live_pod TEXT,
  live_pod_uid TEXT,
  release_reason TEXT,
  canary_provider TEXT
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
  tokens_cache_write INTEGER NOT NULL DEFAULT 0,
  incomplete TEXT,
  provider TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS requests_session ON requests (session_id, ts);
CREATE TABLE IF NOT EXISTS outcomes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  class TEXT NOT NULL,
  subclass TEXT,
  evidence TEXT,
  reporter TEXT,
  at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS outcomes_session ON outcomes (session_id, id);
CREATE TABLE IF NOT EXISTS strikes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  stack TEXT NOT NULL,
  task TEXT NOT NULL,
  rail TEXT NOT NULL,
  model TEXT NOT NULL,
  provider TEXT NOT NULL DEFAULT '',
  class TEXT NOT NULL,
  scope TEXT NOT NULL,
  source TEXT NOT NULL,
  session_id TEXT NOT NULL,
  at REAL NOT NULL,
  refuted_at REAL,
  UNIQUE (session_id, class, source, provider)
);
CREATE INDEX IF NOT EXISTS strikes_task ON strikes (stack, task);
CREATE INDEX IF NOT EXISTS requests_ts ON requests (ts);
CREATE TABLE IF NOT EXISTS catalog_snapshots (
  source TEXT PRIMARY KEY,
  fetched_at REAL NOT NULL,
  body TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS provider_cells (
  model TEXT NOT NULL,
  provider TEXT NOT NULL,
  state TEXT NOT NULL,
  class TEXT,
  since REAL NOT NULL,
  cooldown_until REAL,
  PRIMARY KEY (model, provider)
);
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value REAL NOT NULL
);
"""
_STRIKES_REBUILD = """
BEGIN;
CREATE TABLE strikes_v2 (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  stack TEXT NOT NULL,
  task TEXT NOT NULL,
  rail TEXT NOT NULL,
  model TEXT NOT NULL,
  provider TEXT NOT NULL DEFAULT '',
  class TEXT NOT NULL,
  scope TEXT NOT NULL,
  source TEXT NOT NULL,
  session_id TEXT NOT NULL,
  at REAL NOT NULL,
  refuted_at REAL,
  UNIQUE (session_id, class, source, provider)
);
INSERT INTO strikes_v2 (id, stack, task, rail, model, provider, class, scope, source, session_id, at, refuted_at)
  SELECT id, stack, task, rail, model, provider, class, scope, source, session_id, at, refuted_at FROM strikes;
DROP TABLE strikes;
ALTER TABLE strikes_v2 RENAME TO strikes;
CREATE INDEX IF NOT EXISTS strikes_task ON strikes (stack, task);
COMMIT;
"""
# Columns added after the first PVC database was created: `CREATE TABLE IF NOT EXISTS` never adds
# them to an existing table, so _migrate() does (idempotent, additive only). The bind columns
# (GW-SESSIONS-PULL) are nullable: NULL = an unbound session, whose env went out in the dispatch.
# `caller` (GW-SESSIONS-AUTH) is the admitting caller's ServiceAccount username; NULL = admitted
# with no authenticated identity (the `observe` knob), or before the column existed.
# `requests_incomplete` / `requests.incomplete` (GW-RAIL-*): a 2xx whose body stopped before its end
# (no terminal event, a mid-stream timeout or transport error, the client gone) — the reason; NULL = complete.
_COUNTER = "INTEGER NOT NULL DEFAULT 0"
_ADDED_COLUMNS = {
    "sessions": {"tokens_cache_read": _COUNTER, "tokens_cache_write": _COUNTER, "bind_namespace": "TEXT",
                 "bind_serviceaccount": "TEXT", "bind_pod": "TEXT", "env_delivered_at": "REAL",
                 "caller": "TEXT", "requests_incomplete": _COUNTER, "attempt": "INTEGER NOT NULL DEFAULT 1",
                 "live_namespace": "TEXT", "live_pod": "TEXT", "live_pod_uid": "TEXT", "release_reason": "TEXT",
                 "canary_provider": "TEXT"},  # GW-CATALOG-OR: the cell a canary session is pinned to (NULL = not a canary)
    "requests": {"tokens_cache_read": _COUNTER, "tokens_cache_write": _COUNTER, "incomplete": "TEXT",
                 "provider": "TEXT NOT NULL DEFAULT ''"},  # GW-RAIL-OPENROUTER: the serving provider's slug ('' = none named)
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
    "env_delivered_at", "caller", "requests_incomplete", "attempt", "live_namespace", "live_pod", "live_pod_uid",
    "release_reason", "canary_provider",
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
    # GW-RAIL-*: the 2xx answers whose body stopped before its end (never counted as clean).
    requests_incomplete: int = 0
    attempt: int = 1  # GW-SESSIONS-ADMIT: the consumer's re-admission counter at this round
    # GW-SESSIONS-LIVENESS: the pod this session lives in (the pulling pod, else the caller's), and why it ended
    live_namespace: str | None = None
    live_pod: str | None = None
    live_pod_uid: str | None = None
    release_reason: str | None = None  # released (DELETE) | superseded | pod-gone; NULL = not released
    canary_provider: str | None = None  # GW-CATALOG-OR: the (model, provider) cell this canary session is pinned to

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

    def public(self, now: float | None = None) -> dict:
        """The GET /sessions/{id} row — exactly the schema's fields; never the token, never its hash."""
        return {
            "id": self.id,
            "stack": self.stack,
            "role": self.role,
            "task": self.task,
            "round": self.round,
            "attempt": self.attempt,
            "state": self.state(now),
            "release_reason": self.release_reason if self.released_at is not None else None,
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
            "requests_incomplete": self.requests_incomplete,
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
        # The strike key gained the provider (GW-RAIL-OPENROUTER: a failed-over ride strikes each
        # provider it tried, in the same class): a table built with the old UNIQUE is rebuilt once.
        (sql,) = self._db.execute("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'strikes'").fetchone()
        if "UNIQUE (session_id, class, source)" in sql:
            self._db.executescript(_STRIKES_REBUILD)
            log.info("db: migrated strikes — the unique key now carries provider")

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

    def release(self, session_id: str, now: float | None = None, reason: str = "released") -> Session | None:
        now = time.time() if now is None else now
        with self._lock:
            self._db.execute(
                "UPDATE sessions SET released_at = ?, release_reason = ? WHERE id = ? AND released_at IS NULL",
                (now, reason, session_id),
            )
        return self.get_session(session_id)

    def set_live_pod(self, session_id: str, namespace: str | None, pod: str | None, uid: str | None) -> None:
        with self._lock:
            self._db.execute("UPDATE sessions SET live_namespace = ?, live_pod = ?, live_pod_uid = ? WHERE id = ?",
                             (namespace, pod, uid, session_id))

    def live_sessions(self, now: float) -> list[Session]:
        """ACTIVE sessions with a known pod — the reaper's work list."""
        with self._lock:
            rows = self._db.execute(
                "SELECT * FROM sessions WHERE released_at IS NULL AND expires_at > ? AND live_pod IS NOT NULL", (now,)
            ).fetchall()
        return [Session(**dict(r)) for r in rows]

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

    def rotate_pulled_token(self, sid: str, previous: str, replacement: str, now: float) -> bool:
        """Atomically replace only a still-active delivered token; racing reads cannot both win."""
        with self._lock:
            cur = self._db.execute(
                "UPDATE sessions SET token_hash=? WHERE id=? AND token_hash=?"
                " AND harness='codex' AND env_delivered_at IS NOT NULL"
                " AND released_at IS NULL AND expires_at>? AND live_pod_uid IS NOT NULL",
                (replacement, sid, previous, now),
            )
            return cur.rowcount == 1

    def active_duplicates(self, stack: str, task: str, rnd: int, attempt: int, caller: str | None, pod: str | None,
                          now: float) -> list[str]:
        """ACTIVE sessions the same caller admitted for (stack, task, round, attempt) and the same bound
        pod (NULL = unbound) — the ids a re-admission supersedes."""
        with self._lock:
            rows = self._db.execute(
                "SELECT id FROM sessions WHERE stack = ? AND task = ? AND round = ? AND attempt = ? AND caller IS ?"
                " AND bind_pod IS ? AND released_at IS NULL AND expires_at > ?",
                (stack, task, rnd, attempt, caller, pod, now)).fetchall()
        return [r[0] for r in rows]

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
        self, session_id: str, status: int, upstream_ms: int, usage: Usage | None = None, ts: float | None = None,
        incomplete: str | None = None, provider: str = "",
    ) -> None:
        ts = time.time() if ts is None else ts
        u = usage or Usage()
        with self._lock:
            self._db.execute(
                "INSERT INTO requests (session_id, ts, status, upstream_ms, tokens_in, tokens_out, tokens_cache_read,"
                " tokens_cache_write, incomplete, provider) VALUES (?,?,?,?,?,?,?,?,?,?)",
                (session_id, ts, status, upstream_ms, u.tokens_in, u.tokens_out, u.tokens_cache_read, u.tokens_cache_write,
                 incomplete, provider),
            )
            self._db.execute(
                "UPDATE sessions SET requests = requests + 1, tokens_in = tokens_in + ?, tokens_out = tokens_out + ?,"
                " tokens_cache_read = tokens_cache_read + ?, tokens_cache_write = tokens_cache_write + ?,"
                " requests_incomplete = requests_incomplete + ? WHERE id = ?",
                (u.tokens_in, u.tokens_out, u.tokens_cache_read, u.tokens_cache_write, 1 if incomplete else 0, session_id),
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

    def session_providers(self, session_id: str) -> set[str]:
        """The providers this session's 2xx answers were attributed to (GW-RAIL-OPENROUTER)."""
        with self._lock:
            rows = self._db.execute(
                "SELECT DISTINCT provider FROM requests WHERE session_id = ? AND provider <> '' AND status BETWEEN 200 AND 299",
                (session_id,)).fetchall()
        return {r[0] for r in rows}

    def cell_outcomes(self, rail: str, model: str) -> dict[str, tuple[int, int]]:
        """Per provider of (rail, model): (clean rides, judged rides) — a ride = a session whose
        2xx answers that provider served and whose LATEST outcome is reported; clean = that outcome
        is `clean` (GW-RAIL-OPENROUTER §Selection: the clean-ride rate the order reads). Provider
        `''` is the model's own cell — the only one on the rails that pin none (the Go rail's clean
        rate, GW-MODEL-TIERS §The rail choice), the unattributed rides on openrouter."""
        with self._lock:
            rows = self._db.execute(
                "SELECT p.provider, o.class, COUNT(*) FROM"
                " (SELECT DISTINCT r.session_id, r.provider FROM requests r JOIN sessions s ON s.id = r.session_id"
                "  WHERE s.rail = ? AND s.model = ? AND r.status BETWEEN 200 AND 299) p"
                " JOIN outcomes o ON o.id = (SELECT id FROM outcomes WHERE session_id = p.session_id ORDER BY id DESC LIMIT 1)"
                " GROUP BY p.provider, o.class", (rail, model)).fetchall()
        out: dict[str, list[int]] = {}
        for provider, klass, n in rows:
            cell = out.setdefault(provider, [0, 0])
            cell[1] += int(n)
            if klass == "clean":
                cell[0] += int(n)
        return {p: (c[0], c[1]) for p, c in out.items()}

    # -- outcomes + strikes (GW-SESSIONS-OUTCOME) ---------------------------------------------
    def add_outcome(self, session_id: str, klass: str, sub: str | None, evidence: str | None, reporter: str | None,
                    at: float) -> dict:
        with self._lock:
            cur = self._db.execute(
                "INSERT INTO outcomes (session_id, class, subclass, evidence, reporter, at) VALUES (?,?,?,?,?,?)",
                (session_id, klass, sub, evidence, reporter, at),
            )
            row = self._db.execute("SELECT * FROM outcomes WHERE id = ?", (cur.lastrowid,)).fetchone()
        return dict(row)

    def outcome_by(self, session_id: str, reporter: str | None) -> dict | None:
        with self._lock:
            row = self._db.execute(
                "SELECT * FROM outcomes WHERE session_id = ? AND reporter IS ? ORDER BY id DESC LIMIT 1", (session_id, reporter)
            ).fetchone()
        return dict(row) if row else None

    def latest_outcome(self, session_id: str) -> dict | None:
        with self._lock:
            row = self._db.execute("SELECT * FROM outcomes WHERE session_id = ? ORDER BY id DESC LIMIT 1", (session_id,)).fetchone()
        return dict(row) if row else None

    def add_strike(self, stack: str, task: str, rail: str, model: str, provider: str, klass: str, scope: str, source: str,
                   session_id: str, at: float) -> bool:
        """One strike per (session, class, source); False = it was already counted."""
        with self._lock:
            cur = self._db.execute(
                "INSERT OR IGNORE INTO strikes (stack, task, rail, model, provider, class, scope, source, session_id, at)"
                " VALUES (?,?,?,?,?,?,?,?,?,?)",
                (stack, task, rail, model, provider, klass, scope, source, session_id, at),
            )
            return cur.rowcount == 1

    def refute_strikes(self, stack: str, task: str, rail: str, model: str, at: float, providers: set[str] = frozenset()) -> int:
        """A clean outcome on (rail, model) refutes the task's counted model strikes on that model and
        its cell strikes on the cells the ride touched: (rail, model, '') and (rail, model, p) for each
        provider p the session rode (GW-RAIL-OPENROUTER: a provider-scoped strike is refuted only by
        a clean ride on that provider)."""
        ps = sorted(providers)
        marks = ",".join("?" for _ in ps)
        with self._lock:
            cur = self._db.execute(
                "UPDATE strikes SET refuted_at = ? WHERE stack = ? AND task = ? AND refuted_at IS NULL AND at <= ?"
                " AND model = ? AND (scope = 'model' OR (rail = ? AND (provider = ''" + (f" OR provider IN ({marks})" if ps else "") + ")))",
                (at, stack, task, at, model, rail, *ps),
            )
            return cur.rowcount

    def strikes_for(self, stack: str, task: str, counted_only: bool = True) -> list[dict]:
        q = "SELECT * FROM strikes WHERE stack = ? AND task = ?" + (" AND refuted_at IS NULL" if counted_only else "") + " ORDER BY id"
        with self._lock:
            rows = self._db.execute(q, (stack, task)).fetchall()
        return [dict(r) for r in rows]

    def requests_for(self, session_id: str) -> list[dict]:
        with self._lock:
            rows = self._db.execute(
                "SELECT * FROM requests WHERE session_id = ? ORDER BY id", (session_id,)
            ).fetchall()
        return [dict(r) for r in rows]

    # -- the Go catalog's last good snapshots (GW-CATALOG-GO) ---------------------------------
    def snapshot_save(self, source: str, fetched_at: float, body: dict) -> None:
        """Replace the source's last good snapshot (one row per source)."""
        with self._lock:
            self._db.execute(
                "INSERT INTO catalog_snapshots (source, fetched_at, body) VALUES (?,?,?)"
                " ON CONFLICT(source) DO UPDATE SET fetched_at = excluded.fetched_at, body = excluded.body",
                (source, fetched_at, json.dumps(body, sort_keys=True, separators=(",", ":"))),
            )

    def snapshot_load(self, source: str) -> tuple[float, dict] | None:
        with self._lock:
            row = self._db.execute("SELECT fetched_at, body FROM catalog_snapshots WHERE source = ?", (source,)).fetchone()
        if row is None:
            return None
        try:
            return float(row[0]), json.loads(row[1])
        except ValueError:
            log.error("db: catalog_snapshots.%s is not JSON — ignored (the next refresh replaces it)", source)
            return None

    # -- the OpenRouter catalog's cells + the canary meter (GW-CATALOG-OR) ----------------------
    def cells_sync(self, pairs: list[tuple[str, str]], now: float) -> int:
        """Every (model, provider) the snapshot carries gets a row; a pair new to the table enters as
        `candidate`. Returns how many entered."""
        n = 0
        with self._lock:
            for model, provider in set(pairs):
                cur = self._db.execute("INSERT OR IGNORE INTO provider_cells (model, provider, state, class, since, cooldown_until)"
                                       " VALUES (?,?,'candidate',NULL,?,NULL)", (model, provider, now))
                n += cur.rowcount
        return n

    def cell_get(self, model: str, provider: str) -> dict | None:
        with self._lock:
            row = self._db.execute("SELECT * FROM provider_cells WHERE model = ? AND provider = ?", (model, provider)).fetchone()
        return dict(row) if row else None

    def cell_states(self, model: str) -> dict[str, dict]:
        with self._lock:
            rows = self._db.execute("SELECT * FROM provider_cells WHERE model = ?", (model,)).fetchall()
        return {r["provider"]: dict(r) for r in rows}

    def cell_set(self, model: str, provider: str, state: str, klass: str | None, now: float, cooldown_until: float | None) -> None:
        with self._lock:
            self._db.execute(
                "INSERT INTO provider_cells (model, provider, state, class, since, cooldown_until) VALUES (?,?,?,?,?,?)"
                " ON CONFLICT(model, provider) DO UPDATE SET state = excluded.state, class = excluded.class,"
                " since = excluded.since, cooldown_until = excluded.cooldown_until",
                (model, provider, state, klass, now, cooldown_until))

    def cells_count(self, now: float) -> dict[str, int]:
        """Cells by state at `now` — an exclusion past its cooldown counts as a candidate."""
        with self._lock:
            rows = self._db.execute("SELECT state, cooldown_until, COUNT(*) AS n FROM provider_cells GROUP BY state, cooldown_until").fetchall()
        out: dict[str, int] = {}
        for r in rows:
            state = "candidate" if r["state"] == "excluded" and r["cooldown_until"] is not None and now >= r["cooldown_until"] else r["state"]
            out[state] = out.get(state, 0) + int(r["n"])
        return out

    def canary_sessions_since(self, since: float) -> int:
        with self._lock:
            (n,) = self._db.execute("SELECT COUNT(*) FROM sessions WHERE canary_provider IS NOT NULL AND created_at >= ?", (since,)).fetchone()
        return int(n)

    def canary_usage_since(self, since: float) -> list[tuple[str, str, int, int, int, int]]:
        """The canary sessions' 2xx requests since `since`: (model, provider, tokens_in, cache_read,
        cache_write, tokens_out) — the budget meter's ledger."""
        with self._lock:
            rows = self._db.execute(
                "SELECT s.model, s.canary_provider, r.tokens_in, r.tokens_cache_read, r.tokens_cache_write, r.tokens_out"
                " FROM requests r JOIN sessions s ON s.id = r.session_id"
                " WHERE s.canary_provider IS NOT NULL AND r.ts > ? AND r.status BETWEEN 200 AND 299", (since,)).fetchall()
        return [(r[0], r[1], int(r[2]), int(r[3]), int(r[4]), int(r[5])) for r in rows]

    def meta_get(self, key: str) -> float | None:
        with self._lock:
            row = self._db.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        return float(row[0]) if row else None

    def meta_set(self, key: str, value: float) -> None:
        with self._lock:
            self._db.execute("INSERT INTO meta (key, value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", (key, value))

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
