"""Replay as a comparison (goal #3490 pin 8; islands/README.md §Built from the specs, never copied, rule 4).

For one row of a replay family, two streams are built and compared byte for byte:

- **old** — the old member run on the family's own world through the replay adapter (`replay.run_row`,
  the harness's stubs, the stream it already builds);
- **new** — the island's component run as a process against the island's fake `gh` (`world.World`), on
  the row's answers **lifted** onto the recorded world (`specs/worlds/<name>/`).

The lift. Every answer file the row's family world serves (world → row overlay → row patch, as the
adapter materialises it) is matched to the recorded read of the same shape — the same argv once the
repo, the item numbers and the head SHAs are set aside — and laid over that read's recorded whole
answer: a family value overrides the recorded value of the same field, a family list element is laid
over a recorded element of the same list, and the list holds the family's elements. The read is
re-addressed to the family's repo, numbers and SHAs, so both sides are asked about the same item. A
field the family lacks keeps its recorded value; a top-level field outside the read's own `--json` list
is dropped (gh never prints it for that argv). What cannot be laid over the recording is **not
liftable**: the row is a difference, never skipped. The family's injected conditions (`STUB_GH_<call>=fail`,
`STUB_GH_GRAPHQL=drained`) become faults of the fake on the same calls, with the stub's own failure
text, captured by running the stub.

A differing row passes only with a committed ruling in `comparison/<family>.rulings`: `spec` (the page
is wrong), `old` (the old member is wrong) or `new` (the component is wrong), and one line of reason.
A ruling for a row that does not differ fails. Equality with the old member is not the acceptance.
"""

from __future__ import annotations

import copy
import difflib
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Callable, Iterator, Sequence
from dataclasses import dataclass, field
from functools import cache
from pathlib import Path

from .fake_gh import NON_JSON_BODY
from .old_subjects import MAJOR_HANDOFF_DIR, UPDATER_DIR, old_major_handoff, old_updater
from .replay import (
    STUBS,
    UNSET,
    Family,
    ReplayRed,
    Row,
    build_stream,
    env_entries,
    load_family,
    materialise,
    run_row,
    subject_argv_from_env,
)
from .world import WORLDS, UnrecordedCall, World, parse_provenance

RULINGS_DIR = Path(__file__).resolve().parent / "comparison"
RULINGS = ("spec", "old", "new")
COMMON = STUBS / "_common.sh"
ITEM, SHA = "qqitemqq", "qqshaqq"  # placeholders that survive the stubs' slug unchanged
# The family commits whose headline says "merge" by title only: the family's world has no parents, so the lift gives
# such a commit two (the pull-commits read, glossary.md merge commit) and any other commit one.
MERGE_SHAPES = ("Merge branch ", "Merge remote-tracking branch ", "Merge pull request ")


class NotLiftable(Exception):
    """A family answer or condition with no counterpart in the recorded world."""


class RulingError(ValueError):
    """A rulings file line outside the grammar."""


@dataclass(frozen=True)
class Spec:
    name: str
    dir: Path
    world: str
    repo: Callable[[Family, Row], str]
    old: Callable[[Family, Row], list[str]]
    new: Callable[[Family, Row], list[str]]

    @property
    def family(self) -> Family:
        return load_family(self.dir)

    @property
    def rulings_file(self) -> Path:
        return RULINGS_DIR / f"{self.name}.rulings"


SPECS = {
    "major-handoff": Spec(
        "major-handoff",
        MAJOR_HANDOFF_DIR,
        "pr-handoff",
        lambda fam, row: subject_argv_from_env(fam, row, "IN_SLUG")[0],
        old_major_handoff,
        lambda fam, row: [sys.executable, "-m", "scan_island.major_handoff", *subject_argv_from_env(fam, row, "IN_SLUG", "IN_PR")],
    ),
    "updater": Spec(
        "updater",
        UPDATER_DIR,
        "pr-board",
        lambda fam, row: "teststuffstash/testrepo",  # updater/bridge.sh:3
        old_updater,
        lambda fam, row: [sys.executable, "-m", "scan_island.updater", "teststuffstash/testrepo"],
    ),
}


