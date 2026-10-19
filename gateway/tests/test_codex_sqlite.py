"""Durable ownership decision table.

| description | sequence | result |
| seed once | empty database | ready |
| seed unchanged is not imported again | rotate, restart | rotation retained |
| changed seed replaces | rotate, replace seed | new ready record |
| restart recovers state | revoke, restart | revoked |
| crash between exchange and save | child exits in exchange | recovery until reseed |
| memory fallback is refused | :memory: | unavailable |
"""
import json
import multiprocessing
import os
from dataclasses import asdict, replace

import pytest

from agent_gateway.oauth import Code, Credential, Failure, Lifecycle, Record
from agent_gateway.sqlite_oauth import SqliteStore

from .conftest import rule, then_eq, when, world

pytestmark = rule("GW-CODEX-OAUTH")
OLD = Credential("DUMMY-SECRET-access", "DUMMY-SECRET-refresh", "dummy-account", 1001)
NEW = replace(OLD, access_token="DUMMY-SECRET-new", refresh_token="DUMMY-SECRET-new-refresh", expires_at=9000)


def crash_exchange(_):
    os._exit(42)


def crash_worker(path, seed):
    Lifecycle(SqliteStore(path, seed), crash_exchange, lambda: 1000, 30).acquire()


@pytest.mark.parametrize("case", ["first", "same", "changed", "restart", "crash", "memory"], ids=[
    "seed once", "seed unchanged is not imported again", "changed seed replaces",
    "restart recovers state", "crash between exchange and save", "memory fallback is refused"])
def test_durable(tmp_path, case):
    world("policy-codex")
    path, seed = str(tmp_path / "gateway.db"), tmp_path / "seed"
    seed.write_text(json.dumps(asdict(OLD)))
    store = SqliteStore(path, str(seed))
    with when("exercise durable ownership: " + case):
        if case == "memory":
            life = Lifecycle(SqliteStore(":memory:", str(seed)), lambda _: NEW, lambda: 1000, 30)
            with pytest.raises(Failure) as error:
                life.acquire()
            result = error.value.code == Code.STORE
        elif case == "crash":
            child = multiprocessing.get_context("spawn").Process(target=crash_worker, args=(path, str(seed)))
            child.start()
            child.join(10)
            assert not child.is_alive()
            life = Lifecycle(store, lambda _: NEW, lambda: 1000, 30)
            with pytest.raises(Failure) as error:
                life.acquire()
            blocked = error.value.code == Code.RECOVERY
            seed.write_text(json.dumps(asdict(NEW)))
            result = child.exitcode == 42 and blocked and life.acquire() == NEW
        else:
            with store.lock():
                initial = store.load() == Record(OLD)
                if case != "first":
                    store.save(Record(NEW, "revoked" if case == "restart" else "ready"))
            if case == "changed":
                seed.write_text(json.dumps(asdict(replace(NEW, expires_at=10000))))
            restarted = SqliteStore(path, str(seed))
            with restarted.lock():
                got = restarted.load()
            expected = {"first": Record(OLD), "same": Record(NEW), "changed": Record(replace(NEW, expires_at=10000)),
                        "restart": Record(NEW, "revoked")}[case]
            result = initial and got == expected
    then_eq("durable ownership contract holds", result, True)
