"""The updater contract (specs/updater.md), its rows read from the page over the recorded world `pr-board`.

Every row of the SCAN-UPDATER-PICK, -UNSTRAND, -CONFLICT and -RENOVATE tables is one case (goal #3490
pins 4–7): the description cell is the case id verbatim, every other header cell is a parameter whose value
is the row's cell verbatim (tests/page.py). The cells are decoded HERE, against the page's World lines, its
`expect?` legend and the decoders below, into value overrides on the recorded snapshot and per-PR reads
(tests/world.py); the component runs as a process against the island's fake `gh`, and the case asserts what
the legend states: the probes and rollup reads made, the `update-branch` PUTs issued, the label operation or
hand-back, the printed lines and the exit code.

The page's `#n` names (its ⚖ World paragraph): `#90` and `#91` stand for the two recorded snapshot entries
with no per-PR reads, and the pull requests a row adds for the recorded items (the ones with per-PR reads), in
the order the row names them. Every printed or written number is the entry's recorded number.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import re
import sys
from collections.abc import Callable
from dataclasses import dataclass, field

import allure
import pytest

from .page import params, table, tables, ticks
from .rules import SPECS, rule
from .world import Run, World

PAGE = SPECS / "updater.md"
SCHEMA = json.loads((SPECS / "updater.schema.json").read_text("utf-8"))
COMPONENT = [sys.executable, "-m", "scan_island.updater"]
TABLES = tables(PAGE)
TEXT = PAGE.read_text("utf-8")

# ── the recorded world and its anchors ────────────────────────────────────────────────────────────

WORLD = "pr-board"
_PROBE = World(WORLD)
REPO = _PROBE.provenance["repo"]
ITEMS: list[int] = _PROBE.provenance["items"]  # the recorded items: the snapshot entries whose per-PR reads the world holds
_READS = {tuple(r["argv"]): r["file"] for r in _PROBE.provenance["reads"]}
[SNAPSHOT] = [f for argv, f in _READS.items() if argv[:2] == ("pr", "list")]
SNAP: list[dict] = json.loads((_PROBE.dir / SNAPSHOT).read_text("utf-8"))
INDEX = {e["number"]: i for i, e in enumerate(SNAP)}
SPARE = [e["number"] for e in SNAP if e["number"] not in ITEMS]  # recorded entries the world holds no per-PR read for


def _recorded(file: str) -> dict:
    return json.loads((_PROBE.dir / file).read_text("utf-8"))


def commit_probe(n: int) -> str:
    return _READS[("pr", "view", str(n), "--repo", REPO, "--json", "commits")]


def review_probe(n: int) -> str:
    return _READS[("pr", "view", str(n), "--repo", REPO, "--json", "commits,reviews")]


def check_runs(n: int) -> str:
    return _READS[("api", f"repos/{REPO}/commits/{SNAP[INDEX[n]]['headRefOid']}/check-runs?per_page=100")]


def status(n: int) -> str:
    return _READS[("api", f"repos/{REPO}/commits/{SNAP[INDEX[n]]['headRefOid']}/status")]


def pull(n: int) -> str:
    return _READS[("api", f"repos/{REPO}/pulls/{n}")]


def base_ci(name: str = "master") -> str:
    """The base ci read's recorded answer file: the check runs at the head of `master` (the only recorded base)."""
    return _READS[("api", f"repos/{REPO}/commits/heads/{name}/check-runs?per_page=100")]


def parents_read(n: int) -> str:
    """The pull-commits read for a recorded item: which commit is a merge commit (glossary.md merge commit)."""
    return _READS[("api", f"repos/{REPO}/pulls/{n}/commits?per_page=100")]


# Recorded elements every decoder copies from (pin 4: a list element is a copy of a recorded element of its list).
BOT = "homelab-reviewer"  # the reviewer bot the page's prose names (REVIEWER_LOGIN's default)
ARMED = next(e["autoMergeRequest"] for e in SNAP if e["autoMergeRequest"])
REVIEW = next(r for e in SNAP for r in e["reviews"] if r["author"]["login"] == BOT)
LATEST = next(r for e in SNAP for r in e["latestReviews"] if r["author"]["login"] == BOT)
LABEL = next(lb for e in SNAP for lb in e["labels"])
COMMIT = _recorded(commit_probe(ITEMS[0]))["commits"][0]
PARENT = _recorded(parents_read(ITEMS[0]))[0]["parents"][0]  # a recorded element of a `parents` list
PROBE_REVIEW = next(r for r in _recorded(review_probe(ITEMS[0]))["reviews"] if r["author"]["login"] == BOT)
CHECK_RUN = _recorded(check_runs(ITEMS[0]))["check_runs"][0]
T = dt.datetime.fromisoformat(COMMIT["committedDate"])  # "the newest non-merge commit": one recorded content commit
CREATED = dt.datetime.fromisoformat(min(e["createdAt"] for e in SNAP))
# The RENOVATE World line's values (held verbatim against the page by test_the_renovate_world_values_are_the_pages).
RENOVATE_LIST, RENOVATE_COMMIT = "app/homelab-renovate-1234", "homelab-renovate-1234[bot]"
BOX_OFF, BOX_ON = "- [ ] <!-- rebase-check -->", "- [x] <!-- rebase-check -->"
MERGE_HEADLINE = "Merge branch 'master' into <head>"


