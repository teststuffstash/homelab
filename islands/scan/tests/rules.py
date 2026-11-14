"""The `rule()` marker: a spec requirement id, checked against the `### SCAN-…` headings under specs/.

A label naming no heading fails at COLLECTION (labels drift silently otherwise) — the gateway's
`rule` marker, reading this island's heading grammar.
"""

from __future__ import annotations

import re
from collections.abc import Callable
from functools import cache
from pathlib import Path
from typing import Any

import allure
import pytest

ISLAND = Path(__file__).resolve().parent.parent
SPECS = ISLAND / "specs"
_HEADING = re.compile(r"^#{2,4}[ \t]+(SCAN-[A-Z0-9][A-Z0-9-]*)[ \t]*$", re.MULTILINE)


@cache
def rule_ids() -> frozenset[str]:
    if not SPECS.is_dir():
        raise ValueError(f"rule(): {SPECS} is absent — the island's specs/ is the label source")
    return frozenset(m for md in sorted(SPECS.rglob("*.md")) for m in _HEADING.findall(md.read_text("utf-8")))


def rule(rule_id: str) -> Callable[[Any], Any]:
    if rule_id not in rule_ids():
        raise ValueError(
            f"rule({rule_id!r}): no such `### {rule_id}` heading in specs/ — labels drift silently, "
            f"so this fails loudly. Known: {sorted(rule_ids())}"
        )
    mark = pytest.mark.rule(rule_id)
    story = allure.story(rule_id)

    def apply(fn: Any) -> Any:
        return story(mark(fn))

    return apply
