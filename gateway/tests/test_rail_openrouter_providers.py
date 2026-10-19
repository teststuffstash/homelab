"""GW-RAIL-OPENROUTER §Attribution / §Selection / §Failover — the provider axis (specs/endpoints/openai-chat.md;
operator rulings 2026-10-19, homelab#2741: `:exacto` is not ported).

World `policy-default · openrouter-endpoints` unless a row says `(no snapshot)`: the store holds the
endpoint snapshot of `deepseek/deepseek-v4.1-flash` (tests/fixtures/openrouter-endpoints/, ten endpoints
trimmed from the live answer of 2026-10-19), the fake openrouter upstream answers a PINNED request as
`provider_behaviours[slug]` says and names the serving provider in every 200. A worker with harness
opencode, `rail: openrouter`, `tier: heavy` rides v4.1-flash (covered); `tier: standard` rides
`deepseek/deepseek-v4-flash` (no snapshot: unpinned). M = deepseek/deepseek-v4.1-flash.

Attribution — the answer names the cell:

| description | ride | the answer names || request row `provider` | strike `provider` |
|---|---|---||---|---|
| a chat completion's provider is the cell | pinned deepinfra, upstream-ok | `provider: "DeepInfra"` || deepinfra | — |
| a stream's first chunk names the cell | pinned deepinfra, upstream-stream | the first chunk's `provider: "DeepInfra"` || deepinfra | — |
| the snapshot joins the display name to the slug provider.order uses | pinned inference-net (deepinfra + atlas-cloud + morph struck) | `provider: "InferenceNet"` || inference-net | — |
| a name the snapshot lacks is slugged by rule | unpinned (M' = v4-flash, no snapshot), upstream-ok | `provider: "Sail Research"` || sail-research (lower-case, non-alphanumerics → `-`) | — |
| the rule is not the tag: a snapshot-less name may differ from its slug | unpinned (M'), upstream-ok | `provider: "OpenInference"` || openinference (the tag reads `open-inference`) | — |
| an answer that names no provider is unattributed | unpinned (M'), upstream-ok, no `provider` || '' | — |
| the answer's name outranks the pin | pinned deepinfra; the fake answers as AtlasCloud || atlas-cloud (logged) | — |
| a transport strike carries the provider | unpinned (M'), upstream-stream-truncated, `provider: "Sail Research"` || sail-research | stream-incomplete @ sail-research |

Selection — the gateway's own evidence, never `:exacto`:

| description | harness | arrange || the order (`provider.order[0]` of successive attempts), or the pin |
|---|---|---||---|
| the floors: ≥ fp8, every tool-choice mode the harness uses, uptime_1d ≥ 95, status 0 | opencode | — || deepinfra, atlas-cloud, morph, inference-net, baidu (dropped: open-inference fp4, alibaba unknown, parasail uptime 77.4) |
| a harness that needs required + function drops the providers without them | claude (anthropic dialect) | — || deepinfra, atlas-cloud, inference-net (morph, baidu dropped) |
| the pin is one provider with fallbacks off | opencode | — || upstream body `provider = {order: [deepinfra], allow_fallbacks: false}`; model and messages unchanged |
| a provider's service tiers are one order entry: the default tag represents | opencode | deepinfra/fp8, /flex (uptime 84.5), /priority in the snapshot || the deepinfra entry is `deepinfra/fp8` (out $0.42/M) |
| the order is price ÷ the cell's clean-ride rate | opencode | 5 judged rides on deepinfra, 2 clean (rate 0.4: 0.42 ÷ 0.4 = 1.05) || atlas-cloud first (0.54), deepinfra 4th (before baidu's 1.2) |
| under min_rides the uptime is the prior | opencode | 4 judged rides on deepinfra, 0 clean || deepinfra still first (prior: uptime 100) |
| a struck provider cell is left out for the task | opencode | the task's earlier ride struck `harness-gave-up` on deepinfra || atlas-cloud first; another task still pins deepinfra |
| a cooled provider cell is left out | opencode | deepinfra answered 429 (retry-after 30) on the previous request || atlas-cloud first; +30 s deepinfra again |
| no snapshot for the model: the request rides unpinned | opencode (M') | — || the upstream body carries no `provider` key |

Failover — before the first byte only, bounded, silent to the harness:

| description | provider_behaviours || upstream calls (pins, in order) | status | the harness sees | strikes (class @ provider) | `gateway_provider_failovers_total{model=M,from,to}` |
|---|---||---|---|---|---|---|
| fails over once | deepinfra: upstream-500 || deepinfra, atlas-cloud | 200 | one JSON answer, served by AtlasCloud | provider-5xx @ deepinfra | deepinfra→atlas-cloud 1 |
| fails over twice | deepinfra: upstream-500, atlas-cloud: upstream-html || deepinfra, atlas-cloud, morph | 200 | served by Morph | provider-5xx @ deepinfra, provider-5xx @ atlas-cloud | deepinfra→atlas-cloud 1, atlas-cloud→morph 1 |
| exhausts the order: the last answer is the typed error, bounded by max_providers_per_request 3 | deepinfra, atlas-cloud, morph: upstream-500 || deepinfra, atlas-cloud, morph (inference-net never asked) | 500 | the last provider's 500 body | provider-5xx @ deepinfra, @ atlas-cloud, @ morph | 2 series, 1 each |
| a 429 fails over and cools only that provider's cell | deepinfra: upstream-429 || deepinfra, atlas-cloud | 200 | served by AtlasCloud | none (a 429 is a cooldown) | deepinfra→atlas-cloud 1 |
| the cooled provider's model still admits | deepinfra: upstream-429 || deepinfra, atlas-cloud | 200 | served by AtlasCloud | none | `gateway_cells_cooled{rail=openrouter}` 1; `POST /sessions` worker, rail openrouter, tier heavy → dispatch M |
| a provider's own refusal (a 4xx naming it) fails over | deepinfra: upstream-provider-400 || deepinfra, atlas-cloud | 200 | served by AtlasCloud | refused @ deepinfra | deepinfra→atlas-cloud 1 |
| a 2xx the dialect cannot read is a pre-byte failure | deepinfra: upstream-html || deepinfra, atlas-cloud | 200 | served by AtlasCloud | provider-5xx @ deepinfra | deepinfra→atlas-cloud 1 |
| a post-byte failure never fails over | deepinfra: upstream-stream-truncated || deepinfra | 200, incomplete (no-terminal) | the cut stream | stream-incomplete @ deepinfra | none |
| every provider cooled or struck mid-session: the request rides unpinned | the five eligible cells cooled by 429s || the next request carries no `provider` key | 200 | served (the lottery) | — | — |
"""

