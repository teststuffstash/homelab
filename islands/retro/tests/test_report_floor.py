"""RETRO-REPORT-FLOOR (specs/cell.md) — world cell-report-logs. Each case is green exactly when
(1) the fixture `retro-cell-report/<id>` is green against the old member (the oracle), (2) the NEW component
`retro_island.report_floor` gives the row's `reason?` / `rc?` cells, and (3) the old member run read-only on the
fixture's committed ride.log agrees with the new component: same rc, same reason line, same extracted bytes."""

import subprocess

import allure
import pytest
from conftest import FIXTURES, REPO, case_id, oracle_green, rule

from retro_island.report_floor import FLOOR, content_lines, is_reason, report_floor

pytestmark = rule("RETRO-REPORT-FLOOR")

FAMILY = "retro-cell-report"
OLD = REPO / "agents" / "retro-report-floor.sh"


def run_old(src, out, kind):
    """The old member, read-only: (rc, stderr reason line, extracted bytes or None)."""
    p = subprocess.run(["bash", str(OLD), str(src), str(out), kind], capture_output=True, text=True, check=False)
    return p.returncode, p.stderr.strip(), (out.read_bytes() if p.returncode == 0 else None)


def agree(tmp_path, text, kind, name="in.txt"):
    """New component vs old member on the same input; returns the new result."""
    src = tmp_path / name
    src.write_bytes(text.encode())
    rc, reason, body = run_old(src, tmp_path / "out.md", kind)
    new = report_floor(text, kind)
    if rc == 0:
        assert not is_reason(new) and new.encode() == body
    else:
        assert rc == 1 and new == reason
    return new


@pytest.mark.parametrize(
    "ride_log, expected_reason, expected_rc",
    [
        pytest.param("one block, a full report", None, 0, id="present"),
        pytest.param("no markers", "no-markers", 1, id="missing"),
        pytest.param("one block, 9 heading-only lines", "under-floor: 0 content lines < 20", 1, id="⚖ skeleton"),
        pytest.param("three empty echoes, then the real block", None, 0, id="multi-block"),
        pytest.param("a long marker-less transcript", "no-markers", 1, id="⚖ longlog"),
    ],
)
def test_report_floor(request, tmp_path, ride_log, expected_reason, expected_rc):
    row = case_id(request.node.callspec.id)
    allure.dynamic.parameter("world", "cell-report-logs")
    assert oracle_green(f"{FAMILY}/{row}", f"{FAMILY}-{row}"), f"replay fixture {FAMILY}/{row} is not green (or missing)"
    log = FIXTURES / FAMILY / row / "ride.log"
    text = log.read_bytes().decode()
    # (a) new component against the row's cells
    new = report_floor(text, "log")
    if expected_rc == 0:
        assert not is_reason(new)
    else:
        assert new == expected_reason
    # (b) old member on the committed ride.log, read in place: same rc, reason line, extracted bytes
    rc, reason, body = run_old(log, tmp_path / "out.md", "log")
    assert rc == expected_rc
    if rc == 0:
        assert new.encode() == body
    else:
        assert new == reason
    if row == "present":  # (c) the boundary: exactly 20 content lines, accepted
        assert content_lines(new) == FLOOR


def test_boundary_19_and_20(tmp_path):
    body = "".join(f"line {i}\n" for i in range(20))
    assert not is_reason(agree(tmp_path, body, "report"))
    assert agree(tmp_path, "".join(f"line {i}\n" for i in range(19)), "report") == "under-floor: 19 content lines < 20"


def test_definitions_match_old(tmp_path):
    filler = "".join(f"c {i}\n" for i in range(20))
    cases = [
        ("report", ""),
        ("report", "\n\n  \n"),
        ("report", "  # indented counts\n" + filler[:-4]),
        ("log", f"BEGIN-RETRO-REPORT\n{filler}"),  # two-marker rule: BEGIN only
        ("log", "BEGIN-RETRO-REPORT\nBEGIN-RETRO-REPORT\nx\n"),  # two BEGINs, no END
        ("log", f"END-RETRO-REPORT\n{filler}BEGIN-RETRO-REPORT\n"),  # END precedes every BEGIN → empty
        ("log", f"BEGIN-RETRO-REPORT\nEND-RETRO-REPORT\n{filler}"),
        ("log", f"x BEGIN-RETRO-REPORT\n{filler}END-RETRO-REPORT y\n"),  # marker strings anywhere in a line
        ("log", f"BEGIN-RETRO-REPORT\n{filler.rstrip()}\nEND-RETRO-REPORT\n"),
        # bare \r / \f / U+2028 are not line breaks for the old awk/grep member
        ("log", "BEGIN-RETRO-REPORT\n" + "progress 10%\rprogress 100%\n" * 10 + "x\n" * 5 + "END-RETRO-REPORT\n"),
        ("log", "BEGIN-RETRO-REPORT\n" + "a\fb\n" * 10 + "x\n" * 5 + "END-RETRO-REPORT\n"),
        ("log", "BEGIN-RETRO-REPORT\n" + "a\u2028b\n" * 10 + "x\n" * 5 + "END-RETRO-REPORT\n"),
        ("report", "a\rb\n" * 10 + "x\n" * 5),
    ]
    for kind, text in cases:
        agree(tmp_path, text, kind)
    assert report_floor("END-RETRO-REPORT\nBEGIN-RETRO-REPORT\n", "log") == "empty"
    cr = "BEGIN-RETRO-REPORT\n" + "progress 10%\rprogress 100%\n" * 10 + "x\n" * 5 + "END-RETRO-REPORT\n"
    assert report_floor(cr, "log") == "under-floor: 15 content lines < 20"


def test_bad_kind():
    with pytest.raises(ValueError):
        report_floor("x", "bogus")
