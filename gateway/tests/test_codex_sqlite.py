"""Durable ownership decision table (GW-CODEX-OAUTH, the gateway-local SQLite store).

| description | sequence | result |
| seed once | empty database | ready |
| seed unchanged is not imported again | rotate, restart | rotation retained |
| changed seed replaces ⚖ | rotate, replace seed (the record carries a `refreshing` marker) | new ready record — the marker is replaced too |
| restart recovers state | revoke, restart | revoked |
| crash between exchange and save ⚖ | child exits in exchange | `refreshing` persists; `credential-recovery-required` until a changed seed |
| memory fallback is refused | :memory: | unavailable |

Every value below is OBSERVED from the store after the step (durable state, the retained
refresh token's identity, the owner's import count, the failure code) — never a bare boolean.
Dummy credentials only.
"""
import json
import multiprocessing
import os
from dataclasses import asdict

import pytest

from agent_gateway.oauth import Code, Credential, Failure, Lifecycle, Record
from agent_gateway.sqlite_oauth import SqliteStore

from .conftest import attach_json, given, rule, then_eq, when, world

pytestmark = rule("GW-CODEX-OAUTH")
OLD = Credential("DUMMY-SECRET-access", "DUMMY-SECRET-refresh", "dummy-account", 1001)
NEW = Credential("DUMMY-SECRET-new", "DUMMY-SECRET-new-refresh", "dummy-account", 9000)
RESEED = Credential("DUMMY-SECRET-reseed", "DUMMY-SECRET-reseed-refresh", "dummy-account", 10000)
NAMES = {OLD.refresh_token: "seed", NEW.refresh_token: "rotation", RESEED.refresh_token: "reseed"}


def crash_exchange(_):
    os._exit(42)


def crash_worker(path, seed):
    Lifecycle(SqliteStore(path, seed), crash_exchange, lambda: 1000, 30).acquire()


def observed(store: SqliteStore) -> dict:
    """The durable row as this owner reads it — state + WHICH refresh token (by name, never the value)."""
    with store.lock():
        record = store.load()
    return {"state": record.state, "refresh_token": NAMES.get(record.credential.refresh_token, "other"),
            "imports_by_this_owner": store.imports}


def test_seed_once(tmp_path):
    """row: seed once"""
    world("policy-codex")
    path, seed = str(tmp_path / "gateway.db"), tmp_path / "seed"
    with given("an empty database and a mounted seed (the dummy OLD record)"):
        seed.write_text(json.dumps(asdict(OLD)))
    with when("the first owner opens the store"):
        got = observed(SqliteStore(path, str(seed)))
        attach_json("durable row after the first open", got)
    then_eq("durable state", got["state"], "ready")
    then_eq("refresh token held", got["refresh_token"], "seed")
    then_eq("imports by this owner", got["imports_by_this_owner"], 1)


def test_seed_unchanged(tmp_path):
    """row: seed unchanged is not imported again"""
    world("policy-codex")
    path, seed = str(tmp_path / "gateway.db"), tmp_path / "seed"
    with given("a seeded store whose owner rotated the credential (ready), then exited"):
        seed.write_text(json.dumps(asdict(OLD)))
        first = SqliteStore(path, str(seed))
        with first.lock():
            first.save(Record(NEW))
    with when("a new owner opens the store on the UNCHANGED seed bytes"):
        restarted = SqliteStore(path, str(seed))
        got = observed(restarted)
        attach_json("durable row after the restart", got)
    then_eq("durable state", got["state"], "ready")
    then_eq("refresh token held (the rotation, not the seed)", got["refresh_token"], "rotation")
    then_eq("imports by the restarted owner", got["imports_by_this_owner"], 0)


