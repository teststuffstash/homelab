"""GW-CODEX-OAUTH — the codex credential's lifecycle behind the persistence interface, FAKE store only
(specs/endpoints/openai-responses.md). World `policy-codex` (refresh_margin_s 30). Ported from
experiments/codex-rail/test_lifecycle.py (FU-270); the gateway rows are new.

The lifecycle (oauth.Lifecycle + tests/_codex_world.MemoryStore):

| description | store state, exchange | result | exchanges | durable state after |
|---|---|---|---|---|
| concurrent owners share one rotation | ready, near expiry; 16 owners | every owner gets the rotation | 1 | ready, rotated |
| a fresh credential is returned without refresh | 100 s from expiry | the stored credential | 0 | unchanged |
| the marker is durable before the exchange | near expiry | rotated | 1, saw refreshing | ready |
| a failed marker write prevents the exchange | marker save raises | store-unavailable; next acquire rotates | 0 then 1 | ready |
| a failed rotation write blocks restart | rotation save raises | store-unavailable, then recovery-required | 1 | refreshing |
| an ambiguous save reloads the committed rotation | rotation save commits then raises | store-unavailable, then the rotation | 1 | ready |
| a crash after the exchange requires recovery | process dies after exchange | recovery-required | 1 | refreshing |
| an uncertain exchange is never retried | exchange times out | refresh-uncertain, then recovery-required | 1 | refreshing |
| revocation survives restart | exchange says revoked | revoked, revoked | 1 | revoked |
| explicit revocation blocks a cached access token | fresh; revoke() | revoked | 0 | revoked |
| an invalid rotation fails closed | other account / CRLF / NaN / expired / none | invalid, then recovery-required | 1 each | refreshing |
| a lock failure is the store class | lock raises | store-unavailable | 0 | unchanged |
| the next refresh uses the persisted rotation | rotated, near expiry again | third credential from the rotated one | 2 | ready |
| a failed revocation save still blocks restart | revoked; that save raises | store-unavailable, then recovery-required | 1 | refreshing |
| a committed-then-failed marker never exchanges | marker commits then raises | store-unavailable, then recovery-required | 0 | refreshing |
| no record or failure shows a credential | any | no DUMMY-SECRET in reprs/messages/tracebacks | - | - |

Through the gateway:

| description | world | admission | data plane |
|---|---|---|---|
| a near-expiry credential rotates on first use | 1 s from expiry | dispatch | 200, rotated bearer, one exchange |
| a revoked credential is not admissible | revoked | defer credential-unresolved | - |
| a recovery-required credential is not admissible | refreshing | defer credential-unresolved | - |
| a store that does not answer at admission is transient | lock raises | 503 credential-transient | - |
| a revocation mid-session refuses before upstream | admitted, revoked | - | 401 credential-revoked, upstream not called |
| an uncertain refresh refuses, then stays refused | exchange times out | - | 401 refresh-uncertain, then 401 recovery-required |
| a store fault on the data plane is retriable | marker save raises | - | 503 credential-store-unavailable, retry-after 60 |
| no backend: the rail is a definitive miss | create_app without a store | defer credential-unresolved | - |
| the deployed policy declares no codex rail | argocd/resources/agent-gateway/policy.json | no codex rail | - |
"""

from __future__ import annotations

import dataclasses
import json
import traceback
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from dataclasses import replace

import httpx
import pytest

from agent_gateway.app import create_app
from agent_gateway.config import Policy
from agent_gateway.oauth import Code, Failure, Lifecycle, Record, Revoked

from ._codex_world import (
    CODEX_BASE,
    MemoryStore,
    admitted,
    codex_session,
    creds,
    fresh_report,
    observe,
    ride,
)
from .conftest import ISLAND, Clock, attach_json, check, err, given, rule, then, then_eq, when, world

pytestmark = rule("GW-CODEX-OAUTH")

