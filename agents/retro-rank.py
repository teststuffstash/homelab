#!/usr/bin/env python3
"""Pain-rank the retro ledger — the retro-argo.yaml rank step, extracted so the r4 F5 snapshot
exclusion is replay-pinned (agents/replay/fixtures/retro-rank-snapshot-exclusion).

The ledger is append-only and read whole; every historical row lacks the `snapshot` field, and
those rows are treated as NOT snapshot. Rows stamped mid-flight (`snapshot: true` — at emit time
the issue was still OPEN or the terminal label was non-terminal) are NOT terminal facts: they are
EXCLUDED from the rank order and from the brief, and the exclusion is logged loudly (the
no-silent-caps rule) so the deep-dive budget never quietly lands on already-converged work.

Sort: blocked first, then rounds desc, then cost desc, then wall-time desc (B2 pick-worst-K).
`rounds` is the per-round ARRAY on new rows but a plain INT on historical rows — both are ranked
by count.

Usage: retro-rank.py <ledger.jsonl> <ledger-ranked.json> [KEEP]
"""
import json
import sys


def round_count(row):
    """Row `rounds` is the per-round array on new rows, the historical int count on old ones."""
    v = row.get("rounds")
    return len(v) if isinstance(v, list) else (v or 0)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    keep = int(sys.argv[3]) if len(sys.argv) > 3 else 40
    rows = [json.loads(l) for l in open(src) if l.strip()]
    snapshots = [r for r in rows if r.get("snapshot")]
    rankable = [r for r in rows if not r.get("snapshot")]
    rankable.sort(key=lambda r: (r.get("terminal_label") != "agent/blocked",
                                 -round_count(r),
                                 -(r.get("total_cost_usd") or 0),
                                 -(r.get("wall_time_s") or 0)))
    for i, r in enumerate(rankable):
        r["rank"] = i + 1
    json.dump(rankable[:keep], open(dst, "w"), indent=1)
    print("ledger: %d rows ranked, top %d into the brief; excluded %d snapshot rows from the rank "
          "(no silent caps)" % (len(rankable), min(keep, len(rankable)), len(snapshots)))


if __name__ == "__main__":
    main()