def test_seed_changed(tmp_path):
    """row: changed seed replaces ⚖"""
    world("policy-codex")
    path, seed = str(tmp_path / "gateway.db"), tmp_path / "seed"
    with given("a seeded store whose owner rotated and left a `refreshing` marker, then exited"):
        seed.write_text(json.dumps(asdict(OLD)))
        first = SqliteStore(path, str(seed))
        with first.lock():
            first.save(Record(NEW, "refreshing"))
        before = observed(first)
        attach_json("durable row before the reseed", before)
    with when("the seed bytes change (a fresh login's RESEED record) and a new owner opens the store"):
        seed.write_text(json.dumps(asdict(RESEED)))
        restarted = SqliteStore(path, str(seed))
        got = observed(restarted)
        attach_json("durable row after the reseed", got)
    then_eq("marker before → state after", (before["state"], got["state"]), ("refreshing", "ready"))
    then_eq("refresh token held", got["refresh_token"], "reseed")
    then_eq("imports by the restarted owner", got["imports_by_this_owner"], 1)


def test_restart_recovers_state(tmp_path):
    """row: restart recovers state"""
    world("policy-codex")
    path, seed = str(tmp_path / "gateway.db"), tmp_path / "seed"
    with given("a seeded store whose owner persisted `revoked`, then exited"):
        seed.write_text(json.dumps(asdict(OLD)))
        first = SqliteStore(path, str(seed))
        with first.lock():
            first.save(Record(NEW, "revoked"))
    with when("a new owner opens the store"):
        got = observed(SqliteStore(path, str(seed)))
        attach_json("durable row after the restart", got)
    then_eq("durable state after the restart", got["state"], "revoked")
    then_eq("imports by the restarted owner", got["imports_by_this_owner"], 0)


def test_crash_between_exchange_and_save(tmp_path):
    """row: crash between exchange and save ⚖"""
    world("policy-codex")
    path, seed = str(tmp_path / "gateway.db"), tmp_path / "seed"
    with given("a seeded store (OLD, 1 s from expiry) and a child owner whose exchange exits the process"):
        seed.write_text(json.dumps(asdict(OLD)))
    with when("the child acquires (refresh → exchange → os._exit(42)); the parent then acquires, is reseeded, acquires again"):
        child = multiprocessing.get_context("spawn").Process(target=crash_worker, args=(path, str(seed)))
        child.start()
        child.join(10)
        assert not child.is_alive()
        store = SqliteStore(path, str(seed))
        after_crash = observed(store)
        life = Lifecycle(store, lambda _: NEW, lambda: 1000, 30)
        with pytest.raises(Failure) as error:
            life.acquire()
        next_acquire = str(error.value.code)
        seed.write_text(json.dumps(asdict(RESEED)))
        reseeded = NAMES.get(life.acquire().refresh_token, "other")
        after_reseed = observed(store)
        attach_json("sequence", {"child_exitcode": child.exitcode, "after_crash": after_crash, "next_acquire": next_acquire,
                                 "acquired_after_reseed": reseeded, "after_reseed": after_reseed})
    then_eq("child exit code", child.exitcode, 42)
    then_eq("durable state after the child exit", after_crash["state"], "refreshing")
    then_eq("next acquire fails with", next_acquire, str(Code.RECOVERY))
    then_eq("after a changed seed: acquire returns", reseeded, "reseed")
    then_eq("durable state after the reseed", after_reseed["state"], "ready")


def test_memory_refused(tmp_path):
    """row: memory fallback is refused"""
    world("policy-codex")
    seed = tmp_path / "seed"
    with given("a mounted seed and a store path of `:memory:`"):
        seed.write_text(json.dumps(asdict(OLD)))
    with when("the lifecycle acquires through a `:memory:` store"):
        life = Lifecycle(SqliteStore(":memory:", str(seed)), lambda _: NEW, lambda: 1000, 30)
        with pytest.raises(Failure) as error:
            life.acquire()
        code = str(error.value.code)
        attach_json("failure", {"code": code})
    then_eq("failure code for :memory:", code, str(Code.STORE))
