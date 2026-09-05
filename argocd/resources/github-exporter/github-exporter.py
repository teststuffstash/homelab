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
Actions:read + Issues:read + Metadata:read + Pull requests:read, all repos —
scripts/github-exporter-pat-bootstrap.sh; Pull requests:read feeds collect_open_prs / the stall
detector (FU-063), Issues:read feeds collect_agent_issues / collect_issue_lifecycle), GITHUB_ORG,
POLL_INTERVAL_SECONDS (120), RUN_WINDOW_HOURS (24 — also bounds series cardinality: one series per run in window).
"""

import json
import os
import re
import sys
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


def _is_transient_http_error(exc):
    """True when an HTTP error is transient (5xx) and worth retrying within a poll window."""
    if isinstance(exc, urllib.error.HTTPError):
        return 500 <= exc.code < 600
    return False


def _urlopen_with_retry(req, timeout=30, max_retries=3, backoff_base=0.1):
    """Wrapper around urllib.request.urlopen that retries on transient 5xx errors.

    Retries up to `max_retries` times with exponential backoff (base^attempt seconds).
    Transient errors (502, 504, etc.) are retried; other errors propagate immediately."""
    for attempt in range(max_retries):
        try:
            return urllib.request.urlopen(req, timeout=timeout)
        except urllib.error.HTTPError as exc:
            if not _is_transient_http_error(exc):
                raise
            if attempt < max_retries - 1:
                wait = backoff_base * (2 ** attempt)
                print(f"HTTP {exc.code} (transient) on attempt {attempt + 1}/{max_retries}; "
                      f"retrying in {wait:.1f}s", flush=True)
                time.sleep(wait)
            else:
                raise
# Run→runner-class memo (completed runs never change; in-flight re-checked). The jobs endpoint is
# the only place runner labels live — one request per NEW run in the window, then cached.
_run_runner = {}
# Run→job-timing-lines memo (completed runs' job metrics cached per scrape; every poll re-emits
# the cached lines while the run is still in the window). Caches the computed exposition lines
# (with run_id label for disambiguation) and re-emits them every scrape so series stay visible.
_job_timings = {}
# Completed runs whose jobs have been fetched (delta-only API call: one per new completed run).
_jobs_fetched = set()
ORG = os.environ.get("GITHUB_ORG", "teststuffstash")
# Absent token = fatal, but raised in __main__ rather than at import, so `--self-test` (the CI
# gate for the goal walk, #209) can import this module without inventing a fake credential. The
# pod behaviour is unchanged: no token, no serving process.
TOKEN = os.environ.get("GITHUB_TOKEN", "").strip()
INTERVAL = int(os.environ.get("POLL_INTERVAL_SECONDS", "120"))
WINDOW_HOURS = int(os.environ.get("RUN_WINDOW_HOURS", "24"))
# ADR-102 goal registry (#209). The goal series ride the collect_open_prs GraphQL walk — two extra
# fields on the repo node, ZERO extra API calls (the FU-108 precedent; graphql is the pool that
# drained 2026-07-17, so a second walk or a per-goal query loop is not on the table).
# GOAL_ISSUE_WINDOW bounds the flat per-repo issue read the descendant walk runs over. Ordered
# UPDATED_AT DESC because a live goal's tree is by definition the recently-touched end of the
# list; a repo with more issues than this reports goal_tree_truncated=1 rather than quietly
# under-counting a tree whose older members fell out of the window.
GOAL_ISSUE_WINDOW = int(os.environ.get("GOAL_ISSUE_WINDOW", "100"))
GOAL_MAX = int(os.environ.get("GOAL_MAX_PER_REPO", "20"))
# Closed goals age out of the panel (ADR-102: the registry stays queryable via Prometheus
# retention, not via an ever-growing default view).
GOAL_CLOSED_MAX_AGE_DAYS = int(os.environ.get("GOAL_CLOSED_MAX_AGE_DAYS", "30"))
# ADR-093 review edge-trigger: POST reviewable PRs to the Argo Events webhook so a review Workflow
# fires without the review-reflex CronJob's */5 GraphQL poll (this poll already knows the reviewable
# set — reuse it, the one-poller doctrine). Empty = disabled (dispatch stays with the CronJob).
REVIEW_WEBHOOK_URL = os.environ.get("REVIEW_WEBHOOK_URL", "").strip()
# FU-115 red edge-trigger: the /coordinate doorbell (same agent-loop EventSource) — POST it when an
# armed agent PR goes CI-RED so the coordinate scan's ci-red clause fires near-instant instead of
# only on the */10 poll (the symmetric twin of REVIEW_WEBHOOK_URL for the RED half of the FSM).
COORDINATE_WEBHOOK_URL = os.environ.get("COORDINATE_WEBHOOK_URL", "").strip()
# homelab#650 head-changed edge: the same agent-loop EventSource, a NEW endpoint. With `ci` at
# ~1m post-minRunners, the iac-sentinel status's cron poll (*/5, interim */2) became the binding
# merge wait on every push — POSTing the new head lets the sentinel Sensor evaluate it near-
# instant instead of riding the tick out. Empty = disabled (dispatch stays with the cron).
SENTINEL_WEBHOOK_URL = os.environ.get("SENTINEL_WEBHOOK_URL", "").strip()
# ADR-111 updater edge (homelab#743): /update-pr doorbell when an armed, green PR goes BEHIND —
# the in-cluster updater (agents/update-pr-branch.sh via its Sensor, #742/#744) replaces the
# GitHub-hosted cron that burned ~4,800 hosted min/mo (#698). Empty = disabled; until the #744
# Sensor lands a POST connection-refuses, carried by the dispatcher's best-effort try/except —
# the same ride-ahead-of-its-Sensor contract the sentinel edge shipped under.
UPDATE_PR_WEBHOOK_URL = os.environ.get("UPDATE_PR_WEBHOOK_URL", "").strip()
# The tofu `protected_repos` four that actually carry the required `iac-sentinel` status check
# (repo_rulesets.tf, mirrored by scripts/iac-sentinel.sh's own SENTINEL_REPOS) — POSTing for a
# repo outside this set would wake a Sensor evaluation whose merge wait doesn't depend on it.
SENTINEL_REPOS = frozenset({"homelab", "sleep-iac", "oracle-iac", "circles-iac"})
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
# "map": GRADUATED repos only → {"stack", "loop_ns"} (the review/coordinate edge routing).
# "stack_of": EVERY repo → stack name, from the same one fetch — the goal series carry a `stack`
# label so the convergence tile is `sum by (stack) (…)` (#209) instead of a label_replace chain
# duplicating stacks.json inside dashboard JSON.
_stacks_cache = {"at": None, "map": {}, "stack_of": {}}
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
_dupes = 0  # duplicate sample lines collapsed by dedupe_exposition (#153) — 0 in a healthy poller
_graphql_partial_total = {}  # error class -> count: resource-limit, not-accessible, other
_carryover = {}  # collector.__name__ → its last successful lines, republished while a new cycle
                 # re-runs that collector (fixes the per-cycle no-data blinks on scrape); popped on
                 # failure so a failed walk still publishes NOTHING for its families (absent ≠ zero)
_first_successful_poll = True  # homelab#648: skip job timings backfill on first poll to avoid ~25m startup delay
_review_dispatched = set()  # (repo, number, head_sha) already POSTed this process lifetime
_cired_dispatched = set()   # (repo, number, head_sha, run_attempt) already red-doorbelled this lifetime (FU-115, homelab#1108)
_conflict_dispatched = set()  # (repo, number, head_sha) already conflict-doorbelled this lifetime (FU-144)
_sentinel_dispatched = set()  # (repo, number, head_sha) already sentinel-doorbelled this lifetime (homelab#650)
_behind_dispatched = set()    # (repo, number, head_sha) already updater-doorbelled this lifetime (ADR-111 #743)
_merged_rung = set()          # (repo, number) already merge-doorbelled this lifetime (ADR-106 (6))
_queued_prev = {}             # repo -> {dispatchable-queued issue numbers last poll} (#459: the appearance-edge's only memory)
_open_prs_prev = {}           # repo -> open PR numbers last poll; a vanished number is a merge candidate


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
    with _urlopen_with_retry(req, timeout=30) as resp:
        return json.loads(resp.read())


def _classify_graphql_error(error_msg):
    """Classify a GraphQL error message into one of three classes.

    Returns: 'resource-limit' | 'not-accessible' | 'other'
    """
    msg_lower = (error_msg or "").lower()
    if "resource limit" in msg_lower or "node limit" in msg_lower:
        return "resource-limit"
    if "not accessible" in msg_lower or "permission" in msg_lower or "forbidden" in msg_lower:
        return "not-accessible"
    return "other"


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
    with _urlopen_with_retry(req, timeout=30) as resp:
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
        error_class = _classify_graphql_error(errors[0].get("message", ""))
        global _graphql_partial_total
        _graphql_partial_total[error_class] = _graphql_partial_total.get(error_class, 0) + 1
        print("graphql: partial data (%d field error(s), class=%s, e.g. %s) — continuing"
              % (len(errors), error_class, errors[0].get("message", "")), flush=True)
    return data


def gh_paged(path, key):
    """Yield items across pages (path must already contain a query string), each `id` at most once.

    The dedup is load-bearing, not hygiene (#153). These endpoints page by OFFSET over a list they
    sort NEWEST-FIRST, and the list GROWS while we walk it: a workflow run created between two page
    fetches shifts every older item one slot down, so the item that was last on page N comes back as
    the first item of page N+1 and is yielded TWICE in one poll. With ~460 runs/24h in this org
    (5 pages) and runs starting constantly, that fired in bursts — the duplicated run's two series
    were appended twice, and when its `updated_at` advanced between the two fetches while its
    status/conclusion labels did not, the second append was the SAME series with a DIFFERENT value.
    Prometheus drops those ("different value but same timestamp", `num_dropped=2..6` in its log) and
    PrometheusDuplicateTimestamps fired. Deduping here fixes every caller at the source, including
    the per-item accumulation in collect_open_prs that a later exposition-level dedup cannot repair.

    The mirror image is not fixable with offset paging: an insertion can also push an item ACROSS a
    boundary we already passed, so it is missed this poll. Harmless here — the next poll (120s) sees
    it, and every series is re-emitted from scratch each poll anyway."""
    seen = set()
    for page in range(1, 20):  # hard cap: 20 pages ≈ 2000 items, far beyond this org
        batch = gh(f"{path}&per_page=100&page={page}")
        items = batch[key] if key else batch
        for item in items:
            ident = item.get("id") if isinstance(item, dict) else None
            if ident is not None:
                if ident in seen:
                    continue
                seen.add(ident)
            yield item
        if len(items) < 100:
            return


def epoch(iso):
    return int(datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp())


def esc(value):
    return str(value).replace("\\", r"\\").replace('"', r"\"").replace("\n", r"\n")


def metric(name, labels, value):
    # Labels are emitted SORTED so that one series has exactly one textual form regardless of which
    # call site built the dict — that is what lets dedupe_exposition() key on the rendered
    # `name{labels}` prefix and have it mean "the same series" the way Prometheus means it (#153).
    inner = ",".join(f'{k}="{esc(v)}"' for k, v in sorted(labels.items()))
    return f"{name}{{{inner}}} {value}"


def dedupe_exposition(lines, count=True):
    """Collapse repeated samples of the same series, LAST WRITE WINS — the structural belt (#153).

    A series appearing twice in one exposition is exactly what Prometheus reports as "error on
    ingesting samples with different value but same timestamp": it drops them and the scrape loses
    data silently. No collector may cause that, so this pass makes it unrepresentable rather than
    relying on every present and future collector to be careful. The duplicate found in #153 was
    offset-pagination re-yield (fixed at its source in gh_paged); this catches the class.

    Line order is preserved EXACTLY — a repeat overwrites the first occurrence's slot rather than
    appending — so the published body keeps the shape Prometheus already ingests here, header lines
    ahead of the samples they describe. (A rebuild that regrouped by family would be a bigger,
    unnecessary behaviour change: collect_workflow_runs has always interleaved its two families and
    the scrape parser, which reads line by line, has always accepted it.) Identical header lines
    collapse to one, since some text parsers reject a second `# HELP` for a name. Counts what it
    collapsed into `_dupes`, which rides the exposition as a counter: if a new duplication path ever
    appears, this fixes the metrics AND says so, instead of hiding it. `count=False` skips the
    counter — for the cross-cycle carryover merge, where same-series overlap is expected."""
    global _dupes
    out, at, meta = [], {}, set()
    for line in lines:
        if line.startswith("#"):
            if line not in meta:
                meta.add(line)
                out.append(line)
            continue
        series = line.rsplit(" ", 1)[0]  # values never contain a space; label values are esc()aped
        if series in at:
            out[at[series]] = line
            if count:
                _dupes += 1
            continue
        at[series] = len(out)
        out.append(line)
    return out


def collect_workflow_runs(lines):
    global _first_successful_poll
    since = (datetime.now(timezone.utc) - timedelta(hours=WINDOW_HOURS)).strftime("%Y-%m-%dT%H:%M:%SZ")
    all_repos = [r for r in gh_paged(f"/orgs/{ORG}/repos?type=all", None) if not r["archived"]]
    repos = [r["name"] for r in all_repos]
    _repo_private.update({r["name"]: bool(r.get("private")) for r in all_repos})
    if _first_successful_poll:
        print("First poll: skipping job timings backfill to keep startup under 2m (homelab#648)", flush=True)
    lines += [
        "# TYPE github_workflow_run_updated_timestamp gauge",
        "# HELP github_workflow_run_updated_timestamp Last update (epoch s) of each workflow run in the window; conclusion/status ride as labels.",
        "# TYPE github_workflow_run_duration_seconds gauge",
        "# TYPE github_workflow_run_queued_since_timestamp gauge",
        "# HELP github_workflow_run_queued_since_timestamp Creation epoch of a run still waiting for a runner (status=queued ONLY) — queued-age = time() - this. Absent once the run starts, so the alert self-resolves (FU-150).",
        "# TYPE github_ci_job_queue_seconds gauge",
        "# HELP github_ci_job_queue_seconds Job-level queue time (created_at to started_at) per (repo, workflow, job, runner_pool). Delta-only: one /jobs call per new completed run.",
        "# TYPE github_ci_job_duration_seconds gauge",
        "# HELP github_ci_job_duration_seconds Job-level execution time (started_at to completed_at) per (repo, workflow, job, runner_pool).",
        "# TYPE github_ci_runner_busy_jobs gauge",
        "# HELP github_ci_runner_busy_jobs In-progress CI jobs per runner pool at poll time (runs-on labels via the in-flight /jobs fetch). Capacity: proxmox-vm=2 slots (tofu/ci-runner.tf), arc maxRunners=4 (argocd/platform/arc-runners.yaml). arc/proxmox-vm always emit (0 is a reading); other pools only while busy.",
    ]
    _busy_pools.clear()
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
            lines += run_series(labels, run)
            if not _first_successful_poll:
                lines += collect_job_timings(repo, run)
    # Busy-slot gauge (ask-D instrument): counts accumulated by _runner_class over this cycle's
    # in-flight runs. Fixed-capacity pools emit 0 explicitly; collector failure keeps the family
    # absent (absent ≠ zero, same doctrine as every other family here).
    for pool in sorted(set(_BUSY_ALWAYS) | set(_busy_pools)):
        lines.append(metric("github_ci_runner_busy_jobs",
                            {"owner": ORG, "runner_pool": pool},
                            _busy_pools.get(pool, 0)))


def run_series(labels, run):
    """Every metric line for ONE workflow run — pure over the API object, so `--self-test` drives
    the queued-age arm against recorded runs instead of the network.

    The queued-age series (FU-150, the OURS half) exists because a run that cannot get a runner
    never FAILS: `GithubWorkflowRunFailed` needs a conclusion, so five hours of `queued` on
    2026-08-07 produced no alert at all, and on 2026-08-11 a node's route loss starved the same
    queue with the ARC listener alive and scaling (which is why the listener-zero signal FU-150
    originally proposed was dropped for this one — see the two incidents under docs/incidents/).
    It is a TIMESTAMP, not a precomputed age, so PromQL's `time() - x` stays correct between the
    120s polls instead of aging in 2-minute steps; and it is emitted only while the run is
    waiting, so the series simply disappears at pickup and the alert self-resolves — the same
    shape as github_pull_request_reviews_recent.

    `status` is matched EXACTLY against "queued" = waiting for a runner. The other pre-start
    statuses are deliberately excluded: `waiting`/`requested` are approval gates and `pending` is
    a concurrency group (docs/ci.md §Concurrency — homelab's own master runs queue serially by
    design). Those are policy waits, not "CI cannot dispatch", and alerting on them would ring on
    a healthy queue.

    Bounded by RUN_WINDOW_HOURS like every other run series: a run queued longer than the window
    (24h) falls out of the poll, its series disappears, and the alert RESOLVES while CI is still
    dead. Left that way deliberately — it will have been ringing for a day by then, and widening
    the window multiplies the cardinality of every run family to cover a case neither incident
    came near (the longest recorded wait is ~11h, 2026-08-06)."""
    updated = epoch(run["updated_at"])
    out = [metric("github_workflow_run_updated_timestamp", labels, updated)]
    started = run.get("run_started_at")
    if started:
        out.append(metric("github_workflow_run_duration_seconds", labels, updated - epoch(started)))
    if (run.get("status") or "") == "queued" and run.get("created_at"):
        # created_at, never run_started_at: GitHub sets run_started_at = created_at on every run
        # in this org (verified over 100 runs, 2026-08-11 — all deltas 0), so it says nothing
        # about pickup. The queue starts when the run is created.
        out.append(metric("github_workflow_run_queued_since_timestamp", labels,
                          epoch(run["created_at"])))
    return out


def _pool_of(labs):
    """Runner POOL from a job's runs-on label set — finer than _runner_class's hosted/self-hosted
    split: the pool is the capacity unit (the ask-D instrument, python golden-path proposal
    2026-09-02 — queue time and busy slots must split arc vs proxmox-vm before any ci-runner-02
    decision). Closed value set to keep cardinality fixed."""
    labs = [str(x).lower() for x in (labs or [])]
    if any("proxmox-vm" in x for x in labs):
        return "proxmox-vm"
    if any("homelab-ephemeral" in x for x in labs):
        return "arc"
    if any("self-hosted" in x or "homelab" in x for x in labs):
        return "self-hosted-other"
    if labs:
        return "hosted"
    return "unknown"


# Poll-scoped in-progress job counts per pool. Reset by collect_workflow_runs each cycle, filled
# as a side effect of _runner_class's in-flight /jobs fetches — zero additional API calls. Pools
# with fixed self-hosted capacity always emit (0 is a real reading); others only when busy. A
# failed per-run jobs probe undercounts rather than guesses (rule #6).
_busy_pools = {}
_BUSY_ALWAYS = ("arc", "proxmox-vm")


def _runner_class(repo, run):
    """hosted | self-hosted | mixed | unknown — from the run's job runner labels (the runs API
    itself carries nothing). Memoized for completed runs; a failed probe returns unknown rather
    than a guess (rule #6). Side effect: counts in-progress jobs into _busy_pools (the busy-slot
    gauge rides the same fetch)."""
    rid = run.get("id")
    done = (run.get("status") == "completed")
    if rid in _run_runner and done:
        return _run_runner[rid]
    try:
        jobs = gh(f"/repos/{ORG}/{repo}/actions/runs/{rid}/jobs?per_page=100").get("jobs") or []
        kinds = set()
        for j in jobs:
            labs = [str(x).lower() for x in (j.get("labels") or [])]
            if (j.get("status") or "") == "in_progress":
                pool = _pool_of(labs)
                _busy_pools[pool] = _busy_pools.get(pool, 0) + 1
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


def collect_job_timings(repo, run):
    """Emit job-level queue and duration metrics for a completed run (delta-only API call).

    Returns lines to be added to the exposition. Caches computed lines and re-emits them on every
    poll while the run is in the window, so job-level series stay visible across scrapes.
    One API call per new completed run, ~dozens/day. Job timings: queue_seconds (created_at to
    started_at) and duration_seconds (started_at to completed_at). Emits per (repo, workflow,
    job_name, run_id) to support load analysis across runs (run_id disambiguates multiple runs
    of the same workflow in the window)."""
    lines = []
    rid = run.get("id")
    done = (run.get("status") == "completed")
    if not rid or not done:
        return lines
    if rid in _job_timings:
        return _job_timings[rid]
    if rid in _jobs_fetched:
        return lines
    try:
        jobs = gh(f"/repos/{ORG}/{repo}/actions/runs/{rid}/jobs?per_page=100").get("jobs") or []
        for job in jobs:
            job_name = job.get("name") or ""
            created_at = job.get("created_at")
            started_at = job.get("started_at")
            completed_at = job.get("completed_at")
            if not (job_name and created_at and started_at and completed_at):
                continue
            labels = {
                "owner": ORG,
                "repo": repo,
                "workflow": run.get("name") or "",
                "job": job_name,
                "run_id": rid,
                "runner_pool": _pool_of(job.get("labels")),
            }
            queue_seconds = epoch(started_at) - epoch(created_at)
            duration_seconds = epoch(completed_at) - epoch(started_at)
            lines.append(metric("github_ci_job_queue_seconds", labels, queue_seconds))
            lines.append(metric("github_ci_job_duration_seconds", labels, duration_seconds))
        _job_timings[rid] = lines
        _jobs_fetched.add(rid)
    except Exception:
        pass  # failed to fetch jobs for this run; will retry if run re-appears in window
    return lines


def ci_state_from_runs(repo, sha):
    """CI state for a head SHA from workflow-run conclusions — the PRIVATE-repo path (FU-063a).

    Returns (state, max_run_attempt) — the second element is the highest run_attempt across
    all latest-per-(workflow,event) runs, used by the ci-red edge dedup (homelab#1108) so a
    rerun (same head_sha, new attempt) re-rings the doorbell.

    statusCheckRollup aggregates CHECK RUNS, and no fine-grained-PAT scope can read those on a
    private repo (`checks:read` is App-only; GitHub Actions reports check runs, never commit
    statuses — verified 2026-07-16). `/actions/runs?head_sha=` rides the PAT's existing
    Actions:read instead. Approximates the rollup: latest attempt per (workflow, event);
    anything unfinished → pending, any failure-ish conclusion → failure, all green-ish (≥1) →
    success, no runs → none (also the value for non-Actions CI, same degradation as before)."""
    if not sha:
        return ("none", 0)  # empty head_sha= would return ALL runs, not none
    runs = gh(f"/repos/{ORG}/{repo}/actions/runs?head_sha={sha}&per_page=100").get("workflow_runs") or []
    latest = {}
    max_attempt = 0
    for run in runs:
        key = (run.get("workflow_id"), run.get("event"))
        rank = (run.get("run_number") or 0, run.get("run_attempt") or 0)
        if key not in latest or rank > latest[key][0]:
            latest[key] = (rank, run)
        max_attempt = max(max_attempt, run.get("run_attempt") or 0)
    if not latest:
        return ("none", max_attempt)
    conclusions = []
    for _, run in latest.values():
        if run.get("status") != "completed":
            return ("pending", max_attempt)
        conclusions.append(run.get("conclusion") or "")
    if any(c in ("failure", "timed_out", "startup_failure", "cancelled", "action_required") for c in conclusions):
        return ("failure", max_attempt)
    if all(c in ("success", "neutral", "skipped") for c in conclusions):
        return ("success", max_attempt)
    return ("error", max_attempt)  # stale / unknown mixtures — visible rather than falsely green


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
            _stacks_cache["stack_of"] = {
                r: s["name"] for s in data.get("stacks", []) for r in s.get("repos", [])
            }
        except Exception as exc:
            print(f"stacks.json refresh FAILED (per-stack review routing degraded to the "
                  f"global path): {exc}", flush=True)
    return _stacks_cache["map"].get(repo)


def stack_of(repo):
    """repo → stack name for ANY stack in stacks.json, graduated or not ("unknown" if absent).

    Rides graduated_loop_ns' TTL-cached fetch — one stacks.json read serves both. "unknown" is
    deliberate: a repo the mirror doesn't know is honestly unattributed rather than silently
    folded into some other stack's convergence number."""
    graduated_loop_ns(repo)  # refreshes both maps under the shared TTL
    return _stacks_cache["stack_of"].get(repo, "unknown")


def maybe_dispatch_cired(repo, number, head_sha, *, ci_state, armed, draft, labels, run_attempt=0):
    """FU-115 red edge-trigger (MP-T12): POST a /coordinate doorbell when an ARMED agent PR is
    CI-RED, so the coordinate scan's ci-red clause dispatches a fix round near-instant instead of
    only on the */10 poll — the symmetric twin of the green review edge. Deduped per
    (repo, number, head_sha, run_attempt): ONE wake per red (commit, attempt). A rerun (same
    head_sha, new run_attempt) re-rings the doorbell (homelab#1108). A no-op fix round pushes NO
    commit → same head_sha → no re-wake unless CI is re-run (the content-basis the old 4h
    `updatedAt` timer lacked, which reset on the no-op's own comment). The scan owns the attempt
    cap → agent/arbitrate; this only decides WHEN to look. Label exclusions mirror the ci-red scan
    predicate. Best-effort — the */10 cron is the backstop; a restart re-POSTs a still-red head,
    which the scan's attempt-count dedups anyway."""
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
    key = (repo, str(number), head_sha, run_attempt)
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
        print(f"cired-edge: POST /coordinate for {repo}#{number} @ {head_sha[:8]} (CI red, attempt {run_attempt})", flush=True)
    except Exception as e:
        print(f"cired-edge: POST failed for {repo}#{number}: {e}", flush=True)


def maybe_dispatch_conflict(repo, number, head_sha, *, review_decision, labels):
    """FU-144 conflict edge-trigger: POST a /coordinate doorbell when an open agent PR carries
    `merge-conflict`, so the scan's merge-conflict clause dispatches a resolution round instead of
    waiting out the */30 cron (PR#275 did exactly that on 2026-08-11).

    The row for this transition in docs/agents/workflow.md §Triggers promised an "exporter
    piggyback" from the day the table was written and it was never built — the label was already
    in this poll's `label_names`, but nothing read it. So this is the missing emitter, not a
    payload edit; every other in-repo emitter already carries {stack, loop_ns}.

    `update-pr-branch` is the actor that applies the label and it is GitHub-hosted BY DESIGN (the
    merge path must not depend on the self-hosted tier being awake), so it cannot curl the
    in-cluster webhook itself — the piggyback is the belt for exactly that off-cluster class.
    Latency becomes ≤ one poll (120 s) instead of ≤30 min.

    Predicate mirrors the scan's merge-conflict clause (coordinator-scan.sh, the `merge-conflict`
    unit loop) label for label: the label present, `agent/error`/`agent/arbitrate` absent (the
    human-first breaker and the arbitration park), and reviewDecision ≠ CHANGES_REQUESTED (that PR
    belongs to the changes-requested clause, which resolves the conflict as part of its round).
    Deliberately NOT filtered on armed/draft, because the scan's clause is not either — the
    doorbell may over-approximate (a false wake costs a scan, never an LLM tick) but a wake the
    scan then ignores as out-of-predicate is pure waste.

    Deduped per (repo, number, head_sha) like the red edge: one wake per conflicted head, so a
    resolution round that pushes nothing cannot re-wake itself, while a genuine new head that is
    STILL conflicted rings again. Best-effort — the */30 cron stays the backstop; a pod restart
    re-POSTs a still-conflicted head, which the scan's own predicate re-judges anyway."""
    if not COORDINATE_WEBHOOK_URL:
        return
    conflicted = (
        "merge-conflict" in labels
        and not ({"agent/error", "agent/arbitrate"} & set(labels))
        and review_decision != "changes_requested"
    )
    if not conflicted or not head_sha:
        return
    key = (repo, str(number), head_sha)
    if key in _conflict_dispatched:
        return
    payload = {"repo": repo, "number": str(number), "head_sha": head_sha}
    # FU-144: a graduated stack's POST carries {stack, loop_ns} so the coordinator Sensor's
    # per-stack trigger scans INSIDE <loop_ns> — a plain {repo} POST takes the global trigger,
    # which SKIPS graduated stacks entirely and would leave the wake doing nothing at all (the
    # `coordinate-now` sting, workflow.md §Triggers ⚠). A failed/absent lookup fails SOFT to the
    # plain payload = today's behaviour, i.e. the cron backstop.
    grad = graduated_loop_ns(repo)
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
        _conflict_dispatched.add(key)
        print(f"conflict-edge: POST /coordinate for {repo}#{number} @ {head_sha[:8]}"
              f"{' (loop_ns ' + grad['loop_ns'] + ')' if grad else ''}", flush=True)
    except Exception as e:
        print(f"conflict-edge: POST failed for {repo}#{number}: {e}", flush=True)


def maybe_dispatch_sentinel(repo, number, head_sha):
    """homelab#650 head-changed edge: POST /sentinel — a new endpoint on the same agent-loop
    EventSource the other dispatchers piggyback on — so the iac-sentinel WorkflowTemplate
    evaluates a NEW head near-instant instead of riding out the cron tick. With `ci` down to ~1m
    post-minRunners, that tick (*/5, interim */2 operator-direct 2026-08-19) became the BINDING
    merge wait on every push in a sentinel-covered repo — the exact "a status the cron services
    is a defect with an id" case (workflow.md §Triggers, ALL EVENTS HAVE DOORBELLS).

    Scoped to SENTINEL_REPOS — the tofu `protected_repos` four that actually carry the required
    `iac-sentinel` status check — so a repo whose merge wait doesn't depend on the check never
    wakes the Sensor. Repo-dumb WITHIN that set per the issue's own payload shape: no
    {stack, loop_ns} lookup, because the sentinel Sensor scores one head directly rather than
    routing into an agent loop namespace the way /coordinate and /review do.

    Deduped per (repo, number, head_sha), the same shape as the conflict/red edges: the key
    ALREADY encodes the head, so a genuinely new head is unconditionally a new key and rings —
    including a brand-new PR's first observed head (nothing to diff against, and the issue's own
    worked example: the sentinel status is what that PR's merge wait blocks on, so under-ringing
    here strands the PR, not just adds noise). A false/duplicate wake costs one ~20s evaluation —
    over-approximation is explicitly fine (the issue's own acceptance framing); best-effort, same
    contract as every sibling dispatcher — a POST failure never disturbs the metrics poll, and the
    cron backstop (dropping back to */15 once this edge is proven) owns the miss."""
    if not SENTINEL_WEBHOOK_URL or repo not in SENTINEL_REPOS or not head_sha:
        return
    key = (repo, str(number), head_sha)
    if key in _sentinel_dispatched:
        return
    payload = {"repo": repo, "pr": number, "head": head_sha}
    body = json.dumps(payload).encode()
    try:
        req = urllib.request.Request(
            SENTINEL_WEBHOOK_URL, data=body,
            headers={"Content-Type": "application/json"}, method="POST",
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp.read()
        _sentinel_dispatched.add(key)
        print(f"sentinel-edge: POST /sentinel for {repo}#{number} @ {head_sha[:8]}", flush=True)
    except Exception as e:
        print(f"sentinel-edge: POST failed for {repo}#{number}: {e}", flush=True)


def maybe_dispatch_behind(repo, number, head_sha, *, merge_state, ci_state, armed):
    """ADR-111 updater edge (homelab#743): POST /update-pr when an ARMED, green PR sits BEHIND
    master, so the in-cluster updater (agents/update-pr-branch.sh, #742) brings it current
    near-instantly — the edge whose GitHub-hosted predecessor effectively WAS its own cron
    (91–96% of runs, ~4,800 hosted min/mo, #698).

    Predicate: armed ∧ BEHIND ∧ green-or-checkless. Deliberately NARROWER than the updater's own
    main pick (which has NO green gate — the 2026-07-10 wedge lesson): the edge serves the common
    case, and a red-behind PR (a base-side CI fix landing) is the */15 cron backstop's within one
    tick. Checkless ("none") rings — over-approximation is explicitly fine, the updater re-derives
    the FULL predicate (incl. the CR∧BEHIND unstrand gate) with the App token before acting, so a
    false wake costs one pr-list read, never a bad update. NB the exporter PAT's null-commit-dates
    limitation (the reason the review edge stays off on private repos) does NOT bite here — this
    predicate reads no commit objects; the commit-reading unstrand gate runs in the updater
    itself under the App token.

    Payload is repo-dumb ({repo}, + number/head for the log): this doorbell wakes the CENTRAL
    updater in agent-coordinator, not a stack loop, so no {stack, loop_ns} lookup. Deduped per
    (repo, number, head_sha) — an update CHANGES the head (merge commit), so a PR that falls
    behind again re-rings on its new head, while a serviced-or-failed ring never repeats on the
    same head (the cron retries). Best-effort, sibling contract: a POST failure never disturbs
    the metrics poll."""
    if not UPDATE_PR_WEBHOOK_URL or not head_sha:
        return
    if not (armed and merge_state == "BEHIND" and ci_state in ("success", "none")):
        return
    key = (repo, str(number), head_sha)
    if key in _behind_dispatched:
        return
    payload = {"repo": repo, "number": str(number), "head_sha": head_sha}
    body = json.dumps(payload).encode()
    try:
        req = urllib.request.Request(
            UPDATE_PR_WEBHOOK_URL, data=body,
            headers={"Content-Type": "application/json"}, method="POST",
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp.read()
        _behind_dispatched.add(key)
        print(f"behind-edge: POST /update-pr for {repo}#{number} @ {head_sha[:8]}", flush=True)
    except Exception as e:
        print(f"behind-edge: POST failed for {repo}#{number}: {e}", flush=True)


def maybe_dispatch_merged(repo, vanished):
    """ADR-106 (6) merge doorbell: a MERGE previously woke nothing anywhere — reviewer rings at
    verdict, the ride at its own exit, but auto-merge completes minutes later and the
    merged-closeout/goal chain then waited out the cron (the v1.1 spike's finding 6 named the
    sibling platform repos, where this was the ONLY missing edge; the gap was in fact
    fleet-wide). The poll sees OPEN PRs, so the edge is a DISAPPEARANCE diff: a number gone from
    the repo's open set is read once via REST (`merged` is authoritative; closed-unmerged rings
    nothing and is remembered), and a merge POSTs /coordinate with the graduated pair so the
    stack's own loop takes it. In-memory prev-set: a pod restart forgets one window and misses
    merges during the outage — the cron backstop owns those, same best-effort contract as the
    sibling dispatchers; over-ringing is legal (a doorbell costs a scan, and the receiver-side
    collapse absorbs bursts). Returns the numbers it could NOT settle (failed read or failed
    POST) so the caller folds them back into the tracked set and they re-diff next poll —
    without that, one transient hiccup dropped the edge FOREVER (bot review, PR#396: the
    edge-triggered diff has no natural retry, unlike the level-triggered siblings)."""
    unresolved = set()
    if not COORDINATE_WEBHOOK_URL or not vanished:
        return unresolved
    for number in vanished:
        key = (repo, str(number))
        if key in _merged_rung:
            continue
        try:
            pr = gh(f"/repos/{ORG}/{repo}/pulls/{number}")
        except Exception as e:
            print(f"merge-edge: read failed for {repo}#{number}: {e} — retrying next poll", flush=True)
            unresolved.add(number)
            continue
        if not (pr or {}).get("merged"):
            _merged_rung.add(key)  # closed without merging: settled, never re-read
            continue
        payload = {"repo": repo, "number": str(number),
                   "merged_sha": (pr.get("merge_commit_sha") or "")}
        grad = graduated_loop_ns(repo)
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
            _merged_rung.add(key)
            print(f"merge-edge: POST /coordinate for merged {repo}#{number}"
                  f"{' (loop_ns ' + grad['loop_ns'] + ')' if grad else ''}", flush=True)
        except Exception as e:
            print(f"merge-edge: POST failed for {repo}#{number}: {e} — retrying next poll", flush=True)
            unresolved.add(number)
    return unresolved


def queued_dispatchable(labels):
    """The scan's queued-dispatch clause (coordinator-scan.sh, the `queued` derivation), label for
    label: agent-fix ∧ agent/queued ∧ ¬direction-change ∧ ¬agent/error. The doorbell mirrors it so
    a wake the scan then ignores as out-of-predicate is pure waste (#459) — the same doctrine
    maybe_dispatch_conflict documents for its clause."""
    return ("agent-fix" in labels and "agent/queued" in labels
            and "direction-change" not in labels and "agent/error" not in labels)


def maybe_dispatch_queued(repo, currently):
    """#459 label-transition doorbell: an issue newly carrying `agent-fix`+`agent/queued` is the
    ONE loop transition with no emitter. The ⚑ ALL EVENTS HAVE DOORBELLS table promised an
    "exporter piggyback" for "issue gains agent/queued" and never built one, so a human directly
    applying the labels (sleep-tracking#121; homelab#478/479/491) sat unrung until the */30
    per-stack cron backstop picked it up — the AgentDispatchCronWoken alert (the label is already
    in this poll's walk; nothing read it, the FU-144 row's exact shape).

    The edge is an APPEARANCE diff over `currently` — the dispatchable-queued issue numbers seen
    this poll (see queued_dispatchable). An issue newly present is the moment the scan CAN
    dispatch it: ring then. Staying queued does not re-ring (a scan dispatch applies
    agent/in-progress and the issue leaves the set); a genuine re-queue re-appears and rings
    again. Repo-dumb payload per the post-FU-144 emitter doctrine (workflow.md §Triggers ⚠
    block — new emitters prefer `{repo}` over learning stack mechanics): a plain {repo} POST
    wakes the global scan, whose receiver-side fan-out resolves repo → {stack, loop_ns} and
    re-rings the stack's own loop. The exporter's OLDER dispatchers predate that fan-out and
    carry the pair themselves; this one follows the current guidance.

    Failed POSTs stay OUT of the prev-set so they re-appear as new next poll — the appearance
    edge has no natural retry (the merged-edge lesson, bot review PR#396). A pod restart
    re-rings everything still queued, which is correct: those issues are genuinely still
    waiting. Best-effort — the */30 cron backstop owns misses (and a repo overflowing the
    GraphQL first:50 agent-issue window)."""
    unresolved = set()
    if not COORDINATE_WEBHOOK_URL or not currently:
        _queued_prev[repo] = currently
        return unresolved
    newly = currently - _queued_prev.get(repo, set())
    if newly:
        for number in sorted(newly):
            payload = {"repo": repo, "number": str(number)}
            body = json.dumps(payload).encode()
            try:
                req = urllib.request.Request(
                    COORDINATE_WEBHOOK_URL, data=body,
                    headers={"Content-Type": "application/json"}, method="POST",
                )
                with urllib.request.urlopen(req, timeout=30) as resp:
                    resp.read()
                print(f"queued-edge: POST /coordinate for {repo}#{number}", flush=True)
            except Exception as e:
                print(f"queued-edge: POST failed for {repo}#{number}: {e} — retrying next poll",
                      flush=True)
                unresolved.add(number)
    _queued_prev[repo] = currently - unresolved
    return unresolved


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


# ADR-102 goal registry (#209): the goal issues themselves (body carries the `Budget:` line) plus a
# FLAT per-repo issue list with native `parent` edges — the descendant walk is then a fixpoint in
# python, exactly as coordinator-scan.sh and the launcher's budget gate do it over their one fetch.
# Deliberately NOT nested subIssues: goals×depth×breadth blows past GraphQL's 500k node ceiling,
# while flat costs (repos × GOAL_ISSUE_WINDOW) nodes and answers the same question.
_GOAL_FIELDS = """
        goalIssues: issues(labels:["task/goal"], states:[OPEN,CLOSED], first:$goals,
                           orderBy:{field:UPDATED_AT, direction:DESC}) {
          nodes { number title state stateReason closedAt body
                  labels(first:20){ nodes { name } } }
        }
        issueTree: issues(states:[OPEN,CLOSED], first:$issues,
                          orderBy:{field:UPDATED_AT, direction:DESC}) {
          pageInfo { hasNextPage }
          nodes { number state createdAt closedAt parent { number } }
        }
"""

_PR_QUERY = """
query($org:String!, $cursor:String, $goals:Int!, $issues:Int!) {
  organization(login:$org) {
    repositories(first:50, after:$cursor, orderBy:{field:PUSHED_AT, direction:DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        name
        agentIssues: issues(states:OPEN, first:50,
                            labels:["agent/queued","agent/in-progress","agent/blocked","agent/error"]) {
          nodes { number labels(first:10){ nodes { name } } }
        }
__GOAL_FIELDS__
        pullRequests(states:OPEN, first:40) {
          nodes {
            number isDraft updatedAt reviewDecision baseRefName headRefName mergeStateStatus
            labels(first:15){ nodes { name } }
            reviews(last:10){ nodes { author { login } state submittedAt } }
            headRefOid
            autoMergeRequest { enabledAt }
            commits(last:5){ nodes { commit { committedDate messageHeadline statusCheckRollup { state } } } }
          }
        }
      }
    }
  }
}
"""

# The goal fields are NEW schema surface on a LOAD-BEARING query: collect_open_prs also drives the
# review + ci-red edge triggers and the stall detector, and a GraphQL *validation* error fails the
# WHOLE query (data=None → graphql() raises), not just the new fields. So the extended query is
# tried once and, if it errors, the walk falls back to the pre-#209 query FOREVER (this process)
# and says so in `goal_query_supported`. Losing the goal panel is a degradation; losing review
# dispatch would be an outage.
_PR_QUERY_GOALS = _PR_QUERY.replace("__GOAL_FIELDS__", _GOAL_FIELDS)
# The variable DECLARATIONS go too: "all variables used" is a GraphQL validation rule, so a base
# query still declaring $goals/$issues would be rejected — the fallback has to be clean.
# (Passing unused variable VALUES in the map is fine; only the document is validated.)
_PR_QUERY_BASE = _PR_QUERY.replace("__GOAL_FIELDS__", "").replace(", $goals:Int!, $issues:Int!", "")
_goal_fields_ok = True
_TRANSIENT_GRAPHQL = ("rate limit", "rate_limit", "ratelimit", "timeout", "timed out",
                      "temporarily", "try again", "internal error", "service unavailable",
                      "was submitted too quickly", "loading")


def is_transient_graphql_error(exc):
    """True when a GraphQL error says "not now" rather than "not ever".

    Only the second kind may latch the goal-field fallback: a drained pool (the 2026-07-17 class)
    or a 502 is not evidence that `parent`/`stateReason` are unreadable, and a process that
    concluded so would serve an empty goal panel until someone restarted it."""
    return any(marker in str(exc).lower() for marker in _TRANSIENT_GRAPHQL)


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
        "# TYPE github_pull_request_codeowner_park gauge",
        "# HELP github_pull_request_codeowner_park One row per green undrafted PR the bot APPROVED while GitHub still says REVIEW_REQUIRED — only the delegated codeowner read moves it (FU-166(a): the needs-meta clause-4 predicate on the one-poller; reviews[], never latestReviews[] — the PR#235 aside trap).",
        "# TYPE github_pull_request_reflex_wait gauge",
        "# HELP github_pull_request_reflex_wait One row per green undrafted REVIEW_REQUIRED PR with NO bot approval yet — the review reflex's own queue (the dashboard split's other half).",
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
        "# TYPE github_pull_request_park_blocking_count gauge",
        "# HELP github_pull_request_park_blocking_count Blocking-dependency count for the closing issue of a codeowner-parked PR (absent-when-unreadable — the FU-108 read-honesty rule; hotfix=\"true\" when the closing issue title starts with 🚨).",
    ]
    global _goal_fields_ok
    cursor = None
    _AGENT_ISSUE_NUMBERS.clear()
    _GOAL_TREES.clear()
    # NB the repo walk pages a CURSOR over a mutable sort key (PUSHED_AT DESC), the GraphQL cousin
    # of the offset hazard gh_paged documents: a push during the walk can re-present a repo on a
    # later page. Not reachable today — the org has 11 repos and `first:50` ends the walk on page
    # one — but it becomes live at 50+ repos, which is why the counting below is set-based and the
    # exposition is deduped rather than trusting this to stay single-page.
    for _ in range(10):  # hard page cap
        variables = {"org": ORG, "cursor": cursor, "goals": GOAL_MAX, "issues": GOAL_ISSUE_WINDOW}
        if _goal_fields_ok:
            try:
                data = graphql(_PR_QUERY_GOALS, variables)
            except RuntimeError as exc:
                # RuntimeError is graphql()'s "GraphQL said no with no usable data" — a schema or
                # permission rejection of the new fields. Transport failures (URLError, timeouts)
                # deliberately propagate instead: they say nothing about the query, and latching
                # the fallback on a network blip would kill the panel until the pod restarts.
                # A drained pool says the same thing, so it is excluded by name.
                if is_transient_graphql_error(exc):
                    raise
                _goal_fields_ok = False
                print(f"goal fields rejected by GraphQL ({exc}) — falling back to the pre-#209 "
                      f"query for this process; goal_query_supported=0, PR/review metrics "
                      f"unaffected", flush=True)
                data = graphql(_PR_QUERY_BASE, variables)
        else:
            data = graphql(_PR_QUERY_BASE, variables)
        repos = data["organization"]["repositories"]
        for repo in repos["nodes"] or []:
            if not repo:
                continue
            ingest_goal_tree(repo["name"], repo)  # #209; a no-op on the fallback query
            # FU-108: per-repo agent-label counts ride THIS walk (the REST Search API silently
            # omits private repos under the fine-grained PAT — github_agent_issue_labels had
            # never emitted for oracle-fleet/sleep-tracking; same silent-success class as FU-063).
            # Counted as a SET of issue numbers, not a running += 1: a repo visited twice in one
            # walk would otherwise inflate the gauge, and no exposition-level dedup can repair an
            # already-wrong value (#153). Sets make the count idempotent in the repo dimension.
            queued_now = set()  # #459: dispatchable-queued issue numbers this poll (the appearance edge)
            for iss in (repo.get("agentIssues") or {}).get("nodes") or []:
                if not iss:
                    continue
                iss_labels = {lb.get("name") or "" for lb in (iss.get("labels") or {}).get("nodes") or [] if lb}
                for lname in iss_labels:
                    if lname.startswith("agent/"):
                        _AGENT_ISSUE_NUMBERS.setdefault(
                            (repo["name"], lname), set()).add(iss.get("number"))
                if queued_dispatchable(iss_labels):
                    queued_now.add(iss.get("number"))
            open_now = set()
            for pr in (repo.get("pullRequests") or {}).get("nodes") or []:
                if not pr:
                    continue
                open_now.add(pr["number"])
                # Null-safe: on private repos the forbidden statusCheckRollup nulls the whole
                # commit list element (bubbles to the nullable list item), so any commits[i] can be
                # None — fall through to the workflow-run join rather than crashing the collector.
                # commits[-1] = the NEWEST commit (GraphQL last:N is chronological ascending).
                commits = (pr.get("commits") or {}).get("nodes") or []
                commit = (commits[-1] or {}).get("commit") if commits else None
                rollup = (commit or {}).get("statusCheckRollup")
                if rollup:
                    ci_state = rollup["state"].lower()
                    if ci_state == "failure":
                        # Red on the rollup path: fetch the real run_attempt so a same-head
                        # rerun re-rings the doorbell (homelab#1166). One REST call per red PR
                        # per poll — the edge that matters.
                        _, ci_run_attempt = ci_state_from_runs(repo["name"], pr.get("headRefOid") or "")
                    else:
                        ci_run_attempt = 0  # non-red: no rerun expected, skip the REST call
                else:
                    # Private repo (rollup FORBIDDEN-nulls for every PAT) or genuinely no checks:
                    # join workflow runs by head SHA under Actions:read (FU-063a). One REST call
                    # per rollup-less PR per poll — a handful against the 5000/h limit.
                    ci_state, ci_run_attempt = ci_state_from_runs(repo["name"], pr.get("headRefOid") or "")
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
                    run_attempt=ci_run_attempt,
                )
                # FU-144 conflict edge-trigger: the third /coordinate edge — POST when this PR
                # carries `merge-conflict`, the transition whose workflow.md row promised this
                # piggyback and never had one (its actor, update-pr-branch, is GitHub-hosted by
                # design and cannot curl the in-cluster webhook).
                maybe_dispatch_conflict(
                    repo["name"], pr["number"], pr.get("headRefOid") or "",
                    review_decision=(pr["reviewDecision"] or "none").lower(),
                    labels=label_names,
                )
                # homelab#650 head-changed edge: POST /sentinel so a sentinel-covered repo's
                # required `iac-sentinel` status evaluates THIS head near-instant instead of
                # riding out the cron tick (the binding merge wait on every push since ci hit
                # ~1m). SENTINEL_REPOS-gated inside the dispatcher; no new API call — headRefOid
                # is already read above for the other three edges.
                maybe_dispatch_sentinel(repo["name"], pr["number"], pr.get("headRefOid") or "")
                # ADR-111 updater edge (#743): POST /update-pr when this armed PR sits
                # green-but-BEHIND — the in-cluster updater's wake; its GitHub-hosted
                # predecessor's cron burn is #698. mergeStateStatus rides the same walk,
                # zero extra API calls (the #209 goal-fields precedent).
                maybe_dispatch_behind(
                    repo["name"], pr["number"], pr.get("headRefOid") or "",
                    merge_state=(pr.get("mergeStateStatus") or "").upper(),
                    ci_state=ci_state,
                    armed=pr.get("autoMergeRequest") is not None,
                )
                # FU-166(a): the codeowner-park vs reflex-wait split, first-class series (was a
                # 600s direct-gh poll in meta-needs-attention.sh clause 4 — against the one-poller
                # doctrine and FU-084's API pool). ci green folds INTO the predicate here, so the
                # consumer needs no run-state annotation at all.
                if (pr["reviewDecision"] or "") == "REVIEW_REQUIRED" and not pr["isDraft"] \
                        and ci_state in ("success", "none"):
                    if bot_approved_at:
                        lines.append(metric("github_pull_request_codeowner_park", ident, 1))
                        # #1115: blocking-edge read for PARKED PRs only — resolve the closing issue
                        # and read its blocking dependencies. One REST call per parked PR (parks are
                        # few, so the pool cost is ~0). Absent-when-unreadable (the FU-108 rule):
                        # a failed read emits NO series, never a fake zero.
                        try:
                            pr_detail = gh(f"/repos/{repo['name']}/pulls/{pr['number']}")
                            body = pr_detail.get("body") or ""
                            # Parse "Fixes #N" or "Closes #N" (GitHub's closing keywords)
                            closing_issue = _parse_closing_issue(body)
                            if closing_issue is not None:
                                blocking = gh(
                                    f"/repos/{repo['name']}/issues/{closing_issue}/dependencies/blocking?per_page=100")
                                blocking_count = len(blocking) if isinstance(blocking, list) else 0
                                block_labels = {"owner": ORG, "repo": repo["name"],
                                                "pr": str(pr["number"]),
                                                "issue": str(closing_issue)}
                                # Check if the closing issue title starts with 🚨 (hotfix)
                                try:
                                    issue_data = gh(
                                        f"/repos/{repo['name']}/issues/{closing_issue}")
                                    if (issue_data.get("title") or "").startswith("\U0001f6a8"):
                                        block_labels["hotfix"] = "true"
                                except Exception:
                                    pass  # issue read failure is not fatal — emit without hotfix
                                lines.append(metric(
                                    "github_pull_request_park_blocking_count",
                                    block_labels, blocking_count))
                        except Exception:
                            pass  # absent-when-unreadable — emit nothing on failure
                    else:
                        lines.append(metric("github_pull_request_reflex_wait", ident, 1))
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
            # ADR-106 (6): PRs that LEFT the open set since last poll — the merge edge.
            # Unresolved numbers (transient read/POST failure) stay in the tracked set so they
            # vanish AGAIN next poll and retry — the prev-set is the only memory this edge has.
            _mdb_unresolved = maybe_dispatch_merged(
                repo["name"], _open_prs_prev.get(repo["name"], set()) - open_now)
            _open_prs_prev[repo["name"]] = open_now | _mdb_unresolved
            # #459: issues newly dispatchable-queued since last poll — the label-transition edge.
            # maybe_dispatch_queued owns the prev-set diff + retry internally.
            maybe_dispatch_queued(repo["name"], queued_now)
        if not repos["pageInfo"]["hasNextPage"]:
            return
        cursor = repos["pageInfo"]["endCursor"]



_AGENT_ISSUE_NUMBERS = {}  # (repo, label) -> {issue numbers}; filled by collect_open_prs' walk (FU-108)


def collect_agent_issues(lines):
    """FU-091 queue-liveness: per-repo counts of the agent state labels, so "queued work + idle
    loop" is a Prometheus fact instead of tick-log prose (the 2026-07-18→21 three-day stall).
    FU-108: counts come from the collect_open_prs GraphQL walk (agentIssues on each repo node —
    0 extra API calls); the REST Search API was dropped because it SILENTLY omits private-repo
    results under the fine-grained PAT (30d of series proved oracle-fleet/sleep-tracking never
    emitted — AgentQueueStalled only ever watched public repos). Runs after collect_open_prs in
    the collectors tuple; if that walk failed this poll, the dict is stale-empty and no series
    emit (absent ≠ zero — honest, same rule as the subscription gauges)."""
    lines += [
        "# TYPE github_agent_issue_labels gauge",
        "# HELP github_agent_issue_labels Open issues per repo carrying each agent state label (source: the PR GraphQL walk, FU-108).",
    ]
    for (repo, label), numbers in sorted(_AGENT_ISSUE_NUMBERS.items()):
        lines.append(metric("github_agent_issue_labels",
                            {"owner": ORG, "repo": repo, "label": label}, len(numbers)))
    # FU-166 dashboard tables: one row PER issue so the cockpit can render clickable repo#N
    # links (cardinality = open agent-labelled issues, dozens at worst — same walk, no calls).
    lines += [
        "# TYPE github_agent_issue gauge",
        "# HELP github_agent_issue One row per open agent-state-labelled issue (link tables; source: the FU-108 walk).",
    ]
    for (repo, label), numbers in sorted(_AGENT_ISSUE_NUMBERS.items()):
        for n in sorted(numbers):
            lines.append(metric("github_agent_issue",
                                {"owner": ORG, "repo": repo, "label": label, "number": n}, 1))


_GOAL_TREES = {}  # repo -> {"goals": [...], "parent": {n: p}, "issue": {n: {...}}, "truncated": bool}
_BUDGET_RE = re.compile(r"^[ \t]*budget:[ \t]*(.+)$", re.IGNORECASE | re.MULTILINE)
# ADR-102 terminals as they will be recorded once the claim taxonomy carries them. Read here
# ALREADY so the panel needs no code change the day the labels land — until then a closed goal
# reports the GitHub-native close reason, which is what is actually knowable.
_VERDICT_LABELS = {"goal/validated": "validated", "goal/reverted": "reverted",
                   "goal/abandoned": "abandoned"}


def parse_budget_usd(body):
    """The goal's `Budget:` line → float USD, or None when there is no machine-parsable one.

    Mirrors the launcher gate byte for byte (agents/agent-session.sh §Σ(spend) ≤ Budget): FIRST
    `Budget:` line wins (ADR-102: "one line only" — #29 carried €12 in prose and $16 in the
    footer), any currency symbol is stripped and the number READ AS USD (the estimator and
    OpenRouter both price in USD; an FX rate is not this platform's business). A line that does
    not reduce to a bare number yields None — the series is then ABSENT, never 0, because a goal
    with an unreadable budget is unfunded-unknown, not funded-zero."""
    m = _BUDGET_RE.search(body or "")
    if not m:
        return None
    raw = re.sub(r"^[^0-9]*", "", m.group(1).strip())
    raw = re.sub(r"[ \t]", "", raw)
    m2 = re.match(r"^[0-9]+(\.[0-9]+)?$", raw)
    return float(m2.group(0)) if m2 else None


def descendants_by_depth(parent_of, root):
    """{issue: depth} for the whole DESCENDANT TREE under `root` — never direct children.

    The same fixpoint the scan's goal-review clause and the launcher's budget gate walk, for the
    same reason (FU-143 point 6): a sprout harvested from a child sits at depth 2, and ADR-102's
    post-launch bucket puts every post-merge sprout at depth 2 as well, so a direct-children read
    would miss exactly the issues that make a goal diverge. Cycle-safe by the seen-set; the depth
    cap is a second belt against a pathological parent graph (real trees run ~3)."""
    children = {}
    for node, parent in parent_of.items():
        if parent:
            children.setdefault(parent, []).append(node)
    out, seen, frontier, depth = {}, {root}, [root], 1
    while frontier and depth <= 12:
        nxt = []
        for cur in frontier:
            for kid in sorted(children.get(cur, [])):
                if kid in seen:
                    continue
                seen.add(kid)
                out[kid] = depth
                nxt.append(kid)
        frontier, depth = nxt, depth + 1
    return out


def ingest_goal_tree(repo_name, repo_node):
    """Capture one repo's goal issues + flat parent map from the collect_open_prs walk (#209).

    Pure over the GraphQL node, so the `--self-test` drives it against a recorded tree. Absent
    fields (the pre-#209 fallback query) simply record nothing: absent ≠ zero, the same rule
    collect_agent_issues follows when its walk failed."""
    goals = (repo_node.get("goalIssues") or {}).get("nodes")
    tree = repo_node.get("issueTree") or {}
    if goals is None and not tree:
        return
    parent_of, issue = {}, {}
    for node in tree.get("nodes") or []:
        if not node:
            continue
        parent_of[node["number"]] = ((node.get("parent") or {}) or {}).get("number")
        issue[node["number"]] = {"state": node.get("state") or "",
                                 "createdAt": node.get("createdAt") or "",
                                 "closedAt": node.get("closedAt") or ""}
    _GOAL_TREES[repo_name] = {
        "goals": [g for g in (goals or []) if g],
        "parent": parent_of,
        "issue": issue,
        "truncated": bool((tree.get("pageInfo") or {}).get("hasNextPage")),
    }


def collect_goals(lines):
    """ADR-102 §"Convergence is a number" (#209, supersedes IL-G04's unbuilt gauge): per-goal
    burn-down + sprout inflow, and with it the goal REGISTRY — "what goals ran, with what
    verdicts, at what cost" as a query instead of archaeology (the operator could not find
    circles#17 by search).

    What is NOT here, deliberately: `goal_spent_usd`. Spend is already a Prometheus fact
    (`agent_run_cost_usd{project,issue,…}` on the pushgateway, pushed by the launcher's finalize
    leg) and this pod holds GitHub tokens only — it has no bucket credentials and must not grow
    an S3 read of `_ledger.jsonl` to restate a series Prometheus already has. So the exporter
    emits MEMBERSHIP (`goal_descendant_info`) and `goal_spent_usd` is the recording-rule join in
    prometheusrule.yaml. The `project` label carries the repo NAME precisely so that join is a
    plain `on(project, issue)` against the pushed series.

    Runs after collect_open_prs in the collectors tuple; if that walk failed this poll the dict
    is stale-empty and nothing emits (absent ≠ zero, same rule as collect_agent_issues)."""
    lines += [
        "# TYPE goal_query_supported gauge",
        "# HELP goal_query_supported 1 = the goal GraphQL fields are being read; 0 = this process fell back to the pre-#209 query (goal series are ABSENT, PR/review metrics unaffected).",
        f"goal_query_supported {1 if _goal_fields_ok else 0}",
        "# TYPE goal_budget_usd gauge",
        "# HELP goal_budget_usd The goal's machine-parsed `Budget:` line in USD (ADR-102). ABSENT when no line parses — an unreadable budget is unfunded-unknown, never 0.",
        "# TYPE goal_descendants_open gauge",
        "# HELP goal_descendants_open Open issues in the goal's native sub-issue tree at any depth (post-launch bucket and its sprouts included).",
        "# TYPE goal_descendants_closed gauge",
        "# HELP goal_descendants_closed Closed issues in the goal's descendant tree. A GAUGE: the 7d fix rate is delta(goal_descendants_closed[7d]), not increase().",
        "# TYPE goal_sprouts_filed_total counter",
        "# HELP goal_sprouts_filed_total Descendants at depth>=2 — the harvest sprouts and post-launch bucket children whose inflow is what makes a goal diverge. Recomputed per poll from the read window, so a sprout aging out of GOAL_ISSUE_WINDOW reads as a counter reset (increase() then undercounts; goal_tree_truncated says when that window is biting).",
        "# TYPE goal_descendant_info gauge",
        "# HELP goal_descendant_info 1 per (goal, descendant) edge incl. the goal itself at depth 0 — the membership series `goal_spent_usd` joins against agent_run_cost_usd on (project, issue).",
        "# TYPE goal_verdict gauge",
        "# HELP goal_verdict 1 per goal, state enum on the `verdict` label: open | validated | reverted | abandoned (ADR-102 terminals, read from goal/* labels once the taxonomy carries them) | completed | not_planned (the GitHub-native close reason, all that is knowable until then).",
        "# TYPE goal_tree_truncated gauge",
        "# HELP goal_tree_truncated 1 = this repo has more issues than GOAL_ISSUE_WINDOW, so a descendant that has not been updated recently can be missing from the counts above. Not a silent cap.",
    ]
    now = datetime.now(timezone.utc)
    for repo in sorted(_GOAL_TREES):
        tree = _GOAL_TREES[repo]
        ident_repo = {"owner": ORG, "project": repo, "stack": stack_of(repo)}
        lines.append(metric("goal_tree_truncated", ident_repo, 1 if tree["truncated"] else 0))
        for goal in tree["goals"]:
            number, state = goal.get("number"), (goal.get("state") or "").upper()
            closed_at = goal.get("closedAt") or ""
            # Closed goals age out of the panel (~30d) — the registry keeps them queryable via
            # Prometheus retention rather than growing the default view forever.
            if state == "CLOSED" and closed_at:
                try:
                    if (now - datetime.strptime(closed_at, "%Y-%m-%dT%H:%M:%SZ")
                            .replace(tzinfo=timezone.utc)).days > GOAL_CLOSED_MAX_AGE_DAYS:
                        continue
                except ValueError:
                    pass  # unparseable date → keep it visible rather than hide it
            ident = {**ident_repo, "goal": number}
            names = {(lb or {}).get("name") or "" for lb in (goal.get("labels") or {}).get("nodes") or []}
            verdict = next((v for lb, v in _VERDICT_LABELS.items() if lb in names), None)
            if verdict is None:
                verdict = "open" if state == "OPEN" else {
                    "COMPLETED": "completed", "NOT_PLANNED": "not_planned",
                }.get((goal.get("stateReason") or "").upper(), "closed")
            budget = parse_budget_usd(goal.get("body"))
            if budget is not None:
                lines.append(metric("goal_budget_usd", ident, budget))
            depths = descendants_by_depth(tree["parent"], number)
            states = {n: tree["issue"].get(n, {}).get("state", "") for n in depths}
            lines.append(metric("goal_descendants_open", ident,
                                sum(1 for s in states.values() if s == "OPEN")))
            lines.append(metric("goal_descendants_closed", ident,
                                sum(1 for s in states.values() if s == "CLOSED")))
            lines.append(metric("goal_sprouts_filed_total", ident,
                                sum(1 for d in depths.values() if d >= 2)))
            # The goal itself is a member (depth 0): its own decompose/coordination rounds spend
            # the same budget, so leaving it out would understate every burn-down.
            for issue_number, depth in sorted({number: 0, **depths}.items()):
                lines.append(metric("goal_descendant_info",
                                    {**ident, "issue": issue_number, "depth": depth}, 1))
            # Title rides the info series so the registry panel is readable without a second
            # lookup — bounded to 80 chars, and only ever one series per goal.
            lines.append(metric("goal_verdict",
                                {**ident, "verdict": verdict,
                                 "title": (goal.get("title") or "")[:80]}, 1))


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
        # Via metric() like every other series, so the dedup in dedupe_exposition() keys on the same
        # canonical (sorted-label) rendering — a hand-rolled line is how a series escapes it (#153).
        lines.append(metric("github_app_permission_drift", {"app": slug}, 1 if mismatches else 0))
        for perm, decl, liv in mismatches:
            lines.append(metric("github_app_permission_mismatch",
                                {"app": slug, "permission": perm, "declared": decl, "live": liv}, 1))
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


def collect_graphql_partial_stats(lines):
    """Emit counters for GraphQL partial-data errors by class (homelab#1405).

    Tracks resource-limit (GitHub's per-query node/resource exhaustion), not-accessible
    (PAT permission issues), and other errors encountered during this poll and prior.
    The counter increments once per error occurrence in any GraphQL call."""
    lines += [
        "# TYPE github_exporter_graphql_partial_total counter",
        "# HELP github_exporter_graphql_partial_total Count of GraphQL partial-data errors by class (resource-limit | not-accessible | other). Absence = zero. Increments on every partial-data response with errors.",
    ]
    for error_class in ("resource-limit", "not-accessible", "other"):
        count = _graphql_partial_total.get(error_class, 0)
        lines.append(metric("github_exporter_graphql_partial_total",
                            {"owner": ORG, "class": error_class}, count))


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


GITHUBSTATUS_URL = "https://www.githubstatus.com/api/v2/components.json"
ANTHROPICSTATUS_URL = "https://status.claude.com/api/v2/components.json"
# statuspage.io status strings, worst-last — the gauge is the index, so `>= 2` = partial outage+.
VENDOR_STATUS_SCALE = ["operational", "degraded_performance", "partial_outage", "major_outage"]


def vendor_status_value(status):
    """statuspage.io status string → gauge index. Unknown → 4 (worse than major_outage): a
    threshold that assumes the scale must not silently read a new status string as healthy."""
    return VENDOR_STATUS_SCALE.index(status) if status in VENDOR_STATUS_SCALE else 4


def _emit_vendor_status(lines, series, help_text, url):
    """Fetch ONE statuspage.io components.json and emit `series{component=…}` gauges. Group rows
    and "Visit …" banner rows are skipped — they duplicate their members / are not components. A
    failed fetch raises; the poller's per-collector try/except handles it (that vendor's family
    vanishes for a poll cycle, which is exactly the hole the alerts' max_over_time bridge rides,
    #331)."""
    req = urllib.request.Request(url, headers={"User-Agent": "homelab-github-exporter"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        components = json.loads(resp.read()).get("components", [])
    lines += [f"# TYPE {series} gauge", f"# HELP {series} {help_text}"]
    for c in components:
        name = c.get("name") or ""
        if not name or c.get("group") or name.startswith("Visit "):
            continue
        lines.append(metric(series, {"component": name}, vendor_status_value(c.get("status") or "")))


def collect_vendor_status(lines):
    """FU-150 (vendor half): GitHub's OWN view of GitHub, as a gauge. During the 2026-08-07
    Actions outage every in-cluster signal looked like ours (runners idle, queues frozen, zero
    failures — a queued run never FAILS) and the operator had to check githubstatus.com by hand.
    Unauthenticated statuspage.io endpoint — no token, no rate-limit pool. A component we don't
    recognize maps to 4 (worse than major_outage): unknown is not okay."""
    _emit_vendor_status(lines, "github_vendor_component_status",
                        "githubstatus.com component state: 0 operational, 1 degraded_performance, 2 partial_outage, 3 major_outage, 4 unrecognized.",
                        GITHUBSTATUS_URL)


def collect_anthropic_status(lines):
    """homelab#555: Anthropic's OWN view of Anthropic, the sibling of collect_vendor_status. The
    whole coordination/review plane rides the Anthropic subscription (agents/coordinator), so
    status.claude.com is the "is it us or them" gauge for slow/failed subscription sessions while
    our own windows (the FU-088 latch, utilization headers) stay green. Canonical URL =
    status.claude.com, probed 2026-08-18 ~19:40Z (serves statuspage JSON; status.anthropic.com
    301-redirects to it). The gauge emits ALL components — report-only, six series — so a future
    incident on a component nobody predicted is still visible; only the alert filters
    (prometheusrule.yaml AnthropicVendorDegraded)."""
    _emit_vendor_status(lines, "anthropic_vendor_component_status",
                        "status.claude.com component state: 0 operational, 1 degraded_performance, 2 partial_outage, 3 major_outage, 4 unrecognized.",
                        ANTHROPICSTATUS_URL)


def collect_issue_lifecycle(lines):
    """Leg 2 of #628: issue-lifecycle series (queued→done wall) per closed issue.

    For issues CLOSED since the last poll, emit `github_issue_queued_at` / `github_issue_done_at`
    per (repo, issue) from the label-event timeline. The agent/queued first-applied timestamp is
    the queued_at; the close time is the done_at. Re-queues keep the FIRST queued epoch (the
    platform throughput board joins this against agent_run_* for LLM-vs-platform split).

    Uses server-side `since` filter on `updated_at` to reduce API quota usage (GitHub's Issues
    List endpoint filters by updated_at, and closing an issue updates it)."""
    global _errors
    since = (datetime.now(timezone.utc) - timedelta(hours=WINDOW_HOURS)).strftime("%Y-%m-%dT%H:%M:%SZ")
    all_repos = [r for r in gh_paged(f"/orgs/{ORG}/repos?type=all", None) if not r["archived"]]
    repos = [r["name"] for r in all_repos]
    lines += [
        "# TYPE github_issue_queued_at gauge",
        "# HELP github_issue_queued_at Epoch when the issue first received agent/queued label.",
        "# TYPE github_issue_done_at gauge",
        "# HELP github_issue_done_at Epoch when the issue was closed (the wall time for queued→done).",
    ]
    for repo in repos:
        # Fetch closed issues with server-side since filter on updated_at
        path = f"/repos/{ORG}/{repo}/issues?state=closed&sort=updated&direction=desc&since={since}"
        try:
            window_cutoff = epoch(since)
            for issue in gh_paged(path, None):
                if not issue or issue.get("pull_request"):
                    continue  # skip PRs (they appear in issues list too)
                number = issue.get("number")
                closed_at = issue.get("closed_at")
                if not (number and closed_at):
                    continue
                # Filter to window: only issues closed within WINDOW_HOURS
                if epoch(closed_at) < window_cutoff:
                    continue
                # Get label timeline for this issue to find first agent/queued application
                try:
                    events = list(gh_paged(f"/repos/{ORG}/{repo}/issues/{number}/events?", None))
                    if not events:
                        continue
                    queued_at = None
                    for event in events:
                        if (event.get("event") == "labeled" and
                            (event.get("label") or {}).get("name") == "agent/queued"):
                            # First labeled event with agent/queued — record the epoch and stop
                            created = event.get("created_at")
                            if created and not queued_at:
                                queued_at = epoch(created)
                    if queued_at is not None:
                        labels = {
                            "owner": ORG,
                            "repo": repo,
                            "number": number,
                        }
                        lines.append(metric("github_issue_queued_at", labels, queued_at))
                        lines.append(metric("github_issue_done_at", labels, epoch(closed_at)))
                except Exception as exc:
                    _errors += 1
                    print(f"collect_issue_lifecycle: failed to fetch events for {ORG}/{repo}#{number}: {exc}", flush=True)
        except Exception as exc:
            _errors += 1
            print(f"collect_issue_lifecycle: failed to fetch issues for {ORG}/{repo}: {exc}", flush=True)


def _publish_with_self_metrics(published):
    global _body
    self_metrics = [
        "# TYPE github_exporter_errors_total counter",
        f"github_exporter_errors_total {_errors}",
        "# TYPE github_exporter_last_success_timestamp gauge",
        "# HELP github_exporter_last_success_timestamp Epoch of the last fully successful poll (stale ⇒ token expired/revoked or API down).",
        f"github_exporter_last_success_timestamp {_last_success}",
        "# TYPE github_exporter_duplicate_samples_total counter",
        "# HELP github_exporter_duplicate_samples_total Duplicate sample lines collapsed out of the exposition (#153); >0 = a collector re-emitted a series and the dedup absorbed it — the poller is correct but a duplication path is back.",
        f"github_exporter_duplicate_samples_total {_dupes}",
    ]
    with _lock:
        _body = "\n".join(published + self_metrics) + "\n"


def _run_poll_cycle(collectors):
    """Run one collection cycle: iterate collectors, accumulate/dedupe lines, publish incrementally.

    Returns True iff all collectors succeeded; False if any failed. Updates module globals:
    _body (published lines + self-metrics), _dupes (dedup counter), _last_success (only on success),
    _carryover (per-collector last successful lines).

    Each publish also carries the PREVIOUS successful lines of every collector that hasn't run yet
    this cycle. Without that, the first publish of a cycle dropped all later collectors' series for
    the ~1 min the two GraphQL/Actions walks take, and any scrape landing in that window read
    "No data" on every table riding those series (the agent-running queue panels blinked every
    cycle; diagnosed 2026-08-31: 68/361 range points had github_agent_issue absent while
    collector-1 series were present, errors_total 0). A FAILED collector still publishes nothing
    for its families — its carryover is popped, keeping absent ≠ zero for the alerts."""
    global _body, _errors, _last_success, _first_successful_poll
    accumulated = []  # this cycle's deduped lines so far — dupe counting is per fresh cycle only
    pending = [c.__name__ for c in collectors]  # not yet run this cycle → carryover applies
    ok = True
    for collector in collectors:
        try:
            collector_lines = []
            collector(collector_lines)
            # Accumulate this collector's lines and deduplicate the full body so far
            accumulated.extend(collector_lines)
            before = _dupes
            published = dedupe_exposition(accumulated)  # dedupe the accumulated body
            accumulated = published  # keep only deduped lines for the next collector
            if _dupes > before:
                print(f"exposition: collapsed {_dupes - before} duplicate sample line(s) in {collector.__name__} "
                      f"(github_exporter_duplicate_samples_total={_dupes})", flush=True)
            _carryover[collector.__name__] = collector_lines
            # Clear _first_successful_poll once workflow_runs itself succeeds (not when all collectors do)
            if collector.__name__ == "collect_workflow_runs":
                _first_successful_poll = False
        except Exception as exc:  # keep the other collector alive; alert rides the metrics below
            ok = False
            _errors += 1
            print(f"{collector.__name__} failed: {exc}", flush=True)
            _carryover.pop(collector.__name__, None)  # absent ≠ zero: a failed walk publishes nothing
            published = accumulated
        # Publish: previous cycle's lines for the collectors still pending, then this cycle's fresh
        # lines (carryover first, so a series present in both resolves to the fresh value —
        # dedupe is last-write-wins). Self-metrics always appended, present even during cold start.
        pending.remove(collector.__name__)
        carry = [line for name in pending for line in _carryover.get(name, [])]
        if carry:
            _publish_with_self_metrics(dedupe_exposition(carry + published, count=False))
        else:
            _publish_with_self_metrics(published)
    # Only update _last_success on a fully successful cycle (all collectors succeeded)
    if ok:
        _last_success = int(time.time())
    return ok


def poll_forever():
    collectors = (collect_open_prs, collect_workflow_runs, collect_agent_issues, collect_goals,
                  collect_issue_lifecycle, collect_billing, collect_rate_limits,
                  collect_app_permission_drift, collect_vendor_status, collect_anthropic_status,
                  collect_graphql_partial_stats)
    while True:
        _run_poll_cycle(collectors)
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


# ── the goal-walk self-test (#209) ───────────────────────────────────────────────────────────────
# Same shape as the openrouter-proxy's (`python3 …/router.py --self-test`, `devbox run
# router-self-test`): the test lives INSIDE the shipped module and drives the pure functions
# against a RECORDED tree, so what CI checks is the code the ConfigMap ships — not a copy.
# The fixture is the two shapes ADR-102 was validated against: oracle-fleet goal-174 (a tree that
# kept sprouting 3 generations deep after close) and circles#17 (a goal closed on a machine
# "goal met" that production refuted).
_FIXTURE = {
    "name": "oracle-fleet",
    "goalIssues": {"nodes": [
        {"number": 174, "title": "goal-174 — absorbable tier", "state": "OPEN",
         "stateReason": None, "closedAt": None,
         "body": "Some prose about a €99 idea.\n\nBudget: $12.50\nVerdict-authority: kpi\n",
         "labels": {"nodes": [{"name": "task/goal"}]}},
        {"number": 17, "title": "circles P0 MVP", "state": "CLOSED",
         "stateReason": "COMPLETED", "closedAt": "2026-08-08T10:00:00Z",
         "body": "Budget: 16\n", "labels": {"nodes": [{"name": "task/goal"},
                                                      {"name": "goal/reverted"}]}},
        {"number": 3, "title": "ancient goal", "state": "CLOSED", "stateReason": "NOT_PLANNED",
         "closedAt": "2020-01-01T00:00:00Z", "body": "Budget: 5\n", "labels": {"nodes": []}},
        {"number": 40, "title": "unfunded goal", "state": "OPEN", "stateReason": None,
         "closedAt": None, "body": "no machine line here\n", "labels": {"nodes": []}},
    ]},
    "issueTree": {"pageInfo": {"hasNextPage": True}, "nodes": [
        {"number": 174, "state": "CLOSED", "createdAt": "2026-08-01T00:00:00Z",
         "closedAt": "2026-08-07T00:00:00Z", "parent": None},
        {"number": 175, "state": "CLOSED", "createdAt": "2026-08-01T00:00:00Z",
         "closedAt": "2026-08-02T00:00:00Z", "parent": {"number": 174}},   # child, depth 1
        {"number": 176, "state": "OPEN", "createdAt": "2026-08-01T00:00:00Z",
         "closedAt": None, "parent": {"number": 174}},                      # post-launch, depth 1
        {"number": 177, "state": "OPEN", "createdAt": "2026-08-03T00:00:00Z",
         "closedAt": None, "parent": {"number": 175}},                      # sprout, depth 2
        {"number": 178, "state": "CLOSED", "createdAt": "2026-08-03T00:00:00Z",
         "closedAt": "2026-08-04T00:00:00Z", "parent": {"number": 176}},    # sprout, depth 2
        {"number": 179, "state": "OPEN", "createdAt": "2026-08-05T00:00:00Z",
         "closedAt": None, "parent": {"number": 177}},                      # sprout, depth 3
        {"number": 17, "state": "CLOSED", "createdAt": "2026-07-01T00:00:00Z",
         "closedAt": "2026-08-08T10:00:00Z", "parent": None},
        {"number": 29, "state": "OPEN", "createdAt": "2026-07-20T00:00:00Z",
         "closedAt": None, "parent": {"number": 17}},
        {"number": 900, "state": "OPEN", "createdAt": "2026-08-01T00:00:00Z",
         "closedAt": None, "parent": None},                                 # unrelated to any goal
    ]},
}


# ── the queued-age pins (FU-150 OURS half, #284) ─────────────────────────────────────────────────
# The alert that consumes github_workflow_run_queued_since_timestamp lives in the PrometheusRule
# beside this file, and `promtool test rules` cannot read a CR (its rules sit under .spec), so the
# behaviour fixture loads a COPY of the rule. Both halves are pinned here rather than trusted:
# a renamed series, an edited threshold or a fixture left behind fails CI (devbox run
# exporter-self-test) instead of rotting into a fixture that tests something nobody ships.
# The line-scan-not-YAML-parse choice is spend-probe.py's, for its reason: this pod image is
# stdlib-only, and a two-key lookup does not justify vendoring a parser.
_HERE = os.path.dirname(os.path.abspath(__file__))
RULE_FILE = os.path.join(_HERE, "prometheusrule.yaml")
FIXTURE_RULES = os.path.join(_HERE, "queued-age.promtool-rules")
GOALS_FIXTURE_RULES = os.path.join(_HERE, "agent-goals.promtool-rules")
QUEUED_AGE_METRIC = "github_workflow_run_queued_since_timestamp"
_ALERT_RE = re.compile(r"^\s*-\s*alert:\s*(\S+)\s*$")
# homelab#348: the goal registry's arithmetic is RECORDING rules, so the pin needs the same block
# scan keyed on `- record:`. Same shape, one regex apart — hence _rule_block below.
_RECORD_RE = re.compile(r"^\s*-\s*record:\s*(\S+)\s*$")


def _rule_block(path, pattern, name):
    """One rule's block, dedented so the CR and the promtool copy compare as equals.

    Comments and blank lines are dropped (the CR carries the reasoning, the fixture carries the
    runnable copy); everything the rule MEANS — expr, for, labels, annotations — must match."""
    out, indent, capturing = [], 0, False
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            match = pattern.match(line)
            if match:
                if capturing:
                    break              # the next rule starts: this block is complete
                if match.group(1) != name:
                    continue
                capturing, indent = True, len(line) - len(line.lstrip())
                out.append(line.strip())
                continue
            if not capturing:
                continue
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if len(line) - len(line.lstrip()) <= indent:
                break                  # dedented out of the rule
            out.append(line[indent:].rstrip())
    return out


def alert_rule(path, name):
    """One alert's rule block (see _rule_block)."""
    return _rule_block(path, _ALERT_RE, name)


def record_rule(path, name):
    """One recording rule's block (see _rule_block)."""
    return _rule_block(path, _RECORD_RE, name)


def _test_poll_forever_incremental_cycles():
    """Test _run_poll_cycle()'s incremental-cycle behavior (#676).

    Verifies that (a) _body grows monotonically across collectors, (b) _dupes counts
    each real duplicate exactly once per cycle (the #669 round-2 regression), and
    (c) _last_success advances only on a fully-successful cycle; plus the carryover
    semantics (the 2026-08-31 no-data-blink fix): (d) mid-cycle, a not-yet-rerun
    collector's previous series stay published, and (e) a FAILED collector's series
    vanish — absent ≠ zero survives. The test calls the real _run_poll_cycle() seam
    with fake collectors, asserting on MODULE GLOBALS."""
    global _body, _dupes, _last_success, _first_successful_poll, _errors, _carryover
    saved_time = time.time
    saved_first_successful_poll = _first_successful_poll
    saved_body = _body
    saved_dupes = _dupes
    saved_last_success = _last_success
    saved_errors = _errors
    saved_carryover = _carryover

    cycle_times = [1000.0]  # mutable clock for time.time() mock
    def _mock_time():
        return cycle_times[0]

    # Simulated collectors that emit lines with intentional duplicates
    def _collector1(lines):
        """First collector: emits 2 unique lines and 1 duplicate."""
        lines.append("# TYPE test_metric gauge")
        lines.append("test_metric{job=\"job1\"} 1")
        lines.append("test_metric{job=\"job2\"} 2")
        lines.append("test_metric{job=\"job1\"} 1")  # duplicate of job1

    def _collector2(lines):
        """Second collector: emits 2 unique lines, 1 duplicate from collector1."""
        lines.append("test_metric{job=\"job3\"} 3")
        lines.append("test_metric{job=\"job4\"} 4")
        lines.append("test_metric{job=\"job1\"} 1")  # duplicate from collector1

    def _collector3(lines):
        """Third collector: emits 1 unique line, 1 duplicate from collector2."""
        lines.append("test_metric{job=\"job5\"} 5")
        lines.append("test_metric{job=\"job3\"} 3")  # duplicate from collector2

    def _collector_fail(lines):
        """Failing collector: raises an exception."""
        raise RuntimeError("simulated collector failure")

    def _collector2_expects_carryover(lines):
        """Runs where _collector2 would: by now only _collector1 has re-run this cycle, so
        _collector3's PREVIOUS series (job5) must still be in the published body (d)."""
        assert 'test_metric{job="job5"} 5' in _body, \
            "carryover: collector3's previous series must survive collector1's mid-cycle publish"
        _collector2(lines)

    def _collector3_fails(lines):
        raise RuntimeError("simulated collector3 failure")
    _collector3_fails.__name__ = _collector3.__name__  # fail the collector that HAS carryover

    try:
        time.time = _mock_time

        # Test cycle 1: all collectors succeed
        _dupes = 0
        _body = "# initial\n"
        _last_success = 0
        _errors = 0
        _carryover = {}
        cycle_times[0] = 1000.0

        # Call the real _run_poll_cycle() with fake collectors
        ok = _run_poll_cycle((_collector1, _collector2, _collector3))

        # Cycle 1: all succeed, so ok should be True and _last_success should advance
        assert ok is True, "cycle 1 should succeed"
        assert _last_success == 1000, "_last_success should advance on full success (was 0, now should be 1000)"
        assert _dupes > 0, "collector1 should find duplicates (job1 appears twice)"
        assert len(_body) > len("# initial\n"), "_body should grow after cycle 1"

        # Test cycle 2: one collector fails — _last_success should NOT advance
        _dupes = 0
        _body = "# cycle 2\n"
        _last_success = 0  # reset
        _errors = 0
        cycle_times[0] = 2000.0

        # Run a cycle with a failure in the middle
        ok = _run_poll_cycle((_collector1, _collector_fail, _collector3))

        # Cycle 2: failure occurred, so ok should be False and _last_success should still be 0
        assert ok is False, "cycle 2 should fail"
        assert _last_success == 0, "_last_success should NOT advance when a collector fails"
        assert _errors > 0, "_errors should increment on collector failure"

        # Test cycle 3: all succeed again — _last_success should advance
        _dupes = 0
        _body = "# cycle 3\n"
        _last_success = 0  # reset
        _errors = 0
        cycle_times[0] = 3000.0

        ok = _run_poll_cycle((_collector1, _collector2, _collector3))

        # Cycle 3: all succeed, so ok should be True and _last_success should advance
        assert ok is True, "cycle 3 should succeed"
        assert _last_success == 3000, "_last_success should advance on full success (was 0, now should be 3000)"

        # Test cycle 4 (d): mid-cycle, collector3's previous series must still be published —
        # the probe collector asserts on _body from inside the cycle.
        cycle_times[0] = 4000.0
        ok = _run_poll_cycle((_collector1, _collector2_expects_carryover, _collector3))
        assert ok is True, "cycle 4 should succeed (carryover probe asserts inside)"

        # Test cycle 5 (e): the collector WITH carryover fails — its series must vanish
        # (absent ≠ zero), while the successful collectors' series stay.
        cycle_times[0] = 5000.0
        ok = _run_poll_cycle((_collector1, _collector2, _collector3_fails))
        assert ok is False, "cycle 5 should fail"
        assert 'test_metric{job="job5"} 5' not in _body, \
            "a failed collector's carryover must be dropped — absent ≠ zero"
        assert 'test_metric{job="job2"} 2' in _body, "successful collectors' series must stay"

    finally:
        time.time = saved_time
        _first_successful_poll = saved_first_successful_poll
        _body = saved_body
        _dupes = saved_dupes
        _last_success = saved_last_success
        _errors = saved_errors
        _carryover = saved_carryover


def _parse_closing_issue(body):
    """Extract a closing-issue number from a PR body using GitHub's closing-keyword convention.

    Returns the issue number as int, or None if no closing keyword is found.
    The leading-edge anchor ((?:^|[^a-z])) prevents false matches on words like
    'prefixes', 'unresolved', or 'disclosed' that contain the keyword as a substring.
    """
    if not body:
        return None
    m = re.search(
        r"(?i)(?:^|[^a-z])(?:clos|fix|resolv)(?:e[ds]?|ing)?\s+#(\d+)", body)
    return int(m.group(1)) if m else None


def self_test():
    """`python3 github-exporter.py --self-test` — the descendant walk against a recorded tree."""
    assert parse_budget_usd("Budget: $12.50\n") == 12.5
    assert parse_budget_usd("budget:  €12\n") == 12.0, "currency stripped, number read as USD"
    assert parse_budget_usd("Budget: 16\nBudget: 99\n") == 16.0, "FIRST line wins (ADR-102)"
    assert parse_budget_usd("Budget: to be decided\n") is None, "unreadable ⇒ absent, never 0"
    assert parse_budget_usd(None) is None and parse_budget_usd("") is None

    # ── #1137: closing-keyword regex coverage ────────────────────────────────────────────────────
    # All 12 closing-keyword forms (3 roots × 4 inflections) must parse.
    _closing_forms = [
        "close", "closes", "closed", "closing",
        "fix", "fixes", "fixed", "fixing",
        "resolve", "resolves", "resolved", "resolving",
    ]
    for kw in _closing_forms:
        assert _parse_closing_issue(f"This PR {kw} #456") == 456, \
            f"'{kw}' must parse as closing keyword"
    # Also test at line start (no leading space)
    assert _parse_closing_issue("Fixes #789") == 789, "line-start keyword must parse"
    assert _parse_closing_issue("Closes #789") == 789, "line-start keyword must parse"
    assert _parse_closing_issue("Resolves #789") == 789, "line-start keyword must parse"
    # Negative controls: no keyword, non-closing refs, and false-positive substrings
    assert _parse_closing_issue("Just a reference to #456") is None, \
        "bare #N with no keyword must NOT parse"
    assert _parse_closing_issue("Refs #456") is None, \
        "'Refs #N' must NOT parse as closing"
    assert _parse_closing_issue("prefixes #456") is None, \
        "'prefixes #N' must NOT parse (false positive from unanchored regex)"
    assert _parse_closing_issue("unresolved #456") is None, \
        "'unresolved #N' must NOT parse (false positive from unanchored regex)"
    assert _parse_closing_issue("disclosed #456") is None, \
        "'disclosed #N' must NOT parse (false positive from unanchored regex)"
    assert _parse_closing_issue(None) is None, "None body must return None"
    assert _parse_closing_issue("") is None, "empty body must return None"
    assert _parse_closing_issue("No numbers here") is None, \
        "body with no #N must return None"

    # Cycle safety: the seen-set must terminate a parent graph that points back at itself.
    assert descendants_by_depth({1: 2, 2: 1}, 1) == {2: 1}, "cycle must terminate"
    assert descendants_by_depth({}, 174) == {}

    # Hermetic: seed the stacks.json cache (fresh `at` ⇒ no refresh) so the test never touches the
    # network, and assert the `stack` label the convergence tile groups by.
    _stacks_cache.update({"at": time.monotonic(), "map": {},
                          "stack_of": {"oracle-fleet": "oracle", "circles": "circles"}})
    assert stack_of("oracle-fleet") == "oracle"
    assert stack_of("some-unclaimed-repo") == "unknown", "unattributed, not folded into a stack"

    _GOAL_TREES.clear()
    ingest_goal_tree("oracle-fleet", _FIXTURE)
    tree = _GOAL_TREES["oracle-fleet"]
    depths = descendants_by_depth(tree["parent"], 174)
    assert depths == {175: 1, 176: 1, 177: 2, 178: 2, 179: 3}, depths
    assert 900 not in depths, "an issue outside the tree is not a descendant"

    lines = []
    collect_goals(lines)
    body = "\n".join(dedupe_exposition(lines))

    def has(sample):
        assert sample in body, f"missing sample: {sample}\n--- exposition ---\n{body}"

    has('goal_budget_usd{goal="174",owner="teststuffstash",project="oracle-fleet",stack="oracle"} 12.5')
    has('goal_descendants_open{goal="174",owner="teststuffstash",project="oracle-fleet",stack="oracle"} 3')
    has('goal_descendants_closed{goal="174",owner="teststuffstash",project="oracle-fleet",stack="oracle"} 2')
    has('goal_sprouts_filed_total{goal="174",owner="teststuffstash",project="oracle-fleet",stack="oracle"} 3')
    has('goal_tree_truncated{owner="teststuffstash",project="oracle-fleet",stack="oracle"} 1')
    # The goal itself is a member at depth 0 — its own rounds spend the same budget.
    has('goal_descendant_info{depth="0",goal="174",issue="174",owner="teststuffstash",project="oracle-fleet",stack="oracle"} 1')
    has('goal_descendant_info{depth="3",goal="174",issue="179",owner="teststuffstash",project="oracle-fleet",stack="oracle"} 1')
    # Verdict: a goal/* terminal label wins over the GitHub close reason; an open goal is "open";
    # a goal with no parsable Budget: line emits NO budget series at all.
    has('verdict="reverted"')
    has('verdict="open"')
    assert 'goal="40"' in body and 'goal_budget_usd{goal="40"' not in body, \
        "an unfunded goal must emit no budget series"
    assert 'goal="3"' not in body, "a goal closed >30d ago ages out of the panel"
    assert body.count("goal_verdict{") == 3, body.count("goal_verdict{")

    # Whatever the collectors build, the exposition may never carry a series twice (#153).
    before = _dupes
    dedupe_exposition(lines)
    assert _dupes == before, "the goal collector emitted a duplicate series"

    # The fallback query must be a VALID document: "all variables used" means the goal variable
    # declarations have to disappear with the fields they served.
    assert "$goals" not in _PR_QUERY_BASE and "$issues" not in _PR_QUERY_BASE
    assert "goalIssues" not in _PR_QUERY_BASE and "goalIssues" in _PR_QUERY_GOALS
    assert "__GOAL_FIELDS__" not in _PR_QUERY_GOALS
    # …and only a permanent rejection may latch it. "API rate limit exceeded" must NOT.
    assert is_transient_graphql_error(RuntimeError("API rate limit exceeded for installation"))
    assert is_transient_graphql_error(RuntimeError("Something went wrong, please try again"))
    assert not is_transient_graphql_error(
        RuntimeError("Field 'parent' doesn't exist on type 'Issue'"))

    # ── the updater edge (ADR-111 / homelab#743): armed ∧ green ∧ BEHIND rings /update-pr ────────
    global UPDATE_PR_WEBHOOK_URL
    saved_update_url = UPDATE_PR_WEBHOOK_URL
    saved_urlopen_behind = urllib.request.urlopen
    _behind_posts = []

    class _BehindResp:
        def read(self):
            return b"{}"

        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

    def _capture_behind(req, timeout=30):
        _behind_posts.append(json.loads(req.data.decode()))
        return _BehindResp()

    try:
        UPDATE_PR_WEBHOOK_URL = "http://updater.test/update-pr"
        urllib.request.urlopen = _capture_behind
        _behind_dispatched.clear()
        fire = dict(merge_state="BEHIND", ci_state="success", armed=True)
        maybe_dispatch_behind("oracle-fleet", 101, "a" * 40, **fire)
        assert _behind_posts == [{"repo": "oracle-fleet", "number": "101", "head_sha": "a" * 40}], \
            _behind_posts
        maybe_dispatch_behind("oracle-fleet", 101, "a" * 40, **fire)
        assert len(_behind_posts) == 1, "same behind head must dedup — one ring per head"
        maybe_dispatch_behind("oracle-fleet", 101, "b" * 40, **fire)
        assert len(_behind_posts) == 2, "a NEW head that is still behind rings again"
        # No-fire rows: armed∧green∧CURRENT (the issue's explicit one), unarmed, red, and no URL.
        maybe_dispatch_behind("oracle-fleet", 102, "c" * 40,
                              merge_state="CLEAN", ci_state="success", armed=True)
        maybe_dispatch_behind("oracle-fleet", 103, "d" * 40,
                              merge_state="BEHIND", ci_state="success", armed=False)
        maybe_dispatch_behind("oracle-fleet", 104, "e" * 40,
                              merge_state="BEHIND", ci_state="failure", armed=True)
        assert len(_behind_posts) == 2, "CURRENT / unarmed / red must not ring"
        maybe_dispatch_behind("oracle-fleet", 105, "f" * 40,
                              merge_state="BEHIND", ci_state="none", armed=True)
        assert len(_behind_posts) == 3, "a checkless BEHIND armed PR rings (over-approx is fine)"
        UPDATE_PR_WEBHOOK_URL = ""
        maybe_dispatch_behind("oracle-fleet", 106, "0" * 40, **fire)
        assert len(_behind_posts) == 3, "empty URL disables the edge entirely"
        # The walk carries the field the predicate reads — on BOTH query variants (the goal-field
        # fallback must not strip it; it is not a goal field).
        assert "mergeStateStatus" in _PR_QUERY_GOALS and "mergeStateStatus" in _PR_QUERY_BASE
    finally:
        UPDATE_PR_WEBHOOK_URL = saved_update_url
        urllib.request.urlopen = saved_urlopen_behind
        _behind_dispatched.clear()

    # ── transient HTTP error retry (homelab#652): exponential backoff for 5xx errors ──────────────
    # Test that transient 5xx errors are retried within a poll, but persistent errors fail fast.
    assert _is_transient_http_error(urllib.error.HTTPError(None, 502, "Bad Gateway", {}, None))
    assert _is_transient_http_error(urllib.error.HTTPError(None, 504, "Gateway Timeout", {}, None))
    assert not _is_transient_http_error(urllib.error.HTTPError(None, 400, "Bad Request", {}, None))
    assert not _is_transient_http_error(urllib.error.HTTPError(None, 403, "Forbidden", {}, None))
    assert not _is_transient_http_error(RuntimeError("some error"))

    # Mock Request and responses for retry testing
    _retry_attempt_count = [0]
    def _make_failing_request(code, max_attempts=2):
        """Return a callable that simulates HTTP errors then success."""
        def _mock_request(req, timeout=30):
            _retry_attempt_count[0] += 1
            if _retry_attempt_count[0] < max_attempts:
                raise urllib.error.HTTPError(None, code, f"HTTP {code}", {}, None)
            class MockResp:
                def read(self):
                    return b'{"data": "success"}'
                def __enter__(self):
                    return self
                def __exit__(self, *args):
                    pass
            return MockResp()
        return _mock_request

    saved_urlopen_for_retry = urllib.request.urlopen
    try:
        # Test: 502 error on first attempt, success on retry
        _retry_attempt_count[0] = 0
        urllib.request.urlopen = _make_failing_request(502, max_attempts=2)
        req = urllib.request.Request("http://example.com")
        resp = _urlopen_with_retry(req, timeout=5, max_retries=3, backoff_base=0.01)
        assert resp is not None, "should succeed after retry"
        assert _retry_attempt_count[0] == 2, f"should retry once (2 attempts total), got {_retry_attempt_count[0]}"

        # Test: permanent error (400) fails immediately without retry
        _retry_attempt_count[0] = 0
        urllib.request.urlopen = lambda req, timeout=30: \
            (_ for _ in ()).throw(urllib.error.HTTPError(None, 400, "Bad Request", {}, None))
        try:
            _urlopen_with_retry(req, timeout=5, max_retries=3, backoff_base=0.01)
            assert False, "should have raised for 400 error"
        except urllib.error.HTTPError as e:
            assert e.code == 400
            assert _retry_attempt_count[0] == 0, "should not retry on 400"

        # Test: exhausts max retries on persistent 503
        _retry_attempt_count[0] = 0
        urllib.request.urlopen = _make_failing_request(503, max_attempts=10)
        try:
            _urlopen_with_retry(req, timeout=5, max_retries=2, backoff_base=0.01)
            assert False, "should fail after exhausting retries"
        except urllib.error.HTTPError as e:
            assert e.code == 503
            assert _retry_attempt_count[0] == 2, f"should exhaust max_retries (2), got {_retry_attempt_count[0]}"

    finally:
        urllib.request.urlopen = saved_urlopen_for_retry

    # ── job-level timing (#636): job queue and duration per (repo, workflow, job) ────────────────
    # Recorded runs+jobs fixture: a completed run with 3 sample jobs.
    _FIXTURE_JOBS_RUN = {
        "id": 98765432101,
        "status": "completed",
        "conclusion": "success",
        "name": "Integration Tests",
        "created_at": "2026-08-19T10:00:00Z",
        "run_started_at": "2026-08-19T10:00:15Z",
        "updated_at": "2026-08-19T10:05:00Z",
    }
    _FIXTURE_JOBS = [
        {"name": "checkout", "created_at": "2026-08-19T10:00:15Z", "started_at": "2026-08-19T10:00:20Z",
         "completed_at": "2026-08-19T10:00:30Z", "labels": ["homelab-ephemeral"]},
        {"name": "setup-python", "created_at": "2026-08-19T10:00:15Z", "started_at": "2026-08-19T10:00:35Z",
         "completed_at": "2026-08-19T10:01:45Z", "labels": ["self-hosted", "proxmox-vm"]},
        # run-tests deliberately has NO labels key: the runner_pool label must degrade to "unknown".
        {"name": "run-tests", "created_at": "2026-08-19T10:00:15Z", "started_at": "2026-08-19T10:02:00Z",
         "completed_at": "2026-08-19T10:04:50Z"},
    ]

    # Test job timing collection: queue and duration metrics (PR #645, round 2: fix regressions).
    # Regression 1: series must be emitted EVERY scrape while run is in window (caching fix).
    # Regression 2: a failed /jobs fetch must be retried, not blacklisted (exception handling).
    _job_timings.clear()
    _jobs_fetched.clear()

    saved_gh = globals()['gh']
    call_count = [0]  # mutable count for closure

    def _mock_gh_jobs_succeed(path, token=None):
        """Mock gh() that succeeds on the jobs endpoint."""
        call_count[0] += 1
        if "/jobs" in path:
            return {"jobs": _FIXTURE_JOBS}
        return {}

    def _mock_gh_jobs_fail_once(path, token=None):
        """Mock gh() that fails once on jobs, then succeeds (retry test)."""
        call_count[0] += 1
        if "/jobs" in path:
            if call_count[0] == 1:
                raise Exception("simulated /jobs API failure")
            return {"jobs": _FIXTURE_JOBS}
        return {}

    globals()['gh'] = _mock_gh_jobs_succeed
    try:
        # First scrape: populate cache.
        lines1 = collect_job_timings("homelab", _FIXTURE_JOBS_RUN)
        assert len(lines1) == 6, f"expected 6 lines (3 jobs × 2 metrics), got {len(lines1)}"
        assert _FIXTURE_JOBS_RUN["id"] in _job_timings, "lines must be cached"
        assert _FIXTURE_JOBS_RUN["id"] in _jobs_fetched, "run must be marked fetched on success"
        assert call_count[0] == 1, "API should be called once"

        # Verify run_id label is present for disambiguation.
        body1 = "\n".join(lines1)
        assert f'run_id="{_FIXTURE_JOBS_RUN["id"]}"' in body1, \
            "job series must carry run_id label to disambiguate multiple runs"

        # Ask-D instrument: the runner_pool label classifies each job's runs-on label set.
        assert 'runner_pool="arc"' in body1, "homelab-ephemeral must classify as pool arc"
        assert 'runner_pool="proxmox-vm"' in body1, "proxmox-vm label must classify as its pool"
        assert 'runner_pool="unknown"' in body1, "a job without labels must classify as unknown"

        # Second scrape: return cached lines WITHOUT calling API.
        lines2 = collect_job_timings("homelab", _FIXTURE_JOBS_RUN)
        assert lines1 == lines2, "cached lines must be identical on re-scrape"
        assert call_count[0] == 1, "API should NOT be called again (cache hit)"

        # Third scrape (same run, same cache).
        lines3 = collect_job_timings("homelab", _FIXTURE_JOBS_RUN)
        assert lines1 == lines3, "cache must return same lines every scrape"
        assert call_count[0] == 1, "API should still not be called"

        # Regression 2: failed fetch is retried.
        _job_timings.clear()
        _jobs_fetched.clear()
        call_count[0] = 0
        globals()['gh'] = _mock_gh_jobs_fail_once

        run2 = dict(_FIXTURE_JOBS_RUN)
        run2["id"] = 98765432102

        # First call fails.
        lines_fail = collect_job_timings("homelab", run2)
        assert len(lines_fail) == 0, "failed fetch should return empty lines"
        assert run2["id"] not in _jobs_fetched, \
            "run must NOT be marked fetched after API failure (retry on next scrape)"
        assert run2["id"] not in _job_timings, "cache must not store on failure"
        assert call_count[0] == 1

        # Second call succeeds (retry).
        lines_retry = collect_job_timings("homelab", run2)
        assert len(lines_retry) == 6, "retry should succeed and return 6 lines"
        assert run2["id"] in _jobs_fetched, "run must be marked fetched on success"
        assert run2["id"] in _job_timings, "lines must be cached on success"
        assert call_count[0] == 2, "API should be called again for retry"

        # Third call uses cache.
        call_count[0] = 0
        lines_cached = collect_job_timings("homelab", run2)
        assert lines_retry == lines_cached, "cache must return same lines on hit"
        assert call_count[0] == 0, "API should not be called when cached"

    finally:
        globals()['gh'] = saved_gh
        _job_timings.clear()
        _jobs_fetched.clear()

    # ── ask-D instrument: busy-slot counting rides _runner_class's in-flight jobs fetch ──────────
    assert _pool_of(["self-hosted", "proxmox-vm"]) == "proxmox-vm"
    assert _pool_of(["homelab-ephemeral"]) == "arc"
    assert _pool_of(["ubuntu-latest"]) == "hosted"
    assert _pool_of(["self-hosted"]) == "self-hosted-other"
    assert _pool_of([]) == "unknown" and _pool_of(None) == "unknown"

    saved_gh_busy = globals()['gh']

    def _mock_gh_busy(path, token=None):
        assert "/jobs" in path, f"busy test expects only a jobs fetch, got {path}"
        return {"jobs": [
            {"name": "e2e", "status": "in_progress", "labels": ["self-hosted", "proxmox-vm"]},
            {"name": "e2e-2", "status": "in_progress", "labels": ["self-hosted", "proxmox-vm"]},
            {"name": "gate", "status": "queued", "labels": ["homelab-ephemeral"]},
        ]}

    globals()['gh'] = _mock_gh_busy
    _busy_pools.clear()
    try:
        cls = _runner_class("test-repo", {"id": 555001, "status": "in_progress"})
        assert cls == "self-hosted", f"self-hosted label sets must classify self-hosted, got {cls}"
        assert _busy_pools.get("proxmox-vm") == 2, \
            f"two in-progress VM jobs must count 2 busy slots, got {_busy_pools}"
        assert "arc" not in _busy_pools, "a queued (not started) job must NOT count as busy"
    finally:
        globals()['gh'] = saved_gh_busy
        _busy_pools.clear()

    # ── FU-150 OURS half (#284): the queued-age series and the alert that consumes it ────────────
    ident = {"owner": ORG, "repo": "homelab", "workflow": "CI", "branch": "master",
             "event": "push", "number": 42, "attempt": 1, "id": 30122222222, "conclusion": "",
             "runner": "self-hosted"}

    def emitted(status):
        run = {"status": status, "created_at": "2026-08-07T01:05:00Z",
               # GitHub sets run_started_at = created_at on a run that has not started, which is
               # exactly why the queue clock has to be read off created_at.
               "run_started_at": "2026-08-07T01:05:00Z", "updated_at": "2026-08-07T01:05:30Z"}
        return {line.split("{")[0]: line.rsplit(" ", 1)[1]
                for line in run_series({**ident, "status": status}, run)}

    assert QUEUED_AGE_METRIC in emitted("queued"), "a run waiting for a runner must publish its age"
    assert emitted("queued")[QUEUED_AGE_METRIC] == str(epoch("2026-08-07T01:05:00Z"))
    # The two existing families are untouched by the new arm.
    assert "github_workflow_run_updated_timestamp" in emitted("queued")
    assert "github_workflow_run_duration_seconds" in emitted("completed")
    # A started or finished run is not queued, and the POLICY waits are not dispatch failures:
    # waiting/requested are approval gates, pending is a concurrency group (homelab's own master
    # runs queue serially by design, docs/ci.md §Concurrency). Alerting on those would ring on a
    # healthy queue, so only the exact "waiting for a runner" status may emit.
    for status in ("in_progress", "completed", "waiting", "requested", "pending", ""):
        assert QUEUED_AGE_METRIC not in emitted(status), f"status={status!r} must not read as queued"

    # The alert is only as good as its wiring: it must select the series this collector emits…
    shipped = alert_rule(RULE_FILE, "CiDispatchStalled")
    fixture = alert_rule(FIXTURE_RULES, "CiDispatchStalled")
    assert shipped, f"the queued-age alert is gone from {RULE_FILE}"
    expr = next((line.split("expr:", 1)[1].strip() for line in shipped
                 if line.strip().startswith("expr:")), "")
    assert QUEUED_AGE_METRIC in expr, \
        f"CiDispatchStalled no longer reads {QUEUED_AGE_METRIC}: {expr!r}"
    # …and the promtool fixture must be testing the rule that actually ships. This is the whole
    # reason the copy is allowed to exist: homelab#288 (FU-158) owns the harness that will extract
    # .spec.groups at run time and delete it, and until then a drifted copy would be a green
    # behaviour test of a rule nobody deployed.
    assert fixture, f"CiDispatchStalled not found in {FIXTURE_RULES}"
    assert shipped == fixture, (
        "the promtool fixture's copy of CiDispatchStalled has drifted from prometheusrule.yaml — "
        "re-extract it (the yq one-liner is in queued-age.promtool-rules) and re-run "
        "`promtool test rules argocd/resources/github-exporter/queued-age.promtool-test`\n"
        f"  shipped: {shipped}\n  fixture: {fixture}")

    # ── the agent-goals pins (homelab#348) ───────────────────────────────────────────────────────
    # Same pin, RECORDING lane. #348 found goal_budget_ratio and goal_budget_remaining_usd empty
    # for every goal since #209 — a `sum by (…)` aggregate over a raw scrape, so the plain match
    # had no pair to match — and the fix only stays fixed if the behaviour fixture keeps testing
    # the expr that actually ships. An un-pinned hand copy is #337's hazard: the fixture would go
    # on asserting the OLD expr and pass VACUOUSLY, a green that saw nothing (FU-125/FU-108).
    for _record in ("goal_spent_usd", "goal_budget_ratio", "goal_budget_remaining_usd"):
        _shipped = record_rule(RULE_FILE, _record)
        _fixture = record_rule(GOALS_FIXTURE_RULES, _record)
        assert _shipped, f"the {_record} recording rule is gone from {RULE_FILE}"
        assert _fixture, f"{_record} not found in {GOALS_FIXTURE_RULES}"
        assert _shipped == _fixture, (
            f"the promtool fixture's copy of {_record} has drifted from prometheusrule.yaml — "
            "re-extract it (the yq one-liner is in agent-goals.promtool-rules; re-fold the `>-` "
            "expr by hand) and re-run `promtool test rules "
            "argocd/resources/github-exporter/agent-goals.promtool-test`\n"
            f"  shipped: {_shipped}\n  fixture: {_fixture}")
    # The join is the whole bug: both derived rules must collapse the SCRAPED side to the
    # aggregate's label set. A plain `goal_spent_usd / goal_budget_usd` parses and returns nothing,
    # which no parse check can see — so the shape is asserted here too, not just its copy.
    for _record in ("goal_budget_ratio", "goal_budget_remaining_usd"):
        _expr = next((ln.split("expr:", 1)[1].strip() for ln in record_rule(RULE_FILE, _record)
                      if ln.strip().startswith("expr:")), "")
        assert "max by (owner, project, stack, goal) (goal_budget_usd)" in _expr, (
            f"{_record} reads goal_budget_usd without collapsing it to the aggregate's label set "
            f"— the scraped gauge carries the target labels too and the match yields NOTHING "
            f"(homelab#348): {_expr!r}")

    # ── FU-144 conflict edge-trigger (#285): the doorbell this transition never had ──────────────
    # Hermetic: urlopen is swapped for a recorder, so the predicate, the {stack, loop_ns} routing
    # and the dedup are all exercised without a socket. The dispatcher is the ONLY executable gate
    # this emitter has (agents/replay/ records coordinator-SCAN behaviour — an exporter dispatcher
    # is not a scan clause and has no fixture shape there), so every arm of the predicate is
    # pinned here.
    global COORDINATE_WEBHOOK_URL
    _stacks_cache.update({
        "at": time.monotonic(),  # fresh ⇒ graduated_loop_ns never refreshes over the network
        "map": {"circles": {"stack": "circles", "loop_ns": "circles-agents"}},
        "stack_of": {"oracle-fleet": "oracle", "circles": "circles"},
    })
    posted = []

    class _Recorded:
        def read(self):
            return b""

        def __enter__(self):
            return self

        def __exit__(self, *_):
            return False

    def _record(req, timeout=None):
        posted.append((req.full_url, json.loads((req.data or b"{}").decode())))
        return _Recorded()

    saved_urlopen, saved_url = urllib.request.urlopen, COORDINATE_WEBHOOK_URL
    urllib.request.urlopen = _record
    COORDINATE_WEBHOOK_URL = "http://agent-loop.invalid/coordinate"
    try:
        def conflict(repo, number, labels, review_decision="none", head_sha="deadbeefcafe"):
            del posted[:]
            maybe_dispatch_conflict(repo, number, head_sha,
                                    review_decision=review_decision, labels=set(labels))
            return list(posted)

        # Fires on the label alone — the scan's clause filters on nothing else, and the doorbell
        # may over-approximate (a false wake costs a scan run, never an LLM tick).
        fired = conflict("some-repo", 275, {"merge-conflict"})
        assert len(fired) == 1, fired
        assert fired[0][0] == COORDINATE_WEBHOOK_URL
        assert fired[0][1] == {"repo": "some-repo", "number": "275",
                               "head_sha": "deadbeefcafe"}, fired[0][1]
        # Silent without the label, and on each exclusion the scan's merge-conflict clause makes.
        assert conflict("some-repo", 276, {"agent/queued"}) == []
        assert conflict("some-repo", 277, {"merge-conflict", "agent/error"}) == []
        assert conflict("some-repo", 278, {"merge-conflict", "agent/arbitrate"}) == []
        assert conflict("some-repo", 279, {"merge-conflict"},
                        review_decision="changes_requested") == [], \
            "a changes-requested PR belongs to that clause, which resolves the conflict itself"
        # No head SHA ⇒ nothing to dedup on, so nothing is sent (the poll retries next cycle).
        assert conflict("some-repo", 280, {"merge-conflict"}, head_sha="") == []
        # A GRADUATED repo routes into its own loop_ns; an unknown one falls SOFT to {repo} (the
        # global trigger + its cron backstop) rather than inventing a namespace.
        grad = conflict("circles", 281, {"merge-conflict"})[0][1]
        assert grad["stack"] == "circles" and grad["loop_ns"] == "circles-agents", grad
        assert "stack" not in conflict("some-repo", 282, {"merge-conflict"})[0][1]
        # Dedup per (repo, number, head_sha): one wake per conflicted head — a resolution round
        # that pushes NO commit keeps the same head and must not re-ring…
        assert conflict("some-repo", 283, {"merge-conflict"}), "first call must fire"
        assert conflict("some-repo", 283, {"merge-conflict"}) == [], "repeat head must not re-ring"
        # …while a genuinely new head that is still conflicted rings again.
        assert conflict("some-repo", 283, {"merge-conflict"}, head_sha="f00df00df00d"), \
            "a new head still carrying the label is a new wake"
        # Empty webhook URL = the feature is off (the pre-FU-144 behaviour).
        COORDINATE_WEBHOOK_URL = ""
        assert conflict("some-repo", 284, {"merge-conflict"}) == []
    finally:
        urllib.request.urlopen, COORDINATE_WEBHOOK_URL = saved_urlopen, saved_url

    # ── #459 queued label-transition doorbell ─────────────────────────────────────────────────────
    # The appearance edge the triggers-table row promised and never built: a human applying
    # agent-fix+agent/queued (sleep-tracking#121, homelab#478/479/491) sat unrung until the */30
    # cron. Same seam as the conflict edge (recorded urlopen), so the predicate, the diff
    # semantics, the payload and the failed-POST retry are pinned without a socket.
    assert queued_dispatchable({"agent-fix", "agent/queued"})
    assert not queued_dispatchable({"agent/queued"}), "agent-fix is the fixer opt-in"
    assert not queued_dispatchable({"agent-fix"}), "agent/queued is the ready-to-dispatch state"
    assert not queued_dispatchable({"agent-fix", "agent/queued", "direction-change"}), \
        "the scan's direction-change exclusion"
    assert not queued_dispatchable({"agent-fix", "agent/queued", "agent/error"}), \
        "the scan's circuit-breaker exclusion"
    assert queued_dispatchable({"agent-fix", "agent/queued", "task/fix"}), \
        "other labels (task/fix) do not block dispatch"

    saved_urlopen, saved_url = urllib.request.urlopen, COORDINATE_WEBHOOK_URL
    urllib.request.urlopen = _record
    COORDINATE_WEBHOOK_URL = "http://agent-loop.invalid/coordinate"
    try:
        def queued(repo, currently):
            del posted[:]
            maybe_dispatch_queued(repo, set(currently))
            return list(posted)

        # The appearance diff: an issue newly dispatchable-queued rings once, payload is {repo,
        # number} — repo-dumb per the post-FU-144 emitter doctrine (the receiver fans out).
        fired = queued("sleep-tracking", [121])
        assert len(fired) == 1, fired
        assert fired[0][0] == COORDINATE_WEBHOOK_URL
        assert fired[0][1] == {"repo": "sleep-tracking", "number": "121"}, fired[0][1]
        # Staying queued does not re-ring (a scan dispatch moves it to agent/in-progress)…
        assert queued("sleep-tracking", [121]) == []
        # …a newly-queued sibling rings while the old one stays silent…
        assert queued("sleep-tracking", [121, 478]) == [
            (COORDINATE_WEBHOOK_URL, {"repo": "sleep-tracking", "number": "478"})], \
            "only the NEW member of the set may ring"
        # …and an issue that leaves the set then re-queues rings again (a genuine re-queue).
        assert queued("sleep-tracking", []) == []
        assert queued("sleep-tracking", [121]) == [
            (COORDINATE_WEBHOOK_URL, {"repo": "sleep-tracking", "number": "121"})]
        # A repo with nothing queued rings nothing.
        assert queued("circles", []) == []

        # A failed POST is folded OUT of the prev-set so the issue re-appears as new next poll —
        # the appearance edge has no natural retry (the merged-edge lesson, bot review PR#396).
        def _fail_once(req, timeout=None):
            raise urllib.error.URLError("simulated webhook outage")

        urllib.request.urlopen = _fail_once
        try:
            assert maybe_dispatch_queued("retry-repo", {7}) == {7}, "returns the unresolved set"
            assert _queued_prev.get("retry-repo") == set(), \
                "a failed POST must not mark the issue rung"
        finally:
            urllib.request.urlopen = _record
        retried = queued("retry-repo", [7])
        assert len(retried) == 1 and retried[0][1] == {"repo": "retry-repo", "number": "7"}, retried

        # Empty webhook URL = the feature is off (the pre-#459 behaviour).
        COORDINATE_WEBHOOK_URL = ""
        assert queued("off-repo", [999]) == []
    finally:
        urllib.request.urlopen, COORDINATE_WEBHOOK_URL = saved_urlopen, saved_url

    # ── FU-150 vendor half (#555): the status→index mapping both vendor gauges and the alerts'
    # thresholds assume. unknown → 4, never a silent 0 — a threshold that assumed the scale would
    # read an unrecognized string as healthy is the vacuous-green class.
    assert vendor_status_value("operational") == 0
    assert vendor_status_value("degraded_performance") == 1
    assert vendor_status_value("partial_outage") == 2
    assert vendor_status_value("major_outage") == 3
    assert vendor_status_value("under_maintenance") == 4, "unknown must read WORSE, not healthy"
    assert vendor_status_value("") == 4

    # ── leg 2 #628: issue lifecycle series (queued→done wall) with re-queue first-epoch rule ───────
    # Test 1: basic first-epoch rule — a re-queue records only T1.
    # Timestamps are relative to now so they remain inside any RUN_WINDOW_HOURS >= 1.
    _lc_now = datetime.now(timezone.utc)
    def _lc_ts(minutes_ago):
        return (_lc_now - timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")
    _LC_T1, _LC_T2, _LC_T3, _LC_T4 = _lc_ts(120), _lc_ts(90), _lc_ts(60), _lc_ts(30)

    _FIXTURE_ISSUE_LIFECYCLE_EVENTS = [
        {"event": "labeled", "label": {"name": "agent/queued"}, "created_at": _LC_T1},
        {"event": "unlabeled", "label": {"name": "agent/queued"}, "created_at": _LC_T2},
        {"event": "labeled", "label": {"name": "agent/queued"}, "created_at": _LC_T3},
        {"event": "closed", "created_at": _LC_T4},
    ]
    _FIXTURE_CLOSED_ISSUE = {
        "number": 637,
        "state": "closed",
        "closed_at": _LC_T4,
        "pull_request": None,
    }

    saved_gh_for_issue = globals()['gh']
    saved_gh_paged_for_issue = globals()['gh_paged']
    issue_fetch_calls = []

    def _mock_gh_issue_lifecycle(path, token=None):
        """Mock gh() for issue lifecycle testing."""
        issue_fetch_calls.append(path)
        if "/events" in path:
            return _FIXTURE_ISSUE_LIFECYCLE_EVENTS
        return {}

    def _mock_gh_paged_issue_lifecycle(path, key):
        """Mock gh_paged() for issue lifecycle testing."""
        issue_fetch_calls.append(path)
        if "/issues?" in path and "state=closed" in path:
            # The Issues List endpoint returns a bare array, so key must be None
            assert key is None, f"Issues List endpoint must use key=None (not key={key!r}) to avoid batch[key] indexing on bare arrays"
            yield _FIXTURE_CLOSED_ISSUE
        elif "/events" in path:
            # The Issue Events endpoint returns a bare array too, so key must be None
            assert key is None, f"Issue events endpoint must use key=None (not key={key!r}) to avoid batch[key] indexing on bare arrays"
            yield from _FIXTURE_ISSUE_LIFECYCLE_EVENTS
        elif "/repos?" in path:
            assert key is None, f"Repos endpoint must use key=None (not key={key!r})"
            yield {"name": "homelab", "archived": False, "private": False}

    globals()['gh'] = _mock_gh_issue_lifecycle
    globals()['gh_paged'] = _mock_gh_paged_issue_lifecycle
    try:
        lifecycle_lines = []
        collect_issue_lifecycle(lifecycle_lines)
        lifecycle_body = "\n".join(dedupe_exposition(lifecycle_lines))

        # Guard: collector must emit something before checking content
        assert lifecycle_body, \
            "collector emitted no samples (window filter may have excluded fixture)"

        # Verify the first queued_at is recorded (first-epoch rule: T1, not T3)
        first_queued_epoch = str(epoch(_LC_T1))
        done_epoch = str(epoch(_LC_T4))
        has_queued = f'github_issue_queued_at{{number="637",owner="teststuffstash",repo="homelab"}} {first_queued_epoch}'
        has_done = f'github_issue_done_at{{number="637",owner="teststuffstash",repo="homelab"}} {done_epoch}'
        assert has_queued in lifecycle_body, \
            f"first queued_at must be T1 (first-epoch rule), not T3 (re-queue). Got:\n{lifecycle_body}"
        assert has_done in lifecycle_body, \
            f"done_at must record close time. Got:\n{lifecycle_body}"

        # Test 2: server-side since filter and early break (FU-115 work, #656).
        # The API path must include the since parameter, and early break must prevent
        # unnecessary pagination when items fall out of the window.
        issue_fetch_calls.clear()
        collect_issue_lifecycle(lifecycle_lines)
        # Verify that the issues endpoint was called with since parameter
        issues_calls = [c for c in issue_fetch_calls if "/issues?" in c and "state=closed" in c]
        assert issues_calls, "issues endpoint must be called at least once"
        # Since parameter must be in the path (URL-encoded or not)
        assert any("since=" in call for call in issues_calls), \
            f"issues endpoint must include since parameter, got calls: {issues_calls}"

        # Test 3: closed_at vs updated_at divergence — post-close comments update updated_at
        # but not closed_at, so an out-of-window closed_at can sort ahead of an in-window one.
        # The filter must check closed_at, not updated_at, and must not early-break on the first
        # out-of-window closed_at (a later issue in the sort may have in-window closed_at).
        _OUT_OF_WINDOW = _lc_ts(1500)  # 25 hours ago (outside 24h window)
        _IN_WINDOW = _lc_ts(10)        # 10 minutes ago
        _FIXTURE_CLOSED_ISSUE_OOW = {
            "number": 638,
            "state": "closed",
            "closed_at": _OUT_OF_WINDOW,  # closed 5h ago
            "updated_at": _IN_WINDOW,      # but commented on 10m ago (sorts first by updated_at DESC)
            "pull_request": None,
        }
        _FIXTURE_CLOSED_ISSUE_IW = {
            "number": 639,
            "state": "closed",
            "closed_at": _IN_WINDOW,      # closed 10m ago (in window)
            "updated_at": _IN_WINDOW,
            "pull_request": None,
        }
        _FIXTURE_EVENTS_IW = [
            {"event": "labeled", "label": {"name": "agent/queued"}, "created_at": _LC_T1},
        ]

        def _mock_gh_paged_closed_at_divergence(path, key):
            """Mock gh_paged() for closed_at vs updated_at divergence test."""
            if "/issues?" in path and "state=closed" in path:
                # Return issues sorted by updated_at DESC (newest first)
                # Issue 638 has out-of-window closed_at but in-window updated_at (sorts first)
                # Issue 639 has in-window closed_at (sorts second)
                assert key is None
                yield _FIXTURE_CLOSED_ISSUE_OOW
                yield _FIXTURE_CLOSED_ISSUE_IW
            elif "/events" in path:
                assert key is None
                yield from _FIXTURE_EVENTS_IW
            elif "/repos?" in path:
                assert key is None
                yield {"name": "homelab", "archived": False, "private": False}

        globals()['gh_paged'] = _mock_gh_paged_closed_at_divergence
        lifecycle_lines_divergence = []
        collect_issue_lifecycle(lifecycle_lines_divergence)
        lifecycle_body_divergence = "\n".join(dedupe_exposition(lifecycle_lines_divergence))

        # Issue 638 is out-of-window by closed_at, should NOT emit
        assert 'number="638"' not in lifecycle_body_divergence, \
            "issue 638 (closed_at out-of-window) must not emit, even if updated_at is in-window"
        # Issue 639 is in-window by closed_at, MUST emit (the critical assertion)
        assert 'number="639"' in lifecycle_body_divergence, \
            f"issue 639 (closed_at in-window) must emit even when another issue sorts first; got:\n{lifecycle_body_divergence}"
    finally:
        globals()['gh'] = saved_gh_for_issue
        globals()['gh_paged'] = saved_gh_paged_for_issue

    # ── homelab#650 sentinel head-changed edge ─────────────────────────────────────────────────────
    # Same recorded-urlopen seam as the conflict/queued edges above: the predicate (SENTINEL_REPOS
    # gate), the payload shape and the per-(repo, number, head_sha) dedup are all exercised without
    # a socket.
    global SENTINEL_WEBHOOK_URL
    saved_urlopen, saved_url = urllib.request.urlopen, SENTINEL_WEBHOOK_URL
    urllib.request.urlopen = _record
    SENTINEL_WEBHOOK_URL = "http://agent-loop.invalid/sentinel"
    try:
        def sentinel(repo, number, head_sha):
            del posted[:]
            maybe_dispatch_sentinel(repo, number, head_sha)
            return list(posted)

        # A NEW head on a sentinel-covered repo rings once, payload {repo, pr, head} verbatim.
        fired = sentinel("homelab", 650, "deadbeefcafe")
        assert len(fired) == 1, fired
        assert fired[0][0] == SENTINEL_WEBHOOK_URL
        assert fired[0][1] == {"repo": "homelab", "pr": 650, "head": "deadbeefcafe"}, fired[0][1]
        # A repo outside SENTINEL_REPOS never rings, however plausible the head.
        assert sentinel("sleep-tracking", 42, "f00dbeef") == [], \
            "non-sentinel repos must never ring the sentinel doorbell"
        # The same head on a repeat poll must not re-ring (a quiet poll stays quiet)…
        assert sentinel("sleep-iac", 7, "cafef00d"), "first call must fire"
        assert sentinel("sleep-iac", 7, "cafef00d") == [], "repeat head must not re-ring"
        # …while a genuinely NEW head on the same PR is a new wake.
        assert sentinel("sleep-iac", 7, "f00df00d"), "a new head must re-ring"
        # A brand-new PR's first observed head counts as new (nothing to diff against) and rings —
        # under-ringing here strands the PR on the sentinel status its own merge wait blocks on.
        assert sentinel("oracle-iac", 999, "abc12300"), "a PR's first observed head must ring"
        assert sentinel("circles-iac", 1, "abc12399"), "every SENTINEL_REPOS member is covered"
        # No head SHA ⇒ nothing to dedup on, so nothing is sent (the poll retries next cycle).
        assert sentinel("homelab", 650, "") == []
        # Empty webhook URL = the feature is off.
        SENTINEL_WEBHOOK_URL = ""
        assert sentinel("homelab", 650, "0ff00ff00f") == []
    finally:
        urllib.request.urlopen, SENTINEL_WEBHOOK_URL = saved_urlopen, saved_url

    # ── homelab#648: first-poll job-timings skip and flag clearing ────────────────────────────────
    # Test that the _first_successful_poll branch gates job-timing collection and that the flag
    # clears once collect_workflow_runs succeeds, not when all collectors do.
    global _first_successful_poll
    _first_successful_poll = True
    _job_timings.clear()
    _jobs_fetched.clear()

    def _mock_gh_first_poll_runs(path, token=None):
        """Mock gh() for first-poll job-timings test."""
        if "/repos?" in path and "type=all" in path:
            return [{"name": "test-repo", "archived": False, "private": False}]
        if "/actions/runs?" in path:
            return {
                "workflow_runs": [{
                    "id": 999,
                    "name": "Test Workflow",
                    "status": "completed",
                    "conclusion": "success",
                    "created_at": "2026-08-19T10:00:00Z",
                    "run_started_at": "2026-08-19T10:00:15Z",
                    "updated_at": "2026-08-19T10:05:00Z",
                    "run_number": 1,
                    "run_attempt": 1,
                    "head_branch": "main",
                    "event": "push",
                }]
            }
        if "/jobs?" in path:
            # Return job details for the test run
            return {
                "jobs": [{
                    "name": "test-job",
                    "created_at": "2026-08-19T10:00:15Z",
                    "started_at": "2026-08-19T10:00:20Z",
                    "completed_at": "2026-08-19T10:00:50Z",
                }]
            }
        return {}

    saved_gh_for_first_poll = globals()['gh']
    saved_gh_paged_for_first_poll = globals()['gh_paged']

    def _mock_gh_paged_first_poll(path, key):
        """Mock gh_paged() for first-poll test."""
        if "/actions/runs?" in path:
            assert key == "workflow_runs"
            yield {
                "id": 999,
                "name": "Test Workflow",
                "status": "completed",
                "conclusion": "success",
                "created_at": "2026-08-19T10:00:00Z",
                "run_started_at": "2026-08-19T10:00:15Z",
                "updated_at": "2026-08-19T10:05:00Z",
                "run_number": 1,
                "run_attempt": 1,
                "head_branch": "main",
                "event": "push",
            }
        elif "/repos?" in path and "type=all" in path:
            assert key is None
            yield {"name": "test-repo", "archived": False, "private": False}

    globals()['gh'] = _mock_gh_first_poll_runs
    globals()['gh_paged'] = _mock_gh_paged_first_poll
    try:
        # First poll with _first_successful_poll=True: job timings are SKIPPED
        lines_first = []
        assert _first_successful_poll, "flag must start True"
        _first_successful_poll = True  # ensure it's set
        collect_workflow_runs(lines_first)
        body_first = "\n".join(lines_first)
        # Job-timing DATA samples should NOT appear on first poll (TYPE/HELP lines are always there)
        # A sample line has format: metric{labels} value
        assert not any(line.startswith("github_ci_job_queue_seconds{") for line in lines_first), \
            "first poll must skip job-timing sample collection when _first_successful_poll=True"
        # The run_updated_timestamp samples should still be there (not a job timing)
        assert any(line.startswith("github_workflow_run_updated_timestamp{") for line in lines_first), \
            "workflow run metric samples must be emitted even on first poll"
        # The busy-slot gauge costs no extra API call, so it emits even on first poll — and the
        # fixed-capacity pools read 0 explicitly when idle (ask-D instrument).
        assert any(line.startswith('github_ci_runner_busy_jobs{') and line.endswith(" 0")
                   for line in lines_first), \
            "busy-slot gauge must emit explicit zeros for the fixed-capacity pools on an idle poll"

        # Verify _first_successful_poll is reset after collect_workflow_runs
        # (simulating what happens in poll_forever after this collector succeeds)
        _first_successful_poll = False

        # Second poll with _first_successful_poll=False: job timings ARE INCLUDED
        lines_second = []
        _first_successful_poll = False
        collect_workflow_runs(lines_second)
        # Job-timing DATA samples should appear on second poll (when run is still in window)
        assert any(line.startswith("github_ci_job_queue_seconds{") for line in lines_second), \
            "second poll must include job-timing sample collection when _first_successful_poll=False"
        assert any(line.startswith("github_ci_job_duration_seconds{") for line in lines_second), \
            "job duration metric samples must be emitted"
    finally:
        globals()['gh'] = saved_gh_for_first_poll
        globals()['gh_paged'] = saved_gh_paged_for_first_poll
        _first_successful_poll = True  # reset to initial state
        _job_timings.clear()
        _jobs_fetched.clear()

    # ── #1138: park-blocking count pagination (per_page=100 on dependencies/blocking) ──────────────
    # The blocking-edge read for codeowner-parked PRs must request 100 items per page so the count
    # does not saturate at GitHub's default page size (30). This test exercises the full code path
    # through collect_open_prs with a mocked GraphQL response and mocked gh() calls.
    saved_graphql = globals().get('graphql')
    saved_gh_for_park = globals()['gh']
    saved_open_prs_prev = dict(_open_prs_prev)
    _open_prs_prev.clear()
    _AGENT_ISSUE_NUMBERS.clear()
    _GOAL_TREES.clear()
    gh_calls = []

    def _mock_graphql_park_blocking(query, variables):
        """Return a fixture with one repo and one PR that triggers the park blocking code path."""
        return {
            "organization": {
                "repositories": {
                    "pageInfo": {"hasNextPage": False, "endCursor": None},
                    "nodes": [
                        {
                            "name": "test-repo",
                            "agentIssues": {"nodes": []},
                            "pullRequests": {
                                "nodes": [
                                    {
                                        "number": 123,
                                        "isDraft": False,
                                        "updatedAt": "2026-09-01T00:00:00Z",
                                        "reviewDecision": "REVIEW_REQUIRED",
                                        "baseRefName": "main",
                                        "headRefName": "fix/foo",
                                        "mergeStateStatus": "CLEAN",
                                        "labels": {"nodes": []},
                                        "reviews": {
                                            "nodes": [
                                                {
                                                    "author": {"login": "homelab-reviewer[bot]"},
                                                    "state": "APPROVED",
                                                    "submittedAt": "2026-09-01T00:05:00Z",
                                                }
                                            ]
                                        },
                                        "headRefOid": "abc123def",
                                        "autoMergeRequest": None,
                                        "commits": {
                                            "nodes": [
                                                {
                                                    "commit": {
                                                        "committedDate": "2026-09-01T00:00:00Z",
                                                        "messageHeadline": "fix: something",
                                                        "statusCheckRollup": {"state": "SUCCESS"},
                                                    }
                                                }
                                            ]
                                        },
                                    }
                                ]
                            },
                        }
                    ],
                }
            }
        }

    def _mock_gh_park_blocking(path, token=None):
        """Mock gh() for park blocking test: record calls and return appropriate responses."""
        gh_calls.append(path)
        if "/pulls/" in path and "/dependencies" not in path and "/issues/" not in path:
            return {"body": "This PR fixes #456"}
        if "/dependencies/blocking" in path:
            # Return 35 items to verify pagination doesn't saturate at default 30
            return [{"id": i} for i in range(35)]
        if "/issues/" in path and "/dependencies" not in path:
            return {"title": "Some issue"}
        return {}

    globals()['graphql'] = _mock_graphql_park_blocking
    globals()['gh'] = _mock_gh_park_blocking
    try:
        park_lines = []
        collect_open_prs(park_lines)
        park_body = "\n".join(dedupe_exposition(park_lines))

        # Verify the park blocking count metric is emitted with the correct count (35)
        assert 'github_pull_request_park_blocking_count{' in park_body, \
            f"park blocking count metric must be emitted; got:\n{park_body}"
        assert 'issue="456"' in park_body, \
            f"park blocking count must reference closing issue 456; got:\n{park_body}"
        # The count should be 35 (all items returned, not capped at 30)
        assert ' 35' in park_body.split("github_pull_request_park_blocking_count")[-1].split("\n")[0], \
            f"park blocking count must be 35 (not capped at 30); got:\n{park_body}"

        # Verify the blocking dependencies URL includes per_page=100
        blocking_calls = [c for c in gh_calls if "/dependencies/blocking" in c]
        assert len(blocking_calls) == 1, f"expected 1 blocking call, got {len(blocking_calls)}"
        assert "per_page=100" in blocking_calls[0], \
            f"blocking dependencies URL must include per_page=100; got: {blocking_calls[0]}"

        # Verify the codeowner_park metric is also emitted (the PR is parked)
        assert 'github_pull_request_codeowner_park{' in park_body, \
            f"codeowner park metric must be emitted for a bot-approved REVIEW_REQUIRED PR; got:\n{park_body}"
    finally:
        if saved_graphql:
            globals()['graphql'] = saved_graphql
        else:
            globals().pop('graphql', None)
        globals()['gh'] = saved_gh_for_park
        _open_prs_prev.clear()
        _open_prs_prev.update(saved_open_prs_prev)
        _AGENT_ISSUE_NUMBERS.clear()
        _GOAL_TREES.clear()
    # ── #1187: cired edge-trigger coverage — real run_attempt on rollup + REST-fallback paths ──
    # The rollup path (statusCheckRollup readable, ci_state == "failure") calls ci_state_from_runs
    # to fetch the real run_attempt so a same-head rerun re-rings the doorbell (homelab#1166).
    # The REST-fallback path (rollup FORBIDDEN-null) also returns the real run_attempt from
    # ci_state_from_runs. Both paths must propagate it to maybe_dispatch_cired.
    #
    # Test 1: maybe_dispatch_cired directly — the dedup key includes run_attempt.
    _cired_dispatched.clear()
    _stacks_cache.update({
        "at": time.monotonic(),
        "map": {"circles": {"stack": "circles", "loop_ns": "circles-agents"}},
        "stack_of": {"oracle-fleet": "oracle", "circles": "circles"},
    })
    cired_posted = []

    class _CiredResp:
        def read(self):
            return b""
        def __enter__(self):
            return self
        def __exit__(self, *_):
            return False

    def _record_cired(req, timeout=None):
        cired_posted.append((req.full_url, json.loads((req.data or b"{}").decode())))
        return _CiredResp()

    saved_urlopen_cired, saved_url_cired = urllib.request.urlopen, COORDINATE_WEBHOOK_URL
    urllib.request.urlopen = _record_cired
    COORDINATE_WEBHOOK_URL = "http://agent-loop.invalid/coordinate"
    try:
        def cired(repo, number, head_sha, run_attempt=0):
            del cired_posted[:]
            maybe_dispatch_cired(
                repo, number, head_sha,
                ci_state="failure", armed=True, draft=False,
                labels=set(),
                run_attempt=run_attempt,
            )
            return list(cired_posted)

        # Fires with real run_attempt=2 — the dedup key includes it.
        fired = cired("test-repo", 1187, "deadbeefcafe", run_attempt=2)
        assert len(fired) == 1, fired
        assert fired[0][0] == COORDINATE_WEBHOOK_URL
        assert fired[0][1] == {"repo": "test-repo", "number": "1187",
                               "head_sha": "deadbeefcafe"}, fired[0][1]
        # Same (repo, number, head_sha, run_attempt) must NOT re-ring.
        assert cired("test-repo", 1187, "deadbeefcafe", run_attempt=2) == [], \
            "same (repo, number, head_sha, run_attempt) must dedup"
        # Same head_sha but NEW run_attempt (rerun) MUST re-ring (homelab#1108).
        fired_rerun = cired("test-repo", 1187, "deadbeefcafe", run_attempt=3)
        assert len(fired_rerun) == 1, f"rerun with new attempt must re-ring: {fired_rerun}"
        assert fired_rerun[0][1] == {"repo": "test-repo", "number": "1187",
                                     "head_sha": "deadbeefcafe"}, fired_rerun[0][1]
        # run_attempt=0 (no rerun expected) must NOT re-ring if already dispatched with 0.
        _cired_dispatched.clear()
        fired_zero = cired("test-repo", 1188, "f00df00d", run_attempt=0)
        assert len(fired_zero) == 1, "run_attempt=0 must fire"
        assert cired("test-repo", 1188, "f00df00d", run_attempt=0) == [], \
            "run_attempt=0 must dedup on repeat"
        # Non-red conditions must NOT fire.
        del cired_posted[:]
        maybe_dispatch_cired(
            "test-repo", 1189, "deadbeef",
            ci_state="success", armed=True, draft=False,
            labels=set(), run_attempt=0,
        )
        assert cired_posted == [], "green PR must not ring cired"
        del cired_posted[:]
        maybe_dispatch_cired(
            "test-repo", 1190, "deadbeef",
            ci_state="failure", armed=False, draft=False,
            labels=set(), run_attempt=0,
        )
        assert cired_posted == [], "unarmed PR must not ring cired"
        del cired_posted[:]
        maybe_dispatch_cired(
            "test-repo", 1191, "deadbeef",
            ci_state="failure", armed=True, draft=True,
            labels=set(), run_attempt=0,
        )
        assert cired_posted == [], "draft PR must not ring cired"
        # Exclusion labels must block.
        for excl in ("agent/error", "agent/arbitrate", "major", "major/awaiting-human", "automerge"):
            del cired_posted[:]
            maybe_dispatch_cired(
                "test-repo", 1192, "deadbeef",
                ci_state="failure", armed=True, draft=False,
                labels={excl}, run_attempt=0,
            )
            assert cired_posted == [], f"PR with label {excl!r} must not ring cired"
        # Empty webhook URL disables the edge.
        COORDINATE_WEBHOOK_URL = ""
        del cired_posted[:]
        maybe_dispatch_cired(
            "test-repo", 1193, "deadbeef",
            ci_state="failure", armed=True, draft=False,
            labels=set(), run_attempt=2,
        )
        assert cired_posted == [], "empty webhook URL must disable cired edge"
    finally:
        urllib.request.urlopen, COORDINATE_WEBHOOK_URL = saved_urlopen_cired, saved_url_cired
        _cired_dispatched.clear()

    # Test 2: rollup path in collect_open_prs — statusCheckRollup state="FAILURE" triggers
    # ci_state_from_runs to fetch the real run_attempt, which propagates to maybe_dispatch_cired.
    saved_graphql_cired = globals().get('graphql')
    saved_gh_cired = globals()['gh']
    saved_open_prs_prev_cired = dict(_open_prs_prev)
    _open_prs_prev.clear()
    _cired_dispatched.clear()
    _AGENT_ISSUE_NUMBERS.clear()
    _GOAL_TREES.clear()
    cired_collect_posted = []

    def _record_cired_collect(req, timeout=None):
        cired_collect_posted.append((req.full_url, json.loads((req.data or b"{}").decode())))
        return _CiredResp()

    def _mock_graphql_rollup_red(query, variables):
        """Return a fixture with one repo and one PR that is red on the rollup path."""
        return {
            "organization": {
                "repositories": {
                    "pageInfo": {"hasNextPage": False, "endCursor": None},
                    "nodes": [
                        {
                            "name": "test-repo",
                            "agentIssues": {"nodes": []},
                            "pullRequests": {
                                "nodes": [
                                    {
                                        "number": 1187,
                                        "isDraft": False,
                                        "updatedAt": "2026-09-01T00:00:00Z",
                                        "reviewDecision": "CHANGES_REQUESTED",
                                        "baseRefName": "goal/1162-exporter",
                                        "headRefName": "fix/test",
                                        "mergeStateStatus": "CLEAN",
                                        "labels": {"nodes": []},
                                        "reviews": {"nodes": []},
                                        "headRefOid": "abc123def",
                                        "autoMergeRequest": {"enabledAt": "2026-09-01T00:00:00Z"},
                                        "commits": {
                                            "nodes": [
                                                {
                                                    "commit": {
                                                        "committedDate": "2026-09-01T00:00:00Z",
                                                        "messageHeadline": "fix: test",
                                                        "statusCheckRollup": {"state": "FAILURE"},
                                                    }
                                                }
                                            ]
                                        },
                                    }
                                ]
                            },
                        }
                    ],
                }
            }
        }

    def _mock_gh_cired_rollup(path, token=None):
        """Mock gh() for cired rollup test: return a workflow run with run_attempt=2."""
        if "/actions/runs?" in path:
            return {
                "workflow_runs": [
                    {
                        "id": 1001,
                        "name": "CI",
                        "status": "completed",
                        "conclusion": "failure",
                        "run_number": 42,
                        "run_attempt": 2,
                        "workflow_id": 1,
                        "event": "pull_request",
                    }
                ]
            }
        return {}

    urllib.request.urlopen = _record_cired_collect
    COORDINATE_WEBHOOK_URL = "http://agent-loop.invalid/coordinate"
    globals()['graphql'] = _mock_graphql_rollup_red
    globals()['gh'] = _mock_gh_cired_rollup
    try:
        rollup_lines = []
        collect_open_prs(rollup_lines)
        # The cired dispatch must have fired with the real run_attempt=2 (not 0).
        cired_calls = [p for p in cired_collect_posted
                       if p[0] == "http://agent-loop.invalid/coordinate"]
        assert len(cired_calls) >= 1, \
            f"cired dispatch must fire for red rollup PR; got {cired_collect_posted}"
        # The dedup key includes run_attempt=2, so the same call again would dedup.
        # Verify the dispatch happened by checking _cired_dispatched.
        assert ("test-repo", "1187", "abc123def", 2) in _cired_dispatched, \
            f"cired dedup key must include run_attempt=2; got {_cired_dispatched}"
        # Regression: run_attempt=0 must NOT be in the dedup set (the real value is 2).
        assert ("test-repo", "1187", "abc123def", 0) not in _cired_dispatched, \
            "run_attempt=0 must NOT be used when the real value is 2"
    finally:
        globals()['graphql'] = saved_graphql_cired if saved_graphql_cired else (globals().pop('graphql', None) or None)
        globals()['gh'] = saved_gh_cired
        _open_prs_prev.clear()
        _open_prs_prev.update(saved_open_prs_prev_cired)
        _AGENT_ISSUE_NUMBERS.clear()
        _GOAL_TREES.clear()
        _cired_dispatched.clear()

    # Test 3: REST-fallback path in collect_open_prs — null statusCheckRollup (private repo)
    # triggers ci_state_from_runs which returns the real run_attempt.
    saved_graphql_cired_fb = globals().get('graphql')
    saved_gh_cired_fb = globals()['gh']
    saved_open_prs_prev_cired_fb = dict(_open_prs_prev)
    _open_prs_prev.clear()
    _cired_dispatched.clear()
    _AGENT_ISSUE_NUMBERS.clear()
    _GOAL_TREES.clear()
    cired_fb_posted = []

    def _record_cired_fb(req, timeout=None):
        cired_fb_posted.append((req.full_url, json.loads((req.data or b"{}").decode())))
        return _CiredResp()

    def _mock_graphql_no_rollup(query, variables):
        """Return a fixture with one repo and one PR with null statusCheckRollup (private repo)."""
        return {
            "organization": {
                "repositories": {
                    "pageInfo": {"hasNextPage": False, "endCursor": None},
                    "nodes": [
                        {
                            "name": "private-repo",
                            "agentIssues": {"nodes": []},
                            "pullRequests": {
                                "nodes": [
                                    {
                                        "number": 42,
                                        "isDraft": False,
                                        "updatedAt": "2026-09-01T00:00:00Z",
                                        "reviewDecision": "APPROVED",
                                        "baseRefName": "main",
                                        "headRefName": "fix/private",
                                        "mergeStateStatus": "CLEAN",
                                        "labels": {"nodes": []},
                                        "reviews": {"nodes": []},
                                        "headRefOid": "f00df00d",
                                        "autoMergeRequest": {"enabledAt": "2026-09-01T00:00:00Z"},
                                        "commits": {
                                            "nodes": [
                                                {
                                                    "commit": {
                                                        "committedDate": "2026-09-01T00:00:00Z",
                                                        "messageHeadline": "fix: private",
                                                        "statusCheckRollup": None,
                                                    }
                                                }
                                            ]
                                        },
                                    }
                                ]
                            },
                        }
                    ],
                }
            }
        }

    def _mock_gh_cired_fallback(path, token=None):
        """Mock gh() for cired REST-fallback test: return a workflow run with run_attempt=3."""
        if "/actions/runs?" in path:
            return {
                "workflow_runs": [
                    {
                        "id": 2001,
                        "name": "CI",
                        "status": "completed",
                        "conclusion": "failure",
                        "run_number": 7,
                        "run_attempt": 3,
                        "workflow_id": 1,
                        "event": "pull_request",
                    }
                ]
            }
        return {}

    urllib.request.urlopen = _record_cired_fb
    COORDINATE_WEBHOOK_URL = "http://agent-loop.invalid/coordinate"
    globals()['graphql'] = _mock_graphql_no_rollup
    globals()['gh'] = _mock_gh_cired_fallback
    try:
        fb_lines = []
        collect_open_prs(fb_lines)
        # The cired dispatch must have fired with the real run_attempt=3 (from REST fallback).
        assert ("private-repo", "42", "f00df00d", 3) in _cired_dispatched, \
            f"cired dedup key must include run_attempt=3 from REST fallback; got {_cired_dispatched}"
        # Regression: run_attempt=0 must NOT be in the dedup set.
        assert ("private-repo", "42", "f00df00d", 0) not in _cired_dispatched, \
            "run_attempt=0 must NOT be used when REST fallback returns 3"
    finally:
        if saved_graphql_cired_fb:
            globals()['graphql'] = saved_graphql_cired_fb
        else:
            globals().pop('graphql', None)
        globals()['gh'] = saved_gh_cired_fb
        _open_prs_prev.clear()
        _open_prs_prev.update(saved_open_prs_prev_cired_fb)
        _AGENT_ISSUE_NUMBERS.clear()
        _GOAL_TREES.clear()
        _cired_dispatched.clear()
        urllib.request.urlopen = saved_urlopen_cired

    # The poll loop accumulates and deduplicates across multiple collectors within each cycle.
    # A fixture-driven seam tests that (a) _body grows monotonically across collectors, (b) _dupes
    # counts each real duplicate exactly once per cycle (the #669 round-2 regression), and
    # (c) _last_success advances only on a fully-successful cycle. This test uses mocked collectors
    # to drive the three properties without network or threading.
    _test_poll_forever_incremental_cycles()

    # ── homelab#1405: GraphQL partial-data error classification and metrics collection ─────────────
    # Test that error messages are classified into the three classes and the counter increments.
    global _graphql_partial_total
    _graphql_partial_total.clear()

    assert _classify_graphql_error("Resource limits for this query exceeded") == "resource-limit"
    assert _classify_graphql_error("this query exceeded GitHub's GraphQL node limit") == "resource-limit"
    assert _classify_graphql_error("Resource not accessible by personal access token") == "not-accessible"
    assert _classify_graphql_error("API rate limit exceeded") == "other"
    assert _classify_graphql_error("") == "other"

    # Test that the partial-data fixture emits correctly: simulate partial data errors and
    # verify they increment the counter and are classified.
    lines = []
    _graphql_partial_total["resource-limit"] = 3
    _graphql_partial_total["not-accessible"] = 2
    _graphql_partial_total["other"] = 1
    collect_graphql_partial_stats(lines)
    body = "\n".join(lines)

    assert 'github_exporter_graphql_partial_total{class="resource-limit",owner="teststuffstash"} 3' in body, \
        "resource-limit counter must be emitted"
    assert 'github_exporter_graphql_partial_total{class="not-accessible",owner="teststuffstash"} 2' in body, \
        "not-accessible counter must be emitted"
    assert 'github_exporter_graphql_partial_total{class="other",owner="teststuffstash"} 1' in body, \
        "other counter must be emitted"

    _graphql_partial_total.clear()

    print("github-exporter self-test: OK (closing-keyword regex coverage, goal walk, budget parse, verdict, membership, "
          "fallback query, queued-age series + alert wiring, agent-goals record pins + join "
          "shape, conflict edge-trigger, queued label-transition edge-trigger, vendor status "
          "scale, job-level queue/duration metrics + caching + retry on API failure, "
          "runner-pool split + busy-slot gauge (ask-D instrument), issue "
          "lifecycle series with re-queue first-epoch rule, first-poll job-timings skip when "
          "_first_successful_poll flag is set, sentinel head-changed edge-trigger, "
          "updater behind edge-trigger (ADR-111 #743), "
          "cired edge-trigger direct coverage with real run_attempt dedup (homelab#1187), "
          "rollup-path run_attempt propagation through collect_open_prs, "
          "REST-fallback-path run_attempt propagation through collect_open_prs, "
          "GraphQL partial-data error classification and counter metrics (homelab#1405), "
          "poll_forever incremental-cycle behavior with monotonic _body growth, dedup counter "
          "per cycle, and _last_success-only-on-full-success)")
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(self_test())
    if not TOKEN:
        sys.exit("github-exporter: GITHUB_TOKEN is empty/unset — refusing to start")
    threading.Thread(target=poll_forever, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", 9504), Handler).serve_forever()