MARGIN = 30.0  # policy-codex rails.codex.oauth.refresh_margin_s


class Lab:
    """One account's FAKE store + a counting exchange; `owner()` = a fresh gateway process."""

    def __init__(self):
        self.clock = Clock(1000.0)
        self.old, self.new = creds(self.clock)  # old expires at now+1 (inside the margin), new at now+2000
        self.store = MemoryStore(self.old)
        self.calls = 0
        self.saw: list[str] = []

    def exchange(self, old):
        assert old == self.old, "the exchange must be handed the stored credential"
        self.saw.append(self.store.record.state)
        self.calls += 1
        return self.new

    def owner(self, exchange=None) -> Lifecycle:
        return Lifecycle(self.store, exchange or self.exchange, self.clock, MARGIN)

    def failure(self, owner, code: Code) -> None:
        try:
            owner.acquire()
        except Failure as error:
            assert error.code == code, (error.code, code)
            assert "DUMMY-SECRET" not in "".join(traceback.format_exception(error))
            assert error.__context__ is None
        else:
            raise AssertionError("expected a typed failure")


def _then_failure(lab, owner, code, claim=None):
    with then(claim or f"acquire fails {code.value} (no DUMMY-SECRET in the traceback, no exception context)"):
        lab.failure(owner, code)


def _then_state(lab, state, calls):
    then_eq("(durable state, exchanges)", (lab.store.record.state, lab.calls), (state, calls))


def test_concurrent_owners():
    """row: concurrent owners share one rotation"""
    world("policy-codex")
    lab = Lab()
    with when("16 owners acquire at once"):
        with ThreadPoolExecutor(max_workers=16) as pool:
            results = list(pool.map(lambda o: o.acquire(), [lab.owner() for _ in range(16)]))
    then_eq("every owner got the rotation", results == [lab.new] * 16, True)
    _then_state(lab, "ready", 1)
    then_eq("a restarted owner reads the rotation", lab.owner().acquire() == lab.new, True)
    then_eq("stored refresh token is the rotated one", lab.store.record.credential.refresh_token == lab.new.refresh_token, True)


def test_fresh():
    """row: a fresh credential is returned without refresh"""
    world("policy-codex")
    lab = Lab()
    lab.store.record = Record(replace(lab.old, expires_at=lab.clock.t + 100))
    with when("acquire 100 s before expiry (margin 30 s)"):
        got = lab.owner().acquire()
    then_eq("the stored credential", got.expires_at, lab.clock.t + 100)
    _then_state(lab, "ready", 0)


def test_marker_first():
    """row: the marker is durable before the exchange"""
    world("policy-codex")
    lab = Lab()
    with when("acquire 1 s before expiry"):
        got = lab.owner().acquire()
    then_eq("rotated", got == lab.new, True)
    then_eq("state the exchange saw", lab.saw, ["refreshing"])


def test_marker_write_fails():
    """row: a failed marker write prevents the exchange"""
    world("policy-codex")
    lab = Lab()
    lab.store.fail_at = 1
    with when("acquire; save #1 (the marker) raises"):
        pass
    _then_failure(lab, lab.owner(), Code.STORE)
    then_eq("exchanges", lab.calls, 0)
    then_eq("the next acquire rotates", lab.owner().acquire() == lab.new, True)


def test_rotation_write_fails():
    """row: a failed rotation write blocks restart"""
    world("policy-codex")
    lab = Lab()
    lab.store.fail_at = 2
    with when("acquire; save #2 (the rotation) raises"):
        pass
    _then_failure(lab, lab.owner(), Code.STORE)
    _then_failure(lab, lab.owner(), Code.RECOVERY, claim="the restarted owner fails credential-recovery-required")
    _then_state(lab, "refreshing", 1)