from __future__ import annotations

import json
import re

import pytest

from agent_gateway.providers import _row, eligible, representatives

from .conftest import (
    attach_json,
    bearer,
    check,
    given,
    open_session,
    quiet,
    rule,
    seed_openrouter_endpoints,
    then,
    then_eq,
    when,
    world,
)

pytestmark = rule("GW-RAIL-OPENROUTER")
RAIL = "openrouter"
M = "deepseek/deepseek-v4.1-flash"  # covered by the snapshot (the heavy tier)
M2 = "deepseek/deepseek-v4-flash"  # not covered (the standard tier): rides unpinned
WORLD = "openrouter-endpoints"
PATH = "/openai/v1/chat/completions"
H = 3600


@pytest.fixture
async def orworld(app, store, upstreams):
    """The `openrouter-endpoints` world: the snapshot seeded, the fake taught the display names."""
    body = seed_openrouter_endpoints(store, upstreams[RAIL])
    app.state.providers.reload()
    return body


def _pins(upstream) -> list[str | None]:
    return [((c["body"] or {}).get("provider") or {}).get("order", [None])[0] if isinstance((c["body"] or {}).get("provider"), dict) else None
            for c in upstream.calls]


async def _session(gw, tier: str = "heavy", task: str = "homelab-2741-r1", harness: str = "opencode", **extra) -> dict:
    with given(f"a session on rail openrouter: worker, harness {harness}, tier {tier} ({M if tier == 'heavy' else M2}), task {task}"):
        return await open_session(gw, role="worker", harness=harness, rail=RAIL, tier=tier, task=task, **extra)


async def _ride(gw, doc: dict, stream: bool = False, label: str = ""):
    model = doc["model"]
    body = {"model": model, "messages": [{"role": "user", "content": "hi"}], "max_tokens": 8, **({"stream": True} if stream else {})}
    with when(f"POST {PATH} model {model}{' stream' if stream else ''}{label}"):
        return await gw.post(PATH, json=body, headers=bearer(doc))


