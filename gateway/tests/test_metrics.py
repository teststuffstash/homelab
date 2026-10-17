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
| tokens are counted by class | upstream-ok-cached answers usage {input_tokens: 12, cache_read_input_tokens: 300, cache_creation_input_tokens: 40, output_tokens: 7} on anthropic | gateway_tokens_total{rail="anthropic",class="in"} / "cache_read" / "cache_write" / "out" | 12 / 300 / 40 / 7 |
| the subscription windows are read | one call on anthropic, answered with anthropic-ratelimit-unified-{5h,7d}-{utilization,reset} | gateway_subscription_utilization{rail="anthropic",window="5h"} / "7d"; gateway_subscription_reset_seconds{…} | 0.13 / 0.67; 1792172400 / 1792274400 |
| an upstream auth rejection is counted apart | upstream-401 on opencode | gateway_upstream_auth_rejected_total{rail="opencode"} / gateway_requests_total{rail="opencode",dialect="openai",status="424"} | 1 / 1 |
| an unreachable upstream is not an auth rejection | upstream-down on opencode | gateway_upstream_auth_rejected_total{rail="opencode"} / gateway_requests_total{rail="opencode",dialect="openai",status="502"} | 0 / 1 |
| every rail's rejection count renders from 0 | no request yet | gateway_upstream_auth_rejected_total{rail=…} for anthropic, openrouter, opencode, codex | 0 each |
| a resolution verdict is counted | the anthropic ref is a definitive miss | gateway_credential_resolve_total{rail="anthropic",outcome="definitive"} | 1 |
| a cooled cell is counted on its rail | upstream-429 on openrouter | gateway_cells_cooled{rail="openrouter"} | 1 |
| a rejected credential is counted on its rail | upstream-401 on openrouter | gateway_credentials_rejected{rail="openrouter"} | 1 |
| an incomplete stream is counted by reason | upstream-stream-truncated on opencode (stream: true) | gateway_requests_incomplete_total{rail="opencode",dialect="openai",reason="no-terminal"} | 1 |
| the transport-fact gauges render every rail from 0 | no request yet | gateway_cells_cooled{rail=…} / gateway_credentials_rejected{rail=…} for anthropic, openrouter, opencode, codex | 0 each |

