"""GW-MODEL-RESOLVE — one model per session, from policy; the body's model must be it (specs/endpoints/anthropic-messages.md).

| description | session model (policy) | rail | body model | verdict | upstream body model |
|---|---|---|---|---|---|
| the Go wire id is the policy id without its prefix | opencode-go/deepseek-v4.1-flash | opencode | deepseek-v4.1-flash | forwarded | deepseek-v4.1-flash |
| the openrouter wire id is the policy id itself | deepseek/deepseek-v4-flash | openrouter | deepseek/deepseek-v4-flash | forwarded | deepseek/deepseek-v4-flash |
| an absent model is filled | opencode-go/deepseek-v4.1-flash | opencode | (absent) | forwarded | deepseek-v4.1-flash |
| a different model is refused | opencode-go/deepseek-v4.1-flash | opencode | claude-haiku-5-5 | 403 model-not-session | — |
| the policy spelling is not the wire spelling | opencode-go/deepseek-v4.1-flash | opencode | opencode-go/deepseek-v4.1-flash | 403 model-not-session | — |
| an anthropic alias matches its family | claude/haiku | anthropic | claude-haiku-4-5 | forwarded | claude-haiku-4-5 (untouched) |
| an anthropic alias refuses another family | claude/sonnet | anthropic | claude-opus-4-1 | 403 model-not-session | — |
| a bare alias in the body matches | claude/sonnet | anthropic | sonnet | forwarded | sonnet (untouched) |
| a claude-code haiku side-call under a sonnet session is admitted | claude/sonnet | anthropic | claude-haiku-4-5 | forwarded | claude-haiku-4-5 (untouched) |
| a bare haiku side-call under a sonnet session is admitted | claude/sonnet | anthropic | haiku | forwarded | haiku (untouched) |
| a side-call family is policy, not code: the Go rail declares none | opencode-go/claude-haiku-5-5 | opencode | claude-haiku-4-5 | 403 model-not-session | — |
| a Go-rail claude id is exact, not family | opencode-go/claude-haiku-5-5 | opencode | claude-haiku-5-5 | forwarded | claude-haiku-5-5 |
| a Go-rail claude id refuses a dated sibling | opencode-go/claude-haiku-5-5 | opencode | claude-sonnet-4-5 | 403 model-not-session | — |

| description | policy document | verdict |
|---|---|---|
| the dispatch answer names the policy id for (rail, tier) | policy-default | model == rails.<rail>.models.<tier> for every role |
| no model id from the policy appears in src/ | policy-default | grep finds none |
| the anthropic body is forwarded byte-untouched | policy-default | upstream body == inbound body |
| the deployed policy loads under the island's loader, every id known | argocd/resources/agent-gateway/policy.json (skipped when absent) | loads; same rails + roles as policy-default; every anthropic model/side-model id is a models.*.ids value of model-classes.json; every opencode id is an opencode candidate row of the committed tier evidence benchmarks.json (the gateway's own GET /catalog/opencode read — listed, with a monthly limit under the plan; GW-MODEL-TIERS) and every openrouter id an openrouter candidate row of it (the gateway's own GET /catalog/openrouter read: ranked ∩ benched — never the old proxy's table, 2026-10-22) ⚖; opencode max_sessions = rails.opencode-go.concurrency |
"""

from __future__ import annotations

import json
import re

import pytest

from agent_gateway.config import Policy

