"""The trigger (b) hold of SCAN-CLAUSE-GOAL, its rows read from the page over the recorded world `goal-checkpoint`.

Every row of the (b) table is one case (goal #3656 child 2): the description cell is the case id verbatim,
every other header cell a parameter whose value is the row's cell verbatim (CONVENTIONS § The intent column).
The cells are decoded HERE, against the page's two legends, into value overrides on `goal-checkpoint`. A case
runs one wake through the sequence driver (`evaluate`, then `dispatch` only when this Goal won the lane), then
the next wake's `evaluate` on what the driver carried forward — the marker writes the first wake ACTUALLY
issued — with the fault gone, and compares the three expected cells with what the processes did.

The base state is the page's `**World:**` sentence: Goal #3118 with its pre-launch child set complete (a case
input, nothing here computes it); `A` is the open element derived for #3270, `B` another derived element.
"""

from __future__ import annotations

import json
import re
import sys
from collections.abc import Callable
from pathlib import Path

import allure
import pytest

from scan_island.checkpoint_b import marker

from .page import params as page_params
from .page import tables, ticks
from .rules import SPECS, rule
from .sequence import Derived, Wake, derive_open_pr, overlay, run_sequence
from .world import World

PAGE = SPECS / "scan-decision.md"
HAND = Path(__file__).resolve().parent.parent / "trial" / "checkpoint-b-hand.md"  # the hand-authored arm, outside the specs root
SCHEMA = SPECS / "scan-decision.schema.json"
QUESTION = "Does trigger (b) fire while an assembly pull request is open?"
COMPONENT = [sys.executable, "-m", "scan_island.checkpoint_b"]
MUTANTS = Path(__file__).resolve().parent / "mutants"
MUTANT = [sys.executable, str(MUTANTS / "checkpoint_b_stamp_on_evaluate.py")]
CHURN_MUTANT = [sys.executable, str(MUTANTS / "checkpoint_b_release_on_churn.py")]

def _load_script(name: str, path: Path):
    import importlib.util

    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _load_render():
    return _load_script("render_model", HAND.parent.parent / "scripts" / "render_model.py")


TABLES = tables(PAGE)  # the page's (b) table is rendered from the YAML model (arm `model`)
ARGS, ROWS = page_params(TABLES, QUESTION)
HAND_ARGS, HAND_ROWS = page_params(tables(HAND), QUESTION)  # arm `hand`
assert HAND_ARGS == ARGS
ARMS = {"model": ROWS, "hand": HAND_ROWS}
[READ_LEGEND] = [{r[0]: r[1:] for r in rows} for _q, h, rows in TABLES if h[0] == "literal" and len(h) == 4 and h[1].startswith("stdout")]
[WRITE_LEGEND] = [{r[0]: r[1] for r in rows} for _q, h, rows in TABLES if h[0] == "literal" and len(h) == 2 and h[1].startswith("comment writes")]

WORLD = "goal-checkpoint"
_PROBE = World(WORLD)
REPO = _PROBE.provenance["repo"]
GOAL = "3118"
A = 3270  # the derived open element: #3270's number, head branch and body from the recorded REST read
B = 3271  # a second derived element: another number
COMMENTS = "api.issues.3270.comments@per_page=100.json"
STAMP = "🤖 `state-fp:goal-checkpoint-b:"


def comments_path(n: int) -> str:
    return f"repos/{REPO}/issues/{n}/comments?per_page=100"


def number(letter: str) -> int:
    return {"A": A, "B": B}[letter]


# ── the decoders: one cell → state on the world ───────────────────────────────────────────────────


def neutralise(w: World) -> None:
    """No comment of the recorded list starts with a (b) marker: the ten recorded ones get a plain body."""
    for i, c in enumerate(w.get(COMMENTS, ())):
        if c["body"].startswith(STAMP):
            w.set(COMMENTS, (i, "body"), f"(the recorded checkpoint-b marker, neutralised: {c['id']})")