# ── the stubs' own helpers, driven (never re-implemented): the world key, the CALL line ──────────────


def _common(script: str, *args: str) -> str:
    p = subprocess.run(["sh", "-c", f'_RP_TOOL=gh; . "$0"; {script}', str(COMMON), *args], capture_output=True, text=True, check=True)
    return p.stdout


@cache
def stub_words(argv: tuple[str, ...]) -> tuple[str, ...]:
    """The bare words the stub keys a call on: `_rp_words` (agents/replay/stubs/_common.sh)."""
    return tuple(_common('_rp_words "$@"', *argv).split(" "))


@cache
def slug_of(words: tuple[str, ...]) -> str:
    """`_rp_slug` of bare words: `pr view 234` → `pr-view-234`."""
    return _common('_rp_slug "$1"', " ".join(words))


def stub_slug(argv: tuple[str, ...]) -> str:
    return slug_of(stub_words(argv))


def stub_file(gh_dir: Path, argv: tuple[str, ...]) -> Path | None:
    """The family file the stub serves a READ from: the key shortened one word at a time, `.json`, `.txt`,
    bare (`_rp_serve`'s lookup order — its loop, walked here to learn the path rather than the bytes)."""
    words = stub_words(argv)
    for k in range(len(words), 0, -1):
        for ext in (".json", ".txt", ""):
            f = gh_dir / f"{slug_of(words[:k])}{ext}"
            if f.is_file():
                return f
    return None


def call_lines(argvs: Sequence[Sequence[str]], tmp: Path) -> bytes:
    """`CALL gh …` lines exactly as the stub records them (`_rp_record`)."""
    actions = tmp / "calls.actions"
    actions.write_bytes(b"")
    for argv in argvs:
        subprocess.run(
            ["sh", "-c", '_RP_TOOL=gh; . "$0"; _rp_record "$@"', str(COMMON), *argv],
            env={**os.environ, "REPLAY_ACTIONS": str(actions)}, check=True,
        )
    return actions.read_bytes()


def stub_answer(argv: Sequence[str], env: dict[str, str]) -> tuple[int, str, str]:
    """What the harness's stub answers to one call under the family's condition (an empty world)."""
    with tempfile.TemporaryDirectory() as t:
        (Path(t) / "world" / "gh").mkdir(parents=True)
        full = {k: v for k, v in os.environ.items() if k not in UNSET and not k.startswith("STUB_")}
        full.update(env, REPLAY_WORLD=f"{t}/world", REPLAY_ACTIONS=f"{t}/actions", REPLAY_STUB_DIR=str(STUBS))
        p = subprocess.run(["sh", str(STUBS / "gh"), *argv], env=full, capture_output=True, text=True, check=False)
        return p.returncode, p.stdout, p.stderr


# ── the lift ───────────────────────────────────────────────────────────────────────────────────────


def _templated(arg: str, rec_repo: str, repo: str, items: Sequence[int]) -> str:
    arg = arg.replace(rec_repo, repo)
    arg = re.sub(r"(?<![0-9A-Za-z])[0-9a-f]{40}(?![0-9A-Za-z])", SHA, arg)
    for n in items:
        arg = re.sub(rf"(?<![0-9A-Za-z]){n}(?![0-9A-Za-z])", ITEM, arg)
    return arg


def _key_regex(slug: str, sep: str = "-") -> re.Pattern[str]:
    """A templated key as a pattern; `sep="_"` for a STUB_GH_<key> variable name."""
    pattern = re.escape(slug.replace("-", sep))
    return re.compile(pattern.replace(ITEM, r"(\d+)").replace(SHA, r"([0-9a-z]+)"))


def _address(argv_t: tuple[str, ...], stem: str) -> tuple[str, ...] | None:
    """The concrete read a family file named `stem` answers for this templated read, or None. The stub
    serves a key shortened word by word, so `pr-list.json` answers `pr list open`; a placeholder in a
    dropped word cannot be named from the file, so such a match is not an address."""
    words = stub_words(argv_t)
    for k in range(len(words), 0, -1):
        m = _key_regex(slug_of(words[:k])).fullmatch(stem)
        if m:
            if any(ITEM in w or SHA in w for w in words[k:]):
                return None
            return _fill(argv_t, m.groups())
    return None


