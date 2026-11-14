"""Checks of the gate itself — carry no rule() label."""

from __future__ import annotations

import re
import shutil
import subprocess

import pytest

from conftest import ISLAND, REPLAY, replay_row, rule

STUB = """\
gw_preflight_caller() { return 0; }
gw_admit() { return 0; }
gw_release() { return 0; }
"""


def _rows() -> list[str]:
    psv = REPLAY / "fixtures" / "gateway-admit" / "rows.psv"
    return [ln.split("|", 1)[0].strip() for ln in psv.read_text(encoding="utf-8").splitlines()
            if ln.strip() and not ln.startswith("#")]


def test_control_stub_target_fails_every_row(tmp_path) -> None:
    """The same family against a do-nothing stub passes only when all 12 rows FAIL."""
    stub = tmp_path / "gateway-admit.sh"
    stub.write_text(STUB, encoding="utf-8")
    rows = _rows()
    assert len(rows) == 12
    passed = [r for r in rows if replay_row(r, stub)[0]]
    assert passed == [], f"rows that still passed against the stub: {passed}"


def test_rule_refuses_an_id_with_no_spec_heading() -> None:
    with pytest.raises(ValueError, match=re.escape("LAUNCH-ADMIT-NOPE")):
        rule("LAUNCH-ADMIT-NOPE")


def test_island_helper_sources_silently_under_set_u() -> None:
    """Sourcing defines the functions, prints nothing, makes no request, never exits or traps."""
    script = (
        'set -u; trap - EXIT; . "$1"; '
        'for f in gw_preflight_caller gw_admit gw_release; do declare -F "$f" >/dev/null || exit 3; done; '
        '[ -n "$GW_URL" ] && [ -z "$GW_SESSION_ID" ] && [ -z "$GW_PULL_URL" ] || exit 4; '
        '[ -z "$(trap -p)" ] || exit 5; echo SURVIVED'
    )
    p = subprocess.run([shutil.which("bash") or "/bin/bash", "-c", script, "x", str(ISLAND / "lib" / "gateway-admit.sh")],
                       capture_output=True, text=True, check=False,
                       env={"PATH": "/nonexistent", "HOME": "/nonexistent"})
    assert p.returncode == 0 and p.stdout == "SURVIVED\n" and p.stderr == "", (p.returncode, p.stdout, p.stderr)


def test_island_helper_names_nothing_under_agents() -> None:
    text = (ISLAND / "lib" / "gateway-admit.sh").read_text(encoding="utf-8")
    assert "agents/gateway-admit.sh" not in text
    assert not re.search(r"^\s*(\.|source)\s+\S*agents/", text, re.M)
    assert not re.search(r"(^|[^\w-])agents/", text, re.M)
