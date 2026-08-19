#!/bin/bash
# ci-timing — job-level CI queue-vs-duration readout for a repo's recent runs (homelab#518's
# instrument; the minRunners trial's readout tool). Run-level `gh run list` fields CANNOT answer
# "how long did a run wait for a runner": a run's own startedAt ≈ createdAt (the run "starts"
# immediately; the JOB inside it is what queues for a runner), so this walks the JOBS API —
# queue = job.started_at − job.created_at, duration = completed_at − started_at. Hand-rolled at
# least twice in the 2026-08 jail sessions before becoming a script (operator, 2026-08-19).
#
# Usage:
#   bash scripts/ci-timing.sh [-R owner/repo] [-w workflow.yaml] [-d YYYY-MM-DD] [-n limit] [-j job]
# Defaults: -R teststuffstash/homelab, -w ci.yaml, -d today (UTC), -n 30, -j ci
# Jail: devbox run ci-timing [-- flags]
set -euo pipefail
REPO="teststuffstash/homelab"; WF="ci.yaml"; DAY="$(date -u +%F)"; N=30; JOB="ci"
while getopts "R:w:d:n:j:" o; do case "$o" in
  R) REPO="$OPTARG";; w) WF="$OPTARG";; d) DAY="$OPTARG";; n) N="$OPTARG";; j) JOB="$OPTARG";;
  *) echo "usage: ci-timing.sh [-R repo] [-w workflow] [-d date] [-n limit] [-j jobname]" >&2; exit 2;;
esac; done

IDS=$(gh run list --repo "$REPO" --limit "$N" --created "$DAY" --workflow "$WF" --json databaseId -q '.[].databaseId')
[ -n "$IDS" ] || { echo "ci-timing: no $WF runs on $REPO created $DAY" >&2; exit 1; }

# One API call per run (job-level truth). A run whose job never started (still queued /
# cancelled pre-pickup) is printed with queue=∞ rather than dropped — an unpicked run is the
# finding, not noise (the absence-is-easiest-to-fake rule).
for id in $IDS; do
  gh api "repos/$REPO/actions/runs/$id/jobs" \
    --jq ".jobs[] | select(.name==\"$JOB\") | \"\(.created_at) \(.started_at) \(.completed_at) \(.conclusion)\"" \
    || echo "PROBE-FAIL $id"
done | python3 -c '
import sys
from datetime import datetime
P=lambda t: datetime.fromisoformat(t.replace("Z","+00:00"))
qs,ds,fails=[],[],0
for l in sys.stdin:
    p=l.split()
    if p and p[0]=="PROBE-FAIL": fails+=1; print(f"PROBE-FAIL run {p[1]} — jobs API unreadable"); continue
    if len(p)<3 or not p[0].startswith("2"): continue
    c,s,e=p[0],p[1],p[2]; concl=p[3] if len(p)>3 else "?"
    if s in ("null","None"):
        print(f"{c[11:19]}Z queue=NEVER-PICKED (created, no runner)"); continue
    q=(P(s)-P(c)).total_seconds()
    if e in ("null","None"):
        print(f"{c[11:19]}Z queue={q:5.0f}s RUNNING"); qs.append(q); continue
    d=(P(e)-P(s)).total_seconds(); qs.append(q); ds.append(d)
    print(f"{c[11:19]}Z queue={q:5.0f}s job={d:4.0f}s total={q+d:5.0f}s {concl}")
import statistics as st
if qs and ds:
    tot=[a+b for a,b in zip(qs,ds)]
    print(f"--- n={len(ds)} queue p50={st.median(qs):.0f}s max={max(qs):.0f}s | "
          f"job p50={st.median(ds):.0f}s max={max(ds):.0f}s | total p50={st.median(tot):.0f}s")
elif not qs: print("--- no completed jobs matched (job name filter? -j)")
if fails: sys.exit(3)
'
