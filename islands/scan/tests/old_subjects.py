"""The OLD scripts as replay subjects — the adapter's positive controls (and, later, the oracle's pair)."""

from __future__ import annotations

import atexit
import shutil
import tempfile
from pathlib import Path

from .replay import FIXTURES, ROOT, Family, Row, subject_argv_from_env

MAJOR_HANDOFF_DIR = FIXTURES / "major-handoff"
UPDATER_DIR = FIXTURES / "updater"


def old_major_handoff(fam: Family, row: Row) -> list[str]:
    """`agents/major-handoff.sh <IN_SLUG> <IN_PR>`, argv from the fixture's env:."""
    return ["bash", str(ROOT / "agents" / "major-handoff.sh"), *subject_argv_from_env(fam, row, "IN_SLUG", "IN_PR")]


def old_updater(fam: Family, row: Row) -> list[str]:
    """`agents/update-pr-branch.sh teststuffstash/testrepo` (updater/bridge.sh:3)."""
    return ["bash", str(ROOT / "agents" / "update-pr-branch.sh"), "teststuffstash/testrepo"]



GOAL_DIR = FIXTURES / "goal"
_COMPOSED: dict[str, Path] = {}


def _extract(marker: str, source: Path) -> str:
    """`run.sh`'s `extract`: the lines between `# >>>REPLAY:<marker>>>>` and `# <<<REPLAY:<marker><<<`, leading blanks trimmed on the sentinels only."""
    out, inside, opened, closed = [], False, False, False
    for line in source.read_text("utf-8").splitlines():
        s = line.lstrip(" \t")
        if s == f"# >>>REPLAY:{marker}>>>":
            inside = opened = True
        elif s == f"# <<<REPLAY:{marker}<<<":
            inside, closed = False, True
        elif inside:
            out.append(line)
    if not (opened and closed):
        raise AssertionError(f"sentinel {marker} missing from {source}")
    return "\n".join(out) + "\n" if out else ""


def old_goal(fam: Family, row: Row) -> list[str]:
    """The `goal` family's clause, composed as `agents/replay/run.sh` composes it (`set -euo pipefail`, the source's
    config-defaults block, then the family's `parts:` in order), run with bash. The composed script is the same for every row."""
    if "goal" not in _COMPOSED:
        source = ROOT / fam.scalars["source"]
        text = "set -euo pipefail\n" + _extract("config-defaults", source) + "\n"
        for part in fam.lists["parts"]:
            kind, _, name = part.partition(":")
            text += (_extract(name, source) if kind == "block" else (fam.dir / name).read_text("utf-8")) + "\n"
        d = Path(tempfile.mkdtemp(prefix="old-goal-"))
        atexit.register(shutil.rmtree, d, ignore_errors=True)
        (d / "composed.sh").write_text(text, "utf-8")
        _COMPOSED["goal"] = d / "composed.sh"
    return ["bash", str(_COMPOSED["goal"])]