def _row_provider(store, doc: dict) -> list[str]:
    return [r["provider"] for r in store.requests_for(doc["session"]["id"])]


def _strikes(store, task: str) -> list[tuple[str, str, str]]:
    return [(s["class"], s["provider"], s["source"]) for s in store.strikes_for("platform", task)]


async def _series(gw, family: str, labels: dict[str, str]) -> float | None:
    with quiet():
        text = (await gw.get("/metrics")).text
    want = family + "{" + ",".join(f'{k}="{v}"' for k, v in labels.items()) + "}"
    m = re.search("^" + re.escape(want) + r" (\S+)$", text, re.M)
    attach_json(f"sample: {want}", {"line": m.group(0) if m else None})
    return float(m.group(1)) if m else None


# -- attribution -----------------------------------------------------------------------------------
async def test_chat_provider_is_the_cell(gw, store, upstreams, orworld):
    """row: a chat completion's provider is the cell"""
    world(upstream="upstream-ok", note=WORLD)
    doc = await _session(gw)
    r = await _ride(gw, doc)
    then_eq("status", r.status_code, 200)
    then_eq("the answer's provider", r.json().get("provider"), "DeepInfra")
    then_eq("the request row's provider", _row_provider(store, doc), ["deepinfra"])


async def test_stream_first_chunk_names_the_cell(gw, store, upstreams, orworld):
    """row: a stream's first chunk names the cell"""
    world(upstream="upstream-stream", note=WORLD)
    upstreams[RAIL].behaviour = "upstream-stream"
    doc = await _session(gw)
    r = await _ride(gw, doc, stream=True)
    then_eq("status", r.status_code, 200)
    first = json.loads(r.text.split("\n")[0][5:])
    then_eq("the first chunk's provider", first.get("provider"), "DeepInfra")
    then_eq("the request row's provider", _row_provider(store, doc), ["deepinfra"])


async def test_snapshot_joins_display_to_slug(gw, store, upstreams, orworld):
    """row: the snapshot joins the display name to the slug provider.order uses"""
    world(upstream="upstream-ok", note=WORLD)
    task = "homelab-2741-join"
    with given("the task's earlier rides struck deepinfra, atlas-cloud and morph (harness-gave-up)"):
        for _ in range(3):
            with quiet():
                d = await open_session(gw, role="worker", harness="opencode", rail=RAIL, tier="heavy", task=task)
                await gw.post(PATH, json={"model": M, "messages": []}, headers=bearer(d))
                await gw.post(f"/sessions/{d['session']['id']}/outcome", json={"class": "harness-gave-up"})
        attach_json("struck", _strikes(store, task))
    doc = await _session(gw, task=task)
    r = await _ride(gw, doc)
    then_eq("status", r.status_code, 200)
    then_eq("the answer's provider (the display name)", r.json().get("provider"), "InferenceNet")
    then_eq("the request row's provider (the tag's base slug)", _row_provider(store, doc), ["inference-net"])


RULE_ROWS = [
    ("a name the snapshot lacks is slugged by rule", "Sail Research", "sail-research"),
    ("the rule is not the tag: a snapshot-less name may differ from its slug", "OpenInference", "openinference"),
    ("an answer that names no provider is unattributed", None, ""),
]


@pytest.mark.parametrize(("display", "slug"), [r[1:] for r in RULE_ROWS], ids=[r[0] for r in RULE_ROWS])
async def test_attribution_rule(gw, store, upstreams, orworld, display, slug):
    world(upstream="upstream-ok", note=f"{WORLD}; {M2} has no snapshot entry")
    upstreams[RAIL].provider_display = display
    doc = await _session(gw, tier="standard")
    r = await _ride(gw, doc)
    then_eq("status", r.status_code, 200)
    then_eq("the upstream body carries no provider pin", "provider" in (upstreams[RAIL].calls[-1]["body"] or {}), False)
    then_eq("the request row's provider", _row_provider(store, doc), [slug],
            claim=f"the request row's provider = {slug!r} (the answer named {display!r})")


