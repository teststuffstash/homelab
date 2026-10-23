#!/usr/bin/env python3
"""The requirement ⇄ schema ⇄ test-row coupling gate (stdlib only). Run AFTER pytest.

Red when:
  - a `specs/endpoints/<n>.md` `## GW-…` heading has no `x-requirements` mention in its sibling
    `<n>.schema.json`, or the schema names a requirement the page lacks (orphans both ways);
  - a key of a schema's `errors` object is not mentioned on its page;
  - a `## GW-…` heading anywhere in specs/ has zero rows in evidence/evidence.json, unless its
    index row (specs/README.md) or heading line carries `🚧 WIP` / `⚑ gap`;
  - evidence names a rule that has no heading (a ghost rule);
  - a policy world `specs/worlds/policy-*.json` and its `tests/fixtures/` twin differ (or one lacks the other);
  - the spec ⇄ test JOIN ratchet (CONVENTIONS.md § The intent column, § The lint gate): per rule, the
    count of `row-unkeyed` (a description cell no case id equals exactly), `header-unthreaded` (a
    column name no matched case carries as a parameter), `cell-mismatch` (a cell ≠ the same-named
    parameter's value) and `case-unspecified` (a labelled case no table row names) may never
    EXCEED the committed `scripts/spec-gate-baseline.json`; equal or lower passes, lower says so.
    `--write-baseline` re-records today's counts — a rule's fix lowers its line, never raises one.
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
ALLURE_RESULTS = ISLAND / "allure-results"
BASELINE = ISLAND / "scripts" / "spec-gate-baseline.json"
FIXTURE_POLICY = ISLAND / "tests" / "fixtures" / "policy-default.json"
WORLD_POLICY = SPECS / "worlds" / "policy-default.json"

RULE_RE = re.compile(r"^#{2,6}\s+(GW-[A-Z0-9-]+)(?:\s|$)")
ID_RE = re.compile(r"\bGW-[A-Z0-9-]+\b")
WIP_MARKS = ("🚧", "⚑")
JOIN_CODES = ("row-unkeyed", "header-unthreaded", "cell-mismatch", "case-unspecified")

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


def split_cells(line: str) -> list[str]:
    """A pipe-table line's cells: `|` inside backticks is text, not a border."""
    return [c.strip() for c in re.split(r"\|(?=(?:[^`]*`[^`]*`)*[^`]*$)", line.strip().strip("|"))]


def tables(md: Path):
    """Yield (line_no, header cells, rows) for every pipe table."""
    lines = md.read_text(encoding="utf-8").splitlines()
    i = 0
    while i < len(lines):
        if lines[i].lstrip().startswith("|") and i + 1 < len(lines) and re.match(r"^\s*\|?\s*:?-{2,}", lines[i + 1]):
            header = split_cells(lines[i])
            rows = []
            j = i + 2
            while j < len(lines) and lines[j].lstrip().startswith("|"):
                rows.append(split_cells(lines[j]))
                j += 1
            yield i + 1, header, rows
            i = j
        else:
            i += 1


def spec_pages() -> list[Path]:
    """Every authored spec page. specs/evidence/ is GENERATED (evidence_render.py writes one
    `## <RULE>` page per rule there, gitignored), so reading it would make a second run of the
    gate see every heading twice and fail on a dirty tree that a fresh checkout passes."""
    generated = SPECS / "evidence"
    return [md for md in sorted(SPECS.rglob("*.md")) if generated not in md.parents]


def wip_ids() -> set[str]:
    """Requirement ids whose index row (specs/README.md) or own heading line carries a WIP/gap mark."""
    out: set[str] = set()
    for md in spec_pages():
        for line in md.read_text(encoding="utf-8").splitlines():
            if any(m in line for m in WIP_MARKS):
                if RULE_RE.match(line) or line.lstrip().startswith("|"):
                    out.update(ID_RE.findall(line))
    return out


