"""GW-SESSIONS-PULL §Codex token re-read — after the first full env delivery a Codex pull returns only a
fresh session token (specs/endpoints/sessions.md). World policy-codex. Header == argnames, description
== id (tests/_rows.py)."""

from __future__ import annotations

from dataclasses import replace

import httpx
import pytest

from agent_gateway.pull import POD_NAME_EXTRA, POD_UID_EXTRA, Review, StaticTokenReviews

from ._codex_world import body, fresh_report
from ._rows import DASH, enter_world, expect, inputs
from .conftest import given, rule, when

pytestmark = rule("GW-SESSIONS-PULL")

ROWS = [
    pytest.param("policy-codex", "same UID", 200, "a plain gws_ token, Cache-Control no-store; the old token refused; the data plane serves the new one",
                 id="same pod rotates token only"),
    pytest.param("policy-codex", "different UID", 403, DASH, id="recreated pod is refused ⚖"),
    pytest.param("policy-codex", "missing UID", 403, DASH, id="absent UID cannot reread ⚖"),
    pytest.param("policy-codex", "released", 401, DASH, id="released session cannot reread"),
    pytest.param("policy-codex", "expired", 401, DASH, id="expired session cannot reread"),
]


@pytest.mark.parametrize(("world", "second_pull", "expected_status", "expected_answer"), ROWS)
async def test_codex_token_reread(codex_app, clock, world, second_pull, expected_status, expected_answer):
    enter_world(world)
    inputs(second_pull=second_pull)
    svc = codex_app.state.sessions
    review = Review(True, "system:serviceaccount:platform-agents:agentstack-worker", ("agent-gateway",),
                    {POD_NAME_EXTRA: ("dummy-pod",), POD_UID_EXTRA: ("dummy-uid",)})
    reviews = StaticTokenReviews({"DUMMY-SECRET-pod": review})
    svc.reviewer = reviews
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=codex_app), base_url="http://gw") as client:
        with given("a codex session (prober, harness codex) bound to platform-agents/agentstack-worker/dummy-pod, its env pulled once by that pod (uid dummy-uid)"):
            codex_app.state.codex.headroom.observe(fresh_report(clock))
            dispatch = await client.post("/sessions", json={"stack": "platform", "role": "prober", "harness": "codex", "task": "dummy",
                                                            "bind": {"namespace": "platform-agents", "serviceaccount": "agentstack-worker", "pod": "dummy-pod"}})
            sid = dispatch.json()["session"]["id"]
            path = f"/sessions/{sid}/env"
            headers = {"authorization": "Bearer DUMMY-SECRET-pod"}
            first = await client.post(path, headers=headers)
            old = first.json()["env"]["OPENAI_API_KEY"]
        with given(f"second_pull = {second_pull}"):
            if second_pull in ("different UID", "missing UID"):
                extra = {POD_NAME_EXTRA: ("dummy-pod",)}
                if second_pull == "different UID":
                    extra[POD_UID_EXTRA] = ("different-uid",)
                reviews.tokens["DUMMY-SECRET-pod"] = replace(review, extra=extra)
            elif second_pull == "released":
                svc.store.release(sid, clock.t)
            elif second_pull == "expired":
                clock.t += 999999
        with when(f"POST {path} again — the Codex re-read, second_pull = {second_pull}"):
            answer = await client.post(path, headers=headers)
        if answer.status_code == 200:
            ridden = await client.post("/openai/v1/responses", json=body(), headers={"authorization": f"Bearer {answer.text}"})
            plain = answer.text.startswith("gws_") and len(answer.text) == 36 and answer.text != old
            text = (("a plain gws_ token" if plain else f"body {answer.text[:12]!r}") + f", Cache-Control {answer.headers.get('cache-control')}"
                    + ("; the old token refused" if svc.authenticate(old)[1] == "session-unknown" else "; the old token still authenticates")
                    + ("; the data plane serves the new one" if ridden.status_code == 200 else f"; the data plane answers {ridden.status_code}"))
        else:
            text = DASH
    expect({"status": answer.status_code, "answer": text}, status=expected_status, answer=expected_answer)
