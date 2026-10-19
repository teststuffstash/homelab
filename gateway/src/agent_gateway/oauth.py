"""The codex rail's OAuth lifecycle behind a persistence interface (GW-CODEX-OAUTH).

The native exchange and Store are injected. Production uses sqlite_oauth.SqliteStore
with the ESO seed as an import; rotations remain gateway-local (operator 2026-10-19).

The store contract: one account per store; `lock()` is exclusive across ALL owners and spans load →
exchange → save; `save` atomically replaces the record and acknowledges only after durability; a
`save` exception may mean the write committed, so callers reload and never assume. Before
contacting upstream the lifecycle persists `refreshing`; it returns a rotated access token only
after saving `ready` with the replacement. A persisted `refreshing` (a crash or an uncertain
exchange) fails closed as `credential-recovery-required` — never an automatic retry, because
replaying an already-rotated refresh token is the one unrecoverable move.

Credentials never appear in reprs or in boundary exception messages/chains (`Failure` is raised
outside the `except` block); consumers must still never serialise a `Credential`.
"""

from __future__ import annotations

import math
from collections.abc import Callable
from contextlib import AbstractContextManager
from dataclasses import dataclass, field, replace
from enum import StrEnum
from typing import Protocol


class Code(StrEnum):
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
    """An exchange maps an authoritative invalid_grant / revocation to this type."""


@dataclass(frozen=True)
class Credential:
    access_token: str = field(repr=False)
    refresh_token: str = field(repr=False)
    account_id: str = field(repr=False)
    expires_at: float


@dataclass(frozen=True)
class Record:
    credential: Credential = field(repr=False)
    state: str = "ready"  # ready | refreshing | revoked


class Store(Protocol):
    def lock(self) -> AbstractContextManager: ...
    def load(self) -> Record: ...
    def save(self, record: Record) -> None: ...


def finite(value) -> bool:
    return type(value) in (int, float) and math.isfinite(value)


def valid(credential, now: float) -> bool:
    return (isinstance(credential, Credential)
            and all(isinstance(v, str) and v and not any(c in v for c in "\r\n")
                    for v in (credential.access_token, credential.refresh_token, credential.account_id))
            and finite(credential.expires_at) and credential.expires_at > now)


class Lifecycle:
    def __init__(self, store: Store, exchange: Callable[[Credential], Credential], clock: Callable[[], float],
                 margin: float):
        if not finite(margin) or margin < 0:
            raise ValueError("invalid refresh margin")
        self.store, self.exchange, self.clock, self.margin = store, exchange, clock, margin

    def acquire(self) -> Credential:
        """A usable access credential, refreshing once under the store lock when it is within
        `margin` of expiry. Raises `Failure(code)` — never anything carrying a credential."""
        code = None
        try:
            with self.store.lock():
                result = self._acquire()
        except Failure as error:
            code = error.code
        except Exception:  # noqa: BLE001 — every store/lock fault is the same fixed code
            code = Code.STORE
        if code is not None:
            # Outside the except block: no secret-bearing exception context / traceback chain.
            raise Failure(code)
        return result

    def status(self) -> Code | None:
        """The admission read (GW-CODEX-HEADROOM's sibling): None when the durable record is
        `ready`, else the code `acquire` would fail with — without refreshing anything."""
        code = None
        try:
            with self.store.lock():
                state = self.store.load().state
        except Exception:  # noqa: BLE001
            code = Code.STORE
        if code is not None:
            return code
        if state == "revoked":
            return Code.REVOKED
        return None if state == "ready" else Code.RECOVERY

    def _acquire(self) -> Credential:
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
        # Write-ahead marker: survives a crash after rotation, before the replacement persists.
        self.store.save(replace(record, state="refreshing"))
        try:
            new = self.exchange(old)
        except Revoked:
            self.store.save(replace(record, state="revoked"))
            raise Failure(Code.REVOKED) from None
        except Exception:  # noqa: BLE001 — an exchange that may have rotated is uncertain, whatever it raised
            raise Failure(Code.REFRESH) from None
        if not valid(new, self.clock()) or new.account_id != old.account_id:
            raise Failure(Code.INVALID)
        self.store.save(Record(new))
        return new

    def revoke(self) -> None:
        code = None
        try:
            with self.store.lock():
                self.store.save(replace(self.store.load(), state="revoked"))
        except Exception:  # noqa: BLE001
            code = Code.STORE
        if code:
            raise Failure(code)