def _fill(argv_t: Sequence[str], values: Sequence[str]) -> tuple[str, ...]:
    it = iter(values)
    marker = re.compile(f"{ITEM}|{SHA}")
    return tuple(marker.sub(lambda _m: next(it), a) for a in argv_t)


@dataclass
class _Group:
    """The recorded answers of one read shape: the reads, then any GET write answering the same path."""

    argv_t: tuple[str, ...]
    reads: list[str] = field(default_factory=list)
    after: list[str] = field(default_factory=list)  # writes/<op>.<status>.json of a GET-after write

    def answers(self, root: Path) -> list[object]:
        return [json.loads((root / f).read_text("utf-8")) for f in self.reads + self.after]


def _json_fields(argv: Sequence[str]) -> set[str] | None:
    for flag, value in zip(argv, argv[1:], strict=False):
        if flag == "--json":
            return set(value.split(","))
    return None


def _at(value: object, spath: tuple) -> Iterator[object]:
    if not spath:
        yield value
        return
    head, rest = spath[0], spath[1:]
    if head == "[]" and isinstance(value, list):
        for v in value:
            yield from _at(v, rest)
    elif isinstance(value, dict) and head in value:
        yield from _at(value[head], rest)


def _where(spath: tuple) -> str:
    return "".join("[]" if k == "[]" else f".{k}" for k in spath) or "(the answer)"


def lay(rec: object, fam: object, spath: tuple, pool: Callable[[tuple], list[object]], what: str) -> object:
    """The family value laid over the recorded one; raises NotLiftable where the shapes cannot meet."""
    if isinstance(fam, dict):
        if not isinstance(rec, dict):
            rec = next((v for v in pool(spath) if isinstance(v, dict)), None)
            if rec is None:
                raise NotLiftable(f"{what}: {_where(spath)} — the recording holds no object to lay the family's over")
        out = copy.deepcopy(rec)
        for k, v in fam.items():
            if k not in rec:
                raise NotLiftable(f"{what}: field {_where((*spath, k))} is not in the recording")
            out[k] = lay(rec[k], v, (*spath, k), pool, what)
        return out
    if isinstance(fam, list):
        if not isinstance(rec, list):
            if rec is not None:
                raise NotLiftable(f"{what}: {_where(spath)} is a list in the family, a {type(rec).__name__} in the recording")
            rec = next((v for v in pool(spath) if isinstance(v, list) and v), [])
        out_list = []
        for i, e in enumerate(fam):
            if isinstance(e, dict | list):
                base = rec[i] if i < len(rec) else (rec[0] if rec else None)
                out_list.append(lay(base, e, (*spath, "[]"), pool, what))
            else:
                out_list.append(e)
        return out_list
    if isinstance(rec, dict | list) and fam is not None:
        raise NotLiftable(f"{what}: {_where(spath)} is a {type(fam).__name__} in the family, a {type(rec).__name__} in the recording")
    return fam


def lift_answer(answers: list[object], base: object, fam: object, fields: set[str] | None, what: str) -> object:
    def pool(spath: tuple) -> list[object]:
        return [v for a in answers for v in _at(a, spath)]

    if fields is not None:  # the read's own --json list: gh prints nothing else for this argv
        if isinstance(fam, dict):
            fam = {k: v for k, v in fam.items() if k in fields}
        elif isinstance(fam, list):
            fam = [{k: v for k, v in e.items() if k in fields} if isinstance(e, dict) else e for e in fam]
    return lay(base, fam, (), pool, what)


@dataclass
class Lifted:
    world: World
    dir: Path
    env: dict[str, str]  # the family's non-stub env, handed to the component
    reads: dict[str, list[str]]  # family answer (gh/<file>) → the lifted answer files it became
    family: Path  # the row's materialised family world (world → overlay → patch)