def norm_cell(text: str) -> str:
    """A spec cell / an Allure parameter value as the pinned join compares them
    (allure_behavior_snippets.evidence.norm_cell): backticks gone, a markdown link is its text,
    one pair of surrounding quotes gone (the spec quotes literals, allure-pytest records
    `repr()`), whitespace folded."""
    s = str(text).replace("`", "").strip()
    s = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", s)
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
        s = s[1:-1]
    return " ".join(s.split())


def allure_cases() -> dict[str, list[dict]]:
    """rule → [{case, params}] from the raw Allure results (one result file per executed test):
    the story label is the rule, the case is the parametrize id (`name[...]`) or the test's
    dynamic title (a function-per-row case's `row:` docstring), params by their argnames."""
    out: dict[str, list[dict]] = {}
    if not ALLURE_RESULTS.is_dir():
        return out
    for p in sorted(ALLURE_RESULTS.glob("*-result.json")):
        try:
            d = json.loads(p.read_text(encoding="utf-8"))
        except ValueError:
            continue
        rule = next((lab["value"] for lab in d.get("labels", []) if lab.get("name") == "story"), None)
        if not rule or not rule.startswith("GW-"):
            continue
        name = d.get("name", "")
        m = re.search(r"\[(.*)\]$", name)
        case = m.group(1) if m else name
        params = {str(prm["name"]): str(prm.get("value", "")) for prm in d.get("parameters", []) if prm.get("name")}
        out.setdefault(rule, []).append({"case": case, "params": params})
    return out


def rule_tables(md: Path):
    """Yield (rule, line_no, header, rows) for every decision table (header[0] == `description`)
    under a `## GW-…` heading; the `||` divider's empty cell is dropped from header and rows alike."""
    lines = md.read_text(encoding="utf-8").splitlines()
    rule_at: list[str | None] = []
    current: str | None = None
    for line in lines:
        if (m := RULE_RE.match(line)):
            current = m.group(1)
        elif re.match(r"^#{1,2}\s", line):
            current = None  # a page- or section-level heading that names no rule ends the section
        rule_at.append(current)
    for line_no, header, rows in tables(md):
        rule = rule_at[line_no - 1]
        if rule is None or not header or header[0].lower() != "description":
            continue
        keep = [i for i, h in enumerate(header) if h != ""]
        yield rule, line_no, [header[i] for i in keep], [[r[i] if i < len(r) else "" for i in keep] for r in rows]


def join_counts(cases: dict[str, list[dict]]) -> tuple[dict[str, dict[str, int]], list[str]]:
    """Per rule, the four join codes counted over its decision tables, plus one detail line each."""
    counts: dict[str, dict[str, int]] = {}
    detail: list[str] = []
    seen_cases: dict[str, set[str]] = {}

    def bump(rule: str, code: str, line: str) -> None:
        counts.setdefault(rule, dict.fromkeys(JOIN_CODES, 0))[code] += 1
        detail.append(f"{code} {rule}: {line}")

    for md in spec_pages():
        where = md.relative_to(ISLAND)
        for rule, line_no, header, rows in rule_tables(md):
            # every record of a case id together (a row id reused across tests or worlds): a column is
            # threaded when ANY of them carries it, a cell matches when ANY of them equals it — the
            # result-file order (random UUIDs) must never decide the count
            by_case: dict[str, list[dict]] = {}
            for c in cases.get(rule, []):
                by_case.setdefault(c["case"], []).append(c)
            unthreaded_cols: set[str] = set()
            for row in rows:
                desc = norm_cell(row[0]) if row else ""
                if desc.startswith(WIP_MARKS):
                    continue  # rendered incompleteness (rule 10) — no case is expected
                recs = by_case.get(desc)
                if not recs:
                    bump(rule, "row-unkeyed", f"{where}:{line_no} `{desc}` equals no case id of this rule")
                    continue
                seen_cases.setdefault(rule, set()).add(desc)
                for name, spec_cell in zip(header[1:], row[1:], strict=False):
                    values = sorted({r["params"][name] for r in recs if name in r["params"]})
                    if not values:
                        unthreaded_cols.add(name)
                    elif norm_cell(spec_cell) not in {norm_cell(v) for v in values}:
                        bump(rule, "cell-mismatch", f"`{desc}` · {name}: spec {spec_cell!r} ⇢ test {values!r}")
            for name in sorted(unthreaded_cols):
                bump(rule, "header-unthreaded", f"{where}:{line_no} column `{name}` is no parameter of its cases")
        # a rule with no decision table at all: every labelled case is unspecified (counted below)
    for rule, recs in cases.items():
        for c in recs:
            if c["case"] not in seen_cases.get(rule, set()):
                bump(rule, "case-unspecified", f"case `{c['case']}` names no table row")
    return counts, detail


