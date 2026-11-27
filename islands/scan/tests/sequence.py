"""The sequence driver: several wakes over one recorded world, state crossing wakes only through actual writes (goal #3656 pin 6).

    w = World("goal-checkpoint")
    result = run_sequence(w, [
        Wake([[sys.executable, "-m", "scan_island.checkpoint_b", "dispatch", REPO, "3118"]], setup=derive_open_pr),
        Wake([[sys.executable, "-m", "scan_island.checkpoint_b", "evaluate", REPO, "3118"]]),
    ])
    result.wakes[1].outputs, result.wakes[1].calls, result.wakes[1].derived

A wake is one or more processes run, in order, against the world's fake `gh` (`tests/world.py`). After a
wake the driver reads the fake's call log. For every comment write the fake answered 201 it adds ONE
element to the next wake's comments read of the same target: a copy of a recorded comment of that list,
its body set to the body the process sent, its author, id and times derived. A write answered 403 (or
any other failure) adds nothing; a wake with no write adds nothing. What the next wake sees is built
from the writes the processes ISSUED, never from what the case expected them to write: a write the case
did not expect still appears (`WakeResult.unexpected` lists it). The world on disk is never written.

Every element the driver or its helpers derive is recorded in `WakeResult.derived` as a `Derived`.
"""

from __future__ import annotations

import datetime
import re
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field

from .fake_gh import api_method, api_path, strip_jq
from .world import Run, World

AUTHOR = "scan-island-sequence[bot]"  # the derived author of an overlaid comment
CLOCK = datetime.datetime(2026, 11, 25, 12, 0, 0, tzinfo=datetime.UTC)  # wake n's derived time is CLOCK + n minutes
FIELD_FLAGS = ("-f", "-F", "--field", "--raw-field")


@dataclass(frozen=True)
class Derived:
    """An answer element that no recording holds: its kind, the file and index it sits at, and its source."""

    kind: str  # "comment-overlay" | "open-list"
    file: str
    index: int
    source: str  # the recorded element or read it was copied from / taken from
    detail: str = ""  # an overlay: the body sent


@dataclass
class Wake:
    processes: list[list[str]]
    setup: Callable[[World], list[Derived] | None] | None = None  # applied to the world before the wake's first process
    expected_writes: list[str] | None = None  # bodies the case expects the wake to send (None: not stated)


@dataclass
class WakeResult:
    runs: list[Run]
    derived: list[Derived]  # what was added to the world BEFORE this wake (setup, then overlays of earlier wakes)
    unexpected: list[str]  # bodies written and answered 201 that `expected_writes` did not name

    @property
    def calls(self) -> list[dict]:
        return [c for r in self.runs for c in r.calls]

    @property
    def argvs(self) -> list[list[str]]:
        return [c["argv"] for c in self.calls]

    @property
    def outputs(self) -> list[str]:
        return [r.stdout for r in self.runs]


@dataclass
class SequenceResult:
    wakes: list[WakeResult] = field(default_factory=list)


def write_body(argv: Sequence[str]) -> str:
    """The `body` a `gh api` comment write sent (`-f body=…`, `-F body=…`, `--field`, `--raw-field`)."""
    it = iter(argv)
    for a in it:
        if a in FIELD_FLAGS:
            v = next(it, "")
        elif a.startswith("--field=") or a.startswith("--raw-field="):
            v = a.partition("=")[2]
        else:
            continue
        k, _, val = v.partition("=")
        if k == "body":
            return val
    raise ValueError(f"the comment write names no body field: gh {' '.join(argv)}")


def comments_file(world: World, path: str) -> str:
    """The world's comments read of the target a write's path names (`repos/<r>/issues/<n>/comments`)."""
    for r in world.provenance.get("reads", []):
        argv = r["argv"]
        if argv[:1] == ["api"] and api_path(argv).partition("?")[0] == path:
            return r["file"]
    raise ValueError(f"world {world.name} holds no comments read for {path}: a write to it cannot be carried to the next wake")


def _successful_comment_writes(runs: Sequence[Run], world: World) -> list[tuple[str, str]]:
    """(comments file, body) of each comment write answered 201, in call order."""
    created = {w["op"] for w in world.provenance.get("writes", []) if w["method"] == "POST" and w["path"].endswith("/comments") and "201" in w.get("statuses", [])}
    out = []
    for run in runs:
        for c in run.calls:
            if c.get("kind") == "write" and c.get("op") in created and c.get("rc") == 0:
                key, _ = strip_jq(c["argv"])
                assert api_method(key) == "POST"
                out.append((comments_file(world, api_path(key).partition("?")[0]), write_body(key)))
    return out


def overlay(world: World, file: str, body: str, wake: int, copy_of: int = 0) -> Derived:
    """Add the written comment to `file`'s list as a copy of recorded element `copy_of` with derived identity."""
    items = world.get(file, ())
    if not isinstance(items, list) or not items:
        raise ValueError(f"{file} holds no recorded comment to copy")
    top = max(int(c["id"]) for c in items)
    new_id = top + 1
    at = (CLOCK + datetime.timedelta(minutes=wake)).strftime("%Y-%m-%dT%H:%M:%SZ")
    base = re.sub(r"/comments/\d+$", "", str(items[copy_of]["url"]))
    html = re.sub(r"#issuecomment-\d+$", "", str(items[copy_of]["html_url"]))
    world.add(
        file,
        (),
        copy_of=copy_of,
        changes={
            ("body",): body,
            ("id",): new_id,
            ("node_id",): f"IC_derived_{new_id}",
            ("url",): f"{base}/comments/{new_id}",
            ("html_url",): f"{html}#issuecomment-{new_id}",
            ("user", "login"): AUTHOR,
            ("created_at",): at,
            ("updated_at",): at,
        },
    )
    return Derived("comment-overlay", file, len(items), f"{file}[{copy_of}]", body)


def derive_open_pr(world: World, rest: str = "api.pulls.3270.json", copy_of: int = 0, file: str = "pr-list.json") -> list[Derived]:
    """Add to the open list one element copied from a recorded element, its number, head branch and body
    taken from the recorded REST read `rest` (the pull request merged, so no read shows it open)."""
    pull = world.get(rest, ())
    index = len(world.get(file, ()))
    world.add(file, (), copy_of=copy_of, changes={("number",): pull["number"], ("headRefName",): pull["head"]["ref"], ("body",): pull["body"]})
    return [Derived("open-list", file, index, f"{file}[{copy_of}] + {rest}")]


def run_sequence(world: World, wakes: Sequence[Wake]) -> SequenceResult:
    result = SequenceResult()
    carried: list[Derived] = []
    for n, wake in enumerate(wakes):
        derived = list(carried)
        carried = []
        if wake.setup:
            derived = [*(wake.setup(world) or []), *derived]
        runs = [world.run(argv) for argv in wake.processes]
        written = _successful_comment_writes(runs, world)
        bodies = [b for _, b in written]
        unexpected = [] if wake.expected_writes is None else [b for b in bodies if b not in wake.expected_writes]
        result.wakes.append(WakeResult(runs, derived, unexpected))
        for file, body in written:
            carried.append(overlay(world, file, body, n + 1))
    return result
