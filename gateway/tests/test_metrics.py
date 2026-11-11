"""GW-METRICS — the gateway_* families and their bounded labels (specs/endpoints/metrics.md).

Every table of the page is a parametrized function here: the header is the argname list
(`value?` ⇄ `expected_value`, …), every `pytest.param` id is a description cell verbatim, and the
`world` / `event` cells are short literals this module decodes (`_drive`) exactly as the page's
legend reads them. One rule, one world family (`policy-default` · an upstream behaviour, or the
`openrouter-endpoints` snapshot for the provider rows).
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any

import httpx
import pytest

from agent_gateway.app import create_app
from agent_gateway.config import Settings
from agent_gateway.outcomes import OUTCOME_CLASSES
from agent_gateway.store import Store

from .conftest import (
    POLICY_FIXTURE,
    SPECS,
    UPSTREAM_BASES,
    FakeUpstream,
    ObservedAsyncClient,
    RailTransport,
    attach_json,
    bearer,
    check,
    given,
    open_session,
    quiet,
    rule,
    seed_go_catalog,
    seed_openrouter_endpoints,
    then,
    when,
)
from .conftest import world as name_world

pytestmark = rule("GW-METRICS")

SCHEMA = json.loads((SPECS / "endpoints" / "metrics.schema.json").read_text(encoding="utf-8"))
RAILS = ("anthropic", "openrouter", "opencode", "codex")
CHAT = "/openai/v1/chat/completions"
MESSAGES = "/anthropic/v1/messages"
OR_M = "deepseek/deepseek-v4.1-flash"
OR_M2 = "deepseek/deepseek-v4-flash"
MODEL_FAMILIES = ("gateway_provider_requests_total", "gateway_provider_failovers_total", "gateway_rail_choice_total")
LABEL_RE = re.compile(r'^(gateway_[a-z_]+)\{([^}]*)\} ')


@dataclass
class Fixtures:
    gw: Any
    app: Any
    policy: Any
    secrets: Any
    upstreams: Any
    transport: Any
    clock: Any
    reviews: Any
    pods: Any
    store: Any
    doc: dict | None = None  # the drive's session answer, for the rows that need its identifiers


@pytest.fixture
def fx(gw, app, policy, secrets, upstreams, transport, clock, reviews, pods, store) -> Fixtures:
    return Fixtures(gw, app, policy, secrets, upstreams, transport, clock, reviews, pods, store)


# -- reading the exposition ------------------------------------------------------------------------
def _value(text: str, series: str) -> float | None:
    m = re.search(r"^" + re.escape(series) + r" (\S+)$", text, re.M)
    return float(m.group(1)) if m else None


async def _metrics(gw) -> str:
    """The exposition, read quietly — a verdict attaches the sample lines it judged instead."""
    with quiet():
        return (await gw.get("/metrics")).text


def _lines(text: str, prefix: str) -> list[str]:
    return [line for line in text.splitlines() if line.startswith(prefix)]


def _series(text: str) -> list[tuple[str, dict[str, str]]]:
    out = []
    for line in text.splitlines():
        m = LABEL_RE.match(line)
        if m:
            labels = dict(kv.split("=", 1) for kv in m.group(2).split(","))
            out.append((m.group(1), {k: v.strip('"') for k, v in labels.items()}))
    return out


# -- the world cell ---------------------------------------------------------------------------------
def _world(cell: str, event: str) -> str | None:
    """`policy-default · <behaviour>` → the world label (conftest.world) + the behaviour name the
    drive applies; `policy-default` alone → no behaviour."""
    policy, _, behaviour = cell.partition(" · ")
    name_world(policy, behaviour or None, note=f"event: {event}")
    return behaviour or None


def _apply(fx: Fixtures, rail: str, behaviour: str | None) -> None:
    if behaviour == "upstream-down":
        fx.transport.unreachable.add(rail)
    elif behaviour and behaviour.startswith("upstream-") and behaviour != "upstream-ok":
        fx.upstreams[rail].behaviour = behaviour


# -- the event cell: given (arrange) + the act. `act` = when the page's `when` is the event itself
#    (a series row); False = the event is arrange and the metrics read is the `when` (a label row).
async def _ride(fx: Fixtures, rail: str, behaviour: str | None, event: str, act: bool, stream: bool = False) -> None:
    _apply(fx, rail, behaviour)
    with given(f"a worker session on {rail} (harness goose); the {rail} upstream answers {behaviour or 'upstream-ok'}"):
        fx.doc = await open_session(fx.gw, harness="goose", rail=rail)
    with (when if act else given)(f"{event}: POST {CHAT}{' stream: true' if stream else ''}"):
        await fx.gw.post(CHAT, json={"messages": [], **({"stream": True} if stream else {})}, headers=bearer(fx.doc))


async def _anthropic_call(fx: Fixtures, behaviour: str | None, event: str, act: bool, expired: bool = False) -> None:
    _apply(fx, "anthropic", behaviour)
    with given("a reviewer session on anthropic (harness claude)" + (f", expired (clock +{fx.policy.session_ttl_s + 1} s)" if expired else "")):
        fx.doc = await open_session(fx.gw, role="reviewer", harness="claude")
        if expired:
            fx.clock.advance(fx.policy.session_ttl_s + 1)
    with (when if act else given)(f"{event}: POST {MESSAGES}"):
        await fx.gw.post(MESSAGES, json={"messages": []}, headers=bearer(fx.doc))


async def _provider_world(fx: Fixtures) -> None:
    seed_openrouter_endpoints(fx.store, fx.upstreams["openrouter"])
    fx.app.state.providers.reload()


async def _provider_ride(fx: Fixtures, event: str, act: bool, model: str, tier: str, display: str | None = None, fail_deepinfra: bool = False) -> None:
    await _provider_world(fx)
    if fail_deepinfra:
        fx.upstreams["openrouter"].provider_behaviours["deepinfra"] = "upstream-500"
    fx.upstreams["openrouter"].provider_display = display
    with given(f"openrouter-endpoints seeded; a worker session on rail openrouter, tier {tier} (harness opencode)"):
        fx.doc = await open_session(fx.gw, role="worker", harness="opencode", rail="openrouter", tier=tier)
    with (when if act else given)(f"{event}: POST {CHAT} model {model}"):
        await fx.gw.post(CHAT, json={"model": model, "messages": []}, headers=bearer(fx.doc))


async def _exercise(fx: Fixtures) -> None:
    """`every family driven`: a dispatch + a served call, a reviewer session + a served call, a truncated
    stream, an outcome, an unknown stack, an unknown token, a transient credential (exchanges muted —
    one summary attaches instead)."""
    gw = fx.gw
    with given("every family driven: a dispatch + a served call, a reviewer call, a truncated stream, a no-verdict outcome, "
               "an unknown stack, an unknown token, a transient credential"):
        with quiet():
            fx.doc = await open_session(gw, task="homelab-2588-r1")
            await gw.post(CHAT, json={"messages": []}, headers=bearer(fx.doc))
            rev = await open_session(gw, role="reviewer", harness="claude", task="homelab-2588-review")
            await gw.post(MESSAGES, json={"messages": []}, headers=bearer(rev))
            fx.upstreams["opencode"].behaviour = "upstream-stream-truncated"
            await gw.post(CHAT, json={"messages": [], "stream": True}, headers=bearer(fx.doc))
            fx.upstreams["opencode"].behaviour = "upstream-ok"
            await gw.post(f"/sessions/{fx.doc['session']['id']}/outcome", json={"class": "no-verdict"})
            await gw.post("/sessions", json={"stack": "nope", "role": "worker", "task": "t"})
            await gw.post(CHAT, json={"messages": []}, headers={"authorization": "Bearer gws_" + "x" * 32})
            fx.secrets.transient.add("platform-agents/claude-session")
            fx.app.state.resolver.forget()
            await gw.post("/sessions", json={"stack": "platform", "role": "prober", "task": "t"})
        attach_json("exercised: the calls", ["POST /sessions platform worker task homelab-2588-r1 → dispatch", f"POST {CHAT} on it",
                                             f"a reviewer session + POST {MESSAGES} on it",
                                             "a truncated stream on the worker session (upstream-stream-truncated)",
                                             "POST /sessions/{id}/outcome {class: no-verdict} on the worker session",
                                             "POST /sessions stack nope", f"POST {CHAT} with an unknown gws_ token",
                                             "POST /sessions platform prober with claude-session transient"])


async def _drive(fx: Fixtures, event: str, behaviour: str | None, act: bool) -> None:
    gw = fx.gw
    step = when if act else given
    if event == "none":
        return
    if event == "a worker dispatched on opencode":
        with step(f"{event}: POST /sessions (stack platform, role worker)"):
            fx.doc = await open_session(gw)
    elif event == "a worker dispatched on opencode, then released":
        with given("a worker session dispatched on opencode"):
            fx.doc = await open_session(gw)
        with step(f"{event}: DELETE /sessions/{fx.doc['session']['id']}"):
            await gw.delete(f"/sessions/{fx.doc['session']['id']}")
    elif event == "every worker rail full, a worker deferred":
        caps = {rail: fx.policy.rails[rail].max_sessions for rail in ("opencode", "openrouter")}
        with given(f"every worker rail is full: {caps}"):
            with quiet():
                for rail, cap in caps.items():
                    for i in range(cap):
                        await open_session(gw, task=f"{rail}-{i}", rail=rail)
            attach_json(f"filled: {caps}", caps)
        with step(f"{event}: POST /sessions (stack platform, role worker)"):
            r = await gw.post("/sessions", json={"stack": "platform", "role": "worker", "task": "t"})
            assert r.json()["reason"] == "rail-capacity", r.text  # arrange sanity: the defer is the capacity one
    elif event == "a worker session reports no-verdict":
        with given("a worker session dispatched on opencode"):
            fx.doc = await open_session(gw)
        with step(f"{event}: POST /sessions/{{id}}/outcome {{class: no-verdict}}"):
            await gw.post(f"/sessions/{fx.doc['session']['id']}/outcome", json={"class": "no-verdict"})
    elif event == "a bound opencode session whose pod is gone, one reaper pass":
        from agent_gateway.liveness import PodState
        from agent_gateway.pull import POD_NAME_EXTRA, Review

        with given("a bound opencode worker session pulled by pod fixer-1, which is gone"):
            with quiet():
                fx.doc = await open_session(gw, bind={"namespace": "platform-agents", "serviceaccount": "agentstack-worker", "pod": "fixer-1"})
                fx.reviews.tokens["fake-projected-sa-token-metrics"] = Review(True, "system:serviceaccount:platform-agents:agentstack-worker",
                                                                              ("agent-gateway",), {POD_NAME_EXTRA: ("fixer-1",)})
                await gw.post(f"/sessions/{fx.doc['session']['id']}/env", headers={"authorization": "Bearer fake-projected-sa-token-metrics"})
            fx.pods.pods[("platform-agents", "fixer-1")] = PodState("gone")
        with step(f"{event}: the reaper runs once"):
            await fx.app.state.sessions.reap()
    elif event in ("one openai call on opencode", "one openai call on openrouter"):
        await _ride(fx, event.rsplit(" ", 1)[-1], behaviour, event, act)
    elif event == "one streamed openai call on opencode":
        await _ride(fx, "opencode", behaviour, event, act, stream=True)
    elif event == "an expired token on /anthropic/v1/messages":
        await _anthropic_call(fx, behaviour, event, act, expired=True)
    elif event == "one call on anthropic":
        await _anthropic_call(fx, behaviour, event, act)
    elif event == "the anthropic ref is a definitive miss, a prober asks":
        with given("state: the anthropic ref platform-agents/claude-session is a definitive miss"):
            fx.secrets.secrets.pop("platform-agents/claude-session")
            fx.app.state.resolver.forget()
            attach_json("secrets after: platform-agents/claude-session removed", sorted(fx.secrets.secrets))
        with step(f"{event}: POST /sessions (role prober — its only rail is anthropic)"):
            r = await gw.post("/sessions", json={"stack": "platform", "role": "prober", "task": "t"})
            assert r.json()["reason"] == "credential-unresolved", r.text
    elif event == "one openai call on opencode answered 401, 60 s, the re-probe answered upstream-ok":
        with given("a worker session on opencode whose request was answered upstream-401-key-expired; the fake back to upstream-ok; 60 s pass"):
            with quiet():
                fx.doc = await open_session(gw, harness="goose", rail="opencode")
                fx.upstreams["opencode"].behaviour = "upstream-401-key-expired"
                await gw.post(CHAT, json={"messages": []}, headers=bearer(fx.doc))
                fx.upstreams["opencode"].behaviour = "upstream-ok"
            fx.clock.advance(60)
        with step(f"{event}: the re-probe pass runs"):
            sent = await fx.app.state.proxy.reprobe()
            attach_json("the re-probe pass", {"probes sent": sent})
    elif event == "deepinfra answers 500, atlas-cloud serves":
        await _provider_ride(fx, event, act, OR_M, "heavy", fail_deepinfra=True)
    elif event == "a ride on deepseek/deepseek-v4-flash, the answer unnamed":
        await _provider_ride(fx, event, act, OR_M2, "standard", display=None)
    elif event == "a ride on deepseek/deepseek-v4-flash, the answer names Sail Research":
        await _provider_ride(fx, event, act, OR_M2, "standard", display="Sail Research")
    elif event == "every family driven":
        await _exercise(fx)
    elif event == "a worker admitted at tier light, a twin on both rails":
        await _provider_world(fx)
        with step(f"{event}: POST /sessions (worker, harness opencode, tier light)"):
            fx.doc = await open_session(gw, role="worker", harness="opencode", tier="light")
            attach_json("the answer's rail_choice", fx.doc.get("rail_choice"))
    else:
        raise ValueError(f"the page's legend has no event {event!r}")


# -- the series tables: description | world | event | series | value? -----------------------------
SERIES_ARGS = ("world", "event", "series", "expected_value")
OK, S429, S401, DOWN, CACHED = ("policy-default · upstream-ok", "policy-default · upstream-429", "policy-default · upstream-401",
                                "policy-default · upstream-down", "policy-default · upstream-ok-cached")
BASE, OR_WORLD = "policy-default", "policy-default · openrouter-endpoints"
DISPATCH, ANTHROPIC, ON_OPENCODE, ON_OPENROUTER = ("a worker dispatched on opencode", "one call on anthropic",
                                                   "one openai call on opencode", "one openai call on openrouter")
FAILOVER = "deepinfra answers 500, atlas-cloud serves"
SESSIONS_TOTAL = 'gateway_sessions_total{rail="%s",role="worker",stack="platform",decision="%s"}'
REQUESTS_TOTAL = 'gateway_requests_total{rail="%s",dialect="%s",status="%s"}'
PROVIDER_TOTAL = 'gateway_provider_requests_total{rail="openrouter",model="%s",provider="%s",outcome="%s"}'


async def _series_row(fx: Fixtures, world: str, event: str, series: str, expected_value) -> None:
    behaviour = _world(world, event)
    await _drive(fx, event, behaviour, act=True)
    with then(f"{series} = {expected_value}"):
        text = await _metrics(fx.gw)
        attach_json(f"sample: {series.split('{')[0]} lines", _lines(text, series.split("{")[0]))
        check("expected_value", _value(text, series), float(expected_value))


SESSION_ROWS = [
    pytest.param(OK, DISPATCH, 'gateway_sessions_active{rail="opencode"}', 1, id="a dispatch raises the active gauge"),
    pytest.param(OK, "a worker dispatched on opencode, then released", 'gateway_sessions_active{rail="opencode"}', 0, id="a release lowers it"),
    pytest.param(OK, DISPATCH, SESSIONS_TOTAL % ("opencode", "dispatch"), 1, id="a dispatch is counted with its identity"),
    pytest.param(OK, "every worker rail full, a worker deferred", SESSIONS_TOTAL % ("none", "defer"), 1, id="a defer is counted with no rail ⚖"),
    pytest.param(BASE, "a worker session reports no-verdict", 'gateway_strikes_total{class="no-verdict",source="outcome"}', 1,
                 id="a strike is counted by class and source"),
    pytest.param(BASE, "a bound opencode session whose pod is gone, one reaper pass", 'gateway_sessions_reaped_total{rail="opencode"}', 1,
                 id="a reaped session is counted on its rail"),
]


@pytest.mark.parametrize(SERIES_ARGS, SESSION_ROWS)
async def test_sessions_and_outcomes_are_counted(fx, world, event, series, expected_value):
    await _series_row(fx, world, event, series, expected_value)


REQUEST_ROWS = [
    pytest.param(OK, ON_OPENCODE, REQUESTS_TOTAL % ("opencode", "openai", "200"), 1, id="a served request is counted by status"),
    pytest.param(OK, "an expired token on /anthropic/v1/messages", REQUESTS_TOTAL % ("none", "anthropic", "401"), 1,
                 id="a refused request is counted by its status"),
    pytest.param(S429, ON_OPENROUTER, REQUESTS_TOTAL % ("openrouter", "openai", "429"), 1, id="an upstream 429 keeps its status"),
    pytest.param(S401, ON_OPENCODE, REQUESTS_TOTAL % ("opencode", "openai", "424"), 1,
                 id="an upstream auth rejection is answered 424 and counted at it"),
    pytest.param(DOWN, ON_OPENCODE, REQUESTS_TOTAL % ("opencode", "openai", "502"), 1,
                 id="an unreachable upstream is answered 502 and counted at it"),
]


@pytest.mark.parametrize(SERIES_ARGS, REQUEST_ROWS)
async def test_requests_are_counted_by_status(fx, world, event, series, expected_value):
    await _series_row(fx, world, event, series, expected_value)


TOKEN_ROWS = [
    pytest.param(CACHED, ANTHROPIC, 'gateway_tokens_total{rail="anthropic",class="in"}', 12, id="uncached input tokens are counted as in"),
    pytest.param(CACHED, ANTHROPIC, 'gateway_tokens_total{rail="anthropic",class="cache_read"}', 300, id="cache reads are counted as cache_read"),
    pytest.param(CACHED, ANTHROPIC, 'gateway_tokens_total{rail="anthropic",class="cache_write"}', 40, id="cache writes are counted as cache_write"),
    pytest.param(CACHED, ANTHROPIC, 'gateway_tokens_total{rail="anthropic",class="out"}', 7, id="output tokens are counted as out"),
    pytest.param(OK, ANTHROPIC, 'gateway_upstream_seconds_count{rail="anthropic"}', 1, id="upstream time is observed per rail"),
]


@pytest.mark.parametrize(SERIES_ARGS, TOKEN_ROWS)
async def test_tokens_and_upstream_time_are_observed_per_rail(fx, world, event, series, expected_value):
    await _series_row(fx, world, event, series, expected_value)


WINDOW_ROWS = [
    pytest.param(OK, ANTHROPIC, 'gateway_subscription_utilization{rail="anthropic",window="5h"}', 0.13, id="the 5h utilization is the header's"),
    pytest.param(OK, ANTHROPIC, 'gateway_subscription_utilization{rail="anthropic",window="7d"}', 0.67, id="the 7d utilization is the header's"),
    pytest.param(OK, ANTHROPIC, 'gateway_subscription_reset_seconds{rail="anthropic",window="5h"}', 1792172400, id="the 5h reset is the header's epoch"),
    pytest.param(OK, ANTHROPIC, 'gateway_subscription_reset_seconds{rail="anthropic",window="7d"}', 1792274400, id="the 7d reset is the header's epoch"),
]


@pytest.mark.parametrize(SERIES_ARGS, WINDOW_ROWS)
async def test_the_subscription_windows_are_read(fx, world, event, series, expected_value):
    await _series_row(fx, world, event, series, expected_value)


VERDICT_ROWS = [
    pytest.param(OK, "the anthropic ref is a definitive miss, a prober asks", 'gateway_credential_resolve_total{rail="anthropic",outcome="definitive"}', 1,
                 id="a resolution verdict is counted"),
    pytest.param(S401, ON_OPENCODE, 'gateway_upstream_auth_rejected_total{rail="opencode"}', 1, id="an upstream auth rejection is counted apart"),
    pytest.param(DOWN, ON_OPENCODE, 'gateway_upstream_auth_rejected_total{rail="opencode"}', 0, id="an unreachable upstream is not an auth rejection"),
    pytest.param(S429, ON_OPENROUTER, 'gateway_cells_cooled{rail="openrouter"}', 1, id="a cooled cell is counted on its rail"),
    pytest.param(S401, ON_OPENROUTER, 'gateway_credentials_rejected{rail="openrouter"}', 1, id="a rejected credential is counted on its rail"),
    pytest.param("policy-default · upstream-stream-truncated", "one streamed openai call on opencode",
                 'gateway_requests_incomplete_total{rail="opencode",dialect="openai",reason="no-terminal"}', 1,
                 id="an incomplete stream is counted by reason"),
    pytest.param("policy-default · upstream-401-key-expired", "one openai call on opencode answered 401, 60 s, the re-probe answered upstream-ok",
                 'gateway_credential_probes_total{rail="opencode",outcome="cleared"}', 1, id="a credential re-probe is counted by outcome"),
]


@pytest.mark.parametrize(SERIES_ARGS, VERDICT_ROWS)
async def test_credential_verdicts_and_transport_facts(fx, world, event, series, expected_value):
    await _series_row(fx, world, event, series, expected_value)


PROVIDER_ROWS = [
    pytest.param(OR_WORLD, FAILOVER, PROVIDER_TOTAL % (OR_M, "deepinfra", "5xx"), 1, id="a failed attempt is counted on its cell by how it ended"),
    pytest.param(OR_WORLD, FAILOVER, PROVIDER_TOTAL % (OR_M, "atlas-cloud", "ok"), 1, id="the serving attempt is counted ok on its cell"),
    pytest.param(OR_WORLD, FAILOVER, f'gateway_provider_failovers_total{{model="{OR_M}",from="deepinfra",to="atlas-cloud"}}', 1,
                 id="a failover is counted from and to"),
    pytest.param(OR_WORLD, "a ride on deepseek/deepseek-v4-flash, the answer unnamed", PROVIDER_TOTAL % (OR_M2, "unattributed", "ok"), 1,
                 id="an unpinned attempt that names no provider is unattributed ⚖"),
    pytest.param(OR_WORLD, "a ride on deepseek/deepseek-v4-flash, the answer names Sail Research", PROVIDER_TOTAL % (OR_M2, "other", "ok"), 1,
                 id="a provider the snapshot lacks renders as other ⚖"),
]


@pytest.mark.parametrize(SERIES_ARGS, PROVIDER_ROWS)
async def test_the_provider_families(fx, world, event, series, expected_value):
    await _series_row(fx, world, event, series, expected_value)


# -- Every rail renders from 0: description | world | family | value? -----------------------------
ZERO_ROWS = [
    pytest.param(BASE, "gateway_upstream_auth_rejected_total", 0, id="every rail's rejection count renders from 0 ⚖"),
    pytest.param(BASE, "gateway_cells_cooled", 0, id="the cooled-cell gauge renders every rail from 0"),
    pytest.param(BASE, "gateway_credentials_rejected", 0, id="the rejected-credential gauge renders every rail from 0 ⚖"),
    pytest.param(BASE, "gateway_sessions_active", 0, id="the active gauge renders every rail from 0, codex included ⚖"),
    pytest.param(BASE, "gateway_sessions_reaped_total", 0, id="the reaped counter renders every rail from 0"),
]


@pytest.mark.parametrize(("world", "family", "expected_value"), ZERO_ROWS)
async def test_every_rail_renders_from_0(fx, world, family, expected_value):
    _world(world, "none")
    with when(f"GET /metrics on a fresh gateway: the {family} lines"):
        text = await _metrics(fx.gw)
        attach_json(f"sample: {family} lines", _lines(text, family))
    with then(f"{family}{{rail=<r>}} = {expected_value} for every rail {', '.join(RAILS)}"):
        got = {rail: _value(text, f'{family}{{rail="{rail}"}}') for rail in RAILS}
        check("expected_value", got, dict.fromkeys(RAILS, float(expected_value)))


# -- Labels are bounded: description | world | event | family | label | values_within? ------------
LABEL_ARGS = ("world", "event", "family", "label", "expected_values_within")
DRIVEN = "every family driven"
TWIN = "a worker admitted at tier light, a twin on both rails"
STATUS_PATTERN = "^[1-5][0-9][0-9]$"
OR_MODELS, OR_SLUGS = "the openrouter rail's policy models", "the endpoint snapshot's slugs, unattributed"


def _allowed(fx: Fixtures, spec: str) -> set[str] | re.Pattern:
    """The legend's literals → the set (or pattern) the seen values must lie within."""
    if spec == STATUS_PATTERN:
        return re.compile(spec[1:-1])
    if spec == "the strike classes":
        return {k for k, v in OUTCOME_CLASSES.items() if v}
    if spec == OR_MODELS:
        return {m for tier in fx.policy.rails["openrouter"].models.values() for m in tier}
    if spec == OR_SLUGS:
        return fx.app.state.providers.slugs() | {"unattributed"}
    return set(spec.split(", "))


