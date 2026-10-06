#!/usr/bin/env python3
"""chart-revert — the chart-pin revert receiver, OUTSIDE Argo Workflows' dependency cone.

The deterministic revert chain (agents/coordinator/deploy-revert-argo.yaml: one Argo Events
Sensor + four WorkflowTemplates) RUNS ON Argo Workflows, so a chart bump that breaks the Argo
controller also breaks the chain that would revert it (docs/dependency-upgrades.md §4 Rollout,
the dependency-cone rule). This receiver is the chain's shape re-hosted as a plain Deployment:
Alertmanager POSTs `ArgoControllerSilent` here directly (receiver `chart-revert`, route with
`continue: true` so the responder still sees the alert), and the revert logic — candidate query,
pin-only predicate, branch-name ledger, preemptive-auth clone, `git revert --no-edit`, the
`automerge`+`dependencies` PR the renovate-approve reflex approves — runs in this pod on the
chain's own image and credential (the `coordinator-git` Secret in agent-coordinator, mounted as a
file: the token lives ~1h and ESO refreshes it, so every run RE-READS the file, never an env
snapshot). Design: docs/designs/fu-1990-workflow-pin-revert.md Part 4. Operator ruling 2026-10-05
(after the seat's read of PR #2254): argo-workflows chart majors merge on their own the way
terraform provider majors do (ADR-141 as amended 2026-10-04) — a detector (`ArgoControllerSilent`,
step 1) + this revert actor (step 2) behind them.

Runs from a ConfigMap (the repo's DIY pattern — github-exporter, openrouter-proxy; kustomize's
configMapGenerator hash rolls the pod on edits). The operator flagged ConfigMap-shipped scripts as
an IMAGE candidate; at ~10 KiB this one is accepted here as is. Stdlib only; `git` and `gh` come
from the image (ghcr.io/teststuffstash/agent-coordinator — the same one the chain's templates
run; its `gh` is a wrapper that reads $GH_TOKEN_FILE per call).

HTTP (:8080):
  POST /alert    Alertmanager webhook v4 payload. Every alert with status=firing and an alertname
                 in TARGETS is QUEUED (one worker thread, serial — a clone+revert takes longer
                 than a webhook should block; Alertmanager re-POSTs on timeout and a second run is
                 made idempotent by the ledger anyway) and the request returns 200 at once.
                 Everything else is ignored, 200. Malformed JSON → 400.
                 DRILL: labels drill="true" + drill_pr=<n> (label or annotation) skips the
                 120-minute window and targets that MERGED PR — still pin-only, still ledgered.
  GET  /metrics  Prometheus text: chart_revert_alerts_total{outcome=...} (every outcome
                 pre-initialised at 0 so increase() sees the first one — the pod-admission lesson),
                 chart_revert_last_run_timestamp_seconds, chart_revert_webhooks_total{result=...}.
                 Gap G10 (the chain's report-only branch reports to nobody) is why the counter is
                 the durable report; every decision is also one JSON line on stdout (Alloy → Loki).
  GET  /healthz  200 once the server is up.

Outcomes (the `outcome` label):
  reverted      the revert PR is open, labelled automerge+dependencies and armed
  already       branch revert-chart-<sha8> exists (a racing/previous instance owns it), or master's
                pin is no longer the bumped version (already reverted or bumped again — stale alert)
  no_candidate  no merged PR in the window touched the chart file (not a rollback case —
                responder/operator lane owns it), or the alert has no target
  not_pin_only  the squash commit changed something besides `targetRevision:` (+ comments) in that
                one file — values edits, other files: outside the revert class, a human reads it
  conflict      `git revert` conflicted — never forced, nothing pushed
  error         a read failed (gh/git unreadable, no token, a drill without a merged PR): no revert
                on bad data, fail closed

Config (env): REPO_SLUG (teststuffstash/homelab), REVERT_WINDOW_MIN (120), GH_TOKEN_FILE
(/var/run/coordinator-git/GH_TOKEN; GH_TOKEN env is the fallback), WORKDIR (/work — an emptyDir;
the clone, HOME and TMPDIR live under it because the root filesystem is read-only), PORT (8080).
"""

