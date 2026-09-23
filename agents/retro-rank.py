#!/usr/bin/env python3
"""Pain-rank the retro ledger — the retro-argo.yaml rank step, extracted so the r4 F5 snapshot
exclusion is replay-pinned (agents/replay/fixtures/retro-rank-snapshot-exclusion).

The ledger is append-only and read whole; every historical row lacks the `snapshot` field, and
those rows are treated as NOT snapshot. Rows stamped mid-flight (`snapshot: true` — at emit time
the issue was still OPEN or the terminal label was non-terminal) are NOT terminal facts: they are
EXCLUDED from the rank order and from the brief, and the exclusion is logged loudly (the
no-silent-caps rule) so the deep-dive budget never quietly lands on already-converged work.

r5 F1 (homelab#1911): the ledger's `issue_state` / `terminal_label` are DISPATCH-TIME snapshots
(agents/ledger.py — stays that way, documented as such). When the IL-T28 belt has not yet flipped
a label, a merged success still ranks as pain — r5's deep-dive set spent half its budget auditing
CLOSED issues with merged PRs. So before cutting the brief, the top-KEEP candidates are re-read
LIVE: an issue that is CLOSED with a strong-link merged PR (the C6 grammar
`implements|closes|fixes|resolves #n`) is EXCLUDED from the rank whatever its `terminal_label`
says, and COUNTED in the same no-silent-caps line. The re-read is BOUNDED to the top-KEEP slice
(the brief's own cut; the deep-dive set is a subset of it) — never the whole ledger. A probe that
cannot be read (no `gh`, a repo the token cannot reach, an API blip) KEEPS the row and is counted
as unverified (rule #6: never drop on a failed read).

Sort: blocked first, then rounds desc, then cost desc, then wall-time desc (B2 pick-worst-K).
`rounds` is the per-round ARRAY on new rows but a plain INT on historical rows — both are ranked
by count.

Usage: retro-rank.py <ledger.jsonl> <ledger-ranked.json> [KEEP]
"""
import json
import os
import re
import subprocess
import sys

ORG = os.environ.get("ORG", "teststuffstash")

# The C6 strong-link grammar (implements|closes|fixes|resolves #N), the same set `finalize` writes
# and the scan's closeout belt keys on. `\b` on both ends so a prose suffix (`unresolved`,
# `prefixes`, `disclose`) cannot false-match — the failure the guard exists to kill.
STRONG_LINK = r"(?i)\b(?:implements|close[sd]?|fix(?:e[sd])?|resolve[sd]?):?[ \t]+#%s\b"


def round_count(row):
    """Row `rounds` is the per-round array on new rows, the historical int count on old ones."""
    v = row.get("rounds")
    return len(v) if isinstance(v, list) else (v or 0)


def gh_json(args, token):
    """Run `gh`, return parsed JSON, or None on ANY failure (rule #6: a failed read never drops)."""
    env = dict(os.environ)
    if token:
        env["GH_TOKEN"] = token
    try:
        p = subprocess.run(["gh"] + args, capture_output=True, text=True, env=env,
                           timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if p.returncode != 0:
        return None
    try:
        return json.loads(p.stdout)
    except ValueError:
        return None


def live_merged_work(row, token):
    """True iff the row's issue is CLOSED with a strong-link merged PR; None iff unreadable.

    One `gh issue view --json state,closedAt` + (only when CLOSED) one merged-PR probe. The
    project/issue come from the row's own fields, falling back to the `<project>#<issue>` key.
    """
    project = row.get("project") or str(row.get("key", "")).split("#", 1)[0]
    issue = row.get("issue")
    if issue is None:
        key = str(row.get("key", ""))
        issue = key.split("#", 1)[1] if "#" in key else ""
    if not project or issue in (None, ""):
        return None
    slug = "%s/%s" % (ORG, project)
    st = gh_json(["issue", "view", str(issue), "--repo", slug, "--json", "state,closedAt"], token)
    if not isinstance(st, dict) or "state" not in st:
        return None
    if str(st.get("state", "")).upper() != "CLOSED":
        return False
    prs = gh_json(["pr", "list", "--repo", slug, "--state", "merged", "--limit", "50",
                   "--json", "number,body"], token)
    if not isinstance(prs, list):
        return None
    pat = re.compile(STRONG_LINK % re.escape(str(issue)))
    for pr in prs:
        if pat.search(str(pr.get("body") or "")):
            return True
    return False


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

    # Live-state re-read, BOUNDED to the top-KEEP candidates (the brief slice; the deep-dive set
    # is a subset of it). Rows below the cut are never probed — the whole ledger is not the
    # contract. RETRO_GH_TOKEN overrides the ambient gh auth when the retro pod mirrors it.
    token = os.environ.get("RETRO_GH_TOKEN") or None
    merged_work = 0
    unverified = 0
    kept = []
    for i, r in enumerate(rankable):
        if i >= keep:
            kept.append(r)
            continue
        verdict = live_merged_work(r, token)
        if verdict is None:
            unverified += 1
            kept.append(r)
        elif verdict:
            merged_work += 1
        else:
            kept.append(r)

    for i, r in enumerate(kept):
        r["rank"] = i + 1
    json.dump(kept[:keep], open(dst, "w"), indent=1)
    print("ledger: %d rows ranked, top %d into the brief; excluded %d snapshot rows from the rank; "
          "excluded %d merged-work rows from the rank; kept %d rows on an unreadable probe "
          "(unverified) (no silent caps)"
          % (len(kept), min(keep, len(kept)), len(snapshots), merged_work, unverified))


if __name__ == "__main__":
    main()