def open_pr(cell: str, w: World) -> list[Derived]:
    """`none`, `A`, `B (…)`, `A, its head branch is not a `goal/**` branch` → the open list's derived element."""
    if cell == "none":
        return []
    if cell == "A":
        return derive_open_pr(w)
    if cell == "A, its head branch is not a `goal/**` branch":
        derived = derive_open_pr(w)
        w.set("pr-list.json", (derived[0].index, "headRefName"), "fix/not-a-goal-branch")
        return derived
    if cell.startswith("B (A is closed"):
        derived = derive_open_pr(w)
        i = derived[0].index
        w.set("pr-list.json", (i, "number"), B)
        # B's comments read is not recorded: the fake serves #3270's recorded list for it too (a derived read)
        w.provenance["reads"].append({"argv": ["api", comments_path(B)], "file": COMMENTS, "auth": "token"})
        return [*derived, Derived("read-alias", COMMENTS, -1, f"{comments_path(A)}", comments_path(B))]
    raise ValueError(f"open assembly PR cell {cell!r}: no decoder")


def markers(cell: str, target: int, w: World, stamp: Callable[[World], str] | None = None) -> list[Derived]:
    """`(b) markers on it` → the comment list the open assembly PR's read answers. `stamp`: the marker a mutant stamps on A."""
    mark = stamp(w) if stamp else marker(A)
    if cell == "—":
        return []
    if cell.startswith("the ten recorded on #3270"):
        recorded = [c["body"] for c in w.get(COMMENTS, ()) if c["body"].startswith(STAMP)]
        assert len(recorded) == 10 and not any(b.startswith(marker(A)) for b in recorded), recorded
        return []
    neutralise(w)
    if cell == "none":
        return []
    if cell == "the marker for A":
        return [overlay(w, COMMENTS, mark + " — placed on the pull request", 0)]
    if cell == "the marker for A, and the three `state-fp:assembly-cr:` markers recorded on #3270":
        other = [c["body"] for c in w.get(COMMENTS, ()) if c["body"].startswith("🤖 `state-fp:assembly-cr:")]
        assert len(other) == 3, other
        return [overlay(w, COMMENTS, mark + " — placed on the pull request", 0)]
    if cell == "the marker for A, quoted (each line starts `> `)":
        return [overlay(w, COMMENTS, "> " + marker(A) + "\n> — placed on the pull request", 0)]
    if cell == "none on B; the marker for A stays on A":
        # the list B's read serves also holds the marker for A: B's own is absent, A's does not count for B
        return [overlay(w, COMMENTS, marker(A) + " — placed on A", 0)]
    raise ValueError(f"markers cell {cell!r}: no decoder")


STATUS = "pr-view-3270.commits,reviews,statusCheckRollup.json"
NEW_HEAD = "5e17c0de5e17c0de5e17c0de5e17c0de5e17c0de"


def list_index(w: World, n: int) -> int:
    [i] = [i for i, p in enumerate(w.get("pr-list.json", ())) if p["number"] == n]
    return i


def _ci(w: World) -> int:
    [i] = [i for i, c in enumerate(w.get(STATUS, ("statusCheckRollup",))) if c.get("name") == "ci"]
    return i


