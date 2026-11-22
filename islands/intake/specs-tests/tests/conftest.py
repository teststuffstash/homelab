"""Test chassis for island intake's spec root (the launch island's `tests/conftest.py` shape).

`rule("INTAKE-…")`: the Allure taxonomy (story == rule ID, epic == spec page) plus the `rule`
marker, and it REFUSES an id with no `### INTAKE-…` heading under `../specs/` (labels drift
silently, so this fails loudly at collection).
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import allure
import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

SPECS = HERE.parent.parent / "specs"

_RULE_RE = re.compile(r"^###\s+(INTAKE-[A-Z0-9-]+)\s*$")


def rule_pages() -> dict[str, str]:
    """rule id → spec page stem, from `### INTAKE-…` headings (outside code fences)."""
    index: dict[str, str] = {}
    for md in sorted(SPECS.rglob("*.md")):
        fenced = False
        for line in md.read_text(encoding="utf-8").splitlines():
            if line.startswith("```"):
                fenced = not fenced
            m = None if fenced else _RULE_RE.match(line)
            if m:
                index[m.group(1)] = md.relative_to(SPECS).with_suffix("").as_posix()
    return index


def rule(rule_id: str) -> list:
    """`@pytest.mark…` list: `pytest.param(…, marks=rule("INTAKE-ACCESS-GOAL-BRANCH"))`."""
    pages = rule_pages()
    if rule_id not in pages:
        known = ", ".join(sorted(pages)) or "<none>"
        raise ValueError(f"rule({rule_id!r}): no such `### {rule_id}` heading under specs/. Known: {known}")
    return [pytest.mark.rule(rule_id), allure.story(rule_id), allure.epic(pages[rule_id])]