async def _label_row(fx: Fixtures, world: str, event: str, family: str, label: str, expected_values_within: str) -> None:
    behaviour = _world(world, event)
    await _drive(fx, event, behaviour, act=False)
    labels = label.split(", ")
    with when(f"GET /metrics: the values of label {label} on family {family}"):
        text = await _metrics(fx.gw)
        seen = {lv[k] for fam, lv in _series(text) if (family == "any" or fam in family.split(", ")) for k in labels if k in lv}
        attach_json(f"seen: {label} values on {family}", sorted(seen))
    allowed = _allowed(fx, expected_values_within)
    shown = expected_values_within if isinstance(allowed, re.Pattern) else sorted(allowed)
    with then(f"{label} values ⊆ {expected_values_within}, non-empty",
              expected_values_within={"expected": shown, "actual": sorted(seen)}):
        assert seen, (family, label)
        if isinstance(allowed, re.Pattern):
            assert all(allowed.fullmatch(v) for v in seen), seen
        else:
            assert seen <= allowed, seen - allowed


SESSION_LABEL_ROWS = [
    pytest.param(OK, DRIVEN, "any", "rail", "anthropic, opencode, openrouter, codex, none", id="rail is the rail enum plus none"),
    pytest.param(OK, DRIVEN, "gateway_sessions_total", "role", "worker, reviewer, coordinator, responder, retro, prober, researcher", id="role is the role enum"),
    pytest.param(OK, DRIVEN, "gateway_sessions_total", "stack", "platform, oracle, other", id="stack is a policy key, else other ⚖"),
    pytest.param(OK, DRIVEN, "gateway_sessions_total", "decision", "dispatch, defer", id="decision is the answer enum"),
    pytest.param(OK, DRIVEN, "gateway_requests_total", "dialect", "anthropic, openai, responses", id="dialect is the three paths"),
    pytest.param(OK, DRIVEN, "gateway_requests_total", "status", STATUS_PATTERN, id="status is a numeric HTTP status"),
    pytest.param(OK, DRIVEN, "gateway_tokens_total", "class", "in, cache_read, cache_write, out", id="class is one of the four usage classes"),
    pytest.param(OK, DRIVEN, "gateway_subscription_utilization", "window", "5h, 7d, other", id="window is 5h or 7d"),
]


