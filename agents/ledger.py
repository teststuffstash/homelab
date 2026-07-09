#!/usr/bin/env python3
"""Retro-facts ledger — the deterministic B1 reflex (docs/agents/observability-and-retro.md §B1,
FU-057). NO LLM turn: when an agent-fix issue reaches a terminal label (agent/done | agent/blocked),
compute one summary line from the bucket manifests + issue labels and append it to
s3://agent-transcripts/_ledger.jsonl — the durable, append-only record the scheduled retro (FU-058)
reads to pick the worst-K tasks and score itself over time.

Level-triggered + idempotent: each run re-lists terminal issues and the existing ledger, and only
appends tasks not already present (keyed <project>#<issue>). S3 has no append, so it's a
read(reader key)-modify-write(writer key) of the single _ledger.jsonl; a single CronJob runs it, so
no concurrent writer. Everything is best-effort — a parse/list failure skips that task, never
crashes the reflex.

Env: GH_TOKEN(+FILE) for `gh issue list`; AGENT_TS_ENDPOINT/BUCKET + reader (list+get) and writer
(put) keys for the bucket. Repos come from agents/stacks.json (the same source coordinator-scan uses).
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time

ENDPOINT = os.environ.get("AGENT_TS_ENDPOINT", "http://garage.garage.svc.cluster.local:3900")
BUCKET = os.environ.get("AGENT_TS_BUCKET", "agent-transcripts")
LEDGER = "s3://%s/_ledger.jsonl" % BUCKET
TERMINAL_LABELS = ("agent/done", "agent/blocked")
# Budget tiers — kept in lockstep with agents/estimate_budget.py TIERS (the source of truth). Used to
# turn an `agent-budget/<tier>` dispatch label into the cap the actual cost is calibrated against.
TIERS = {"xs": 0.25, "sm": 0.50, "md": 1.00, "lg": 2.00}
TS_RE = re.compile(r"(\d{8}T\d{6}Z)")


def sh(cmd, env=None):
    return subprocess.run(cmd, env=env, check=True, timeout=120,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True).stdout


def s5(args, key_id, key_secret):
    env = dict(os.environ, AWS_ACCESS_KEY_ID=key_id, AWS_SECRET_ACCESS_KEY=key_secret, AWS_REGION="garage")
    return sh(["s5cmd", "--endpoint-url", ENDPOINT] + args, env=env)


def repos_from_stacks():
    """{repo: stack} across all stacks (dedup); the ledger scans every agent-target repo."""
    here = os.path.dirname(os.path.abspath(__file__))
    stacks = json.load(open(os.path.join(here, "stacks.json")))["stacks"]
    out = {}
    for st in stacks:
        for repo in st.get("repos", []):
            out.setdefault(repo, st["name"])
    return out


def terminal_issues(org, repos):
    """[(project, issue_number, terminal_label, state, closed_at, budget_tier)] across repos."""
    found = []
    for repo in repos:
        for label in TERMINAL_LABELS:
            try:
                data = json.loads(sh([
                    "gh", "issue", "list", "--repo", "%s/%s" % (org, repo), "--state", "all",
                    "--label", label, "--limit", "200",
                    "--json", "number,state,closedAt,labels",
                ]))
            except Exception as e:
                print("ledger: gh issue list failed for %s (%s) — skipped" % (repo, e), file=sys.stderr)
                continue
            for it in data:
                names = [l["name"] for l in it.get("labels", [])]
                tier = next((n.split("/", 1)[1] for n in names if n.startswith("agent-budget/")), None)
                found.append((repo, it["number"], label, it["state"], it.get("closedAt"), tier))
    return found


def parse_ts(name):
    m = TS_RE.search(name)
    if not m:
        return None
    return int(time.mktime(time.strptime(m.group(1), "%Y%m%dT%H%M%SZ")))


def summarize(project, issue, rid, rsec):
    """Read every manifest under <project>/issue-<N>/ and fold them into one ledger record."""
    prefix = "s3://%s/%s/issue-%s/" % (BUCKET, project, issue)
    try:
        listing = s5(["ls", prefix + "*"], rid, rsec)
    except Exception:
        return None
    manifest_keys = [ln.split()[-1] for ln in listing.splitlines() if ln.strip().endswith("manifest.json")]
    workers, reviewers, timestamps = [], [], []
    models, pr_url = set(), ""
    for rel in manifest_keys:
        key = prefix + rel
        try:
            m = json.loads(s5(["cat", key], rid, rsec))
        except Exception:
            continue
        timestamps.append(parse_ts(rel))
        role = m.get("role")
        if role == "worker":
            workers.append(m)
            if m.get("model"):
                models.add(m["model"])
            pr_url = pr_url or (m.get("stats", {}) or {}).get("pr_url") or m.get("pr_url") or ""
        elif role == "reviewer":
            reviewers.append(m)
    if not workers and not reviewers:
        return None

    def worker_round(m):
        r = m.get("round")
        return r if isinstance(r, int) else 0

    workers.sort(key=worker_round)
    exit_statuses = [w.get("exit_status") or (w.get("stats", {}) or {}).get("exit_status", "") for w in workers]
    ci_sequence = [(w.get("stats", {}) or {}).get("ci_passed") for w in workers]
    total_cost = round(sum(float((w.get("stats", {}) or {}).get("cost_usd") or 0) for w in workers), 4)
    retry_storms = sum(1 for e in exit_statuses if e in ("auth-storm", "budget-403"))
    ts = [t for t in timestamps if t]
    return {
        "rounds": len(workers),
        "reviewer_rounds": len(reviewers),
        "worker_exit_statuses": exit_statuses,
        "retry_storms": retry_storms,
        "ci_sequence": ci_sequence,
        "wall_time_s": (max(ts) - min(ts)) if len(ts) >= 2 else 0,
        "total_cost_usd": total_cost,
        "models": sorted(models),
        "pr_url": pr_url,
    }


def main():
    org = os.environ.get("ORG", "teststuffstash")
    rid = os.environ.get("AGENT_TS_READER_ID", "")
    rsec = os.environ.get("AGENT_TS_READER_SECRET", "")
    wid = os.environ.get("AGENT_TS_WRITER_ID", "")
    wsec = os.environ.get("AGENT_TS_WRITER_SECRET", "")
    if not (rid and wid):
        print("ledger: reader/writer S3 keys absent — nothing to do", file=sys.stderr)
        return

    # Existing ledger (idempotency): reader get, tolerate absence (first run).
    existing_lines, seen = [], set()
    try:
        with tempfile.NamedTemporaryFile("w+", suffix=".jsonl", delete=False) as f:
            cur = f.name
        s5(["cp", LEDGER, cur], rid, rsec)
        for ln in open(cur):
            ln = ln.strip()
            if not ln:
                continue
            existing_lines.append(ln)
            try:
                seen.add(json.loads(ln)["key"])
            except Exception:
                pass
    except Exception:
        pass  # ledger doesn't exist yet

    repos = repos_from_stacks()
    new = []
    for project, issue, label, state, closed_at, tier in terminal_issues(org, list(repos)):
        key = "%s#%s" % (project, issue)
        if key in seen:
            continue
        summ = summarize(project, issue, rid, rsec)
        if summ is None:
            continue  # no transcripts captured for this issue — nothing to record yet
        cap = TIERS.get(tier)
        rec = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "key": key, "project": project, "issue": issue, "stack": repos.get(project, ""),
            "terminal_label": label, "issue_state": state, "closed_at": closed_at,
            "budget_tier": tier, "budget_cap_usd": cap,
            "calibration_error": round(summ["total_cost_usd"] / cap, 3) if cap else None,
        }
        rec.update(summ)
        new.append(json.dumps(rec, separators=(",", ":")))
        seen.add(key)
        print("ledger: + %s (%s, %d rounds, $%.4f)" % (key, label, summ["rounds"], summ["total_cost_usd"]))

    if not new:
        print("ledger: no new terminal tasks to record (%d already ledgered)" % len(existing_lines))
        return
    body = "\n".join(existing_lines + new) + "\n"
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
        f.write(body)
        out = f.name
    s5(["cp", out, LEDGER], wid, wsec)
    print("ledger: wrote %d line(s) → %s (%d new)" % (len(existing_lines) + len(new), LEDGER, len(new)))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print("ledger: non-fatal error: %s" % e, file=sys.stderr)
        sys.exit(0)