def _provenance_text(prov: dict) -> str:
    lines = ["# The row's answers lifted onto the recorded world (tests/compare.py) — a temp dir, never committed."]
    for k, v in prov.items():
        if isinstance(v, list):
            lines.append(f"{k}:")
            for item in v:
                for i, (ik, iv) in enumerate(item.items()):
                    lines.append(f"  {'- ' if i == 0 else '  '}{ik}: {json.dumps(iv, ensure_ascii=False)}")
        else:
            lines.append(f"{k}: {json.dumps(v, ensure_ascii=False)}")
    return "\n".join(lines) + "\n"


def lift_row(spec: Spec, fam: Family, row: Row, tmp: Path) -> Lifted:
    """Build the row's lifted world under `tmp`; raises NotLiftable (the row is then a difference)."""
    rec_dir = WORLDS / spec.world
    prov = parse_provenance((rec_dir / "provenance.yaml").read_text("utf-8"))
    rec_repo, repo, items = prov["repo"], spec.repo(fam, row), prov.get("items", [])

    groups: dict[tuple[str, ...], _Group] = {}
    for r in prov["reads"]:
        argv_t = tuple(_templated(a, rec_repo, repo, items) for a in r["argv"])
        groups.setdefault(argv_t, _Group(argv_t)).reads.append(r["file"])
    writes = []
    for w in prov["writes"]:
        w = {**w, "path": w["path"].replace(rec_repo, repo)}
        writes.append(w)
        if w["method"] == "GET" and w.get("after"):
            argv_t = ("api", re.sub(r"\{[a-z_]+\}", ITEM, w["path"]))
            if argv_t in groups:
                groups[argv_t].after.append(f"writes/{w['op']}.{w['statuses'][0]}.json")

    out = tmp / "lifted" / spec.world
    out.mkdir(parents=True)
    for sub in ("writes", "schemas"):
        if (rec_dir / sub).is_dir():
            shutil.copytree(rec_dir / sub, out / sub)

    synth = materialise(fam, row, tmp)
    faults: list[tuple[str, str, dict]] = []  # (read file or write op, fault kind, its keywords)
    lifted_reads: list[dict] = []
    reads_of: dict[str, list[str]] = {}
    after_written: dict[str, str] = {}
    viewed: dict[str, list[dict]] = {}  # the pull request → the lifted view commits (the first read of it)
    for path in sorted(p for p in (synth / "world").rglob("*") if p.is_file()):
        rel = path.relative_to(synth / "world").as_posix()
        if not rel.startswith("gh/"):
            raise NotLiftable(f"{rel}: the family answers a tool other than gh; the fake serves gh only")
        stem = path.name.removesuffix(".json").removesuffix(".txt")
        text = path.read_text("utf-8")
        try:
            fam_body, non_json = json.loads(text), False
        except ValueError as e:  # the family's garbage answer: the fake's `non-json` fault, if it prints the same body
            if text != NON_JSON_BODY:
                raise NotLiftable(f"{rel}: the family's answer is not JSON ({e}) and not the body the fake's non-json fault prints") from e
            fam_body, non_json = None, True
        matched = False
        for gi, g in enumerate(groups.values()):
            argv = _address(g.argv_t, stem)
            if argv is None or stub_file(synth / "world" / "gh", argv) != path:
                continue  # not this read's shape, or a more specific family file answers it
            matched = True
            answers = g.answers(rec_dir)
            what = f"{rel} over {g.reads[0]}"
            name = f"lifted.{gi}.{stem}.json"
            if non_json:  # the recorded answer stands; the fault replaces it on every call
                if g.after:
                    raise NotLiftable(f"{rel}: a non-JSON answer for a write's read-back has no fake counterpart")
                body = answers[0]
                faults.append((name, "non-json", {}))
            else:
                body = lift_answer(answers, answers[0], fam_body, _json_fields(argv), what)
                _distinct_oids(body, f"{rel}")
            (out / name).write_text(json.dumps(body, ensure_ascii=False) + "\n", "utf-8")
            lifted_reads.append({"argv": list(argv), "file": name})
            if isinstance(body, dict) and isinstance(body.get("commits"), list):
                viewed.setdefault(argv[2], body["commits"])
            reads_of.setdefault(rel, []).append(name)
            for k, after in enumerate(g.after):
                if after in after_written:
                    raise NotLiftable(f"{rel}: {after} is already the lift of {after_written[after]} — two family answers for one write's read-back")
                body = lift_answer(answers, answers[len(g.reads) + k], fam_body, None, f"{rel} over {after}")
                (out / after).write_text(json.dumps(body, ensure_ascii=False) + "\n", "utf-8")
                after_written[after] = rel
                reads_of[rel].append(after)
        if not matched:
            raise NotLiftable(f"{rel}: the family answers a read the recorded world {spec.world} does not hold")

    for n, commits in viewed.items():
        _serve_parents(groups, rec_dir, repo, n, commits, out, lifted_reads)
    _serve_ci(groups, rec_dir, repo, out, lifted_reads)

    env: dict[str, str] = {}
    for entry in env_entries(fam, row):
        k, _, v = entry.partition("=")
        if k == "STUB_GH_GRAPHQL":
            if v != "drained":
                raise NotLiftable(f"{entry}: no counterpart in the fake gh")
            for w in writes:  # gh porcelain writes are GraphQL mutations; REST writes keep serving
                if w["method"] == "gh":
                    probe = re.sub(r"\{[a-z_]+\}", "1", w["path"]).split()
                    faults.append((w["op"], "fail", _failure(probe, {k: v}, entry)))
        elif k.startswith("STUB_GH_"):
            if v != "fail":
                raise NotLiftable(f"{entry}: the fake gh has no answer of that shape")
            for target, argv in _per_call_targets(k.removeprefix("STUB_GH_"), lifted_reads, writes, out, entry):
                faults.append((target, "fail", _failure(argv, {k: v}, entry)))
        elif k.startswith("STUB_"):
            raise NotLiftable(f"{entry}: no counterpart in the fake gh")
        else:
            env[k] = v

    (out / "provenance.yaml").write_text(
        _provenance_text({"world": spec.world, "repo": repo, "reads": lifted_reads, "writes": writes}), "utf-8"
    )
    world = World(spec.world, root=out.parent)
    for target, kind, kw in faults:
        world.fault(target, kind, occurrence=None, **kw)
    return Lifted(world, out, env, reads_of, synth / "world")