@pytest.mark.parametrize(LABEL_ARGS, SESSION_LABEL_ROWS)
async def test_labels_are_bounded_sessions_and_requests(fx, world, event, family, label, expected_values_within):
    await _label_row(fx, world, event, family, label, expected_values_within)


CONTROL_LABEL_ROWS = [
    pytest.param(OK, DRIVEN, "gateway_credential_resolve_total", "outcome", "resolved, definitive, transient", id="outcome is the verdict class"),
    pytest.param(OK, DRIVEN, "gateway_control_plane_unauthenticated_total", "route", "admit, lookup, release, outcome, list",
                 id="route is the control-plane route"),
    pytest.param(OK, DRIVEN, "gateway_control_plane_unauthenticated_total", "reason", "absent, invalid, review-transient",
                 id="reason is why no caller identity was read"),
    pytest.param(OK, DRIVEN, "gateway_strikes_total", "class", "the strike classes", id="class is a strike class of the one vocabulary"),
    pytest.param(OK, DRIVEN, "gateway_strikes_total", "source", "outcome, gateway", id="source is the strike's writer"),
    pytest.param(OK, DRIVEN, "gateway_requests_incomplete_total", "reason", "no-terminal, timeout, transport-error, client-closed",
                 id="reason is why a 2xx body stopped before its end"),
    pytest.param(OK, DRIVEN, "gateway_db_mode", "mode", "pvc, memory", id="mode is the store mode the gateway opened at start"),
    pytest.param(OK, DRIVEN, "gateway_go_catalog_refresh_total", "source", "config, docs", id="source is the catalog source"),
    pytest.param(OK, DRIVEN, "gateway_go_catalog_refresh_total", "outcome", "ok, fetch-failed, parse-failed, implausible",
                 id="the catalog outcome is the refresh outcome"),
]


