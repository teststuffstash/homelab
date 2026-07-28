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
# FU-115 red edge-trigger: the /coordinate doorbell (same agent-loop EventSource) — POST it when an
# armed agent PR goes CI-RED so the coordinate scan's ci-red clause fires near-instant instead of
# only on the */10 poll (the symmetric twin of REVIEW_WEBHOOK_URL for the RED half of the FSM).
COORDINATE_WEBHOOK_URL = os.environ.get("COORDINATE_WEBHOOK_URL", "").strip()
# The reviewer App's login (GraphQL bare; REST appends "[bot]" — stripped where compared). Feeds
# the bot_approved_head arm of the review edge-trigger, mirroring review-reflex.sh's $bot.
REVIEWER_BOT = os.environ.get("REVIEWER_BOT", "homelab-reviewer").strip()
# FU-100 per-stack review edge routing: repo → loop_ns for GRADUATED stacks, read from
# agents/stacks.json (the committed mirror — fetched raw from the public repo, the same source
# the shell emitters read from their homelab clone; this pod has no clone, and the raw fetch is
# rate-limit-free). A graduated repo's POST carries {stack, loop_ns} so the review Sensor's
# per-stack trigger inlines the review INTO <loop_ns>; a failed/absent lookup fails SOFT to a
# plain {repo} POST = the global trigger, which DEFERS graduated repos to their */15 cron
# (latency, never a wrong review). Empty STACKS_URL disables the routing entirely.
STACKS_URL = os.environ.get(
    "STACKS_URL",
    "https://raw.githubusercontent.com/teststuffstash/homelab/master/agents/stacks.json",
).strip()
STACKS_TTL = int(os.environ.get("STACKS_TTL_SECONDS", "600"))
_stacks_cache = {"at": None, "map": {}}  # repo → {"stack": ..., "loop_ns": "<stack>-agents"}
# FU-084: dir of per-installation probe tokens (one file per token identity; rl-tokens.yaml).
RL_TOKEN_DIR = os.environ.get("RL_TOKEN_DIR", "/var/run/rl-tokens")
# FU-098: dir of App PRIVATE KEYS for the permission-drift belt (one subdir per declared slug,
# file `privateKey` — deployment.yaml mounts the rl-* App-key Secrets it already holds). The
# declared state rides the script ConfigMap as github-apps.json (GENERATED from
# docs/github-apps.yaml; github-apps-lint keeps them in sync).
APP_KEYS_DIR = os.environ.get("APP_KEYS_DIR", "/var/run/app-keys")
APPS_DECLARED = os.environ.get("APPS_DECLARED", "/app/github-apps.json")

_lock = threading.Lock()
_body = "# poller has not completed a cycle yet\n"
_errors = 0
_last_success = 0
_review_dispatched = set()  # (repo, number, head_sha) already POSTed this process lifetime
_cired_dispatched = set()   # (repo, number, head_sha) already red-doorbelled this lifetime (FU-115)


