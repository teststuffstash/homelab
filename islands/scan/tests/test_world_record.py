"""The recorded worlds and their recorder (goal #3490 pins 1, 2): unlabelled — they prove no row."""

import json
import re
import sys
from pathlib import Path

import pytest

from .world import ISLAND, WORLDS, UnrecordedCall, World, parse_provenance

RECORDER = ISLAND / "scripts" / "record_world.py"
RECORDED = ["pr-handoff", "pr-board", "pr-merges", "goal-checkpoint"]
REPO = "teststuffstash/homelab"

# GitHub's token formats (classic/OAuth/user-to-server/server-to-server/refresh `gh[opsur]_`, fine-grained
# `github_pat_`) and an Authorization header carrying a credential.
TOKEN = re.compile(r"\bgh[opsur]_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}")
AUTH_HEADER = re.compile(r"""(?i)["']?\bauthorization["']?\s*[:=]\s*["']?(?:bearer|token|basic)\s+[A-Za-z0-9+/=._-]{8,}""")


def leaks(text: str) -> list[str]:
    return [m.group(0)[:16] + "…" for m in (*TOKEN.finditer(text), *AUTH_HEADER.finditer(text))]


def world_files() -> list[Path]:
    return sorted(p for p in WORLDS.rglob("*") if p.is_file())


def test_no_world_file_holds_a_token_or_an_authorization_header():
    assert world_files(), "no file under specs/worlds/ — the scan below would pass on nothing"
    found = {str(p.relative_to(WORLDS)): leaks(p.read_text("utf-8", errors="replace")) for p in world_files()}
    assert not {k: v for k, v in found.items() if v}


@pytest.mark.parametrize(
    "text",
    [
        "ghp_" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8",
        '{"token":"ghs_' + "x" * 36 + '"}',
        "github_pat_" + "11ABCDEFG0" * 6,
        'Authorization: Bearer abcdefgh12345678',
        '{"authorization": "token 0123456789abcdef"}',
    ],
)
def test_the_token_scan_catches_a_planted_credential(text):
    assert leaks(text)  # the control: the scan above can fail


def _private_world(tmp_path: Path, private: bool) -> World:
    w = tmp_path / "visibility"
    w.mkdir()
    # hand-written: the two fields of GET /repos/{owner}/{repo} the recorder reads
    (w / "api.repo.json").write_text(json.dumps({"full_name": REPO, "private": private, "visibility": "private" if private else "public"}))
    (w / "provenance.yaml").write_text(f'reads:\n  - argv: ["api", "repos/{REPO}"]\n    file: "api.repo.json"\nwrites:\n')
    return World("visibility", root=tmp_path)


def test_recorder_refuses_a_private_repo_before_any_other_read(tmp_path):
    out = tmp_path / "out"
    run = _private_world(tmp_path, private=True).run([sys.executable, str(RECORDER), "pr-handoff", "3344", "--out", str(out)])
    assert run.rc != 0 and "is private" in run.stderr
    assert run.argvs == [["api", f"repos/{REPO}"]]
    assert not out.exists()


def test_recorder_goes_past_the_visibility_read_for_a_public_repo(tmp_path):
    # the control: with `private: false` the recorder issues its next read, which this world does not hold
    with pytest.raises(UnrecordedCall, match="gh pr view 3344"):
        _private_world(tmp_path, private=False).run([sys.executable, str(RECORDER), "pr-handoff", "3344", "--out", str(tmp_path / "out")])


@pytest.mark.parametrize("world", RECORDED)
def test_provenance_names_every_answer_file(world):
    d = WORLDS / world
    prov = parse_provenance((d / "provenance.yaml").read_text("utf-8"))
    assert prov["repo"] == REPO and prov["visibility"] == "public" and prov["world"] == world
    assert re.fullmatch(r"[0-9a-f]{40}", prov["recorder_commit"])
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", prov["recorded_at"]) and prov["items"]
    listed = {r["file"] for r in prov["reads"]}
    on_disk = {p.name for p in d.iterdir() if p.is_file() and p.name != "provenance.yaml"}
    assert listed == on_disk
    for read in prov["reads"]:
        json.loads((d / read["file"]).read_bytes())  # every recorded answer is the JSON gh printed
    for read in prov["reads"]:  # a read added after the whole recording carries its own time and recorder commit
        if "recorded_at" in read:
            assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", read["recorded_at"]) and re.fullmatch(r"[0-9a-f]{40}", read["recorder_commit"])
    declared = {f"{w['op']}.{s}.json" for w in prov["writes"] for s in w.get("statuses", [])}
    if prov["writes"]:
        assert re.fullmatch(r"[0-9a-f]{40}", prov["rest_description"]["commit"])
        assert {p.name for p in (d / "schemas").iterdir()} == declared
        assert {p.name for p in (d / "writes").iterdir()} == declared
    else:  # a world that declares no write has no description, no schemas/ and no writes/
        assert "rest_description" not in prov and not (d / "schemas").exists() and not (d / "writes").exists()