import base64
import json
import os
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# alertname → the chart pin it guards. One home per chart: the file ArgoCD reads the pin from and
# the chart name the `reverted-charts:` memory line names (pin-only-lint reads exactly that line
# from merged `revert-chart-*` PRs — the sibling check beside (e)/(f)/(g)).
TARGETS = {
    "ArgoControllerSilent": {"file": "argocd/platform/argo-workflows.yaml", "chart": "argo-workflows"},
}
OUTCOMES = ("reverted", "already", "no_candidate", "not_pin_only", "conflict", "error")
WEBHOOK_RESULTS = ("queued", "ignored", "bad_request")
BRANCH_PREFIX = "revert-chart-"
PIN_LINE_RE = re.compile(r"^targetRevision:\s*(\S+)\s*(#.*)?$")
PR_URL_RE = re.compile(r"/pull/(\d+)\s*$")

REPO_SLUG = os.environ.get("REPO_SLUG", "teststuffstash/homelab")
REVERT_WINDOW_MIN = int(os.environ.get("REVERT_WINDOW_MIN", "120"))
GH_TOKEN_FILE = os.environ.get("GH_TOKEN_FILE", "/var/run/coordinator-git/GH_TOKEN")
WORKDIR = os.environ.get("WORKDIR", "/work")
PORT = int(os.environ.get("PORT", "8080"))


