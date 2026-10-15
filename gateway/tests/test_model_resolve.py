"""GW-MODEL-RESOLVE — one model per session, from policy; the body's model must be it (specs/endpoints/anthropic-messages.md).

| description | session model (policy) | rail | body model | verdict | upstream body model |
|---|---|---|---|---|---|
| the Go wire id is the policy id without its prefix | opencode-go/deepseek-v4-flash | opencode | deepseek-v4-flash | forwarded | deepseek-v4-flash |
| the openrouter wire id is the policy id itself | deepseek/deepseek-v4-flash | openrouter | deepseek/deepseek-v4-flash | forwarded | deepseek/deepseek-v4-flash |
| an absent model is filled | opencode-go/deepseek-v4-flash | opencode | (absent) | forwarded | deepseek-v4-flash |
| a different model is refused | opencode-go/deepseek-v4-flash | opencode | claude-sonnet-4-6 | 403 model-not-session | — |
| the policy spelling is not the wire spelling | opencode-go/deepseek-v4-flash | opencode | opencode-go/deepseek-v4-flash | 403 model-not-session | — |
| an anthropic alias matches its family | claude/haiku | anthropic | claude-haiku-4-5 | forwarded | claude-haiku-4-5 (untouched) |
| an anthropic alias refuses another family | claude/sonnet | anthropic | claude-haiku-4-5 | 403 model-not-session | — |
| a bare alias in the body matches | claude/sonnet | anthropic | sonnet | forwarded | sonnet (untouched) |
| a Go-rail claude id is exact, not family | opencode-go/claude-sonnet-4-6 | opencode | claude-sonnet-4-6 | forwarded | claude-sonnet-4-6 |
| a Go-rail claude id refuses a dated sibling | opencode-go/claude-sonnet-4-6 | opencode | claude-sonnet-4-5 | 403 model-not-session | — |

| description | expected |
|---|---|
| the dispatch answer names the policy id for (rail, tier) | model == rails.<rail>.models.<tier> for every role |
| no model id from the policy appears in src/ | grep finds none |
| the anthropic body is forwarded byte-untouched | upstream body == inbound body |
"""

from __future__ import annotations

import json
import re

import pytest

from .conftest import ISLAND, bearer, err, open_session, rule

pytestmark = rule("GW-MODEL-RESOLVE")

SESSIONS = {
    "go-flash": ({"role": "worker", "harness": "opencode"}, "opencode", "chat"),
    "or-flash": ({"role": "worker", "harness": "goose", "rail": "openrouter"}, "openrouter", "chat"),
    "sub-haiku": ({"role": "prober", "harness": "claude"}, "anthropic", "messages"),
    "sub-sonnet": ({"role": "reviewer", "harness": "claude"}, "anthropic", "messages"),
    "go-sonnet": ({"role": "reviewer", "harness": "claude", "rail": "opencode"}, "opencode", "messages"),
}

ROWS = [
    ("the Go wire id is the policy id without its prefix", "go-flash", "deepseek-v4-flash", "deepseek-v4-flash"),
    ("the openrouter wire id is the policy id itself", "or-flash", "deepseek/deepseek-v4-flash", "deepseek/deepseek-v4-flash"),
    ("an absent model is filled", "go-flash", None, "deepseek-v4-flash"),
    ("a different model is refused", "go-flash", "claude-sonnet-4-6", 403),
    ("the policy spelling is not the wire spelling", "go-flash", "opencode-go/deepseek-v4-flash", 403),
    ("an anthropic alias matches its family", "sub-haiku", "claude-haiku-4-5", "claude-haiku-4-5"),
    ("an anthropic alias refuses another family", "sub-sonnet", "claude-haiku-4-5", 403),
    ("a bare alias in the body matches", "sub-sonnet", "sonnet", "sonnet"),
    ("a Go-rail claude id is exact, not family", "go-sonnet", "claude-sonnet-4-6", "claude-sonnet-4-6"),
    ("a Go-rail claude id refuses a dated sibling", "go-sonnet", "claude-sonnet-4-5", 403),
]


@pytest.mark.parametrize(("which", "asked", "expected"), [r[1:] for r in ROWS], ids=[r[0] for r in ROWS])
async def test_body_model(gw, upstreams, which, asked, expected):
    body, rail, op = SESSIONS[which]
    doc = await open_session(gw, **body)
    assert doc["rail"] == rail
    payload = {"messages": [{"role": "user", "content": "hi"}], "max_tokens": 8}
    if asked is not None:
        payload["model"] = asked
    path = "/anthropic/v1/messages" if op == "messages" else "/openai/v1/chat/completions"
    r = await gw.post(path, json=payload, headers=bearer(doc))
    if expected == 403:
        assert r.status_code == 403 and err(r) == "model-not-session"
        assert upstreams[rail].calls == []
    else:
        assert r.status_code == 200, r.text
        assert upstreams[rail].calls[-1]["body"]["model"] == expected


async def test_dispatch_names_policy_id(gw, policy):
    """row: the dispatch answer names the policy id for (rail, tier)"""
    for role in policy.roles:
        doc = await open_session(gw, role=role, task=f"t-{role}")
        assert doc["model"] == policy.rails[doc["rail"]].models[policy.roles[role].tier]


def test_no_model_id_in_code(policy):
    """row: no model id from the policy appears in src/"""
    ids = {m for rail in policy.rails.values() for m in rail.models.values()}
    ids |= {m.split("/", 1)[-1] for m in ids}
    src = "\n".join(p.read_text(encoding="utf-8") for p in (ISLAND / "src").rglob("*.py"))
    leaked = sorted(m for m in ids if re.search(re.escape(m), src))
    assert not leaked, leaked


async def test_anthropic_body_untouched(gw, upstreams):
    """row: the anthropic body is forwarded byte-untouched"""
    doc = await open_session(gw, role="prober", harness="claude")
    inbound = {"model": "claude-haiku-4-5", "max_tokens": 1024, "messages": [{"role": "user", "content": "Probe."}], "stream": False, "metadata": {"user_id": "u"}}
    raw = json.dumps(inbound, indent=2).encode()
    r = await gw.post("/anthropic/v1/messages", content=raw, headers={**bearer(doc), "content-type": "application/json"})
    assert r.status_code == 200
    assert upstreams["anthropic"].calls[-1]["raw"] == raw
