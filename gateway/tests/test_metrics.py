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
| a strike is counted by class and source | a worker session reports no-verdict | gateway_strikes_total{class="no-verdict",source="outcome"} | 1 |
| a reaped session is counted on its rail | a bound opencode session whose pod is gone, one reaper pass | gateway_sessions_reaped_total{rail="opencode"} | 1 |
| a credential re-probe is counted by outcome | opencode 401 (upstream-401-key-expired), +60 s, the re-probe answered upstream-ok | gateway_credential_probes_total{rail="opencode",outcome="cleared"} | 1 |
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
| route is the control-plane route | control_plane_unauthenticated_total | route | admit, lookup, release, outcome |
| reason is why no caller identity was read | control_plane_unauthenticated_total | reason | absent, invalid, review-transient |
| class is a strike class, source the writer | strikes_total | class / source | the strike classes / outcome, gateway |
| reason is why a 2xx body stopped before its end | requests_incomplete_total | reason | no-terminal, timeout, transport-error, client-closed |
| no task label, ever | any | — | no label named task, session, id, model, token; no task key / session id / token / model string in the text |
| source is the catalog source | go_catalog_refresh_total | source | config, docs |
| the catalog outcome is the refresh outcome | go_catalog_refresh_total | outcome | ok, fetch-failed, parse-failed, implausible |
| every family is declared with HELP and TYPE | — | — | 23 families |

The provider families (GW-RAIL-OPENROUTER; world policy-default · openrouter-endpoints — the snapshot of
deepseek/deepseek-v4.1-flash, the openrouter heavy tier):

| description | event || series | value |
|---|---||---|---|
| an attempt is counted on its cell by how it ended | a ride whose deepinfra attempt answered 500, served by atlas-cloud || gateway_provider_requests_total{rail=openrouter,model=deepseek/deepseek-v4.1-flash,provider=deepinfra,outcome=5xx} / {…,provider=atlas-cloud,outcome=ok} | 1 / 1 |
| a failover is counted from and to | the same || gateway_provider_failovers_total{model=deepseek/deepseek-v4.1-flash,from=deepinfra,to=atlas-cloud} | 1 |
| an unpinned attempt that names no provider is unattributed | a ride on deepseek/deepseek-v4-flash (no snapshot entry), the answer unnamed || gateway_provider_requests_total{rail=openrouter,model=deepseek/deepseek-v4-flash,provider=unattributed,outcome=ok} | 1 |
| a provider the snapshot lacks renders as other | the same, the answer names Sail Research || gateway_provider_requests_total{…,model=deepseek/deepseek-v4-flash,provider=other,outcome=ok} | 1 |

