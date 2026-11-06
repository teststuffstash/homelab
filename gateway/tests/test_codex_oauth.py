"""GW-CODEX-OAUTH — the codex credential's lifecycle behind the persistence interface, FAKE store only
(specs/endpoints/openai-responses.md §GW-CODEX-OAUTH: a rotation, a store fault, the exchange's answer,
admission reads the durable state, the data plane, the deployed policy). World `policy-codex`
(refresh_margin_s 30). Ported from experiments/codex-rail/test_lifecycle.py (FU-270); the gateway rows
are new. Argnames = each table's header, ids = its description cells (the scenario a case runs is keyed
by its id — `request.node.callspec.id`); the durable-ownership table is tests/test_codex_sqlite.py.
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

from ._codex_rows import expect, row, verdicts
from ._codex_world import (
    CODEX_BASE,
    MemoryStore,
    codex_session,
    creds,
    fresh_report,
    observe,
    ride,
)
from .conftest import ISLAND, Clock, attach_json, err, given, rule, then, then_eq, when, world

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

    def acquire(self, exchange=None) -> str:
        """One `acquire()` by a fresh owner → the failure code, or a name for what it returned."""
        try:
            got = self.owner(exchange).acquire()
        except Failure as error:
            assert "DUMMY-SECRET" not in "".join(traceback.format_exception(error))
            assert error.__context__ is None
            return str(error.code)
        return "the rotation" if got == self.new else "the stored credential" if got == self.old else "a credential"

    def state(self) -> str:
        """The durable state after, with the credential's identity when it is `ready`."""
        s = self.store.record.state
        held = self.store.record.credential.refresh_token  # WHICH credential, by its refresh token
        if s == "ready":
            return f"{s}, rotated" if held == self.new.refresh_token else f"{s}, unchanged" if held == self.old.refresh_token else s
        return s


# -- a rotation -----------------------------------------------------------------------------------

def _rotation(case: str, lab: Lab) -> tuple[str, object]:
    """→ (result, exchanges) for the §A rotation row `case`."""
    if case.startswith("concurrent owners"):
        with when("16 owners acquire at once"):
            with ThreadPoolExecutor(max_workers=16) as pool:
                results = list(pool.map(lambda o: o.acquire(), [lab.owner() for _ in range(16)]))
        return ("every owner gets the rotation" if results == [lab.new] * 16 else f"{sum(r == lab.new for r in results)} of 16 got the rotation"), lab.calls
    if case.startswith("a fresh credential"):
        lab.store.record = Record(replace(lab.old, expires_at=lab.clock.t + 100))
        with when("acquire 100 s before expiry (margin 30 s)"):
            got = lab.owner().acquire()
        return ("the stored credential" if got.expires_at == lab.clock.t + 100 else "another credential"), lab.calls
    if case.startswith("the marker is durable"):
        with when("acquire 1 s before expiry"):
            result = lab.acquire()
        return result, f"{lab.calls} — it saw {lab.saw[0]}" if lab.saw else f"{lab.calls}"
    if case.startswith("the next refresh"):
        lab.owner().acquire()
        lab.clock.t = lab.new.expires_at - 10  # inside the 30 s margin again
        third = replace(lab.new, expires_at=lab.clock.t + 3000, refresh_token="DUMMY-SECRET-third")
        handed = []

        def ex(rotated):
            handed.append(rotated)
            lab.calls += 1
            return third
        with when("acquire 10 s before the rotation's expiry"):
            got = lab.owner(ex).acquire()
        return ("the third credential, exchanged from the rotated one" if got == third and handed == [lab.new]
                else f"got {'the third' if got == third else 'another'} credential, exchanged from {'the rotation' if handed == [lab.new] else handed}"), lab.calls
    with when("repr the credential, the record and a Failure"):
        shown = [repr(lab.old), repr(lab.store.record), repr(Failure(Code.REVOKED)), str(Failure(Code.STORE))]
        attach_json("reprs", shown)
    return ("no DUMMY-SECRET in reprs, messages or tracebacks" if not any("DUMMY-SECRET" in s for s in shown) else "a repr shows DUMMY-SECRET"), "—"


