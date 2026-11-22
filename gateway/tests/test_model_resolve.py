"""GW-MODEL-RESOLVE — one model per session, from policy; the body's model must be it
(specs/endpoints/anthropic-messages.md).

One parametrized case per table row: the argnames are the table's header cells (`name?` is
`expected_name`), the ids its description cells, the literals the page's Legend lines. World
`policy-default`, every upstream at `upstream-ok`; a session's (rail, policy model) is reached
through the admission that lands there (`SESSIONS`).
"""

from __future__ import annotations

import json
import re

import pytest

from agent_gateway.config import Policy

from ._codex_world import CODEX_POLICY
from ._rail_rows import NONE, inputs
from .conftest import (
    ISLAND,
    attach_json,
    bearer,
    check,
    given,
    open_session,
    quiet,
    rule,
    then,
    then_eq,
    when,
    world,
)

pytestmark = rule("GW-MODEL-RESOLVE")

# The deploy half of the island, when this checkout carries it (the monorepo; absent in a
# service-only checkout): the deployed policy.json and the fleet's model table.
DEPLOYED_POLICY = ISLAND.parent / "argocd" / "resources" / "agent-gateway" / "policy.json"
MODEL_CLASSES = ISLAND.parent / "argocd" / "resources" / "openrouter-proxy" / "model-classes.json"
# ⚖ (operator, 2026-10-17): the opencode rail's ids are checked against the Go catalog, not
# model-classes.json — that table is the old proxy's, and a Go id added there is a new models key in
# the live router. Since the lists are DERIVED (GW-MODEL-TIERS, 2026-10-18) the catalog read is the
# committed tier evidence: benchmarks.json's opencode rows are the live `GET /catalog/opencode`
# answer (the leg's own parser in the running gateway) filtered to listed models with a monthly limit
# — the candidate set every deployed Go id is drawn from.
BENCHMARKS = ISLAND.parent / "argocd" / "resources" / "agent-gateway" / "benchmarks.json"

# (rail, the session's policy model) → the admission that lands there, and the dialect path it rides.
SESSIONS = {
    ("opencode", "opencode-go/deepseek-v4.1-flash"): ({"role": "worker", "harness": "opencode"}, "/openai/v1/chat/completions"),
    ("openrouter", "deepseek/deepseek-v4-flash"): ({"role": "worker", "harness": "goose", "rail": "openrouter"}, "/openai/v1/chat/completions"),
    ("anthropic", "claude/haiku"): ({"role": "prober", "harness": "claude"}, "/anthropic/v1/messages"),
    ("anthropic", "claude/sonnet"): ({"role": "reviewer", "harness": "claude"}, "/anthropic/v1/messages"),
    ("opencode", "opencode-go/claude-haiku-5-5"): ({"role": "reviewer", "harness": "claude", "rail": "opencode"}, "/anthropic/v1/messages"),
}
NO_CALL = "(no upstream call)"
ABSENT = "(absent)"


async def _model_case(gw, upstreams, rail, session_model, body_model, expected_status, expected_code, expected_upstream_model):
    world(upstream="upstream-ok")
    admission, path = SESSIONS[(rail, session_model)]
    with given(f"a session on rail {rail} whose policy model is session_model = {session_model} ({admission})"):
        doc = await open_session(gw, **admission)
        check("the admitted (rail, model)", (doc["rail"], doc["model"]), (rail, session_model))
    payload = {"messages": [{"role": "user", "content": "hi"}], "max_tokens": 8}
    if body_model != ABSENT:
        payload["model"] = body_model
    with when(f"POST {path} · {inputs(rail=rail, session_model=session_model, body_model=body_model)}"):
        r = await gw.post(path, json=payload, headers=bearer(doc))
    then_eq("expected_status", r.status_code, expected_status, claim=f"status? = {expected_status}")
    code = r.json()["error"]["code"] if r.status_code != 200 else NONE
    then_eq("expected_code", code, expected_code, claim=f"code? = {expected_code}")
    seen = upstreams[rail].calls[-1]["body"]["model"] if upstreams[rail].calls else NO_CALL
    then_eq("expected_upstream_model", seen, expected_upstream_model, claim=f"upstream_model? = {expected_upstream_model}")


