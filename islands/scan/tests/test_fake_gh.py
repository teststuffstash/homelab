"""The island's fake `gh` over a recorded world (goal #3490 pins 4–6): unlabelled — it proves no row.

Each test drives `gh` itself as the process, through `tests/world.py`, so what is asserted is what a
component would see on its stdout, stderr and exit status.
"""

import json
import sys

import pytest

from .world import WORLDS, OverrideRefused, UnrecordedCall, World

REPO = "teststuffstash/homelab"
HANDOFF_VIEW = "pr-view-3344.state,labels,reviews,commits.json"
HANDOFF_VIEW_ARGV = ["gh", "pr", "view", "3344", "--repo", REPO, "--json", "state,labels,reviews,commits"]


def board_list_argv() -> list[str]:
    reads = World("pr-board").provenance["reads"]
    return ["gh", *next(r["argv"] for r in reads if r["file"] == "pr-list.json")]


# 1 — a recorded read is answered with the file's bytes


@pytest.mark.parametrize("world", ["pr-handoff", "pr-board"])
def test_recorded_read_answers_the_file_bytes(world):
    w = World(world)
    for read in w.provenance["reads"]:
        run = w.run(["gh", *read["argv"]])
        assert run.rc == 0, run.stderr
        assert run.stdout.encode() == (WORLDS / world / read["file"]).read_bytes(), read["file"]
    assert [c["argv"] for c in run.calls] == [w.provenance["reads"][-1]["argv"]]  # one log line per call, this run's only


def test_jq_is_applied_over_the_recorded_answer():
    run = World("pr-handoff").run(["gh", "api", f"repos/{REPO}/issues/3344/labels", "--jq", ".[].name"])
    # api.issues.3344.labels.json holds dependencies, major, major/awaiting-human, in that order
    assert (run.rc, run.stdout) == (0, "dependencies\nmajor\nmajor/awaiting-human\n")


# 2 — an unrecorded read exits non-zero, names the read, and fails the case


def test_unrecorded_read_fails_the_case():
    argv = ["gh", "pr", "view", "3344", "--repo", REPO, "--json", "state,labels"]  # a field list the world never read
    with pytest.raises(UnrecordedCall, match=r"gh pr view 3344 --repo teststuffstash/homelab --json state,labels"):
        World("pr-handoff").run(argv)
    # the fake itself, run under a shell that tolerates the failure, still exits non-zero and names the read
    with pytest.raises(UnrecordedCall) as e:
        World("pr-handoff").run(["sh", "-c", 'gh "$@"; echo "rc=$?"', "sh", *argv[1:]])
    assert "unrecorded read" in str(e.value) and "--json state,labels" in str(e.value)


def test_undeclared_write_fails_the_case():
    with pytest.raises(UnrecordedCall, match="gh pr comment 3344"):
        World("pr-handoff").run(["gh", "pr", "comment", "3344", "--repo", REPO, "--body", "x"])


# 3 — value overrides: a field that exists changes, a list gains a copied element; nothing else


def test_override_changes_an_existing_value_and_copies_a_list_element():
    w = World("pr-handoff")
    w.set(HANDOFF_VIEW, ("state",), "OPEN")
    w.add(HANDOFF_VIEW, ("labels",), copy_of=0, changes={("name",): "agent/in-progress"})
    data = json.loads(w.run(HANDOFF_VIEW_ARGV).stdout)
    recorded = json.loads((WORLDS / "pr-handoff" / HANDOFF_VIEW).read_text())
    assert data["state"] == "OPEN" and recorded["state"] == "MERGED"
    assert [lb["name"] for lb in data["labels"]] == [lb["name"] for lb in recorded["labels"]] + ["agent/in-progress"]
    assert set(data["labels"][-1]) == set(recorded["labels"][0])  # the copy has the recorded element's fields


