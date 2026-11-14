"""The OLD scripts as replay subjects — the adapter's positive controls (and, later, the oracle's pair)."""

from __future__ import annotations

from .replay import FIXTURES, ROOT, Family, Row, subject_argv_from_env

MAJOR_HANDOFF_DIR = FIXTURES / "major-handoff"
UPDATER_DIR = FIXTURES / "updater"


def old_major_handoff(fam: Family, row: Row) -> list[str]:
    """`agents/major-handoff.sh <IN_SLUG> <IN_PR>`, argv from the fixture's env:."""
    return ["bash", str(ROOT / "agents" / "major-handoff.sh"), *subject_argv_from_env(fam, row, "IN_SLUG", "IN_PR")]


def old_updater(fam: Family, row: Row) -> list[str]:
    """`agents/update-pr-branch.sh teststuffstash/testrepo` (updater/bridge.sh:3)."""
    return ["bash", str(ROOT / "agents" / "update-pr-branch.sh"), "teststuffstash/testrepo"]