def _distinct_oids(body: object, seed: str) -> None:
    """Every lifted view commit has its own `oid`: the recorded one the first time a recorded element is used (the lay
    copies recorded elements in order), a derived 40-hex value after that."""
    if not isinstance(body, dict) or not isinstance(body.get("commits"), list):
        return
    seen: set[str] = set()
    for i, c in enumerate(body["commits"]):
        if not isinstance(c, dict) or "oid" not in c:
            continue
        if c["oid"] in seen:
            c["oid"] = hashlib.sha1(f"{seed}:{i}".encode()).hexdigest()  # noqa: S324 — a derived 40-hex value
        seen.add(c["oid"])


def _serve_parents(groups: dict, rec_dir: Path, repo: str, n: str, commits: list[dict], out: Path, lifted_reads: list[dict]) -> None:
    """The lifted world's pull-commits answer for pull request `n`: one element per lifted view commit, in order — a copy
    of a recorded element, its `sha` that commit's `oid`, its `parents` two copies of a recorded parent element when the
    family commit's headline has one of the three default merge-message shapes, and one otherwise."""
    group = groups.get(("api", f"repos/{repo}/pulls/{ITEM}/commits?per_page=100"))
    if group is None:
        raise NotLiftable(f"the recorded world holds no pull-commits read (pulls/<n>/commits?per_page=100) to lift #{n}'s parents over")
    recorded = [e for a in group.answers(rec_dir) for e in a]  # type: ignore[union-attr]
    element = next(e for e in recorded if len(e["parents"]) == 1)
    parent = element["parents"][0]
    listed = [
        {**copy.deepcopy(element), "sha": c["oid"], "parents": [copy.deepcopy(parent) for _ in range(2 if c["messageHeadline"].startswith(MERGE_SHAPES) else 1)]}
        for c in commits
    ]
    name = f"lifted.parents.{n}.json"
    (out / name).write_text(json.dumps(listed, ensure_ascii=False) + "\n", "utf-8")
    lifted_reads.append({"argv": ["api", f"repos/{repo}/pulls/{n}/commits?per_page=100"], "file": name})


