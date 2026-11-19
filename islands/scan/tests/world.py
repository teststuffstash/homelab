"""Serve one recorded world (`specs/worlds/<name>/`) to a process through the island's fake `gh`.

    w = World("pr-board")
    w.set("pr-list.json", (0, "mergeStateStatus"), "BEHIND")       # a value override (goal #3490 pin 4)
    w.add("pr-list.json", (0, "labels"), copy_of=0, changes={("name",): "agent/error"})
    w.fault("api.pulls.3556.json", "fail")                          # one call fails
    run = w.run([sys.executable, "-m", "scan_island.updater", "teststuffstash/homelab"])
    run.rc, run.stdout, run.calls                                   # what the component issued

The world on disk is never written: every run materialises a copy in a temp dir, applies the case's
overrides there, and puts `tests/fake_gh.py` first on PATH as `gh`. An override that names a field
the answer lacks, or that would remove a field, is refused here (`OverrideRefused`). A call the
world does not hold fails the run (`UnrecordedCall`), whatever the component made of the error.
"""

from __future__ import annotations

import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

ISLAND = Path(__file__).resolve().parent.parent
WORLDS = ISLAND / "specs" / "worlds"
FAKE = Path(__file__).resolve().parent / "fake_gh.py"
FAULT_KINDS = ("fail", "non-json", "absent", "status")
# A component must never see the operator's token or a pod's GitHub env through a case.
SCRUB = ("GH_TOKEN", "GITHUB_TOKEN", "GH_HOST", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "UPDATER_LABEL_TOKEN")

Path_ = tuple[str | int, ...]


class OverrideRefused(ValueError):
    """The override would change the world's shape: a field it lacks, or a field removed."""


class UnrecordedCall(AssertionError):
    """The process made a call the world holds no answer for."""


