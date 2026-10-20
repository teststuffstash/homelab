#!/usr/bin/env python3
"""The tier-evidence CLI (GW-MODEL-TIERS) — the thin shell over `agent_gateway.tiers`:

  devbox run tiers -- snapshot --capability C --go-catalog G --openrouter-catalog O [-o benchmarks.json]
  devbox run tiers -- derive   [--benchmarks B] [--policy P]      print {rail: {tier: [ids]}} (+ the undecided tiers on stderr)
  devbox run tiers -- check    [--benchmarks B] [--policy P]      exit 1 + the mismatches when a list is not the derivation;
                                                                  an UNDECIDED tier (no priced candidate) is named, never a mismatch
  devbox run tiers -- apply    [--benchmarks B] [--policy P]      rewrite the DECIDED rails' lists in place, nothing else

Defaults: the deployed files under argocd/resources/agent-gateway/ (this is the monorepo's gateway/).
`snapshot`'s inputs are gathered by scripts/benchmarks-snapshot.sh; the subscription rail's
candidate aliases are an argument (ruling 4) — no model id lives in code.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import UTC, datetime
from pathlib import Path

from agent_gateway.config import tiers_policy
from agent_gateway.tiers import apply_text, build_snapshot, check, derive, undecided

HERE = Path(__file__).resolve().parent
DEPLOY = HERE.parent.parent / "argocd" / "resources" / "agent-gateway"


def _load(path: str | Path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    snap = sub.add_parser("snapshot")
    snap.add_argument("--capability", required=True, help="JSON list of [model, source, intelligence, coding, agentic, updated_ts]")
    snap.add_argument("--go-catalog", required=True, help="the gateway's GET /catalog/opencode answer (with `pricing`)")
    snap.add_argument("--openrouter-catalog", required=True, help="the gateway's GET /catalog/openrouter answer (the selected endpoint prices)")
    snap.add_argument("--anthropic-aliases", required=True, help="comma-separated `claude/<alias>` policy ids (ruling 4)")
    snap.add_argument("-o", "--out", default=str(DEPLOY / "benchmarks.json"))
    for name in ("derive", "check", "apply"):
        p = sub.add_parser(name)
        p.add_argument("--benchmarks", default=str(DEPLOY / "benchmarks.json"))
        p.add_argument("--policy", default=str(DEPLOY / "policy.json"))
    a = ap.parse_args(argv)

    if a.cmd == "snapshot":
        now = datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")
        doc = build_snapshot(capability=_load(a.capability), go_catalog=_load(a.go_catalog),
                             openrouter_catalog=_load(a.openrouter_catalog),
                             anthropic_aliases=[x for x in a.anthropic_aliases.split(",") if x], snapshot_at=now)
        Path(a.out).write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
        counts = {rail: f"{sum(1 for r in rows.values() if r['aa_id'])}/{len(rows)} benched, {sum(1 for r in rows.values() if r['out_price'] is not None)} priced"
                  for rail, rows in doc["rails"].items()}
        print(f"snapshot: {a.out} — capability {doc['sources']['capability']['rows']} rows pulled {doc['sources']['capability']['pulled_at']}; {counts}")
        return 0

    benchmarks = _load(a.benchmarks)
    policy = _load(a.policy)
    if a.cmd == "derive":
        tiers = tiers_policy(policy.get("tiers"))
        if tiers is None:
            print("derive: the policy has no `tiers` block", file=sys.stderr)
            return 2
        print(json.dumps(derive(benchmarks, tiers), indent=2))
        if und := undecided(benchmarks, tiers):
            print(f"derive: undecided (no priced candidate — the deployed list stands): {json.dumps(und)}", file=sys.stderr)
        return 0
    if a.cmd == "check":
        mismatches = check(policy, benchmarks)
        und = undecided(benchmarks, tiers_policy(policy.get("tiers")))
        if mismatches:
            print("check: the deployed tier lists are NOT the derivation:", file=sys.stderr)
            print(json.dumps(mismatches, indent=2), file=sys.stderr)
            return 1
        print("check: every decided tier list equals the derivation" + (f"; undecided (the deployed list stands): {json.dumps(und)}" if und else ""))
        return 0
    if a.cmd == "apply":
        tiers = tiers_policy(policy.get("tiers"))
        if tiers is None:
            print("apply: the policy has no `tiers` block", file=sys.stderr)
            return 2
        text = Path(a.policy).read_text(encoding="utf-8")
        lists = derive(benchmarks, tiers)
        und = undecided(benchmarks, tiers)
        decided = {rail: {t: ids for t, ids in ts.items() if t not in und.get(rail, [])} for rail, ts in lists.items()}
        decided = {rail: ts for rail, ts in decided.items() if ts}
        if und:
            print(f"apply: undecided, left as deployed: {json.dumps(und)}", file=sys.stderr)
        if not decided:
            print("apply: nothing is decided — nothing to write")
            return 0
        new = apply_text(text, decided)
        if new == text:
            print("apply: the lists already equal the derivation — nothing to write")
            return 0
        Path(a.policy).write_text(new, encoding="utf-8")
        print(f"apply: {a.policy} rewritten ({', '.join(f'{r}: {', '.join(ts)}' for r, ts in decided.items())})")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
