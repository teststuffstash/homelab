"""GW-METRICS — the gateway_* families and their bounded labels (specs/endpoints/metrics.md).

| description | event (world policy-default, upstream-ok) | series | value |
|---|---|---|---|
| a dispatch raises the active gauge | worker dispatched on opencode | gateway_sessions_active{rail="opencode"} | 1 |
| a release lowers it | ...then released | gateway_sessions_active{rail="opencode"} | 0 |
| a dispatch is counted with its identity | worker dispatched on opencode | gateway_sessions_total{rail="opencode",role="worker",stack="platform",decision="dispatch"} | 1 |
| a defer is counted with no rail | worker deferred (rail-capacity) | gateway_sessions_total{rail="none",role="worker",stack="platform",decision="defer"} | 1 |
| a served request is counted by status | one openai-dialect call on opencode | gateway_requests_total{rail="opencode",dialect="openai",status="200"} | 1 |
| a refused request is counted by its status | an expired token on /anthropic/v1/messages | gateway_requests_total{rail="none",dialect="anthropic",status="401"} | 1 |
| an upstream 429 keeps its status | upstream-429 on openrouter | gateway_requests_total{rail="openrouter",dialect="openai",status="429"} | 1 |
| upstream time is observed per rail | one call on anthropic | gateway_upstream_seconds_count{rail="anthropic"} | 1 |
| tokens are counted by direction | upstream-ok answers usage {input_tokens: 11, output_tokens: 5} on anthropic | gateway_tokens_total{rail="anthropic",direction="in"} / "out" | 11 / 5 |
| a resolution verdict is counted | the anthropic ref is a definitive miss | gateway_credential_resolve_total{rail="anthropic",outcome="definitive"} | 1 |

| description | the series | label | allowed values |
|---|---|---|---|
| rail is the rail enum plus none | any | rail | anthropic, opencode, openrouter, none |
| role is the role enum | sessions_total | role | the seven roles |
| stack is a policy key | sessions_total | stack | the keys of policy.stacks (an unknown stack renders as other) |
| decision is the answer enum | sessions_total | decision | dispatch, defer |
| dialect is the two paths | requests_total | dialect | anthropic, openai |
| status is a numeric HTTP status | requests_total | status | ^[1-5][0-9][0-9]$ |
| direction is in or out | tokens_total | direction | in, out |
| outcome is the verdict class | credential_resolve_total | outcome | resolved, definitive, transient |
| no task label, ever | any | — | no label named task, session, id, model, token; no task key / session id / token / model string in the text |
| every family is declared with HELP and TYPE | — | — | 6 families |
"""

from __future__ import annotations

import re

import pytest

from .conftest import bearer, open_session, rule

pytestmark = rule("GW-METRICS")

FAMILIES = (
    "gateway_sessions_active", "gateway_sessions_total", "gateway_requests_total",
    "gateway_upstream_seconds", "gateway_tokens_total", "gateway_credential_resolve_total",
)


def _value(text: str, series: str) -> float | None:
    m = re.search(r"^" + re.escape(series) + r" (\S+)$", text, re.M)
    return float(m.group(1)) if m else None


async def _metrics(gw) -> str:
    return (await gw.get("/metrics")).text


async def test_dispatch_raises_gauge(gw):
    """row: a dispatch raises the active gauge"""
    await open_session(gw)
    assert _value(await _metrics(gw), 'gateway_sessions_active{rail="opencode"}') == 1


async def test_release_lowers_gauge(gw):
    """row: a release lowers it"""
    doc = await open_session(gw)
    await gw.delete(f"/sessions/{doc['session']['id']}")
    assert _value(await _metrics(gw), 'gateway_sessions_active{rail="opencode"}') == 0


async def test_dispatch_counted_with_identity(gw):
    """row: a dispatch is counted with its identity"""
    await open_session(gw)
    assert _value(await _metrics(gw), 'gateway_sessions_total{rail="opencode",role="worker",stack="platform",decision="dispatch"}') == 1


async def test_defer_counted_with_no_rail(gw, policy):
    """row: a defer is counted with no rail"""
    for rail in ("opencode", "openrouter"):
        for i in range(policy.rails[rail].max_sessions):
            await open_session(gw, task=f"{rail}-{i}", rail=rail)
    r = await gw.post("/sessions", json={"stack": "platform", "role": "worker", "task": "t"})
    assert r.json()["reason"] == "rail-capacity"
    assert _value(await _metrics(gw), 'gateway_sessions_total{rail="none",role="worker",stack="platform",decision="defer"}') == 1


async def test_served_request_counted(gw):
    """row: a served request is counted by status"""
    doc = await open_session(gw)
    assert (await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))).status_code == 200
    assert _value(await _metrics(gw), 'gateway_requests_total{rail="opencode",dialect="openai",status="200"}') == 1


async def test_refused_request_counted(gw, policy, clock):
    """row: a refused request is counted by its status"""
    doc = await open_session(gw, role="reviewer", harness="claude")
    clock.advance(policy.session_ttl_s + 1)
    assert (await gw.post("/anthropic/v1/messages", json={"messages": []}, headers=bearer(doc))).status_code == 401
    assert _value(await _metrics(gw), 'gateway_requests_total{rail="none",dialect="anthropic",status="401"}') == 1