@pytest.mark.parametrize(("store", "exchange", "expected_result", "expected_exchanges", "expected_state"), [
    pytest.param("ready, 1 s from expiry; 16 owners at once", "the rotation", "every owner gets the rotation", 1, "ready, rotated",
                 id="concurrent owners share one rotation"),
    pytest.param("ready, 100 s from expiry", "—", "the stored credential", 0, "ready, unchanged", id="a fresh credential is returned without refresh"),
    pytest.param("ready, 1 s from expiry", "the rotation", "the rotation", "1 — it saw refreshing", "ready, rotated", id="the marker is durable before the exchange"),
    pytest.param("rotated once, 10 s from the rotation's expiry", "a third credential", "the third credential, exchanged from the rotated one", 2, "ready",
                 id="the next refresh uses the persisted rotation"),
    pytest.param("any of the above", "—", "no DUMMY-SECRET in reprs, messages or tracebacks", "—", "—", id="no record or failure shows a credential"),
])
def test_rotation(request, store, exchange, expected_result, expected_exchanges, expected_state):
    world("policy-codex")
    row(store=store, exchange=exchange, expected_result=expected_result, expected_exchanges=expected_exchanges, expected_state=expected_state)
    lab = Lab()
    with given(f"store {store}; the exchange returns {exchange}"):
        pass
    result, exchanges = _rotation(request.node.callspec.id, lab)
    verdicts(
        result=(result, expected_result),
        exchanges=(exchanges, expected_exchanges),
        state=("—" if expected_state == "—" else lab.state(), expected_state),
    )
    if request.node.callspec.id.startswith("concurrent owners"):
        then_eq("a restarted owner reads the rotation", lab.owner().acquire() == lab.new, True)


# -- a store fault --------------------------------------------------------------------------------

def _fault(case: str, lab: Lab) -> tuple[str, object]:
    """→ (result, exchanges) for the §A store fault row `case` — two acquires where the row says `then`."""
    if case.startswith("a failed marker write"):
        lab.store.fail_at = 1
        with when("acquire; save #1 (the marker) raises; acquire again"):
            first, calls_first = lab.acquire(), lab.calls
            second = lab.acquire()
        return f"{first}, then {second}", f"{calls_first}, then {lab.calls}"
    if case.startswith("a failed rotation write"):
        lab.store.fail_at = 2
        with when("acquire; save #2 (the rotation) raises; a restarted owner acquires"):
            first, second = lab.acquire(), lab.acquire()
        return f"{first}, then {second}", lab.calls
    if case.startswith("an ambiguous save"):
        lab.store.fail_at, lab.store.commit_then_fail = 2, True
        with when("acquire; save #2 commits, then raises; acquire again"):
            first, second = lab.acquire(), lab.acquire()
        return f"{first}, then {second}", lab.calls
    if case.startswith("a lock failure"):
        @contextmanager
        def broken():
            raise RuntimeError("DUMMY-SECRET lock error")
            yield
        lab.store.lock = broken
        with when("acquire; the lock raises"):
            first = lab.acquire()
        return first, lab.calls
    if case.startswith("a failed revocation save"):
        lab.store.fail_at = 2

        def revoked(old):
            lab.calls += 1
            raise Revoked("DUMMY-SECRET revoked")
        with when("acquire; the exchange says revoked; that save (#2) raises; a restarted owner acquires"):
            first, second = lab.acquire(revoked), lab.acquire()
        return f"{first}, then {second}", lab.calls
    lab.store.fail_at, lab.store.commit_then_fail = 1, True
    with when("acquire; save #1 (the marker) commits, then raises; a restarted owner acquires"):
        first, second = lab.acquire(), lab.acquire()
    return f"{first}, then {second}", lab.calls