@pytest.mark.parametrize(LABEL_ARGS, CONTROL_LABEL_ROWS)
async def test_labels_are_bounded_credentials_the_control_plane_the_catalog(fx, world, event, family, label, expected_values_within):
    await _label_row(fx, world, event, family, label, expected_values_within)


CATALOG_LABEL_ROWS = [
    pytest.param(BASE, "none", "gateway_openrouter_cells", "state", "candidate, eligible, excluded", id="state is a cell's entry state ⚖"),
    pytest.param(BASE, "none", "gateway_canary_rides_total", "outcome", "eligible, excluded, no-verdict", id="a canary ride's outcome is a verdict"),
    pytest.param(BASE, "none", "gateway_canary_admissions_total", "outcome", "dispatch, budget, not-due, not-in-catalog",
                 id="a canary admission's outcome is an answer"),
    pytest.param(OR_WORLD, FAILOVER, "gateway_provider_requests_total, gateway_provider_failovers_total", "model", OR_MODELS,
                 id="model is a policy openrouter id ⚖"),
    pytest.param(OR_WORLD, FAILOVER, "gateway_provider_requests_total", "provider", OR_SLUGS, id="provider is a snapshot slug or unattributed ⚖"),
    pytest.param(OR_WORLD, FAILOVER, "gateway_provider_failovers_total", "from, to", OR_SLUGS, id="a failover's from and to are snapshot slugs too ⚖"),
    pytest.param(OR_WORLD, TWIN, "gateway_rail_choice_total", "reason", "price, clean-rate, headroom, not-in-catalog, no-eligible-endpoint",
                 id="reason is why the rail choice fell ⚖"),
    pytest.param(OR_WORLD, TWIN, "gateway_rail_choice_total", "model", OR_MODELS, id="the rail choice's model is the twin's openrouter spelling ⚖"),
]


