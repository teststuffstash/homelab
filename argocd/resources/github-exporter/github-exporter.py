#!/usr/bin/env python3
"""GitHub → Prometheus poller (the ONE GitHub polling mechanism — keep it that way).

Polls the GitHub REST API for (a) workflow-run conclusions across every repo in the org and
(b) month-to-date billing usage from the enhanced billing platform, and serves both as
Prometheus metrics on :9504/metrics. Why DIY instead of an off-the-shelf exporter: as of
2026-07 none polls BOTH — promhippie/github_exporter only ingests workflow runs via a public
webhook receiver (rejected: docs/agents/workflow.md, polling-first) and Labbs/
github-actions-exporter bills via the pre-enhanced-platform endpoints GitHub removed. Adding
future GitHub data = one more collect_*() here, not another deployment/token.

Runs from a ConfigMap on a stock python image (deployment.yaml next to this file; ArgoCD-managed,
kustomize's configMapGenerator hash rolls the pod on edits) — stdlib only, no state (each poll
re-reads the full window; a restart just re-polls). Repos are discovered from
the org each poll, so new repos need no config. Budget: (repos + 2) requests per poll ≈ a few
hundred/hour against the 5000/h PAT limit.

Config (env): GITHUB_TOKEN (fine-grained PAT: org Administration:read for billing + repo
Actions:read + Metadata:read + Pull requests:read, all repos —
scripts/github-exporter-pat-bootstrap.sh; Pull requests:read is the one NEW scope feeding
collect_open_prs / the stall detector, FU-063 — absent it that one collector is skipped, the rest
keep flowing), GITHUB_ORG,
POLL_INTERVAL_SECONDS (120), RUN_WINDOW_HOURS (24 — also bounds series cardinality: one series per run in window).
"""

import json
import os
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

API = "https://api.github.com"
# Repo visibility map (refreshed each runs-poll): billing "included minutes" only counts PRIVATE
# repos — public-repo hosted minutes are free (found 2026-07-24: dashboard said 2927, the GitHub
# meter 1436 = exactly the private subset). Billing metrics carry visibility=<private|public>.
_repo_private = {}
# Run→runner-class memo (completed runs never change; in-flight re-checked). The jobs endpoint is
# the only place runner labels live — one request per NEW run in the window, then cached.
_run_runner = {}
ORG = os.environ.get("GITHUB_ORG", "teststuffstash")
TOKEN = os.environ["GITHUB_TOKEN"].strip()
INTERVAL = int(os.environ.get("POLL_INTERVAL_SECONDS", "120"))
WINDOW_HOURS = int(os.environ.get("RUN_WINDOW_HOURS", "24"))
# ADR-093 review edge-trigger: POST reviewable PRs to the Argo Events webhook so a review Workflow
# fires without the review-reflex CronJob's */5 GraphQL poll (this poll already knows the reviewable
# set — reuse it, the one-poller doctrine). Empty = disabled (dispatch stays with the CronJob).
REVIEW_WEBHOOK_URL = os.environ.get("REVIEW_WEBHOOK_URL", "").strip()
# The reviewer App's login (GraphQL bare; REST appends "[bot]" — stripped where compared). Feeds
# the bot_approved_head arm of the review edge-trigger, mirroring review-reflex.sh's $bot.
REVIEWER_BOT = os.environ.get("REVIEWER_BOT", "homelab-reviewer").strip()

_lock = threading.Lock()
_body = "# poller has not completed a cycle yet\n"
_errors = 0
_last_success = 0
_review_dispatched = set()  # (repo, number, head_sha) already POSTed this process lifetime


