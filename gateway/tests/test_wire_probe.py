"""GW-WIRE-PROBE — a declared read of a vendor endpoint the gateway does not call yet, and where it is declared
(specs/endpoints/wire.md §GW-WIRE-PROBE).

World: policy-codex with the declarations world wire-codex (tests/fixtures/wire-codex.json — byte-identical to
specs/worlds/wire-codex.json). The fake `/models` answer is an obviously synthetic body: the probe treats
bytes as opaque and no row asserts the vendor's shape. T0 = the test clock (2027-01-15T08:00:00Z). The tables
are the spec's, verbatim; the header is the parameter list.
"""

from __future__ import annotations

import dataclasses
import json
import re

import httpx
import pytest

from agent_gateway.app import create_app
from agent_gateway.codex import CodexBackend
from agent_gateway.config import Policy, PolicyError
from agent_gateway.wire import WireDeclarationError

from ._catalog_rows import T0, at_offset
from ._codex_rows import row, verdicts
from ._codex_world import CODEX_BASE, CODEX_POLICY
from .conftest import HERE, attach_json, given, rule, when, world

pytestmark = rule("GW-WIRE-PROBE")

DECLARATIONS = HERE / "fixtures" / "wire-codex.json"
SYNTHETIC = b'{"fixture":"synthetic /models stand-in","items":[{"n":1}]}'


class FakeModels:
    """The fake codex upstream's `/models`: records every request, answers `status` + a synthetic body."""

    def __init__(self):
        self.status = 200
        self.calls: list[httpx.Request] = []

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.calls.append(request)
        return httpx.Response(self.status, headers={"content-type": "application/json"}, content=SYNTHETIC)


def build(tmp_path, settings, secrets, store, clock, codex_store, exchange, fake: FakeModels, declarations: str | None):
    """A gateway on the world's policy; `declarations` = the file's text, or None for GATEWAY_WIRE unset."""
    path = ""
    if declarations is not None:
        f = tmp_path / "wire.json"
        f.write_text(declarations, encoding="utf-8")
        path = str(f)
    s = dataclasses.replace(settings, upstreams={**settings.upstreams, "codex": CODEX_BASE}, wire_path=path)
    client = httpx.AsyncClient(transport=httpx.MockTransport(fake.handler))
    app = create_app(s, policy=Policy.load(CODEX_POLICY), source=secrets, store=store, client=client, clock=clock,
                     codex_backend=CodexBackend(codex_store, exchange))
    return app, client


WIRE_CODEX = DECLARATIONS.read_text(encoding="utf-8")
PROBE_ROWS = [
    pytest.param("wire-codex", "a valid credential", "T0", "`GET {CODEX_UPSTREAM}/models?client_version=0.155.0`, `Bearer <the lifecycle's access token>`, `chatgpt-account-id`",
                 "ok", "account", id="a declared probe goes out through the rail's lifecycle"),
    pytest.param("`GATEWAY_WIRE` unset", "a valid credential", "T0", "none", "—", "—", id="no file, nothing read ⚖"),
    pytest.param("`{}`", "a valid credential", "T0", "none", "—", "—", id="an empty file, nothing read"),
    pytest.param("wire-codex", "the lifecycle refuses", "T0", "none", "no-credential", "—", id="no usable credential, no fetch ⚖"),
    pytest.param("wire-codex, the fake answers 503", "a valid credential", "T0", "as the first row", "fetch-failed", "account",
                 id="an upstream error is counted and recorded as the failure"),
    pytest.param("`GATEWAY_WIRE` names a path that does not exist", "a valid credential", "T0", "none", "—", "—", id="a missing path, nothing read ⚖"),
    pytest.param("wire-codex, a no-credential tick at T0", "the lifecycle refuses", "a second tick at T0 + 60 s", "none", "no-credential", "—",
                 id="no credential is not retried inside the interval ⚖"),
    pytest.param("wire-codex, a record at T0", "a valid credential", "restart at T0 + 3600 s", "none", "—", "account",
                 id="a restart inside the interval probes nothing at start"),
]


@pytest.mark.parametrize(("declarations", "lifecycle", "at", "expected_request", "expected_outcome", "expected_recorded_class"), PROBE_ROWS,
                         ids=[p.id for p in PROBE_ROWS])