| description | the series | label | allowed values |
|---|---|---|---|
| rail is the rail enum plus none | any | rail | anthropic, opencode, openrouter, codex, none |
| role is the role enum | sessions_total | role | the seven roles |
| stack is a policy key | sessions_total | stack | the keys of policy.stacks (an unknown stack renders as other) |
| decision is the answer enum | sessions_total | decision | dispatch, defer |
| dialect is the three paths | requests_total | dialect | anthropic, openai, responses |
| status is a numeric HTTP status | requests_total | status | ^[1-5][0-9][0-9]$ |
| class is one of the four usage classes | tokens_total | class | in, cache_read, cache_write, out |
| window is 5h or 7d | subscription_utilization | window | 5h, 7d |
| outcome is the verdict class | credential_resolve_total | outcome | resolved, definitive, transient |
| route is the control-plane route | control_plane_unauthenticated_total | route | admit, lookup, release |
| reason is why no caller identity was read | control_plane_unauthenticated_total | reason | absent, invalid, review-transient |
| reason is why a 2xx body stopped before its end | requests_incomplete_total | reason | no-terminal, timeout, transport-error, client-closed |
| no task label, ever | any | — | no label named task, session, id, model, token; no task key / session id / token / model string in the text |
| every family is declared with HELP and TYPE | — | — | 13 families |
"""

from __future__ import annotations

import re

import pytest

from .conftest import attach_json, bearer, check, given, open_session, quiet, rule, then, then_eq, when, world

pytestmark = rule("GW-METRICS")

FAMILIES = (
    "gateway_sessions_active", "gateway_sessions_total", "gateway_requests_total",
    "gateway_upstream_seconds", "gateway_tokens_total", "gateway_credential_resolve_total",
    "gateway_subscription_utilization", "gateway_subscription_reset_seconds",
    "gateway_control_plane_unauthenticated_total", "gateway_upstream_auth_rejected_total",
    "gateway_cells_cooled", "gateway_credentials_rejected", "gateway_requests_incomplete_total",
)


def _value(text: str, series: str) -> float | None:
    m = re.search(r"^" + re.escape(series) + r" (\S+)$", text, re.M)
    return float(m.group(1)) if m else None


async def _metrics(gw) -> str:
    """The exposition, read quietly — a verdict attaches the sample lines it judged instead."""
    with quiet():
        return (await gw.get("/metrics")).text


def _lines(text: str, prefix: str) -> list[str]:
    return [line for line in text.splitlines() if line.startswith(prefix)]


async def _then_series(gw, series: str, expected: float) -> None:
    """Then: <series> = <value>, read from GET /metrics inside the step."""
    with then(f"series {series} = {expected:g}"):
        text = await _metrics(gw)
        attach_json(f"sample: {series.split('{')[0]} lines", _lines(text, series.split("{")[0]))
        check(series, _value(text, series), expected)


async def test_dispatch_raises_gauge(gw):
    """row: a dispatch raises the active gauge"""
    world(upstream="upstream-ok")
    with when("event: worker dispatched on opencode (POST /sessions)"):
        await open_session(gw)
    await _then_series(gw, 'gateway_sessions_active{rail="opencode"}', 1)


async def test_release_lowers_gauge(gw):
    """row: a release lowers it"""
    world(upstream="upstream-ok")
    with given("a worker session dispatched on opencode"):
        doc = await open_session(gw)
    with when(f"event: …then released (DELETE /sessions/{doc['session']['id']})"):
        await gw.delete(f"/sessions/{doc['session']['id']}")
    await _then_series(gw, 'gateway_sessions_active{rail="opencode"}', 0)


async def test_dispatch_counted_with_identity(gw):
    """row: a dispatch is counted with its identity"""
    world(upstream="upstream-ok")
    with when("event: worker dispatched on opencode (POST /sessions, stack platform)"):
        await open_session(gw)
    await _then_series(gw, 'gateway_sessions_total{rail="opencode",role="worker",stack="platform",decision="dispatch"}', 1)


async def test_defer_counted_with_no_rail(gw, policy):
    """row: a defer is counted with no rail"""
    world(upstream="upstream-ok")
    caps = {rail: policy.rails[rail].max_sessions for rail in ("opencode", "openrouter")}
    with given(f"every worker rail is full: {caps}"):
        with quiet():
            for rail in ("opencode", "openrouter"):
                for i in range(policy.rails[rail].max_sessions):
                    await open_session(gw, task=f"{rail}-{i}", rail=rail)
        attach_json(f"filled: {caps}", caps)
    with when("event: worker deferred (POST /sessions, every rail full)"):
        r = await gw.post("/sessions", json={"stack": "platform", "role": "worker", "task": "t"})
    then_eq("reason", r.json()["reason"], "rail-capacity")
    await _then_series(gw, 'gateway_sessions_total{rail="none",role="worker",stack="platform",decision="defer"}', 1)


async def test_served_request_counted(gw):
    """row: a served request is counted by status"""
    world(upstream="upstream-ok")
    with given("a worker session on opencode"):
        doc = await open_session(gw)
    with when("event: one openai-dialect call on opencode (POST /openai/v1/chat/completions)"):
        r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))
    then_eq("status", r.status_code, 200)
    await _then_series(gw, 'gateway_requests_total{rail="opencode",dialect="openai",status="200"}', 1)


async def test_refused_request_counted(gw, policy, clock):
    """row: a refused request is counted by its status"""
    world(upstream="upstream-ok")
    with given(f"a reviewer session on anthropic, expired (clock +{policy.session_ttl_s + 1} s)"):
        doc = await open_session(gw, role="reviewer", harness="claude")
        clock.advance(policy.session_ttl_s + 1)
    with when("event: an expired token on /anthropic/v1/messages"):
        r = await gw.post("/anthropic/v1/messages", json={"messages": []}, headers=bearer(doc))
    then_eq("status", r.status_code, 401)
    await _then_series(gw, 'gateway_requests_total{rail="none",dialect="anthropic",status="401"}', 1)


async def test_429_keeps_status(gw, upstreams):
    """row: an upstream 429 keeps its status"""
    world(upstream="upstream-429")
    upstreams["openrouter"].behaviour = "upstream-429"
    with given("a worker session on openrouter (harness goose)"):
        doc = await open_session(gw, harness="goose", rail="openrouter")
    with when("event: upstream-429 on openrouter (POST /openai/v1/chat/completions)"):
        r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))
    then_eq("status", r.status_code, 429)
    await _then_series(gw, 'gateway_requests_total{rail="openrouter",dialect="openai",status="429"}', 1)


async def test_upstream_time_per_rail(gw):
    """row: upstream time is observed per rail"""
    world(upstream="upstream-ok")
    with given("a reviewer session on anthropic"):
        doc = await open_session(gw, role="reviewer", harness="claude")
    with when("event: one call on anthropic (POST /anthropic/v1/messages)"):
        r = await gw.post("/anthropic/v1/messages", json={"messages": []}, headers=bearer(doc))
    then_eq("status", r.status_code, 200)
    with then('series gateway_upstream_seconds{rail="anthropic"}: count 1, +Inf bucket 1, a sum'):
        text = await _metrics(gw)
        attach_json("sample: gateway_upstream_seconds lines", [line for line in _lines(text, "gateway_upstream_seconds") if 'rail="anthropic"' in line and ("_count" in line or "_sum" in line or "+Inf" in line)])
        check('gateway_upstream_seconds_count{rail="anthropic"}', _value(text, 'gateway_upstream_seconds_count{rail="anthropic"}'), 1)
        check('gateway_upstream_seconds_bucket{rail="anthropic",le="+Inf"}', _value(text, 'gateway_upstream_seconds_bucket{rail="anthropic",le="+Inf"}'), 1)
        assert re.search(r'^gateway_upstream_seconds_sum\{rail="anthropic"\} \d', text, re.M)


async def test_tokens_by_class(gw, upstreams):
    """row: tokens are counted by class"""
    world(upstream="upstream-ok-cached")
    upstreams["anthropic"].behaviour = "upstream-ok-cached"
    with given("a reviewer session on anthropic"):
        doc = await open_session(gw, role="reviewer", harness="claude")
    with when("event: upstream-ok-cached answers usage {input_tokens: 12, cache_read_input_tokens: 300, cache_creation_input_tokens: 40, output_tokens: 7} on anthropic"):
        r = await gw.post("/anthropic/v1/messages", json={"messages": []}, headers=bearer(doc))
    then_eq("status", r.status_code, 200)
    with then('series gateway_tokens_total{rail="anthropic",class="in"} / "cache_read" / "cache_write" / "out" = 12 / 300 / 40 / 7'):
        text = await _metrics(gw)
        attach_json("sample: gateway_tokens_total lines", _lines(text, "gateway_tokens_total"))
        got = {cls: _value(text, f'gateway_tokens_total{{rail="anthropic",class="{cls}"}}') for cls in ("in", "cache_read", "cache_write", "out")}
        check("gateway_tokens_total{rail=anthropic} by class", got, {"in": 12, "cache_read": 300, "cache_write": 40, "out": 7})


async def test_subscription_windows_read(gw):
    """row: the subscription windows are read"""
    world(upstream="upstream-ok")
    with given("a reviewer session on anthropic"):
        doc = await open_session(gw, role="reviewer", harness="claude")
    with when("event: one call on anthropic, answered with anthropic-ratelimit-unified-{5h,7d}-{utilization,reset}"):
        r = await gw.post("/anthropic/v1/messages", json={"messages": []}, headers=bearer(doc))
    then_eq("status", r.status_code, 200)
    with then("gateway_subscription_utilization 5h / 7d = 0.13 / 0.67; gateway_subscription_reset_seconds = 1792172400 / 1792274400"):
        text = await _metrics(gw)
        attach_json("sample: gateway_subscription_* lines", _lines(text, "gateway_subscription"))
        got = {f"{fam} {w}": _value(text, f'gateway_subscription_{fam}{{rail="anthropic",window="{w}"}}')
               for fam in ("utilization", "reset_seconds") for w in ("5h", "7d")}
        check("gateway_subscription_*{rail=anthropic}", got, {"utilization 5h": 0.13, "utilization 7d": 0.67,
                                                             "reset_seconds 5h": 1792172400, "reset_seconds 7d": 1792274400})


async def test_upstream_auth_counted_apart(gw, upstreams):
    """row: an upstream auth rejection is counted apart"""
    world(upstream="upstream-401")
    upstreams["opencode"].behaviour = "upstream-401"
    with given("a worker session on opencode"):
        doc = await open_session(gw)
    with when("event: upstream-401 on opencode (POST /openai/v1/chat/completions)"):
        r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))
    then_eq("status", r.status_code, 424)
    await _then_series(gw, 'gateway_upstream_auth_rejected_total{rail="opencode"}', 1)
    await _then_series(gw, 'gateway_requests_total{rail="opencode",dialect="openai",status="424"}', 1)


async def test_unreachable_not_auth(gw, transport):
    """row: an unreachable upstream is not an auth rejection"""
    world(upstream="upstream-down")
    transport.unreachable.add("opencode")
    with given("a worker session on opencode"):
        doc = await open_session(gw)
    with when("event: upstream-down on opencode (POST /openai/v1/chat/completions)"):
        r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))
    then_eq("status", r.status_code, 502)
    await _then_series(gw, 'gateway_upstream_auth_rejected_total{rail="opencode"}', 0)
    await _then_series(gw, 'gateway_requests_total{rail="opencode",dialect="openai",status="502"}', 1)


async def test_rejections_render_from_zero(gw):
    """row: every rail's rejection count renders from 0"""
    world()
    with when("GET /metrics before any request"):
        text = await _metrics(gw)
        attach_json("sample: gateway_upstream_auth_rejected_total lines", _lines(text, "gateway_upstream_auth_rejected_total"))
    with then("gateway_upstream_auth_rejected_total{rail=…} = 0 for anthropic, openrouter, opencode, codex"):
        got = {rail: _value(text, f'gateway_upstream_auth_rejected_total{{rail="{rail}"}}') for rail in ("anthropic", "openrouter", "opencode", "codex")}
        check("gateway_upstream_auth_rejected_total by rail", got, {"anthropic": 0, "openrouter": 0, "opencode": 0, "codex": 0})