def log(**fields):
    fields.setdefault("ts", datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
    print(json.dumps(fields, sort_keys=True), flush=True)


class RunError(Exception):
    """A read or write the receiver cannot trust — maps to outcome `error`, never a revert."""


class Outcome(Exception):
    """A terminal decision reached before the revert: carries the outcome label + the reason."""

    def __init__(self, outcome, reason):
        super().__init__(reason)
        self.outcome, self.reason = outcome, reason


# ── pure functions (unit-tested; no gh, no git) ──────────────────────────────────────────────


def select_alerts(payload):
    """The firing alerts whose alertname has a target. Raises ValueError on a malformed payload."""
    if not isinstance(payload, dict) or not isinstance(payload.get("alerts"), list):
        raise ValueError("payload is not an Alertmanager webhook body ({alerts: [...]})")
    out = []
    for a in payload["alerts"]:
        if not isinstance(a, dict) or a.get("status") != "firing":
            continue
        labels = a.get("labels") or {}
        if labels.get("alertname") in TARGETS:
            out.append(a)
    return out


def drill_target(alert):
    """The PR number a drill alert names, or None for a real alert. A drill WITHOUT a usable
    drill_pr raises — it must never fall through to the time-window path."""
    labels = alert.get("labels") or {}
    if str(labels.get("drill", "")).lower() != "true":
        return None
    raw = labels.get("drill_pr") or (alert.get("annotations") or {}).get("drill_pr")
    try:
        n = int(str(raw).strip())
    except (TypeError, ValueError):
        raise RunError(f"drill alert without a numeric drill_pr (got {raw!r})")
    if n <= 0:
        raise RunError(f"drill_pr must be positive (got {n})")
    return n


def pick_candidate(prs, target_file, cutoff):
    """Newest MERGED PR at/after `cutoff` (ISO-8601 Z string) whose files include `target_file`.
    `revert-*` heads are never candidates (a revert of a revert ping-pongs). None = no candidate."""
    best = None
    for pr in prs:
        if not isinstance(pr, dict):
            continue
        head = pr.get("headRefName") or ""
        merged = pr.get("mergedAt") or ""
        oid = (pr.get("mergeCommit") or {}).get("oid") or ""
        files = [f.get("path") for f in (pr.get("files") or []) if isinstance(f, dict)]
        if head.startswith("revert-") or not oid or merged < cutoff or target_file not in files:
            continue
        if best is None or merged > best["mergedAt"]:
            best = pr
    return best


def classify_commit(files, target_file):
    """The pin-only predicate over a commit's `files` (the GitHub commits API shape: filename,
    status, patch). Returns ("pin_only", old, new) or raises Outcome(not_pin_only|error).

    Pin-only = the commit touched exactly `target_file`, and every changed line that is not a
    `#` comment is a `targetRevision:` line (#2254's diff rewrote the pin's comment block — that
    is allowed; a values edit, a blank line, any other key, any other file is not). Exactly one
    version removed and one added, and they differ. An absent patch is a read failure (fail
    closed), never 'no offending lines found'."""
    if not isinstance(files, list) or not files:
        raise RunError("commit has no files[] — cannot classify")
    names = sorted({f.get("filename", "") for f in files if isinstance(f, dict)})
    if names != [target_file]:
        raise Outcome("not_pin_only", f"commit touches {names}, not only {target_file}")
    patch = files[0].get("patch")
    if not patch or not isinstance(patch, str):
        raise RunError(f"commit's patch for {target_file} is empty/unreadable")
    removed, added, offending = [], [], []
    for line in patch.splitlines():
        if not line or line[0] not in "+-":
            continue
        content = line[1:].strip()
        if content.startswith("#"):
            continue
        m = PIN_LINE_RE.match(content)
        if not m:
            offending.append(line)
            continue
        (removed if line[0] == "-" else added).append(m.group(1))
    if offending:
        raise Outcome("not_pin_only", "changed lines outside the pin grammar: " + " | ".join(offending[:5]))
    if len(removed) != 1 or len(added) != 1:
        raise Outcome("not_pin_only", f"expected one targetRevision pair, got -{removed} +{added}")
    if removed[0] == added[0]:
        raise Outcome("not_pin_only", f"targetRevision unchanged ({added[0]}) — nothing to revert")
    return "pin_only", removed[0], added[0]


def revert_branch(sha):
    return BRANCH_PREFIX + sha[:8]


def pin_in_file(text):
    """The `targetRevision:` value of a chart Application file (one pin per file by design)."""
    pins = [m.group(1) for m in (PIN_LINE_RE.match(line.strip()) for line in text.splitlines()) if m]
    if len(pins) != 1:
        raise RunError(f"expected exactly one targetRevision in the file, found {len(pins)}")
    return pins[0]


def pr_title(chart, new, old, alertname):
    return f"revert: {chart} chart {new} → {old} ({alertname})"


def pr_body(chart, new, old, alertname, starts_at, pr_number, pr_title_text, window_min, drill):
    """The revert PR body. The LAST line is the one machine line pin-only-lint reads."""
    how = ("DRILL — the alert was synthetic and named this PR" if drill
           else f"the merge was within {window_min}m of the alert")
    return (
        f"Deterministic chart-pin rollback (ADR-141 as amended, operator ruling 2026-10-05): "
        f"**{alertname}** fired (startsAt {starts_at}) and {how}. The squash commit of #{pr_number} "
        f"changed only `targetRevision:` (+ comments) in `{TARGETS[alertname]['file']}`, so reverting "
        f"it restores chart `{chart}` {new} → {old} and ArgoCD re-syncs the previous release. "
        f"A Renovate PR that re-proposes the reverted version is refused by pin-only-lint "
        f"(the `reverted-charts:` memory) until Renovate proposes a newer one. Mechanical lane: "
        f"`automerge` + `dependencies` → the reflex approves, CI is the gate. Actor: the "
        f"`chart-revert` receiver (argocd/resources/chart-revert/, outside Argo Workflows' cone — "
        f"docs/designs/fu-1990-workflow-pin-revert.md Part 4).\n\n"
        f"**Reverted PR:** #{pr_number} — {pr_title_text}\n"
        f"**Alert:** {alertname} startsAt {starts_at}\n\n"
        f"reverted-charts: {chart}@{new}"
    )


def render_metrics(counters, webhooks, last_run):
    lines = [
        "# HELP chart_revert_alerts_total Decisions of the chart-pin revert receiver, by outcome.",
        "# TYPE chart_revert_alerts_total counter",
    ]
    for o in OUTCOMES:
        lines.append(f'chart_revert_alerts_total{{outcome="{o}"}} {counters.get(o, 0)}')
    lines += [
        "# HELP chart_revert_webhooks_total Alertmanager POSTs to /alert, by what became of them.",
        "# TYPE chart_revert_webhooks_total counter",
    ]
    for r in WEBHOOK_RESULTS:
        lines.append(f'chart_revert_webhooks_total{{result="{r}"}} {webhooks.get(r, 0)}')
    lines += [
        "# HELP chart_revert_last_run_timestamp_seconds Unix time of the last completed decision (0 = none yet).",
        "# TYPE chart_revert_last_run_timestamp_seconds gauge",
        f"chart_revert_last_run_timestamp_seconds {last_run}",
    ]
    return "\n".join(lines) + "\n"


# ── the runner (gh + git); replaced by a fake in the tests ───────────────────────────────────


class Runner:
    def run(self, cmd, cwd=None, env=None, timeout=600):
        full_env = dict(os.environ)
        full_env.update(env or {})
        p = subprocess.run(cmd, cwd=cwd, env=full_env, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr

    def read_token(self):
        try:
            with open(GH_TOKEN_FILE, encoding="utf-8") as fh:
                tok = fh.read().strip()
        except OSError:
            tok = os.environ.get("GH_TOKEN", "").strip()
        if not tok:
            raise RunError(f"no GitHub token ({GH_TOKEN_FILE} unreadable, GH_TOKEN unset) — refusing an anonymous run")
        return tok

    def read_file(self, path):
        with open(path, encoding="utf-8") as fh:
            return fh.read()

    def fresh_dir(self, path):
        """Remove a previous clone; the parent must exist (git clone creates the leaf)."""
        shutil.rmtree(path, ignore_errors=True)
        os.makedirs(os.path.dirname(path), exist_ok=True)


def gh_json(runner, args):
    rc, out, err = runner.run(["gh", *args])
    if rc != 0:
        raise RunError(f"gh {' '.join(args[:3])} failed rc={rc}: {err.strip()[:300]}")
    try:
        return json.loads(out)
    except ValueError as exc:
        raise RunError(f"gh {' '.join(args[:3])} returned non-JSON: {exc}")


def auth_header(token):
    b64 = base64.b64encode(f"x-access-token:{token}".encode()).decode()
    return f"Authorization: Basic {b64}"


def handle_alert(alert, runner, now=None, slug=REPO_SLUG, window_min=REVERT_WINDOW_MIN, workdir=WORKDIR):
    """One decision for one firing alert. Returns (outcome, reason)."""
    now = now or datetime.now(timezone.utc)
    labels = alert.get("labels") or {}
    alertname = labels.get("alertname", "")
    starts_at = alert.get("startsAt", "?")
    target = TARGETS.get(alertname)
    if not target:
        return "no_candidate", f"no target for alertname {alertname!r}"
    try:
        drill_pr = drill_target(alert)
        token = runner.read_token()
        fields = "number,title,headRefName,mergedAt,mergeCommit,files,state"
        if drill_pr:
            pr = gh_json(runner, ["pr", "view", str(drill_pr), "--repo", slug, "--json", fields])
            if pr.get("state") != "MERGED":
                raise RunError(f"drill_pr #{drill_pr} is {pr.get('state')}, not MERGED")
            files = [f.get("path") for f in pr.get("files") or []]
            if target["file"] not in files:
                raise Outcome("no_candidate", f"drill_pr #{drill_pr} does not touch {target['file']}")
            cand = pr
        else:
            cutoff = (now - timedelta(minutes=window_min)).strftime("%Y-%m-%dT%H:%M:%SZ")
            prs = gh_json(runner, ["pr", "list", "--repo", slug, "--state", "merged", "--limit", "30", "--json", fields])
            cand = pick_candidate(prs, target["file"], cutoff)
            if cand is None:
                raise Outcome("no_candidate", f"no merged PR since {cutoff} touched {target['file']} — not a rollback case")
        sha = cand["mergeCommit"]["oid"]
        number, title = cand["number"], cand.get("title", "")
        branch = revert_branch(sha)
        url = f"https://github.com/{slug}.git"
        hdr = auth_header(token)
        # Ledger: the deterministic branch name. rc 0 = exists, rc 2 = absent, anything else = unreadable.
        rc, _, err = runner.run(["git", "-c", f"http.extraHeader={hdr}", "ls-remote", "--exit-code", "--heads", url, branch])
        if rc == 0:
            raise Outcome("already", f"branch {branch} exists — #{number} @ {sha[:8]} already handled")
        if rc != 2:
            raise RunError(f"git ls-remote failed rc={rc}: {err.strip()[:200]}")
        commit = gh_json(runner, ["api", f"repos/{slug}/commits/{sha}"])
        _, old, new = classify_commit(commit.get("files"), target["file"])
        repo = os.path.join(workdir, "repo")
        runner.fresh_dir(repo)
        # Preemptive auth (homelab#1136: token-in-URL clones are anonymous-first and get throttled);
        # full history with blobs on demand — a drill PR can be days old, a fixed depth would miss it.
        rc, _, err = runner.run(["git", "clone", "-c", f"http.extraHeader={hdr}", "--filter=blob:none", url, repo])
        if rc != 0:
            raise RunError(f"git clone failed rc={rc}: {err.strip()[:200]}")
        for args in (["config", "http.extraHeader", hdr],
                     ["config", "user.name", "chart-revert (ADR-141)"],
                     ["config", "user.email", "noreply@teststuff.net"]):
            rc, _, err = runner.run(["git", *args], cwd=repo)
            if rc != 0:
                raise RunError(f"git {args[0]} failed: {err.strip()[:200]}")
        # Stale-alert guard: master must still pin the version the candidate introduced.
        current = pin_in_file(runner.read_file(os.path.join(repo, target["file"])))
        if current != new:
            raise Outcome("already", f"master pins {target['chart']} at {current}, not {new} — already reverted or bumped again")
        rc, _, err = runner.run(["git", "checkout", "-b", branch], cwd=repo)
        if rc != 0:
            raise RunError(f"git checkout -b failed: {err.strip()[:200]}")
        rc, _, err = runner.run(["git", "revert", "--no-edit", sha], cwd=repo)
        if rc != 0:
            runner.run(["git", "revert", "--abort"], cwd=repo)
            raise Outcome("conflict", f"git revert {sha[:8]} conflicted — human/coordinator lane, nothing pushed")
        rc, _, err = runner.run(["git", "push", "origin", branch], cwd=repo)
        if rc != 0:
            raise RunError(f"git push failed: {err.strip()[:200]}")
        body = pr_body(target["chart"], new, old, alertname, starts_at, number, title, window_min, bool(drill_pr))
        rc, out, err = runner.run(["gh", "pr", "create", "--repo", slug, "--base", "master", "--head", branch,
                                   "--title", pr_title(target["chart"], new, old, alertname), "--body", body], cwd=repo)
        m = PR_URL_RE.search(out or "")
        if rc != 0 or not m:
            raise RunError(f"gh pr create failed rc={rc}: {(err or out).strip()[:200]}")
        new_pr = m.group(1)
        # Labels BEFORE arming — the `labeled` event is what fires the renovate-approve reflex.
        rc, _, err = runner.run(["gh", "pr", "edit", new_pr, "--repo", slug, "--add-label", "automerge", "--add-label", "dependencies"])
        if rc != 0:
            raise RunError(f"revert PR #{new_pr} opened but NOT labelled (rc={rc}: {err.strip()[:200]}) — a human must label it")
        rc, _, err = runner.run(["gh", "pr", "merge", "--auto", "--squash", new_pr, "--repo", slug])
        if rc != 0:
            raise RunError(f"revert PR #{new_pr} labelled but NOT armed (rc={rc}: {err.strip()[:200]})")
        return "reverted", f"#{new_pr} reverts #{number} ({target['chart']} {new} → {old}) on {branch}, labelled + armed"
    except Outcome as o:
        return o.outcome, o.reason
    except RunError as e:
        return "error", str(e)
    except Exception as e:  # noqa: BLE001 — fail closed on anything unexpected, keep serving
        return "error", f"{type(e).__name__}: {e}"


# ── the server ───────────────────────────────────────────────────────────────────────────────


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.counters = {o: 0 for o in OUTCOMES}
        self.webhooks = {r: 0 for r in WEBHOOK_RESULTS}
        self.last_run = 0
        self.q = queue.Queue()

    def bump(self, table, key):
        with self.lock:
            table[key] = table.get(key, 0) + 1

    def metrics(self):
        with self.lock:
            return render_metrics(self.counters, self.webhooks, self.last_run)


STATE = State()


def worker(runner):
    while True:
        alert = STATE.q.get()
        labels = alert.get("labels") or {}
        t0 = time.time()
        outcome, reason = handle_alert(alert, runner)
        STATE.bump(STATE.counters, outcome)
        with STATE.lock:
            STATE.last_run = int(time.time())
        log(event="decision", alertname=labels.get("alertname"), outcome=outcome, reason=reason,
            drill=str(labels.get("drill", "")).lower() == "true", startsAt=alert.get("startsAt"),
            seconds=round(time.time() - t0, 1))
        STATE.q.task_done()


class Handler(BaseHTTPRequestHandler):
    server_version = "chart-revert/1"

    def _send(self, code, body, ctype="application/json"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):  # one JSON line per request instead of the stdlib's access log
        log(event="http", method=self.command, path=self.path, msg=fmt % args)

    def do_GET(self):
        if self.path == "/metrics":
            return self._send(200, STATE.metrics(), "text/plain; version=0.0.4")
        if self.path == "/healthz":
            return self._send(200, '{"ok":true}')
        self._send(404, '{"error":"not found"}')

    def do_POST(self):
        if self.path != "/alert":
            return self._send(404, '{"error":"not found"}')
        try:
            n = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(n) or b"{}")
            alerts = select_alerts(payload)
        except (ValueError, UnicodeDecodeError) as exc:
            STATE.bump(STATE.webhooks, "bad_request")
            log(event="webhook", result="bad_request", reason=str(exc)[:200])
            return self._send(400, json.dumps({"error": f"bad payload: {exc}"[:300]}))
        if not alerts:
            STATE.bump(STATE.webhooks, "ignored")
            log(event="webhook", result="ignored", alerts=len(payload.get("alerts", [])),
                names=sorted({(a.get("labels") or {}).get("alertname", "?") for a in payload["alerts"] if isinstance(a, dict)}))
            return self._send(200, '{"queued":0}')
        for a in alerts:
            STATE.q.put(a)
        STATE.bump(STATE.webhooks, "queued")
        log(event="webhook", result="queued", queued=len(alerts))
        self._send(200, json.dumps({"queued": len(alerts)}))


def main():
    for sub in ("home", "tmp"):
        os.makedirs(os.path.join(WORKDIR, sub), exist_ok=True)
    os.environ.setdefault("HOME", os.path.join(WORKDIR, "home"))
    os.environ["TMPDIR"] = os.path.join(WORKDIR, "tmp")
    os.environ.setdefault("GH_NO_UPDATE_NOTIFIER", "1")
    os.environ.setdefault("GH_PROMPT_DISABLED", "1")
    threading.Thread(target=worker, args=(Runner(),), daemon=True, name="revert-worker").start()
    log(event="start", port=PORT, repo=REPO_SLUG, window_min=REVERT_WINDOW_MIN, targets=sorted(TARGETS))
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()


if __name__ == "__main__":
    sys.exit(main())
