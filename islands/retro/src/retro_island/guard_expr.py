"""RETRO-GUARD-EXPR (specs/guard.md): one instant-query outcome → the guard's decision.

Same verdicts as the old member `agents/retro_guard_expr.py` (`FIRE, QUIET, FAIL = 0, 3, 1`). Pure:
no HTTP call, no push, no `prepare`. The outcome is the response body text, or `None` for a
transport failure (Prometheus unreachable — the old parser is never called then).
"""

from __future__ import annotations

import json
from dataclasses import dataclass

FIRE, QUIET, FAIL = 0, 3, 1


@dataclass(frozen=True)
class Decision:
    verdict: int  # the parser verdict: 0 FIRE / 3 QUIET / 1 FAIL
    rc: int  # the guard STEP's exit code
    quiet: bool | None  # the `quiet` output; None when the step fails before setting it
    prepare_called: str  # `--no-ledger` or `no`
    reason: str


def verdict(body: str | None) -> tuple[int, str]:
    """The parser verdict for a response body (None = transport failure)."""
    if body is None:
        return FAIL, "transport failure"
    try:
        doc = json.loads(body)
    except ValueError:
        return FAIL, "unparsable response"
    if not isinstance(doc, dict) or doc.get("status") != "success":
        return FAIL, "non-success status"
    data = doc.get("data") or {}
    result = data.get("result")
    if data.get("resultType") == "scalar" and isinstance(result, list) and len(result) == 2:
        result = [{"metric": {}, "value": result}]
    if not isinstance(result, list) or not result:
        return FAIL, "no samples"
    values: list[float] = []
    for sample in result:
        try:
            values.append(float(sample["value"][1]))
        except (KeyError, IndexError, TypeError, ValueError):
            return FAIL, "malformed sample"
    if any(v != v for v in values):
        return FAIL, "NaN sample"
    return (FIRE, "max > 0") if max(values) > 0 else (QUIET, "max <= 0")


def decide(body: str | None) -> Decision:
    """The verdict plus the guard step's decision for it (retro-argo.yaml `retro-quiet-guard`).

    A QUIET verdict assumes the quiet push succeeds (the world's premise); a failed push is RETRO-GUARD-QUIET.
    """
    code, reason = verdict(body)
    if code == FIRE:
        return Decision(code, 0, False, "--no-ledger", reason)
    if code == QUIET:
        return Decision(code, 0, True, "no", reason)
    return Decision(code, 1, None, "no", reason)
