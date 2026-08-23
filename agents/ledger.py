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


# r4 F4/F5 (homelab PR#454): `models[]` was a de-duplicated SET (unsound to zip against the
# per-round exit-status list) and rows were stamped mid-flight. The row now carries `rounds[]` —
# one entry per round IN ORDER, strike-only entries included — and the flat fields are DERIVED
# from it (see merge_rounds + main). `snapshot` marks rows the retro must not pain-rank as facts.
# `^` anchored: the strike line is the FIRST line of its comment (agent-session.sh builds the
# body as STRIKE_LINE + details). A human quoting it writes `> AGENT_STRIKE …` — "talking about
# the strike" is not the strike (the infeasible-marker doctrine, coordinator-scan).
STRIKE_RE = re.compile(r"^AGENT_STRIKE: model=(\S+) error_class=(\S+) round=(\d+)")


def is_snapshot(issue_state, terminal_label):
    """r4 F5: a row stamped mid-flight is a snapshot, not a terminal fact. At emit time the issue
    is still OPEN (more rounds may land) or the terminal label is not one this reflex recognizes
    (the only terminal labels today are agent/done | agent/blocked). Historical rows predating the
    flag carry no `snapshot` field and are treated as NOT snapshot by the retro's pain-rank."""
    return issue_state == "open" or terminal_label not in TERMINAL_LABELS


def strike_rounds(org, project, issue):
    """Parse AGENT_STRIKE comments on an issue → [{round, model, error_class}]. A PR-less ride
    posts one structured first-line comment (agent-session.sh §STRIKE BOOKKEEPING); that comment
    IS the strike store. A strike-only round is a dispatch the manifests never saw (finalize did
    not run), so it must be folded in for `rounds[]` to be a complete per-round record. Best-
    effort: an unreadable comments probe is skipped loudly, never fatal to the reflex."""
    try:
        bodies = json.loads(sh([
            "gh", "api", "repos/%s/%s/issues/%s/comments?per_page=100" % (org, project, issue),
            "--jq", "[.[] | .body]",
        ]))
    except Exception as e:
        print("ledger: strike comments unreadable for %s#%s (%s) — strike-only rounds skipped"
              % (project, issue, e), file=sys.stderr)
        return []
    out, seen = [], set()
    for body in bodies:
        m = STRIKE_RE.search(body or "")
        if not m:
            continue
        rnd = int(m.group(3))
        if rnd in seen:
            continue
        seen.add(rnd)
        out.append({"round": rnd, "model": m.group(1), "error_class": m.group(2)})
    return out


def merge_rounds(manifest_rounds, strikes):
    """Fold strike-comment rounds into the manifest rounds, one entry per round IN ORDER (r4 F4).
    A round the manifests saw keeps its manifest entry (finalize ran — authoritative); a round
    only a strike comment knows about becomes a strike-only entry: no PR means no CI (ci=False)
    and no recorded exit status (error_class carries the classification). Manifest entries are
    preserved as-read (round-ordered, duplicates intact), strikes fill gaps, then re-sort by
    round (stable, so duplicates keep their manifest order)."""
    out = sorted(manifest_rounds, key=lambda r: r["round"])
    present = {r["round"] for r in out}
    for s in sorted(strikes, key=lambda s: s["round"]):
        if s["round"] in present:
            continue  # the manifest entry already covers this round
        out.append({
            "round": s["round"],
            "model": s["model"],
            "exit_status": "",
            "error_class": s["error_class"],
            "ci": False,
        })
        present.add(s["round"])
    out.sort(key=lambda r: r["round"])
    return out