async def test_resolution_verdict_counted(gw, app, secrets):
    """row: a resolution verdict is counted"""
    world(upstream="upstream-ok")
    with given("state: the anthropic ref platform-agents/claude-session is a definitive miss"):
        secrets.secrets.pop("platform-agents/claude-session")
        app.state.resolver.forget()
        attach_json("secrets after: platform-agents/claude-session removed", sorted(secrets.secrets))
    with when("event: a prober asks POST /sessions (its only rail is anthropic)"):
        r = await gw.post("/sessions", json={"stack": "platform", "role": "prober", "task": "t"})
    then_eq("reason", r.json()["reason"], "credential-unresolved")
    await _then_series(gw, 'gateway_credential_resolve_total{rail="anthropic",outcome="definitive"}', 1)


LABEL_RE = re.compile(r'^(gateway_[a-z_]+)\{([^}]*)\} ')


FACT_ROWS = [
    ("a cooled cell is counted on its rail", "openrouter", "upstream-429", False, 'gateway_cells_cooled{rail="openrouter"}'),
    ("a rejected credential is counted on its rail", "openrouter", "upstream-401", False, 'gateway_credentials_rejected{rail="openrouter"}'),
    ("an incomplete stream is counted by reason", "opencode", "upstream-stream-truncated", True,
     'gateway_requests_incomplete_total{rail="opencode",dialect="openai",reason="no-terminal"}'),
]


