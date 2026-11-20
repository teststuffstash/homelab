"""The major handoff contract (specs/major-handoff.md), its rows read from the page over the recorded world.

Every row of the SCAN-HANDOFF-GATE and SCAN-HANDOFF-ARM tables is one case (goal #3490 pins 4–7): the
description cell is the case id verbatim, every other header cell is a parameter whose value is the
row's cell verbatim (CONVENTIONS § The intent column; a header becomes its argname lower-cased with
each run of other characters an `_`, and `name?` becomes `expected_name`). The cells are decoded HERE,
against the page's `expect?` legend and the decoders below, into value overrides on the recorded world
`pr-handoff` (tests/world.py); the component runs as a process against the island's fake `gh`, and the
case asserts what the legend states: the writes issued, in order, the exit code, the refusal's words.

The base state is the page's `**World:**` sentence: the PR is open, its newest non-merge commit is older
than the bot's APPROVED review, that review carries the four headings, and after the writes the label
re-read lists `major/awaiting-human` and not `agent/in-progress`. The recording already holds the last
three; only `state` (recorded MERGED) is overridden for every row, and the row's own cells do the rest.
"""

from __future__ import annotations

import datetime as dt
import json
import re
import sys
from collections.abc import Callable
from urllib.parse import quote

import allure
import pytest

from .page import params as page_params
from .page import table as page_table
from .page import tables, ticks
from .rules import SPECS, rule
from .world import World

PAGE = SPECS / "major-handoff.md"
SCHEMA = SPECS / "major-handoff.schema.json"
COMPONENT = [sys.executable, "-m", "scan_island.major_handoff"]


# ── the page, parsed ──────────────────────────────────────────────────────────────────────────────

TABLES = tables(PAGE)


def table(question: str) -> tuple[list[str], list[list[str]]]:
    return page_table(TABLES, question)


def params(question: str) -> tuple[list[str], list]:
    return page_params(TABLES, question)


_ticks = ticks


[LEGEND] = [dict((r[0], r[1:]) for r in rows) for _q, h, rows in TABLES if h[0] == "literal"]


# ── the recorded world and its anchors ────────────────────────────────────────────────────────────

WORLD = "pr-handoff"
_PROBE = World(WORLD)
REPO = _PROBE.provenance["repo"]
[PR] = _PROBE.provenance["items"]
_READS = {tuple(r["argv"]): r["file"] for r in _PROBE.provenance["reads"]}
PR_READ = _READS[("pr", "view", str(PR), "--repo", REPO, "--json", "state,labels,reviews,commits")]
LABEL_READ = _READS[("api", f"repos/{REPO}/issues/{PR}/labels")]
PULL_READ = _READS[("api", f"repos/{REPO}/pulls/{PR}")]
[PULL_AFTER_ARM] = [f"writes/{w['op']}.{w['statuses'][0]}.json" for w in _PROBE.provenance["writes"] if w.get("after") == "pr-merge-auto"]
RECORDED = json.loads((_PROBE.dir / PR_READ).read_text("utf-8"))
PULL = json.loads((_PROBE.dir / PULL_READ).read_text("utf-8"))
BOT = "homelab-reviewer"  # the page's prose: the reviewer bot `homelab-reviewer`, `[bot]` suffix normalized
HEADINGS = json.loads(SCHEMA.read_text("utf-8"))["properties"]["evidence"]["properties"]["headings"]["const"]


def _approval_index() -> int:
    """The recorded bot APPROVED review the rows override (exactly one in the recording)."""
    [i] = [i for i, r in enumerate(RECORDED["reviews"]) if r["author"]["login"] == BOT and r["state"] == "APPROVED"]
    return i


APPROVAL = _approval_index()
APPROVED_AT = dt.datetime.fromisoformat(RECORDED["reviews"][APPROVAL]["submittedAt"])