async def test_answer_outranks_pin(gw, store, upstreams, orworld):
    """row: the answer's name outranks the pin"""
    world(upstream="upstream-ok", note=f"{WORLD}; the fake answers a deepinfra pin as AtlasCloud")
    upstreams[RAIL].provider_names["deepinfra"] = "AtlasCloud"
    doc = await _session(gw)
    r = await _ride(gw, doc)
    then_eq("status", r.status_code, 200)
    then_eq("the pin", _pins(upstreams[RAIL]), ["deepinfra"])
    then_eq("the request row's provider (the answer's)", _row_provider(store, doc), ["atlas-cloud"])


async def test_transport_strike_carries_provider(gw, store, upstreams, orworld):
    """row: a transport strike carries the provider"""
    world(upstream="upstream-stream-truncated", note=f"{WORLD}; {M2} unpinned, the fake names Sail Research")
    upstreams[RAIL].behaviour = "upstream-stream-truncated"
    upstreams[RAIL].provider_display = "Sail Research"
    task = "homelab-2741-cut"
    doc = await _session(gw, tier="standard", task=task)
    r = await _ride(gw, doc, stream=True)
    then_eq("status", r.status_code, 200)
    then_eq("the request row's provider", _row_provider(store, doc), ["sail-research"])
    then_eq("the strike", _strikes(store, task), [("stream-incomplete", "sail-research", "gateway")])


# -- selection -------------------------------------------------------------------------------------
async def _order_seen(gw, upstreams, harness: str, task: str, n: int) -> list[str]:
    """The first n providers the gateway pins for `task`: n rides on one session, each striking the
    provider it rode (harness-gave-up on a fresh session of the task) so the next pins the next."""
    seen: list[str] = []
    for _ in range(n):
        with quiet():
            d = await open_session(gw, role="worker", harness=harness, rail=RAIL, tier="heavy", task=task)
            path = "/anthropic/v1/messages" if harness == "claude" else PATH
            r = await gw.post(path, json={"model": M, "messages": [], "max_tokens": 8}, headers=bearer(d))
            assert r.status_code == 200, r.text
            seen.append(_pins(upstreams[RAIL])[-1])
            await gw.post(f"/sessions/{d['session']['id']}/outcome", json={"class": "harness-gave-up"})
    return seen


async def test_floors(gw, upstreams, policy, orworld):
    """row: the floors: ≥ fp8, every tool-choice mode the harness uses, uptime_1d ≥ 95, status 0"""
    world(upstream="upstream-ok", note=WORLD)
    with when("five rides on task T (opencode), each striking the provider it rode"):
        seen = await _order_seen(gw, upstreams, "opencode", "homelab-2741-floors", 5)
    then_eq("the order", seen, ["deepinfra", "atlas-cloud", "morph", "inference-net", "baidu"])
    pol = policy.rails[RAIL].providers
    with when("eligible() over the snapshot's rows for harness opencode"):
        kept, dropped = eligible([_row(d) for d in orworld["models"][M]["endpoints"]], pol, "opencode")
    then_eq("dropped, and why", dropped, {"open-inference": "quantization fp4 < fp8", "alibaba": "quantization unknown",
                                         "parasail": "uptime_1d 77.4359 < 95"})
    then_eq("kept", sorted(e.slug for e in kept), ["atlas-cloud", "baidu", "deepinfra", "inference-net", "morph"])


async def test_floors_claude(gw, upstreams, orworld):
    """row: a harness that needs required + function drops the providers without them"""
    world(upstream="upstream-ok", note=f"{WORLD}; claude speaks the anthropic dialect on this rail")
    with when("three rides on task T (claude), each striking the provider it rode"):
        seen = await _order_seen(gw, upstreams, "claude", "homelab-2741-claude", 3)
    then_eq("the order", seen, ["deepinfra", "atlas-cloud", "inference-net"])


async def test_pin_shape(gw, upstreams, orworld):
    """row: the pin is one provider with fallbacks off"""
    world(upstream="upstream-ok", note=WORLD)
    doc = await _session(gw)
    r = await _ride(gw, doc)
    then_eq("status", r.status_code, 200)
    body = upstreams[RAIL].calls[-1]["body"]
    then_eq("the upstream body's provider block", body.get("provider"), {"order": ["deepinfra"], "allow_fallbacks": False})
    then_eq("the rest of the body is the harness's", {k: v for k, v in body.items() if k != "provider"},
            {"model": M, "messages": [{"role": "user", "content": "hi"}], "max_tokens": 8})


