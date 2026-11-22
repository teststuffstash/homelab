"""Test chassis for the launch island (homelab#3392; the gateway's `tests/conftest.py` shape).

- `rule("LAUNCH-…")`: the Allure taxonomy (story == rule ID, epic == spec page) plus the `rule`
  marker, and it REFUSES an id with no `### LAUNCH-…` heading under `specs/` (labels drift silently,
  so this fails loudly at collection).
- The overlay: a replay row runs through `agents/replay/run.sh` executed from a throwaway copy of
  `agents/replay/` in which `agents/gateway-admit.sh` holds the file under test. `run.sh` derives its
  root from its own location, so the copy's root IS the overlay; nothing under `agents/` is written.
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import allure
import pytest

ISLAND = Path(__file__).resolve().parent.parent
REPO = ISLAND.parent.parent
SPECS = ISLAND / "specs"
REPLAY = REPO / "agents" / "replay"
OLD_MEMBER = "agents/gateway-admit.sh"

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


def replay_row(row_id: str, target: Path, fixture: str = "gateway-admit") -> tuple[bool, str]:
    """Run ONE row of `fixture` through run.sh from an overlay whose old-member path holds `target`.

    The copy's rows.psv keeps only the named row (so the verdict turns on that row alone). Returns
    (the row passed, run.sh's combined output). Never writes under the repo's agents/.
    """
    import tempfile

    with tempfile.TemporaryDirectory(prefix="launch-overlay-") as tmp:
        root = Path(tmp)
        (root / "agents").mkdir()
        shutil.copytree(REPLAY, root / "agents" / "replay", symlinks=True)
        shutil.copyfile(target, root / OLD_MEMBER)
        fx = root / "agents" / "replay" / "fixtures" / fixture
        psv = fx / "rows.psv"
        kept = [
            ln for ln in psv.read_text(encoding="utf-8").splitlines()
            if ln.startswith("#") or not ln.strip() or ln.split("|", 1)[0].strip() == row_id
        ]
        psv.write_text("\n".join(kept) + "\n", encoding="utf-8")
        proc = subprocess.run(
            ["bash", str(root / "agents" / "replay" / "run.sh"), str(fx)],
            cwd=root, capture_output=True, text=True, check=False,
        )
        out = proc.stdout + proc.stderr
    passed = proc.returncode == 0 and f"{fixture}/{row_id} " in out and "1 passed, 0 failed" in out
    return passed, out
