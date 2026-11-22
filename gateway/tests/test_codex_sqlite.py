"""GW-CODEX-OAUTH §Gateway-local durable ownership — the gateway-local SQLite store
(specs/endpoints/openai-responses.md). Argnames = the table's header (`sequence | result? |
refresh_token? | imports?`), ids = its description cells. Every value is OBSERVED from the store after
the step (durable state, WHICH refresh token by name, the owner's import count, the failure code) —
never a bare boolean. Dummy credentials only.
"""

from __future__ import annotations

import json
import multiprocessing
import os
from dataclasses import asdict

import pytest

from agent_gateway.oauth import Code, Credential, Failure, Lifecycle, Record
from agent_gateway.sqlite_oauth import SqliteStore

from ._codex_rows import row, verdicts
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


@pytest.mark.parametrize(("sequence", "expected_result", "expected_refresh_token", "expected_imports"), [
    pytest.param("an empty database, a mounted seed", "ready", "seed", 1, id="seed once"),
    pytest.param("rotate, restart on the same seed bytes", "ready", "rotation", 0, id="seed unchanged is not imported again"),
    pytest.param("rotate and leave a refreshing marker, reseed, restart", "ready", "reseed", 1, id="changed seed replaces ⚖"),
    pytest.param("revoke, restart", "revoked", "rotation", 0, id="restart recovers state"),
    pytest.param("the child exits in the exchange; the parent acquires; reseed; acquire",
                 "refreshing, then credential-recovery-required, then ready after the reseed", "reseed", 1, id="crash between exchange and save ⚖"),
    pytest.param("a :memory: store path", "credential-store-unavailable", "—", "—", id="memory fallback is refused"),
])
def test_durable_ownership(tmp_path, request, sequence, expected_result, expected_refresh_token, expected_imports):
    world("policy-codex")
    row(sequence=sequence, expected_result=expected_result, expected_refresh_token=expected_refresh_token, expected_imports=expected_imports)
    case = request.node.callspec.id
    path, seed = str(tmp_path / "gateway.db"), tmp_path / "seed"
    with given(f"sequence {sequence}: a mounted seed (the dummy OLD record)"):
        seed.write_text(json.dumps(asdict(OLD)))
    if case == "seed once":
        with when("the first owner opens the store"):
            got = observed(SqliteStore(path, str(seed)))
            attach_json("durable row after the first open", got)
    elif case.startswith("seed unchanged"):
        first = SqliteStore(path, str(seed))
        with first.lock():
            first.save(Record(NEW))
        with when("a new owner opens the store on the UNCHANGED seed bytes"):
            got = observed(SqliteStore(path, str(seed)))
            attach_json("durable row after the restart", got)
    elif case.startswith("changed seed"):
        first = SqliteStore(path, str(seed))
        with first.lock():
            first.save(Record(NEW, "refreshing"))
        before = observed(first)
        with when("the seed bytes change (a fresh login's RESEED record) and a new owner opens the store"):
            seed.write_text(json.dumps(asdict(RESEED)))
            got = observed(SqliteStore(path, str(seed)))
            attach_json("durable row before → after the reseed", {"before": before, "after": got})
        then_eq("the marker before the reseed", before["state"], "refreshing")
    elif case.startswith("restart recovers"):
        first = SqliteStore(path, str(seed))
        with first.lock():
            first.save(Record(NEW, "revoked"))
        with when("a new owner opens the store"):
            got = observed(SqliteStore(path, str(seed)))
            attach_json("durable row after the restart", got)
    elif case.startswith("crash between"):
        with when("the child acquires (refresh → exchange → os._exit(42)); the parent acquires, is reseeded, acquires again"):
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
            got = observed(store)
            attach_json("sequence", {"child_exitcode": child.exitcode, "after_crash": after_crash, "next_acquire": next_acquire,
                                     "acquired_after_reseed": reseeded, "after_reseed": got})
        then_eq("child exit code", child.exitcode, 42)
        then_eq("acquire after the reseed returns", reseeded, "reseed")
        verdicts(
            result=(f"{after_crash['state']}, then {next_acquire}, then {got['state']} after the reseed", expected_result),
            refresh_token=(got["refresh_token"], expected_refresh_token),
            imports=(got["imports_by_this_owner"], expected_imports),
        )
        return
    else:
        with when("the lifecycle acquires through a `:memory:` store"):
            life = Lifecycle(SqliteStore(":memory:", str(seed)), lambda _: NEW, lambda: 1000, 30)
            with pytest.raises(Failure) as error:
                life.acquire()
            code = str(error.value.code)
            attach_json("failure", {"code": code})
        verdicts(
            result=(code, expected_result),
            refresh_token=("—", expected_refresh_token),
            imports=("—", expected_imports),
        )
        assert code == str(Code.STORE)
        return
    verdicts(
        result=(got["state"], expected_result),
        refresh_token=(got["refresh_token"], expected_refresh_token),
        imports=(got["imports_by_this_owner"], expected_imports),
    )
