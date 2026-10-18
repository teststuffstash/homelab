"""The Python version SET agrees — one major.minor across every pinned member (unlabelled chassis
test, the oracle-fleet `tests/test_serving_image.py` row 5 shape; homelab#2014 §Version SETS).

CI runs under the devbox interpreter, the image runs the Dockerfile's — a Renovate bump that
moves only the image `FROM` (homelab#2610, python 3.13 → 3.15) leaves `ci` proving the OLD
interpreter and says nothing about the new one. This row makes a one-member move red, naming
the odd member(s), so the fixer/reviewer loop reverts or moves the set together instead of a
human noticing. Static text scan: no network, no Docker, no interpreter launch.

Decision table (test id = row description):

| row | probe | expect |
|---|---|---|
| the Python version set agrees | every member's major.minor | one value |
| bumping only `<member>` is red, naming it | that member mutated to 9.99 | fails; names the member + the majority |
"""

from __future__ import annotations

import re
from collections.abc import Callable
from pathlib import Path

import pytest

ISLAND = Path(__file__).resolve().parent.parent

_PY = r"(\d+\.\d+)"
# member -> (island file, regex whose groups spell the major.minor, odd-value mutation of the match)
_MEMBERS: dict[str, tuple[str, str, Callable[[re.Match[str]], str]]] = {
    "Dockerfile build stage": (
        "Dockerfile", rf"^FROM python:{_PY}-slim AS build\s*$", lambda m: m.group(0).replace(m.group(1), "9.99")),
    "Dockerfile runtime stage": (
        "Dockerfile", rf"^FROM python:{_PY}-slim\s*$", lambda m: m.group(0).replace(m.group(1), "9.99")),
    "devbox.json python": (
        "devbox.json", rf'"python":\s*"{_PY}"', lambda m: m.group(0).replace(m.group(1), "9.99")),
    "devbox.lock python@": (
        "devbox.lock", rf'^\s*"python@{_PY}":', lambda m: m.group(0).replace(m.group(1), "9.99")),
    "pyproject.toml requires-python": (
        "pyproject.toml", rf'^requires-python\s*=\s*">=\s*{_PY}', lambda m: m.group(0).replace(m.group(1), "9.99")),
    "pyproject.toml ruff target-version": (
        "pyproject.toml", r'^target-version\s*=\s*"py(\d)(\d{2,})"', lambda m: 'target-version = "py999"'),
}


def _python_versions(texts: dict[str, str]) -> dict[str, str]:
    out = {}
    for member, (fname, pattern, _) in _MEMBERS.items():
        m = re.search(pattern, texts[fname], re.MULTILINE)
        out[member] = ".".join(m.groups()) if m else "<not found>"
    return out


def _python_set_problem(versions: dict[str, str]) -> str | None:
    if len(set(versions.values())) == 1:
        return None
    counts: dict[str, int] = {}
    for v in versions.values():
        counts[v] = counts.get(v, 0) + 1
    majority = max(counts, key=lambda v: (counts[v], v))
    odd = [m for m, v in versions.items() if v != majority]
    lines = [f"  {m}: {v}" for m, v in versions.items()]
    return (
        "the Python version set must agree on one major.minor — move every member together "
        "(Dockerfile FROM ×2, devbox.json + devbox.lock, requires-python, ruff target-version):\n"
        + "\n".join(lines)
        + f"\nmajority={majority}; odd one(s) out: {', '.join(odd)}"
    )


def _real_texts() -> dict[str, str]:
    return {f: (ISLAND / f).read_text(encoding="utf-8") for f in {v[0] for v in _MEMBERS.values()}}


def test_python_version_set_agrees():
    """row: the Python version set agrees — every pinned member reads one major.minor."""
    versions = _python_versions(_real_texts())
    assert "<not found>" not in versions.values(), f"a member pattern no longer matches: {versions}"
    problem = _python_set_problem(versions)
    assert problem is None, problem


@pytest.mark.parametrize("member", list(_MEMBERS), ids=list(_MEMBERS))
def test_python_version_set_mutation_names_member(member):
    """row: bumping only this member is red, naming it and the majority's value."""
    texts = _real_texts()
    fname, pattern, mutate = _MEMBERS[member]
    base = _python_versions(texts)[member]
    assert base != "<not found>", f"{member}: pattern no longer matches {fname}"
    texts[fname] = re.sub(pattern, mutate, texts[fname], count=1, flags=re.MULTILINE)
    problem = _python_set_problem(_python_versions(texts))
    assert problem is not None and f"odd one(s) out: {member}" in problem
    assert f"majority={base}" in problem and f"{member}: 9.99" in problem
