"""The `gateway-admit` family run through `agents/replay/run.sh` from a throwaway copy of the harness.

`streams(target)` copies `agents/replay/` into a temp root, puts `target` at the old member's path
`agents/gateway-admit.sh`, empties the copy's expected-action templates (so run.sh prints what the
target DID instead of judging it against the recorded stream), runs the whole family once and returns
row id → action stream (run.sh's scrubbed `CALL` / `OUT` / `ERR` lines). The repo's `agents/` is
read, never written.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ISLAND = Path(__file__).resolve().parents[2]
REPO = ISLAND.parent.parent
REPLAY = REPO / "agents" / "replay"
FAMILY = "gateway-admit"
OLD_MEMBER = "agents/gateway-admit.sh"
COMPARE = Path(__file__).resolve().parent

def row_ids() -> list[str]:
    psv = REPLAY / "fixtures" / FAMILY / "rows.psv"
    return [ln.split("|", 1)[0].strip() for ln in psv.read_text(encoding="utf-8").splitlines()
            if ln.strip() and not ln.startswith("#")]


def streams(target: Path, extra_env: dict[str, str] | None = None) -> dict[str, list[str]]:
    import os

    with tempfile.TemporaryDirectory(prefix="launch-compare-") as tmp:
        root = Path(tmp)
        (root / "agents").mkdir()
        shutil.copytree(REPLAY, root / "agents" / "replay", symlinks=True)
        shutil.copyfile(target, root / OLD_MEMBER)
        fx = root / "agents" / "replay" / "fixtures" / FAMILY
        for tpl in (fx / "expected").glob("*.txt"):
            tpl.write_text("", encoding="utf-8")
        env = {**os.environ, "LAUNCH_COMPARE_DIR": str(COMPARE), "LAUNCH_PYTHON": sys.executable, "PYTHONPATH": str(ISLAND / "src"),
               **(extra_env or {})}
        proc = subprocess.run(["bash", str(root / "agents" / "replay" / "run.sh"), str(fx)],
                              cwd=root, capture_output=True, text=True, check=False, env=env)
    return parse(proc.stdout + proc.stderr)


def parse(out: str) -> dict[str, list[str]]:
    """run.sh prints a block per row (header, then the diff of an empty expectation against what the
    target did): the `+` lines of a block are that row's action stream."""
    result: dict[str, list[str]] = {}
    current: list[str] | None = None
    for line in out.splitlines():
        plain = re.sub(r"\x1b\[[0-9;]*m", "", line)
        m = re.match(rf"^\s*\S+ {FAMILY}/(?P<id>[A-Za-z0-9_-]+) ", plain)
        if m:
            current = result.setdefault(m["id"], [])
        elif current is not None and re.match(r"^ {8}\+(?!\+\+)", plain):
            current.append(plain[9:])
    return result