async def test_tiers_are_one_entry(orworld, policy):
    """row: a provider's service tiers are one order entry: the default tag represents"""
    world(note=f"{WORLD} (the snapshot read directly)")
    eps = [_row(d) for d in orworld["models"][M]["endpoints"]]
    with when("representatives() over the snapshot's deepinfra rows"):
        reps = representatives(eps)
    then_eq("the deepinfra tags in the snapshot", sorted(e.tag for e in eps if e.slug == "deepinfra"),
            ["deepinfra/fp8", "deepinfra/fp8/flex", "deepinfra/fp8/priority"])
    then_eq("the representative", (reps["deepinfra"].tag, reps["deepinfra"].out_price, reps["deepinfra"].service_tier),
            ("deepinfra/fp8", 0.42, None))


async def _judge(gw, upstreams, outcomes: list[str]) -> None:
    """Arrange judged rides on the first-ordered provider: one session per outcome, each on its own task."""
    for i, klass in enumerate(outcomes):
        with quiet():
            d = await open_session(gw, role="worker", harness="opencode", rail=RAIL, tier="heavy", task=f"homelab-2741-judge-{i}")
            await gw.post(PATH, json={"model": M, "messages": []}, headers=bearer(d))
            await gw.post(f"/sessions/{d['session']['id']}/outcome", json={"class": klass})
    attach_json("judged rides on deepinfra", {"outcomes": outcomes, "pins": _pins(upstreams[RAIL])})


async def test_order_is_price_over_clean_rate(gw, upstreams, store, orworld):
    """row: the order is price ÷ the cell's clean-ride rate"""
    world(upstream="upstream-ok", note=WORLD)
    with given("5 judged rides on deepinfra: 2 clean, 3 harness-gave-up (rate 0.4)"):
        await _judge(gw, upstreams, ["clean", "harness-gave-up", "clean", "harness-gave-up", "harness-gave-up"])
    then_eq("the store's cell outcomes", store.cell_outcomes(RAIL, M), {"deepinfra": (2, 5)})
    with when("five rides on a new task, each striking the provider it rode"):
        seen = await _order_seen(gw, upstreams, "opencode", "homelab-2741-rate", 5)
    then_eq("the order", seen, ["atlas-cloud", "morph", "inference-net", "deepinfra", "baidu"])


async def test_prior_under_min_rides(gw, upstreams, store, orworld):
    """row: under min_rides the uptime is the prior"""
    world(upstream="upstream-ok", note=WORLD)
    with given("4 judged rides on deepinfra, none clean (min_rides 5)"):
        await _judge(gw, upstreams, ["harness-gave-up"] * 4)
    then_eq("the store's cell outcomes", store.cell_outcomes(RAIL, M), {"deepinfra": (0, 4)})
    doc = await _session(gw, task="homelab-2741-prior")
    r = await _ride(gw, doc)
    then_eq("status", r.status_code, 200)
    then_eq("the pin", _pins(upstreams[RAIL])[-1], "deepinfra")


async def test_struck_cell_left_out(gw, upstreams, store, orworld):
    """row: a struck provider cell is left out for the task"""
    world(upstream="upstream-ok", note=WORLD)
    task = "homelab-2741-struck"
    with given("the task's earlier ride struck harness-gave-up on deepinfra"):
        with quiet():
            d = await open_session(gw, role="worker", harness="opencode", rail=RAIL, tier="heavy", task=task)
            await gw.post(PATH, json={"model": M, "messages": []}, headers=bearer(d))
            await gw.post(f"/sessions/{d['session']['id']}/outcome", json={"class": "harness-gave-up"})
        attach_json("the strike", _strikes(store, task))
    doc = await _session(gw, task=task)
    r = await _ride(gw, doc, label=" (the task)")
    then_eq("status", r.status_code, 200)
    then_eq("the task's pin", _pins(upstreams[RAIL])[-1], "atlas-cloud")
    other = await _session(gw, task="homelab-2741-other")
    r2 = await _ride(gw, other, label=" (another task)")
    then_eq("status", r2.status_code, 200)
    then_eq("another task's pin", _pins(upstreams[RAIL])[-1], "deepinfra")


