"""The old member, run read-only: the guard-expression parser and the replay family row."""

import subprocess

from conftest import REPO, family_rows


def old_verdict(body: str) -> int:
    """Exit code of the old parser on a response body."""
    return subprocess.run(["python3", "agents/retro_guard_expr.py"], cwd=REPO, input=body, capture_output=True, text=True, check=False).returncode


def old_family_row(row_id: str) -> str:
    """`green` / `red` / `missing` for the replay family's row `retro-quiet-guard/<row_id>`."""
    rows = family_rows("retro-quiet-guard")
    key = f"retro-quiet-guard/{row_id}"
    return "missing" if key not in rows else ("green" if rows[key] else "red")