| description | the series || label | allowed values |
|---|---||---|---|
| model is a policy openrouter id | provider_requests_total, provider_failovers_total || model | the openrouter rail's policy models (wire ids); else other |
| provider is a snapshot slug or unattributed | provider_requests_total (from, to on provider_failovers_total) || provider | the endpoint snapshot's tag-base slugs, unattributed; else other |
| reason is why the rail choice fell | rail_choice_total || reason | price, clean-rate, headroom, not-in-catalog, no-eligible-endpoint (model = a policy openrouter id, rail = the rail enum) |
"""

from __future__ import annotations

import re

import pytest

from agent_gateway.outcomes import OUTCOME_CLASSES

from .conftest import attach_json, bearer, check, given, open_session, quiet, rule, then, then_eq, when, world

pytestmark = rule("GW-METRICS")

FAMILIES = (
    "gateway_sessions_active", "gateway_sessions_total", "gateway_requests_total",
    "gateway_upstream_seconds", "gateway_tokens_total", "gateway_credential_resolve_total",
    "gateway_subscription_utilization", "gateway_subscription_reset_seconds",
    "gateway_control_plane_unauthenticated_total", "gateway_upstream_auth_rejected_total",
    "gateway_cells_cooled", "gateway_credentials_rejected", "gateway_requests_incomplete_total",
    "gateway_strikes_total",
    "gateway_credential_probes_total", "gateway_sessions_reaped_total",
    "gateway_go_catalog_age_seconds", "gateway_go_catalog_models", "gateway_go_catalog_refresh_total",
    "gateway_go_catalog_last_outcome", "gateway_go_catalog_policy_models_missing",
    "gateway_rail_choice_total", "gateway_tier_evidence_age_seconds",
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
    auth, req = 'gateway_upstream_auth_rejected_total{rail="opencode"}', 'gateway_requests_total{rail="opencode",dialect="openai",status="424"}'
    with then(f"status 424; series {auth} = 1 and {req} = 1"):
        text = await _metrics(gw)
        check("status · the two series", (r.status_code, _value(text, auth), _value(text, req)), (424, 1, 1))


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


async def test_strike_counted(gw):
    """row: a strike is counted by class and source"""
    world()
    with given("a worker session"):
        doc = await open_session(gw)
    with when("POST /sessions/{id}/outcome {class: no-verdict}"):
        await gw.post(f"/sessions/{doc['session']['id']}/outcome", json={"class": "no-verdict"})
    await _then_series(gw, 'gateway_strikes_total{class="no-verdict",source="outcome"}', 1)
async def test_reaped_counted(gw, app, reviews, pods):
    """row: a reaped session is counted on its rail"""
    from agent_gateway.liveness import PodState
    from agent_gateway.pull import POD_NAME_EXTRA, Review
    world()
    with given("a bound opencode worker session pulled by pod fixer-1, which is gone"):
        with quiet():
            doc = await open_session(gw, bind={"namespace": "platform-agents", "serviceaccount": "agentstack-worker", "pod": "fixer-1"})
            reviews.tokens["fake-projected-sa-token-metrics"] = Review(True, "system:serviceaccount:platform-agents:agentstack-worker",
                                                                       ("agent-gateway",), {POD_NAME_EXTRA: ("fixer-1",)})
            await gw.post(f"/sessions/{doc['session']['id']}/env", headers={"authorization": "Bearer fake-projected-sa-token-metrics"})
        pods.pods[("platform-agents", "fixer-1")] = PodState("gone")
    with when("one reaper pass"):
        await app.state.sessions.reap()
    await _then_series(gw, 'gateway_sessions_reaped_total{rail="opencode"}', 1)


async def test_credential_probe_counted(gw, app, upstreams, clock):
    """row: a credential re-probe is counted by outcome"""
    world(upstream="upstream-401-key-expired")
    with given("a worker session on opencode whose request was answered upstream-401-key-expired; 60 s pass"):
        with quiet():
            doc = await open_session(gw, harness="goose", rail="opencode")
            upstreams["opencode"].behaviour = "upstream-401-key-expired"
            await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))
            upstreams["opencode"].behaviour = "upstream-ok"
        clock.advance(60)
    with when("the re-probe pass runs (the probe is answered upstream-ok)"):
        sent = await app.state.proxy.reprobe()
        attach_json("the re-probe pass", {"probes sent": sent})
    await _then_series(gw, 'gateway_credential_probes_total{rail="opencode",outcome="cleared"}', 1)


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
            await gw.post(f"/sessions/{doc['session']['id']}/outcome", json={"class": "no-verdict"})
            await gw.post("/sessions", json={"stack": "nope", "role": "worker", "task": "t"})
            await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers={"authorization": "Bearer gws_" + "x" * 32})
            secrets.transient.add("platform-agents/claude-session")
            app.state.resolver.forget()
            await gw.post("/sessions", json={"stack": "platform", "role": "prober", "task": "t"})
        attach_json("exercised: the calls", ["POST /sessions platform worker task homelab-2588-r1 → dispatch", "POST /openai/v1/chat/completions on it",
                                             "a reviewer session + POST /anthropic/v1/messages on it",
                                             "a truncated stream on the worker session (upstream-stream-truncated)",
                                             "POST /sessions/{id}/outcome {class: no-verdict} on the worker session",
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
    ("route is the control-plane route", "gateway_control_plane_unauthenticated_total", "route", {"admit", "lookup", "release", "outcome"}),
    ("reason is why no caller identity was read", "gateway_control_plane_unauthenticated_total", "reason", {"absent", "invalid", "review-transient"}),
    ("class is a strike class, source the writer", "gateway_strikes_total", "class", {k for k, v in OUTCOME_CLASSES.items() if v}),
    ("reason is why a 2xx body stopped before its end", "gateway_requests_incomplete_total", "reason",
     {"no-terminal", "timeout", "transport-error", "client-closed"}),
    ("source is the catalog source", "gateway_go_catalog_refresh_total", "source", {"config", "docs"}),
    ("the catalog outcome is the refresh outcome", "gateway_go_catalog_refresh_total", "outcome", {"ok", "fetch-failed", "parse-failed", "implausible"}),
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


# -- the provider families (GW-RAIL-OPENROUTER) ---------------------------------------------------
PROVIDER_PATH = "/openai/v1/chat/completions"
OR_M = "deepseek/deepseek-v4.1-flash"
OR_M2 = "deepseek/deepseek-v4-flash"


async def _provider_sample(gw, family: str, labels: dict[str, str]) -> float | None:
    text = await _metrics(gw)
    want = family + "{" + ",".join(f'{k}="{v}"' for k, v in labels.items()) + "}"
    m = re.search("^" + re.escape(want) + r" (\S+)$", text, re.M)
    attach_json(f"sample: {want}", {"line": m.group(0) if m else None})
    return float(m.group(1)) if m else None


async def _provider_world(app, store, upstreams):
    from .conftest import seed_openrouter_endpoints

    seed_openrouter_endpoints(store, upstreams["openrouter"])
    app.state.providers.reload()


async def test_provider_attempts_counted(gw, app, store, upstreams):
    """row: an attempt is counted on its cell by how it ended"""
    world(upstream="upstream-ok", note="openrouter-endpoints; deepinfra answers 500")
    await _provider_world(app, store, upstreams)
    upstreams["openrouter"].provider_behaviours["deepinfra"] = "upstream-500"
    with given("a worker session on rail openrouter, tier heavy"):
        doc = await open_session(gw, role="worker", harness="opencode", rail="openrouter", tier="heavy")
    with when("one ride: deepinfra 500 → atlas-cloud 200"):
        r = await gw.post(PROVIDER_PATH, json={"model": OR_M, "messages": []}, headers=bearer(doc))
    then_eq("status", r.status_code, 200)
    with then("gateway_provider_requests_total{rail=openrouter,model=M,provider=deepinfra,outcome=5xx} = 1"):
        check("series", await _provider_sample(gw, "gateway_provider_requests_total", {"rail": "openrouter", "model": OR_M, "provider": "deepinfra", "outcome": "5xx"}), 1)
    with then("gateway_provider_requests_total{…,provider=atlas-cloud,outcome=ok} = 1"):
        check("series", await _provider_sample(gw, "gateway_provider_requests_total", {"rail": "openrouter", "model": OR_M, "provider": "atlas-cloud", "outcome": "ok"}), 1)
    with then("gateway_provider_failovers_total{model=M,from=deepinfra,to=atlas-cloud} = 1 (the failover row)"):
        check("series", await _provider_sample(gw, "gateway_provider_failovers_total", {"model": OR_M, "from": "deepinfra", "to": "atlas-cloud"}), 1)


async def test_provider_failover_counted(gw, app, store, upstreams):
    """row: a failover is counted from and to"""
    world(upstream="upstream-ok", note="openrouter-endpoints; deepinfra answers 500")
    await _provider_world(app, store, upstreams)
    upstreams["openrouter"].provider_behaviours["deepinfra"] = "upstream-500"
    with given("a worker session on rail openrouter, tier heavy"):
        doc = await open_session(gw, role="worker", harness="opencode", rail="openrouter", tier="heavy")
    with when("one ride: deepinfra 500 → atlas-cloud 200"):
        r = await gw.post(PROVIDER_PATH, json={"model": OR_M, "messages": []}, headers=bearer(doc))
    then_eq("status", r.status_code, 200)
    with then("gateway_provider_failovers_total{model=M,from=deepinfra,to=atlas-cloud} = 1"):
        check("series", await _provider_sample(gw, "gateway_provider_failovers_total", {"model": OR_M, "from": "deepinfra", "to": "atlas-cloud"}), 1)


async def test_cell_state_labels(gw):
    """row: state is a cell's entry state"""
    world(note="policy-default (the catalog leg declared; its families render every value from 0)")
    with when("GET /metrics"):
        rows = await _series(gw)
    then_eq("gateway_openrouter_cells{state}", sorted({labels["state"] for fam, labels in rows if fam == "gateway_openrouter_cells"}),
            ["candidate", "eligible", "excluded"])


