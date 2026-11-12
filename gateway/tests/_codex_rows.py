"""Row helpers for the codex page's modules (specs/endpoints/openai-responses.md). The header is the
parameter list (CONVENTIONS § The intent column): every case is a `pytest.param` whose id is the
description cell and whose argnames are the header cells (`name?` ⇄ `expected_name`), so the
pinned join compares each cell to the recorded parameter. These helpers thread the columns:

- `row(**cells)` — a given step NAMED with every column and value, so each parameter threads the
  given phase and the report shows the row the case ran (no attachment: the name is the row);
- `verdicts(**columns)` — the row's `?` columns pronounced in ONE then step: one `verdict:` JSON
  keyed `expected_<column>` (the argname — the then phase threads by name even when the value is
  too short to, `—`, `0`) and one nested step per claim, so each column goes red or green on its
  own while the case stays within the report-hygiene marks (≲8 top-level steps, ≲8 attachments);
- `expect(column, actual, expected)` — one column alone, the same shape.
"""

from __future__ import annotations

from typing import Any

import allure

from .conftest import given, then


def row(**cells: Any) -> None:
    """The row as a given step NAMED with every column and value (the name is what threads)."""
    with given("row: " + " · ".join(f"{k}={v}" for k, v in cells.items())):
        pass


def verdicts(**columns: tuple[Any, Any]) -> None:
    """`column=(actual, expected)` per `?` column of the row."""
    text = " · ".join(f"{c}? = {e}" for c, (_, e) in columns.items())
    with then(text, **{f"expected_{c}": {"expected": e, "actual": a} for c, (a, e) in columns.items()}):
        failed = []
        for c, (a, e) in columns.items():
            with allure.step(f"{c}? = {e}"):
                if a != e:
                    failed.append(f"{c}?: expected {e!r}, got {a!r}")
                assert a == e, failed[-1] if failed else ""
        assert not failed, "; ".join(failed)


def expect(column: str, actual: Any, expected: Any, claim: str | None = None) -> None:
    text = claim or f"{column}? = {expected}"
    with then(text, **{f"expected_{column}": {"expected": expected, "actual": actual}}):
        assert actual == expected, f"{text}: got {actual!r}"


def joined(values, sep: str = " / ") -> str:
    """The cell spelling of a list of observed values, in order, duplicates folded."""
    return sep.join(dict.fromkeys(str(v) for v in values))