# -- The body's model against the session's -------------------------------------------------------
EXACT_ROWS = [  # description | rail | session_model | body_model | status? | code? | upstream_model?
    ("the Go wire id is the policy id without its prefix", "opencode", "opencode-go/deepseek-v4.1-flash", "deepseek-v4.1-flash", 200, NONE, "deepseek-v4.1-flash"),
    ("the openrouter wire id is the policy id itself", "openrouter", "deepseek/deepseek-v4-flash", "deepseek/deepseek-v4-flash", 200, NONE, "deepseek/deepseek-v4-flash"),
    ("an absent model is filled", "opencode", "opencode-go/deepseek-v4.1-flash", ABSENT, 200, NONE, "deepseek-v4.1-flash"),
    ("a different model is refused", "opencode", "opencode-go/deepseek-v4.1-flash", "claude-haiku-5-5", 403, "model-not-session", NO_CALL),
    ("the policy spelling is not the wire spelling ⚖", "opencode", "opencode-go/deepseek-v4.1-flash", "opencode-go/deepseek-v4.1-flash", 403, "model-not-session", NO_CALL),
    ("a Go-rail claude id is exact, not family", "opencode", "opencode-go/claude-haiku-5-5", "claude-haiku-5-5", 200, NONE, "claude-haiku-5-5"),
    ("a Go-rail claude id refuses a dated sibling", "opencode", "opencode-go/claude-haiku-5-5", "claude-sonnet-4-5", 403, "model-not-session", NO_CALL),
]


@pytest.mark.parametrize(("rail", "session_model", "body_model", "expected_status", "expected_code", "expected_upstream_model"),
                         [r[1:] for r in EXACT_ROWS], ids=[r[0] for r in EXACT_ROWS])
async def test_body_model(gw, upstreams, rail, session_model, body_model, expected_status, expected_code, expected_upstream_model):
    await _model_case(gw, upstreams, rail, session_model, body_model, expected_status, expected_code, expected_upstream_model)


# -- The anthropic rail's family check and the side-call families ---------------------------------
FAMILY_ROWS = [  # description | rail | session_model | body_model | status? | code? | upstream_model?
    ("an anthropic alias matches its family ⚖", "anthropic", "claude/haiku", "claude-haiku-4-5", 200, NONE, "claude-haiku-4-5"),
    ("an anthropic alias refuses another family", "anthropic", "claude/sonnet", "claude-opus-4-1", 403, "model-not-session", NO_CALL),
    ("a bare alias in the body matches ⚖", "anthropic", "claude/sonnet", "sonnet", 200, NONE, "sonnet"),
    ("a claude-code haiku side-call under a sonnet session is admitted ⚖", "anthropic", "claude/sonnet", "claude-haiku-4-5", 200, NONE, "claude-haiku-4-5"),
    ("a bare haiku side-call under a sonnet session is admitted ⚖", "anthropic", "claude/sonnet", "haiku", 200, NONE, "haiku"),
    ("a side-call family is policy, not code: the Go rail declares none", "opencode", "opencode-go/claude-haiku-5-5", "claude-haiku-4-5", 403, "model-not-session", NO_CALL),
]


@pytest.mark.parametrize(("rail", "session_model", "body_model", "expected_status", "expected_code", "expected_upstream_model"),
                         [r[1:] for r in FAMILY_ROWS], ids=[r[0] for r in FAMILY_ROWS])
async def test_family_model(gw, upstreams, rail, session_model, body_model, expected_status, expected_code, expected_upstream_model):
    await _model_case(gw, upstreams, rail, session_model, body_model, expected_status, expected_code, expected_upstream_model)


# -- The dispatch answer names the policy id ------------------------------------------------------
DISPATCH_ROWS = [  # description | role | rail? | model?
    ("a worker lands on the Go rail's standard model", "worker", "opencode", "opencode-go/deepseek-v4.1-flash"),
    ("a reviewer lands on the subscription's heavy list, first id", "reviewer", "anthropic", "claude/sonnet"),
    ("a coordinator lands on the subscription's standard model", "coordinator", "anthropic", "claude/sonnet"),
    ("a responder lands on the subscription's standard model", "responder", "anthropic", "claude/sonnet"),
    ("a retro lands on the subscription's heavy list, first id", "retro", "anthropic", "claude/sonnet"),
    ("a prober lands on the subscription's light model", "prober", "anthropic", "claude/haiku"),
    ("a researcher lands on openrouter's heavy model", "researcher", "openrouter", "deepseek/deepseek-v4.1-flash"),
]


