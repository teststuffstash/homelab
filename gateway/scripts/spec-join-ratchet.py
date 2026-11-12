#!/usr/bin/env python3
"""The spec ⇄ test JOIN ratchet (allure-behavior-snippets CONVENTIONS.md v0.6.9 § The lint gate,
item 6; the oracle-fleet scripts/spec-join-ratchet.py shape). Run AFTER pytest, inside the pinned
tool's environment:

    source scripts/lib/snippets.sh && allure_snippets_python scripts/spec-join-ratchet.py \
        [--results allure-results] [--specs specs] [--baseline scripts/spec-join-baseline.json] \
        [--write-baseline]

Per rule (every exact `## ID` / `### ID` heading under specs/), the GFM tables under the heading
are joined to the rule-labelled records of the run by the PINNED tool's own join
(`allure_behavior_snippets.evidence.spec_tables` + `join_rule` — the same code that renders the
spec site and the reviewer's digest, never a re-implementation), and five counts are taken:

  row-unkeyed        a description cell the join reaches only by substring — not a case id verbatim
  header-unthreaded  a column no matched case of that table carries as a parameter
                     (`name?` ⇄ `expected_name`; the `||` divider's empty cell is never a column)
  cell-mismatch      a cell ≠ its same-named parameter's value
  case-unspecified   a labelled case no table row names
  row-unproven       ⚖ a row painted ∅ (no case, exact or substring) INSIDE a table that joins at
                     least one row — the half-join hazard: the site renders the table as evidence
                     the moment ONE row keys a case, and every other row paints ∅ unverified
                     (docs/agents/specs-reviewer.md open question 5; oracle-fleet's answer is this
                     repo gate, adopted here). A description cell starting with `🚧` / `⚑` is
                     rule-10 incompleteness and is never counted; a rule whose index row (the
                     specs/README.md index or a page's Interface table) carries `🚧` / `⚑` counts 0.

Ratchet verdict against scripts/spec-join-baseline.json ({rule: {code: n}}): a count that EXCEEDS
its baseline line is red; equal passes; lower passes and prints "lowered" (the fixing PR
re-records with `--write-baseline` — a line only ever goes down). A rule with zero labelled
records in the results is SKIPPED (scripts/spec_gate.py owns "no evidence"); a rule absent from the
baseline is red only when any of its counts is non-zero. `--write-baseline` re-records every
counted rule from the current run and reports against the rewritten file (a write is never red;
record from a FULL run, never a `-k` subset).

Zero deps beyond the pinned wheel; stdlib otherwise.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from allure_behavior_snippets import evidence as ev

ISLAND = Path(__file__).resolve().parent.parent
CODES = ("row-unkeyed", "header-unthreaded", "cell-mismatch", "case-unspecified", "row-unproven")
WIP_MARKS = ("🚧", "⚑")

# Same shapes as scripts/spec_gate.py: a rule heading is exactly the ID; an index-table row names
# the ID (bare or linked) in its first cell.
ID_RE = r"[A-Z][A-Z0-9]*(?:-[A-Z0-9]+)+"
EXACT_HEAD = re.compile(rf"^(#{{2,6}})\s+({ID_RE})\s*$")
INDEX_CELL = re.compile(rf"^\|\s*(?:\[)?({ID_RE})(?:\]\(#?[^)]*\))?\s*\|")


def scan_specs(specs: Path) -> tuple[dict[str, Path], set[str]]:
    """→ (rule → page, rules whose index row carries a 🚧/⚑ mark)."""
    pages: dict[str, Path] = {}
    open_rules: set[str] = set()
    for md in sorted(specs.rglob("*.md")):
        if (specs / "evidence") in md.parents:  # the retired generated fragment dir a stale tree may carry
            continue
        fenced = False
        for line in md.read_text(encoding="utf-8").splitlines():
            if line.startswith("```"):
                fenced = not fenced
            if fenced:
                continue
            if (m := EXACT_HEAD.match(line)):
                pages.setdefault(m.group(2), md)
            elif (c := INDEX_CELL.match(line)) and any(mark in line for mark in WIP_MARKS):
                open_rules.add(c.group(1))
    return pages, open_rules


def join_counts(tables, records, rule_open: bool) -> tuple[dict[str, int], list[str]]:
    """The five counts for one rule over the pinned join, plus one detail line per offence
    (the same reading `evidence.spec_findings` gives the digest)."""
    counts = dict.fromkeys(CODES, 0)
    detail: list[str] = []

    def bump(code: str, line: str) -> None:
        counts[code] += 1
        detail.append(f"{code}: {line}")

    per_table, unspecified, _ = ev.join_rule(tables, records)
    for header, joined in per_table:
        matched = [j["record"] for j in joined if j["record"] is not None]
        for j in joined:
            desc = ev.norm_cell(j["spec"][0]) if j["spec"] else ""
            if j["record"] is None:
                if matched and not rule_open and not desc.startswith(WIP_MARKS):
                    bump("row-unproven", f"`{desc}` paints ∅ inside a table that joins")
                continue
            if j["kind"] == "substring":
                bump("row-unkeyed", f"`{desc}` joins only by substring to case "
                                    f"`{j['record']['case']}`")
            for name, spec_cell, actual in j["mismatches"]:
                bump("cell-mismatch", f"`{desc}` · {name}: spec {spec_cell!r} ⇢ test {actual!r}")
        if matched:
            for name in header[1:]:
                pname = ev.param_name(name)  # `rc?` ⇄ `expected_rc`
                if name and not any(pname in rec["params"] for rec in matched):  # '' = `||` divider
                    bump("header-unthreaded", f"column `{name}` is no parameter of its cases")
    for rec in unspecified:
        bump("case-unspecified", f"case `{rec['case']}` names no table row")
    return counts, detail


def ratchet(counts: dict[str, dict[str, int]], baseline: dict) -> tuple[list[str], list[str]]:
    """→ (red lines, info lines) comparing per-rule counts with the baseline."""
    red: list[str] = []
    info: list[str] = []
    for rule in sorted(counts):
        now = counts[rule]
        if rule not in baseline:
            bad = {c: n for c, n in now.items() if n}
            if bad:
                red.append(f"{rule} is absent from the baseline and counts "
                           + ", ".join(f"{c} {n}" for c, n in bad.items())
                           + " — key the rows (or record master's debt once with --write-baseline)")
            continue
        was = baseline[rule]
        for code in CODES:
            n, b = now.get(code, 0), int(was.get(code, 0))
            if n > b:
                red.append(f"{rule} {code}: {n} > baseline {b} — fix the rows, never raise the line")
            elif n < b:
                info.append(f"{rule} {code}: {n} < baseline {b} — lowered (re-record with --write-baseline)")
    return red, info


def run(results: Path, specs: Path, baseline_path: Path, write: bool) -> int:
    pages, open_rules = scan_specs(specs)
    evidence = ev.build_evidence(ev.load_results([results]), results_dirs=[results])
    records_by_rule = evidence["rules"]
    if not records_by_rule:
        print(f"spec-join-ratchet: {results} holds no rule-labelled results — nothing to ratchet "
              f"(run pytest first)")
        return 1
    text_cache: dict[Path, str] = {}
    counts: dict[str, dict[str, int]] = {}
    details: dict[str, list[str]] = {}
    ghosts: list[str] = []
    for rule, records in sorted(records_by_rule.items()):
        page = pages.get(rule)
        if page is None:
            ghosts.append(rule)  # spec_gate.py reds it; the join has no table to count against
            continue
        text = text_cache.setdefault(page, page.read_text(encoding="utf-8"))
        tables = ev.spec_tables(text, rule)
        counts[rule], details[rule] = join_counts(tables, records, rule in open_rules)
    skipped = sorted(set(pages) - set(counts))

    if write:
        baseline_path.write_text(
            json.dumps({r: counts[r] for r in sorted(counts)}, indent=1, ensure_ascii=False) + "\n",
            encoding="utf-8")
    baseline = json.loads(baseline_path.read_text(encoding="utf-8")) if baseline_path.is_file() else {}
    red, info = ratchet(counts, baseline)

    print("spec-join-ratchet (current/baseline per rule with any debt on either side; "
          + ", ".join(CODES) + "):")
    for rule in sorted(set(counts) | set(baseline)):
        if rule not in counts:
            continue  # skipped: no labelled records this run — the baseline line is kept as is
        now, was = counts[rule], baseline.get(rule, {})
        if not any(now.values()) and not any(int(was.get(c, 0)) for c in CODES):
            continue
        cells = "  ".join(f"{now.get(c, 0):3d}/{int(was.get(c, 0)):<3d}" for c in CODES)
        print(f"  {rule:<28} {cells}")
    total_now = {c: sum(v[c] for v in counts.values()) for c in CODES}
    total_was = {c: sum(int(baseline.get(r, {}).get(c, 0)) for r in counts) for c in CODES}
    print(f"  {'TOTAL':<28} " + "  ".join(f"{total_now[c]:3d}/{total_was[c]:<3d}" for c in CODES))
    print(f"  rules: {len(counts)} counted, {len(skipped)} skipped (no labelled records this run)"
          + (f", {len(ghosts)} with no heading (spec_gate.py): {', '.join(ghosts)}" if ghosts else ""))
    if write:
        print(f"  baseline written: {baseline_path} ({len(counts)} rules)")
    for line in info:
        print(f"  ↓ {line}")
    for line in red:
        print(f"  ✗ {line}")
        rule = line.split(" ", 1)[0]
        for d in details.get(rule, []):
            print(f"      {d}")
    if red:
        print(f"spec-join-ratchet: {len(red)} red")
        return 1
    print(f"spec-join-ratchet ok: {len(counts)} rules within baseline"
          + (f", {len(info)} lowered" if info else ""))
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--results", default=ISLAND / "allure-results", type=Path)
    ap.add_argument("--specs", default=ISLAND / "specs", type=Path)
    ap.add_argument("--baseline", default=ISLAND / "scripts" / "spec-join-baseline.json", type=Path)
    ap.add_argument("--write-baseline", action="store_true")
    args = ap.parse_args(argv)
    return run(args.results, args.specs, args.baseline, args.write_baseline)


if __name__ == "__main__":
    sys.exit(main())