async def test_cooled_cell_left_out(gw, upstreams, clock, orworld):
    """row: a cooled provider cell is left out"""
    world(upstream="upstream-429", note=f"{WORLD}; deepinfra answers 429 retry-after 30 once")
    upstreams[RAIL].provider_behaviours["deepinfra"] = "upstream-429"
    doc = await _session(gw)
    with given("a ride whose deepinfra attempt answered 429 (failed over to atlas-cloud)"):
        with quiet():
            r = await gw.post(PATH, json={"model": M, "messages": []}, headers=bearer(doc))
        attach_json("the ride", {"status": r.status_code, "pins": _pins(upstreams[RAIL])})
        upstreams[RAIL].provider_behaviours.clear()
    r = await _ride(gw, doc, label=" (the next request)")
    then_eq("status", r.status_code, 200)
    then_eq("the pin while deepinfra is cooled", _pins(upstreams[RAIL])[-1], "atlas-cloud")
    clock.advance(30)
    r = await _ride(gw, doc, label=" (+30 s)")
    then_eq("the pin at the cooldown's reset", _pins(upstreams[RAIL])[-1], "deepinfra")


async def test_no_snapshot_unpinned(gw, upstreams, orworld):
    """row: no snapshot for the model: the request rides unpinned"""
    world(upstream="upstream-ok", note=f"{WORLD}; {M2} has no snapshot entry")
    doc = await _session(gw, tier="standard")
    r = await _ride(gw, doc)
    then_eq("status", r.status_code, 200)
    then_eq("the upstream body's provider key", (upstreams[RAIL].calls[-1]["body"] or {}).get("provider"), None)


# -- failover --------------------------------------------------------------------------------------
FAILOVER_ROWS = [
    ("fails over once", {"deepinfra": "upstream-500"}, ["deepinfra", "atlas-cloud"], 200, "AtlasCloud",
     [("provider-5xx", "deepinfra", "gateway")], {("deepinfra", "atlas-cloud"): 1}),
    ("fails over twice", {"deepinfra": "upstream-500", "atlas-cloud": "upstream-html"}, ["deepinfra", "atlas-cloud", "morph"], 200, "Morph",
     [("provider-5xx", "deepinfra", "gateway"), ("provider-5xx", "atlas-cloud", "gateway")],
     {("deepinfra", "atlas-cloud"): 1, ("atlas-cloud", "morph"): 1}),
    ("exhausts the order: the last answer is the typed error, bounded by max_providers_per_request 3",
     {"deepinfra": "upstream-500", "atlas-cloud": "upstream-500", "morph": "upstream-500"}, ["deepinfra", "atlas-cloud", "morph"], 500, None,
     [("provider-5xx", "deepinfra", "gateway"), ("provider-5xx", "atlas-cloud", "gateway"), ("provider-5xx", "morph", "gateway")],
     {("deepinfra", "atlas-cloud"): 1, ("atlas-cloud", "morph"): 1}),
    ("a 429 fails over and cools only that provider's cell", {"deepinfra": "upstream-429"}, ["deepinfra", "atlas-cloud"], 200, "AtlasCloud",
     [], {("deepinfra", "atlas-cloud"): 1}),
    ("a provider's own refusal (a 4xx naming it) fails over", {"deepinfra": "upstream-provider-400"}, ["deepinfra", "atlas-cloud"], 200, "AtlasCloud",
     [("refused", "deepinfra", "gateway")], {("deepinfra", "atlas-cloud"): 1}),
    ("a 2xx the dialect cannot read is a pre-byte failure", {"deepinfra": "upstream-html"}, ["deepinfra", "atlas-cloud"], 200, "AtlasCloud",
     [("provider-5xx", "deepinfra", "gateway")], {("deepinfra", "atlas-cloud"): 1}),
]


@pytest.mark.parametrize(("behaviours", "calls", "status", "served", "strikes", "failovers"), [r[1:] for r in FAILOVER_ROWS],
                         ids=[r[0] for r in FAILOVER_ROWS])