async def test_429_keeps_status(gw, upstreams):
    """row: an upstream 429 keeps its status"""
    upstreams["openrouter"].behaviour = "upstream-429"
    doc = await open_session(gw, harness="goose", rail="openrouter")
    assert (await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))).status_code == 429
    assert _value(await _metrics(gw), 'gateway_requests_total{rail="openrouter",dialect="openai",status="429"}') == 1


async def test_upstream_time_per_rail(gw):
    """row: upstream time is observed per rail"""
    doc = await open_session(gw, role="reviewer", harness="claude")
    assert (await gw.post("/anthropic/v1/messages", json={"messages": []}, headers=bearer(doc))).status_code == 200
    text = await _metrics(gw)
    assert _value(text, 'gateway_upstream_seconds_count{rail="anthropic"}') == 1
    assert _value(text, 'gateway_upstream_seconds_bucket{rail="anthropic",le="+Inf"}') == 1
    assert re.search(r'^gateway_upstream_seconds_sum\{rail="anthropic"\} \d', text, re.M)


async def test_tokens_by_direction(gw):
    """row: tokens are counted by direction"""
    doc = await open_session(gw, role="reviewer", harness="claude")
    assert (await gw.post("/anthropic/v1/messages", json={"messages": []}, headers=bearer(doc))).status_code == 200
    text = await _metrics(gw)
    assert _value(text, 'gateway_tokens_total{rail="anthropic",direction="in"}') == 11
    assert _value(text, 'gateway_tokens_total{rail="anthropic",direction="out"}') == 5


async def test_resolution_verdict_counted(gw, app, secrets):
    """row: a resolution verdict is counted"""
    secrets.secrets.pop("platform-agents/claude-session")
    app.state.resolver.forget()
    r = await gw.post("/sessions", json={"stack": "platform", "role": "prober", "task": "t"})
    assert r.json()["reason"] == "credential-unresolved"
    assert _value(await _metrics(gw), 'gateway_credential_resolve_total{rail="anthropic",outcome="definitive"}') == 1


LABEL_RE = re.compile(r'^(gateway_[a-z_]+)\{([^}]*)\} ')


async def _series(gw) -> list[tuple[str, dict[str, str]]]:
    out = []
    for line in (await _metrics(gw)).splitlines():
        m = LABEL_RE.match(line)
        if m:
            out.append((m.group(1), dict(kv.split("=", 1) for kv in m.group(2).split(","))))
    return [(fam, {k: v.strip('"') for k, v in labels.items()}) for fam, labels in out]


async def _exercise(gw, app, secrets, upstreams, policy, clock):
    """Drive every family, including an unknown stack and a refused request."""
    doc = await open_session(gw, task="homelab-2588-r1")
    await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))
    await gw.post("/sessions", json={"stack": "nope", "role": "worker", "task": "t"})
    await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers={"authorization": "Bearer gws_" + "x" * 32})
    secrets.transient.add("platform-agents/claude-session")
    app.state.resolver.forget()
    await gw.post("/sessions", json={"stack": "platform", "role": "prober", "task": "t"})
    return doc


LABEL_ROWS = [
    ("rail is the rail enum plus none", None, "rail", {"anthropic", "opencode", "openrouter", "none"}),
    ("role is the role enum", "gateway_sessions_total", "role", {"worker", "reviewer", "coordinator", "responder", "retro", "prober", "researcher"}),
    ("stack is a policy key", "gateway_sessions_total", "stack", {"platform", "oracle", "other"}),
    ("decision is the answer enum", "gateway_sessions_total", "decision", {"dispatch", "defer"}),
    ("dialect is the two paths", "gateway_requests_total", "dialect", {"anthropic", "openai"}),
    ("status is a numeric HTTP status", "gateway_requests_total", "status", None),
    ("direction is in or out", "gateway_tokens_total", "direction", {"in", "out"}),
    ("outcome is the verdict class", "gateway_credential_resolve_total", "outcome", {"resolved", "definitive", "transient"}),
]


@pytest.mark.parametrize(("family", "label", "allowed"), [r[1:] for r in LABEL_ROWS], ids=[r[0] for r in LABEL_ROWS])
async def test_bounded_labels(gw, app, secrets, upstreams, policy, clock, family, label, allowed):
    await _exercise(gw, app, secrets, upstreams, policy, clock)
    seen = {labels[label] for fam, labels in await _series(gw) if (family is None or fam == family) and label in labels}
    assert seen, (family, label)
    if allowed is None:
        assert all(re.fullmatch(r"[1-5][0-9][0-9]", v) for v in seen), seen
    else:
        assert seen <= allowed, seen - allowed


async def test_no_task_label_ever(gw, app, secrets, upstreams, policy, clock):
    """row: no task label, ever"""
    doc = await _exercise(gw, app, secrets, upstreams, policy, clock)
    text = await _metrics(gw)
    for fam, labels in await _series(gw):
        assert not ({"task", "session", "id", "model", "token"} & set(labels)), (fam, labels)
    for needle in ("homelab-2588-r1", doc["session"]["id"], doc["session"]["token"], doc["model"], "nope"):
        assert needle not in text, needle


async def test_families_declared(gw):
    """row: every family is declared with HELP and TYPE"""
    text = await _metrics(gw)
    for fam in FAMILIES:
        assert f"# HELP {fam} " in text and f"# TYPE {fam} " in text, fam