async def test_a_declared_probe_is_read(tmp_path, settings, secrets, store, clock, codex_store, exchange, declarations, lifecycle, at,
                                        expected_request, expected_outcome, expected_recorded_class):
    world("policy-codex", upstream="wire-codex")
    row(declarations=declarations, lifecycle=lifecycle, at=at)
    text = {"wire-codex": WIRE_CODEX, "wire-codex, the fake answers 503": WIRE_CODEX, "wire-codex, a record at T0": WIRE_CODEX,
            "`{}`": "{}", "`GATEWAY_WIRE` unset": None, "`GATEWAY_WIRE` names a path that does not exist": None,
            "wire-codex, a no-credential tick at T0": WIRE_CODEX}[declarations]
    fake = FakeModels()
    if "503" in declarations:
        fake.status = 503
    if lifecycle == "the lifecycle refuses":
        exchange.fault = RuntimeError("DUMMY-SECRET exchange refused")  # the stored credential is near expiry: acquire must exchange
    app, client = build(tmp_path, settings, secrets, store, clock, codex_store, exchange, fake, text)
    if "does not exist" in declarations:  # the same app, GATEWAY_WIRE naming a path nothing is at
        await client.aclose()
        s2 = dataclasses.replace(settings, upstreams={**settings.upstreams, "codex": CODEX_BASE}, wire_path=str(tmp_path / "absent.json"))
        client = httpx.AsyncClient(transport=httpx.MockTransport(fake.handler))
        app = create_app(s2, policy=Policy.load(CODEX_POLICY), source=secrets, store=store, client=client, clock=clock,
                         codex_backend=CodexBackend(codex_store, exchange))
    if text:
        attach_json("declarations", json.loads(text))
    restart = at.startswith("restart")
    probe = app.state.wire_probe
    if restart:
        with given("a record at T0: the probe has read once"):
            await probe.tick()
        store.close()
        clock.t = T0 + at_offset(at.removeprefix("restart at "))
        fake.calls.clear()
        app2, client2 = build(tmp_path, settings, secrets, type(store)(settings.db_path), clock, codex_store, exchange, fake, text)
        app, probe = app2, app2.state.wire_probe
        await client.aclose()
        client = client2
    if at.startswith("a second tick"):
        with given("a no-credential tick at T0"):
            first = await probe.tick()
            assert first.get("codex-models") == "no-credential"
        clock.t = T0 + at_offset(at.removeprefix("a second tick at "))
    with when(f"the probe schedule runs at {at}"):
        outcomes = await probe.tick()
    if at.startswith("a second tick"):
        assert outcomes == {}  # nothing probed again; the counter stays at the first tick's 1
        outcomes = first
    metrics = app.state.metrics.render()
    rec = app.state.store.wire_get("codex-models") or {}
    await client.aclose()
    if expected_request == "none":
        got_request = "none" if not fake.calls else str(fake.calls[-1].url)
    else:
        r = fake.calls[-1] if fake.calls else None
        want_auth = "Bearer DUMMY-SECRET-rotated-access"
        got_request = ("`GET {CODEX_UPSTREAM}/models?client_version=0.155.0`, `Bearer <the lifecycle's access token>`, `chatgpt-account-id`"
                       if r is not None and r.method == "GET" and str(r.url) == CODEX_BASE + "/models?client_version=0.155.0"
                       and r.headers.get("authorization") == want_auth and r.headers.get("chatgpt-account-id") else str(r and r.url))
        if expected_request == "as the first row":
            expected_request = got_request if got_request.startswith("`GET") else "the first row's request"
    got_outcome = outcomes.get("codex-models", "—")
    series = {m.group(1): int(m.group(2)) for m in re.finditer(r'gateway_wire_probe_total\{source="codex-models",outcome="([a-z-]+)"\} (\d+)', metrics)}
    if expected_outcome != "—":
        assert series.get(expected_outcome) == 1, series
    attach_json("the record (no body)", {k: v for k, v in rec.items() if k != "body"})
    if expected_request != "none" and expected_outcome == "ok":
        assert json.loads(rec["body"]) == {"fixture": {"len": 26}, "items": [{"n": 1}]}  # an account answer: structure, no string
    if restart:
        got_request = "none" if not fake.calls else got_request  # the first-run read happened before the restart; none after
    verdicts(request=(got_request, expected_request), outcome=(got_outcome, expected_outcome),
             recorded_class=(rec.get("class") or "—", expected_recorded_class))


# ── What a probe may be ──────────────────────────────────────────────────────────────────────
def declare(**probe) -> dict:
    p = {"rail": "codex", "path": "/models", "interval_s": 21600, **probe}
    return {"probes": {"codex-models": {k: v for k, v in p.items() if v is not None}}}


def load(tmp_path, text: str) -> None:
    f = tmp_path / "declared.json"
    f.write_text(text, encoding="utf-8")
    from agent_gateway.wire import load_declarations
    load_declarations(str(f), Policy.load(CODEX_POLICY).rails)


