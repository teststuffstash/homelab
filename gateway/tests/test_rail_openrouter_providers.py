"""GW-RAIL-OPENROUTER §Attribution / §Selection / §Failover — the provider axis
(specs/endpoints/openai-chat.md; operator rulings 2026-10-19, homelab#2741: `:exacto` is not ported).

One parametrized case per table row: the argnames are the table's header cells (`name?` is
`expected_name`), the ids its description cells, the literals the page's Legend lines. World
`policy-default · openrouter-endpoints`: the store holds the endpoint snapshot of
`deepseek/deepseek-v4.1-flash` (M — the heavy tier; tests/fixtures/openrouter-endpoints/, ten
endpoints trimmed from the live answer of 2026-10-19), the fake openrouter upstream answers a PINNED
request as the `providers` cell says and names the serving provider in every 200;
`deepseek/deepseek-v4-flash` (M′ — the standard tier) has no snapshot entry and rides unpinned.
"""

from __future__ import annotations

import json
import re

import pytest

from agent_gateway.providers import SNAPSHOT_SOURCE, _row, eligible, parse_endpoints, representatives

from ._rail_rows import NONE, inputs, parse_pairs
from .conftest import (
    OPENROUTER_ENDPOINTS_FIXTURES,
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
SYMBOL = {M: "M", M2: "M′"}
TIER = {"M": "heavy", "M′": "standard"}
WORLD = "openrouter-endpoints"
PATH = "/openai/v1/chat/completions"
NO_BLOCK = "(no provider block)"
EMPTY = "(empty)"
ELIGIBLE = ("deepinfra", "atlas-cloud", "morph", "inference-net", "baidu")


def _world(upstream: str = "upstream-ok", note: str | None = None) -> None:
    world(upstream=f"{WORLD} · {upstream}", note=note)


def _seed(app, store, upstream, snapshot: str = "the ten endpoints") -> dict:
    """The world's endpoint snapshot (specs/worlds/README.md §The openrouter-endpoints world), as the
    `snapshot` cell spells it: `the ten endpoints` = the fixture as read; `<tag> at uptime_last_1d
    null` = the same with that endpoint's `uptime_last_1d` set to null (the vendor's answer for a
    fresh or idle endpoint)."""
    with given(f"snapshot = {snapshot}: the store holds M's endpoint snapshot, every cell eligible; the fake knows the display names"):
        if snapshot == "the ten endpoints":
            body = seed_openrouter_endpoints(store, upstream)
        else:
            tag = snapshot.split(" at uptime_last_1d null")[0]
            raw = json.loads((OPENROUTER_ENDPOINTS_FIXTURES / "deepseek-v4.1-flash.json").read_text(encoding="utf-8"))
            for e in raw["data"]["endpoints"]:
                if e["tag"] == tag:
                    e["uptime_last_1d"] = None
            parsed = parse_endpoints(raw)
            body = {"models": {parsed["model"]: {"endpoints": parsed["endpoints"]}}}
            upstream.provider_names.update({e["slug"]: e["provider_name"] for e in parsed["endpoints"]})
            store.snapshot_save(SNAPSHOT_SOURCE, 1_800_000_000.0, body)
            for e in parsed["endpoints"]:
                store.cell_set(parsed["model"], e["slug"], "eligible", None, 1_800_000_000.0, None)
        app.state.providers.reload()
        attach_json("the snapshot's endpoints (tag · quantization · uptime_1d · out $/M)",
                    [f"{e['tag']} · {e['quantization']} · {e['uptime_1d']} · {e['out_price']}" for e in body["models"][M]["endpoints"]])
    return body


def _pins(upstream) -> list[str | None]:
    return [((c["body"] or {}).get("provider") or {}).get("order", [None])[0] if isinstance((c["body"] or {}).get("provider"), dict) else None
            for c in upstream.calls if c["path"] in ("/v1/chat/completions", "/v1/messages")]


def _pin_cell(pin: str | None) -> str:
    return pin or NONE


async def _session(gw, model: str = "M", task: str = "homelab-2741-r1", harness: str = "opencode", **extra) -> dict:
    tier = TIER[model]
    with given(f"a session on rail openrouter: worker, harness {harness}, tier {tier} — model = {model} ({M if model == 'M' else M2}), task {task}"):
        return await open_session(gw, role="worker", harness=harness, rail=RAIL, tier=tier, task=task, **extra)


async def _ride(gw, doc: dict, stream: bool = False, label: str = ""):
    model = doc["model"]
    body = {"model": model, "messages": [{"role": "user", "content": "hi"}], "max_tokens": 8, **({"stream": True} if stream else {})}
    with when(f"POST {PATH} model {model}{' stream' if stream else ''} · {label}"):
        return await gw.post(PATH, json=body, headers=bearer(doc))


def _row_provider(store, doc: dict) -> list[str]:
    return [r["provider"] for r in store.requests_for(doc["session"]["id"])]


def _strikes(store, task: str) -> str:
    """`strikes?`: `class @ provider` per strike of the task, in store order; `(none)`."""
    return ", ".join(f"{s['class']} @ {s['provider']}" for s in store.strikes_for("platform", task)) or NONE


async def _metrics(gw) -> str:
    with quiet():
        return (await gw.get("/metrics")).text


def _failovers(text: str, attempts: list[str | None]) -> str:
    """`failovers?`: every `gateway_provider_failovers_total{model=M,from,to}` sample as `from→to n`,
    in the order the attempts moved (the exposition sorts labels alphabetically); `(none)`."""
    found = re.findall(rf'^gateway_provider_failovers_total\{{model="{re.escape(M)}",from="([^"]+)",to="([^"]+)"\}} (\S+)$', text, re.M)
    order = [p for p in attempts if p]
    found.sort(key=lambda x: order.index(x[0]) if x[0] in order else len(order))
    return ", ".join(f"{f}→{t} {int(float(n))}" for f, t, n in found) or NONE


def _named_provider(r) -> str:
    """`served_by?` / the answer's provider: a completion's `provider`, a stream's first chunk's,
    an error envelope's `error.metadata.provider_name`; `(none)`."""
    ctype = r.headers.get("content-type") or ""
    if "event-stream" in ctype:
        first = json.loads(r.text.split("\n")[0][5:])
        return first.get("provider") or NONE
    if "json" not in ctype:
        return NONE
    body = r.json()
    if isinstance(body.get("error"), dict):
        return (body["error"].get("metadata") or {}).get("provider_name") or NONE
    return body.get("provider") or NONE


async def _strike_for(gw, task: str, slugs: list[str]) -> None:
    """One ride per slug on `task`, each struck `harness-gave-up` — the first-ordered cell each time."""
    for _ in slugs:
        with quiet():
            d = await open_session(gw, role="worker", harness="opencode", rail=RAIL, tier="heavy", task=task)
            await gw.post(PATH, json={"model": M, "messages": []}, headers=bearer(d))
            await gw.post(f"/sessions/{d['session']['id']}/outcome", json={"class": "harness-gave-up"})


# -- Attribution: the answer names the cell -------------------------------------------------------
PINNED_ROWS = [  # description | model | upstream | struck | answer_provider | pin? | row_provider?
    ("a chat completion's provider is the cell", "M", "upstream-ok", NONE, "DeepInfra", "deepinfra", "deepinfra"),
    ("a stream's first chunk names the cell", "M", "upstream-stream", NONE, "DeepInfra", "deepinfra", "deepinfra"),
    ("the snapshot joins the display name to the slug provider.order uses", "M", "upstream-ok", "deepinfra, atlas-cloud, morph", "InferenceNet",
     "inference-net", "inference-net"),
    ("the answer's name outranks the pin ⚖", "M", "upstream-ok", NONE, "AtlasCloud", "deepinfra", "atlas-cloud"),
]


@pytest.mark.parametrize(("model", "upstream", "struck", "answer_provider", "expected_pin", "expected_row_provider"),
                         [r[1:] for r in PINNED_ROWS], ids=[r[0] for r in PINNED_ROWS])
async def test_attribution_pinned(gw, app, store, upstreams, model, upstream, struck, answer_provider, expected_pin, expected_row_provider):
    _world(upstream)
    _seed(app, store, upstreams[RAIL])
    upstreams[RAIL].behaviour = upstream
    task = "homelab-2741-attr"
    if struck != NONE:
        with given(f"struck = {struck}: the task's earlier rides struck those cells (harness-gave-up)"):
            await _strike_for(gw, task, [s.strip() for s in struck.split(",")])
            attach_json("the task's strikes", _strikes(store, task))
    with given(f"answer_provider = {answer_provider}: the display name the upstream's every answer carries"):
        upstreams[RAIL].provider_names = {slug: answer_provider for slug in upstreams[RAIL].provider_names}
    doc = await _session(gw, model, task=task)
    r = await _ride(gw, doc, stream=upstream == "upstream-stream", label=inputs(model=model, upstream=upstream, struck=struck, answer_provider=answer_provider))
    with then(f"status 200; pin? = {expected_pin}; the answer names {answer_provider}",
              status={"expected": 200, "actual": r.status_code}, expected_pin={"expected": expected_pin, "actual": _pin_cell(_pins(upstreams[RAIL])[-1])},
              answer_provider={"expected": answer_provider, "actual": _named_provider(r)}):
        assert r.status_code == 200 and _pin_cell(_pins(upstreams[RAIL])[-1]) == expected_pin and _named_provider(r) == answer_provider
    then_eq("expected_row_provider", _row_provider(store, doc)[-1], expected_row_provider, claim=f"row_provider? = {expected_row_provider} (requests.provider)")


# -- Attribution: a name the snapshot lacks --------------------------------------------------------
UNPINNED_ROWS = [  # description | model | upstream | answer_provider | pin? | row_provider? | strike?
    ("a name the snapshot lacks is slugged by rule ⚖", "M′", "upstream-ok", "Sail Research", NONE, "sail-research", NONE),
    ("the rule is not the tag: a snapshot-less name may differ from its slug ⚖", "M′", "upstream-ok", "OpenInference", NONE, "openinference", NONE),
    ("an answer that names no provider is unattributed", "M′", "upstream-ok", NONE, NONE, EMPTY, NONE),
    ("a transport strike carries the provider", "M′", "upstream-stream-truncated", "Sail Research", NONE, "sail-research", "stream-incomplete @ sail-research"),
]


@pytest.mark.parametrize(("model", "upstream", "answer_provider", "expected_pin", "expected_row_provider", "expected_strike"),
                         [r[1:] for r in UNPINNED_ROWS], ids=[r[0] for r in UNPINNED_ROWS])
async def test_attribution_unpinned(gw, app, store, upstreams, model, upstream, answer_provider, expected_pin, expected_row_provider, expected_strike):
    _world(upstream, note=f"{M2} has no snapshot entry")
    _seed(app, store, upstreams[RAIL])
    upstreams[RAIL].behaviour = upstream
    upstreams[RAIL].provider_display = None if answer_provider == NONE else answer_provider
    task = "homelab-2741-unpinned"
    doc = await _session(gw, model, task=task)
    r = await _ride(gw, doc, stream=upstream.startswith("upstream-stream"), label=inputs(model=model, upstream=upstream, answer_provider=answer_provider))
    with then(f"status 200; pin? = {expected_pin} (the upstream body carries no provider block)",
              status={"expected": 200, "actual": r.status_code}, expected_pin={"expected": expected_pin, "actual": _pin_cell(_pins(upstreams[RAIL])[-1])}):
        assert r.status_code == 200 and _pin_cell(_pins(upstreams[RAIL])[-1]) == expected_pin
    then_eq("expected_row_provider", _row_provider(store, doc)[-1] or EMPTY, expected_row_provider,
            claim=f"row_provider? = {expected_row_provider} (the answer named {answer_provider})")
    then_eq("expected_strike", _strikes(store, task), expected_strike, claim=f"strike? = {expected_strike}")


# -- Selection: the order -------------------------------------------------------------------------
ORDER_ROWS = [  # description | harness | snapshot | judged | order?
    ("the floors: ≥ fp8, every tool-choice mode the harness uses, uptime_1d ≥ 95, status 0 ⚖", "opencode", "the ten endpoints", NONE,
     "deepinfra, atlas-cloud, morph, inference-net, baidu"),
    ("an endpoint with no uptime figure is dropped, the model's other endpoints stand ⚖", "opencode", "atlas-cloud/fp8 at uptime_last_1d null", NONE,
     "deepinfra, morph, inference-net, baidu"),
    ("a harness that needs required + function drops the providers without them ⚖", "claude", "the ten endpoints", NONE, "deepinfra, atlas-cloud, inference-net"),
    ("the order is price ÷ the cell's clean-ride rate ⚖", "opencode", "the ten endpoints", "5 rides on deepinfra, 2 clean",
     "atlas-cloud, morph, inference-net, deepinfra, baidu"),
    ("under min_rides the uptime is the prior ⚖", "opencode", "the ten endpoints", "4 rides on deepinfra, 0 clean",
     "deepinfra, atlas-cloud, morph, inference-net, baidu"),
]


async def _judge(gw, judged: str) -> None:
    """`judged` = `N rides on deepinfra, K clean`: N sessions on their own tasks, each one ride on the
    first-ordered cell (deepinfra, fresh) and an outcome — K `clean`, the rest `harness-gave-up`."""
    m = re.match(r"(\d+) rides on deepinfra, (\d+) clean", judged)
    n, k = int(m.group(1)), int(m.group(2))
    outcomes = ["clean"] * k + ["harness-gave-up"] * (n - k)
    for i, klass in enumerate(outcomes):
        with quiet():
            d = await open_session(gw, role="worker", harness="opencode", rail=RAIL, tier="heavy", task=f"homelab-2741-judge-{i}")
            await gw.post(PATH, json={"model": M, "messages": []}, headers=bearer(d))
            await gw.post(f"/sessions/{d['session']['id']}/outcome", json={"class": klass})


async def _walk(gw, upstreams, harness: str, task: str) -> tuple[list[str], dict]:
    """The order: successive rides of one task, each striking the cell it rode (harness-gave-up) so
    the next ride pins the next cell, until the task's admission defers (`cells-exhausted`: every
    eligible cell struck). → (the pins in order, the closing admission answer)."""
    seen: list[str] = []
    answer: dict = {}
    for _ in range(len(ELIGIBLE) + 1):
        with quiet():
            a = await gw.post("/sessions", json={"stack": "platform", "role": "worker", "harness": harness, "rail": RAIL, "tier": "heavy", "task": task})
            answer = a.json()
            if answer.get("decision") != "dispatch":
                break
            path = "/anthropic/v1/messages" if harness == "claude" else PATH
            r = await gw.post(path, json={"model": M, "messages": [], "max_tokens": 8}, headers=bearer(answer))
            assert r.status_code == 200, r.text
            pin = _pins(upstreams[RAIL])[-1]
            await gw.post(f"/sessions/{answer['session']['id']}/outcome", json={"class": "harness-gave-up"})
        if pin is None:
            break
        seen.append(pin)
    return seen, answer


@pytest.mark.parametrize(("harness", "snapshot", "judged", "expected_order"), [r[1:] for r in ORDER_ROWS], ids=[r[0] for r in ORDER_ROWS])
async def test_order(gw, app, store, upstreams, policy, harness, snapshot, judged, expected_order):
    _world("upstream-ok")
    body = _seed(app, store, upstreams[RAIL], snapshot)
    if judged != NONE:
        with given(f"judged = {judged}"):
            await _judge(gw, judged)
            attach_json("the store's cell outcomes for M (clean, judged)", store.cell_outcomes(RAIL, M))
    with when(f"rides of one task, each striking the cell it rode, until the task's admission defers · {inputs(harness=harness, snapshot=snapshot, judged=judged)}"):
        seen, closing = await _walk(gw, upstreams, harness, "homelab-2741-order")
        attach_json("the pins, ride by ride, and the closing admission answer", {"pins": seen, "closing": closing})
    then_eq("expected_order", ", ".join(seen), expected_order, claim=f"order? = {expected_order}")
    if judged == NONE:
        kept, dropped = eligible([_row(d) for d in body["models"][M]["endpoints"]], policy.rails[RAIL].providers, harness)
        with then(f"the floors' verdict on the snapshot for harness {harness}: dropped {sorted(dropped)}", dropped=dropped, kept=sorted(e.slug for e in kept)):
            assert sorted(e.slug for e in kept) == sorted(expected_order.split(", "))


# -- Selection: the pin ---------------------------------------------------------------------------
PIN_ROWS = [  # description | model | cells | pin? | fallbacks?
    ("the pin is one provider with fallbacks off ⚖", "M", "all eligible", "deepinfra", "off"),
    ("a struck provider cell is left out for the task", "M", "deepinfra struck by this task", "atlas-cloud", "off"),
    ("a strike is the task's own: another task still pins the cell", "M", "deepinfra struck by another task", "deepinfra", "off"),
    ("a cooled provider cell is left out", "M", "deepinfra cooled (429, retry-after 30)", "atlas-cloud", "off"),
    ("the cooldown over, the cell is pinned again", "M", "deepinfra cooled 30 s ago", "deepinfra", "off"),
    ("no snapshot for the model: the request rides unpinned ⚖", "M′", "(no snapshot)", NONE, NO_BLOCK),
    ("every provider cooled or struck mid-session: the request rides unpinned ⚖", "M", "every eligible cell cooled", NONE, NO_BLOCK),
]


@pytest.mark.parametrize(("model", "cells", "expected_pin", "expected_fallbacks"), [r[1:] for r in PIN_ROWS], ids=[r[0] for r in PIN_ROWS])
async def test_pin(gw, app, store, upstreams, clock, model, cells, expected_pin, expected_fallbacks):
    _world("upstream-ok", note=None if model == "M" else f"{M2} has no snapshot entry")
    _seed(app, store, upstreams[RAIL])
    task = "homelab-2741-pin"
    if "struck" in cells:
        with given(f"cells = {cells}: an earlier ride of that task struck the cell (harness-gave-up)"):
            await _strike_for(gw, task if "this task" in cells else "homelab-2741-other", ["deepinfra"])
    doc = await _session(gw, model, task=task)
    with given(f"cells = {cells}"):
        with quiet():
            if cells.startswith("deepinfra cooled"):
                upstreams[RAIL].provider_behaviours["deepinfra"] = "upstream-429"
                await gw.post(PATH, json={"model": M, "messages": []}, headers=bearer(doc))  # 429 on deepinfra, failed over
                upstreams[RAIL].provider_behaviours.clear()
                if cells.endswith("30 s ago"):
                    clock.advance(30)
            elif cells == "every eligible cell cooled":
                for slug in ELIGIBLE:
                    upstreams[RAIL].provider_behaviours[slug] = "upstream-429"
                await gw.post(PATH, json={"model": M, "messages": []}, headers=bearer(doc))  # 3 cells cooled
                await gw.post(PATH, json={"model": M, "messages": []}, headers=bearer(doc))  # 2 more
                upstreams[RAIL].provider_behaviours.clear()
        attach_json("the arrangement's pins so far, and the strikes on this task and on the other",
                    {"pins": _pins(upstreams[RAIL]), task: _strikes(store, task), "homelab-2741-other": _strikes(store, "homelab-2741-other")})
    r = await _ride(gw, doc, label=inputs(model=model, cells=cells))
    body = upstreams[RAIL].calls[-1]["body"]
    block = body.get("provider")
    then_eq("expected_pin", _pin_cell(_pins(upstreams[RAIL])[-1]), expected_pin, claim=f"status {r.status_code}; pin? = {expected_pin}")
    fallbacks = NO_BLOCK if block is None else ("off" if block.get("allow_fallbacks") is False and len(block.get("order", [])) == 1 else f"{block}")
    with then(f"fallbacks? = {expected_fallbacks}; the rest of the body is the harness's",
              expected_fallbacks={"expected": expected_fallbacks, "actual": fallbacks},
              body={"expected": {"model": doc["model"], "messages": [{"role": "user", "content": "hi"}], "max_tokens": 8},
                    "actual": {k: v for k, v in body.items() if k != "provider"}}):
        assert r.status_code == 200
        assert fallbacks == expected_fallbacks
        assert {k: v for k, v in body.items() if k != "provider"} == {"model": doc["model"], "messages": [{"role": "user", "content": "hi"}], "max_tokens": 8}


# -- Selection: the representative endpoint -------------------------------------------------------
REPRESENTATIVE_ROWS = [  # description | provider | tags | representative? | out_price?
    ("a provider's service tiers are one order entry: the default tag represents ⚖", "deepinfra", "deepinfra/fp8, deepinfra/fp8/flex, deepinfra/fp8/priority",
     "deepinfra/fp8", 0.42),
]


@pytest.mark.parametrize(("provider", "tags", "expected_representative", "expected_out_price"), [r[1:] for r in REPRESENTATIVE_ROWS],
                         ids=[r[0] for r in REPRESENTATIVE_ROWS])
async def test_representative(app, store, upstreams, provider, tags, expected_representative, expected_out_price):
    _world("upstream-ok", note="the snapshot read directly")
    body = _seed(app, store, upstreams[RAIL])
    eps = [_row(d) for d in body["models"][M]["endpoints"]]
    with when(f"representatives() over the snapshot's rows · {inputs(provider=provider, tags=tags)}"):
        reps = representatives(eps)
        check("the provider's tags in the snapshot", ", ".join(sorted(e.tag for e in eps if e.slug == provider)), tags)
    then_eq("expected_representative", reps[provider].tag, expected_representative, claim=f"representative? = {expected_representative} (service_tier {reps[provider].service_tier})")
    then_eq("expected_out_price", reps[provider].out_price, expected_out_price, claim=f"out_price? = {expected_out_price}")


# -- Failover: before the first byte ---------------------------------------------------------------
FAILOVER_ROWS = [  # description | providers | attempts? | status? | served_by? | strikes? | failovers?
    ("fails over once", "deepinfra: upstream-500", "deepinfra, atlas-cloud", 200, "AtlasCloud", "provider-5xx @ deepinfra", "deepinfra→atlas-cloud 1"),
    ("fails over twice", "deepinfra: upstream-500; atlas-cloud: upstream-html", "deepinfra, atlas-cloud, morph", 200, "Morph",
     "provider-5xx @ deepinfra, provider-5xx @ atlas-cloud", "deepinfra→atlas-cloud 1, atlas-cloud→morph 1"),
    ("exhausts the order: the last answer is the typed error, bounded by max_providers_per_request 3 ⚖",
     "deepinfra: upstream-500; atlas-cloud: upstream-500; morph: upstream-500", "deepinfra, atlas-cloud, morph", 500, "Morph",
     "provider-5xx @ deepinfra, provider-5xx @ atlas-cloud, provider-5xx @ morph", "deepinfra→atlas-cloud 1, atlas-cloud→morph 1"),
    ("a 429 fails over and cools only that provider's cell ⚖", "deepinfra: upstream-429", "deepinfra, atlas-cloud", 200, "AtlasCloud", NONE, "deepinfra→atlas-cloud 1"),
    ("a provider's own refusal (a 4xx naming it) fails over ⚖", "deepinfra: upstream-provider-400", "deepinfra, atlas-cloud", 200, "AtlasCloud",
     "refused @ deepinfra", "deepinfra→atlas-cloud 1"),
    ("a 2xx the dialect cannot read is a pre-byte failure ⚖", "deepinfra: upstream-html", "deepinfra, atlas-cloud", 200, "AtlasCloud",
     "provider-5xx @ deepinfra", "deepinfra→atlas-cloud 1"),
]


def _behaviours(providers: str) -> dict[str, str]:
    return dict(parse_pairs(providers))


@pytest.mark.parametrize(("providers", "expected_attempts", "expected_status", "expected_served_by", "expected_strikes", "expected_failovers"),
                         [r[1:] for r in FAILOVER_ROWS], ids=[r[0] for r in FAILOVER_ROWS])
async def test_failover(gw, app, store, upstreams, providers, expected_attempts, expected_status, expected_served_by, expected_strikes, expected_failovers):
    _world("upstream-ok", note=f"providers {providers}")
    _seed(app, store, upstreams[RAIL])
    upstreams[RAIL].provider_behaviours.update(_behaviours(providers))
    task = "homelab-2741-failover"
    doc = await _session(gw, task=task)
    with when(f"POST {PATH} model {M} — the gateway tries the providers in order · {inputs(providers=providers)}"):
        with quiet():  # the per-attempt exchanges fold into ONE attachment (ATTACH_BULK: ≤ 8 per case)
            r = await gw.post(PATH, json={"model": M, "messages": [{"role": "user", "content": "hi"}], "max_tokens": 8}, headers=bearer(doc))
        attach_json("the attempts and the harness's answer", {
            "attempts": [{"pin": pin, "behaviour": _behaviours(providers).get(pin, "upstream-ok")} for pin in _pins(upstreams[RAIL])],
            "answer": {"status": r.status_code, "content_type": r.headers.get("content-type"),
                       "body": r.json() if "json" in (r.headers.get("content-type") or "") else r.text[:200]}})
    attempts = ", ".join(p or NONE for p in _pins(upstreams[RAIL]))
    with then(f"attempts? = {expected_attempts}; status? = {expected_status}; served_by? = {expected_served_by}; one request row per attempt",
              expected_attempts={"expected": expected_attempts, "actual": attempts}, expected_status={"expected": expected_status, "actual": r.status_code},
              expected_served_by={"expected": expected_served_by, "actual": _named_provider(r)}, request_rows={"actual": _row_provider(store, doc)}):
        assert attempts == expected_attempts and r.status_code == expected_status and _named_provider(r) == expected_served_by
        assert ", ".join(_row_provider(store, doc)) == expected_attempts
    then_eq("expected_strikes", _strikes(store, task), expected_strikes, claim=f"strikes? = {expected_strikes}")
    then_eq("expected_failovers", _failovers(await _metrics(gw), _pins(upstreams[RAIL])), expected_failovers, claim=f"failovers? = {expected_failovers} (gateway_provider_failovers_total{{model=M}})")


# -- Failover: a cooled cell does not block the model ----------------------------------------------
COOLED_ROWS = [  # description | providers | cells_cooled? | decision? | model?
    ("the cooled provider's model still admits ⚖", "deepinfra: upstream-429", 1, "dispatch", "M"),
]


@pytest.mark.parametrize(("providers", "expected_cells_cooled", "expected_decision", "expected_model"), [r[1:] for r in COOLED_ROWS], ids=[r[0] for r in COOLED_ROWS])
async def test_cooled_cell_still_admits(gw, app, store, upstreams, providers, expected_cells_cooled, expected_decision, expected_model):
    _world("upstream-ok", note=f"providers {providers}")
    _seed(app, store, upstreams[RAIL])
    upstreams[RAIL].provider_behaviours.update(_behaviours(providers))
    doc = await _session(gw)
    with given(f"a ride whose deepinfra attempt answered 429 and failed over (providers = {providers})"):
        with quiet():
            r = await gw.post(PATH, json={"model": M, "messages": []}, headers=bearer(doc))
        attach_json("the ride", {"status": r.status_code, "pins": _pins(upstreams[RAIL])})
    with when(f"POST /sessions worker, rail openrouter, tier heavy — the model whose deepinfra cell is cooled · {inputs(providers=providers)}"):
        a = await gw.post("/sessions", json={"stack": "platform", "role": "worker", "task": "homelab-2741-admit", "rail": RAIL, "tier": "heavy", "harness": "opencode"})
    m = re.search(r'^gateway_cells_cooled\{rail="openrouter"\} (\S+)$', await _metrics(gw), re.M)
    then_eq("expected_cells_cooled", int(float(m.group(1))) if m else 0, expected_cells_cooled, claim=f"cells_cooled? = {expected_cells_cooled} (gateway_cells_cooled{{rail=openrouter}})")
    then_eq("expected_decision", a.json()["decision"], expected_decision, claim=f"decision? = {expected_decision}")
    then_eq("expected_model", SYMBOL.get(a.json().get("model"), a.json().get("model")), expected_model, claim=f"model? = {expected_model}")


# -- Failover: after the first byte, never --------------------------------------------------------
POSTBYTE_ROWS = [  # description | providers | attempts? | incomplete? | strikes? | failovers?
    ("a post-byte failure never fails over", "deepinfra: upstream-stream-truncated", "deepinfra", "no-terminal", "stream-incomplete @ deepinfra", NONE),
]


@pytest.mark.parametrize(("providers", "expected_attempts", "expected_incomplete", "expected_strikes", "expected_failovers"), [r[1:] for r in POSTBYTE_ROWS],
                         ids=[r[0] for r in POSTBYTE_ROWS])
async def test_post_byte_never_fails_over(gw, app, store, upstreams, providers, expected_attempts, expected_incomplete, expected_strikes, expected_failovers):
    _world("upstream-ok", note=f"providers {providers}")
    _seed(app, store, upstreams[RAIL])
    upstreams[RAIL].provider_behaviours.update(_behaviours(providers))
    task = "homelab-2741-postbyte"
    doc = await _session(gw, task=task)
    r = await _ride(gw, doc, stream=True, label=inputs(providers=providers))
    row = store.requests_for(doc["session"]["id"])[-1]
    attempts = ", ".join(p or NONE for p in _pins(upstreams[RAIL]))
    with then(f"status 200; attempts? = {expected_attempts}; incomplete? = {expected_incomplete} (the request row's)",
              status={"expected": 200, "actual": r.status_code}, expected_attempts={"expected": expected_attempts, "actual": attempts},
              expected_incomplete={"expected": expected_incomplete, "actual": row["incomplete"] or NONE}):
        assert r.status_code == 200 and attempts == expected_attempts and (row["incomplete"] or NONE) == expected_incomplete
    then_eq("expected_strikes", _strikes(store, task), expected_strikes, claim=f"strikes? = {expected_strikes}")
    then_eq("expected_failovers", _failovers(await _metrics(gw), _pins(upstreams[RAIL])), expected_failovers, claim=f"failovers? = {expected_failovers}")
