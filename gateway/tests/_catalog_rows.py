"""Row helpers shared by the catalog page's modules (specs/endpoints/catalog.md — GW-CATALOG-GO,
GW-CATALOG-GO-PARSE, GW-CATALOG-OR, GW-CATALOG-OR-CANARY, GW-MODEL-TIERS, GW-RAIL-CHOICE).

The page's tables are in the v0.6.9 shape (CONVENTIONS § The intent column): every header cell is a
parametrize argname, every `name?` column the argname `expected_name`, every cell the parameter's
value — so a row module passes STRINGS (`T0 + 600 s`, `the five`, `3600 · 3600`) and decodes them
here, and its one verdict step threads the columns by NAME (`verdict()` — the attachment's keys
are the argnames) so the report shows which column each compared value is.
"""

from __future__ import annotations

import contextlib
import datetime as dt
import json
from collections.abc import Iterator
from typing import Any

import httpx

from .conftest import ObservedAsyncClient, attach_json, quiet, then, when

T0 = 1_800_000_000.0  # 2027-01-15T08:00:00Z — the test clock's origin (conftest Clock)


def verdict(claim: str, **compared: dict[str, Any]) -> None:
    """ONE Then step for the row, named with the claimed values. `compared` keys are the row's
    COLUMN argnames: an expected column as `expected_<name>={"expected": …, "actual": …}` (asserted
    here, so the step's status IS the verdict), an input column as `<name>={"actual": …}` (restated
    so the thread finds it in the then phase). Observability never swallows an assertion."""
    with then(claim, **compared):
        for key, pair in compared.items():
            if "expected" in pair:
                assert pair["actual"] == pair["expected"], f"{key}: expected {pair['expected']!r}, got {pair['actual']!r}"


@contextlib.contextmanager
def verdict_block(claim: str, **compared: dict[str, Any]) -> Iterator[None]:
    """`verdict()` whose assertions the caller writes inside the block (observed values that need
    the step open — a /metrics read, a store row). The compared pairs attach the same way."""
    with then(claim, **compared):
        for key, pair in compared.items():
            if "expected" in pair:
                assert pair["actual"] == pair["expected"], f"{key}: expected {pair['expected']!r}, got {pair['actual']!r}"
        yield