@pytest.mark.parametrize(("rail", "behaviour", "stream", "series"), [r[1:] for r in FACT_ROWS], ids=[r[0] for r in FACT_ROWS])
async def test_transport_facts(gw, upstreams, rail, behaviour, stream, series):
    world(upstream=behaviour)
    upstreams[rail].behaviour = behaviour
    with given(f"a worker session on {rail} (harness goose)"):
        doc = await open_session(gw, harness="goose", rail=rail)
    with when(f"event: {behaviour} on {rail} (POST /openai/v1/chat/completions{', stream: true' if stream else ''})"):
        await gw.post("/openai/v1/chat/completions", json={"messages": [], **({"stream": True} if stream else {})}, headers=bearer(doc))
    await _then_series(gw, series, 1)


async def test_fact_gauges_from_zero(gw):
    """row: the transport-fact gauges render every rail from 0"""
    world()
    with when("GET /metrics before any request"):
        text = await _metrics(gw)
        attach_json("sample: the gauge lines", _lines(text, "gateway_cells_cooled") + _lines(text, "gateway_credentials_rejected"))
    with then("gateway_cells_cooled / gateway_credentials_rejected = 0 for anthropic, openrouter, opencode, codex"):
        rails = ("anthropic", "openrouter", "opencode", "codex")
        got = {f"{fam}{{{r}}}": _value(text, f'{fam}{{rail="{r}"}}') for fam in ("gateway_cells_cooled", "gateway_credentials_rejected") for r in rails}
        check("gauges by rail", got, {k: 0 for k in got})