def _serve_ci(groups: dict, rec_dir: Path, repo: str, out: Path, lifted_reads: list[dict]) -> None:
    """The ci read (updater.md SCAN-UPDATER-PICK) of every pull request of the lifted snapshot that is armed ∧ BEHIND and
    not CHANGES_REQUESTED, when the family answers no check-runs read for that head: a copy of a recorded check-runs
    answer addressed to the family's head SHA, its `ci` run `completed` / `success` (the leg then finds no red)."""
    snapshot = next((r for r in lifted_reads if r["argv"][:2] == ["pr", "list"]), None)
    if snapshot is None:
        return
    group = groups.get(("api", f"repos/{repo}/commits/{SHA}/check-runs?per_page=100"))
    served = {tuple(r["argv"]) for r in lifted_reads}
    for pr in json.loads((out / snapshot["file"]).read_text("utf-8")):
        if not (pr.get("autoMergeRequest") is not None and pr.get("mergeStateStatus") == "BEHIND" and pr.get("reviewDecision") != "CHANGES_REQUESTED"):
            continue
        argv = ("api", f"repos/{repo}/commits/{pr['headRefOid']}/check-runs?per_page=100")
        if argv in served:
            continue
        if group is None:
            raise NotLiftable("the recorded world holds no check-runs read (commits/<sha>/check-runs?per_page=100) to lift the ci read over")
        body = copy.deepcopy(next(a for a in group.answers(rec_dir) if any(r["name"] == "ci" for r in a["check_runs"])))  # type: ignore[union-attr, index]
        for run in body["check_runs"]:
            run["head_sha"] = pr["headRefOid"]
            if run["name"] == "ci":
                run["status"], run["conclusion"] = "completed", "success"
        name = f"lifted.ci.{pr['number']}.json"
        (out / name).write_text(json.dumps(body, ensure_ascii=False) + "\n", "utf-8")
        lifted_reads.append({"argv": list(argv), "file": name})


def _failure(argv: Sequence[str], env: dict[str, str], entry: str) -> dict:
    rc, stdout, stderr = stub_answer(argv, env)
    if rc == 0 or stdout:
        raise NotLiftable(f"{entry}: the stub answers `gh {' '.join(argv)}` with rc={rc} and stdout — not a failing call")
    return {"stderr": stderr}


def _per_call_targets(slug_us: str, reads: list[dict], writes: list[dict], out: Path, entry: str) -> list[tuple[str, list[str]]]:
    """Every lifted read and write the stub's per-call variable fails. The stub keys it on the bare words,
    so it fails each call of that key — every field list of a read, a write on the same path (`-X` is not
    a word), a GET write's read-back. A write is split into its own op for the addressed path."""
    hits: list[tuple[str, list[str]]] = [(r["file"], r["argv"]) for r in reads if stub_slug(tuple(r["argv"])).replace("-", "_") == slug_us]
    for w in list(writes):
        argv_t = w["path"].split() if w["method"] == "gh" else ["api", "-X", w["method"], w["path"]]
        m = _key_regex(stub_slug(tuple(re.sub(r"\{[a-z_]+\}", ITEM, a) for a in argv_t)), "_").fullmatch(slug_us)
        if not m:
            continue
        if w["method"] == "GET":  # the read-back the fake serves after its write: one answer, any number
            hits.append((f"writes/{w['op']}.{w['statuses'][0]}.json", ["api", w["path"]]))
            continue
        values = iter(m.groups())
        path = re.sub(r"\{[a-z_]+\}", lambda _m, it=values: next(it), w["path"])
        concrete = {**w, "op": f"{w['op']}@{slug_us}", "path": path}
        for s in w.get("statuses", []):
            shutil.copy(out / "writes" / f"{w['op']}.{s}.json", out / "writes" / f"{concrete['op']}.{s}.json")
        writes.insert(writes.index(w), concrete)  # first match wins in the fake: the addressed path before the template
        hits.append((concrete["op"], path.split() if w["method"] == "gh" else ["api", "-X", w["method"], path]))
    if not hits:
        raise NotLiftable(f"{entry}: the family fails a call the lifted world holds no read or write for")
    return hits