def gh(path):
    req = urllib.request.Request(
        API + path,
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "homelab-github-exporter",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


def graphql(query, variables):
    req = urllib.request.Request(
        API + "/graphql",
        data=json.dumps({"query": query, "variables": variables}).encode(),
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Content-Type": "application/json",
            "User-Agent": "homelab-github-exporter",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        payload = json.loads(resp.read())
    data = payload.get("data")
    errors = payload.get("errors")
    # Tolerate PARTIAL data: a field the PAT can't read (e.g. statusCheckRollup on a PRIVATE repo —
    # check runs are unreadable by ANY fine-grained-PAT scope, checks:read is App-only) comes back
    # as null with a FORBIDDEN error entry, but the rest of `data` is valid. Only raise when
    # there's no usable data at all. collect_open_prs fills the gap from workflow runs instead
    # (ci_state_from_runs, FU-063a). A hard/whole-query error (bad token, SAML) still raises.
    if errors and data is None:
        raise RuntimeError(errors)
    if errors:
        print("graphql: partial data (%d field error(s), e.g. %s) — continuing"
              % (len(errors), errors[0].get("message", "")), flush=True)
    return data


def gh_paged(path, key):
    """Yield items across pages (path must already contain a query string)."""
    for page in range(1, 20):  # hard cap: 20 pages ≈ 2000 items, far beyond this org
        batch = gh(f"{path}&per_page=100&page={page}")
        items = batch[key] if key else batch
        yield from items
        if len(items) < 100:
            return


def epoch(iso):
    return int(datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp())


def esc(value):
    return str(value).replace("\\", r"\\").replace('"', r"\"").replace("\n", r"\n")


def metric(name, labels, value):
    inner = ",".join(f'{k}="{esc(v)}"' for k, v in labels.items())
    return f"{name}{{{inner}}} {value}"


def collect_workflow_runs(lines):
    since = (datetime.now(timezone.utc) - timedelta(hours=WINDOW_HOURS)).strftime("%Y-%m-%dT%H:%M:%SZ")
    all_repos = [r for r in gh_paged(f"/orgs/{ORG}/repos?type=all", None) if not r["archived"]]
    repos = [r["name"] for r in all_repos]
    _repo_private.update({r["name"]: bool(r.get("private")) for r in all_repos})
    lines += [
        "# TYPE github_workflow_run_updated_timestamp gauge",
        "# HELP github_workflow_run_updated_timestamp Last update (epoch s) of each workflow run in the window; conclusion/status ride as labels.",
        "# TYPE github_workflow_run_duration_seconds gauge",
    ]
    for repo in repos:
        # created=>=<ts> — GitHub search qualifier, URL-encoded
        path = f"/repos/{ORG}/{repo}/actions/runs?created=%3E%3D{since}"
        for run in gh_paged(path, "workflow_runs"):
            labels = {
                "owner": ORG,
                "repo": repo,
                "workflow": run.get("name") or "",
                "branch": run.get("head_branch") or "",
                "event": run.get("event") or "",
                "number": run.get("run_number") or 0,
                "attempt": run.get("run_attempt") or 0,
                "id": run.get("id") or 0,
                "status": run.get("status") or "",
                "conclusion": run.get("conclusion") or "",
                "runner": _runner_class(repo, run),
            }
            updated = epoch(run["updated_at"])
            lines.append(metric("github_workflow_run_updated_timestamp", labels, updated))
            started = run.get("run_started_at")
            if started:
                lines.append(metric("github_workflow_run_duration_seconds", labels, updated - epoch(started)))


def _runner_class(repo, run):
    """hosted | self-hosted | mixed | unknown — from the run's job runner labels (the runs API
    itself carries nothing). Memoized for completed runs; a failed probe returns unknown rather
    than a guess (rule #6)."""
    rid = run.get("id")
    done = (run.get("status") == "completed")
    if rid in _run_runner and done:
        return _run_runner[rid]
    try:
        jobs = gh(f"/repos/{ORG}/{repo}/actions/runs/{rid}/jobs?per_page=100").get("jobs") or []
        kinds = set()
        for j in jobs:
            labs = [str(x).lower() for x in (j.get("labels") or [])]
            if any("self-hosted" in x or "homelab" in x for x in labs):
                kinds.add("self-hosted")
            elif labs:
                kinds.add("hosted")
        cls = "unknown" if not kinds else ("mixed" if len(kinds) > 1 else kinds.pop())
    except Exception:
        return _run_runner.get(rid, "unknown")
    if done:
        _run_runner[rid] = cls
    return cls


def ci_state_from_runs(repo, sha):
    """CI state for a head SHA from workflow-run conclusions — the PRIVATE-repo path (FU-063a).

    statusCheckRollup aggregates CHECK RUNS, and no fine-grained-PAT scope can read those on a
    private repo (`checks:read` is App-only; GitHub Actions reports check runs, never commit
    statuses — verified 2026-07-16). `/actions/runs?head_sha=` rides the PAT's existing
    Actions:read instead. Approximates the rollup: latest attempt per (workflow, event);
    anything unfinished → pending, any failure-ish conclusion → failure, all green-ish (≥1) →
    success, no runs → none (also the value for non-Actions CI, same degradation as before)."""
    if not sha:
        return "none"  # empty head_sha= would return ALL runs, not none
    runs = gh(f"/repos/{ORG}/{repo}/actions/runs?head_sha={sha}&per_page=100").get("workflow_runs") or []
    latest = {}
    for run in runs:
        key = (run.get("workflow_id"), run.get("event"))
        rank = (run.get("run_number") or 0, run.get("run_attempt") or 0)
        if key not in latest or rank > latest[key][0]:
            latest[key] = (rank, run)
    if not latest:
        return "none"
    conclusions = []
    for _, run in latest.values():
        if run.get("status") != "completed":
            return "pending"
        conclusions.append(run.get("conclusion") or "")
    if any(c in ("failure", "timed_out", "startup_failure", "cancelled", "action_required") for c in conclusions):
        return "failure"
    if all(c in ("success", "neutral", "skipped") for c in conclusions):
        return "success"
    return "error"  # stale / unknown mixtures — visible rather than falsely green


def newest_nonmerge_commit_at_rest(repo, number):
    """Newest non-merge commit date for a PR via REST — the fallback where GraphQL commit objects
    FORBIDDEN-null for this fine-grained PAT (found live 2026-07-21 on PUBLIC oracle-fleet#60:
    the 2026-07-12 "commits node nulls" quirk is a GraphQL-only restriction, not private-only —
    REST /pulls/{n}/commits reads fine with the same token). Called lazily, only for a
    changes_requested PR whose GraphQL dates came back empty — one REST call per such PR per
    poll, a rare state. Returns "" on any doubt (>=100 commits could hide the newest on page 1;
    the fast path then stays off and the */15 CronWorkflow backstop owns the re-review)."""
    try:
        commits = gh(f"/repos/{ORG}/{repo}/pulls/{number}/commits?per_page=100")
        if not isinstance(commits, list) or len(commits) >= 100:
            return ""
        return max(
            ((c.get("commit") or {}).get("committer") or {}).get("date") or ""
            for c in commits
            if not ((c.get("commit") or {}).get("message") or "").startswith("Merge branch ")
        ) if commits else ""
    except Exception:
        return ""


def maybe_dispatch_review(repo, number, head_sha, *, ci_state, review_decision, armed, draft,
                          labels, newest_commit_at="", newest_review_at="", bot_approved_at=""):
    """ADR-093 review edge-trigger: POST a reviewable PR to the Argo Events webhook so a review
    Workflow fires now, instead of waiting up to 5 min for the review-reflex CronJob's poll. The
    reviewable predicate mirrors review-reflex.sh (armed ∧ green ∧ (review_required ∨
    reviewable_again), skipping the mechanical `automerge` dep lane and any `agent/error`
    circuit-breaker). Deduped per (repo, number, head_sha) for this process lifetime — one POST per
    reviewable head; a restart re-POSTs a still-reviewable PR, which is correct (it genuinely needs
    a review), and the review Workflow's deterministic name + reviewer-session.sh's STEP-0
    self-guard backstop any in-flight race. Best-effort: a webhook failure never disturbs the
    metrics poll (the CronJob is the backstop)."""
    if not REVIEW_WEBHOOK_URL:
        return
    # review_required = fresh PR; changes_requested = a re-review round ONLY once the worker has
    # pushed new content after the verdict (dismiss-stale dismisses approvals, not change-requests,
    # so reviewDecision stays CHANGES_REQUESTED forever). That "new content landed" check is
    # review-reflex.sh's `reviewable_again` (newest NON-MERGE commit > newest verdict) and it must
    # live HERE, not be delegated to the reviewer's STEP-0 guard: on 2026-07-21 (oracle-fleet#60)
    # this poll re-POSTed a head one cycle after its CHANGES_REQUESTED verdict landed (restart at
    # 16:10 had emptied the dedup set), STEP-0 correctly refused — and its agent/error label then
    # froze the PR's own FIX round for 5 h behind the human-first breaker. Private repos
    # FORBIDDEN-null the commit objects → newest_commit_at is "" → the changes_requested fast path
    # stays off there and the review-reflex CronJob (App token, full visibility) owns re-reviews.
    reviewable_again = bool(newest_commit_at) and newest_commit_at > newest_review_at
    # bot_approved_head, mirroring review-reflex.sh / MP-T08: a codeowner-gated PR snaps BACK to
    # review_required after the bot approves (the human's approval is what's pending) — POSTing it
    # re-reviews an already-approved head, whose STEP-0 refusal latches agent/error on a PR that's
    # merely parked on a human (found live 2026-07-21, oracle-fleet#60, ~2 min after the verdict).
    # Fail CLOSED when a bot approval exists but commit dates are unreadable: the backstop
    # CronWorkflow (App token, full visibility) owns any genuinely-new head.
    bot_approved_head = bool(bot_approved_at) and (
        not newest_commit_at or bot_approved_at > newest_commit_at)
    reviewable = (
        ci_state == "success"
        and ((review_decision == "review_required" and not bot_approved_head)
             or (review_decision == "changes_requested" and reviewable_again))
        and armed
        and not draft
        and "automerge" not in labels
        and "agent/error" not in labels
    )
    if not reviewable or not head_sha:
        return
    key = (repo, str(number), head_sha)
    if key in _review_dispatched:
        return
    body = json.dumps({"repo": repo, "number": str(number), "head_sha": head_sha}).encode()
    try:
        req = urllib.request.Request(
            REVIEW_WEBHOOK_URL, data=body,
            headers={"Content-Type": "application/json"}, method="POST",
        )
        with urllib.request.urlopen(req, timeout=10):
            pass
        _review_dispatched.add(key)
        print(f"review dispatch: {repo}#{number} @{head_sha[:8]} → webhook", flush=True)
    except Exception as exc:
        print(f"review dispatch FAILED for {repo}#{number}: {exc}", flush=True)


_PR_QUERY = """
query($org:String!, $cursor:String) {
  organization(login:$org) {
    repositories(first:50, after:$cursor, orderBy:{field:PUSHED_AT, direction:DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        name
        pullRequests(states:OPEN, first:40) {
          nodes {
            number isDraft updatedAt reviewDecision baseRefName headRefName
            labels(first:15){ nodes { name } }
            reviews(last:30){ nodes { author { login } state submittedAt } }
            headRefOid
            autoMergeRequest { enabledAt }
            commits(last:10){ nodes { commit { committedDate messageHeadline statusCheckRollup { state } } } }
          }
        }
      }
    }
  }
}
"""


def collect_open_prs(lines):
    """Emit per-open-PR review + CI state — the input the running-agents dashboard's stall detector
    needs (a green, unapproved PR with no reviewer acting on it = the 2.5h silent stall measured
    2026-07-09, docs/agents/observability-and-retro.md §A′). One GraphQL query/poll pulls
    reviewDecision + statusCheckRollup across every repo, so cost stays ~1 request.

    Token scope: this needs the PAT to also carry `Pull requests:read` (the PR list + reviewDecision).
    CI state comes from statusCheckRollup where readable (public repos — any token) and otherwise
    from ci_state_from_runs() under `Actions:read` (private repos; no PAT scope reads their check
    runs — FU-063a). If the PAT lacks Pull requests:read the GraphQL call raises and this collector
    is skipped (the poll's try/except isolates it — billing + workflow-runs keep flowing,
    github_exporter_errors_total ticks). Grant it via scripts/github-exporter-pat-bootstrap.sh."""
    lines += [
        "# TYPE github_pull_request_open gauge",
        "# HELP github_pull_request_open 1 per open PR; review_decision (approved|changes_requested|"
        "review_required|none) + ci_state (success|failure|pending|error|none) + draft ride as labels.",
        "# TYPE github_pull_request_updated_timestamp gauge",
        "# HELP github_pull_request_updated_timestamp Last-updated epoch of each open PR (age = time()-this).",
        # Agent-loop guards (docs/agents/merge-path.md §Runaway dispatch): this is the detection
        # path INDEPENDENT of the review-reflex's own breaker — different code, different token —
        # born from the 2026-07-12 oracle-fleet#13 loop (12 duplicate reviewer approvals before the
        # subscription session limit stopped it, nothing alerted).
        "# TYPE github_pull_request_label gauge",
        "# HELP github_pull_request_label 1 per label on each open PR (agent/error = automation circuit breaker — alerted).",
        "# TYPE github_pull_request_reviews_recent gauge",
        "# HELP github_pull_request_reviews_recent APPROVED/CHANGES_REQUESTED reviews per author in the trailing hour — a healthy worker↔reviewer iteration tops ~3, a dispatch loop runs 8+.",
    ]
    cursor = None
    for _ in range(10):  # hard page cap
        data = graphql(_PR_QUERY, {"org": ORG, "cursor": cursor})
        repos = data["organization"]["repositories"]
        for repo in repos["nodes"] or []:
            if not repo:
                continue
            for pr in (repo.get("pullRequests") or {}).get("nodes") or []:
                if not pr:
                    continue
                # Null-safe: on private repos the forbidden statusCheckRollup nulls the whole
                # commit list element (bubbles to the nullable list item), so any commits[i] can be
                # None — fall through to the workflow-run join rather than crashing the collector.
                # commits[-1] = the NEWEST commit (GraphQL last:N is chronological ascending).
                commits = (pr.get("commits") or {}).get("nodes") or []
                commit = (commits[-1] or {}).get("commit") if commits else None
                rollup = (commit or {}).get("statusCheckRollup")
                if rollup:
                    ci_state = rollup["state"].lower()
                else:
                    # Private repo (rollup FORBIDDEN-nulls for every PAT) or genuinely no checks:
                    # join workflow runs by head SHA under Actions:read (FU-063a). One REST call
                    # per rollup-less PR per poll — a handful against the 5000/h limit.
                    ci_state = ci_state_from_runs(repo["name"], pr.get("headRefOid") or "")
                labels = {
                    "owner": ORG,
                    "repo": repo["name"],
                    "number": pr["number"],
                    "draft": "true" if pr["isDraft"] else "false",
                    "review_decision": (pr["reviewDecision"] or "none").lower(),
                    "ci_state": ci_state,
                    "base": pr["baseRefName"],
                    "head": pr["headRefName"],
                }
                lines.append(metric("github_pull_request_open", labels, 1))
                lines.append(metric("github_pull_request_updated_timestamp", labels, epoch(pr["updatedAt"])))
                ident = {"owner": ORG, "repo": repo["name"], "number": pr["number"]}
                label_names = {lab["name"] for lab in (pr.get("labels") or {}).get("nodes") or [] if lab}
                for lab in (pr.get("labels") or {}).get("nodes") or []:
                    if lab:
                        lines.append(metric("github_pull_request_label", {**ident, "label": lab["name"]}, 1))
                # reviewable_again inputs, mirroring review-reflex.sh: newest NON-MERGE commit
                # (updater merge commits are not new content — the #57 nine-review loop) vs newest
                # APPROVED/CHANGES_REQUESTED verdict by ANY author; ISO-8601 UTC strings compare
                # correctly as strings. This PAT FORBIDDEN-nulls GraphQL commit objects on EVERY
                # repo (public included, found live 2026-07-21) → "" here, REST fallback below.
                commit_objs = [(c or {}).get("commit") or {} for c in commits]
                newest_commit_at = max(
                    (co.get("committedDate") or "" for co in commit_objs
                     if not (co.get("messageHeadline") or "").startswith("Merge branch ")),
                    default="")
                bot_approved_at = max(
                    (rv.get("submittedAt") or "" for rv in (pr.get("reviews") or {}).get("nodes") or []
                     if rv and rv.get("state") == "APPROVED"
                     and (((rv.get("author") or {}).get("login") or "").removesuffix("[bot]")
                          == REVIEWER_BOT)),
                    default="")
                if not newest_commit_at and (
                    (pr["reviewDecision"] or "") == "CHANGES_REQUESTED"
                    or ((pr["reviewDecision"] or "") == "REVIEW_REQUIRED" and bot_approved_at)
                ):
                    newest_commit_at = newest_nonmerge_commit_at_rest(repo["name"], pr["number"])
                newest_review_at = max(
                    (rv.get("submittedAt") or "" for rv in (pr.get("reviews") or {}).get("nodes") or []
                     if rv and rv.get("state") in ("APPROVED", "CHANGES_REQUESTED")),
                    default="")
                # ADR-093 edge-trigger: this PR is REVIEWABLE now — green, unapproved, armed, not a
                # draft, not broken/mechanical — so POST it to the review Sensor. Same predicate as
                # review-reflex.sh (armed ∧ green ∧ (review_required ∨ reviewable_again), minus
                # automerge/agent-error).
                maybe_dispatch_review(
                    repo["name"], pr["number"], pr.get("headRefOid") or "",
                    ci_state=ci_state,
                    review_decision=(pr["reviewDecision"] or "none").lower(),
                    armed=pr.get("autoMergeRequest") is not None,
                    draft=bool(pr["isDraft"]),
                    labels=label_names,
                    newest_commit_at=newest_commit_at,
                    newest_review_at=newest_review_at,
                    bot_approved_at=bot_approved_at,
                )
                # Trailing-1h window, NOT reviews-since-head-commit: the commit OBJECT is
                # forbidden to this PAT (needs Contents:read — found live 2026-07-12, the whole
                # commits node nulls regardless of which sub-fields are selected), and a dispatch
                # loop is time-clustered anyway. ISO-8601 UTC strings compare correctly as
                # strings; the series disappears when the PR goes quiet, so the alert
                # self-resolves without any staleness handling.
                cutoff = (datetime.now(timezone.utc) - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
                verdicts = {}
                for rv in (pr.get("reviews") or {}).get("nodes") or []:
                    if not rv or rv.get("state") not in ("APPROVED", "CHANGES_REQUESTED"):
                        continue
                    if (rv.get("submittedAt") or "") > cutoff:
                        login = (rv.get("author") or {}).get("login") or "unknown"
                        verdicts[login] = verdicts.get(login, 0) + 1
                for login, count in verdicts.items():
                    lines.append(metric("github_pull_request_reviews_recent", {**ident, "author": login}, count))
        if not repos["pageInfo"]["hasNextPage"]:
            return
        cursor = repos["pageInfo"]["endCursor"]



def collect_agent_issues(lines):
    """FU-091 queue-liveness: per-repo counts of the agent state labels, so "queued work + idle
    loop" is a Prometheus fact instead of tick-log prose (the 2026-07-18→21 three-day stall: a
    zombie pod wedged WIP while every scan reported it into unread logs — nothing paged). One
    REST search per label per poll (4 calls; the Search API's 30/min ceiling is untouched at the
    120s cadence)."""
    lines += [
        "# TYPE github_agent_issue_labels gauge",
        "# HELP github_agent_issue_labels Open issues per repo carrying each agent state label.",
    ]
    from urllib.parse import quote
    for label in ("agent/queued", "agent/in-progress", "agent/blocked", "agent/error"):
        data = gh(f"/search/issues?q=org:{ORG}+label:%22{quote(label)}%22+state:open+type:issue&per_page=100")
        counts = {}
        for item in data.get("items") or []:
            repo = (item.get("repository_url") or "").rsplit("/", 1)[-1]
            if repo:
                counts[repo] = counts.get(repo, 0) + 1
        for repo, n in sorted(counts.items()):
            lines.append(metric("github_agent_issue_labels", {"owner": ORG, "repo": repo, "label": label}, n))


def collect_billing(lines):
    now = datetime.now(timezone.utc)
    usage = gh(f"/organizations/{ORG}/settings/billing/usage?year={now.year}&month={now.month}")
    agg = {}
    for item in usage.get("usageItems", []):
        key = (item["product"], item["sku"], item["unitType"], item.get("repositoryName") or "")
        sums = agg.setdefault(key, [0.0, 0.0, 0.0, 0.0])
        sums[0] += item.get("quantity", 0)
        sums[1] += item.get("grossAmount", 0)
        sums[2] += item.get("discountAmount", 0)
        sums[3] += item.get("netAmount", 0)
    lines += [
        "# TYPE github_billing_usage gauge",
        "# HELP github_billing_usage Month-to-date usage quantity (unit label) per product/sku/repo.",
        "# TYPE github_billing_gross_amount gauge",
        "# TYPE github_billing_discount_amount gauge",
        "# TYPE github_billing_net_amount gauge",
        "# HELP github_billing_net_amount Month-to-date USD after discounts (>0 = actually paying).",
    ]
    for (product, sku, unit, repo), (qty, gross, discount, net) in sorted(agg.items()):
        vis = "unknown" if repo not in _repo_private else ("private" if _repo_private[repo] else "public")
        labels = {"org": ORG, "product": product, "sku": sku, "unit": unit, "repo": repo,
                  "visibility": vis}
        lines.append(metric("github_billing_usage", labels, round(qty, 6)))
        lines.append(metric("github_billing_gross_amount", labels, round(gross, 6)))
        lines.append(metric("github_billing_discount_amount", labels, round(discount, 6)))
        lines.append(metric("github_billing_net_amount", labels, round(net, 6)))


def poll_forever():
    global _body, _errors, _last_success
    while True:
        lines = []
        ok = True
        for collector in (collect_workflow_runs, collect_open_prs, collect_agent_issues, collect_billing):
            try:
                collector(lines)
            except Exception as exc:  # keep the other collector alive; alert rides the metrics below
                ok = False
                _errors += 1
                print(f"{collector.__name__} failed: {exc}", flush=True)
        if ok:
            _last_success = int(time.time())
        lines += [
            "# TYPE github_exporter_errors_total counter",
            f"github_exporter_errors_total {_errors}",
            "# TYPE github_exporter_last_success_timestamp gauge",
            "# HELP github_exporter_last_success_timestamp Epoch of the last fully successful poll (stale ⇒ token expired/revoked or API down).",
            f"github_exporter_last_success_timestamp {_last_success}",
        ]
        with _lock:
            _body = "\n".join(lines) + "\n"
        time.sleep(INTERVAL)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/metrics", "/healthz", "/"):
            self.send_error(404)
            return
        with _lock:
            body = _body.encode()
        if self.path == "/healthz":
            body = b"ok\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    threading.Thread(target=poll_forever, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", 9504), Handler).serve_forever()
