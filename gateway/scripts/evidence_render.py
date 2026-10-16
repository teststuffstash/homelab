#!/usr/bin/env python3
"""evidence/evidence.json → markdown tables (stdlib only).

Writes `evidence/evidence.md` (every rule) and, when `specs/evidence/` exists, one
`specs/evidence/<RULE>.md` per rule; appends the summary to `$GITHUB_STEP_SUMMARY` when set and
prints the whole render to stdout between `evidence-render: BEGIN` / `END` (the run log is the
only CI output a reader outside the job can fetch).
Each table is sha-stamped (git sha + the test policy's sha256) so a spec row can say which
revision earned its evidence.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

ISLAND = Path(__file__).resolve().parent.parent
EVIDENCE = ISLAND / "evidence" / "evidence.json"
OUT_ALL = ISLAND / "evidence" / "evidence.md"
SPECS_EVIDENCE = ISLAND / "specs" / "evidence"

MARK = {"passed": "✅", "failed": "❌", "skipped": "⏭"}


def render_rule(rid: str, bucket: dict, stamp: str) -> str:
    lines = [f"## {rid}", "", f"_{stamp}_ — {bucket['passed']} passed, {bucket['failed']} failed, {bucket['skipped']} skipped", "",
             "| row | outcome | module | duration (s) |", "|---|---|---|---|"]
    for r in bucket["rows"]:
        row = r["row"].replace("|", "\\|")
        lines.append(f"| {row} | {MARK.get(r['outcome'], r['outcome'])} {r['outcome']} | `{Path(r['module']).name}` | {r['duration_s']} |")
    return "\n".join(lines) + "\n"


def main() -> int:
    if not EVIDENCE.exists():
        print(f"evidence-render: {EVIDENCE} missing — run pytest first")
        return 1
    doc = json.loads(EVIDENCE.read_text(encoding="utf-8"))
    stamp = f"git {str(doc.get('git_sha') or 'unknown')[:12]} · policy sha256 {str(doc.get('policy_sha256') or 'unknown')[:12]} · {doc.get('generated_at')}"
    rules = doc.get("rules", {})
    summary = ["# agent-gateway evidence", "", f"_{stamp}_", "", "| requirement | rows | passed | failed | skipped |", "|---|---|---|---|---|"]
    for rid in sorted(rules):
        b = rules[rid]
        summary.append(f"| {rid} | {len(b['rows'])} | {b['passed']} | {b['failed']} | {b['skipped']} |")
    body = "\n".join(summary) + "\n\n" + "\n".join(render_rule(rid, rules[rid], stamp) for rid in sorted(rules))
    OUT_ALL.parent.mkdir(exist_ok=True)
    OUT_ALL.write_text(body, encoding="utf-8")
    print(f"evidence-render: wrote {OUT_ALL.relative_to(ISLAND)} ({len(rules)} rules)")
    if SPECS_EVIDENCE.is_dir():
        for rid in rules:
            if rid.startswith("GW-"):
                (SPECS_EVIDENCE / f"{rid}.md").write_text(render_rule(rid, rules[rid], stamp), encoding="utf-8")
        print(f"evidence-render: wrote per-rule pages under {SPECS_EVIDENCE.relative_to(ISLAND)}/")
    if step := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(step, "a", encoding="utf-8") as fh:
            fh.write("\n".join(summary) + "\n")
    # The whole render ALSO goes to stdout, between markers, so the CI run LOG carries it: the
    # step summary has no API, `specs/evidence/` is gitignored, and the specs reviewer (ADR-155,
    # agents/specs-reviewer-session.sh) reads evidence from `gh run view --log` — it counts a
    # table only when the stamp names the PR head it is reviewing.
    print("evidence-render: BEGIN")
    print(body, end="")
    print("evidence-render: END")
    return 0


if __name__ == "__main__":
    sys.exit(main())
