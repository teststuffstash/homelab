"""Shared observe helpers for the stream-completeness rows (GW-RAIL-OPENROUTER, GW-RAIL-ANTHROPIC):
the session's `requests_incomplete` counter, the request row's `incomplete` reason and its status,
and the `gateway_requests_incomplete_total{rail,dialect,reason}` sample — each returned in its
column's literal (`(none)` for a null reason) so the row module's `then_eq` carries the cell; they
attach nothing themselves (the verdicts do)."""

from __future__ import annotations

import re

from .conftest import quiet

NONE = "(none)"


def incomplete_recorded(store, doc: dict) -> tuple[int, str, int | None]:
    """(the session's `requests_incomplete`, the last request row's `incomplete` or `(none)`, that
    row's status)."""
    row = store.get_session(doc["session"]["id"])
    reqs = store.requests_for(doc["session"]["id"])
    last = reqs[-1] if reqs else None
    return row.requests_incomplete, (last["incomplete"] if last and last["incomplete"] else NONE), (last["status"] if last else None)


async def incomplete_series(gw, rail: str, dialect: str, reason: str) -> int:
    """`gateway_requests_incomplete_total{rail,dialect,reason}` as the row's `incomplete_total?`
    counts it: 0 when the series is not rendered. The /metrics exposition is muted — the
    `incomplete_total?` verdict names the series and carries the value."""
    with quiet():
        text = (await gw.get("/metrics")).text
    series = f'gateway_requests_incomplete_total{{rail="{rail}",dialect="{dialect}",reason="{reason}"}}'
    m = re.search("^" + re.escape(series) + r" (\S+)$", text, re.M)
    return int(float(m.group(1))) if m else 0