def _iso(t: dt.datetime) -> str:
    return t.astimezone(dt.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


HOUR = dt.timedelta(hours=1)


# ── the board: one row's state as value overrides on the recording ────────────────────────────────


@dataclass
class Board:
    """The page's World line applied to `pr-board`, plus what the row's cells add."""

    w: World = field(default_factory=lambda: World(WORLD))
    alias: dict[str, int] = field(default_factory=dict)  # the page's `#n` → the recorded number
    added: list[str] = field(default_factory=list)  # the pull requests the row adds, in the order it names them
    free: list[int] = field(default_factory=lambda: list(ITEMS))
    listed: set[int] = field(default_factory=set)  # the items whose pull-commits answer a cell has laid out
    dirty: str | None = None  # the PR a cell made armed ∧ DIRTY
    labelled: str | None = None  # the PR a cell gave `merge-conflict`
    faulted: list[tuple[str, str]] = field(default_factory=list)  # (fault target, the `#n` it must address)
    env: dict[str, str] = field(default_factory=dict)

    def __post_init__(self) -> None:
        # "`#90` armed ∧ CLEAN, `#91` un-armed ∧ BEHIND"
        self.alias["#90"], self.alias["#91"] = SPARE[0], SPARE[1]
        self.set("#90", "autoMergeRequest", ARMED).set("#90", "mergeStateStatus", "CLEAN")
        assert SNAP[INDEX[SPARE[1]]]["autoMergeRequest"] is None, "the recorded #91 stand-in is armed"
        self.set("#91", "mergeStateStatus", "BEHIND")

    def n(self, page_n: str) -> int:
        return self.alias[page_n]

    def idx(self, page_n: str) -> int:
        return INDEX[self.n(page_n)]

    def set(self, page_n: str, key: str, value: object) -> Board:
        self.w.set(SNAPSHOT, (self.idx(page_n), key), value)
        return self

    def add(self, page_n: str) -> str:
        """A pull request the row adds: the next recorded item, with no label and no review (the World line)."""
        assert page_n not in self.alias, f"{page_n} is named twice"
        if not self.free:
            raise ValueError(f"{page_n}: the world records per-PR reads for {len(ITEMS)} items only")
        self.alias[page_n] = self.free.pop(0)
        self.added.append(page_n)
        for key in ("labels", "reviews", "latestReviews"):
            self.set(page_n, key, [])
        return page_n

    def armed_behind(self, page_n: str) -> Board:
        return self.set(page_n, "autoMergeRequest", ARMED).set(page_n, "mergeStateStatus", "BEHIND")

    def commits(self, page_n: str, commits: list[C], file: Callable[[int], str] = commit_probe) -> Board:
        """The PR view's commits, and the pull-commits read's element for each: every commit has its own `oid` (the PR's
        recorded first commit's, the first time a recorded element is used; a derived 40-hex value after that), and the
        element for each later commit is a copy of a recorded one with `sha` = that `oid` and its `parents` copies of a
        recorded parent. The first commit keeps its recorded element (one parent)."""
        n = self.n(page_n)
        assert n not in self.listed, f"{page_n}: the pull-commits answer is already laid out"
        self.listed.add(n)
        first = _recorded(file(n))["commits"][0]["oid"]
        assert first in {e["sha"] for e in _recorded(parents_read(n))}, "the recorded first commit has no recorded element"
        assert commits[0].parents == 1
        view = [{**c.view, "oid": first if i == 0 else _oid(f"{n}:{i}")} for i, c in enumerate(commits)]
        self.w.set(file(n), ("commits",), view)
        for v, c in list(zip(view, commits, strict=True))[1:]:
            self.w.add(parents_read(n), (), copy_of=0, changes={("sha",): v["oid"], ("parents",): [PARENT] * c.parents})
        return self


@dataclass
class C:
    """One commit a cell describes: its element of the PR view, and how many parents the pull-commits read lists for it."""

    view: dict
    parents: int = 1


def _oid(seed: str) -> str:
    return hashlib.sha1(seed.encode()).hexdigest()  # noqa: S324 — a derived 40-hex value, not a security digest


def content_commit(at: dt.datetime) -> C:
    assert not COMMIT["messageHeadline"].startswith("Merge "), "the recorded commit the rows copy is a merge"
    return C({**COMMIT, "committedDate": _iso(at)})


def merge_commit(at: dt.datetime, head: str, headline: str = MERGE_HEADLINE, parents: int = 2) -> C:
    """A commit headed `headline` (`<head>` filled) with `parents` parents: two is a merge commit, one is content."""
    return C({**COMMIT, "messageHeadline": headline.replace("<head>", head), "committedDate": _iso(at)}, parents)


def review(state: str, at: dt.datetime, source: dict = REVIEW) -> dict:
    return {**source, "author": {**source["author"], "login": BOT}, "state": state, "submittedAt": _iso(at)}


# ── the decoders: one cell → overrides on the board ───────────────────────────────────────────────


def base(b: Board, cell: str) -> None:
    """`#101`, `#102` → master · `#101` → master, `#110` → goal/x: armed ∧ BEHIND, created in the order named."""
    if cell == "—":
        return
    lanes = re.findall(r"((?:`#\d+`(?:, )?)+) → ([\w/.-]+)", cell)
    if ", ".join(f"{prs} → {lane}" for prs, lane in lanes) != cell:
        raise ValueError(f"base cell {cell!r}: want `#n`[, `#n`] → <base>, comma-separated")
    for prs, lane in lanes:
        for pr in ticks(prs):
            b.add(pr)
            b.armed_behind(pr).set(pr, "baseRefName", lane).set(pr, "createdAt", _iso(CREATED + len(b.added) * HOUR))


APPROVED_AT_HEAD = "`reviewDecision \"\"`, the bot's `reviews[]` APPROVED post-dates the newest non-merge commit"
HAND_TITLED_AFTER = (
    "`reviewDecision \"\"`, the bot's `reviews[]` APPROVED post-dates the newest content commit; "
    "a later commit has two parents and the headline `Merge master into <head>`"
)
MERGE_TITLED_CONTENT = (
    "`reviewDecision \"\"`, the bot's APPROVED is older than a later commit with one parent and the headline "
    "`Merge branch 'master' into <head>` (content: stale)"
)
NO_REVIEW = "`reviewDecision \"\"`, no review, no `automerge` label"
BREAKERED = "; the PR carries `agent/error`"


def pick_review(b: Board, cell: str) -> None:
    if cell == "— (no armed ∧ BEHIND PR: `#90` is CLEAN, `#91` un-armed)":
        assert not b.added, "the row adds a PR its review cell says is not there"
        return
    prs = list(b.added)
    if cell.endswith(BREAKERED):  # the PR carries `agent/error`
        cell = cell.removesuffix(BREAKERED)
        for pr in prs:
            b.set(pr, "labels", [{**LABEL, "name": "agent/error"}])
    if cell.endswith(" (both PRs)"):
        assert len(prs) == 2, cell
        cell = cell.removesuffix(" (both PRs)")
    if not prs:
        raise ValueError(f"review cell {cell!r} with no PR named in the base cell")
    for pr in prs:
        if cell == APPROVED_AT_HEAD:
            b.set(pr, "reviewDecision", "").set(pr, "reviews", [review("APPROVED", T + HOUR)]).commits(pr, [content_commit(T)])
        elif cell == HAND_TITLED_AFTER:  # two parents, so a merge commit whatever its headline: not content
            head = SNAP[b.idx(pr)]["headRefName"]
            b.set(pr, "reviewDecision", "").set(pr, "reviews", [review("APPROVED", T + HOUR)])
            b.commits(pr, [content_commit(T), merge_commit(T + 2 * HOUR, head, "Merge master into <head>")])
        elif cell == MERGE_TITLED_CONTENT:  # one parent, so content whatever its headline: the approval is stale
            head = SNAP[b.idx(pr)]["headRefName"]
            b.set(pr, "reviewDecision", "").set(pr, "reviews", [review("APPROVED", T + HOUR)])
            b.commits(pr, [content_commit(T), merge_commit(T + 2 * HOUR, head, MERGE_HEADLINE, parents=1)])
        elif cell == "`reviewDecision \"\"`, the bot's APPROVED is older than a later content commit (stale)":
            b.set(pr, "reviewDecision", "").set(pr, "reviews", [review("APPROVED", T - HOUR)]).commits(pr, [content_commit(T)])
        elif cell in (NO_REVIEW, NO_REVIEW + " (not merge-ready)"):
            b.set(pr, "reviewDecision", "")  # no review, no label: the World line's start
        elif cell == "`REVIEW_REQUIRED` (park); `latestReviews` bot COMMENTED, `reviews[]` bot APPROVED at head":
            b.set(pr, "reviewDecision", "REVIEW_REQUIRED").set(pr, "latestReviews", [review("COMMENTED", T + HOUR, LATEST)])
            b.set(pr, "reviews", [review("APPROVED", T + HOUR)]).commits(pr, [content_commit(T)])
        elif cell == "`REVIEW_REQUIRED` (park); `latestReviews` bot APPROVED":
            b.set(pr, "reviewDecision", "REVIEW_REQUIRED").set(pr, "latestReviews", [review("APPROVED", T + HOUR, LATEST)])
        else:
            raise ValueError(f"review cell {cell!r}: no decoder")


def fault(b: Board, cell: str, the_pr: str | None = None) -> None:
    if cell == "—":
        return
    if m := re.fullmatch(r"the `update-branch` PUT for `(#\d+)` answers 422", cell):
        b.w.fault("update-branch", "status", status=422)  # its first call; `check` proves that call is this PR's
        b.faulted.append(("update-branch", m[1]))
    elif m := re.fullmatch(r"the commit probe for `(#\d+)` answers a non-JSON body", cell):
        b.w.fault(commit_probe(b.n(m[1])), "non-json")
    elif m := re.fullmatch(r"the pull-commits read for `(#\d+)` fails", cell):
        b.w.fault(parents_read(b.n(m[1])), "fail")
    elif cell == "the pull-commits read for the PR fails":
        assert the_pr is not None, cell
        b.w.fault(parents_read(b.n(the_pr)), "fail")
    elif m := re.fullmatch(r"the snapshot's entry for `(#\d+)` has no `(\w+)` field", cell):
        b.w.fault(SNAPSHOT, "absent", field=(b.idx(m[1]), m[2]))
    elif cell == "the check-runs read for the PR's head answers an error":
        assert the_pr is not None, cell
        b.w.fault(check_runs(b.n(the_pr)), "fail")
    elif m := re.fullmatch(r"the check-runs read for `(#\d+)`'s head answers an error", cell):
        b.w.fault(check_runs(b.n(m[1])), "fail")
    else:
        raise ValueError(f"fault cell {cell!r}: no decoder")


def env(b: Board, cell: str) -> None:
    if cell == "—":
        return
    [assignment] = ticks(cell)
    if f"`{assignment}`" != cell or "=" not in assignment:
        raise ValueError(f"env cell {cell!r}: want one `NAME=value`")
    k, _, v = assignment.partition("=")
    b.env[k] = v


UNSTRAND_PR = "#120"  # the UNSTRAND World line


def unstrand_probe(b: Board, cell: str) -> None:
    pr = b.add(UNSTRAND_PR)
    b.armed_behind(pr).set(pr, "reviewDecision", "CHANGES_REQUESTED").set(pr, "baseRefName", "master")
    assert SNAP[b.idx(pr)]["author"]["login"] and not SNAP[b.idx(pr)]["author"]["login"].startswith(("homelab-renovate", "app/homelab-renovate"))
    if cell == "unreadable (non-JSON body)":
        b.w.fault(review_probe(b.n(pr)), "non-json")
        return
    if cell == "commits and reviews readable; the pull-commits read fails":
        b.commits(pr, [content_commit(T)], review_probe)
        b.w.set(review_probe(b.n(pr)), ("reviews",), [review("CHANGES_REQUESTED", T + HOUR, PROBE_REVIEW)])
        b.w.fault(parents_read(b.n(pr)), "fail")
        return
    m = re.fullmatch(
        r"(newest non-merge commit|a content commit) (\d\d):00 (after|before) the bot's CHANGES_REQUESTED (\d\d):00"
        r"(?:; the (\d\d):00 commit has (two|one) parents? and the headline `([^`]+)`(?: \(a merge commit, not content\))?)?",
        cell,
    )
    if not m:
        raise ValueError(f"probe cell {cell!r}: no decoder")
    day = T.replace(minute=0, second=0, microsecond=0)
    content, verdict = day.replace(hour=int(m[2])), day.replace(hour=int(m[4]))
    assert (content > verdict) == (m[3] == "after"), cell
    commits = [content_commit(content)]
    if m[5]:
        later = day.replace(hour=int(m[5]))
        assert later > verdict, cell
        commits.append(merge_commit(later, SNAP[b.idx(pr)]["headRefName"], m[7], parents=2 if m[6] == "two" else 1))
    b.commits(pr, commits, review_probe)
    b.w.set(review_probe(b.n(pr)), ("reviews",), [review("CHANGES_REQUESTED", verdict, PROBE_REVIEW)])


def pr90(b: Board, cell: str) -> None:
    if cell == "armed ∧ DIRTY, no `merge-conflict` label":
        b.set("#90", "mergeStateStatus", "DIRTY")
        assert all(lb["name"] != "merge-conflict" for lb in SNAP[b.idx("#90")]["labels"])
        b.dirty = "#90"
    elif cell == "carries `merge-conflict`, no longer armed ∧ DIRTY":
        b.set("#90", "labels", [{**LABEL, "name": "merge-conflict"}])  # and stays armed ∧ CLEAN
        b.labelled = "#90"
    elif cell != "`#90` not exercised":
        raise ValueError(f"#90 cell {cell!r}: no decoder")


def pr101(b: Board, cell: str) -> None:
    if cell == "—":
        return
    if cell != "armed ∧ BEHIND, not DIRTY, `reviewDecision \"\"`, the bot's APPROVED post-dates its newest non-merge commit":
        raise ValueError(f"#101 cell {cell!r}: no decoder")
    b.add("#101")
    b.armed_behind("#101").set("#101", "reviewDecision", "").set("#101", "reviews", [review("APPROVED", T + HOUR)])
    b.commits("#101", [content_commit(T)])


RENOVATE_PR = "#150"  # the RENOVATE World line


def renovate_world(b: Board) -> str:
    pr = b.add(RENOVATE_PR)
    b.set(pr, "autoMergeRequest", ARMED).set(pr, "baseRefName", "master").set(pr, "author", {**SNAP[b.idx(pr)]["author"], "login": RENOVATE_LIST})
    body = _recorded(pull(b.n(pr)))["body"] or ""
    b.w.set(pull(b.n(pr)), ("body",), body + "\n\n" + BOX_OFF + "If you want to rebase/retry this PR, check this box\n")
    b.w.set(status(b.n(pr)), ("statuses",), []).set(status(b.n(pr)), ("total_count",), 0)
    return pr


def renovate_review(b: Board, pr: str, cell: str) -> None:
    if cell == "`APPROVED`, BEHIND":
        b.set(pr, "reviewDecision", "APPROVED").set(pr, "mergeStateStatus", "BEHIND")
    elif cell == "`REVIEW_REQUIRED`, no review, PR CURRENT (BLOCKED, not BEHIND)":
        b.set(pr, "reviewDecision", "REVIEW_REQUIRED").set(pr, "mergeStateStatus", "BLOCKED")
    else:
        raise ValueError(f"review cell {cell!r}: no decoder")


def _authored(commit: C, login: str) -> C:
    return C({**commit.view, "authors": [{**COMMIT["authors"][0], "login": login}]}, commit.parents)


def renovate_commits(b: Board, pr: str, cell: str) -> None:
    other = COMMIT["authors"][0]["login"]
    assert not other.startswith("homelab-renovate"), "the recorded author the rows use as 'not Renovate' is Renovate"
    parts = cell.split(" + ")
    if parts[0] not in ("Renovate", "Renovate only") or (parts[0] == "Renovate only") != (len(parts) == 1):
        raise ValueError(f"commits cell {cell!r}: want `Renovate only` or `Renovate + …`")
    head = SNAP[b.idx(pr)]["headRefName"]
    commits = [_authored(content_commit(T), RENOVATE_COMMIT)]
    for i, part in enumerate(parts[1:], 1):
        if part == "a worker commit":
            commits.append(_authored(content_commit(T + i * HOUR), other))
        elif part == "an updater merge commit":  # the World line: two parents, `Merge branch 'master' into <head>`
            commits.append(_authored(merge_commit(T + i * HOUR, head), other))
        elif m := re.fullmatch(r"a (two|one)-parent commit by another login, headline `([^`]+)`", part):
            commits.append(_authored(merge_commit(T + i * HOUR, head, m[2], parents=2 if m[1] == "two" else 1), other))
        else:
            raise ValueError(f"commits cell {cell!r}: no decoder for {part!r}")
    b.commits(pr, commits)


_CHECK = {"success": ("completed", "success"), "failure": ("completed", "failure"),
          "cancelled": ("completed", "cancelled"), "in progress": ("in_progress", None)}
_ONE = r"`([\w-]+)` (success|failure|cancelled|in progress)"


def _run(name: str, state: str, at: dt.datetime) -> dict:
    run_status, conclusion = _CHECK[state]
    done = _iso(at + HOUR) if conclusion else None
    return {**CHECK_RUN, "name": name, "status": run_status, "conclusion": conclusion, "started_at": _iso(at), "completed_at": done}


def ci(b: Board, cell: str) -> None:
    """The World line's `ci` cell: every PR the row adds has one `ci` run at its head, completed `success`, unless the cell
    says otherwise; the cell's base read is the check runs at `master`'s head (`—`: the base's is not read)."""
    day = T.replace(minute=0, second=0, microsecond=0)
    for pr in b.added:
        _set_runs(b, check_runs(b.n(pr)), [_run("ci", "success", T)])
    if cell == "—":
        return
    m = re.fullmatch(
        r"PR `(success|failure)` (\d\d):00( \(both PRs\))?; base(?: `(success|failure)` (\d\d):00"
        r"|: no `ci` run \(one `approve / approve` run, `skipped`, (\d\d):00\))",
        cell,
    )
    if not m:
        raise ValueError(f"ci cell {cell!r}: no decoder")
    assert bool(m[3]) == (len(b.added) == 2), f"{cell!r}: `(both PRs)` and the PRs the row adds disagree"
    for pr in b.added:
        _set_runs(b, check_runs(b.n(pr)), [_run("ci", m[1], day.replace(hour=int(m[2])))])
    if m[4]:
        base_run = _run("ci", m[4], day.replace(hour=int(m[5])))
    else:  # a goal head reads green on two skipped runs: no `ci` run
        base_run = {**_run("approve / approve", "success", day.replace(hour=int(m[6]))), "conclusion": "skipped"}
    _set_runs(b, base_ci(), [base_run])


def _set_runs(b: Board, file: str, runs: list[dict]) -> None:
    b.w.set(file, ("check_runs",), runs).set(file, ("total_count",), len(runs))


def checks(b: Board, pr: str, cell: str, fault_cell: str) -> None:
    file = check_runs(b.n(pr))
    if cell == "not read":  # the commit probe is unreadable before the rollup: no read is issued
        assert fault_cell == "the pull-commits read for the PR fails", f"checks `not read` with fault {fault_cell!r}"
        return
    if cell == "unreadable":
        assert fault_cell == "the check-runs read for the PR's head answers an error", f"checks `unreadable` with fault {fault_cell!r}"
        return
    runs: list[dict] = []
    if cell != "none reported":
        items = list(re.finditer(rf"{_ONE}(?:, outlived by {_ONE})?", cell))
        if ", ".join(m[0] for m in items) != cell:
            raise ValueError(f"checks cell {cell!r}: no decoder")
        for m in items:
            runs.append(_run(m[1], m[2], T))
            if m[3]:  # a same-named sibling started after the first concluded
                assert m[3] == m[1], f"{cell!r}: `outlived by` names another check"
                runs.append(_run(m[3], m[4], T + 2 * HOUR))
    b.w.set(file, ("check_runs",), runs).set(file, ("total_count",), len(runs))


# ── the legend: what a literal states ─────────────────────────────────────────────────────────────

[LEGEND] = [{r[0].strip("`"): r[1:] for r in rows} for _q, h, rows in TABLES if h[0] == "literal"]


@dataclass
class Expect:
    probes: int
    fields: str  # the probe's --json list
    rollup: str | None  # "both" | "check-runs-only" | None
    updates: list[tuple[str, bool]]  # (who, whether the PUT succeeds), in order
    label: str | None  # "add" | "remove" | None
    handback: bool
    phrases: list[str]  # quoted lines, `#n` still unbound
    per_update: str | None  # a line quoted once per update ("an `updating` line per PR")
    only: bool  # the quoted lines are the whole output
    stderr: bool  # gh's stderr of the failed PUT passes through
    rc: int
    ci: int = 0  # the ci reads: one per pull request the leg asks (the PRs the row adds, oldest first)
    base_ci: int = 0  # the base ci reads
    per_pr: str | None = None  # a line quoted once per pull request the row adds, each with its own number


_PROBES = re.compile(
    r"(\d+)(?: \((?:the candidate|both candidates|`(?:--json )?(commits,reviews)`)\))?"
    r"(, unreadable|, plus the rollup reads(?: \(check-runs, status\))?|, then the check-runs read fails)?"
)
_UPDATES = {
    "none": [],
    "one `update-branch` PUT for the picked PR": [("oldest", True)],
    "one PUT": [("oldest", True)],
    "one PUT, for the older PR": [("oldest", True)],
    "two PUTs, one per base lane": [("oldest-per-lane", True)],
    "PUT for the older PR (422, skipped), then PUT for the lane's next PR": [("oldest", False), ("next", True)],
    "one PUT for the Renovate PR": [("the PR", True)],
    "one PUT for the pull request": [("the PR", True)],
    "one PUT for the CR ∧ BEHIND PR": [("the PR", True)],
}
_NOT_A_LINE = re.compile(r"action\.label\.op|^(POST|DELETE) |^--json ")


def _ci_probes(cell: str) -> tuple[int, int, int] | None:
    """`0, plus the ci read (the candidate)` → (probes, ci reads, base ci reads); None for a cell that is not one."""
    m = re.fullmatch(
        r"(\d+), plus the ci read( of both candidates| \(the candidate\))?( and the base ci read| and one base ci read)?(, unreadable)?", cell
    )
    if not m:
        return None
    return int(m[1]), 2 if m[2] == " of both candidates" else 1, 1 if m[3] else 0


def expect(literal: str) -> Expect:
    probes_cell, updates_cell, other = LEGEND[literal]
    cip = _ci_probes(probes_cell)
    m = _PROBES.fullmatch(probes_cell) if cip is None else _PROBES.fullmatch(f"{cip[0]}")
    if not m:
        raise ValueError(f"legend {literal}: probes cell {probes_cell!r}: no decoder")
    rollup = {None: None, ", unreadable": None, ", then the check-runs read fails": "check-runs-only"}.get(m[3], "both")
    if updates_cell in _UPDATES:
        updates = list(_UPDATES[updates_cell])
    elif u := re.fullmatch(r"one PUT for `(#\d+)`, which fails", updates_cell):
        updates = [(u[1], False)]
    else:
        raise ValueError(f"legend {literal}: updates cell {updates_cell!r}: no decoder")
    e = Expect(int(m[1]), m[2] or "commits", rollup, updates, None, False, [], None, False, False, 0)
    if cip:
        e.ci, e.base_ci = cip[1], cip[2]
    if two := re.fullmatch(
        r"as `([\w-]+)`, the `inherited red` line once per pull request, each with that pull request's own number \(the older's first\); "
        r"the `updating` line's `#n` is the older's",
        other,
    ):
        base_e = expect(two[1])
        e.per_pr = next(p for p in base_e.phrases if "inherited red" in p)
        e.phrases = [p for p in base_e.phrases if p != e.per_pr]
        return e
    if inherit := re.fullmatch(r"as `([\w-]+)`", other):
        base_e = expect(inherit[1])
        e.phrases, e.per_update, e.label, e.handback, e.only = base_e.phrases, base_e.per_update, base_e.label, base_e.handback, base_e.only
        e.per_pr = base_e.per_pr
        return e
    if lab := re.match(r"label op \(`action\.label\.op` = (add|remove)\)", other):
        e.label = lab[1]
    e.handback = other.startswith(("hand-back:", "the same hand-back"))
    e.only = re.search(r"\bonly (the line )?`", other) is not None
    e.stderr = "gh's stderr passes through" in other or "gh's stderr on ERR" in other
    if rc := re.search(r"the pass exits (\d+)", other):
        e.rc = int(rc[1])
    if other == "an `updating` line per PR":
        e.per_update = "updating #n"
        return e
    e.phrases = [p for p in ticks(other) if not _NOT_A_LINE.search(p) and p not in LEGEND]
    return e


def _targets(b: Board, e: Expect) -> list[tuple[str, bool]]:
    """The legend's `who` resolved against the PRs the row added (named oldest first)."""
    out: list[tuple[str, bool]] = []
    for who, ok in e.updates:
        if who == "oldest":
            out.append((b.added[0], ok))
        elif who == "next":
            lane = _base_of(b, b.added[0])
            out.append((next(p for p in b.added[1:] if _base_of(b, p) == lane), ok))
        elif who == "oldest-per-lane":
            seen: dict[str, str] = {}
            for p in b.added:
                seen.setdefault(_base_of(b, p), p)
            out += [(p, ok) for p in seen.values()]
        elif who == "the PR":
            [only] = b.added
            out.append((only, ok))
        else:
            out.append((who, ok))
    return out


def _base_of(b: Board, page_n: str) -> str:
    """The base the row's cells gave the PR."""
    return b.w.get(SNAPSHOT, (b.idx(page_n), "baseRefName"))  # type: ignore[return-value]


def phrases_of(b: Board, e: Expect, targets: list[tuple[str, bool]]) -> list[str]:
    """The literal's quoted lines with `#n` bound: to the updates' PRs in order, or — a literal that updates
    nothing (a hold, a hand-back) — to the one PR the row adds; a literal `#101` → its recorded number."""
    numbers = [b.n(p) for p, _ in targets] or [b.n(p) for p in b.added[:1]]
    phrases = [e.per_update] * len(targets) if e.per_update else e.phrases
    it = iter(numbers)
    out = [e.per_pr.replace("#n", f"#{b.n(pr)}") for pr in b.added] if e.per_pr else []
    last = numbers[-1] if numbers else 0
    for p in phrases:
        p = re.sub(r"#(\d+)", lambda m: f"#{b.n(m[0])}", p)
        while "#n" in p:
            p = p.replace("#n", f"#{next(it, last)}", 1)  # a second `#n` of one literal names the same pull request
        out.append(p)
    return out


def line_matches(phrase: str, out: str) -> bool:
    """A quoted line matches within one printed line; `…` is any text."""
    frags = [f for f in phrase.split("…")]
    pattern = ".*".join(re.escape(f) for f in frags)
    return any(re.search(pattern, line) for line in out.splitlines())


# ── what the process issued ───────────────────────────────────────────────────────────────────────

_FILES: dict[str, tuple] = {SNAPSHOT: ("snapshot",), base_ci(): ("base-ci",)}
for _n in ITEMS:
    _FILES[parents_read(_n)] = ("parents", _n)
    _FILES[commit_probe(_n)] = ("probe", _n, "commits")
    _FILES[review_probe(_n)] = ("probe", _n, "commits,reviews")
    _FILES[check_runs(_n)] = ("check-runs", _n)
    _FILES[status(_n)] = ("status", _n)
    _FILES[pull(_n)] = ("body", _n)


def _path(call: dict) -> str:
    return next(a for a in call["argv"][1:] if a.startswith("repos/"))


def classify(call: dict) -> tuple:
    if call["kind"] == "read":
        return _FILES.get(call["file"], ("other", call["argv"]))
    op, path = call.get("op"), _path(call)
    if op == "update-branch":
        sha = next((a.removeprefix("expected_head_sha=") for a in call["argv"] if a.startswith("expected_head_sha=")), None)
        return ("put", int(re.search(r"/pulls/(\d+)/", path)[1]), call["rc"] == 0, sha)  # type: ignore[index]
    if op == "create-label":
        return ("create-label",)
    if op == "add-labels":
        return ("add-label", int(re.search(r"/issues/(\d+)/", path)[1]), [a for a in call["argv"] if a.startswith("labels[]=")])  # type: ignore[index]
    if op == "remove-label":
        return ("remove-label", int(re.search(r"/issues/(\d+)/", path)[1]), path.rsplit("/", 1)[1])  # type: ignore[index]
    if op == "update-pull":
        body = next(a.removeprefix("body=") for a in call["argv"] if a.startswith("body="))
        return ("patch", int(re.search(r"/pulls/(\d+)$", path)[1]), body)  # type: ignore[index]
    return ("other", call["argv"])


def run(b: Board) -> Run:
    return b.w.run([*COMPONENT, REPO], env=b.env)


def check(b: Board, literal: str, note: str = "") -> Run:
    e = expect(literal)
    targets = _targets(b, e)
    with allure.step(f"When the updater runs on {REPO} ({', '.join(f'{k} = #{v}' for k, v in b.alias.items())})"):
        r = run(b)
        allure.attach(r.stdout + r.stderr, "output", allure.attachment_type.TEXT)
    calls = [classify(c) for c in r.calls]
    trace = f"\ncalls: {json.dumps(r.calls, indent=1)}\nstdout:\n{r.stdout}\nstderr:\n{r.stderr}"
    with allure.step(f"Then it issues {literal}: {' | '.join(LEGEND[literal])}"):
        assert calls[:1] == [("snapshot",)] and calls.count(("snapshot",)) == 1, trace
        assert not [c for c in calls if c[0] == "other"], trace
        probes = [c for c in calls if c[0] == "probe"]
        assert len(probes) == e.probes and {c[2] for c in probes} <= {e.fields}, f"probes {probes}, want {e.probes} × {e.fields}{trace}"
        # the pull-commits read follows each probe whose view was readable, for the same pull request, right after it
        unreadable_views = {i for i, (c, raw) in enumerate(zip(calls, r.calls, strict=True)) if c[0] == "probe" and raw.get("fault")}
        for i, c in enumerate(calls):
            if c[0] == "probe" and i not in unreadable_views:
                assert calls[i + 1 : i + 2] == [("parents", c[1])], f"no pull-commits read right after the probe of #{c[1]}{trace}"
        assert [c for c in calls if c[0] == "parents"] == [("parents", c[1]) for i, c in enumerate(calls) if c[0] == "probe" and i not in unreadable_views], trace
        runs_, stats = [c for c in calls if c[0] == "check-runs"], [c for c in calls if c[0] == "status"]
        base_reads = [c for c in calls if c[0] == "base-ci"]
        assert len(base_reads) == e.base_ci, f"base ci reads {base_reads}, want {e.base_ci}{trace}"
        if e.rollup is None and e.ci:  # the inherited-red leg's reads: one ci read per PR it asks, after every probe
            assert not stats and len(b.added) == e.ci, trace
            assert runs_ == [("check-runs", b.n(p)) for p in b.added], trace
            assert all(calls.index(c) < calls.index(runs_[0]) for c in calls if c[0] in ("probe", "parents")), trace
            assert all(calls.index(runs_[0]) < calls.index(c) for c in base_reads), trace  # the base is read once a PR failed
        elif e.rollup is None:
            assert not runs_ and not stats, trace
        else:
            [pr] = b.added
            assert runs_ == [("check-runs", b.n(pr))], trace
            assert calls.index(("parents", b.n(pr))) < calls.index(("check-runs", b.n(pr))), trace  # the rollup follows the parents read
            assert stats == ([("status", b.n(pr))] if e.rollup == "both" else []), trace
        puts = [(c[1], c[2]) for c in calls if c[0] == "put"]
        want = [(b.n(p), ok) for p, ok in targets]
        if e.updates and e.updates[0][0] == "oldest-per-lane":  # the page names no lane order
            puts, want = sorted(puts), sorted(want)
        assert puts == want, f"PUTs {puts}, want {want}{trace}"
        for c in calls:  # schema `action.update` requires expected_head_sha: the PR's own head
            if c[0] == "put":
                assert c[3] == SNAP[INDEX[c[1]]]["headRefOid"], trace
        labels = [c for c in calls if c[0] in ("create-label", "add-label", "remove-label")]
        if e.label == "add":
            assert labels == [("create-label",), ("add-label", b.n(b.dirty), ["labels[]=merge-conflict"])], trace  # type: ignore[arg-type]
        elif e.label == "remove":
            assert labels == [("remove-label", b.n(b.labelled), "merge-conflict")], trace  # type: ignore[arg-type]
        else:
            assert not labels, trace
        hand = [c for c in calls if c[0] in ("body", "patch")]
        if e.handback:
            [pr] = b.added
            assert [c[:2] for c in hand] == [("body", b.n(pr)), ("patch", b.n(pr))], trace
            assert BOX_ON in hand[1][2] and BOX_OFF not in hand[1][2], trace
        else:
            assert not hand, trace
        for target, page_n in b.faulted:  # a fault that fires on a call's n-th occurrence hit the PR its cell named
            hit = [c for c, raw in zip(calls, r.calls, strict=True) if raw.get("fault") and raw.get("op") == target]
            assert hit and all(c[1] == b.n(page_n) for c in hit), f"the {target} fault fired on {hit}, want {page_n}{trace}"
        assert r.rc == e.rc, f"rc {r.rc}, want {e.rc}{trace}"
    phrases = phrases_of(b, e, targets)
    for p in phrases:
        with allure.step(f"And it prints a line matching `{p}`"):
            assert line_matches(p, r.stdout), f"`{p}` not printed{trace}"
    if e.only:
        assert len(r.stdout.splitlines()) == len(phrases), f"more than the quoted lines printed{trace}"
    if e.stderr:
        assert "(HTTP 422)" in r.stderr, trace
    return r


def _expect_parenthetical(b: Board, cell: str) -> str:
    """The `expect?` cell: its literal, with the parenthetical's `#n` and `action.label.op` held to the legend."""
    literal, _, note = cell.partition(" ")
    assert literal in LEGEND, f"{cell!r}: no such literal in the legend"
    e = expect(literal)
    named = [b.n(p) for p in re.findall(r"`(#\d+)`", note)]
    assert set(named) <= {b.n(p) for p, _ in _targets(b, e)}, f"{cell!r} names a PR the legend's updates do not touch"
    if op := re.search(r"`action\.label\.op` = (\w+)", note):
        assert op[1] == e.label, cell
    return literal


# ── the cases ─────────────────────────────────────────────────────────────────────────────────────

PICK_Q, UNSTRAND_Q = "Which PR does the main leg update?", "Is a changes-requested, behind PR brought current?"
CONFLICT_Q, RENOVATE_Q = "Does an armed, conflicted PR carry the label — and only while it is?", "Whose currency is this Renovate PR?"


def pick_board(world: str, base_cell: str, review_cell: str, ci_cell: str, fault_cell: str, env_cell: str) -> Board:
    assert world == WORLD, world
    b = Board()
    base(b, base_cell)
    pick_review(b, review_cell)
    ci(b, ci_cell)
    fault(b, fault_cell)
    env(b, env_cell)
    return b


def unstrand_board(world: str, probe_cell: str) -> Board:
    assert world == WORLD, world
    b = Board()
    unstrand_probe(b, probe_cell)
    return b


def conflict_board(world: str, pr90_cell: str, pr101_cell: str, fault_cell: str) -> Board:
    assert world == WORLD, world
    b = Board()
    pr90(b, pr90_cell)
    pr101(b, pr101_cell)
    fault(b, fault_cell)
    return b


def renovate_board(world: str, review_cell: str, commits_cell: str, checks_cell: str, fault_cell: str) -> Board:
    assert world == WORLD, world
    b = Board()
    pr = renovate_world(b)
    renovate_review(b, pr, review_cell)
    renovate_commits(b, pr, commits_cell)
    checks(b, pr, checks_cell, fault_cell)
    fault(b, fault_cell, the_pr=pr)
    return b


PICK_ARGS, PICK_ROWS = params(TABLES, PICK_Q)
UNSTRAND_ARGS, UNSTRAND_ROWS = params(TABLES, UNSTRAND_Q)
CONFLICT_ARGS, CONFLICT_ROWS = params(TABLES, CONFLICT_Q)
RENOVATE_ARGS, RENOVATE_ROWS = params(TABLES, RENOVATE_Q)


@rule("SCAN-UPDATER-PICK")
@pytest.mark.parametrize(PICK_ARGS, PICK_ROWS)
def test_pick(world, base, review, ci, fault, env, expected_expect):
    with allure.step(f"Given {world}: base {base}; review {review}; ci {ci}; fault {fault}; env {env}"):
        b = pick_board(world, base, review, ci, fault, env)
    check(b, _expect_parenthetical(b, expected_expect))


@rule("SCAN-UPDATER-UNSTRAND")
@pytest.mark.parametrize(UNSTRAND_ARGS, UNSTRAND_ROWS)
def test_unstrand(world, probe, expected_expect):
    with allure.step(f"Given {world} and {UNSTRAND_PR} changes-requested ∧ BEHIND, its probe: {probe}"):
        b = unstrand_board(world, probe)
    check(b, _expect_parenthetical(b, expected_expect))


@rule("SCAN-UPDATER-CONFLICT")
@pytest.mark.parametrize(CONFLICT_ARGS, CONFLICT_ROWS)
def test_conflict(world, pr90_before_the_pass, pr101, fault, expected_expect):
    with allure.step(f"Given {world}: #90 {pr90_before_the_pass}; #101 {pr101}; fault {fault}"):
        b = conflict_board(world, pr90_before_the_pass, pr101, fault)
    check(b, _expect_parenthetical(b, expected_expect))


@rule("SCAN-UPDATER-RENOVATE")
@pytest.mark.parametrize(RENOVATE_ARGS, RENOVATE_ROWS)
def test_renovate(world, review, commits, checks, fault, expected_expect):
    with allure.step(f"Given {world} and Renovate's {RENOVATE_PR}: {review}; commits {commits}; checks {checks}; fault {fault}"):
        b = renovate_board(world, review, commits, checks, fault)
    check(b, _expect_parenthetical(b, expected_expect))


# ── unlabelled: the decoders, the World line and the strict read, held against the page and its schema ──

BUILDERS = {PICK_Q: pick_board, UNSTRAND_Q: unstrand_board, CONFLICT_Q: conflict_board, RENOVATE_Q: renovate_board}


def every_row() -> list[tuple[str, Board, str]]:
    out = []
    for q, build in BUILDERS.items():
        _header, rows = table(TABLES, q)
        for row in rows:
            b = build(*row[1:-1])
            out.append((row[0], b, _expect_parenthetical(b, row[-1])))
    return out


def test_the_tables_hold_the_rows_the_issue_counts():
    counts = {q: len(table(TABLES, q)[1]) for q in BUILDERS}
    assert counts == {PICK_Q: 26, UNSTRAND_Q: 6, CONFLICT_Q: 3, RENOVATE_Q: 12}, counts


def test_rows_differ_by_input_cells():
    """Rows check 10: within a table no two rows share every input cell (description and expect hidden)."""
    for q in BUILDERS:
        _header, rows = table(TABLES, q)
        inputs = [tuple(r[1:-1]) for r in rows]
        assert len(set(inputs)) == len(inputs), q


def test_the_world_line_holds_on_the_recording():
    """The World line's claims on the recording: two spare entries, and no unnamed entry any leg acts on."""
    assert len(SPARE) >= 2 and len(ITEMS) >= 2
    for e in SNAP:
        assert e["mergeStateStatus"] != "BEHIND", e["number"]
        assert not (e["autoMergeRequest"] and e["mergeStateStatus"] == "DIRTY"), e["number"]
        assert "merge-conflict" not in [lb["name"] for lb in e["labels"]], e["number"]


def test_the_renovate_world_values_are_the_pages():
    [renovate_world_line] = [p for p in TEXT.split("\n\n") if p.startswith(f"**World:** the one above, plus `{RENOVATE_PR}`")]
    for value in (RENOVATE_LIST, RENOVATE_COMMIT, BOX_OFF, MERGE_HEADLINE):
        assert f"`{value}`" in renovate_world_line, value
    assert f"plus `{UNSTRAND_PR}` → master" in TEXT


def _signature(r: Run) -> tuple:
    return tuple((c[0], c[2]) if c[0] == "put" else c[0] for c in map(classify, r.calls))


def _observable(literal: str, b: Board, out: str) -> bool:
    e = expect(literal)
    phrases = phrases_of(b, e, _targets(b, e))
    if e.only and len(out.splitlines()) != len(phrases):
        return False
    return all(line_matches(p, out) for p in phrases)


def test_outcome_lines_are_mutually_exclusive():
    """Literals whose passes issue the same calls are told apart by their quoted lines alone (the legend's ⚖):
    no literal's quoted lines match the output of another literal with the same call signature."""
    runs = [(rid, b, lit, run(b)) for rid, b, lit in every_row()]
    groups: dict[tuple, list] = {}
    for rid, b, lit, r in runs:
        groups.setdefault(_signature(r), []).append((rid, b, lit, r))
    pairs = 0
    for members in groups.values():
        for _rid, b, lit, _r in members:
            for other_id, _ob, other_lit, other_r in members:
                if other_lit != lit:
                    pairs += 1
                    assert not _observable(lit, b, other_r.stdout), f"{lit}'s lines match {other_id} ({other_lit}):\n{other_r.stdout}"
    assert pairs, "no two literals share a call signature — the exclusion proves nothing"


# The strict read (pin 5), over every required path of each schema part.


def _resolve(node: dict) -> dict:
    while "$ref" in node:
        node = SCHEMA["$defs"][node["$ref"].removeprefix("#/$defs/")]
    return node


def _types(node: dict) -> tuple[str, bool]:
    node = _resolve(node)
    t = node.get("type", "string" if "enum" in node else None)
    ts = t if isinstance(t, list) else [t]
    return next(x for x in ts if x != "null"), "null" in ts


def schema_paths(node: dict, where: tuple = ()) -> list[tuple[tuple, str, bool]]:
    """Every required field path of a schema node as (path, type, nullable); a list element stands at index 0."""
    node = _resolve(node)
    if node.get("type") == "array":
        return schema_paths(node["items"], (*where, 0))
    out = []
    for key in node.get("required", []):
        sub = node["properties"][key]
        out.append(((*where, key), *_types(sub)))
        out.extend(schema_paths(sub, (*where, key)))
    return out


def shape_paths(shape: object, where: tuple = ()) -> list[tuple[tuple, str, bool]]:
    from scan_island.strict import Nullable

    if isinstance(shape, list):  # a list read: each element stands at index 0
        return shape_paths(shape[0], (*where, 0))

    names = {str: "string", int: "integer", dict: "object", list: "array"}
    out = []
    for key, sub in shape.items():  # type: ignore[union-attr]
        nullable = isinstance(sub, Nullable)
        inner = sub.shape if nullable else sub
        kind = "object" if isinstance(inner, dict) else "array" if isinstance(inner, list) else names[inner]
        out.append(((*where, key), kind, nullable))
        if isinstance(inner, dict):
            out += shape_paths(inner, (*where, key))
        elif isinstance(inner, list) and isinstance(inner[0], dict):
            out += shape_paths(inner[0], (*where, key, 0))
    return out


def _shapes() -> dict[str, object]:
    from scan_island.merges import PULL_COMMITS_READ
    from scan_island.renovate import CHECK_RUNS_READ, COMMIT_PROBE, COMMIT_REVIEW_PROBE, STATUS_READ
    from scan_island.updater import CI_CHECK_READ, PR

    return {"pr": PR, "commit_probe": COMMIT_PROBE, "commit_review_probe": COMMIT_REVIEW_PROBE,
            "check_runs_read": CHECK_RUNS_READ, "status_read": STATUS_READ, "pull_commits_read": PULL_COMMITS_READ,
            "ci_check_read": CI_CHECK_READ}


@pytest.mark.parametrize("part", ["pr", "commit_probe", "commit_review_probe", "check_runs_read", "status_read", "pull_commits_read", "ci_check_read"])
def test_component_requires_exactly_the_schema_list(part):
    """Each read's required fields in the component are the schema part's: same paths, leaf types and nulls."""
    assert sorted(map(str, shape_paths(_shapes()[part]))) == sorted(map(str, schema_paths(SCHEMA["properties"][part])))


def _validate(data: object, part: str) -> None:
    import jsonschema

    jsonschema.validate(data, {**SCHEMA["properties"][part], "$defs": SCHEMA["$defs"]})


def test_the_recording_satisfies_the_schema():
    """Positive control: the schema's names are the recording's, read by read."""
    for e in SNAP:
        _validate(e, "pr")
    for n in ITEMS:
        _validate(_recorded(commit_probe(n)), "commit_probe")
        _validate(_recorded(review_probe(n)), "commit_review_probe")
        _validate(_recorded(check_runs(n)), "check_runs_read")
        _validate(_recorded(status(n)), "status_read")
        _validate(_recorded(parents_read(n)), "pull_commits_read")
        _validate(_recorded(check_runs(n)), "ci_check_read")
    _validate(_recorded(base_ci()), "ci_check_read")


def _row(q: str, rid: str) -> Board:
    [cells] = [r[1:-1] for r in table(TABLES, q)[1] if r[0] == rid]
    return BUILDERS[q](*cells)


def _pick_with_every_list_filled() -> Board:
    """`bot-approved-head-update`, its #141 also carrying a label and a `latestReviews` element, so every required
    path of `pr` exists on it (still picks-probe1: a label other than `automerge` and a COMMENTED latest review
    change nothing when `reviewDecision` is "")."""
    b = _row(PICK_Q, "bot-approved-head-update")
    b.set("#141", "labels", [LABEL]).set("#141", "latestReviews", [review("COMMENTED", T + HOUR, LATEST)])
    return b


PR_PATHS = [p for p, _t, _n in schema_paths(SCHEMA["properties"]["pr"])]


def test_the_strict_read_bases_are_the_rows_outcomes():
    """Positive controls for the absent-field cases below: unfaulted, each base issues its row's literal."""
    check(_pick_with_every_list_filled(), "picks-probe1")
    check(_row(UNSTRAND_Q, "unstrand-yes"), "unstrand-yes")
    b = _row(RENOVATE_Q, "renovate-untouched-green-update")
    pr = b.added[0]
    b.w.set(status(b.n(pr)), ("statuses",), [{**_recorded(status(b.n(pr)))["statuses"][0], "state": "success"}])
    check(b, "picks-probe1-renovate")


@pytest.mark.parametrize("path", PR_PATHS, ids=[".".join(map(str, p)) for p in PR_PATHS])
def test_a_snapshot_entry_lacking_a_required_field_is_unreadable(path):
    b = _pick_with_every_list_filled()
    b.w.fault(SNAPSHOT, "absent", field=(b.idx("#141"), *path))
    r = check(b, "unreadable-snapshot")
    assert f"without `[{b.idx('#141')}].{'.'.join(map(str, path)).replace('.0', '[0]')}`" in r.stdout, r.stdout


@pytest.mark.parametrize(("key", "value"), [("baseRefName", None), ("number", "141"), ("createdAt", None), ("headRefOid", None)])
def test_a_null_or_mistyped_required_field_is_unreadable(key, value):
    b = _row(PICK_Q, "bot-approved-head-update").set("#141", key, value)
    r = check(b, "unreadable-snapshot")
    assert f"with `[{b.idx('#141')}].{key}` not a" in r.stdout, r.stdout


def test_a_null_review_author_is_readable_and_no_verdict():
    """⚖ A review's `author` may be null (a deleted account): the snapshot stays readable, and the review is no one's
    verdict. The world cannot null an object (an override never removes a field), so this one runs in process;
    the comparison's `null-author-no-crash` row runs it as a process."""
    from scan_island.strict import lacking
    from scan_island.updater import PR, _is_bot, _reviewer

    entry = {**SNAP[INDEX[ITEMS[0]]]}
    entry["reviews"] = [{**REVIEW, "author": None}]
    entry["latestReviews"] = [{**LATEST, "author": None}]
    assert lacking([entry], [PR]) is None
    assert not _is_bot(entry["reviews"][0], BOT) and not _reviewer(entry["latestReviews"][0])
    entry["reviews"] = [{**REVIEW, "submittedAt": None}]
    assert lacking([entry], [PR]) == "with `[0].reviews[0].submittedAt` not a str"


COMMIT_PATHS = [p for p, _t, _n in schema_paths(SCHEMA["properties"]["commit_probe"])]
REVIEW_PATHS = [p for p, _t, _n in schema_paths(SCHEMA["properties"]["commit_review_probe"])]
RUNS_PATHS = [p for p, _t, _n in schema_paths(SCHEMA["properties"]["check_runs_read"])]
STATUS_PATHS = [p for p, _t, _n in schema_paths(SCHEMA["properties"]["status_read"])]
CI_PATHS = [p for p, _t, _n in schema_paths(SCHEMA["properties"]["ci_check_read"])]
PARENTS_PATHS = [p for p, _t, _n in schema_paths(SCHEMA["properties"]["pull_commits_read"])]


@pytest.mark.parametrize("path", COMMIT_PATHS, ids=[".".join(map(str, p)) for p in COMMIT_PATHS])
def test_a_commit_probe_lacking_a_required_field_holds(path):
    b = _row(PICK_Q, "bot-approved-head-update")
    b.w.fault(commit_probe(b.n("#141")), "absent", field=path)
    check(b, "noop-probe-hold")


@pytest.mark.parametrize("path", REVIEW_PATHS, ids=[".".join(map(str, p)) for p in REVIEW_PATHS])
def test_a_commit_review_probe_lacking_a_required_field_holds(path):
    b = _row(UNSTRAND_Q, "unstrand-yes")
    b.w.fault(review_probe(b.n(UNSTRAND_PR)), "absent", field=path)
    check(b, "unstrand-hold")


@pytest.mark.parametrize("path", RUNS_PATHS, ids=[".".join(map(str, p)) for p in RUNS_PATHS])
def test_a_check_runs_read_lacking_a_required_field_holds(path):
    b = _row(RENOVATE_Q, "renovate-untouched-green-update")
    b.w.fault(check_runs(b.n(RENOVATE_PR)), "absent", field=path)
    check(b, "renovate-probe-hold")


@pytest.mark.parametrize("path", CI_PATHS, ids=[".".join(map(str, p)) for p in CI_PATHS])
def test_a_ci_check_read_lacking_a_required_field_holds(path):
    """The ci read is raw and strict: lacking a field the schema's `ci_check_read` requires, that PR holds."""
    b = _row(PICK_Q, "inherited-red-unreviewed-update")
    b.w.fault(check_runs(b.n("#101")), "absent", field=path)
    check(b, "noop-ci-hold")


@pytest.mark.parametrize("path", STATUS_PATHS, ids=[".".join(map(str, p)) for p in STATUS_PATHS])
def test_a_status_read_lacking_a_required_field_holds(path):
    """The status read is the rollup's second leg: lacking a field, the probe holds after both reads, nothing written."""
    b = _row(RENOVATE_Q, "renovate-untouched-green-update")
    n = b.n(RENOVATE_PR)
    b.w.set(status(n), ("statuses",), [{**_recorded(status(n))["statuses"][0], "state": "success"}])
    b.w.fault(status(n), "absent", field=path)
    r = run(b)
    assert [classify(c)[0] for c in r.calls] == ["snapshot", "probe", "parents", "check-runs", "status"], r.calls
    assert r.rc == 0 and line_matches("commit probe unreadable — HOLDING", r.stdout), r.stdout


def test_an_unparseable_snapshot_is_unreadable():
    b = Board()
    b.w.fault(SNAPSHOT, "non-json")
    r = check(b, "unreadable-snapshot")
    assert "no parseable JSON" in r.stdout, r.stdout


def test_a_failing_snapshot_read_passes_gh_status_through():
    b = Board()
    b.w.fault(SNAPSHOT, "fail")
    r = run(b)
    assert (r.rc, r.stdout) == (1, "") and "(HTTP 502)" in r.stderr, (r.rc, r.stdout, r.stderr)


@pytest.mark.parametrize("path", PARENTS_PATHS, ids=[".".join(map(str, p)) for p in PARENTS_PATHS])
def test_a_pull_commits_read_lacking_a_required_field_holds(path):
    b = _row(PICK_Q, "bot-approved-head-update")
    b.w.fault(parents_read(b.n("#141")), "absent", field=path)
    check(b, "noop-probe-hold")


def test_a_view_commit_with_no_element_in_the_pull_commits_read_holds():
    """The join is by `sha` = `oid`: the PR view's newest commit has no element, so the commits are unreadable."""
    b = _row(PICK_Q, "hand-titled-merge-after-approval-update")
    n = b.n("#141")
    view = b.w.get(commit_probe(n), ("commits",))
    index = next(i for i, e in enumerate(b.w.get(parents_read(n), ())) if e["sha"] == view[-1]["oid"])
    b.w.fault(parents_read(n), "absent", field=(index,))
    check(b, "noop-probe-hold")


def test_a_non_json_pull_commits_read_holds():
    b = _row(PICK_Q, "bot-approved-head-update")
    b.w.fault(parents_read(b.n("#141")), "non-json")
    check(b, "noop-probe-hold")