async def _series(gw) -> list[tuple[str, dict[str, str]]]:
    out = []
    for line in (await _metrics(gw)).splitlines():
        m = LABEL_RE.match(line)
        if m:
            out.append((m.group(1), dict(kv.split("=", 1) for kv in m.group(2).split(","))))
    return [(fam, {k: v.strip('"') for k, v in labels.items()}) for fam, labels in out]


async def _exercise(gw, app, secrets, upstreams, policy, clock):
    """Drive every family, including an unknown stack and a refused request (one given step,
    the exchanges muted — a summary attaches instead)."""
    with given("every family driven: a dispatch + a served call, an unknown stack, an unknown token, a transient credential"):
        with quiet():
            doc = await open_session(gw, task="homelab-2588-r1")
            await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))
            rev = await open_session(gw, role="reviewer", harness="claude", task="homelab-2588-review")
            await gw.post("/anthropic/v1/messages", json={"messages": []}, headers=bearer(rev))
            upstreams["opencode"].behaviour = "upstream-stream-truncated"
            await gw.post("/openai/v1/chat/completions", json={"messages": [], "stream": True}, headers=bearer(doc))
            upstreams["opencode"].behaviour = "upstream-ok"
            await gw.post("/sessions", json={"stack": "nope", "role": "worker", "task": "t"})
            await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers={"authorization": "Bearer gws_" + "x" * 32})
            secrets.transient.add("platform-agents/claude-session")
            app.state.resolver.forget()
            await gw.post("/sessions", json={"stack": "platform", "role": "prober", "task": "t"})
        attach_json("exercised: the calls", ["POST /sessions platform worker task homelab-2588-r1 → dispatch", "POST /openai/v1/chat/completions on it",
                                             "a reviewer session + POST /anthropic/v1/messages on it",
                                             "a truncated stream on the worker session (upstream-stream-truncated)",
                                             "POST /sessions stack nope", "POST /openai/v1/chat/completions with an unknown gws_ token",
                                             "POST /sessions platform prober with claude-session transient"])
    return doc