@pytest.mark.parametrize(("store", "exchange", "expected_result", "expected_exchanges", "expected_state"), [
    pytest.param("save #1 raises", "—", "credential-store-unavailable, then the rotation", "0, then 1", "ready, rotated",
                 id="a failed marker write prevents the exchange"),
    pytest.param("save #2 raises", "the rotation", "credential-store-unavailable, then credential-recovery-required", 1, "refreshing",
                 id="a failed rotation write blocks restart"),
    pytest.param("save #2 commits, then raises", "the rotation", "credential-store-unavailable, then the rotation", 1, "ready, rotated",
                 id="an ambiguous save reloads the committed rotation"),
    pytest.param("the lock raises", "—", "credential-store-unavailable", 0, "ready, unchanged", id="a lock failure is the store class"),
    pytest.param("save #2 raises", "revoked", "credential-store-unavailable, then credential-recovery-required", 1, "refreshing",
                 id="a failed revocation save still blocks restart ⚖"),
    pytest.param("save #1 commits, then raises", "—", "credential-store-unavailable, then credential-recovery-required", 0, "refreshing",
                 id="a committed-then-failed marker never exchanges"),
])
def test_store_fault(request, store, exchange, expected_result, expected_exchanges, expected_state):
    world("policy-codex")
    row(store=store, exchange=exchange, expected_result=expected_result, expected_exchanges=expected_exchanges, expected_state=expected_state)
    lab = Lab()
    with given(f"store {store}; the exchange returns {exchange}; the stored credential 1 s from expiry"):
        pass
    result, exchanges = _fault(request.node.callspec.id, lab)
    verdicts(
        result=(result, expected_result),
        exchanges=(exchanges, expected_exchanges),
        state=(lab.state(), expected_state),
    )


# -- the exchange's answer ------------------------------------------------------------------------

INVALID = [("another account", {"account_id": "other"}), ("CR-LF in a token", {"access_token": "bad\n"}),
           ("NaN expiry", {"expires_at": float("nan")}), ("already expired", {"expires_at": 999.0}), ("none", None)]


def _answer(case: str, lab: Lab) -> tuple[str, object, str]:
    """→ (result, exchanges, state) for the §The exchange's answer row `case`."""
    if case.startswith("a crash after"):
        def crash(old):
            lab.exchange(old)
            raise SystemExit("simulated power loss")
        with when("acquire; the process dies right after the exchange; a restarted owner acquires"):
            with pytest.raises(SystemExit):
                lab.owner(crash).acquire()
            second = lab.acquire()
        return f"{second} on restart", lab.calls, lab.state()
    if case.startswith("an uncertain exchange"):
        def timeout(old):
            lab.calls += 1
            raise TimeoutError("DUMMY-SECRET upstream response")
        with when("acquire; the exchange times out; a restarted owner acquires"):
            first, second = lab.acquire(timeout), lab.acquire()
        return f"{first}, then {second}", lab.calls, lab.state()
    if case.startswith("revocation survives"):
        def revoked(old):
            lab.calls += 1
            raise Revoked("DUMMY-SECRET invalid grant")
        with when("acquire; the exchange says revoked; a restarted owner acquires"):
            first, second = lab.acquire(revoked), lab.acquire()
        return f"{first}, then {second}", lab.calls, lab.state()
    if case.startswith("explicit revocation"):
        lab.store.record = Record(replace(lab.old, expires_at=lab.clock.t + 100))
        with when("revoke() a fresh credential, then acquire"):
            lab.owner().revoke()
            first = lab.acquire()
        return first, lab.calls, lab.state()
    results, calls, states = [], [], []
    with when("acquire with each invalid replacement: " + ", ".join(n for n, _ in INVALID) + "; a restarted owner acquires each time"):
        for name, change in INVALID:
            each = Lab()
            bad = None if change is None else replace(each.new, **change)

            def ex(old, bad=bad, each=each):
                each.calls += 1
                return bad
            with then(f"{name}: acquire, then the restarted owner"):
                results.append(f"{each.acquire(ex)}, then {each.acquire()}")
                calls.append(each.calls)
                states.append(each.state())
    one = lambda xs: xs[0] if len(set(xs)) == 1 else " / ".join(map(str, xs))  # noqa: E731
    return one(results), (f"{calls[0]} each" if len(set(calls)) == 1 else str(calls)), one(states)