def iso(ts: float) -> str:
    return dt.datetime.fromtimestamp(ts, tz=dt.UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def at_offset(cell: str) -> float | None:
    """`T0` → 0, `T0 + 600 s` → 600, `T0 − 600 s` → -600, `none` → None (the page's time literals)."""
    c = cell.strip()
    if c == "none":
        return None
    if c == "T0":
        return 0.0
    for sign, mul in (("+", 1), ("−", -1), ("-", -1)):
        if c.startswith(f"T0 {sign} ") and c.endswith(" s"):
            return mul * float(c[len(f"T0 {sign} "):-2])
    raise ValueError(f"not a time literal: {cell!r}")


def at_iso(cell: str) -> str | None:
    """The page's time literal as the view renders it (`fetched_at` ISO) — `none` → None."""
    off = at_offset(cell)
    return None if off is None else iso(T0 + off)


def num(v: float | int | None) -> str:
    """A number as the page writes it: `600`, `0.075`, `none`."""
    if v is None:
        return "none"
    if isinstance(v, float) and v != v:  # NaN
        return "nan"
    return f"{v:g}" if isinstance(v, int | float) else str(v)


def listed(cell: str) -> list[str]:
    """`a, b` → [a, b]; `none` → []."""
    return [] if cell.strip() == "none" else [x.strip() for x in cell.split(",")]


def joined(ids: list[str] | tuple[str, ...]) -> str:
    return ", ".join(ids) if ids else "none"


# ---------------------------------------------------------------------------------------------
# the OpenRouter catalog's shared arrange / act steps (GW-CATALOG-OR, GW-CATALOG-OR-CANARY)
# ---------------------------------------------------------------------------------------------
M = "deepseek/deepseek-v4.1-flash"
G = "z-ai/glm-5.3-flash"
OR_RAIL = "openrouter"
CHAT = "/openai/v1/chat/completions"
THROTTLED = "upstream-429-shared-pool"


async def or_refresh(app, label: str = "") -> str:
    """The catalog refresh as the call under test (one When)."""
    with when(f"the OpenRouter catalog refreshes{label}"):
        with quiet():  # the MCP + endpoints exchanges fold into one attachment (ATTACH_BULK)
            outcome = await app.state.orcatalog.refresh()
        attach_json("the refresh", {"outcome": outcome, "sources": app.state.orcatalog.sources,
                                    "endpoint_failures": app.state.orcatalog.endpoint_failures})
        return outcome


async def or_refreshed(app) -> None:
    """A good refresh as ARRANGE (inside the caller's given step; exchanges muted)."""
    with quiet():
        assert await app.state.orcatalog.refresh() == "ok"


async def or_view(gw) -> dict:
    r = await gw.get("/catalog/openrouter")
    assert r.status_code == 200, r.text
    return r.json()


async def or_series(gw, name: str) -> float | None:
    import re

    with quiet():
        text = (await gw.get("/metrics")).text
    m = re.search("^" + re.escape(name) + r" (\S+)$", text, re.M)
    attach_json(f"sample: {name}", {"line": m.group(0) if m else None})
    return float(m.group(1)) if m else None


async def or_series_many(gw, names: list[str]) -> dict[str, float | None]:
    """Several series from ONE /metrics read, one attachment (ATTACH_BULK: ≤ 8 per case)."""
    import re

    with quiet():
        text = (await gw.get("/metrics")).text
    out: dict[str, float | None] = {}
    for name in names:
        m = re.search("^" + re.escape(name) + r" (\S+)$", text, re.M)
        out[name] = float(m.group(1)) if m else None
    attach_json("sampled series", out)
    return out


def canary_body(model: str, provider: str, **extra) -> dict:
    return {"stack": "platform", "role": "prober", "task": f"canary-{model}-{provider}",
            "canary": {"model": model, "provider": provider}, **extra}


async def canary_ride(gw, upstreams, provider: str = "deepinfra", behaviour: str = "upstream-ok",
                      outcome: str | None = "clean", model: str = M) -> dict:
    """ARRANGE: one canary session on (model, provider), its ride under `behaviour`, then the
    consumer's outcome (None = no outcome reported). Exchanges muted; one summary attached."""
    with quiet():
        r = await gw.post("/sessions", json=canary_body(model, provider))
        assert r.json()["decision"] == "dispatch", r.text
        doc = r.json()
        upstreams[OR_RAIL].provider_behaviours[provider] = behaviour
        rr = await gw.post(CHAT, json={"model": model, "messages": []}, headers={"authorization": f"Bearer {doc['session']['token']}"})
        upstreams[OR_RAIL].provider_behaviours.pop(provider, None)
        if outcome:
            await gw.post(f"/sessions/{doc['session']['id']}/outcome", json={"class": outcome})
    attach_json(f"canary ride on ({model}, {provider}): {behaviour} → {rr.status_code}, outcome {outcome}",
                {"session": doc["session"]["id"], "upstream": behaviour, "status": rr.status_code, "outcome": outcome})
    doc["_ride_status"] = rr.status_code
    return doc


def horizon(store, provider: str = "deepinfra", model: str = M) -> dict:
    row = store.cell_get(model, provider)
    return {"state": row["state"], "class": row["class"], "cooldown_until": row["cooldown_until"],
            "retry_at": row["retry_at"], "backoff_s": row["backoff_s"], "limit_source": row["limit_source"]}


class SecondGateway:
    """A new gateway on the same DB (a pod roll): `startup_delay` is the loop's first decision —
    `run()` is not started (ASGI transports run no lifespan), the test reads the helper it wraps."""

    def __init__(self, settings, policy, secrets, transport, reviews, pods, clock):
        from agent_gateway.app import create_app
        from agent_gateway.store import Store

        self.client = httpx.AsyncClient(transport=transport)
        self.app = create_app(settings, policy=policy, source=secrets, store=Store(settings.db_path), client=self.client,
                              clock=clock, reviewer=reviews, pods=pods)
        self.gw = ObservedAsyncClient(transport=httpx.ASGITransport(app=self.app), base_url="http://gw2")
        self.or_delay = self.app.state.orcatalog.startup_delay(clock())
        self.go_delay = self.app.state.catalog.startup_delay(clock())
        attach_json("the second gateway's startup_delay", {"openrouter_catalog_s": self.or_delay, "go_catalog_s": self.go_delay})

    async def close(self) -> None:
        await self.gw.aclose()
        await self.client.aclose()


def dumps(obj: Any) -> str:
    return json.dumps(obj, sort_keys=True, default=repr)
