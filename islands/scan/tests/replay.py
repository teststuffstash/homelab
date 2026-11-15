"""The replay-family adapter: `agents/replay/run.sh`'s `mode: table` semantics, driving any subject.

Contract (run.sh:150-161 and 312-332; goal #3389 pin 3): materialise one `rows.psv` row into a temp
dir (family/registry world → row overlay `rows/<id>/` → row patch via jq), compose the environment
(family `env:` then the row's `env` cell), run the subject with the harness's own `agents/replay/stubs/`
first on PATH under the stubs' contract (REPLAY_WORLD / REPLAY_ACTIONS / REPLAY_STUB_DIR), build the
stream (CALL lines, `OUT ` stdout, `ERR ` stderr, `RC <n>`), scrub the temp dir, the repo root and the
family's `scrub:` seds, and compare it byte for byte with `expected/<expect>.txt` after filling `{{k}}`
from the row's `params`. The family's stubs are driven, never re-implemented: a Python double could
drift from the stream the expected files were recorded in.

Everything is copied to a temp dir; nothing in the repo is written.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
REPLAY = ROOT / "agents" / "replay"
STUBS = REPLAY / "stubs"
FIXTURES = REPLAY / "fixtures"

# run.sh's ambient-env hermeticity `unset` list: a pod's own AGENT_*/GH_TOKEN/… must never reach a
# subject (a fixture that needs one pins it through its `env:`). Mirrors run.sh; keep in step.
UNSET = """PROJECT AGENT_RAIL AGENT_BASE_IMAGE AGENT_BUDGET_REFUSED AGENT_CREDIT_GATE
AGENT_CRED_INJECT AGENT_DEVBOX_SEARCH_HOST AGENT_DISPATCH_EPOCH AGENT_EGRESS_PROXY
AGENT_ERROR AGENT_INFEASIBLE AGENT_LOOP_WEBHOOK AGENT_MIRROR_DOCKER_IO
AGENT_MIRROR_GHCR AGENT_MIRROR_MCR AGENT_MODEL AGENT_NIX_CACHE_URL AGENT_NPM_CACHE_URL
AGENT_OPENROUTER_PROXY AGENT_PREFLIGHT AGENT_PUSHGATEWAY_URL AGENT_PYPI_CACHE_URL
AGENT_REPORT_URL AGENT_REPOS AGENT_ROUND AGENT_ROUTER AGENT_RUN_STATS AGENT_SEARCH_URL
AGENT_SESSION_KEY AGENT_STACK AGENT_STRIKE AGENT_SUBSCRIPTION_FALLBACK
AGENT_SUBSCRIPTION_FALLBACK_MODEL AGENT_TASK AGENT_TS_ACCESS_KEY_ID AGENT_TS_BUCKET
AGENT_TS_ENDPOINT AGENT_TS_READER_ID AGENT_TS_READER_SECRET AGENT_TS_SECRET_ACCESS_KEY
AGENT_TS_WRITER_ID AGENT_TS_WRITER_SECRET AGENT_WIP_LIMIT GH_TOKEN OPENROUTER_API_KEY
AGENT_GATEWAY AGENT_GATEWAY_RAIL AGENT_GATEWAY_URL AGENT_GATEWAY_CALLER_SA AGENT_GATEWAY_CALLER_TOKEN_FILE
ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_MODEL
OPENCODE_CONFIG_CONTENT""".split()


class ReplayRed(AssertionError):
    """The harness itself would red this row (bad world, no-op patch, unfilled {{k}}, …)."""


@dataclass(frozen=True)
class Row:
    id: str
    world: str
    patch: str
    env: str
    expect: str
    params: str


@dataclass
class Family:
    dir: Path
    name: str
    scalars: dict[str, str] = field(default_factory=dict)
    lists: dict[str, list[str]] = field(default_factory=dict)

    @property
    def rows_file(self) -> str:
        return self.scalars.get("rows", "rows.psv")


def _unquote(v: str) -> str:
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v


def load_family(path: Path | str) -> Family:
    """fixture.yaml's tiny subset: `key: value` and `key:` + `- item` lines, nothing nested."""
    d = Path(path)
    fam = Family(dir=d, name=d.name)
    cur = ""
    for raw in (d / "fixture.yaml").read_text("utf-8").splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        if raw[:1].isalpha() or raw[:1] == "_":
            k, _, v = raw.partition(":")
            cur, v = k, _unquote(v.strip())
            if v:
                fam.scalars[k] = v
        elif s.startswith("-"):
            if not cur:
                raise ReplayRed(f"{d.name}: list item before any key")
            fam.lists.setdefault(cur, []).append(_unquote(s[1:].strip()))
        else:
            raise ReplayRed(f"{d.name}: fixture.yaml line outside the supported subset: {raw}")
    fam.name = fam.scalars.get("name", d.name)
    return fam


