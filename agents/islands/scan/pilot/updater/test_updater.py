"""The `updater` replay family (agents/replay/fixtures/updater, 43 rows) run against the Python port.

Per row: materialise the world exactly as agents/replay/run.sh's table mode does (family world →
rows/<id>/ overlay → `jq -f patches/<p>.jq`, which must change the file), run `updater.run` over
`Recorded(world)` with the row's env, assemble the action stream the harness writes (CALL lines,
then OUT, then ERR, then `RC n`) and compare it LINE-FOR-LINE with expected/<expect>.txt rendered
from the row's params. No scrubbing beyond the harness's own (the family declares none).

Spec shape (gateway/tests/_rows.py, conftest.py): argnames == the spec table's header cells
(`expect?` → `expected_expect`), the param id == the description cell == the row id, a
`rule("SCAN-UPDATER-…")` mark from the spec page's tables (rows the page does not list →
SCAN-UPDATER-UNSPECIFIED), a `world` label, and world → given → ONE when → then steps.
allure is optional: without it the labels/steps are no-ops.
"""

from __future__ import annotations

import contextlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from github import Recorded  # noqa: E402
from updater import run  # noqa: E402

ROOT = Path(os.environ.get("HOMELAB_ROOT") or HERE.parents[4])  # agents/islands/scan/pilot/updater → repo root
# UPDATER_FAMILY points the suite at another copy of the family — e.g. the CONSTRUCTED full-shape
# one (family/, built by ../recorder/fullshape.py), which the strict all-12 `from_wire` needs.
FAMILY = Path(os.environ.get("UPDATER_FAMILY") or ROOT / "agents/replay/fixtures/updater")
FIELDS_TSV = ROOT / "agents/replay/stubs/gh-json-fields.tsv"
SPEC = HERE.parents[1] / "specs" / "updater.md"  # the island's contract page
REPO = "teststuffstash/testrepo"  # bridge.sh pins the fixture universe
UNSPECIFIED = "SCAN-UPDATER-UNSPECIFIED"
_DEVBOX_JQ = ROOT / ".devbox/nix/profile/default/bin/jq"
JQ = os.environ.get("JQ") or (str(_DEVBOX_JQ) if _DEVBOX_JQ.exists() else shutil.which("jq") or "jq")

try:  # allure-pytest is optional
    import allure
except ImportError:  # pragma: no cover
    allure = None


# ── rule() / steps — the gateway chassis, degraded to no-ops without allure ──────────────────────


def spec_rules() -> tuple[dict[str, str], dict[str, str]]:
    """(row id → rule id from the page's decision tables, rule id → enclosing heading)."""
    row_rule: dict[str, str] = {}
    sections: dict[str, str] = {}
    cur = None
    for line in SPEC.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^#{2,6}\s+(SCAN-UPDATER-[A-Z0-9-]+)\s*$", line)
        if m:
            cur = m.group(1)
            sections[cur] = "updater"
            continue
        if line.startswith("## "):
            cur = None
        if cur and line.startswith("| ") and not line.startswith("| description") and not line.startswith("|---"):
            cell = line.split("|")[1].strip()
            if cell and not cell.startswith("["):
                row_rule[cell] = cur
    return row_rule, sections


ROW_RULE, RULES = spec_rules()


def rule(rule_id: str) -> list:
    if rule_id != UNSPECIFIED and rule_id not in RULES:
        raise ValueError(f"rule({rule_id!r}): no `### {rule_id}` heading in {SPEC} — labels drift silently")
    marks = [pytest.mark.rule(rule_id)]
    if allure is not None:
        marks += [allure.story(rule_id), allure.epic("scan/specs/updater"), allure.feature(rule_id)]
    return marks


def _step(text: str):
    return allure.step(text) if allure is not None else contextlib.nullcontext()


def world(name: str) -> None:
    if allure is not None:
        with contextlib.suppress(Exception):
            allure.dynamic.label("world", name)
    with _step(f"Given: world {name}"):
        pass


def given(text: str):
    return _step(f"Given: {text}")


def when(text: str):
    return _step(f"When: {text}")


def then(claim: str, **compared):
    if allure is not None and compared:
        with contextlib.suppress(Exception):
            allure.attach(json.dumps(compared, indent=1, ensure_ascii=False), name="verdict",
                          attachment_type=allure.attachment_type.JSON)
    return _step(f"Then: {claim}")


# ── rows.psv (run.sh's table-mode reader) ────────────────────────────────────────────────────────