@pytest.mark.parametrize(("role", "expected_rail", "expected_model"), [r[1:] for r in DISPATCH_ROWS], ids=[r[0] for r in DISPATCH_ROWS])
async def test_dispatch_names_policy_id(gw, policy, role, expected_rail, expected_model):
    world()
    with given(f"role = {role}: rails {policy.roles[role].rails}, tier {policy.roles[role].tier}; nothing struck, nothing cooled"):
        attach_json("the policy's lists for the role's rails and tier",
                    {rail: policy.rails[rail].models[policy.roles[role].tier] for rail in policy.roles[role].rails})
    with when(f"POST /sessions · {inputs(role=role)} (stack platform)"):
        doc = await open_session(gw, role=role, task=f"t-{role}")
    then_eq("expected_rail", doc["rail"], expected_rail, claim=f"rail? = {expected_rail}")
    then_eq("expected_model", doc["model"], expected_model, claim=f"model? = {expected_model} (the FIRST id of rails.{expected_rail}.models.{policy.roles[role].tier})")


# -- The policy is the only home of a model id ----------------------------------------------------
CODE_ROWS = [  # description | policy_document | leaked_ids?
    ("no model id from the policy appears in src/", "policy-default", NONE),
]


@pytest.mark.parametrize(("policy_document", "expected_leaked_ids"), [r[1:] for r in CODE_ROWS], ids=[r[0] for r in CODE_ROWS])
def test_no_model_id_in_code(policy, policy_document, expected_leaked_ids):
    world(policy=policy_document)
    with given(f"every model id in policy = {policy_document} (full and without its rail prefix)"):
        ids = {m for rail in policy.rails.values() for m in (*(x for lst in rail.models.values() for x in lst), *rail.side_models)}
        ids |= {m.split("/", 1)[-1] for m in ids}
        attach_json("policy model ids", sorted(ids))
    with when(f"grep src/**/*.py for each id · {inputs(policy_document=policy_document)}"):
        src = "\n".join(p.read_text(encoding="utf-8") for p in (ISLAND / "src").rglob("*.py"))
        leaked = sorted(m for m in ids if re.search(re.escape(m), src))
    then_eq("expected_leaked_ids", ", ".join(leaked) if leaked else NONE, expected_leaked_ids, claim=f"leaked_ids? = {expected_leaked_ids}")


# -- The anthropic body is forwarded untouched ----------------------------------------------------
BODY_ROWS = [  # description | rail | body_model | upstream_body?
    ("the anthropic body is forwarded byte-untouched", "anthropic", "claude-haiku-4-5", "the inbound bytes"),
]


@pytest.mark.parametrize(("rail", "body_model", "expected_upstream_body"), [r[1:] for r in BODY_ROWS], ids=[r[0] for r in BODY_ROWS])
async def test_anthropic_body_untouched(gw, upstreams, rail, body_model, expected_upstream_body):
    world(upstream="upstream-ok")
    with given(f"a session on rail {rail} (prober, harness claude)"):
        doc = await open_session(gw, role="prober", harness="claude")
    inbound = {"model": body_model, "max_tokens": 1024, "messages": [{"role": "user", "content": "Probe."}], "stream": False, "metadata": {"user_id": "u"}}
    raw = json.dumps(inbound, indent=2).encode()
    with when(f"POST /anthropic/v1/messages with an indent=2 raw body · {inputs(rail=rail, body_model=body_model)}"):
        r = await gw.post("/anthropic/v1/messages", content=raw, headers={**bearer(doc), "content-type": "application/json"})
    then_eq("status", r.status_code, 200)
    seen = upstreams[rail].calls[-1]["raw"]
    then_eq("expected_upstream_body", "the inbound bytes" if seen == raw else f"({len(seen)} bytes, differs)", expected_upstream_body,
            claim=f"upstream_body? = {expected_upstream_body} ({len(raw)} bytes)")


# -- The deployed policy --------------------------------------------------------------------------
DEPLOYED_ROWS = [  # description | policy_document | shape? | unknown_ids? | opencode_max_sessions?
    ("the deployed policy loads under the island's loader, every id known ⚖", "argocd/resources/agent-gateway/policy.json", "the worlds' shape", NONE, 3),
]