def since(cell: str, target: int, w: World) -> list[Derived]:
    """`since the marker` → what the open pull request looks like after the marker: its head commit, review decision and checks.

    The component reads the open list and the pull request's comments and nothing else; these cells change the
    world's answers it does not read as well as the two it does (the head commit id and the review decision sit
    on the open-list element), and `test_the_component_reads_only_the_open_list_and_the_comments` holds the reads.
    """
    if cell == "—":
        return []
    i = list_index(w, target)

    def set_ci(**fields: str) -> None:
        for k, v in fields.items():
            w.set(STATUS, ("statusCheckRollup", _ci(w), k), v)

    def new_head() -> None:
        w.set("pr-list.json", (i, "headRefOid"), NEW_HEAD)
        w.add(STATUS, ("commits",), copy_of=0, changes={("oid",): NEW_HEAD, ("messageHeadline",): "a second commit, not a merge"})

    if cell == "the reviewer bot's APPROVED, newer than the marker":
        w.set("pr-list.json", (i, "reviewDecision"), "APPROVED")
    elif cell == "a new head commit id and a second, non-merge commit":
        new_head()
    elif cell == "`ci` settled on FAILURE":
        set_ci(conclusion="FAILURE", status="COMPLETED")
    elif cell == "a new head commit id, `ci` with no conclusion yet":
        new_head()
        set_ci(conclusion="", status="IN_PROGRESS")
    elif cell == "`ci` re-run after FAILURE, no conclusion yet":
        set_ci(conclusion="FAILURE", status="COMPLETED")  # the recorded green, then the red the re-run follows
        set_ci(conclusion="", status="IN_PROGRESS")
    elif cell == "one open member of the Goal is undispositioned":
        pass  # a Goal-side condition (trigger (c), #3448's): the component never reads the Goal's tree
    elif cell == "CHANGES_REQUESTED on A":
        w.set("pr-list.json", (i, "reviewDecision"), "CHANGES_REQUESTED")
    else:
        raise ValueError(f"since the marker cell {cell!r}: no decoder")
    return [Derived("since-the-marker", "pr-list.json", i, "the recorded #3270 read", cell)]


def fault(cell: str, w: World) -> None:
    if cell == "—":
        return
    if cell == "the comment write answers 403":
        w.fault("create-comment", "status", status=403)
    elif cell == "the read of A's comments fails":
        w.fault(COMMENTS, "fail")
    elif cell == "the open-list read fails":
        w.fault("pr-list.json", "fail")
    else:
        raise ValueError(f"fault cell {cell!r}: no decoder")


# ── the legends: what a literal states ────────────────────────────────────────────────────────────


def expected_read(literal: str, pr: int | None) -> tuple[str, int, int]:
    """(stdout, stderr lines, exit) the read legend states, <g> and <n> filled."""
    out, err, rc = READ_LEGEND[literal]
    stdout = "" if out == "nothing" else ticks(out)[0].replace("<g>", GOAL).replace("<n>", str(pr))
    return stdout, {"—": 0, "one warning line": 1}[err], int(rc)


def actual_read(run) -> tuple[str, int, int]:
    return run.stdout.strip(), len(run.stderr.strip().splitlines()) if run.stderr.strip() else 0, run.rc


def actual_writes(result, runs_of: list[str]) -> str:
    """The `marker write?` literal for the first wake, from the comment writes the processes issued."""
    found = []
    for name, run in zip(runs_of, result.runs, strict=True):
        for c in run.calls:
            if c.get("kind") == "write":
                path = next(a for a in c["argv"][1:] if a.startswith("repos/"))
                n = int(re.fullmatch(rf"repos/{re.escape(REPO)}/issues/(\d+)/comments", path)[1])
                body = next(a for a in c["argv"] if a.startswith("body=")).removeprefix("body=")
                found.append((name, n, c["rc"], body, run))
    if not found:
        return "none"
    if len(found) > 1:
        return f"{len(found)} writes: " + ", ".join(f"{name} on {n}" for name, n, *_ in found)
    name, n, rc, body, run = found[0]
    letter = {A: "A", B: "B"}[n]
    if name != "dispatch":
        return f"by {name}, on {letter}"
    if rc == 0 and body.startswith(marker(n)):
        return f"on {letter}"
    if rc != 0 and body.startswith(marker(n)) and "403" in run.stderr and len(run.stderr.strip().splitlines()) == 1 and run.rc == 0:
        return "refused"
    return f"dispatch on {letter}: rc {rc}, body {body[:60]!r}"


