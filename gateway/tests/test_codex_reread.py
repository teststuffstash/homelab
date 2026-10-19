"""GW-SESSIONS-PULL token-only re-read decision table.

| description | second pull | answer |
| same pod rotates token only | same UID | plain token, old invalid |
| recreated pod is refused | different UID | 403 |
| absent UID cannot reread | missing UID | 403 |
| released session cannot reread | released | 401 |
| expired session cannot reread | expired | 401 |
"""
from dataclasses import replace

import httpx
import pytest

from agent_gateway.pull import POD_NAME_EXTRA, POD_UID_EXTRA, Review, StaticTokenReviews

from ._codex_world import fresh_report
from .conftest import rule, then_eq, when, world

pytestmark = rule("GW-SESSIONS-PULL")


@pytest.mark.parametrize("case,status", [("same", 200), ("recreated", 403), ("no-uid", 403), ("released", 401), ("expired", 401)],
                         ids=["same pod rotates token only", "recreated pod is refused", "absent UID cannot reread",
                              "released session cannot reread", "expired session cannot reread"])
async def test_reread(codex_app, clock, case, status):
    world("policy-codex")
    svc = codex_app.state.sessions
    review = Review(True, "system:serviceaccount:platform-agents:agentstack-worker", ("agent-gateway",),
                    {POD_NAME_EXTRA: ("dummy-pod",), POD_UID_EXTRA: ("dummy-uid",)})
    reviews = StaticTokenReviews({"DUMMY-SECRET-pod": review})
    svc.reviewer = reviews
    codex_app.state.codex.headroom.observe(fresh_report(clock))
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=codex_app), base_url="http://gw") as client:
        dispatch = await client.post("/sessions", json={"stack": "platform", "role": "prober", "harness": "codex", "task": "dummy",
                                      "bind": {"namespace": "platform-agents", "serviceaccount": "agentstack-worker", "pod": "dummy-pod"}})
        sid = dispatch.json()["session"]["id"]
        path = f"/sessions/{sid}/env"
        headers = {"authorization": "Bearer DUMMY-SECRET-pod"}
        first = await client.post(path, headers=headers)
        old = first.json()["env"]["OPENAI_API_KEY"]
        if case in ("recreated", "no-uid"):
            extra = {POD_NAME_EXTRA: ("dummy-pod",)}
            if case == "recreated":
                extra[POD_UID_EXTRA] = ("different-uid",)
            reviews.tokens["DUMMY-SECRET-pod"] = replace(review, extra=extra)
        if case == "released":
            svc.store.release(sid, clock.t)
        if case == "expired":
            clock.t += 999999
        with when("repeat the Codex env pull: " + case):
            answer = await client.post(path, headers=headers)
        then_eq("HTTP status", answer.status_code, status)
        if status == 200:
            then_eq("only a new token returned", answer.text.startswith("gws_") and len(answer.text) == 36 and answer.text != old, True)
            then_eq("old token refused", svc.authenticate(old)[1], "session-unknown")
            then_eq("new token accepted", svc.authenticate(answer.text)[1], None)
            then_eq("cache disabled", answer.headers.get("cache-control"), "no-store")