def _iso(t: dt.datetime) -> str:
    return t.astimezone(dt.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


BEFORE, AFTER = _iso(APPROVED_AT - dt.timedelta(hours=1)), _iso(APPROVED_AT + dt.timedelta(hours=1))
# The placeholders the merge headlines and the suffixed heading name, filled from the recorded pull read.
PLACEHOLDERS = {"<head>": PULL["head"]["ref"], "<owner>": PULL["head"]["repo"]["owner"]["login"], "<n>": str(PR),
                "<sha>": PULL["head"]["sha"], "<remote>": "origin"}


def _fill(text: str) -> str:
    for k, v in PLACEHOLDERS.items():
        text = text.replace(k, v)
    return text


# ── the decoders: one cell → value overrides on the world ─────────────────────────────────────────

Override = Callable[[World], None]


def labels(cell: str) -> Override:
    """`major`, `agent/in-progress` → the PR read's `labels`: one copy of a recorded label per name."""
    names = _ticks(cell)
    if not names or ", ".join(f"`{n}`" for n in names) != cell:
        raise ValueError(f"labels cell {cell!r}: want backticked names, comma-separated")
    recorded = RECORDED["labels"][0]
    return lambda w: w.set(PR_READ, ("labels",), [{**recorded, "name": n} for n in names])


def _base_commits() -> list[dict]:
    """The recorded commits committed before the approval (the World sentence's content-before state)."""
    kept = [c for c in RECORDED["commits"] if dt.datetime.fromisoformat(c["committedDate"]) < APPROVED_AT]
    assert kept and not kept[-1]["messageHeadline"].startswith("Merge "), "the recording's newest commit before the approval is not content"
    return kept


def newest_commit(cell: str) -> Override:
    base = _base_commits()
    if cell == "content":  # no approval to date it against: the recorded content commits
        commits = base
    elif cell == "content, before the approval":
        commits = base[:-1] + [{**base[-1], "committedDate": BEFORE}]
    elif cell == "content, after the approval":
        commits = base + [{**base[-1], "committedDate": AFTER}]
    elif m := re.fullmatch(r"merge, after the approval: `([^`]+)`", cell):
        commits = base + [{**base[-1], "messageHeadline": _fill(m[1]), "committedDate": AFTER}]
    else:
        raise ValueError(f"newest commit cell {cell!r}: no decoder")
    return lambda w: w.set(PR_READ, ("commits",), commits)


def _set_body(transform: Callable[[str], str]) -> Override:
    """Transform the approval's body as the case has it so far (body overrides compose, in cell order)."""
    path = ("reviews", APPROVAL, "body")

    def apply(w: World) -> None:
        body = w.get(PR_READ, path)
        new = transform(body)
        assert new != body, "a body override must change the body"
        w.set(PR_READ, path, new)

    return apply


def _all(*overrides: Override) -> Override:
    def apply(w: World) -> None:
        for o in overrides:
            o(w)

    return apply


def _heading_line(name: str) -> str:
    return f"## {name}\n"


def bot_review(cell: str) -> Override:
    if cell == "none (`reviews` is empty)":
        return lambda w: w.set(PR_READ, ("reviews",), [])
    if not cell.startswith("APPROVED"):
        raise ValueError(f"bot review cell {cell!r}: no decoder")
    parts = cell.split(", ")
    head, rest = parts[0], parts[1:]
    out: list[Override] = []
    if head.startswith("APPROVED by "):
        [login] = _ticks(head)
        out.append(lambda w: w.set(PR_READ, ("reviews", APPROVAL, "author", "login"), login))
    elif head != "APPROVED":
        raise ValueError(f"bot review cell {cell!r}: no decoder for {head!r}")
    if rest[:1] == ["no headings"]:  # each of the four heading lines becomes a plain `Name:` line
        out.append(_set_body(_plain))
    elif rest[:1] == ["four headings"]:
        # the recorded approval carries the four `## …` headings as recorded (the World sentence)
        assert all(_heading_line(h) in RECORDED["reviews"][APPROVAL]["body"] for h in HEADINGS)
    else:
        raise ValueError(f"bot review cell {cell!r}: want `four headings` or `no headings`")
    for extra in rest[1:]:
        if m := re.fullmatch(r"one written `## (\w[\w ]*?) (.+)`", extra):
            name, suffixed = m[1], _fill(f"## {m[1]} {m[2]}")
            out.append(_set_body(lambda b, name=name, suffixed=suffixed: b.replace(_heading_line(name), suffixed + "\n")))
        elif extra == "body lines ending CRLF":
            out.append(_set_body(lambda b: b.replace("\n", "\r\n")))
        else:
            raise ValueError(f"bot review cell {cell!r}: no decoder for {extra!r}")
    return _all(*out)


def _plain(body: str) -> str:
    """Every one of the four heading lines becomes a plain `Name:` line (no `##`, no `**`)."""
    for h in HEADINGS:
        assert body.count(_heading_line(h)) == 1, f"the body holds no single `## {h}` line to un-head"
        body = body.replace(_heading_line(h), f"{h}:\n")
    return body


def fault(cell: str) -> Override:
    if cell == "—":
        return lambda w: None
    if cell == "the PR read fails":
        return lambda w: w.fault(PR_READ, "fail")
    if m := re.fullmatch(r"the PR read's answer has no `(\w+)` field", cell):
        return lambda w: w.fault(PR_READ, "absent", field=(m[1],))
    if m := re.fullmatch(r"the label re-read after the writes still lists `([^`]+)`", cell):
        return lambda w: w.add(LABEL_READ, (), copy_of=0, changes={("name",): m[1]})
    if m := re.fullmatch(r"the DELETE of `([^`]+)` answers (\d{3})", cell):
        # the fault targets the world's one remove-label op, so the cell must name the label the legend removes
        assert [w["op"] for w in _PROBE.provenance["writes"]].count("remove-label") == 1, "the world holds several remove-label ops"
        assert m[1] in {s[2] for s in expected_calls("handoff") if s[1] == "remove-label"}, f"{cell!r}: not the label the gate removes"
        return lambda w: w.fault("remove-label", "status", status=int(m[2]))
    raise ValueError(f"fault cell {cell!r}: no decoder")


def upstream_line(cell: str) -> Override:
    """The first line of the approval's `## Upstream` section becomes the cell's value."""
    [line] = _ticks(cell)

    def swap(body: str) -> str:
        head = _heading_line("Upstream")
        start = body.index(head) + len(head)
        while body[start] == "\n":
            start += 1
        end = body.index("\n", start)
        return body[:start] + line + body[end:]

    return _set_body(swap)


# ── the legend: what a literal states ─────────────────────────────────────────────────────────────


def expected_calls(literal: str) -> list[tuple]:
    """The legend's `writes issued, in order` cell as call matchers, each (kind, target, label)."""
    cell = LEGEND[literal][0]
    if cell == "none":
        return []
    out = []
    for step in cell.split("; "):
        if m := re.fullmatch(r"add `([^`]+)`", step):
            out.append(("write", "add-labels", m[1]))
        elif m := re.fullmatch(r"remove `([^`]+)`", step):
            out.append(("write", "remove-label", m[1]))
        elif step == "arm auto-merge (squash)":
            out.append(("write", "pr-merge-auto", None))  # the world's op path ends `--auto --squash`
        elif step == "then the label re-read":
            out.append(("read", LABEL_READ, None))
        elif step == "then the pull re-read":
            out.append(("read", PULL_AFTER_ARM, None))
        else:
            raise ValueError(f"legend {literal}: no decoder for step {step!r}")
    return out


def _matches(call: dict, want: tuple) -> bool:
    kind, target, label = want
    if call["kind"] != kind or call.get("op", call.get("file")) != target:
        return False
    if target == "add-labels":
        return f"labels[]={label}" in call["argv"]
    if target == "remove-label":
        path = next(a for a in call["argv"][1:] if a.startswith("repos/"))
        return path.endswith("/labels/" + quote(label, safe=""))
    return True


def check(world: World, literal: str) -> None:
    calls_cell, exit_cell, words_cell = LEGEND[literal]
    with allure.step(f"When the handoff gate runs on {REPO}#{PR}"):
        run = world.run([*COMPONENT, REPO, str(PR)])
        allure.attach(run.stdout + run.stderr, "output", allure.attachment_type.TEXT)
    after = [c for c in run.calls if c.get("file") != PR_READ]  # every call after the PR read
    want = expected_calls(literal)
    with allure.step(f"Then it issues: {calls_cell}; exit {exit_cell}"):
        assert run.calls and run.calls[0].get("file") == PR_READ, run.calls
        assert len(after) == len(want) and all(_matches(c, w) for c, w in zip(after, want, strict=True)), (
            f"calls after the PR read:\n{json.dumps(after, indent=1)}\nwant {want}"
        )
        if not want:
            assert not [c for c in run.calls if c["kind"] == "write"], run.calls
        assert run.rc == int(exit_cell), f"rc {run.rc}\n{run.stdout}{run.stderr}"
    for word in _ticks(words_cell):
        with allure.step(f"And the refusal names `{word}`"):
            assert word in run.stdout, run.stdout


def base_world() -> World:
    return World(WORLD).set(PR_READ, ("state",), "OPEN")


def gate_world(world_cell: str, labels_cell: str, commit_cell: str, review_cell: str, fault_cell: str) -> World:
    assert world_cell == WORLD, world_cell
    w = base_world()
    for override in (labels(labels_cell), newest_commit(commit_cell), bot_review(review_cell), fault(fault_cell)):
        override(w)
    return w


# ── the cases ─────────────────────────────────────────────────────────────────────────────────────

GATE_ARGS, GATE_ROWS = params("Does the handoff write the label?")
# "Both rows start from the GATE table's `handoff` state": that row's cells, world first
[HANDOFF] = [r[1:6] for r in table("Does the handoff write the label?")[1] if r[0] == "handoff"]


def _handoff_world(world_cell: str = WORLD) -> World:
    return gate_world(world_cell, *HANDOFF[1:])
ARM_ARGS, ARM_ROWS = params("Does a chart major arm or park?")


@rule("SCAN-HANDOFF-GATE")
@pytest.mark.parametrize(GATE_ARGS, GATE_ROWS)
def test_gate(world, labels, newest_commit, bot_review, fault, expected_expect):
    with allure.step(f"Given {world}: labels {labels}; newest commit {newest_commit}; bot review {bot_review}; fault {fault}"):
        w = gate_world(world, labels, newest_commit, bot_review, fault)
    check(w, expected_expect)


@rule("SCAN-HANDOFF-ARM")
@pytest.mark.parametrize(ARM_ARGS, ARM_ROWS)
def test_arm(world, first_line_of_the_review_s_upstream_section, expected_expect):
    with allure.step(f"Given the GATE `handoff` state on {world}, the Upstream section opening {first_line_of_the_review_s_upstream_section}"):
        w = _handoff_world(world)
        upstream_line(first_line_of_the_review_s_upstream_section)(w)
    check(w, expected_expect)


# ── unlabelled: the decoders and the strict read, held against the page and its schema ─────────────


def _schema_required(node: dict, where: tuple = ()) -> list[tuple]:
    """Every required field path of a schema node; a list element stands at index 0."""
    out = []
    if node.get("type") == "array":
        return _schema_required(node["items"], (*where, 0))
    for key in node.get("required", []):
        out.append((*where, key))
        out.extend(_schema_required(node["properties"][key], (*where, key)))
    return out


PR_READ_SCHEMA = json.loads(SCHEMA.read_text("utf-8"))["properties"]["pr_read"]
REQUIRED = _schema_required(PR_READ_SCHEMA)


def test_the_recording_satisfies_the_pr_read_schema():
    import jsonschema

    jsonschema.validate(RECORDED, PR_READ_SCHEMA)  # positive control: the schema's names are the recording's


@pytest.mark.parametrize("path", REQUIRED, ids=[".".join(map(str, p)) for p in REQUIRED])
def test_each_required_field_absent_is_unreadable(path):
    """Pin 5 over the WHOLE `pr_read` list: from the `handoff` state, the PR read answering without any one
    required field is exit 4 with nothing written."""
    w = _handoff_world().fault(PR_READ, "absent", field=path)
    check(w, "unreadable")


def test_a_null_required_field_is_unreadable_and_named_as_mistyped():
    w = _handoff_world().set(PR_READ, ("reviews", APPROVAL, "body"), None)
    check(w, "unreadable")
    run = w.run([*COMPONENT, REPO, str(PR)])
    assert f"with `reviews[{APPROVAL}].body` not a str" in run.stdout, run.stdout


def test_component_requires_exactly_the_schema_list():
    from scan_island.major_handoff import PR_READ as SHAPE

    def paths(shape, where=()):
        if isinstance(shape, list):
            return paths(shape[0], (*where, 0))
        if isinstance(shape, dict):
            return [p for k, v in shape.items() for p in [(*where, k), *paths(v, (*where, k))]]
        return []

    assert sorted(map(str, paths(SHAPE))) == sorted(map(str, REQUIRED))


def test_refusal_words_are_mutually_exclusive():
    """Each `refused-*` literal's words appear in its own row's output and in no other refusal's, nor in
    the line prefix every refusal shares — else a row could pass on the wrong refusal (all exit 3)."""
    refusals = {lit: words for lit, (_calls, _rc, words) in LEGEND.items() if lit.startswith("refused-")}
    rows = {r[6]: r[1:6] for r in table("Does the handoff write the label?")[1] if r[6] in refusals}
    assert set(rows) == set(refusals), f"a refused-* literal no GATE row uses: {set(refusals) - set(rows)}"
    outputs = {lit: gate_world(*cells).run([*COMPONENT, REPO, str(PR)]).stdout for lit, cells in rows.items()}
    texts = list(outputs.values())
    prefix = next((texts[0][:i] for i in range(len(texts[0])) if len({t[: i + 1] for t in texts}) > 1), texts[0])
    assert prefix, outputs
    for lit, words in refusals.items():
        for word in _ticks(words):
            assert word not in prefix, f"{lit}: `{word}` is in the prefix every refusal prints: {prefix!r}"
            assert [o for o, out in outputs.items() if word in out] == [lit], f"`{word}` is printed by {outputs}"


# Behaviours of the component no page row states: they move from the in-process hook onto the world.


def test_absent_claim_on_the_arm_path_is_success():
    w = _handoff_world()
    upstream_line("`appVersion: unchanged (v1)`")(w)
    w.fault("remove-label", "status", status=404)
    check(w, "armed")


def test_crlf_body_arms():
    w = _handoff_world()
    upstream_line("`appVersion: unchanged (v1)`")(w)
    bot_review("APPROVED, four headings, body lines ending CRLF")(w)
    check(w, "armed")


def test_other_delete_failure_is_not_proven():
    w = _handoff_world().fault("remove-label", "fail", stderr="gh: Server Error (HTTP 500)\n")
    run = w.run([*COMPONENT, REPO, str(PR)])
    assert run.rc == 5, run.stdout
    assert [c.get("op") for c in run.calls if c["kind"] == "write"] == ["add-labels", "remove-label"]