@pytest.mark.parametrize(("exchange", "expected_result", "expected_exchanges", "expected_state"), [
    pytest.param("the process dies right after the exchange", "credential-recovery-required on restart", 1, "refreshing",
                 id="a crash after the exchange requires recovery ⚖"),
    pytest.param("times out", "credential-refresh-uncertain, then credential-recovery-required", 1, "refreshing", id="an uncertain exchange is never retried ⚖"),
    pytest.param("says revoked", "credential-revoked, then credential-revoked", 1, "revoked", id="revocation survives restart"),
    pytest.param("revoke() on a fresh credential", "credential-revoked", 0, "revoked", id="explicit revocation blocks a cached access token"),
    pytest.param("another account / CR-LF in a token / NaN expiry / already expired / none", "credential-invalid, then credential-recovery-required",
                 "1 each", "refreshing", id="an invalid rotation fails closed"),
])
def test_exchanges_answer(request, exchange, expected_result, expected_exchanges, expected_state):
    world("policy-codex")
    row(exchange=exchange, expected_result=expected_result, expected_exchanges=expected_exchanges, expected_state=expected_state)
    lab = Lab()
    with given(f"the stored credential 1 s from expiry; the exchange {exchange}"):
        pass
    result, exchanges, state = _answer(request.node.callspec.id, lab)
    verdicts(
        result=(result, expected_result),
        exchanges=(exchanges, expected_exchanges),
        state=(state, expected_state),
    )


# -- through the gateway: admission ---------------------------------------------------------------

def _post_codex(gw):
    return gw.post("/sessions", json={"stack": "platform", "role": "prober", "task": "t", "harness": "codex"})


@pytest.mark.parametrize(("record", "expected_admission"), [
    pytest.param("revoked", "defer credential-unresolved", id="a revoked credential is not admissible ⚖"),
    pytest.param("refreshing", "defer credential-unresolved", id="a recovery-required credential is not admissible ⚖"),
    pytest.param("the lock raises", "503 credential-transient", id="a store that does not answer at admission is transient ⚖"),
    pytest.param("create_app without a credential store", "defer credential-unresolved", id="no backend: the rail is a definitive miss"),
])
async def test_admission_reads_state(settings, codex_policy, secrets, store, codex_transport, codex_app, codex_gw, codex_store, clock,
                                     record, expected_admission):
    world("policy-codex")
    row(record=record, expected_admission=expected_admission)
    if record.startswith("create_app"):
        with given(f"record {record} (the rail declared, no backend)"):
            client = httpx.AsyncClient(transport=codex_transport)
            s = dataclasses.replace(settings, upstreams={**settings.upstreams, "codex": CODEX_BASE})
            app = create_app(s, policy=codex_policy, source=secrets, store=store, client=client, clock=clock)
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://gw") as gw:
            observe(app, fresh_report(clock))
            with when("POST /sessions {role: prober, harness: codex}"):
                r = await _post_codex(gw)
        await client.aclose()
    else:
        observe(codex_app, fresh_report(clock))
        with given(f"record {record}"):
            if record == "the lock raises":
                def broken():
                    raise RuntimeError("DUMMY-SECRET store down")
                codex_store.lock = broken
            else:
                codex_store.record = replace(codex_store.record, state=record)
        with when("POST /sessions {role: prober, harness: codex}"):
            r = await _post_codex(codex_gw)
    body = r.json()
    admission = f"{body['decision']} {body['reason']}" if r.status_code == 200 and "decision" in body else f"{r.status_code} {err(r)}"
    expect("admission", admission, expected_admission)
    then_eq("no DUMMY-SECRET in the answer", "DUMMY-SECRET" in r.text, False)


# -- through the gateway: the data plane ----------------------------------------------------------