# the probe cell -> (the declarations file's text, the word the refusal must name)
MAY = {
    "rail `codex`, path `/models`": (declare(), None),
    "rail `zen`, path `/models`": (declare(rail="zen"), "zen"),
    "path `https://elsewhere.test/models`": (declare(path="https://elsewhere.test/models"), "path"),
    "path `/responses`": (declare(path="/responses"), "path"),
    "path `/chat/completions`": (declare(path="/chat/completions"), "path"),
    "`method: POST`": (declare(method="POST"), "method"),
    "path `/models?x=1`": (declare(path="/models?x=1"), "path"),
    "path `//elsewhere.test/models`": (declare(path="//elsewhere.test/models"), "path"),
    "path `/../responses`": (declare(path="/../responses"), "path"),
    "`interval_s: 5`": (declare(interval_s=5), "interval_s"),
    "`query: {a: 1}`": (declare(query={"a": 1}), "query"),
    "probe named `go-docs`": ({"probes": {"go-docs": {"rail": "codex", "path": "/models", "interval_s": 600}}}, "go-docs"),
    "top-level `surprise`": ({"surprise": 1}, "surprise"),
    "`[]`": ([], "object"),
}
MAY_ROWS = [
    pytest.param("rail `codex`, path `/models`", "loads", id="a probe is a GET on a declared rail's upstream ⚖"),
    pytest.param("rail `zen`, path `/models`", "refused, naming the rail", id="a rail the policy does not declare refuses the load"),
    pytest.param("path `https://elsewhere.test/models`", "refused, naming path", id="an absolute URL refuses the load ⚖"),
    pytest.param("path `/responses`", "refused, naming path", id="an inference path refuses the load ⚖"),
    pytest.param("path `/chat/completions`", "refused, naming path", id="a chat path is an inference path too"),
    pytest.param("`method: POST`", "refused, naming method", id="a method is not a key"),
    pytest.param("path `/models?x=1`", "refused, naming path", id="a query rides `query`, not the path"),
    pytest.param("path `//elsewhere.test/models`", "refused, naming path", id="a scheme-relative path is a host"),
    pytest.param("path `/../responses`", "refused, naming path", id="a dot-dot segment is refused"),
    pytest.param("`interval_s: 5`", "refused, naming interval_s", id="an interval under a minute is refused ⚖"),
    pytest.param("`query: {a: 1}`", "refused, naming query", id="a query value is a string"),
    pytest.param("probe named `go-docs`", "refused, naming go-docs", id="a name the gateway already reads is refused ⚖"),
    pytest.param("top-level `surprise`", "refused, naming surprise", id="an unknown key of the file is refused"),
    pytest.param("`[]`", "refused, naming object", id="a file that is not an object is refused"),
]


@pytest.mark.parametrize(("probe", "expected_load"), MAY_ROWS, ids=[p.id for p in MAY_ROWS])
def test_what_a_probe_may_be(tmp_path, probe, expected_load):
    world("policy-codex", upstream="wire-codex")
    row(probe=probe)
    doc, needle = MAY[probe]
    with when(f"the declarations file names {probe}"):
        try:
            load(tmp_path, json.dumps(doc))
            got, message = "loads", ""
        except WireDeclarationError as e:
            message = str(e)
            got = "refused" if needle is None else f"refused, naming {'the rail' if needle == 'zen' else needle}"
            if needle is not None and needle not in message:
                got = "refused"
    attach_json("the refusal", {"message": message})
    verdicts(load=(got, expected_load))


# ── The declarations have one home ───────────────────────────────────────────────────────────
HOME_ROWS = [
    pytest.param("the file `GATEWAY_WIRE` names", "loads", id="a probe in the declarations file loads"),
    pytest.param("`policy.json`, key `wire`", "refused, naming wire", id="a `wire` key in the policy refuses the load ⚖"),
    pytest.param("the file `GATEWAY_WIRE` names, not JSON", "refused, naming JSON", id="a declarations file that is not JSON refuses to start ⚖"),
]


@pytest.mark.parametrize(("declared_in", "expected_load"), HOME_ROWS, ids=[p.id for p in HOME_ROWS])
async def test_the_declarations_have_one_home(tmp_path, settings, secrets, store, clock, codex_store, exchange, declared_in, expected_load):
    world("policy-codex", upstream="wire-codex")
    row(declared_in=declared_in)
    with when(f"a probe is declared in {declared_in}"):
        if "policy" in declared_in:
            doc = json.loads(CODEX_POLICY.read_text(encoding="utf-8"))
            doc["wire"] = json.loads(WIRE_CODEX)
            try:
                Policy.from_dict(doc)
                got = "loads"
            except PolicyError as e:
                got = "refused, naming wire" if "wire" in str(e) else "refused"
        elif "not JSON" in declared_in:
            try:
                build(tmp_path, settings, secrets, store, clock, codex_store, exchange, FakeModels(), "{not json")
                got = "loads"
            except WireDeclarationError as e:
                got = "refused, naming JSON" if "JSON" in str(e) else "refused"
        else:
            app, client = build(tmp_path, settings, secrets, store, clock, codex_store, exchange, FakeModels(), WIRE_CODEX)
            got = "loads" if list(app.state.wire_probe.decl.probes) == ["codex-models"] else "no probe"
            await client.aclose()
    verdicts(load=(got, expected_load))