def bash_lines(path: Path) -> list[str]:
    """`while IFS= read -r line` — a final line with no trailing newline is never seen."""
    return path.read_text(encoding="utf-8").split("\n")[:-1]


def rows() -> list:
    out = []
    for line in bash_lines(FAMILY / "rows.psv"):
        if line == "" or line.startswith("#"):
            continue
        cells = line.split("|")
        cell = lambda i: cells[i].strip() if i < len(cells) else ""  # noqa: E731
        rid = cell(0)
        if not rid:
            continue
        out.append(pytest.param(cell(1) or "board", cell(2), cell(3), cell(4), cell(5),
                                id=rid, marks=rule(ROW_RULE.get(rid, UNSPECIFIED))))
    return out


ROWS = rows()


def materialise(rid: str, world_name: str, patch: str, dest: Path) -> Path:
    w = dest / "world"
    for base in (FAMILY / "worlds" / world_name, ROOT / "agents/replay/worlds" / world_name):
        if base.is_dir():
            shutil.copytree(base, w)
            break
    else:
        raise AssertionError(f"world not found: {world_name}")
    (w / "provenance.yaml").unlink(missing_ok=True)
    if (FAMILY / "rows" / rid).is_dir():
        shutil.copytree(FAMILY / "rows" / rid, w, dirs_exist_ok=True)
    if patch:
        rel, _, pfile = (s.strip() for s in patch.partition("@"))
        tgt = w / rel
        assert tgt.is_file(), f"patch target missing in world: {rel}"
        p = subprocess.run([JQ, "-f", str(FAMILY / pfile), str(tgt)], capture_output=True)
        assert p.returncode == 0, f"patch jq failed: {p.stderr.decode()}"
        assert p.stdout != tgt.read_bytes(), "patch is a NO-OP — a row must earn its delta"
        tgt.write_bytes(p.stdout)
    return w


def render(expect: str, params: str) -> list[str]:
    """`sed -i "s|{{k}}|v|g"` per `k=v` word, then refuse any unfilled `{{`. sed's replacement
    metacharacters (& \\) and regex keys are REFUSED here rather than emulated."""
    text = (FAMILY / "expected" / f"{expect}.txt").read_text(encoding="utf-8")
    for kv in params.split():
        k, _, v = kv.partition("=")
        assert re.fullmatch(r"[A-Za-z0-9_]+", k) and not re.search(r"[&\\|]", v), f"sed-special param {kv!r}"
        text = text.replace("{{" + k + "}}", v)
    assert "{{" not in text, "unfilled {{param}} in expected template"
    return text.split("\n")[:-1] if text.endswith("\n") else text.split("\n")


def stream_lines(prefix: str, raw: str) -> list[str]:
    """`sed 's/^/OUT /'` over a captured stream: a final unterminated line still counts."""
    if raw == "":
        return []
    parts = raw.split("\n")
    if raw.endswith("\n"):
        parts = parts[:-1]
    return [f"{prefix} {p}" for p in parts]


# ── the table ────────────────────────────────────────────────────────────────────────────────────


@pytest.mark.parametrize(("world_name", "patch", "env", "expected_expect", "params"), ROWS)
def test_updater_row(request, tmp_path, world_name, patch, env, expected_expect, params):
    rid = request.node.callspec.id
    world(world_name)
    with given(f"inputs: patch = {patch or '—'} · env = {env or '—'}"):
        wdir = materialise(rid, world_name, patch, tmp_path)
        row_env = dict(kv.partition("=")[::2] for kv in env.split())
    gh = Recorded(wdir, row_env, FIELDS_TSV, jq=JQ)
    out_buf: list[str] = []
    err_buf: list[str] = []
    with when(f"update-pr-branch {REPO}"):
        rc = run(gh, REPO, row_env, out=lambda s: out_buf.append(s + "\n"), err=err_buf.append)
    actual = gh.calls + stream_lines("OUT", "".join(out_buf)) + stream_lines("ERR", "".join(err_buf)) + [f"RC {rc}"]
    expected = render(expected_expect, params)
    first = next((i for i, (a, b) in enumerate(zip(expected, actual)) if a != b), None)
    if first is None and len(expected) != len(actual):
        first = min(len(expected), len(actual))
    with then(f"expected {expected_expect} ({len(expected)} actions)",
              expected_expect={"expected": expected, "actual": actual}):
        assert actual == expected, (
            f"first differing action line #{first}:\n  expected: "
            f"{expected[first] if first is not None and first < len(expected) else '<none>'}\n  actual:   "
            f"{actual[first] if first is not None and first < len(actual) else '<none>'}")