def wake_the_row(component: list[str], cells: dict, stamp: Callable[[World], str] | None = None) -> tuple[dict, object]:
    """Build the row's state, run wake 1 and wake 2 through the sequence driver; the three actual cells."""
    w = World(WORLD)
    derived: list[Derived] = []
    with allure.step(
        f"Given {cells['world']}: open assembly PR {cells['open_assembly_pr']}; markers {cells['b_markers_on_it']}; since the marker {cells['since_the_marker']}; fault {cells['fault']}"
    ):
        derived += open_pr(cells["open_assembly_pr"], w)
        target = B if cells["open_assembly_pr"].startswith("B") else A
        derived += markers(cells["b_markers_on_it"], target, w, stamp)
        derived += since(cells["since_the_marker"], target, w)
        fault(cells["fault"], w)
    evaluate = [*component, "evaluate", REPO, GOAL]
    dispatch = [*component, "dispatch", REPO, GOAL]
    this_goal = cells["lane_winner"] == "this Goal"
    names = ["evaluate", *(["dispatch"] if this_goal else [])]
    wakes = [
        Wake([evaluate, *([dispatch] if this_goal else [])]),
        Wake([evaluate], setup=lambda world: world.clear_faults() and None),
    ]
    with allure.step(f"When wake 1 runs {' then '.join(names)} (lane winner: {cells['lane_winner']}), then wake 2 runs evaluate with the fault gone"):
        result = run_sequence(w, wakes)
        allure.attach(json.dumps([d.__dict__ for d in derived], indent=1), "derived elements", allure.attachment_type.JSON)
        for n, wr in enumerate(result.wakes, 1):
            for name, run in zip(names if n == 1 else ["evaluate"], wr.runs, strict=True):
                allure.attach(f"rc {run.rc}\n{run.stdout}--- stderr ---\n{run.stderr}", f"wake {n} {name}", allure.attachment_type.TEXT)
    first, second = result.wakes
    return {
        "expected_b_this_wake": actual_read(first.runs[0]),
        "expected_marker_write": actual_writes(first, names),
        "expected_b_next_wake": actual_read(second.runs[0]),
    }, result


def pr_of(cells: dict) -> int | None:
    cell = cells["open_assembly_pr"]
    return None if cell == "none" or cell.endswith("not a `goal/**` branch") else number(cell[0])


def expected_cells(cells: dict) -> dict:
    n = pr_of(cells)
    return {
        "expected_b_this_wake": expected_read(cells["expected_b_this_wake"], n),
        "expected_marker_write": cells["expected_marker_write"],
        "expected_b_next_wake": expected_read(cells["expected_b_next_wake"], n),
    }


def verdicts(cells: dict, actual: dict) -> dict[str, bool]:
    want = expected_cells(cells)
    return {k: want[k] == actual[k] for k in want}


def check(cells: dict, component: list[str] = COMPONENT) -> None:
    actual, _ = wake_the_row(component, cells)
    want = expected_cells(cells)
    for key, label in (("expected_b_this_wake", "(b) this wake?"), ("expected_marker_write", "marker write?"), ("expected_b_next_wake", "(b) next wake?")):
        with allure.step(f"Then {label} = {cells[key]}"):
            assert actual[key] == want[key], f"{label}: spec {want[key]!r}, actual {actual[key]!r}"
    assert set(WRITE_LEGEND) >= {cells["expected_marker_write"].split()[0]} or cells["expected_marker_write"] in ("on A", "on B")


# ── the cases ─────────────────────────────────────────────────────────────────────────────────────


def run_row(**cells) -> None:
    check(cells)


@rule("SCAN-CLAUSE-GOAL")
@allure.label("world", WORLD)
@allure.label("arm", "model")
@pytest.mark.parametrize(ARGS, ROWS)
def test_trigger_b_hold_model(world, open_assembly_pr, b_markers_on_it, since_the_marker, fault, lane_winner, expected_b_this_wake, expected_marker_write, expected_b_next_wake):
    run_row(**locals())


@rule("SCAN-CLAUSE-GOAL")
@allure.label("world", WORLD)
@allure.label("arm", "hand")
@pytest.mark.parametrize(ARGS, HAND_ROWS)
def test_trigger_b_hold_hand(world, open_assembly_pr, b_markers_on_it, since_the_marker, fault, lane_winner, expected_b_this_wake, expected_marker_write, expected_b_next_wake):
    run_row(**locals())


# ── unlabelled: the mutant, the strict read, the evaluate/dispatch split ──────────────────────────


