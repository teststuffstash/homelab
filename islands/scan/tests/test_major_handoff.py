"""The major handoff contract, exercised through the recorded replay worlds."""

import sys

import allure
import pytest

from .old_subjects import MAJOR_HANDOFF_DIR
from .replay import load_family, load_rows, row_verdict, subject_argv_from_env
from .rules import rule

FAMILY = load_family(MAJOR_HANDOFF_DIR)
ROWS = load_rows(FAMILY)
ARM = {"packaging-only-arms", "app-moves-parks"}


def cases(ids):
    return [pytest.param(row, id=row.id) for row in ROWS if row.id in ids]


def check(row):
    with allure.step(f"Given replay world {row.world} and row {row.id}"):
        argv = subject_argv_from_env(FAMILY, row, "IN_SLUG", "IN_PR")
    with allure.step("When the island gate runs, its action stream matches the recorded verdict"):
        result = row_verdict(FAMILY, row, [sys.executable, "-m", "scan_island.major_handoff", *argv])
        assert result is None, result


@rule("SCAN-HANDOFF-GATE")
@pytest.mark.parametrize("row", cases({r.id for r in ROWS} - ARM - {"handoff-graphql-drained"}))
def test_gate(row):
    check(row)


@rule("SCAN-HANDOFF-ARM")
@pytest.mark.parametrize("row", cases(ARM))
def test_arm(row):
    check(row)


@pytest.mark.parametrize("row", cases({"handoff-graphql-drained"}))
def test_family_completeness(row):
    check(row)


# Behaviours of agents/major-handoff.sh that no replay row can express (reviewer, PR #3411).
def _fake_gh(monkeypatch, body, delete_stderr=""):
    import json
    import subprocess

    from scan_island import gh

    pr = {
        "state": "OPEN",
        "labels": [{"name": "major"}],
        "reviews": [{"author": {"login": "homelab-reviewer"}, "state": "APPROVED", "submittedAt": "2026-09-25T12:00:00Z", "body": body}],
        "commits": [{"committedDate": "2026-09-25T11:00:00Z", "messageHeadline": "bump"}],
    }
    calls = []

    def run(*args):
        calls.append(args)
        out, err, rc = "", "", 0
        if args[0] == "pr" and args[1] == "view":
            out = json.dumps(pr)
        elif args[:3] == ("api", "-X", "DELETE") and delete_stderr:
            err, rc = delete_stderr, 1
        elif args[0] == "api" and "--jq" in args:
            out = "true " if args[1].startswith("repos/o/r/pulls") else "major/awaiting-human\n"
        return subprocess.CompletedProcess(["gh", *args], rc, out, err)

    monkeypatch.setattr(gh, "run", run)
    return calls


HEADINGS = "## Upstream\n## Known issues\n## Platform compatibility\n## Evidence\n"
ABSENT = "gh: Label does not exist (HTTP 404)"


@pytest.mark.parametrize("extra", ["", "appVersion: unchanged\n"], ids=["park", "arm"])
def test_absent_claim_label_is_success(monkeypatch, extra):
    from scan_island import major_handoff

    _fake_gh(monkeypatch, HEADINGS + extra, ABSENT)
    assert major_handoff.main("o/r", "1") == 0


def test_other_delete_failure_still_exits_5(monkeypatch):
    from scan_island import major_handoff

    _fake_gh(monkeypatch, HEADINGS, "gh: Server Error (HTTP 500)")
    assert major_handoff.main("o/r", "1") == 5


@pytest.mark.parametrize("extra", ["", "appVersion: unchanged\r\n"], ids=["park", "arm"])
def test_crlf_body_is_handed_off(monkeypatch, extra):
    from scan_island import major_handoff

    _fake_gh(monkeypatch, (HEADINGS + extra).replace("\n", "\r\n"))
    assert major_handoff.main("o/r", "1") == 0