async def test_canary_outcome_labels(gw):
    """row: a canary outcome is a verdict, an admission an answer"""
    world(note="policy-default (the catalog leg declared; its families render every value from 0)")
    with when("GET /metrics"):
        rows = await _series(gw)
    then_eq("gateway_canary_rides_total{outcome} · gateway_canary_admissions_total{outcome}",
            (sorted({labels["outcome"] for fam, labels in rows if fam == "gateway_canary_rides_total"}),
             sorted({labels["outcome"] for fam, labels in rows if fam == "gateway_canary_admissions_total"})),
            (["eligible", "excluded"], ["budget", "dispatch", "not-due", "not-in-catalog"]))


async def test_rail_choice_labels(gw, app, store, upstreams, policy):
    """row: reason is why the rail choice fell"""
    world(note="policy-default · openrouter-endpoints + the Go catalog: a worker at tier light names a twin on both rails")
    await _provider_world(app, store, upstreams)
    with given("one admission with a twin (worker, harness opencode, tier light: Go's promise price vs deepinfra's)"):
        doc = await open_session(gw, role="worker", harness="opencode", tier="light")
        attach_json("the answer's rail_choice", doc["rail_choice"])
    with when("GET /metrics: every gateway_rail_choice_total series"):
        rows = [(fam, labels) for fam, labels in await _series(gw) if fam == "gateway_rail_choice_total"]
        attach_json("series", [labels for _, labels in rows])
    or_ids = {m for lst in policy.rails["openrouter"].models.values() for m in lst}
    with then("one series; its model a policy openrouter id, its rail the chosen rail, its reason in the enum",
              series={"expected": {"model": "a policy openrouter id", "rail": doc["rail"], "reason": "one of price, clean-rate, headroom, not-in-catalog, no-eligible-endpoint"},
                      "actual": [labels for _, labels in rows]}):
        assert len(rows) == 1, rows
        labels = rows[0][1]
        assert labels["model"] in or_ids and labels["rail"] == doc["rail"]
        assert labels["reason"] in {"price", "clean-rate", "headroom", "not-in-catalog", "no-eligible-endpoint"}
        assert sorted(labels) == ["model", "rail", "reason"]