def main() -> int:
    write_baseline = "--write-baseline" in sys.argv[1:]
    if not SPECS.is_dir():
        msg = f"specs/ absent at {SPECS}"
        if os.environ.get("GATEWAY_SPECS_OPTIONAL") == "1":
            print(f"spec-gate: WARNING {msg} — skipped (GATEWAY_SPECS_OPTIONAL=1)")
            return 0
        print(f"spec-gate: RED {msg}")
        return 1

    # 1. page ⇄ schema coupling
    all_headings: dict[str, Path] = {}
    for md in spec_pages():
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

    # 3. every policy world is its test policy (policy-default, policy-codex, …)
    if WORLD_POLICY.exists():
        worlds = {p.name for p in WORLD_POLICY.parent.glob("policy-*.json")}
        fixtures = {p.name for p in FIXTURE_POLICY.parent.glob("policy-*.json")}
        for name in sorted(worlds | fixtures):
            world, fixture = WORLD_POLICY.parent / name, FIXTURE_POLICY.parent / name
            if not world.exists() or not fixture.exists():
                red.append(f"policy world {name}: present in only one of specs/worlds/ and tests/fixtures/")
            elif world.read_bytes() != fixture.read_bytes():
                red.append(f"{world.relative_to(ISLAND)} and {fixture.relative_to(ISLAND)} differ — they must be byte-identical")
    else:
        warn.append(f"{WORLD_POLICY.relative_to(ISLAND)} absent — the test policy is unchecked against the specs world")

    # 4. report-only table-shape signals
    for md in spec_pages():
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

    # 5. the spec ⇄ test join ratchet (CONVENTIONS.md § The lint gate: exceeding fails, equal or lower passes)
    cases = allure_cases()
    if not cases:
        warn.append(f"{ALLURE_RESULTS.relative_to(ISLAND)}/ holds no rule-labelled results — the join ratchet is unchecked (run pytest first)")
    else:
        counts, detail = join_counts(cases)
        baseline: dict[str, dict[str, int]] = json.loads(BASELINE.read_text(encoding="utf-8")) if BASELINE.exists() else {}
        if write_baseline:
            BASELINE.write_text(json.dumps({r: counts[r] for r in sorted(counts)}, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
            info.append(f"join ratchet: baseline written to {BASELINE.relative_to(ISLAND)} ({len(counts)} rules)")
            baseline = counts
        for rule in sorted(set(counts) | set(baseline)):
            now, was = counts.get(rule, dict.fromkeys(JOIN_CODES, 0)), baseline.get(rule, dict.fromkeys(JOIN_CODES, 0))
            for code in JOIN_CODES:
                n, b = now.get(code, 0), was.get(code, 0)
                if n > b:
                    red.append(f"join ratchet {rule} {code}: {n} > baseline {b} — "
                               + "; ".join(d.removeprefix(f"{code} {rule}: ") for d in detail if d.startswith(f"{code} {rule}: ")))
                elif n < b and not write_baseline:
                    info.append(f"join ratchet {rule} {code}: {n} < baseline {b} — lower it (`spec_gate.py --write-baseline`)")
        total = {code: sum(c[code] for c in counts.values()) for code in JOIN_CODES}
        info.append("join ratchet: " + ", ".join(f"{code} {n}" for code, n in total.items()) + f" across {len(counts)} rules")

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