def row(case_id: str, arm: str = "model") -> dict:
    [r] = [r for r in ARMS[arm] if r.id == case_id]
    return dict(zip(ARGS, r.values, strict=True))


@pytest.mark.parametrize("arm", ARMS)
def test_the_stamp_on_evaluation_mutant_fails_lane_lost_stays_eligible_on_the_marker_write_and_the_next_wake(arm):
    cells = row("lane-lost-stays-eligible ⚖", arm)
    actual, _ = wake_the_row(MUTANT, cells)
    failing = sorted(k for k, ok in verdicts(cells, actual).items() if not ok)
    assert failing == ["expected_b_next_wake", "expected_marker_write"], (failing, actual)
    assert actual["expected_marker_write"] == "by evaluate, on A"


@pytest.mark.parametrize("arm", ARMS)
def test_the_component_passes_the_row_the_mutant_fails(arm):
    check(row("lane-lost-stays-eligible ⚖", arm))


def test_evaluate_issues_no_write_in_any_case():
    for r in ROWS:
        cells = dict(zip(ARGS, r.values, strict=True))
        w = World(WORLD)
        open_pr(cells["open_assembly_pr"], w)
        markers(cells["b_markers_on_it"], A, w)
        since(cells["since_the_marker"], A, w) if cells["open_assembly_pr"] == "A" else None
        fault(cells["fault"], w)
        run = w.run([*COMPONENT, "evaluate", REPO, GOAL])
        assert [c for c in run.calls if c["kind"] == "write"] == [], r.id


def test_the_marker_for_a_is_the_recorded_hash():
    assert marker(A) == "🤖 `state-fp:goal-checkpoint-b:92c59fe63be7`"


def _shape_paths(shape, where=()):
    if isinstance(shape, list):
        return _shape_paths(shape[0], (*where, 0))
    if isinstance(shape, dict):
        return [p for k, v in shape.items() for p in [(*where, k), *_shape_paths(v, (*where, k))]]
    return []


def _schema_required(node: dict, where: tuple = ()) -> list[tuple]:
    if node.get("type") == "array":
        return _schema_required(node["items"], (*where, 0))
    out = []
    for key in node.get("required", []):
        out += [(*where, key), *_schema_required(node["properties"][key], (*where, key))]
    return out


PROPS = json.loads(SCHEMA.read_text("utf-8"))["properties"]
OPEN_REQUIRED = _schema_required(PROPS["open_pr_list"])
COMMENT_REQUIRED = _schema_required(PROPS["issue_comments_read"])


def test_the_component_requires_exactly_the_schema_fields():
    from scan_island.checkpoint_b import ISSUE_COMMENTS_READ, OPEN_PR_LIST

    assert sorted(map(str, _shape_paths(OPEN_PR_LIST))) == sorted(map(str, OPEN_REQUIRED))
    assert sorted(map(str, _shape_paths(ISSUE_COMMENTS_READ))) == sorted(map(str, COMMENT_REQUIRED))


def test_the_recordings_satisfy_the_schema():
    import jsonschema

    w = World(WORLD)
    open_pr("A", w)
    jsonschema.validate(w.get("pr-list.json", ()), PROPS["open_pr_list"])
    jsonschema.validate(w.get(COMMENTS, ()), PROPS["issue_comments_read"])


@pytest.mark.parametrize("path", OPEN_REQUIRED, ids=[".".join(map(str, p)) for p in OPEN_REQUIRED])
def test_each_required_open_list_field_absent_is_unreadable(path):
    w = World(WORLD)
    derived = open_pr("A", w)
    w.fault("pr-list.json", "absent", field=(derived[0].index, *path[1:]) if path[0] == 0 else path)
    run = w.run([*COMPONENT, "dispatch", REPO, GOAL])
    assert (run.rc, run.stdout) == (4, "") and len(run.stderr.strip().splitlines()) == 1, run
    assert [c for c in run.calls if c["kind"] == "write"] == []


