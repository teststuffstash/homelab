#!/usr/bin/env python3
"""The requirement ⇄ schema ⇄ test-row coupling gate (stdlib only). Run AFTER pytest.

Red when:
  - a `specs/endpoints/<n>.md` `## GW-…` heading has no `x-requirements` mention in its sibling
    `<n>.schema.json`, or the schema names a requirement the page lacks (orphans both ways);
  - a key of a schema's `errors` object is not mentioned on its page;
  - a `## GW-…` heading anywhere in specs/ has zero rows in evidence/evidence.json, unless its
    index row (specs/README.md) or heading line carries `🚧 WIP` / `⚑ gap`;
  - evidence names a rule that has no heading (a ghost rule);
  - `specs/worlds/policy-default.json` and `tests/fixtures/policy-default.json` differ.
Report-only: table-shape split candidates (> ~6 columns, > ~12 rows, a column constant across
all rows) — the specs reviewer reads WHY, the gate never demands a size.

`GATEWAY_SPECS_OPTIONAL=1` turns a missing specs/ into a warning (a checkout carrying the
service half alone); CI never sets it.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

ISLAND = Path(__file__).resolve().parent.parent
SPECS = ISLAND / "specs"
EVIDENCE = ISLAND / "evidence" / "evidence.json"
FIXTURE_POLICY = ISLAND / "tests" / "fixtures" / "policy-default.json"
WORLD_POLICY = SPECS / "worlds" / "policy-default.json"

RULE_RE = re.compile(r"^#{2,6}\s+(GW-[A-Z0-9-]+)(?:\s|$)")
ID_RE = re.compile(r"\bGW-[A-Z0-9-]+\b")
WIP_MARKS = ("🚧", "⚑")

red: list[str] = []
warn: list[str] = []
info: list[str] = []


def headings(md: Path) -> list[str]:
    return [m.group(1) for line in md.read_text(encoding="utf-8").splitlines() if (m := RULE_RE.match(line))]


def walk_requirements(node, out: set[str]) -> None:
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "x-requirements":
                vals = v if isinstance(v, list) else [v]
                out.update(str(x) for x in vals)
            else:
                walk_requirements(v, out)
    elif isinstance(node, list):
        for v in node:
            walk_requirements(v, out)


def walk_errors(node, out: set[str]) -> None:
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "errors" and isinstance(v, dict):
                out.update(v.keys())
            walk_errors(v, out)
    elif isinstance(node, list):
        for v in node:
            walk_errors(v, out)


def tables(md: Path):
    """Yield (line_no, header cells, rows) for every pipe table."""
    lines = md.read_text(encoding="utf-8").splitlines()
    i = 0
    while i < len(lines):
        if lines[i].lstrip().startswith("|") and i + 1 < len(lines) and re.match(r"^\s*\|?\s*:?-{2,}", lines[i + 1]):
            header = [c.strip() for c in lines[i].strip().strip("|").split("|")]
            rows = []
            j = i + 2
            while j < len(lines) and lines[j].lstrip().startswith("|"):
                rows.append([c.strip() for c in lines[j].strip().strip("|").split("|")])
                j += 1
            yield i + 1, header, rows
            i = j
        else:
            i += 1


def wip_ids() -> set[str]:
    """Requirement ids whose index row (specs/README.md) or own heading line carries a WIP/gap mark."""
    out: set[str] = set()
    for md in SPECS.rglob("*.md"):
        for line in md.read_text(encoding="utf-8").splitlines():
            if any(m in line for m in WIP_MARKS):
                if RULE_RE.match(line) or line.lstrip().startswith("|"):
                    out.update(ID_RE.findall(line))
    return out


def main() -> int:
    if not SPECS.is_dir():
        msg = f"specs/ absent at {SPECS}"
        if os.environ.get("GATEWAY_SPECS_OPTIONAL") == "1":
            print(f"spec-gate: WARNING {msg} — skipped (GATEWAY_SPECS_OPTIONAL=1)")
            return 0
        print(f"spec-gate: RED {msg}")
        return 1

    # 1. page ⇄ schema coupling
    all_headings: dict[str, Path] = {}
    for md in sorted(SPECS.rglob("*.md")):
        for h in headings(md):
            if h in all_headings:
                red.append(f"{h}: heading in both {all_headings[h].relative_to(ISLAND)} and {md.relative_to(ISLAND)} (one ID namespace)")
            all_headings[h] = md
    for md in sorted((SPECS / "endpoints").glob("*.md")) if (SPECS / "endpoints").is_dir() else []:
        schema = md.with_suffix(".schema.json")
        if not schema.exists():
            red.append(f"{md.relative_to(ISLAND)}: no sibling {schema.name}")
            continue
        try:
            doc = json.loads(schema.read_text(encoding="utf-8"))
        except ValueError as e:
            red.append(f"{schema.relative_to(ISLAND)}: not JSON ({e})")
            continue
        page_ids = set(headings(md))
        schema_ids: set[str] = set()
        walk_requirements(doc, schema_ids)
        for orphan in sorted(page_ids - schema_ids):
            red.append(f"{md.relative_to(ISLAND)}: `## {orphan}` has no x-requirements mention in {schema.name}")
        for orphan in sorted(schema_ids - page_ids - set(all_headings)):
            red.append(f"{schema.relative_to(ISLAND)}: x-requirements names {orphan}, which no page heads")
        for orphan in sorted((schema_ids & set(all_headings)) - page_ids):
            warn.append(f"{schema.relative_to(ISLAND)}: x-requirements names {orphan}, headed on {all_headings[orphan].name} not this page")
        errors: set[str] = set()
        walk_errors(doc, errors)
        text = md.read_text(encoding="utf-8")
        for code in sorted(errors):
            if code not in text:
                red.append(f"{md.relative_to(ISLAND)}: error code `{code}` from {schema.name} is not mentioned on the page")

    # 2. every requirement has evidence rows (or is WIP / gap)
    if not EVIDENCE.exists():
        red.append(f"{EVIDENCE.relative_to(ISLAND)} missing — run pytest first")
        rules: dict = {}
    else:
        rules = json.loads(EVIDENCE.read_text(encoding="utf-8")).get("rules", {})
    wip = wip_ids()
    for rid in sorted(all_headings):
        rows = rules.get(rid, {}).get("rows", [])
        if not rows:
            if rid in wip:
                info.append(f"{rid}: no evidence rows — marked WIP/gap, allowed")
            else:
                red.append(f"{rid}: zero test rows in evidence.json and not marked 🚧 WIP / ⚑ gap")
        else:
            failed = sum(1 for r in rows if r["outcome"] != "passed")
            info.append(f"{rid}: {len(rows)} rows, {failed} not passed")
    for rid in sorted(rules):
        if rid.startswith("GW-") and rid not in all_headings:
            red.append(f"evidence names {rid}, which has no `## {rid}` heading in specs/ (ghost rule)")
    if "(unlabelled)" in rules:
        warn.append(f"{len(rules['(unlabelled)']['rows'])} test rows carry no @rule marker")

    # 3. the policy world is the test policy
    if WORLD_POLICY.exists():
        if WORLD_POLICY.read_bytes() != FIXTURE_POLICY.read_bytes():
            red.append(f"{WORLD_POLICY.relative_to(ISLAND)} and {FIXTURE_POLICY.relative_to(ISLAND)} differ — they must be byte-identical")
    else:
        warn.append(f"{WORLD_POLICY.relative_to(ISLAND)} absent — the test policy is unchecked against the specs world")

    # 4. report-only table-shape signals
    for md in sorted(SPECS.rglob("*.md")):
        for line_no, header, rows in tables(md):
            where = f"{md.relative_to(ISLAND)}:{line_no}"
            if len(header) > 6:
                info.append(f"split-candidate {where}: {len(header)} columns")
            if len(rows) > 12:
                info.append(f"split-candidate {where}: {len(rows)} rows")
            if len(rows) >= 3:
                for ci, name in enumerate(header):
                    col = [r[ci] for r in rows if ci < len(r)]
                    if len(col) == len(rows) and len(set(col)) == 1 and col[0] not in ("", "—", "-"):
                        info.append(f"split-candidate {where}: column `{name}` is constant ({col[0]!r}) across all rows — mixed questions?")

    for line in info:
        print(f"spec-gate: {line}")
    for line in warn:
        print(f"spec-gate: WARNING {line}")
    for line in red:
        print(f"spec-gate: RED {line}")
    print(f"spec-gate: {len(all_headings)} requirements, {len(red)} red, {len(warn)} warnings")
    return 1 if red else 0


if __name__ == "__main__":
    sys.exit(main())