def _answer(world: str, file: str):
    return json.loads((WORLDS / world / file).read_text("utf-8"))


def _reads(world: str, pattern: str) -> list[str]:
    prov = parse_provenance((WORLDS / world / "provenance.yaml").read_text("utf-8"))
    return [r["file"] for r in prov["reads"] if re.fullmatch(pattern, r["file"])]


def test_every_list_a_first_leg_row_varies_holds_a_recorded_element():
    view = _answer("pr-handoff", _reads("pr-handoff", r"pr-view-\d+\.state,labels,reviews,commits\.json")[0])
    for key in ("labels", "reviews", "commits"):
        assert view[key], f"pr-handoff view: {key} is empty"
    assert _answer("pr-handoff", _reads("pr-handoff", r"api\.issues\.\d+\.labels\.json")[0])

    board = _answer("pr-board", "pr-list.json")
    assert len(board) >= 2, "pr-board's snapshot holds fewer than two pull requests"
    for key in ("labels", "reviews", "latestReviews"):
        assert any(pr[key] for pr in board), f"pr-board snapshot: no PR has a recorded {key} element"
    assert all(_answer("pr-board", f)["commits"] for f in _reads("pr-board", r"pr-view-\d+\.commits(,reviews)?\.json"))
    assert any(_answer("pr-board", f)["reviews"] for f in _reads("pr-board", r"pr-view-\d+\.commits,reviews\.json"))
    runs = _reads("pr-board", r"api\.commits\.[0-9a-f]{40}\.check-runs@per_page=100\.json")
    assert runs and any(_answer("pr-board", f)["check_runs"] for f in runs)