# ── the comparison ─────────────────────────────────────────────────────────────────────────────────


@dataclass
class Outcome:
    old: bytes
    new: bytes | None
    reason: str | None = None  # not liftable / unrecorded: a difference no stream can settle

    @property
    def differs(self) -> bool:
        return self.reason is not None or self.old != self.new

    def describe(self) -> str:
        if self.reason is not None:
            return self.reason
        return "".join(
            difflib.unified_diff(
                self.old.decode(errors="replace").splitlines(keepends=True),
                (self.new or b"").decode(errors="replace").splitlines(keepends=True),
                "old member",
                "new component",
            )
        )


_OLD: dict[tuple[str, str], bytes] = {}


def old_stream(spec: Spec, row: Row) -> bytes:
    key = (spec.name, row.id)
    if key not in _OLD:
        fam = spec.family
        _OLD[key] = run_row(fam, row, spec.old(fam, row))[0]
    return _OLD[key]


def new_stream(spec: Spec, row: Row, subject: Sequence[str] | None = None) -> tuple[bytes | None, str | None]:
    fam = spec.family
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t).resolve()
        try:
            lifted = lift_row(spec, fam, row, tmp)
        except (NotLiftable, ReplayRed) as e:
            return None, f"not liftable: {e}"
        try:
            run = lifted.world.run(list(subject or spec.new(fam, row)), env=lifted.env)
        except UnrecordedCall as e:
            return None, f"unrecorded: {e}"
        calls = call_lines(run.argvs, tmp)
        return build_stream(fam, calls, run.stdout.encode(), run.stderr.encode(), run.rc, tmp), None


def compare(spec: Spec, row: Row, subject: Sequence[str] | None = None) -> Outcome:
    new, reason = new_stream(spec, row, subject)
    return Outcome(old_stream(spec, row), new, reason)


# ── rulings ────────────────────────────────────────────────────────────────────────────────────────


def parse_rulings(text: str, row_ids: set[str], where: str) -> dict[str, tuple[str, str]]:
    """`<row id> | spec|old|new | <one line of reason>`, `#` comments; a row id at most once."""
    out: dict[str, tuple[str, str]] = {}
    for n, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        cells = [c.strip() for c in line.split("|", 2)]
        if len(cells) != 3 or not all(cells):
            raise RulingError(f"{where}:{n}: want `<row id> | <ruling> | <reason>`: {line}")
        rid, word, reason = cells
        if word not in RULINGS:
            raise RulingError(f"{where}:{n}: ruling {word!r} is not one of {RULINGS}")
        if rid not in row_ids:
            raise RulingError(f"{where}:{n}: {rid!r} is not a row of the family")
        if rid in out:
            raise RulingError(f"{where}:{n}: {rid!r} is ruled twice")
        out[rid] = (word, reason)
    return out


def load_rulings(spec: Spec, row_ids: set[str]) -> dict[str, tuple[str, str]]:
    return parse_rulings(spec.rulings_file.read_text("utf-8"), row_ids, spec.rulings_file.name)


def verdict(outcome: Outcome, ruling: tuple[str, str] | None) -> str | None:
    """None when the row passes: equal and unruled, or differing and ruled."""
    if outcome.differs and ruling is None:
        return f"unruled difference — rule it spec/old/new in the family's .rulings:\n{outcome.describe()}"
    if not outcome.differs and ruling is not None:
        return f"ruling `{ruling[0]}` for a row that does not differ — remove it"
    return None