@pytest.mark.parametrize(
    "path, value, why",
    [
        (("mergedBy",), "x", "has no field"),  # the view never asked for mergedBy
        (("labels", 0, "colour"), "x", "has no field"),
        (("labels", 9), {"name": "x"}, "has no field"),
        (("reviews", 0, "author"), {}, "removes field"),
        (("labels", 0), {"name": "major"}, "removes field"),
        (("labels",), [{"name": "major"}], "removes field"),
        (("commits",), None, "removes its fields"),
    ],
)
def test_override_refuses_a_missing_or_removed_field(path, value, why):
    with pytest.raises(OverrideRefused, match=why):
        World("pr-handoff").set(HANDOFF_VIEW, path, value)


# 4 — a fault on one call: a failing read, a non-JSON body, one field absent, a write's hand-written error


def test_fault_failing_read_hits_only_the_named_occurrence():
    w = World("pr-handoff").fault(HANDOFF_VIEW, "fail", occurrence=2)
    run = w.run(["sh", "-c", 'for i in 1 2 3; do gh "$@" >/dev/null; echo "rc=$?"; done', "sh", *HANDOFF_VIEW_ARGV[1:]])
    assert run.stdout == "rc=0\nrc=1\nrc=0\n"
    assert [c.get("fault") for c in run.calls] == [None, "fail", None]


def test_fault_non_json_body():
    run = World("pr-handoff").fault(HANDOFF_VIEW, "non-json").run(HANDOFF_VIEW_ARGV)
    assert run.rc == 0
    with pytest.raises(ValueError):
        json.loads(run.stdout)


def test_fault_one_named_field_absent():
    run = World("pr-board").fault("pr-list.json", "absent", field=(0, "labels")).run(board_list_argv())
    data = json.loads(run.stdout)
    recorded = json.loads((WORLDS / "pr-board" / "pr-list.json").read_text())
    assert "labels" not in data[0] and set(data[0]) == set(recorded[0]) - {"labels"}
    assert data[1:] == recorded[1:]


@pytest.mark.parametrize(
    "world, op, argv, status, message",
    [
        ("pr-board", "update-branch", ["api", "-X", "PUT", f"repos/{REPO}/pulls/3147/update-branch", "-f", "expected_head_sha=0"], 422, "expected head sha"),
        ("pr-handoff", "remove-label", ["api", "-X", "DELETE", f"repos/{REPO}/issues/3344/labels/agent%2Fin-progress"], 404, "Label does not exist"),
    ],
)
def test_fault_write_answers_a_hand_written_error(world, op, argv, status, message):
    run = World(world).fault(op, "status", status=status).run(["gh", *argv])
    body = json.loads((WORLDS / world / "writes" / f"{op}.{status}.json").read_text())
    assert run.rc == 1
    assert json.loads(run.stdout) == body and message in body["message"]
    assert f"(HTTP {status})" in run.stderr and body["message"] in run.stderr
    assert run.calls == [{"argv": argv, "kind": "write", "op": op, "fault": "status", "rc": 1}]


def test_write_answers_its_hand_written_success_and_is_logged():
    argv = ["api", "-X", "POST", f"repos/{REPO}/issues/3344/labels", "-f", "labels[]=major/awaiting-human"]
    run = World("pr-handoff").run(["gh", *argv])
    assert run.rc == 0
    assert json.loads(run.stdout) == json.loads((WORLDS / "pr-handoff" / "writes" / "add-labels.200.json").read_text())
    assert run.calls == [{"argv": argv, "kind": "write", "op": "add-labels", "rc": 0}]


def test_fault_on_an_unknown_target_or_status_is_refused():
    with pytest.raises(ValueError, match="no read file or write op"):
        World("pr-handoff").fault("pr-view-1.json", "fail")
    with pytest.raises(ValueError, match="no hand-written 500"):
        World("pr-handoff").fault("remove-label", "status", status=500)
    with pytest.raises(OverrideRefused, match="has no field"):
        World("pr-handoff").fault(HANDOFF_VIEW, "absent", field=("nope",))


# the worlds serve the first leg's components (the recorder's argv are the components' argv)


