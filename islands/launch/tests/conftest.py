"""Test chassis for the launch island (homelab#3392; the gateway's `tests/conftest.py` shape).

- `rule("LAUNCH-…")`: the Allure taxonomy (story == rule ID, epic == spec page) plus the `rule`
  marker, and it REFUSES an id with no `### LAUNCH-…` heading under `specs/` (labels drift silently,
  so this fails loudly at collection).
- The replay comparison's throwaway harness copy lives in `compare/harness.py`; nothing here writes
  under `agents/`.
"""

from __future__ import annotations

import re
from pathlib import Path

import allure
import pytest

ISLAND = Path(__file__).resolve().parent.parent
REPO = ISLAND.parent.parent
SPECS = ISLAND / "specs"

_RULE_RE = re.compile(r"^###\s+(LAUNCH-[A-Z0-9-]+)\s*$")


def rule_pages() -> dict[str, str]:
    """rule id → spec page stem, from `### LAUNCH-…` headings (outside code fences)."""
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
    """`@pytest.mark…` list: `pytestmark = rule("LAUNCH-ADMIT-HELPER")`."""
    pages = rule_pages()
    if rule_id not in pages:
        known = ", ".join(sorted(pages)) or "<none>"
        raise ValueError(f"rule({rule_id!r}): no such `### {rule_id}` heading under specs/. Known: {known}")
    return [pytest.mark.rule(rule_id), allure.story(rule_id), allure.epic(pages[rule_id])]


def pytest_collection_modifyitems(items):
    """Each labelled case id appears exactly once among the rule()-labelled items."""
    seen: dict[str, str] = {}
    for item in items:
        if item.get_closest_marker("rule") is None or not hasattr(item, "callspec"):
            continue
        case_id = item.callspec.id
        if case_id in seen:
            raise pytest.UsageError(f"labelled case id {case_id!r} appears twice: {seen[case_id]} and {item.nodeid}")
        seen[case_id] = item.nodeid