@pytest.mark.parametrize(LABEL_ARGS, CATALOG_LABEL_ROWS)
async def test_labels_are_bounded_the_openrouter_catalog_the_canary_the_providers(fx, world, event, family, label, expected_values_within):
    await _label_row(fx, world, event, family, label, expected_values_within)


# -- No unbounded label, ever: description | world | event | absent | found? ----------------------
FORBIDDEN, IDENTIFIERS = "the forbidden label names", "the ride's identifiers"
ABSENT_ROWS = [
    pytest.param(OK, DRIVEN, FORBIDDEN, "none", id="no task label, ever"),
    pytest.param(OK, DRIVEN, IDENTIFIERS, "none", id="no task key, session id, token, model or unknown stack in the text"),
]


@pytest.mark.parametrize(("world", "event", "absent", "expected_found"), ABSENT_ROWS)
async def test_no_unbounded_label_ever(fx, world, event, absent, expected_found):
    behaviour = _world(world, event)
    await _drive(fx, event, behaviour, act=False)
    with when(f"GET /metrics after {event}: looking for {absent}"):
        text = await _metrics(fx.gw)
        series = _series(text)
        if absent == FORBIDDEN:
            forbidden = set(SCHEMA["forbidden_labels"])
            found = sorted({f"{fam}{{{k}}}" for fam, lv in series for k in lv if k in forbidden or (k == "model" and fam not in MODEL_FAMILIES)})
            attach_json("label names seen per family", {fam: sorted({k for f, lv in series if f == fam for k in lv}) for fam in sorted({f for f, _ in series})})
        else:
            doc = fx.doc
            needles = {"the task key": "homelab-2588-r1", "the session id": doc["session"]["id"], "the session token": doc["session"]["token"],
                       "the model": doc["model"], "the unknown stack": "nope"}
            found = sorted(name for name, needle in needles.items() if needle in text)
            attach_json("needles looked for", {k: ("<redacted>" if "token" in k else v) for k, v in needles.items()})
    with then(f"found = {expected_found}"):
        check("expected_found", ", ".join(found) if found else "none", expected_found)