def load_rows(fam: Family) -> list[Row]:
    rows = []
    for line in (fam.dir / fam.rows_file).read_text("utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        cells = [c.strip() for c in line.split("|")] + [""] * 6
        if cells[0]:
            rows.append(Row(*cells[:6]))
    return rows


def _lines_prefixed(prefix: bytes, data: bytes) -> bytes:
    """`sed 's/^/PFX /'`: every line prefixed; a missing final newline stays missing."""
    return b"".join(prefix + ln for ln in data.splitlines(keepends=True))


def materialise(fam: Family, row: Row, tmp: Path) -> Path:
    """The row's synth dir `$TMP/<fam>.<id>.fx` with its `world/` (world → overlay → patch)."""
    synth = tmp / f"{fam.name}.{row.id}.fx"
    world = synth / "world"
    (synth / "expected").mkdir(parents=True)
    world.mkdir()
    for sh in fam.dir.glob("*.sh"):
        shutil.copy(sh, synth / sh.name)
    w = row.world or fam.scalars.get("world", "")
    if w:
        if (fam.dir / "worlds" / w).is_dir():
            base = fam.dir / "worlds" / w
        elif (REPLAY / "worlds" / w).is_dir():
            base = REPLAY / "worlds" / w
        else:
            raise ReplayRed(f"{row.id}: world not found: {w} (family worlds/ then registry)")
        shutil.copytree(base, world, dirs_exist_ok=True)
        (world / "provenance.yaml").unlink(missing_ok=True)
    if (fam.dir / "rows" / row.id).is_dir():
        shutil.copytree(fam.dir / "rows" / row.id, world, dirs_exist_ok=True)
    if row.patch:
        prel, _, pfile = row.patch.partition("@")
        prel, pfile = prel.strip(), pfile.strip()
        tgt = world / prel
        if not tgt.is_file():
            raise ReplayRed(f"{row.id}: patch target missing in world: {prel}")
        if not (fam.dir / pfile).is_file():
            raise ReplayRed(f"{row.id}: patch file not found: {pfile}")
        p = subprocess.run(["jq", "-f", str(fam.dir / pfile), str(tgt)], capture_output=True)
        if p.returncode != 0:
            raise ReplayRed(f"{row.id}: patch jq failed ({pfile}): {p.stderr.decode()}")
        if p.stdout == tgt.read_bytes():
            raise ReplayRed(f"{row.id}: patch is a NO-OP — a row must earn its delta")
        tgt.write_bytes(p.stdout)
    return synth


def expected_for(fam: Family, row: Row) -> bytes:
    if not row.expect:
        raise ReplayRed(f"{row.id}: empty expect column")
    tpl = fam.dir / "expected" / f"{row.expect}.txt"
    if not tpl.is_file():
        raise ReplayRed(f"{row.id}: template not found: expected/{row.expect}.txt")
    text = tpl.read_bytes()
    for kv in row.params.split():
        k, _, v = kv.partition("=")
        text = text.replace(b"{{" + k.encode() + b"}}", v.encode())
    if b"{{" in text:
        raise ReplayRed(f"{row.id}: unfilled {{{{param}}}} in expected template")
    return text


def env_entries(fam: Family, row: Row) -> list[str]:
    return [*fam.lists.get("env", []), *row.env.split()]


def subject_argv_from_env(fam: Family, row: Row, *keys: str) -> list[str]:
    """Positional argv taken from named `K=V` env entries (family env, then the row's)."""
    kv = dict(e.partition("=")[::2] for e in env_entries(fam, row))
    return [kv[k] for k in keys]


def run_row(fam: Family, row: Row, subject: Sequence[str]) -> tuple[bytes, bytes]:
    """Run one row; returns (actual stream, expected). `subject` is the full argv of the command."""
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t).resolve()
        synth = materialise(fam, row, tmp)
        expected = expected_for(fam, row)
        bin_dir = tmp / fam.name / f"{row.id}.bin"
        bin_dir.mkdir(parents=True)
        for stub in ("gh", "kubectl", "claude", "opencode"):
            shutil.copy(STUBS / stub, bin_dir / stub)
            (bin_dir / stub).chmod(0o755)
        actions = tmp / fam.name / f"{row.id}.actions"
        actions.write_bytes(b"")
        env = {k: v for k, v in os.environ.items() if k not in UNSET}
        for e in env_entries(fam, row):
            k, _, v = e.partition("=")
            env[k] = v
        env.update(
            REPLAY_WORLD=str(synth / "world"),
            REPLAY_ACTIONS=str(actions),
            REPLAY_STUB_DIR=str(STUBS),
            REPLAY_FIXTURE=str(synth),
            REPLAY_ROOT=str(ROOT),
            PATH=f"{bin_dir}{os.pathsep}{env.get('PATH', '')}",
        )
        # restore_signals=False: run.sh runs with SIGPIPE ignored, inherited by every clause.
        p = subprocess.run(list(subject), cwd=synth, env=env, capture_output=True, restore_signals=False)
        stream = (
            actions.read_bytes()
            + _lines_prefixed(b"OUT ", p.stdout)
            + _lines_prefixed(b"ERR ", p.stderr)
            + f"RC {p.returncode}\n".encode()
        )
        stream = stream.replace(str(tmp).encode(), b"$TMP").replace(str(ROOT).encode(), b"$ROOT")
        for sed in fam.lists.get("scrub", []):
            stream = subprocess.run(["sed", sed], input=stream, capture_output=True, check=True).stdout
        return stream, expected


def row_verdict(fam: Family, row: Row, subject: Sequence[str]) -> str | None:
    """None when the row is green, else why it is red (the harness's reds included)."""
    try:
        actual, expected = run_row(fam, row, subject)
    except ReplayRed as e:
        return str(e)
    return None if actual == expected else f"stream moved:\n{_diff(expected, actual)}"


def _diff(expected: bytes, actual: bytes) -> str:
    import difflib

    return "".join(
        difflib.unified_diff(
            expected.decode(errors="replace").splitlines(keepends=True),
            actual.decode(errors="replace").splitlines(keepends=True),
            "expected",
            "actual",
        )
    )