@pytest.mark.parametrize(("record", "expected_status", "expected_code", "expected_retry_after", "expected_upstream_calls", "expected_exchanges"), [
    pytest.param("ready, 1 s from expiry", 200, "—", "—", 1, 1, id="a near-expiry credential rotates on first use"),
    pytest.param("revoked after admission", 401, "credential-revoked", "—", 0, 0, id="a revocation mid-session refuses before upstream"),
    pytest.param("the exchange times out", "401, then 401", "credential-refresh-uncertain, then credential-recovery-required", "—", 0, 1,
                 id="an uncertain refresh refuses, then stays refused"),
    pytest.param("the marker save raises", 503, "credential-store-unavailable", 60, 0, 0, id="a store fault on the data plane is retriable ⚖"),
])
async def test_data_plane(codex_app, codex_gw, codex_store, codex_upstream, exchange, clock, record, expected_status, expected_code,
                          expected_retry_after, expected_upstream_calls, expected_exchanges):
    world("policy-codex", "upstream-ok")
    row(record=record, expected_status=expected_status, expected_code=expected_code, expected_retry_after=expected_retry_after,
        expected_upstream_calls=expected_upstream_calls, expected_exchanges=expected_exchanges)
    observe(codex_app, fresh_report(clock))
    with given(f"a codex session; record {record}"):
        doc = await codex_session(codex_gw)
        if record == "revoked after admission":
            codex_app.state.codex.lifecycle.revoke()
        elif record == "the exchange times out":
            exchange.fault = TimeoutError("DUMMY-SECRET token endpoint")
        elif record == "the marker save raises":
            codex_store.fail_at = codex_store.writes + 1
    r = await ride(codex_gw, doc, label=record)
    if record == "the exchange times out":
        with given("the second request"):
            r2 = await codex_gw.post("/openai/v1/responses", json=json.loads(r.request.content), headers={"authorization": f"Bearer {doc['session']['token']}"})
        verdicts(
            status=(f"{r.status_code}, then {r2.status_code}", expected_status),
            code=(f"{err(r)}, then {err(r2)}", expected_code),
        )
    else:
        verdicts(
            status=(r.status_code, expected_status),
            code=(err(r) if r.status_code >= 400 else "—", expected_code),
        )
    retry = r.headers.get("retry-after")
    verdicts(
        retry_after=(int(retry) if retry else "—", expected_retry_after),
        upstream_calls=(len(codex_upstream.calls), expected_upstream_calls),
        exchanges=(exchange.calls, expected_exchanges),
    )
    if record == "ready, 1 s from expiry":
        then_eq("upstream bearer", codex_upstream.calls[-1]["headers"]["authorization"], "Bearer " + exchange.rotated.access_token,
                claim="the upstream bearer is the rotated access token")


# -- the deployed policy --------------------------------------------------------------------------

DEPLOYED_POLICY = ISLAND.parent / "argocd" / "resources" / "agent-gateway" / "policy.json"
DECLARED = ("rails.codex with its headroom and oauth blocks; every role lists anthropic, opencode and codex; "
            "openrouter walks last where listed, the prober excepted")


@pytest.mark.skipif(not DEPLOYED_POLICY.exists(), reason="deploy manifests absent (service-only checkout)")
@pytest.mark.parametrize(("policy_file", "expected_declared"), [
    pytest.param("argocd/resources/agent-gateway/policy.json", DECLARED, id="the deployed policy lists the subscription rails for every role ⚖"),
])
def test_deployed_policy(policy_file, expected_declared):
    world("policy-codex", note="reads the deployed policy file, not the world")
    row(policy_file=policy_file, expected_declared=expected_declared)
    with when(f"Policy.from_dict({policy_file}) — the island's loader, the GW-MODEL-RESOLVE reader"):
        policy = Policy.from_dict(json.loads((ISLAND.parent / policy_file).read_text(encoding="utf-8")))
        attach_json("deployed rails", sorted(policy.rails))
        attach_json("deployed roles → rails", {n: list(r.rails) for n, r in policy.roles.items()})
    subs = {"anthropic", "opencode", "codex"}
    checks = {
        "rails.codex declared": "codex" in policy.rails,
        "headroom and oauth blocks": "codex" in policy.rails and policy.rails["codex"].headroom is not None and policy.rails["codex"].refresh_margin_s is not None,
        "every role lists the three subscription rails": all(subs <= set(r.rails) for r in policy.roles.values()),
        "openrouter last where listed, the prober excepted": all(r.rails[-1] == "openrouter" for n, r in policy.roles.items()
                                                                 if n != "prober" and "openrouter" in r.rails),
    }
    failed = [k for k, v in checks.items() if not v]
    expect("declared", DECLARED if not failed else "failed: " + ", ".join(failed), expected_declared)