def test_ambiguous_save():
    """row: an ambiguous save reloads the committed rotation"""
    world("policy-codex")
    lab = Lab()
    lab.store.fail_at, lab.store.commit_then_fail = 2, True
    with when("acquire; save #2 commits, then raises"):
        pass
    _then_failure(lab, lab.owner(), Code.STORE)
    then_eq("the next acquire reads the committed rotation", lab.owner().acquire() == lab.new, True)
    _then_state(lab, "ready", 1)


def test_crash_after_exchange():
    """row: a crash after the exchange requires recovery"""
    world("policy-codex")
    lab = Lab()

    def crash(old):
        lab.exchange(old)
        raise SystemExit("simulated power loss")
    with when("acquire; the process dies right after the exchange"):
        with pytest.raises(SystemExit):
            lab.owner(crash).acquire()
    _then_failure(lab, lab.owner(), Code.RECOVERY)
    _then_state(lab, "refreshing", 1)


def test_uncertain_exchange():
    """row: an uncertain exchange is never retried"""
    world("policy-codex")
    lab = Lab()

    def timeout(old):
        lab.calls += 1
        raise TimeoutError("DUMMY-SECRET upstream response")
    with when("acquire; the exchange times out"):
        pass
    _then_failure(lab, lab.owner(timeout), Code.REFRESH)
    _then_failure(lab, lab.owner(), Code.RECOVERY)
    _then_state(lab, "refreshing", 1)


def test_revocation_survives():
    """row: revocation survives restart"""
    world("policy-codex")
    lab = Lab()

    def revoked(old):
        lab.calls += 1
        raise Revoked("DUMMY-SECRET invalid grant")
    with when("acquire; the exchange says revoked"):
        pass
    _then_failure(lab, lab.owner(revoked), Code.REVOKED)
    _then_failure(lab, lab.owner(), Code.REVOKED)
    _then_state(lab, "revoked", 1)


def test_explicit_revocation():
    """row: explicit revocation blocks a cached access token"""
    world("policy-codex")
    lab = Lab()
    lab.store.record = Record(replace(lab.old, expires_at=lab.clock.t + 100))
    with when("revoke() a fresh credential, then acquire"):
        lab.owner().revoke()
    _then_failure(lab, lab.owner(), Code.REVOKED)
    _then_state(lab, "revoked", 0)


INVALID = [("another account", {"account_id": "other"}), ("CR-LF in a token", {"access_token": "bad\n"}),
           ("NaN expiry", {"expires_at": float("nan")}), ("already expired", {"expires_at": 999.0}), ("none", None)]


def test_invalid_rotation():
    """row: an invalid rotation fails closed"""
    world("policy-codex")
    with when("acquire with each invalid replacement: " + ", ".join(n for n, _ in INVALID)):
        for name, change in INVALID:
            lab = Lab()
            bad = None if change is None else replace(lab.new, **change)

            def ex(old, bad=bad, lab=lab):
                lab.calls += 1
                return bad
            with then(f"{name}: credential-invalid, then credential-recovery-required, 1 exchange"):
                lab.failure(lab.owner(ex), Code.INVALID)
                lab.failure(lab.owner(), Code.RECOVERY)
                assert (lab.store.record.state, lab.calls) == ("refreshing", 1)


def test_lock_failure():
    """row: a lock failure is the store class"""
    world("policy-codex")
    lab = Lab()

    @contextmanager
    def broken():
        raise RuntimeError("DUMMY-SECRET lock error")
        yield
    lab.store.lock = broken
    with when("acquire; the lock raises"):
        pass
    _then_failure(lab, lab.owner(), Code.STORE)
    _then_state(lab, "ready", 0)


def test_next_refresh_uses_rotation():
    """row: the next refresh uses the persisted rotation"""
    world("policy-codex")
    lab = Lab()
    lab.owner().acquire()
    lab.clock.t = lab.new.expires_at - 10  # inside the 30 s margin again
    third = replace(lab.new, expires_at=lab.clock.t + 3000, refresh_token="DUMMY-SECRET-third")
    handed = []

    def ex(rotated):
        handed.append(rotated)
        return third
    with when("acquire 10 s before the rotation's expiry"):
        got = lab.owner(ex).acquire()
    then_eq("the third credential", got == third, True)
    then_eq("exchanged from the persisted rotation", handed == [lab.new], True)


