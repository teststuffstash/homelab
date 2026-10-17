"""Shared arrange/observe helpers for the stream-completeness rows (GW-RAIL-OPENROUTER, GW-RAIL-ANTHROPIC)."""

from __future__ import annotations

import re

from .conftest import attach_json, check, then


def recorded_incomplete(store, doc, want_count: int, want_reason: str | None) -> None:
    with then(f"recorded: the session's requests_incomplete = {want_count}; the request row's incomplete = {want_reason}"):
        row = store.get_session(doc["session"]["id"])
        reqs = store.requests_for(doc["session"]["id"])
        attach_json("the session row's request rows", reqs)
        check("requests_incomplete", row.requests_incomplete, want_count)
        check("request row incomplete", reqs[-1]["incomplete"] if reqs else None, want_reason)


async def incomplete_series(gw, rail: str, dialect: str, reason: str) -> float:
    text = (await gw.get("/metrics")).text
    series = f'gateway_requests_incomplete_total{{rail="{rail}",dialect="{dialect}",reason="{reason}"}}'
    m = re.search("^" + re.escape(series) + r" (\S+)$", text, re.M)
    attach_json(f"sample: {series}", {"line": m.group(0) if m else None})
    return float(m.group(1)) if m else 0.0