def test_pr_handoff_serves_the_major_handoff_gate_and_arm_paths():
    gate = World("pr-handoff").set(HANDOFF_VIEW, ("state",), "OPEN")
    run = gate.run([sys.executable, "-m", "scan_island.major_handoff", REPO, "3344"])
    # the recorded APPROVED (15:35:56Z) post-dates the newest content commit (14:36:46Z; later ones are merges)
    # and carries the four headings, so the handoff writes and re-reads the labels
    assert run.rc == 0, run.stdout + run.stderr
    assert [c.get("op", c.get("file")) for c in run.calls] == [HANDOFF_VIEW, "add-labels", "remove-label", "api.issues.3344.labels.json"]

    arm = World("pr-handoff").set(HANDOFF_VIEW, ("state",), "OPEN")
    body = json.loads((WORLDS / "pr-handoff" / HANDOFF_VIEW).read_text())["reviews"][1]["body"]
    arm.set(HANDOFF_VIEW, ("reviews", 1, "body"), body + "\n\nappVersion: unchanged\n")
    run = arm.run([sys.executable, "-m", "scan_island.major_handoff", REPO, "3344"])
    assert run.rc == 0, run.stdout + run.stderr
    assert [c.get("op", c.get("file")) for c in run.calls] == [HANDOFF_VIEW, "pr-merge-auto", "remove-label", "writes/get-pull-after-arm.200.json"]


def test_pr_board_serves_the_updater_pick_and_unstrand_reads():
    w = World("pr-board")
    board = json.loads((WORLDS / "pr-board" / "pr-list.json").read_text())
    mine, other = (next(i for i, pr in enumerate(board) if pr["number"] == n) for n in (3557, 3147))
    armed = {"authorEmail": None, "commitBody": None, "commitHeadline": None, "enabledAt": "2026-11-19T23:00:00Z",
             "enabledBy": {"login": "RasmusSoot"}, "mergeMethod": "SQUASH"}
    for i, decision in ((mine, "APPROVED"), (other, "CHANGES_REQUESTED")):
        w.set("pr-list.json", (i, "autoMergeRequest"), armed)
        w.set("pr-list.json", (i, "mergeStateStatus"), "BEHIND")
        w.set("pr-list.json", (i, "reviewDecision"), decision)
    w.set("pr-list.json", (mine, "author", "login"), "app/homelab-renovate-1234")  # the Renovate probe: commits + check-runs + status
    run = w.run([sys.executable, "-m", "scan_island.updater", REPO])
    assert run.rc == 0, run.stdout + run.stderr
    oid = board[mine]["headRefOid"]
    assert [c.get("op", c.get("file")) for c in run.calls] == [
        "pr-list.json",
        "pr-view-3557.commits.json",
        f"api.commits.{oid}.check-runs@per_page=100.json",
        f"api.commits.{oid}.status.json",
        "update-branch",
        "pr-view-3147.commits,reviews.json",  # leg 2: no bot verdict recorded on #3147 → no update
    ]
    assert "updating #3557 (oldest armed+BEHIND, FIFO)" in run.stdout


@pytest.mark.parametrize("kind, extra", [("non-json", {}), ("absent", {"field": (0,)})])
def test_a_write_refuses_a_fault_it_cannot_answer(kind, extra):
    # a write is answered by a hand-written file or an exit status: only `fail` and `status` replace that
    with pytest.raises(ValueError, match="takes only a `fail` or `status` fault"):
        World("pr-board").fault("update-branch", kind, **extra)
    with pytest.raises(ValueError, match="takes only a `fail` or `status` fault"):
        World("pr-handoff").fault("pr-merge-auto", kind, **extra)


def test_fault_failing_write():
    argv = ["api", "-X", "PUT", f"repos/{REPO}/pulls/3147/update-branch", "-f", "expected_head_sha=0"]
    run = World("pr-board").fault("update-branch", "fail").run(["gh", *argv])
    assert (run.rc, run.stdout) == (1, "") and "(HTTP 502)" in run.stderr
    assert run.calls == [{"argv": argv, "kind": "write", "op": "update-branch", "fault": "fail", "rc": 1}]
