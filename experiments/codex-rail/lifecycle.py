"""Offline OAuth state machine; no HTTP, vendor registration, or secret backend."""
from contextlib import AbstractContextManager
from dataclasses import dataclass, field, replace
from enum import Enum
import math
from typing import Protocol, Callable


class Code(str, Enum):
    STORE = "credential-store-unavailable"
    RECOVERY = "credential-recovery-required"
    REVOKED = "credential-revoked"
    REFRESH = "credential-refresh-uncertain"
    INVALID = "credential-invalid"


class Failure(Exception):
    def __init__(self, code: Code):
        self.code = code
        super().__init__(code.value)


class Revoked(Exception):
    """Transport maps an authoritative invalid_grant/revocation to this type."""


@dataclass(frozen=True)
class Credential:
    access_token: str = field(repr=False)
    refresh_token: str = field(repr=False)
    account_id: str = field(repr=False)
    expires_at: float


@dataclass(frozen=True)
class Record:
    credential: Credential = field(repr=False)
    state: str = "ready"


class Store(Protocol):
    """One account per store. Lock spans load, remote exchange, and durable save.

    All owners MUST share this lock (fenced across processes in production).
    Save atomically replaces the record and acknowledges only after durability.
    An exception may mean a write committed: callers must reload, never assume.
    """
    def lock(self) -> AbstractContextManager: ...
    def load(self) -> Record: ...
    def save(self, record: Record) -> None: ...


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def valid(credential, now):
    return (isinstance(credential, Credential)
            and all(isinstance(v, str) and v and not any(c in v for c in '\r\n')
                    for v in (credential.access_token, credential.refresh_token, credential.account_id))
            and finite(credential.expires_at) and credential.expires_at > now)


class Lifecycle:
    def __init__(self, store: Store, exchange: Callable, clock: Callable, margin=30):
        if not finite(margin) or margin < 0:
            raise ValueError("invalid refresh margin")
        self.store, self.exchange, self.clock, self.margin = store, exchange, clock, margin

    def acquire(self) -> Credential:
        # Sanitize at the outermost boundary, including lock enter/exit and backend errors.
        code = None
        try:
            with self.store.lock():
                result = self._acquire()
        except Failure as error:
            code = error.code
        except Exception:
            code = Code.STORE
        if code is not None:
            # Outside the except block: no secret-bearing exception context/traceback chain.
            raise Failure(code)
        return result

    def _acquire(self):
        record = self.store.load()
        if record.state == "revoked":
            raise Failure(Code.REVOKED)
        if record.state != "ready":
            raise Failure(Code.RECOVERY)
        now = self.clock()
        if not finite(now):
            raise Failure(Code.INVALID)
        old = record.credential
        if not isinstance(old, Credential):
            raise Failure(Code.INVALID)
        # Validate token fields even when expired; expiry itself triggers refresh.
        if not finite(old.expires_at) or not valid(replace(old, expires_at=now + 1), now):
            raise Failure(Code.INVALID)
        if old.expires_at > now + self.margin:
            return old
        # Write-ahead marker survives crash after rotation, before replacement persistence.
        # Never automatically retry a refresh from this state, even after restart.
        self.store.save(replace(record, state="refreshing"))
        try:
            new = self.exchange(old)
        except Revoked:
            self.store.save(replace(record, state="revoked"))
            raise Failure(Code.REVOKED) from None
        except Exception:
            raise Failure(Code.REFRESH) from None
        if not valid(new, self.clock()) or new.account_id != old.account_id:
            raise Failure(Code.INVALID)
        self.store.save(Record(new))
        return new

    def revoke(self):
        code = None
        try:
            with self.store.lock():
                self.store.save(replace(self.store.load(), state="revoked"))
        except Exception:
            code = Code.STORE
        if code:
            raise Failure(code)