async def test_failover(gw, store, upstreams, orworld, behaviours, calls, status, served, strikes, failovers):
    world(upstream="upstream-ok", note=f"{WORLD}; provider_behaviours {behaviours}")
    upstreams[RAIL].provider_behaviours.update(behaviours)
    task = "homelab-2741-failover"
    doc = await _session(gw, task=task)
    r = await _ride(gw, doc)
    then_eq("status", r.status_code, status)
    then_eq("the upstream calls, in order", _pins(upstreams[RAIL]), calls)
    if served:
        then_eq("the harness sees one answer, served by", (r.headers["content-type"].split(";")[0], r.json().get("provider")),
                ("application/json", served))
    else:
        then_eq("the harness sees the typed error, served by nobody", r.json().get("provider"), None,
                claim=f"served = {served!r}: the harness sees the last provider's error body, no answer")
    then_eq("the request rows' providers (one per attempt)", _row_provider(store, doc), calls)
    then_eq("strikes (class, provider, source)", _strikes(store, task), strikes)
    for (frm, to), n in failovers.items():
        with then(f"gateway_provider_failovers_total{{model={M},from={frm},to={to}}} = {n}"):
            check("series", await _series(gw, "gateway_provider_failovers_total", {"model": M, "from": frm, "to": to}), n)


async def test_429_cools_only_the_provider(gw, store, upstreams, orworld):
    """row: the cooled provider's model still admits"""
    world(upstream="upstream-429", note=f"{WORLD}; deepinfra answers 429")
    upstreams[RAIL].provider_behaviours["deepinfra"] = "upstream-429"
    doc = await _session(gw)
    r = await _ride(gw, doc)
    then_eq("status", r.status_code, 200)
    with then("gateway_cells_cooled{rail=openrouter} = 1 (the deepinfra cell)"):
        check("series", await _series(gw, "gateway_cells_cooled", {"rail": RAIL}), 1)
    with when("POST /sessions worker, rail openrouter, tier heavy (the model whose deepinfra cell is cooled)"):
        a = await gw.post("/sessions", json={"stack": "platform", "role": "worker", "task": "homelab-2741-admit", "rail": RAIL,
                                             "tier": "heavy", "harness": "opencode"})
    then_eq("the model still admits", (a.json()["decision"], a.json().get("model")), ("dispatch", M))


async def test_post_byte_never_fails_over(gw, store, upstreams, orworld):
    """row: a post-byte failure never fails over"""
    world(upstream="upstream-stream-truncated", note=f"{WORLD}; deepinfra cuts the stream after its first chunk")
    upstreams[RAIL].provider_behaviours["deepinfra"] = "upstream-stream-truncated"
    task = "homelab-2741-postbyte"
    doc = await _session(gw, task=task)
    r = await _ride(gw, doc, stream=True)
    then_eq("status", r.status_code, 200)
    then_eq("the upstream calls", _pins(upstreams[RAIL]), ["deepinfra"])
    row = store.requests_for(doc["session"]["id"])[-1]
    then_eq("the request row: (provider, incomplete)", (row["provider"], row["incomplete"]), ("deepinfra", "no-terminal"))
    then_eq("strikes", _strikes(store, task), [("stream-incomplete", "deepinfra", "gateway")])
    then_eq("no failover series", await _series(gw, "gateway_provider_failovers_total", {"model": M, "from": "deepinfra", "to": "atlas-cloud"}), None)


async def test_all_cooled_rides_unpinned(gw, upstreams, orworld):
    """row: every provider cooled or struck mid-session: the request rides unpinned"""
    world(upstream="upstream-429", note=f"{WORLD}; every eligible provider answers 429")
    for slug in ("deepinfra", "atlas-cloud", "morph", "inference-net", "baidu"):
        upstreams[RAIL].provider_behaviours[slug] = "upstream-429"
    doc = await _session(gw)
    with given("two requests whose pinned attempts all answered 429 (3 + 2 providers cooled)"):
        with quiet():
            r1 = await gw.post(PATH, json={"model": M, "messages": []}, headers=bearer(doc))
            r2 = await gw.post(PATH, json={"model": M, "messages": []}, headers=bearer(doc))
        attach_json("the two requests", {"statuses": [r1.status_code, r2.status_code], "pins": _pins(upstreams[RAIL])})
        upstreams[RAIL].provider_behaviours.clear()
    r = await _ride(gw, doc, label=" (every provider cooled)")
    then_eq("status", r.status_code, 200)
    then_eq("the upstream body's provider key", (upstreams[RAIL].calls[-1]["body"] or {}).get("provider"), None)
