"""Test chassis for the retro island.

- `rule("RETRO-…")`: the Allure taxonomy (story == rule id, epic == spec page) plus the `rule`
  marker. Fails at COLLECTION, naming the id, when `specs/` has no `## <id>` heading (the
  gateway/tests/conftest.py shape).
- `family_rows()`: the replay ORACLE. Runs `bash agents/replay/run.sh <fixture dir>` read-only
  against the old member and returns `{row id: green?}` from the run's per-row lines. Nothing
  under `agents/` is edited, copied or patched.
"""

from __future__ import annotations

import functools
import re
import subprocess
from pathlib import Path

import allure
import pytest

ISLAND = Path(__file__).resolve().parent.parent
REPO = ISLAND.parent.parent
SPECS = ISLAND / "specs"
FIXTURES = REPO / "agents" / "replay" / "fixtures"

_HEAD_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*$")
_RULE_RE = re.compile(r"^##\s+(RETRO-[A-Z0-9-]+)\s*$")
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
_ROW_RE = re.compile(r"^\s*([✓✗])\s+(\S+)\s+\(")


@functools.cache
def rule_pages() -> dict[str, str]:
    """rule id → spec page stem, from the `## RETRO-…` headings of specs/*.md."""
    index: dict[str, str] = {}
    for md in sorted(SPECS.glob("*.md")):
        for line in md.read_text(encoding="utf-8").splitlines():
            m = _RULE_RE.match(line)
            if m:
                index[m.group(1)] = md.stem
    return index


def rule(rule_id: str) -> list:
    """`pytestmark = rule("RETRO-GUARD-EXPR")` module-wide."""
    pages = rule_pages()
    if rule_id not in pages:
        known = ", ".join(sorted(pages)) or "<none>"
        raise ValueError(f"rule({rule_id!r}): no such `## {rule_id}` heading in specs/ — labels drift silently, so this fails loudly. Known: {known}")
    return [pytest.mark.rule(rule_id), allure.story(rule_id), allure.epic(pages[rule_id])]


@functools.cache
def family_rows(fixture: str) -> dict[str, bool]:
    """Run the replay oracle on `agents/replay/fixtures/<fixture>` (a family or one case dir) and
    return {row id (`<family>/<case>` as printed): green}. A failing run still yields its rows."""
    proc = subprocess.run(
        ["bash", "agents/replay/run.sh", f"agents/replay/fixtures/{fixture}"],
        cwd=REPO, capture_output=True, text=True, check=False,
    )
    rows: dict[str, bool] = {}
    for line in _ANSI_RE.sub("", proc.stdout).splitlines():
        m = _ROW_RE.match(line)
        if m:
            rows[m.group(2)] = m.group(1) == "✓"
    return rows


def oracle_green(fixture: str, row_id: str) -> bool:
    """Is `row_id` present in the fixture's run output AND green? Missing row → False."""
    return family_rows(fixture).get(row_id, False)


def case_id(description: str) -> str:
    """The row's id as the replay names it: the spec cell without its `⚖ `."""
    return description.removeprefix("⚖ ")