UNPINNED_ROWS = [
    ("an unpinned attempt that names no provider is unattributed", None, "unattributed"),
    ("a provider the snapshot lacks renders as other", "Sail Research", "other"),
]


@pytest.mark.parametrize(("display", "label"), [r[1:] for r in UNPINNED_ROWS], ids=[r[0] for r in UNPINNED_ROWS])
async def test_provider_label_bounds(gw, app, store, upstreams, display, label):
    world(upstream="upstream-ok", note=f"openrouter-endpoints; {OR_M2} has no entry; the answer names {display!r}")
    await _provider_world(app, store, upstreams)
    upstreams["openrouter"].provider_display = display
    with given("a worker session on rail openrouter, tier standard (unpinned)"):
        doc = await open_session(gw, role="worker", harness="opencode", rail="openrouter", tier="standard")
    with when("one ride"):
        r = await gw.post(PROVIDER_PATH, json={"model": OR_M2, "messages": []}, headers=bearer(doc))
    then_eq("status", r.status_code, 200)
    with then(f"gateway_provider_requests_total{{rail=openrouter,model={OR_M2},provider={label},outcome=ok}} = 1"):
        check("series", await _provider_sample(gw, "gateway_provider_requests_total", {"rail": "openrouter", "model": OR_M2, "provider": label, "outcome": "ok"}), 1)


async def _provider_labels(gw, app, store, upstreams) -> tuple[set[str], set[str]]:
    """One failed-over ride, then every label value the two provider families render."""
    await _provider_world(app, store, upstreams)
    upstreams["openrouter"].provider_behaviours["deepinfra"] = "upstream-500"
    with given("a worker session on rail openrouter, tier heavy; one failed-over ride (deepinfra 500 → atlas-cloud 200)"):
        doc = await open_session(gw, role="worker", harness="opencode", rail="openrouter", tier="heavy")
        await gw.post(PROVIDER_PATH, json={"model": OR_M, "messages": []}, headers=bearer(doc))
    with when("GET /metrics"):
        rows = await _series(gw)
    models = {labels["model"] for fam, labels in rows if fam in ("gateway_provider_requests_total", "gateway_provider_failovers_total")}
    providers = ({labels["provider"] for fam, labels in rows if fam == "gateway_provider_requests_total"}
                 | {labels[k] for fam, labels in rows if fam == "gateway_provider_failovers_total" for k in ("from", "to")})
    return models, providers


async def test_provider_label_models(gw, app, store, upstreams, policy):
    """row: model is a policy openrouter id"""
    world(upstream="upstream-ok", note="openrouter-endpoints")
    models, _ = await _provider_labels(gw, app, store, upstreams)
    policy_models = {m for tier in policy.rails["openrouter"].models.values() for m in tier}
    then_eq("every model label is a policy openrouter id", models <= policy_models, True, claim=f"model labels {sorted(models)} ⊆ the policy's openrouter ids")


async def test_provider_label_providers(gw, app, store, upstreams):
    """row: provider is a snapshot slug or unattributed"""
    world(upstream="upstream-ok", note="openrouter-endpoints")
    _, providers = await _provider_labels(gw, app, store, upstreams)
    snapshot = app.state.providers.slugs() | {"unattributed"}
    then_eq("every provider label is a snapshot slug (or unattributed)", providers <= snapshot, True,
            claim=f"provider labels {sorted(providers)} ⊆ the snapshot's slugs + unattributed")
