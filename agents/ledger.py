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

# ── Rail vocabulary (homelab#795 — G-A, one taxonomy across ledger + proxy + rules) ────────────
# The launcher (agent-runtime's agent-session.sh, AGENT_RAIL) emits FOUR values:
#   openrouter          — default, everything routed through OpenRouter
#   subscription        — Claude direct + claude-code (Anthropic subscription)
#   opencode-go         — Go rail (opencode-go/ models, also subscription-billed)
#   subscription-fallback — degraded to subscription when OpenRouter/Go capacity is down
#
# The accounting views (_model_rail below and the agent_run_{cost_usd,count}_by_rail recording
# rules in argocd/resources/github-exporter/agent-rail-accounting.promtool-rules) fold the
# subscription-billed rails into a single "subscription" bucket. This is an EXPLICIT fold:
#   subscription   ← claude/*, opencode-go/*, subscription-fallback
#   openrouter     ← everything else
#
# The router's router_run_reports_by_rail_total metric surfaces the raw four values from the
# run_reports table; the difference between raw and folded is the stated fold above, not a drift.
# See homelab#795 for the full taxonomy specification.


def _model_rail(model: str, rail: str = "") -> str:
    """Return the accounting rail bucket for a model.

    When a recorded rail is available (non-empty, not the empty-string written by old
    record_report versions), it takes precedence over prefix derivation. Absence stays absence
    — a row with neither recorded rail nor a recognizable model prefix yields "openrouter",
    which is the default accounting bucket, not a guess (the #348 honesty rule).

    Falls back to prefix derivation for historical rows without a recorded rail:
      claude/*        → subscription (Anthropic direct + claude-code)
      opencode-go/*   → subscription (Go rail, also subscription-billed)
      *               → openrouter (everything else, including :free models)

    See _RAIL_VOCABULARY above for the canonical four values and the fold contract.
    """
    if rail and rail not in ("", "unknown"):
        # Recorded rail from the run-stats/report path wins. The four canonical rails fold
        # to two accounting buckets; return the folded value so the ledger's rail field has
        # a consistent vocabulary.
        if rail == "openrouter":
            return "openrouter"
        return "subscription"  # subscription, opencode-go, subscription-fallback → subscription
    if model.startswith("claude/") or model.startswith("opencode-go/"):
        return "subscription"
    return "openrouter"


def _budget_from_cr(project: str, issue: str) -> tuple[str, float, float] | None:
    """Query the OpenRouterKey CR to get the estimator's own pick_tier result.

    Retro r1 F6: the CR (created by estimate_budget.py --emit-cr) carries budget-tier and
    budget-estimate-usd labels. When the issue has no agent-budget/* override label, the ledger
    falls back to these labels so calibration_error is computed on every capped ride rather than
    only override-labelled ones.

    Returns (tier, cap_usd, estimate_usd) or None if no matching CR exists or the read fails.
    The CR name follows <project>-issue-<N>-round-<r>; we list all CRs in the project namespace
    and filter by name pattern. Best-effort: a failed read is skipped loudly, never fatal.
    """
    try:
        data = json.loads(sh([
            "kubectl", "get", "openrouterkeys", "-n", project,
            "-o", "json",
        ]))
    except Exception as e:
        print("ledger: kubectl get openrouterkeys failed for %s (%s) — CR budget fallback skipped"
              % (project, e), file=sys.stderr)
        return None
    prefix = "%s-issue-%s-round-" % (project, issue)
    best = None  # (round_num, tier, cap, estimate_usd)
    for item in data.get("items", []):
        try:
            name = item.get("metadata", {}).get("name", "")
            if not name.startswith(prefix):
                continue
            labels = item.get("metadata", {}).get("labels", {})
            tier = labels.get("budget-tier")
            estimate_usd = labels.get("budget-estimate-usd")
            if tier and estimate_usd is not None:
                cap = TIERS.get(tier)
                if cap is not None:
                    suffix = name[len(prefix):]
                    try:
                        rnd = int(suffix)
                    except (ValueError, TypeError):
                        rnd = 0
                    if best is None or rnd > best[0]:
                        best = (rnd, tier, cap, float(estimate_usd))
        except Exception as e:
            print("ledger: malformed CR %s (%s) — skipped" % (name, e), file=sys.stderr)
            continue
    if best is not None:
        return best[1], best[2], best[3]
    return None


def is_snapshot(issue_state, terminal_label):
    """r4 F5: a row stamped mid-flight is a snapshot, not a terminal fact. At emit time the issue
    is still OPEN (more rounds may land) or the terminal label is not one this reflex recognizes
    (the only terminal labels today are agent/done | agent/blocked). Historical rows predating the
    flag carry no `snapshot` field and are treated as NOT snapshot by the retro's pain-rank."""
    return str(issue_state).lower() == "open" or terminal_label not in TERMINAL_LABELS


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
            "rail": _model_rail(s["model"]),
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
    rounds = []
    for w in workers:
        stats = w.get("stats") or {}
        model = w.get("model") or ""
        # homelab#795: pass the recorded rail from the manifest (if present — agent-finalize
        # started folding AGENT_RAIL into manifest after agent-runtime#81). Older manifests
        # lack it, falling back to prefix derivation. The manifest rail takes the canonical
        # four values (openrouter, subscription, opencode-go, subscription-fallback) and
        # _model_rail folds them to the two accounting buckets.
        rounds.append({
            "round": worker_round(w),
            "model": model,
            "rail": _model_rail(model, rail=str(w.get("rail") or "")),
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
        # Retro r1 F6: when the issue has no agent-budget/* override label, fall back to the
        # OpenRouterKey CR's budget-tier label (set by estimate_budget.py --emit-cr) so
        # calibration_error is computed on every capped ride, not only override-labelled ones.
        if cap is None:
            cr_info = _budget_from_cr(project, issue)
            if cr_info is not None:
                tier, cap, _ = cr_info
        rounds = merge_rounds(summ["rounds"], strike_rounds(org, project, issue))
        summ["rounds"] = rounds
        # r4 F4: the flat fields are DERIVED from `rounds`, order-preserving — never a
        # de-duplicated set — so zip(models, worker_exit_statuses) is sound.
        summ["models"] = [r["model"] for r in rounds]
        summ["worker_exit_statuses"] = [r["exit_status"] for r in rounds]
        summ["ci_sequence"] = [r["ci"] for r in rounds]
        # budget-403 is prefix-matched: the raw-log classifier split it into -key/-account
        # subclasses (homelab#871) and the strike comment is this reader's source.
        summ["retry_storms"] = sum(
            1 for v in ((r["exit_status"] or r["error_class"]) for r in rounds)
            if v == "auth-storm" or v.startswith("budget-403"))
        rec = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "key": key, "project": project, "issue": issue, "stack": repos.get(project, ""),
            "terminal_label": label, "issue_state": state, "closed_at": closed_at,
            "budget_tier": tier, "budget_cap_usd": cap,
            "calibration_error": round(summ["total_cost_usd"] / (cap * len(rounds)), 3) if cap and rounds else None,
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
