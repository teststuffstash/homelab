"""The standing differences between the old member and the new component (rulings.json).

An entry: requirement, case, old, new, ruling (`spec` | `old`), why. The comparison is red on a
difference with no entry and on an entry with no difference.
"""

import json
from pathlib import Path

RULINGS = Path(__file__).with_name("rulings.json")
FIELDS = {"requirement", "case", "old", "new", "ruling", "why"}


def load() -> list[dict]:
    entries = json.loads(RULINGS.read_text(encoding="utf-8"))
    assert isinstance(entries, list)
    for e in entries:
        assert set(e) == FIELDS, f"rulings.json entry fields {sorted(e)} != {sorted(FIELDS)}"
        assert e["ruling"] in ("spec", "old"), f"ruling must be spec|old: {e['case']!r}"
    return entries


def check(requirement: str, case: str, old: str, new: str) -> None:
    """Assert old/new agree, or agree with exactly one ruled entry for (requirement, case)."""
    entries = [e for e in load() if e["requirement"] == requirement and e["case"] == case]
    assert len(entries) <= 1, f"two rulings for {requirement} {case!r}"
    if old == new:
        assert not entries, f"ruling for {requirement} {case!r} but old == new == {old!r}: remove the entry"
    else:
        assert entries, f"unruled difference {requirement} {case!r}: old {old!r} new {new!r}"
        assert (entries[0]["old"], entries[0]["new"]) == (old, new), f"ruling for {case!r} states old/new that differ from the run: {old!r} / {new!r}"


def check_known(requirement: str, cases: set[str]) -> None:
    for e in load():
        if e["requirement"] == requirement:
            assert e["case"] in cases, f"ruling for unknown {requirement} case {e['case']!r}"