def gh(path, token=None):
    req = urllib.request.Request(
        API + path,
        headers={
            "Authorization": f"Bearer {token or TOKEN}",
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


def graduated_loop_ns(repo):
    """repo → {"stack", "loop_ns"} when it belongs to a GRADUATED stack, else None (FU-100).
    stacks.json is cached STACKS_TTL seconds; a failed refresh keeps the last-good map and
    retries next TTL (stale beats absent — graduation flips are rare, and the */15 per-stack
    cron backstops any routing miss). Poll-loop-only caller, so no lock needed."""
    if not STACKS_URL:
        return None
    now = time.monotonic()
    if _stacks_cache["at"] is None or now - _stacks_cache["at"] >= STACKS_TTL:
        _stacks_cache["at"] = now  # even on failure — never hammer the fetch inside one TTL
        try:
            req = urllib.request.Request(
                STACKS_URL, headers={"User-Agent": "homelab-github-exporter"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.load(resp)
            _stacks_cache["map"] = {
                r: {"stack": s["name"], "loop_ns": f"{s['name']}-agents"}
                for s in data.get("stacks", [])
                if s.get("graduated")
                for r in s.get("repos", [])
            }
        except Exception as exc:
            print(f"stacks.json refresh FAILED (per-stack review routing degraded to the "
                  f"global path): {exc}", flush=True)
    return _stacks_cache["map"].get(repo)


def maybe_dispatch_cired(repo, number, head_sha, *, ci_state, armed, draft, labels):
    """FU-115 red edge-trigger (MP-T12): POST a /coordinate doorbell when an ARMED agent PR is
    CI-RED, so the coordinate scan's ci-red clause dispatches a fix round near-instant instead of
    only on the */10 poll — the symmetric twin of the green review edge. Deduped per
    (repo, number, head_sha): ONE wake per red commit. A no-op fix round pushes NO commit → same
    head_sha → no re-wake (the content-basis the old 4h `updatedAt` timer lacked, which reset on the
    no-op's own comment). The scan owns the attempt cap → agent/arbitrate; this only decides WHEN to
    look. Label exclusions mirror the ci-red scan predicate. Best-effort — the */10 cron is the
    backstop; a restart re-POSTs a still-red head, which the scan's attempt-count dedups anyway."""
    if not COORDINATE_WEBHOOK_URL:
        return
    red = (
        ci_state == "failure"
        and armed
        and not draft
        and not ({"agent/error", "agent/arbitrate", "major", "major/awaiting-human", "automerge"}
                 & set(labels))
    )
    if not red or not head_sha:
        return
    key = (repo, str(number), head_sha)
    if key in _cired_dispatched:
        return
    payload = {"repo": repo, "number": str(number), "head_sha": head_sha}
    grad = graduated_loop_ns(repo)   # graduated stack → {stack, loop_ns} so it routes to the per-stack coordinate
    if grad:
        payload.update(grad)
    body = json.dumps(payload).encode()
    try:
        req = urllib.request.Request(
            COORDINATE_WEBHOOK_URL, data=body,
            headers={"Content-Type": "application/json"}, method="POST",
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp.read()
        _cired_dispatched.add(key)
        print(f"cired-edge: POST /coordinate for {repo}#{number} @ {head_sha[:8]} (CI red)", flush=True)
    except Exception as e:
        print(f"cired-edge: POST failed for {repo}#{number}: {e}", flush=True)


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
    payload = {"repo": repo, "number": str(number), "head_sha": head_sha}
    # FU-100: a graduated repo's event carries {stack, loop_ns} so the review Sensor's per-stack
    # trigger routes it INTO <loop_ns>; plain payloads take the global trigger alone (which
    # defers graduated repos to their */15 cron — the belt when this lookup degrades).
    grad = graduated_loop_ns(repo)
    if grad:
        payload.update(grad)
    body = json.dumps(payload).encode()
    try:
        req = urllib.request.Request(
            REVIEW_WEBHOOK_URL, data=body,
            headers={"Content-Type": "application/json"}, method="POST",
        )
        with urllib.request.urlopen(req, timeout=10):
            pass
        _review_dispatched.add(key)
        print(f"review dispatch: {repo}#{number} @{head_sha[:8]} → webhook"
              f"{' (loop_ns ' + grad['loop_ns'] + ')' if grad else ''}", flush=True)
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
                # FU-115 red edge-trigger: the symmetric RED half — POST /coordinate when this armed
                # agent PR is CI-red, so the coordinate scan's ci-red clause fires now instead of on
                # the */10 poll (the green loop got its edge in ADR-093; the red loop lacked one).
                maybe_dispatch_cired(
                    repo["name"], pr["number"], pr.get("headRefOid") or "",
                    ci_state=ci_state,
                    armed=pr.get("autoMergeRequest") is not None,
                    draft=bool(pr["isDraft"]),
                    labels=label_names,
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


def _app_jwt(app_id, key_path):
    """RS256 App JWT via the openssl BINARY (python:slim has no crypto lib; openssl ships in the
    image). 5-min expiry — minted per poll, never stored."""
    import base64
    import subprocess

    def b64(b):
        return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

    now = int(time.time())
    header = b64(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    payload = b64(json.dumps({"iat": now - 60, "exp": now + 300, "iss": str(app_id)}).encode())
    signing = f"{header}.{payload}".encode()
    sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                         input=signing, stdout=subprocess.PIPE, check=True).stdout
    return f"{header}.{payload}.{b64(sig)}"


_apps_md = "# GitHub Apps — no poll completed yet\n"
_apps_html = "<!doctype html><title>GitHub Apps</title><p>no poll completed yet</p>\n"


def _md_to_html(md):
    """Tiny converter for exactly the shape _render_apps_view emits (h1/h2, pipe tables,
    paragraphs) — python:slim has no markdown lib and this page needs no more. Drift rows
    (⚠) get a highlight class."""
    import html as _h
    out = ["<!doctype html><html><head><meta charset='utf-8'><title>GitHub Apps — declared vs live</title><style>",
           "body{font-family:system-ui,sans-serif;max-width:60rem;margin:2rem auto;padding:0 1rem;line-height:1.5;background:#fff;color:#1a1a1a}",
           "@media(prefers-color-scheme:dark){body{background:#111;color:#ddd}th{background:#222}td,th{border-color:#333}}",
           "table{border-collapse:collapse;margin:.5rem 0 1.5rem}td,th{border:1px solid #ccc;padding:.3rem .6rem;text-align:left}",
           "th{background:#f3f3f3}tr.drift td{background:rgba(255,160,0,.18)}h2{margin-top:2rem;border-bottom:1px solid #8884;padding-bottom:.2rem}",
           "code{font-family:ui-monospace,monospace}</style></head><body>"]
    in_table, past_header = False, False
    for line in md.splitlines():
        if line.startswith("|"):
            cells = [c.strip() for c in line.strip("|").split("|")]
            if all(set(c) <= {"-"} for c in cells):
                past_header = True
                continue
            if not in_table:
                out.append("<table>")
                in_table, past_header = True, False
            tag = "td" if past_header else "th"
            cls = " class='drift'" if "⚠" in line else ""
            out.append(f"<tr{cls}>" + "".join(f"<{tag}>{_h.escape(c)}</{tag}>" for c in cells) + "</tr>")
            continue
        if in_table:
            out.append("</table>")
            in_table = False
        if line.startswith("## "):
            out.append(f"<h2><code>{_h.escape(line[3:])}</code></h2>")
        elif line.startswith("# "):
            out.append(f"<h1>{_h.escape(line[2:])}</h1>")
        elif line.strip():
            out.append(f"<p>{_h.escape(line)}</p>")
    if in_table:
        out.append("</table>")
    out.append("</body></html>")
    return "\n".join(out)


def _render_apps_view(declared, live_by_slug, installs_by_id, repos_by_slug):
    """FU-098 finale: the human-readable Apps page, SERVED (GET /apps) instead of committed —
    a generated doc in the repo needed either a CI auto-commit (a GITHUB_TOKEN push triggers no
    workflows → the PR head loses its required ci check) or manual regeneration; here it simply
    cannot go stale. Declared source stays docs/github-apps.yaml (readable, whys inline)."""
    out = ["# GitHub Apps — declared vs live",
           "",
           "Declared source: homelab docs/github-apps.yaml (change flow: PR it first; the",
           "GithubAppPermissionDrift alert rings until the grant lands). Rendered per poll by",
           "github-exporter — never committed, cannot go stale.", ""]
    for app in declared:
        slug = app.get("slug", "")
        out.append(f"## {slug}")
        out.append(str(app.get("purpose", "")).strip())
        inst = installs_by_id.get(str(app.get("app_id") or ""), {})
        sel = inst.get("repository_selection") or app.get("installs", "?")
        repos = repos_by_slug.get(slug)
        out.append(f"installs: {sel}" + (f" → {', '.join(repos)}" if repos else ""))
        live = live_by_slug.get(slug)
        out.append("")
        out.append("| permission | declared | live |")
        out.append("|---|---|---|")
        want = {k.replace("org:", "organization_"): v["level"]
                for k, v in (app.get("permissions") or {}).items()}
        seen = set()
        for perm, lvl in sorted(want.items()):
            lv = (live or {}).get(perm, "absent" if live is not None else "?")
            mark = "" if (live is None or lv == lvl) else " ⚠"
            out.append(f"| {perm} | {lvl} | {lv}{mark} |")
            seen.add(perm)
        for perm, why in (app.get("absent") or {}).items():
            lv = (live or {}).get(perm, "absent" if live is not None else "?")
            mark = "" if (live is None or lv == "absent") else " ⚠ (decided absent)"
            out.append(f"| {perm} | absent (decided) | {lv}{mark} |")
            seen.add(perm)
        for perm, lv in sorted((live or {}).items()):
            if perm not in seen and perm != "metadata":
                out.append(f"| {perm} | UNDECLARED | {lv} ⚠ |")
        out.append("")
    return "\n".join(out) + "\n"


def collect_app_permission_drift(lines):
    """FU-098: live App permissions (`GET /app`, App JWT — the API can READ but never WRITE
    permissions) vs the declared state (github-apps.json). Drift in EITHER direction is a
    mismatch: a missing declared grant blocks a consumer (the fleet#134 422 class); an
    undeclared live grant is unreviewed blast radius. Coverage = declared apps whose key is
    mounted under APP_KEYS_DIR; the change flow is: PR docs/github-apps.yaml FIRST, the alert
    rings until the operator's UI click (+ install approval) lands, then clears."""
    try:
        declared = json.load(open(APPS_DECLARED)).get("apps", [])
    except Exception as exc:
        print(f"app-permission-drift: declared file unreadable: {exc}", flush=True)
        return
    lines.append("# TYPE github_app_permission_drift gauge")
    lines.append("# HELP github_app_permission_drift 1 = the App's LIVE permissions differ from docs/github-apps.yaml (either direction); the per-permission detail rides github_app_permission_mismatch.")
    lines.append("# TYPE github_app_permission_mismatch gauge")
    live_by_slug, repos_by_slug = {}, {}
    for app in declared:
        slug = app.get("slug", "")
        key_path = os.path.join(APP_KEYS_DIR, slug, "privateKey")
        if not (slug and app.get("app_id") and os.path.exists(key_path)):
            continue  # no key mounted → this App rides the offline verify leg only
        jwt = _app_jwt(app["app_id"], key_path)
        req = urllib.request.Request("https://api.github.com/app", headers={
            "Authorization": f"Bearer {jwt}", "Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            live = (json.load(resp).get("permissions") or {})
        live_by_slug[slug] = live
        want = {k.replace("org:", "organization_"): v["level"]
                for k, v in (app.get("permissions") or {}).items()}
        mismatches = []
        for perm, level in want.items():
            if live.get(perm) != level:
                mismatches.append((perm, level, live.get(perm, "absent")))
        for perm, level in live.items():
            if perm not in want and perm != "metadata":
                mismatches.append((perm, "absent", level))
        lines.append(f'github_app_permission_drift{{app="{esc(slug)}"}} {1 if mismatches else 0}')
        for perm, decl, liv in mismatches:
            lines.append(
                f'github_app_permission_mismatch{{app="{esc(slug)}",permission="{esc(perm)}",'
                f'declared="{esc(decl)}",live="{esc(liv)}"}} 1')
        # /apps view: enumerate this keyed App's installed repos (the token-list guard in
        # git-token.yaml/reviewer-git.yaml — "verify the App covers each repo BEFORE adding").
        try:
            tok_req = urllib.request.Request(
                f"https://api.github.com/app/installations/{app['install_id']}/access_tokens",
                data=b"{}", method="POST",
                headers={"Authorization": f"Bearer {jwt}", "Accept": "application/vnd.github+json"})
            with urllib.request.urlopen(tok_req, timeout=15) as resp:
                itok = json.load(resp).get("token", "")
            if itok:
                rr = urllib.request.Request(
                    "https://api.github.com/installation/repositories?per_page=100",
                    headers={"Authorization": f"Bearer {itok}", "Accept": "application/vnd.github+json"})
                with urllib.request.urlopen(rr, timeout=15) as resp:
                    repos_by_slug[slug] = sorted(
                        r["name"] for r in json.load(resp).get("repositories", []))
        except Exception as exc:  # noqa: BLE001 — the view degrades, the metrics never
            print(f"app-permission-drift: repo enumeration failed for {slug}: {exc}", flush=True)
    # org installations (the exporter PAT's Administration:read) — selection per app_id
    installs_by_id = {}
    try:
        for inst in gh(f"/orgs/{ORG}/installations?per_page=100").get("installations", []):
            installs_by_id[str(inst.get("app_id"))] = inst
    except Exception as exc:  # noqa: BLE001
        print(f"app-permission-drift: installations list unavailable: {exc}", flush=True)
    global _apps_md, _apps_html
    _apps_md = _render_apps_view(declared, live_by_slug, installs_by_id, repos_by_slug)
    _apps_html = _md_to_html(_apps_md)


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


def collect_rate_limits(lines):
    """FU-084: remaining/limit/reset per token per resource. Rate-limit pools are PER
    INSTALLATION (the 2026-07-17 incident drained coordinator-git's GraphQL pool to 9,
    invisible on any REST view) — probe tokens for each watched installation are ESO-minted
    into RL_TOKEN_DIR (rl-tokens.yaml, one file per token name); the exporter's own PAT is
    always included. `/rate_limit` itself never counts against a pool."""
    tokens = {"exporter-pat": TOKEN}
    for name in sorted(os.listdir(RL_TOKEN_DIR)) if os.path.isdir(RL_TOKEN_DIR) else []:
        p = os.path.join(RL_TOKEN_DIR, name)
        if os.path.isfile(p):
            tok = open(p).read().strip()
            if tok:
                tokens[name] = tok
    lines += [
        "# TYPE github_rate_limit_remaining gauge",
        "# HELP github_rate_limit_remaining Requests left in the pool (per token identity, per resource — graphql is the pool that drained 2026-07-17).",
        "# TYPE github_rate_limit_limit gauge",
        "# TYPE github_rate_limit_reset_timestamp gauge",
    ]
    for name, tok in tokens.items():
        try:
            res = gh("/rate_limit", token=tok).get("resources", {})
        except Exception as exc:  # one bad/expired token must not hide the others
            print(f"rate_limit probe {name} failed: {exc}", flush=True)
            continue
        for resource, r in res.items():
            labels = {"token": name, "resource": resource}
            lines.append(metric("github_rate_limit_remaining", labels, r.get("remaining", 0)))
            lines.append(metric("github_rate_limit_limit", labels, r.get("limit", 0)))
            lines.append(metric("github_rate_limit_reset_timestamp", labels, r.get("reset", 0)))


def poll_forever():
    global _body, _errors, _last_success
    while True:
        lines = []
        ok = True
        for collector in (collect_workflow_runs, collect_open_prs, collect_agent_issues, collect_billing,
                          collect_rate_limits, collect_app_permission_drift):
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
        if self.path not in ("/metrics", "/healthz", "/", "/apps", "/apps.md"):
            self.send_error(404)
            return
        with _lock:
            body = _body.encode()
        ctype = "text/plain; version=0.0.4; charset=utf-8"
        if self.path == "/healthz":
            body = b"ok\n"
        elif self.path == "/apps":
            # FU-098: the served (never committed) declared-vs-live Apps page — HTML for humans
            body = _apps_html.encode()
            ctype = "text/html; charset=utf-8"
        elif self.path == "/apps.md":
            body = _apps_md.encode()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    threading.Thread(target=poll_forever, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", 9504), Handler).serve_forever()