def _recorder_module():
    import importlib.util

    spec = importlib.util.spec_from_file_location("record_world", RECORDER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_recorder_fetches_the_board_snapshot_once_and_records_that_fetch(tmp_path):
    rw = _recorder_module()
    oid = "a" * 40
    plan = rw.plan_pr_board(["7"])
    snapshot_argv = plan.reads[0].argv
    w = tmp_path / "board-src"
    w.mkdir()
    reads = [(["api", f"repos/{REPO}"], {"private": False, "visibility": "public"}),
             (snapshot_argv, [{"number": 7, "headRefOid": oid}, {"number": 8, "headRefOid": "b" * 40}])]
    reads += [(argv, {"commits": [], "check_runs": [], "statuses": []}) for argv in rw.board_per_pr("7", oid)]
    lines = ["reads:"]
    for i, (argv, body) in enumerate(reads):
        (w / f"r{i}.json").write_text(json.dumps(body))
        lines += [f"  - argv: {json.dumps(argv)}", f'    file: "r{i}.json"']
    (w / "provenance.yaml").write_text("\n".join([*lines, "writes:"]) + "\n")
    # a hand-written description holding only the board's write operations (no download in the suite)
    ok = {"content": {"application/json": {"schema": {"type": "object"}}}}
    desc = {"paths": {f"/{x.op}": {"post": {"operationId": x.operation_id, "responses": dict.fromkeys(x.statuses, ok)}} for x in plan.writes},
            "components": {"schemas": {}, "responses": {}}}
    (tmp_path / "desc.json").write_text(json.dumps(desc))

    out = tmp_path / "out"
    run = World("board-src", root=tmp_path).run([sys.executable, str(RECORDER), "pr-board", "7", "--out", str(out),
                                                "--rest-description", "c" * 40, "--description-file", str(tmp_path / "desc.json")])
    assert run.rc == 0, run.stderr
    assert sum(1 for a in run.argvs if a[:2] == ["pr", "list"]) == 1  # one snapshot fetch per recording
    assert (out / "pr-board" / "pr-list.json").read_bytes() == (w / "r1.json").read_bytes()
    assert (out / "pr-board" / f"api.commits.{oid}.status.json").is_file()  # per-PR reads follow that snapshot's head
    assert len(run.argvs) == len(reads)  # every read once, nothing else


def test_add_pull_commits_issues_the_visibility_read_then_one_read_per_item(tmp_path):
    rw = _recorder_module()
    src = tmp_path / "add-src"
    src.mkdir()
    reads = [(["api", f"repos/{REPO}"], {"private": False, "visibility": "public"}),
             (rw.pull_commits_read("7"), [{"sha": "a" * 40, "parents": [{"sha": "b" * 40}]}]),
             (rw.pull_commits_read("8"), [{"sha": "c" * 40, "parents": []}])]
    lines = ["reads:"]
    for i, (argv, body) in enumerate(reads):
        (src / f"r{i}.json").write_text(json.dumps(body))
        lines += [f"  - argv: {json.dumps(argv)}", f'    file: "r{i}.json"']
    (src / "provenance.yaml").write_text("\n".join([*lines, "writes:"]) + "\n")
    out = tmp_path / "out"
    recorded = out / "pr-merges"
    recorded.mkdir(parents=True)
    (recorded / "pr-view-7.commits.json").write_text("{}")
    head = (
        '# Written by scripts/record_world.py — re-record, never hand-edit. Every value is JSON (valid YAML).\n'
        'world: "pr-merges"\nitems: [7, 8]\nrecorded_at: "2026-11-19T22:18:15Z"\nrecorder_commit: "' + "d" * 40 + '"\nreads:\n'
        f'  - argv: ["pr", "view", "7", "--repo", "{REPO}", "--json", "commits"]\n    file: "pr-view-7.commits.json"\n    auth: "token"\nwrites:\n'
    )
    (recorded / "provenance.yaml").write_text(head)
    run = World("add-src", root=tmp_path).run([sys.executable, str(RECORDER), "pr-merges", "--add", "pull-commits", "--out", str(out)])
    assert run.rc == 0, run.stderr
    assert run.argvs == [["api", f"repos/{REPO}"], rw.pull_commits_read("7"), rw.pull_commits_read("8")]
    text = (recorded / "provenance.yaml").read_text()
    assert text.startswith(head.split("writes:")[0])  # no existing line changes or moves
    assert text.endswith("writes:\n")
    prov = parse_provenance(text)
    added = prov["reads"][1:]
    assert [r["file"] for r in added] == ["api.pulls.7.commits@per_page=100.json", "api.pulls.8.commits@per_page=100.json"]
    assert all(re.fullmatch(r"[0-9a-f]{40}(-dirty)?", r["recorder_commit"]) and "recorded_at" in r and r["auth"] == "token" for r in added)
    assert (recorded / added[0]["file"]).read_bytes() == (src / "r1.json").read_bytes()
    assert prov["recorded_at"] == "2026-11-19T22:18:15Z" and prov["recorder_commit"] == "d" * 40


def test_add_pull_commits_refuses_a_private_repo_after_the_visibility_read_alone(tmp_path):
    out = tmp_path / "out"
    (out / "pr-merges").mkdir(parents=True)
    (out / "pr-merges" / "provenance.yaml").write_text('world: "pr-merges"\nitems: [7]\nreads:\nwrites:\n')
    run = _private_world(tmp_path, private=True).run([sys.executable, str(RECORDER), "pr-merges", "--add", "pull-commits", "--out", str(out)])
    assert run.rc != 0 and "is private" in run.stderr
    assert run.argvs == [["api", f"repos/{REPO}"]]


def test_the_recorded_pr_merges_world_holds_hand_titled_two_parent_merges():
    view = _answer("pr-merges", "pr-view-3615.commits.json")["commits"]
    listed = {e["sha"]: e for e in _answer("pr-merges", "api.pulls.3615.commits@per_page=100.json")}
    assert all(c["oid"] in listed for c in view)  # (a) every view commit has an element
    shapes = ("Merge branch ", "Merge remote-tracking branch ", "Merge pull request ")
    assert [c for c in view if len(listed[c["oid"]]["parents"]) >= 2 and not c["messageHeadline"].startswith(shapes)]  # (b)


def test_add_pull_commits_failing_second_read_leaves_the_world_byte_identical(tmp_path, monkeypatch):
    import argparse

    rw = _recorder_module()
    out = tmp_path / "out"
    recorded = out / "pr-merges"
    recorded.mkdir(parents=True)
    (recorded / "pr-view-7.commits.json").write_text("{}")
    (recorded / "provenance.yaml").write_text(
        'world: "pr-merges"\nitems: [7, 8, 9]\nreads:\n'
        f'  - argv: ["pr", "view", "7", "--repo", "{REPO}", "--json", "commits"]\n    file: "pr-view-7.commits.json"\n    auth: "token"\nwrites:\n'
    )
    before = {p.name: p.read_bytes() for p in recorded.iterdir()}
    monkeypatch.setattr(rw, "refuse_private", lambda repo: "public")
    monkeypatch.setattr(rw, "recorder_commit", lambda: "d" * 40)
    calls = []

    def perform(read):
        calls.append(read.argv)
        if len(calls) == 2:
            raise SystemExit("record_world: read failed")
        return b"[]"

    monkeypatch.setattr(rw, "perform", perform)
    args = argparse.Namespace(prs=[], world="pr-merges", out=str(out), add="pull-commits")
    with pytest.raises(SystemExit, match="read failed"):
        rw.add_pull_commits(args)
    assert len(calls) == 2
    assert {p.name: p.read_bytes() for p in recorded.iterdir()} == before
