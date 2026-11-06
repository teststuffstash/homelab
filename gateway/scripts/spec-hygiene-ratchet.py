#!/usr/bin/env python3
"""The report-HYGIENE ratchet (allure-behavior-snippets CONVENTIONS.md § Prime rule of reporting;
§ The lint gate, the ratchet principle). Sibling of scripts/spec-join-ratchet.py (the oracle-fleet shape); run AFTER pytest,
inside the pinned tool's environment:

    source scripts/lib/snippets.sh && allure_snippets_python scripts/spec-hygiene-ratchet.py \
        [--results allure-results] [--baseline scripts/spec-hygiene-baseline.json] \
        [--write-baseline]

Per rule, the codes the pinned tool computes deterministically from the Allure results
(`allure_behavior_snippets.evidence.hygiene_lines` — the same lines the specs reviewer's digest
prints, never a re-implementation): STEP_FLAT, STEP_NOISE, NAME_BLANK, ATTACH_BULK, PARAM_BLOB,
THREAD_BROKEN, UNIT_ONLY_CANDIDATE (and CONTEXT_TAX, should the tool emit it).

The baseline is the SET of identities (rule · world · case · code), not counts: a count would hide
a fix-one-break-one under the same rule and code. Verdict against scripts/spec-hygiene-baseline.json
(a sorted list of [rule, world, case, code]):

  identity absent from the baseline   red, with the case named
  baseline identity no longer firing  passes and prints "lowered"
  a renamed case                      a new identity (red) — the fixing PR re-records

A rule with zero labelled records in the results is SKIPPED (its baseline lines are kept);
`--write-baseline` re-records from a FULL run only (partial runs would drop identities) and is
never red.

Zero deps beyond the pinned wheel; stdlib otherwise.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from allure_behavior_snippets import evidence as ev

ISLAND = Path(__file__).resolve().parent.parent
Identity = tuple[str, str, str, str]  # (rule, world, case, code)


def fired(evidence: dict) -> set[Identity]:
    """Every (rule, world, case, code) the pinned hygiene computation fires over the evidence."""
    out: set[Identity] = set()
    for rule, records in evidence["rules"].items():
        worlds: dict[str, set[str]] = {}
        for r in records:
            worlds.setdefault(r["case"], set()).add(r.get("world") or "")
        for line in ev.hygiene_lines(rule, evidence)[2:]:
            if not line.startswith("- ") or line == "- none":
                continue
            body = line[2:]
            code, _, rest = body.partition(" ")
            prefix = f"{rule} "
            if not rest.startswith(prefix):
                continue
            rest = rest[len(prefix):]
            # the case may itself contain ": " — take the longest known case id that prefixes it
            case = max((c for c in worlds if rest.startswith(f"{c}: ")), key=len, default=None)
            if case is None:
                case = rest.split(": ", 1)[0]
            for world in worlds.get(case, {""}):
                out.add((rule, world, case, code))
    return out


def ratchet(now: set[Identity], baseline: set[Identity], counted: set[str]) -> tuple[list[Identity], list[Identity]]:
    """→ (new identities = red, baseline identities that stopped firing = lowered). Baseline lines
    of a rule with no records this run are kept, not lowered."""
    new = sorted(now - baseline)
    lowered = sorted(i for i in baseline - now if i[0] in counted)
    return new, lowered


def load_baseline(path: Path) -> set[Identity]:
    if not path.is_file():
        return set()
    return {tuple(row) for row in json.loads(path.read_text(encoding="utf-8"))}  # type: ignore[misc]


def fmt(i: Identity) -> str:
    rule, world, case, code = i
    return f"{code} {rule} · world {world or '—'} · case `{case}`"


def run(results: Path, baseline_path: Path, write: bool) -> int:
    evidence = ev.build_evidence(ev.load_results([results]), results_dirs=[results])
    if not evidence["rules"]:
        print(f"spec-hygiene-ratchet: {results} holds no rule-labelled results — nothing to ratchet "
              f"(run pytest --alluredir first)")
        return 1
    now = fired(evidence)
    counted = set(evidence["rules"])
    if write:
        kept = {i for i in load_baseline(baseline_path) if i[0] not in counted}
        baseline_path.write_text(
            "[\n" + ",\n".join(" " + json.dumps(list(i), ensure_ascii=False) for i in sorted(now | kept))
            + "\n]\n", encoding="utf-8")
    baseline = load_baseline(baseline_path)
    new, lowered = ratchet(now, baseline, counted)

    by_code: dict[str, int] = {}
    for i in now:
        by_code[i[3]] = by_code.get(i[3], 0) + 1
    print("spec-hygiene-ratchet (identities firing now/in baseline): "
          + (", ".join(f"{c} {n}" for c, n in sorted(by_code.items())) or "none"))
    print(f"  {len(now)} firing, {len(baseline)} in baseline, {len(counted)} rules with records")
    if write:
        print(f"  baseline written: {baseline_path} ({len(now)} identities)")
    for i in lowered:
        print(f"  ↓ {fmt(i)} — lowered (re-record with --write-baseline)")
    for i in new:
        print(f"  ✗ {fmt(i)} — not in the baseline; fix the case, never add the line")
    if new:
        print(f"spec-hygiene-ratchet: {len(new)} red")
        return 1
    print(f"spec-hygiene-ratchet ok: {len(now)} identities within baseline"
          + (f", {len(lowered)} lowered" if lowered else ""))
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--results", default=ISLAND / "allure-results", type=Path)
    ap.add_argument("--baseline", default=ISLAND / "scripts" / "spec-hygiene-baseline.json", type=Path)
    ap.add_argument("--write-baseline", action="store_true")
    args = ap.parse_args(argv)
    return run(args.results, args.baseline, args.write_baseline)


if __name__ == "__main__":
    sys.exit(main())