def summarize(project, issue, rid, rsec):
    """Read every manifest under <project>/issue-<N>/ and fold them into the base of one ledger
    record. Returns the manifest-derived `rounds` list (one entry per worker manifest, ROUND
    ORDER — r4 F4) plus the aggregate fields. `main()` folds in strike-comment rounds via
    merge_rounds and derives the flat `models`/`worker_exit_statuses`/`ci_sequence` from the
    MERGED list so the join stays sound."""
    prefix = "s3://%s/%s/issue-%s/" % (BUCKET, project, issue)
    try:
        listing = s5(["ls", prefix + "*"], rid, rsec)
    except Exception:
        return None
    manifest_keys = [ln.split()[-1] for ln in listing.splitlines() if ln.strip().endswith("manifest.json")]
    workers, reviewers, timestamps = [], [], []
    pr_url = ""
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
            pr_url = pr_url or (m.get("stats", {}) or {}).get("pr_url") or m.get("pr_url") or ""
        elif role == "reviewer":
            reviewers.append(m)
    if not workers and not reviewers:
        return None

    def worker_round(m):
        r = m.get("round")
        return r if isinstance(r, int) else 0

    workers.sort(key=worker_round)
    def _model_rail(model: str) -> str:
        """Derive the rail from the model id (homelab#777 — same derived-field discipline as r4
        F4/F5 rounds array; historical rows lack it, readers tolerate absence). The router's
        record_report folds the launcher's explicit `rail` field into run_reports, but the
        manifest (written by agent-finalize) does not carry it yet — so the ledger derives it
        from the model prefix, matching the router's own ladder_tier / route() logic:
          claude/*  → subscription (Anthropic direct + claude-code)
          opencode-go/* → subscription (Go rail, also subscription-billed)
          *         → openrouter (everything else, including :free models)"""
        if model.startswith("claude/") or model.startswith("opencode-go/"):
            return "subscription"
        return "openrouter"

    rounds = []
    for w in workers:
        stats = w.get("stats") or {}
        model = w.get("model") or ""
        rounds.append({
            "round": worker_round(w),
            "model": model,
            "rail": _model_rail(model),
            "exit_status": w.get("exit_status") or stats.get("exit_status", ""),
            "error_class": w.get("error_class") or stats.get("error_class") or "",
            "ci": stats.get("ci_passed"),
        })
    ts = [t for t in timestamps if t]
    # Retro r1 F6: split queue from compute where the manifests carry it (agent-runtime#19 adds
    # queue_wait_s + duration_s per round; older manifests lack them → fields stay 0/absent-honest).
    queue_wait = sum(int((w.get("stats", {}) or {}).get("queue_wait_s") or 0) for w in workers)
    active = sum(int((w.get("stats", {}) or {}).get("duration_s") or 0) for w in workers)
    return {
        "rounds": rounds,
        "reviewer_rounds": len(reviewers),
        "wall_time_s": (max(ts) - min(ts)) if len(ts) >= 2 else 0,
        "queue_wait_s": queue_wait,
        "active_run_s": active,
        "total_cost_usd": round(sum(float((w.get("stats", {}) or {}).get("cost_usd") or 0) for w in workers), 4),
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
        rounds = merge_rounds(summ["rounds"], strike_rounds(org, project, issue))
        summ["rounds"] = rounds
        # r4 F4: the flat fields are DERIVED from `rounds`, order-preserving — never a
        # de-duplicated set — so zip(models, worker_exit_statuses) is sound.
        summ["models"] = [r["model"] for r in rounds]
        summ["worker_exit_statuses"] = [r["exit_status"] for r in rounds]
        summ["ci_sequence"] = [r["ci"] for r in rounds]
        summ["retry_storms"] = sum(1 for r in rounds
                                   if (r["exit_status"] or r["error_class"]) in ("auth-storm", "budget-403"))
        rec = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "key": key, "project": project, "issue": issue, "stack": repos.get(project, ""),
            "terminal_label": label, "issue_state": state, "closed_at": closed_at,
            "budget_tier": tier, "budget_cap_usd": cap,
            "calibration_error": round(summ["total_cost_usd"] / cap, 3) if cap else None,
        }
        rec.update(summ)
        # r4 F5: mark mid-flight stamps — at emit time the issue is still OPEN or the terminal
        # label is non-terminal, so more rounds may land. The retro's pain-rank excludes these.
        if is_snapshot(state, label):
            rec["snapshot"] = True
        new.append(json.dumps(rec, separators=(",", ":")))
        seen.add(key)
        print("ledger: + %s (%s, %d rounds, $%.4f)" % (key, label, len(rounds), summ["total_cost_usd"]))

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