from .conftest import (
    ISLAND,
    attach_json,
    bearer,
    check,
    err,
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
# — the candidate set every deployed Go id is drawn from. The world's five-model catalog fixture
# (#2712) cannot hold a derivation over 29 live models; the static go-catalog.json snapshot retired
# 2026-10-18 once the catalog leg landed.
BENCHMARKS = ISLAND.parent / "argocd" / "resources" / "agent-gateway" / "benchmarks.json"

SESSIONS = {
    "go-flash": ({"role": "worker", "harness": "opencode"}, "opencode", "chat"),
    "or-flash": ({"role": "worker", "harness": "goose", "rail": "openrouter"}, "openrouter", "chat"),
    "sub-haiku": ({"role": "prober", "harness": "claude"}, "anthropic", "messages"),
    "sub-sonnet": ({"role": "reviewer", "harness": "claude"}, "anthropic", "messages"),
    "go-sonnet": ({"role": "reviewer", "harness": "claude", "rail": "opencode"}, "opencode", "messages"),
}

ROWS = [
    ("the Go wire id is the policy id without its prefix", "go-flash", "deepseek-v4.1-flash", "deepseek-v4.1-flash"),
    ("the openrouter wire id is the policy id itself", "or-flash", "deepseek/deepseek-v4-flash", "deepseek/deepseek-v4-flash"),
    ("an absent model is filled", "go-flash", None, "deepseek-v4.1-flash"),
    ("a different model is refused", "go-flash", "claude-haiku-5-5", 403),
    ("the policy spelling is not the wire spelling", "go-flash", "opencode-go/deepseek-v4.1-flash", 403),
    ("an anthropic alias matches its family", "sub-haiku", "claude-haiku-4-5", "claude-haiku-4-5"),
    ("an anthropic alias refuses another family", "sub-sonnet", "claude-opus-4-1", 403),
    ("a bare alias in the body matches", "sub-sonnet", "sonnet", "sonnet"),
    ("a claude-code haiku side-call under a sonnet session is admitted", "sub-sonnet", "claude-haiku-4-5", "claude-haiku-4-5"),
    ("a bare haiku side-call under a sonnet session is admitted", "sub-sonnet", "haiku", "haiku"),
    ("a side-call family is policy, not code: the Go rail declares none", "go-sonnet", "claude-haiku-4-5", 403),
    ("a Go-rail claude id is exact, not family", "go-sonnet", "claude-haiku-5-5", "claude-haiku-5-5"),
    ("a Go-rail claude id refuses a dated sibling", "go-sonnet", "claude-sonnet-4-5", 403),
]


@pytest.mark.parametrize(("which", "asked", "expected"), [r[1:] for r in ROWS], ids=[r[0] for r in ROWS])
async def test_body_model(gw, upstreams, which, asked, expected):
    world(upstream="upstream-ok")
    body, rail, op = SESSIONS[which]
    with given(f"session which={which}: {body} → rail {rail}"):
        doc = await open_session(gw, **body)
        assert doc["rail"] == rail
    payload = {"messages": [{"role": "user", "content": "hi"}], "max_tokens": 8}
    if asked is not None:
        payload["model"] = asked
    path = "/anthropic/v1/messages" if op == "messages" else "/openai/v1/chat/completions"
    with when(f"POST {path} asked model {asked if asked is not None else '(absent)'}"):
        r = await gw.post(path, json=payload, headers=bearer(doc))
    if expected == 403:
        then_eq("status", r.status_code, 403, claim="expected status = 403")
        then_eq("code", err(r), "model-not-session", claim="error code = model-not-session")
        then_eq("upstream calls", len(upstreams[rail].calls), 0, claim="no upstream call")
    else:
        then_eq("status", r.status_code, 200)
        then_eq("upstream body model", upstreams[rail].calls[-1]["body"]["model"], expected, claim=f"expected upstream body model = {expected}")


async def test_dispatch_names_policy_id(gw, policy):
    """row: the dispatch answer names the policy id for (rail, tier)"""
    world()
    with given(f"roles {sorted(policy.roles)} in the policy"):
        attach_json("roles → tier", {role: policy.roles[role].tier for role in policy.roles})
    docs = {}
    with when("POST /sessions once per role (platform)"):
        with quiet():  # one summary of the answers instead of one exchange per role
            for role in policy.roles:
                docs[role] = await open_session(gw, role=role, task=f"t-{role}")
        attach_json("answers: role → (rail, model)", {role: {"rail": d["rail"], "model": d["model"]} for role, d in docs.items()})
    with then("every answer's model = the FIRST of policy.rails[rail].models[role tier] (nothing struck, nothing cooled)"):
        want = {role: policy.rails[d["rail"]].models[policy.roles[role].tier][0] for role, d in docs.items()}
        check("model per role", {role: d["model"] for role, d in docs.items()}, want)


def test_no_model_id_in_code(policy):
    """row: no model id from the policy appears in src/"""
    world()
    with given("every model id in the policy (full and without its rail prefix)"):
        ids = {m for rail in policy.rails.values() for m in (*(x for lst in rail.models.values() for x in lst), *rail.side_models)}
        ids |= {m.split("/", 1)[-1] for m in ids}
        attach_json("policy model ids", sorted(ids))
    with when("grep src/**/*.py for each id"):
        src = "\n".join(p.read_text(encoding="utf-8") for p in (ISLAND / "src").rglob("*.py"))
        leaked = sorted(m for m in ids if re.search(re.escape(m), src))
    then_eq("leaked ids", leaked, [], claim="leaked ids in src/ = []")


@pytest.mark.skipif(not (DEPLOYED_POLICY.exists() and BENCHMARKS.exists()), reason="deploy manifests absent (service-only checkout)")
def test_deployed_policy_loads(policy):
    """row: the deployed policy loads under the island's loader, every id known"""
    world(note="against the deployed policy (the configMapGenerator source)")
    with given(f"the committed tier evidence {BENCHMARKS.relative_to(ISLAND.parent)} — the gateway's own catalog reads: the opencode "
               "candidates (listed, with a monthly limit under the plan) and the openrouter candidates (ranked ∩ benched); GW-MODEL-TIERS"):
        bench = json.loads(BENCHMARKS.read_text(encoding="utf-8"))
        go = set(bench["rails"]["opencode"])
        ranked = set(bench["rails"]["openrouter"])
        attach_json("tier-evidence candidates per rail", {"snapshot_at": bench["snapshot_at"], "opencode": sorted(go), "openrouter": sorted(ranked)})
    with when(f"Policy.from_dict({DEPLOYED_POLICY.relative_to(ISLAND.parent)})"):
        deployed = Policy.from_dict(json.loads(DEPLOYED_POLICY.read_text(encoding="utf-8")))

    def ids_of(rail: str) -> set[str]:
        r = deployed.rails[rail]
        return {m for m in (*(x for lst in r.models.values() for x in lst), *r.side_models)}

    with then("the deployed policy's shape is the test policy's: the same rails and roles, every rail's models = {light, standard, heavy}",
              shape={"rails": {"expected": sorted(policy.rails), "actual": sorted(deployed.rails)},
                     "roles": {"expected": sorted(policy.roles), "actual": sorted(deployed.roles)},
                     "models": {r: sorted(v.models) for r, v in deployed.rails.items()}}):
        assert set(deployed.rails) == set(policy.rails) and set(deployed.roles) == set(policy.roles)
        assert all(set(r.models) == {"light", "standard", "heavy"} for r in deployed.rails.values())
    with then("opencode: every deployed model and side-model id is an opencode candidate row of the committed tier evidence ⚖",
              opencode={"checked": sorted(ids_of("opencode")), "unknown": {"expected": [], "actual": sorted(ids_of("opencode") - go)}}):
        assert ids_of("opencode") <= go, sorted(ids_of("opencode") - go)
    with then("openrouter: every deployed model and side-model id is an openrouter candidate row of the committed tier evidence ⚖",
              openrouter={"checked": sorted(ids_of("openrouter")), "unknown": {"expected": [], "actual": sorted(ids_of("openrouter") - ranked)}}):
        assert ids_of("openrouter") <= ranked, sorted(ids_of("openrouter") - ranked)
    if MODEL_CLASSES.exists():
        mc = json.loads(MODEL_CLASSES.read_text(encoding="utf-8"))
        known = {wire for m in mc["models"].values() if isinstance(m, dict) for wire in m["ids"].values()}
        others = set().union(*(ids_of(r) for r in deployed.rails if r not in ("opencode", "openrouter")))
        concurrency = mc["rails"]["opencode-go"]["concurrency"]
        with then(f"anthropic (and any further rail): every deployed id is spelled as in model-classes.json; opencode max_sessions = its opencode-go concurrency ({concurrency})",
                  model_classes={"checked": sorted(others), "unknown": {"expected": [], "actual": sorted(others - known)},
                                 "max_sessions": {"expected": concurrency, "actual": deployed.rails["opencode"].max_sessions}}):
            assert others <= known, sorted(others - known)
            assert deployed.rails["opencode"].max_sessions == concurrency


async def test_anthropic_body_untouched(gw, upstreams):
    """row: the anthropic body is forwarded byte-untouched"""
    world(upstream="upstream-ok")
    with given("a session on rail anthropic (prober, harness claude)"):
        doc = await open_session(gw, role="prober", harness="claude")
    inbound = {"model": "claude-haiku-4-5", "max_tokens": 1024, "messages": [{"role": "user", "content": "Probe."}], "stream": False, "metadata": {"user_id": "u"}}
    raw = json.dumps(inbound, indent=2).encode()
    with when("POST /anthropic/v1/messages with an indent=2 raw body (model claude-haiku-4-5)"):
        r = await gw.post("/anthropic/v1/messages", content=raw, headers={**bearer(doc), "content-type": "application/json"})
    then_eq("status", r.status_code, 200)
    with then("the upstream received the raw bytes unchanged", raw={"expected_len": len(raw), "actual_len": len(upstreams["anthropic"].calls[-1]["raw"])}):
        assert upstreams["anthropic"].calls[-1]["raw"] == raw