def parse_provenance(text: str) -> dict:
    """`provenance.yaml` as scripts/record_world.py writes it: `key: <json>` lines and two lists of maps."""
    out: dict = {}
    current: list | None = None
    for n, raw in enumerate(text.splitlines(), 1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if not raw.startswith(" "):
            k, sep, v = raw.partition(":")
            if not sep:
                raise ValueError(f"provenance.yaml:{n}: not a `key: value` line: {raw}")
            if v.strip():
                out[k] = json.loads(v)
                current = None
            else:
                current = out.setdefault(k, [])
            continue
        if current is None:
            raise ValueError(f"provenance.yaml:{n}: an indented line outside a list: {raw}")
        s = raw.strip()
        if s.startswith("- "):
            current.append({})
            s = s[2:]
        k, sep, v = s.partition(": ")
        if not sep or not current:
            raise ValueError(f"provenance.yaml:{n}: not a list-item field: {raw}")
        current[-1][k] = json.loads(v)
    return out


@dataclass
class Run:
    rc: int
    stdout: str
    stderr: str
    calls: list[dict]

    @property
    def argvs(self) -> list[list[str]]:
        return [c["argv"] for c in self.calls]


def _walk(data: object, path: Path_, what: str) -> object:
    node = data
    for k in path:
        try:
            if isinstance(node, list) and isinstance(k, int):
                node = node[k]
            elif isinstance(node, dict) and isinstance(k, str) and k in node:
                node = node[k]
            else:
                raise KeyError(k)
        except (KeyError, IndexError) as e:
            raise OverrideRefused(f"{what}: the answer has no field {list(path)} — an override changes a field that exists") from e
    return node


def _keeps_fields(old: object, new: object, where: str) -> None:
    """A replacing value removes no field: every key of an old object stays, recursively."""
    if isinstance(old, dict):
        if not isinstance(new, dict):
            raise OverrideRefused(f"{where}: an object replaced by a {type(new).__name__} removes its fields")
        gone = sorted(set(old) - set(new))
        if gone:
            raise OverrideRefused(f"{where}: the override removes field(s) {gone} — an override never removes a field")
        for k in old:
            _keeps_fields(old[k], new[k], f"{where}.{k}")
    elif isinstance(old, list):
        if not isinstance(new, list):
            raise OverrideRefused(f"{where}: a list replaced by a {type(new).__name__} removes its fields")
        for i, item in enumerate(new if old else []):
            _keeps_fields(old[0], item, f"{where}[{i}]")


class World:
    def __init__(self, name: str, root: Path = WORLDS) -> None:
        self.name = name
        self.dir = root / name
        self.provenance = parse_provenance((self.dir / "provenance.yaml").read_text("utf-8"))
        self._answers: dict[str, object] = {}
        self._faults: list[dict] = []

    def _answer(self, file: str) -> object:
        if file not in self._answers:
            if not (self.dir / file).is_file():
                raise OverrideRefused(f"{self.name}: no answer file {file}")
            self._answers[file] = json.loads((self.dir / file).read_text("utf-8"))
        return self._answers[file]

    def set(self, file: str, path: Path_, value: object) -> World:
        """Change the value of a field that exists in `file`'s answer."""
        if not path:
            raise OverrideRefused(f"{file}: an override names a field, never the whole answer")
        data = self._answer(file)
        parent = _walk(data, path[:-1], file)
        old = _walk(parent, path[-1:], file)
        _keeps_fields(old, value, f"{file}:{list(path)}")
        parent[path[-1]] = copy.deepcopy(value)  # type: ignore[index]
        return self

    def add(self, file: str, list_path: Path_, copy_of: int, changes: dict[Path_, object] | None = None) -> World:
        """Append a copy of a recorded element of the same list, then apply value overrides to the copy."""
        data = self._answer(file)
        items = _walk(data, list_path, file)
        if not isinstance(items, list):
            raise OverrideRefused(f"{file}:{list(list_path)} is not a list")
        items.append(copy.deepcopy(_walk(items, (copy_of,), file)))
        for sub, value in (changes or {}).items():
            self.set(file, (*list_path, len(items) - 1, *sub), value)
        return self

    def fault(
        self, target: str, kind: str, *, occurrence: int | None = 1, field: Path_ = (), status: int | None = None, stderr: str | None = None
    ) -> World:
        """Replace the answer of one call: `target` is a read's file or a write's op, `occurrence` its n-th call
        (None: every call). A `fail` fault may name the stderr text gh prints instead of the default."""
        if kind not in FAULT_KINDS:
            raise ValueError(f"fault kind {kind!r}: want one of {FAULT_KINDS}")
        if stderr is not None and kind != "fail":
            raise ValueError(f"fault kind {kind!r} prints no stderr of its own; only a `fail` fault takes `stderr`")
        if occurrence is not None and occurrence < 1:
            raise ValueError(f"occurrence {occurrence}: calls count from 1 (None for every call)")
        ops = {w["op"]: w for w in self.provenance.get("writes", [])}
        files = {r["file"] for r in self.provenance.get("reads", [])}
        if target not in ops and target not in files and not target.startswith("writes/"):
            raise ValueError(f"{self.name}: no read file or write op {target!r}")
        if target in ops and kind not in ("fail", "status"):
            raise ValueError(f"{self.name}: a write ({target}) takes only a `fail` or `status` fault, not {kind!r}")
        if kind == "absent":
            _walk(self._answer(target), field, target)
        if kind == "status":
            if target not in ops or str(status) not in ops[target].get("statuses", []) or not (self.dir / "writes" / f"{target}.{status}.json").is_file():
                raise ValueError(f"{self.name}: {target} has no hand-written {status} answer")
        self._faults.append({"target": target, "kind": kind, "occurrence": occurrence, "field": list(field), "status": status, "stderr": stderr})
        return self

    def run(self, argv: Sequence[str], env: dict[str, str] | None = None, cwd: Path | None = None) -> Run:
        with tempfile.TemporaryDirectory(prefix=f"world-{self.name}-") as t:
            tmp = Path(t)
            served = tmp / "world"
            shutil.copytree(self.dir, served)
            for file, data in self._answers.items():
                (served / file).write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")) + "\n", "utf-8")
            plan = {
                "world": str(served),
                "reads": self.provenance.get("reads", []),
                "writes": self.provenance.get("writes", []),
                "faults": self._faults,
            }
            (tmp / "plan.json").write_text(json.dumps(plan))
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            shim = bin_dir / "gh"
            shim.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{FAKE}" "$@"\n')
            shim.chmod(0o755)
            log = tmp / "calls.jsonl"
            full = {k: v for k, v in os.environ.items() if k not in SCRUB}
            full.update(env or {})
            full.update(FAKE_GH_PLAN=str(tmp / "plan.json"), FAKE_GH_LOG=str(log), PATH=f"{bin_dir}{os.pathsep}{full.get('PATH', '')}")
            p = subprocess.run(list(argv), env=full, cwd=cwd or tmp, capture_output=True, text=True, check=False)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        unrecorded = [c for c in calls if c.get("unrecorded")]
        if unrecorded:
            raise UnrecordedCall(
                f"world {self.name} holds no answer for: " + "; ".join("gh " + " ".join(c["argv"]) for c in unrecorded)
                + f"\n--- stderr ---\n{p.stderr}"
            )
        return Run(p.returncode, p.stdout, p.stderr, calls)