# -- Every family is declared: description | world | families | undeclared? -----------------------
DECLARED_ROWS = [
    pytest.param(BASE, "the schema's, less the codex rail's", "none", id="every family renders HELP and TYPE, zeros included"),
]


@pytest.mark.parametrize(("world", "families", "expected_undeclared"), DECLARED_ROWS)
async def test_every_family_is_declared(fx, world, families, expected_undeclared):
    _world(world, "none")
    assert families == "the schema's, less the codex rail's"
    wanted = [f for f in SCHEMA["families"] if not f.startswith("gateway_codex_")]
    with when(f"GET /metrics on a fresh gateway: HELP and TYPE for {len(wanted)} families ({families})"):
        text = await _metrics(fx.gw)
        attach_json("HELP/TYPE lines", [line for line in text.splitlines() if line.startswith(("# HELP gateway_", "# TYPE gateway_"))])
    with then(f"undeclared = {expected_undeclared}"):
        undeclared = [f for f in wanted if f"# HELP {f} " not in text or f"# TYPE {f} " not in text]
        check("expected_undeclared", ", ".join(undeclared) if undeclared else "none", expected_undeclared)


# -- The store mode is a gauge: description | store_state | pvc? | memory? ----------------------------
# A gateway started on a missing DB directory falls open to memory (store.py Store); the mode is read
# off the exposition, never off the store, so the row proves the family is what the probe reports.
def _db_mode_app(policy, secrets, path: str):
    """A gateway on `path` whose rails reach the in-process fakes (no live upstream, ever)."""
    settings = Settings.from_env({"GATEWAY_POLICY": str(POLICY_FIXTURE), "GATEWAY_DB": path, "OPENCODE_GO_API_KEY": "go-key-for-tests-only",
                                  "ANTHROPIC_UPSTREAM": UPSTREAM_BASES["anthropic"], "OPENROUTER_UPSTREAM": UPSTREAM_BASES["openrouter"],
                                  "OPENCODE_GO_UPSTREAM": UPSTREAM_BASES["opencode"]})
    fakes = RailTransport({rail: FakeUpstream(rail) for rail in UPSTREAM_BASES}, UPSTREAM_BASES)
    return create_app(settings, policy=policy, source=secrets, store=seed_go_catalog(Store(path)), client=httpx.AsyncClient(transport=fakes))