def test_revocation_save_fails():
    """row: a failed revocation save still blocks restart"""
    world("policy-codex")
    lab = Lab()
    lab.store.fail_at = 2

    def revoked(old):
        lab.calls += 1
        raise Revoked("DUMMY-SECRET revoked")
    with when("acquire; the exchange says revoked; that save (#2) raises"):
        pass
    _then_failure(lab, lab.owner(revoked), Code.STORE)
    _then_failure(lab, lab.owner(), Code.RECOVERY)
    _then_state(lab, "refreshing", 1)


def test_marker_commit_then_fail():
    """row: a committed-then-failed marker never exchanges"""
    world("policy-codex")
    lab = Lab()
    lab.store.fail_at, lab.store.commit_then_fail = 1, True
    with when("acquire; save #1 (the marker) commits, then raises"):
        pass
    _then_failure(lab, lab.owner(), Code.STORE)
    _then_failure(lab, lab.owner(), Code.RECOVERY)
    _then_state(lab, "refreshing", 0)


def test_reprs_redact():
    """row: no record or failure shows a credential"""
    world("policy-codex")
    lab = Lab()
    with when("repr the credential, the record and a Failure"):
        shown = [repr(lab.old), repr(lab.store.record), repr(Failure(Code.REVOKED)), str(Failure(Code.STORE))]
        attach_json("reprs", shown)
    then_eq("DUMMY-SECRET in any", any("DUMMY-SECRET" in s for s in shown), False)


# -- through the gateway --------------------------------------------------------------------------

def _post_codex(gw):
    return gw.post("/sessions", json={"stack": "platform", "role": "prober", "task": "t", "harness": "codex"})


async def test_rotates_on_first_use(codex_app, codex_gw, codex_upstream, exchange, clock):
    """row: a near-expiry credential rotates on first use"""
    world("policy-codex", "upstream-ok")
    observe(codex_app, fresh_report(clock))
    with given("a codex session; the stored credential is 1 s from expiry"):
        doc = await codex_session(codex_gw)
    r = await ride(codex_gw, doc)
    then_eq("status", r.status_code, 200)
    then_eq("upstream bearer", codex_upstream.calls[-1]["headers"]["authorization"], "Bearer " + exchange.rotated.access_token)
    then_eq("exchanges", exchange.calls, 1)


@pytest.mark.parametrize("state", ["revoked", "refreshing"],
                         ids=["a revoked credential is not admissible", "a recovery-required credential is not admissible"])
async def test_state_not_admissible(codex_app, codex_gw, codex_store, clock, state):
    world("policy-codex")
    observe(codex_app, fresh_report(clock))
    with given(f"the durable state is {state}"):
        codex_store.record = replace(codex_store.record, state=state)
    with when("POST /sessions {role: prober, harness: codex}"):
        r = await _post_codex(codex_gw)
    then_eq("(decision, reason)", (r.json()["decision"], r.json()["reason"]), ("defer", "credential-unresolved"))


async def test_store_away_at_admission(codex_app, codex_gw, codex_store, clock):
    """row: a store that does not answer at admission is transient"""
    world("policy-codex")
    observe(codex_app, fresh_report(clock))

    def broken():
        raise RuntimeError("DUMMY-SECRET store down")
    with given("the store's lock raises"):
        codex_store.lock = broken
    with when("POST /sessions {role: prober, harness: codex}"):
        r = await _post_codex(codex_gw)
    then_eq("(status, code)", (r.status_code, err(r)), (503, "credential-transient"))
    then_eq("no DUMMY-SECRET in the answer", "DUMMY-SECRET" in r.text, False)


