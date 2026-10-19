"""Gateway-local native credential ownership (GW-CODEX-OAUTH).

The separate flock spans exchange; SQLite transactions stay short so session writes proceed.
Every save commits with synchronous=FULL, including the write-ahead refreshing marker.
The mounted ESO seed is an import, never a write-back destination.
"""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
import sqlite3
import threading
from contextlib import contextmanager
from dataclasses import replace
from pathlib import Path

from .oauth import Code, Credential, Failure, Record, finite, valid

MAX_SEED_BYTES = 65536


class SqliteStore:
    def __init__(self, path: str, seed_file: str):
        self.path = str(Path(path).resolve()) if path and path != ":memory:" else ""
        self.seed_file = seed_file
        self.mutex = threading.Lock()
        self.db = None
        self.imports = 0  # seed imports by THIS owner (evidence: a restart on an unchanged seed imports nothing)

    @contextmanager
    def lock(self):
        code = None
        try:
            if not self.path:
                raise ValueError
            with self.mutex:
                fd = os.open(self.path + ".codex.lock", os.O_CREAT | os.O_RDWR, 0o600)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX)
                    db_fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
                    os.fchmod(db_fd, 0o600)
                    os.close(db_fd)
                    self.db = sqlite3.connect(self.path, timeout=10)
                    try:
                        self.db.execute("PRAGMA synchronous=FULL")
                        self.db.execute("""CREATE TABLE IF NOT EXISTS codex_oauth (
                            id INTEGER PRIMARY KEY CHECK(id=1), access TEXT NOT NULL,
                            refresh TEXT NOT NULL, account TEXT NOT NULL, expires REAL NOT NULL,
                            state TEXT NOT NULL, seed_hash TEXT NOT NULL)""")
                        self._seed()
                        yield
                    finally:
                        self.db.close()
                        self.db = None
                finally:
                    os.close(fd)
        except Failure as error:
            code = error.code
        except Exception:  # noqa: BLE001 — do not expose SQLite/seed exception contents
            code = Code.STORE
        if code is not None:
            raise Failure(code)

    def _seed(self):
        row = self.db.execute("SELECT seed_hash FROM codex_oauth WHERE id=1").fetchone()
        try:
            with open(self.seed_file, "rb") as source:
                raw = source.read(MAX_SEED_BYTES + 1)
        except FileNotFoundError:
            if row:
                return
            raise ValueError from None
        if len(raw) > MAX_SEED_BYTES:
            raise ValueError
        digest = hashlib.sha256(raw).hexdigest()
        if row and row[0] == digest:
            return  # no decoding/re-import; a rotated record and its marker win over the seed
        doc = json.loads(raw)
        credential = Credential(**doc)
        if not finite(credential.expires_at) or not valid(replace(credential, expires_at=1), 0):
            raise ValueError
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO codex_oauth VALUES (1,?,?,?,?,?,?)",
                            (credential.access_token, credential.refresh_token, credential.account_id,
                             credential.expires_at, "ready", digest))
        self.imports += 1

    def load(self) -> Record:
        row = self.db.execute("SELECT access,refresh,account,expires,state FROM codex_oauth WHERE id=1").fetchone()
        if row is None:
            raise ValueError("credential absent")
        return Record(Credential(*row[:4]), row[4])

    def save(self, record: Record) -> None:
        c = record.credential
        with self.db:
            self.db.execute("UPDATE codex_oauth SET access=?,refresh=?,account=?,expires=?,state=? WHERE id=1",
                            (c.access_token, c.refresh_token, c.account_id, c.expires_at, record.state))