LABEL_ROWS = [
    ("rail is the rail enum plus none", None, "rail", {"anthropic", "opencode", "openrouter", "codex", "none"}),
    ("role is the role enum", "gateway_sessions_total", "role", {"worker", "reviewer", "coordinator", "responder", "retro", "prober", "researcher"}),
    ("stack is a policy key", "gateway_sessions_total", "stack", {"platform", "oracle", "other"}),
    ("decision is the answer enum", "gateway_sessions_total", "decision", {"dispatch", "defer"}),
    ("dialect is the three paths", "gateway_requests_total", "dialect", {"anthropic", "openai", "responses"}),
    ("status is a numeric HTTP status", "gateway_requests_total", "status", None),
    ("class is one of the four usage classes", "gateway_tokens_total", "class", {"in", "cache_read", "cache_write", "out"}),
    ("window is 5h or 7d", "gateway_subscription_utilization", "window", {"5h", "7d"}),
    ("outcome is the verdict class", "gateway_credential_resolve_total", "outcome", {"resolved", "definitive", "transient"}),
    ("route is the control-plane route", "gateway_control_plane_unauthenticated_total", "route", {"admit", "lookup", "release"}),
    ("reason is why no caller identity was read", "gateway_control_plane_unauthenticated_total", "reason", {"absent", "invalid", "review-transient"}),
    ("reason is why a 2xx body stopped before its end", "gateway_requests_incomplete_total", "reason",
     {"no-terminal", "timeout", "transport-error", "client-closed"}),
]


@pytest.mark.parametrize(("family", "label", "allowed"), [r[1:] for r in LABEL_ROWS], ids=[r[0] for r in LABEL_ROWS])
async def test_bounded_labels(gw, app, secrets, upstreams, policy, clock, family, label, allowed):
    world(upstream="upstream-ok")
    await _exercise(gw, app, secrets, upstreams, policy, clock)
    with when(f"GET /metrics: the values of label {label} on family {family or 'any'}"):
        seen = {labels[label] for fam, labels in await _series(gw) if (family is None or fam == family) and label in labels}
        attach_json(f"seen: {label} values", sorted(seen))
    allowed_txt = "^[1-5][0-9][0-9]$" if allowed is None else ", ".join(sorted(allowed))
    with then(f"label {label} is non-empty and allowed ⊇ seen (allowed: {allowed_txt})",
              allowed={"expected": allowed_txt if allowed is None else sorted(allowed), "actual": sorted(seen)}):
        assert seen, (family, label)
        if allowed is None:
            assert all(re.fullmatch(r"[1-5][0-9][0-9]", v) for v in seen), seen
        else:
            assert seen <= allowed, seen - allowed


async def test_no_task_label_ever(gw, app, secrets, upstreams, policy, clock):
    """row: no task label, ever"""
    world(upstream="upstream-ok")
    doc = await _exercise(gw, app, secrets, upstreams, policy, clock)
    with when("GET /metrics after every family was driven"):
        text = await _metrics(gw)
        series = await _series(gw)
        attach_json("label names seen per family", {fam: sorted({k for f, labels in series if f == fam for k in labels}) for fam in sorted({f for f, _ in series})})
    with then("no label named task, session, id, model, token"):
        for fam, labels in series:
            assert not ({"task", "session", "id", "model", "token"} & set(labels)), (fam, labels)
    needles = ("homelab-2588-r1", doc["session"]["id"], doc["session"]["token"], doc["model"], "nope")
    with then("no task key / session id / token / model / unknown stack string in the text",
              absent={"expected": "none of", "needles": ["homelab-2588-r1", "<session id>", "<token>", doc["model"], "nope"],
                      "found": [n for n in needles if n in text]}):
        for needle in needles:
            assert needle not in text, needle


async def test_families_declared(gw):
    """row: every family is declared with HELP and TYPE"""
    world()
    with when("GET /metrics"):
        text = await _metrics(gw)
        attach_json("HELP/TYPE lines", [line for line in text.splitlines() if line.startswith(("# HELP gateway_", "# TYPE gateway_"))])
    with then(f"{len(FAMILIES)} families declared with HELP and TYPE: {', '.join(FAMILIES)}"):
        for fam in FAMILIES:
            assert f"# HELP {fam} " in text and f"# TYPE {fam} " in text, fam