async def test_revoked_mid_session(codex_app, codex_gw, codex_upstream, clock):
    """row: a revocation mid-session refuses before upstream"""
    world("policy-codex", "upstream-ok")
    observe(codex_app, fresh_report(clock))
    with given("a codex session, then the credential is revoked"):
        doc = await codex_session(codex_gw)
        codex_app.state.codex.lifecycle.revoke()
    r = await ride(codex_gw, doc)
    then_eq("(status, code)", (r.status_code, err(r)), (401, "credential-revoked"))
    then_eq("upstream calls", len(codex_upstream.calls), 0)


async def test_uncertain_refresh_data_plane(codex_app, codex_gw, codex_upstream, exchange, clock):
    """row: an uncertain refresh refuses, then stays refused"""
    world("policy-codex", "upstream-ok")
    doc = await admitted(codex_app, codex_gw, clock)
    with given("the exchange will time out"):
        exchange.fault = TimeoutError("DUMMY-SECRET token endpoint")
    r1 = await ride(codex_gw, doc, label="first")
    then_eq("first (status, code)", (r1.status_code, err(r1)), (401, "credential-refresh-uncertain"))
    with given("the second request"):
        r2 = await codex_gw.post("/openai/v1/responses", json=json.loads(r1.request.content), headers={"authorization": f"Bearer {doc['session']['token']}"})
    then_eq("second (status, code), exchanges, upstream calls", (r2.status_code, err(r2), exchange.calls, len(codex_upstream.calls)),
            (401, "credential-recovery-required", 1, 0))


async def test_store_fault_data_plane(codex_app, codex_gw, codex_store, codex_upstream, clock):
    """row: a store fault on the data plane is retriable"""
    world("policy-codex", "upstream-ok")
    observe(codex_app, fresh_report(clock))
    with given("a codex session; the marker save (#1) will raise"):
        doc = await codex_session(codex_gw)
        codex_store.fail_at = codex_store.writes + 1
    r = await ride(codex_gw, doc)
    then_eq("(status, code, retry-after)", (r.status_code, err(r), r.headers.get("retry-after")), (503, "credential-store-unavailable", "60"))
    then_eq("upstream calls", len(codex_upstream.calls), 0)


async def test_no_backend(settings, codex_policy, secrets, store, codex_transport, clock):
    """row: no backend: the rail is a definitive miss"""
    world("policy-codex")
    with given("create_app with policy-codex and NO credential backend (production today)"):
        client = httpx.AsyncClient(transport=codex_transport)
        s = dataclasses.replace(settings, upstreams={**settings.upstreams, "codex": CODEX_BASE})
        app = create_app(s, policy=codex_policy, source=secrets, store=store, client=client, clock=clock)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://gw") as gw:
        observe(app, fresh_report(clock))
        with when("POST /sessions {role: prober, harness: codex}"):
            r = await _post_codex(gw)
    await client.aclose()
    then_eq("(decision, reason)", (r.json()["decision"], r.json()["reason"]), ("defer", "credential-unresolved"))


DEPLOYED_POLICY = ISLAND.parent / "argocd" / "resources" / "agent-gateway" / "policy.json"


@pytest.mark.skipif(not DEPLOYED_POLICY.exists(), reason="deploy manifests absent (service-only checkout)")
def test_deployed_policy_is_dark():
    """row: the deployed policy declares no codex rail"""
    world("policy-default")
    with when("Policy.from_dict(the deployed policy.json) — the island's loader, the GW-MODEL-RESOLVE reader"):
        policy = Policy.from_dict(json.loads(DEPLOYED_POLICY.read_text(encoding="utf-8")))
        attach_json("deployed rails", sorted(policy.rails))
    with then("rails has no codex key — the rail ships dark"):
        check("codex in rails", "codex" in policy.rails, False)
        check("codex in any role's rails", any("codex" in r.rails for r in policy.roles.values()), False)