@pytest.mark.parametrize("path", COMMENT_REQUIRED, ids=[".".join(map(str, p)) for p in COMMENT_REQUIRED])
def test_each_required_comment_field_absent_leaves_b_eligible_with_one_warning(path):
    w = World(WORLD)
    open_pr("A", w)
    neutralise(w)
    overlay(w, COMMENTS, marker(A), 0)
    w.fault(COMMENTS, "absent", field=path)
    run = w.run([*COMPONENT, "evaluate", REPO, GOAL])
    assert run.rc == 0 and run.stdout.strip().endswith("marker read failed") and len(run.stderr.strip().splitlines()) == 1, run


def _marker_past_the_first_page() -> World:
    w = World(WORLD)
    open_pr("A", w)
    neutralise(w)
    for _ in range(100):
        w.add(COMMENTS, (), copy_of=0)
    overlay(w, COMMENTS, marker(A) + " — placed on the pull request", 0)
    assert len(w.get(COMMENTS, ())) > 100
    return w


def test_a_marker_past_the_first_hundred_comments_still_holds_and_dispatch_stamps_nothing():
    for mode in ("evaluate", "dispatch"):
        run = _marker_past_the_first_page().run([*COMPONENT, mode, REPO, GOAL])
        assert run.stdout.strip() == f"goal-checkpoint-b {GOAL} HELD: pr={A}" and run.stderr == "", (mode, run)
        assert [c for c in run.calls if c["kind"] == "write"] == [], mode


def test_the_single_page_read_would_miss_that_marker():
    # the red side: the first page of the same list (what the old `?per_page=100` read saw) does not hold the marker
    run = _marker_past_the_first_page().run(["gh", "api", comments_path(A)])
    assert not any(c["body"].startswith(marker(A)) for c in json.loads(run.stdout))


def test_a_non_json_open_list_is_no_decision():
    w = World(WORLD).fault("pr-list.json", "non-json")
    run = w.run([*COMPONENT, "evaluate", REPO, GOAL])
    assert (run.rc, run.stdout) == (4, "")


def test_the_goal_may_be_given_with_a_hash():
    w = World(WORLD)
    open_pr("A", w)
    assert w.run([*COMPONENT, "evaluate", REPO, f"#{GOAL}"]).stdout.startswith(f"goal-checkpoint-b {GOAL} fires")


def test_an_assembly_trailer_for_another_goal_is_no_assembly_pr():
    w = World(WORLD)
    open_pr("A", w)
    assert w.run([*COMPONENT, "evaluate", REPO, "9999"]).stdout.strip() == "goal-checkpoint-b 9999 fires: no open assembly PR"


def test_the_trailer_must_be_line_anchored():
    w = World(WORLD)
    d = open_pr("A", w)
    body = w.get("pr-list.json", (d[0].index, "body"))
    w.set("pr-list.json", (d[0].index, "body"), body.replace("Assembly-for: #3118", "see Assembly-for: #3118"))
    assert w.run([*COMPONENT, "evaluate", REPO, GOAL]).stdout.strip().endswith("no open assembly PR")


# ── the two arms and the render ───────────────────────────────────────────────────────────────────

RENDER = _load_render()


def test_the_two_arms_hold_the_same_rows():
    assert [(r.id, r.values) for r in ROWS] == [(r.id, r.values) for r in HAND_ROWS]


def test_a_fresh_render_equals_the_committed_page_section_and_view():
    model = RENDER.load()
    assert RENDER.splice(PAGE.read_text("utf-8"), model) == PAGE.read_text("utf-8"), "page differs from a fresh render"
    assert RENDER.view(model) == RENDER.VIEW.read_text("utf-8"), "view differs from a fresh render"
    assert all("unverified" == line.split("|")[-2].strip() for line in RENDER.VIEW.read_text("utf-8").splitlines()[7:])


