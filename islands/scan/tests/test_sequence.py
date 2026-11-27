"""The sequence driver and the recorded goal-checkpoint world (goal #3656 child 1): unlabelled — no row is proved here."""

import json
import sys
from pathlib import Path

from .sequence import Wake, derive_open_pr, run_sequence
from .world import World

REPO = "teststuffstash/homelab"
PR = "3270"
STANDIN = Path(__file__).resolve().parent / "standin.py"
MARKER = "🤖 `state-fp:goal-checkpoint-b:"


def standin(*args: str) -> list[str]:
    return [sys.executable, str(STANDIN), *args]


def read_wake(**kw) -> Wake:
    return Wake([standin("read", REPO, PR)], **kw)


def bodies(wake_result) -> list[str]:
    return json.loads(wake_result.outputs[0])


def recorded() -> list[str]:
    return [c["body"] for c in World("goal-checkpoint").get("api.issues.3270.comments@per_page=100.json", ())]


def test_the_recorded_assembly_pr_comments_hold_a_checkpoint_b_marker():
    found = [b for b in recorded() if b.startswith(MARKER)]
    assert found, "no recorded comment of #3270 starts with the goal-checkpoint-b marker"


def test_a_write_answered_201_appears_in_the_next_wakes_comments_read_with_the_body_sent():
    body = f"{MARKER}aaaaaaaaaaaa` — sent by the stand-in"
    r = run_sequence(World("goal-checkpoint"), [Wake([standin("write", REPO, PR, body)]), read_wake()])
    assert r.wakes[0].runs[0].rc == 0
    assert bodies(r.wakes[1]) == [*recorded(), body]
    (d,) = r.wakes[1].derived
    assert (d.kind, d.detail, d.index) == ("comment-overlay", body, len(recorded()))


def test_a_write_answered_403_does_not_appear_in_the_next_wake():
    w = World("goal-checkpoint").fault("create-comment", "status", status=403)
    r = run_sequence(w, [Wake([standin("write", REPO, PR, "refused")]), read_wake()])
    assert r.wakes[0].runs[0].rc != 0
    assert bodies(r.wakes[1]) == recorded()
    assert r.wakes[1].derived == []


def test_a_wake_with_no_write_adds_nothing():
    r = run_sequence(World("goal-checkpoint"), [read_wake(), read_wake()])
    assert bodies(r.wakes[0]) == bodies(r.wakes[1]) == recorded()
    assert r.wakes[1].derived == []


def test_a_write_the_case_did_not_expect_still_appears_in_the_next_wake():
    r = run_sequence(World("goal-checkpoint"), [Wake([standin("write", REPO, PR, "surprise")], expected_writes=[]), read_wake()])
    assert r.wakes[0].unexpected == ["surprise"]
    assert bodies(r.wakes[1])[-1] == "surprise"


def test_the_overlaid_element_is_a_copy_with_derived_identity():
    w = World("goal-checkpoint")
    run_sequence(w, [Wake([standin("write", REPO, PR, "x")]), read_wake()])
    items = w.get("api.issues.3270.comments@per_page=100.json", ())
    new, src = items[-1], items[0]
    assert set(new) == set(src) and new["body"] == "x"
    assert new["id"] > max(c["id"] for c in items[:-1]) and new["user"]["login"] != src["user"]["login"]
    assert new["created_at"] == new["updated_at"] and new["created_at"] not in {c["created_at"] for c in items[:-1]}


def test_a_derived_open_list_element_is_built_from_the_recorded_rest_read_and_marked_derived():
    w = World("goal-checkpoint")
    rest = w.get("api.pulls.3270.json", ())
    r = run_sequence(w, [Wake([standin("list-open", REPO)], setup=derive_open_pr)])
    listed = r.wakes[0].outputs[0].splitlines()
    assert listed[-1] == f"{rest['number']} {rest['head']['ref']}"
    assert len(listed) == len(w.get("pr-list.json", ()))
    added = w.get("pr-list.json", (len(listed) - 1,))
    assert added["number"] == rest["number"] and added["headRefName"] == rest["head"]["ref"] and added["body"] == rest["body"]
    (d,) = r.wakes[0].derived
    assert (d.kind, d.file, d.index) == ("open-list", "pr-list.json", len(listed) - 1)
    assert PR not in [x.split()[0] for x in World("goal-checkpoint").run(standin("list-open", REPO)).stdout.splitlines()]  # the world on disk is untouched