DB_MODE_ROWS = [
    pytest.param("file", "1", "0", id="a mounted, writable PVC reads pvc"),
    pytest.param("missing-dir", "0", "1", id="a fail-open store reads memory"),
    pytest.param("file", "1", "0", id="both modes render on every gateway, the inactive one at 0 ⚖"),
]


@pytest.mark.parametrize(("store_state", "expected_pvc", "expected_memory"), DB_MODE_ROWS)
async def test_the_store_mode_is_a_gauge(tmp_path, policy, secrets, store_state, expected_pvc, expected_memory):
    name_world("policy-default", note=f"store_state: {store_state}")
    path = str(tmp_path / "data" / "gateway.db")
    with given(f"store_state {store_state}: the DB path (GATEWAY_DB=<tmp>/data/gateway.db)"):
        if store_state == "file":
            (tmp_path / "data").mkdir()
    with when(f"the gateway starts on the {store_state} store, then GET /metrics"):
        app = _db_mode_app(policy, secrets, path)
        async with ObservedAsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://gw") as c:
            with quiet():  # the exposition is bulk; the verdict carries the two samples it judged
                text = (await c.get("/metrics")).text
    pvc, memory = _value(text, 'gateway_db_mode{mode="pvc"}'), _value(text, 'gateway_db_mode{mode="memory"}')
    attach_json("sample: gateway_db_mode lines", _lines(text, "gateway_db_mode{"))
    with then(f"pvc = {expected_pvc} and memory = {expected_memory}, both rendered",
              expected_pvc={"expected": float(expected_pvc), "actual": pvc},
              expected_memory={"expected": float(expected_memory), "actual": memory}):
        check("expected_pvc", pvc, float(expected_pvc))
        check("expected_memory", memory, float(expected_memory))