def test_a_changed_expectation_changes_the_table_and_fails_against_the_unchanged_component(tmp_path):
    copy = tmp_path / "model.yaml"
    copy.write_text(RENDER.MODEL.read_text("utf-8"), "utf-8")
    model = RENDER.load(copy)
    [case] = [c for c in model["cases"] if c["id"] == "goal-checkpoint-b-held"]
    assert case["expect"]["b_this_wake"] == "held"
    case["expect"]["b_this_wake"] = "fires-unmarked"
    copy.write_text(json.dumps(model, ensure_ascii=False, indent=2), "utf-8")
    assert RENDER.table(RENDER.load(copy)) != RENDER.table(RENDER.load())
    page = tmp_path / "page.md"
    page.write_text(f"#### {QUESTION}\n\n{RENDER.table(RENDER.load(copy))}\n", "utf-8")
    args, rows = page_params(tables(page), QUESTION)
    [changed] = [r for r in rows if r.id == "goal-checkpoint-b-held"]
    with pytest.raises(AssertionError, match=r"\(b\) this wake\?"):
        check(dict(zip(args, changed.values, strict=True)))


def test_the_cases_read_no_path_under_agents():
    here = Path(__file__).read_text("utf-8")
    assert here.count("agents" + "/") == 0


# ── the second mutant: the head commit id folded into the hash ───────────────────────────────────

CHURN = _load_script("checkpoint_b_release_on_churn", MUTANTS / "checkpoint_b_release_on_churn.py")


def churn_stamp(w: World) -> str:
    """The marker the churn mutant would have stamped on A at the head the open list shows before the row's push."""
    return CHURN.marker_for(A, w.get("pr-list.json", (list_index(w, A), "headRefOid")))


def churn_failing(case_id: str, arm: str) -> list[str]:
    cells = row(case_id, arm)
    actual, _ = wake_the_row(CHURN_MUTANT, cells, churn_stamp)
    return sorted(k for k, ok in verdicts(cells, actual).items() if not ok)


@pytest.mark.parametrize("arm", ARMS)
def test_the_release_on_churn_mutant_fails_content_push_held(arm):
    assert churn_failing("goal-checkpoint-b-content-push-held", arm) == ["expected_b_next_wake", "expected_b_this_wake"]


@pytest.mark.parametrize("arm", ARMS)
@pytest.mark.parametrize("case_id", ["goal-checkpoint-b-inflight-check-held"])
def test_the_release_on_churn_mutant_fails_every_row_that_pushes(arm, case_id):
    assert churn_failing(case_id, arm) == ["expected_b_next_wake", "expected_b_this_wake"]


@pytest.mark.parametrize("arm", ARMS)
@pytest.mark.parametrize(
    "case_id",
    ["goal-checkpoint-b-held", "goal-checkpoint-b-verdict-held", "goal-checkpoint-b-check-flip-held", "goal-checkpoint-b-red-rerun-held", "goal-checkpoint-b-c-armed", "assembly-cr-wake-b-silent ⚖"],
)
def test_the_release_on_churn_mutant_holds_where_nothing_pushes(arm, case_id):
    # the mutant is a head-commit mistake only: with the head unchanged its marker still holds, so the rows around the push stay green
    assert churn_failing(case_id, arm) == []


@pytest.mark.parametrize("arm", ARMS)
def test_the_component_passes_the_row_the_churn_mutant_fails(arm):
    check(row("goal-checkpoint-b-content-push-held", arm))


def test_the_component_reads_only_the_open_list_and_the_comments():
    # the since cells change answers the component never asks for; they cannot matter unless it reads them
    for r in ROWS:
        cells = dict(zip(ARGS, r.values, strict=True))
        if cells["since_the_marker"] == "—" or cells["open_assembly_pr"] != "A":
            continue
        w = World(WORLD)
        open_pr("A", w)
        markers(cells["b_markers_on_it"], A, w)
        since(cells["since_the_marker"], A, w)
        run = w.run([*COMPONENT, "dispatch", REPO, GOAL])
        reads = {tuple(c["argv"][:2]) for c in run.calls if c["kind"] != "write"}
        assert {a[0] for a in reads} <= {"pr", "api"}, reads
        assert all(c["argv"][1] == "list" for c in run.calls if c["argv"][0] == "pr"), run.calls
        assert all("/comments" in c["argv"][-1] for c in run.calls if c["argv"][0] == "api"), run.calls