@pytest.mark.skipif(not (DEPLOYED_POLICY.exists() and BENCHMARKS.exists()), reason="deploy manifests absent (service-only checkout)")
@pytest.mark.parametrize(("policy_document", "expected_shape", "expected_unknown_ids", "expected_opencode_max_sessions"),
                         [r[1:] for r in DEPLOYED_ROWS], ids=[r[0] for r in DEPLOYED_ROWS])
def test_deployed_policy_loads(policy, policy_document, expected_shape, expected_unknown_ids, expected_opencode_max_sessions):
    world(note="against the deployed policy (the configMapGenerator source)")
    with given(f"the committed tier evidence {BENCHMARKS.relative_to(ISLAND.parent)} — the gateway's own catalog reads: the opencode "
                                                                 "candidates (listed, with a monthly limit under the plan), the openrouter candidates (ranked ∩ benched), "
                                                                 "the codex candidates (the enrolled account's); GW-MODEL-TIERS"):
        bench = json.loads(BENCHMARKS.read_text(encoding="utf-8"))
        candidates = {rail: set(bench["rails"][rail]) for rail in ("opencode", "openrouter", "codex")}
        attach_json("tier-evidence candidates per rail", {"snapshot_at": bench["snapshot_at"], **{r: sorted(c) for r, c in candidates.items()}})
        rails_world = Policy.load(CODEX_POLICY)  # the policy-codex world: policy-default's rails + codex (lit in the deployed policy 2026-10-22)
        known_spellings = None
        concurrency = None
        if MODEL_CLASSES.exists():
            mc = json.loads(MODEL_CLASSES.read_text(encoding="utf-8"))
            known_spellings = {wire for m in mc["models"].values() if isinstance(m, dict) for wire in m["ids"].values()}
            concurrency = mc["rails"]["opencode-go"]["concurrency"]
            attach_json("model-classes.json: the anthropic spellings and the opencode-go concurrency", {"spellings": sorted(known_spellings), "concurrency": concurrency})
    with when(f"Policy.from_dict({policy_document}) · {inputs(policy_document=policy_document)}"):
        deployed = Policy.from_dict(json.loads((ISLAND.parent / policy_document).read_text(encoding="utf-8")))

    def ids_of(rail: str) -> set[str]:
        r = deployed.rails[rail]
        return {m for m in (*(x for lst in r.models.values() for x in lst), *r.side_models)}

    shape = {"rails": sorted(deployed.rails), "roles": sorted(deployed.roles), "tiers": {r: sorted(v.models) for r, v in deployed.rails.items()}}
    want = {"rails": sorted(rails_world.rails), "roles": sorted(policy.roles), "tiers": {r: ["heavy", "light", "standard"] for r in deployed.rails}}
    then_eq("expected_shape", "the worlds' shape" if shape == want else "differs", expected_shape,
            claim=f"shape? = {expected_shape}: policy-codex's rails {want['rails']}, policy-default's roles, every rail's tiers light/standard/heavy")
    unknown = {rail: sorted(ids_of(rail) - candidates[rail]) for rail in candidates}
    if known_spellings is not None:
        others = set().union(*(ids_of(r) for r in deployed.rails if r not in candidates))
        unknown["anthropic (model-classes.json spelling)"] = sorted(others - known_spellings)
    with then(f"unknown_ids? = {expected_unknown_ids} — every deployed id is a candidate row of the tier evidence for its rail ⚖ (anthropic: spelled as model-classes.json)",
              expected_unknown_ids={"expected": expected_unknown_ids, "actual": ", ".join(f"{r}: {u}" for r, u in unknown.items() if u) or NONE},
              checked={r: sorted(ids_of(r)) for r in deployed.rails}):
        assert not any(unknown.values()), unknown
    then_eq("expected_opencode_max_sessions", deployed.rails["opencode"].max_sessions, expected_opencode_max_sessions,
            claim=f"opencode_max_sessions? = {expected_opencode_max_sessions} (= model-classes.json rails.opencode-go.concurrency {concurrency})")
    if concurrency is not None:
        with quiet():
            check("opencode-go concurrency", concurrency, expected_opencode_max_sessions)
