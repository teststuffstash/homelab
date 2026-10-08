#!/usr/bin/env python3
"""pg-backup — one base backup of EVERY CNPG Cluster, then wait for all of them (ADR-147).

Runs daily as the `pg-backup` CronJob and on demand before a risky change (the Longhorn-upgrade
restore point): `devbox run pg-backup-now` = a Job from this CronJob, same code path.

For each Cluster:
  covered    the Barman Cloud plugin is wired (the admission policy, or the Cluster's own spec), or
             an in-tree spec.backup.barmanObjectStore → create a `Backup` from the PRIMARY, wait for it
  opted out  annotated `homelab.io/pg-backup: disabled` → skipped, named in the summary
  UNCOVERED  anything else → named, and the run FAILS — a database with no backup is the alert,
             not a footnote (job-health's CronJobNotSucceeding / KubeJobFailed carry it)
Exit 1 if any backup failed or timed out, or any Cluster is uncovered.

Backup CRs are bookkeeping only (deleting one does not delete data — the ObjectStore's
retentionPolicy owns the bytes); this job prunes its own CRs older than KEEP_DAYS.
Stdlib only, in-cluster ServiceAccount auth. Transient API errors (429, 5xx, connection drops) are
retried INSIDE api() — what client-go gives every controller for free; the Job keeps backoffLimit 0,
because a pod-level re-run re-takes EVERY base backup and re-reports deterministic failures.
"""
import datetime as dt
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request

API = "https://kubernetes.default.svc"
SA = "/var/run/secrets/kubernetes.io/serviceaccount"
PLUGIN = "barman-cloud.cloudnative-pg.io"
OPT_OUT = "homelab.io/pg-backup"
TRIGGER = os.environ.get("TRIGGER", "scheduled")
TIMEOUT_S = int(os.environ.get("TIMEOUT_S", "3600"))
KEEP_DAYS = int(os.environ.get("KEEP_DAYS", "14"))

_ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt")
_token = open(f"{SA}/token").read().strip()


API_ATTEMPTS = 6  # 1+2+4+8+16 s of backoff (or the server's Retry-After) ≈ half a minute of tolerance


def api(method, path, body=None):
    """One API call, with transient failures retried: 429 (APF, or a cold watch cache — the
    apiserver answers "storage is (re)initializing" + Retry-After on the first request for a CRD
    after a restart, which failed the 2026-10-08 run), 5xx, and connection errors."""
    data = json.dumps(body).encode() if body is not None else None
    for attempt in range(1, API_ATTEMPTS + 1):
        req = urllib.request.Request(API + path, method=method, data=data)
        req.add_header("Authorization", f"Bearer {_token}")
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, context=_ctx, timeout=30) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            # A POST whose earlier attempt landed server-side despite the error: the name is
            # deterministic, so AlreadyExists on a retry means the object is there — done.
            if e.code == 409 and method == "POST" and attempt > 1:
                return json.loads(data)
            if (e.code != 429 and e.code < 500) or attempt == API_ATTEMPTS:
                raise
            ra = e.headers.get("Retry-After", "")
            wait = min(int(ra), 30) if ra.isdigit() else 2 ** (attempt - 1)
            reason = f"HTTP {e.code}"
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            if attempt == API_ATTEMPTS:
                raise
            wait = 2 ** (attempt - 1)
            reason = str(getattr(e, "reason", e))
        log(f"{method} {path}: {reason} — retry {attempt}/{API_ATTEMPTS - 1} in {wait}s")
        time.sleep(wait)


def log(msg):
    print(f"{dt.datetime.now(dt.timezone.utc):%H:%M:%SZ} {msg}", flush=True)


def method(c):
    """The backup method a Cluster is wired for, or None (uncovered)."""
    if any(p.get("name") == PLUGIN for p in c["spec"].get("plugins") or []):
        return "plugin"
    if (c["spec"].get("backup") or {}).get("barmanObjectStore"):
        return "barmanObjectStore"  # a hand-declared in-tree store (gone in CNPG 1.30) — still a backup
    return None


def main():
    now = dt.datetime.now(dt.timezone.utc)
    stamp = now.strftime("%Y%m%d%H%M")
    clusters = api("GET", "/apis/postgresql.cnpg.io/v1/clusters")["items"]
    started, skipped, uncovered = [], [], []
    for c in clusters:
        ns, name = c["metadata"]["namespace"], c["metadata"]["name"]
        ref = f"{ns}/{name}"
        if (c["metadata"].get("annotations") or {}).get(OPT_OUT) == "disabled":
            skipped.append(ref)
            continue
        m = method(c)
        if not m:
            uncovered.append(ref)
            continue
        bname = f"{name}-{TRIGGER}-{stamp}"[:63]
        body = {
            "apiVersion": "postgresql.cnpg.io/v1", "kind": "Backup",
            "metadata": {"name": bname, "namespace": ns,
                         "labels": {"homelab.io/pg-backup": TRIGGER, "cnpg.io/cluster": name}},
            # target primary, never CNPG's prefer-standby default: a primary backup's pg_backup_stop
            # WAITS for its WAL to be archived, so the backup is restorable the moment it completes
            # (the pre-upgrade restore point needs exactly that). A standby backup reported
            # "completed" 4 min before its WAL reached the store, and one taken from a standby that
            # had just rejoined after a failover was unrestorable outright (2026-10-03 drill).
            "spec": {"cluster": {"name": name}, "method": m, "target": "primary"},
        }
        if m == "plugin":
            body["spec"]["pluginConfiguration"] = {"name": PLUGIN}
        try:
            api("POST", f"/apis/postgresql.cnpg.io/v1/namespaces/{ns}/backups", body)
            started.append((ns, bname, ref))
            log(f"started {ns}/{bname}")
        except urllib.error.HTTPError as e:
            log(f"FAILED to create the Backup for {ref}: HTTP {e.code} {e.read()[:300]!r}")
            started.append((ns, None, ref))

    results = {}
    deadline = time.time() + TIMEOUT_S
    pending = [s for s in started if s[1]]
    for ns, bname, ref in started:
        if not bname:
            results[ref] = "not created"
    while pending and time.time() < deadline:
        time.sleep(15)
        still = []
        for ns, bname, ref in pending:
            st = api("GET", f"/apis/postgresql.cnpg.io/v1/namespaces/{ns}/backups/{bname}").get("status") or {}
            phase = st.get("phase", "")
            if phase == "completed":
                results[ref] = f"completed {st.get('startedAt')} → {st.get('stoppedAt')}"
                log(f"completed {ns}/{bname}")
            elif phase == "failed":
                results[ref] = f"FAILED: {st.get('error', '')[:300]}"
                log(f"FAILED {ns}/{bname}: {st.get('error', '')[:300]}")
            else:
                still.append((ns, bname, ref))
        pending = still
    for ns, bname, ref in pending:
        results[ref] = f"TIMED OUT after {TIMEOUT_S}s (still {bname} in progress)"

    # Prune this job's own Backup CRs past KEEP_DAYS (bookkeeping; the data's retention is the store's).
    cutoff = now - dt.timedelta(days=KEEP_DAYS)
    for b in api("GET", "/apis/postgresql.cnpg.io/v1/backups?labelSelector=homelab.io%2Fpg-backup")["items"]:
        made = dt.datetime.fromisoformat(b["metadata"]["creationTimestamp"].replace("Z", "+00:00"))
        if made < cutoff:
            m = b["metadata"]
            api("DELETE", f"/apis/postgresql.cnpg.io/v1/namespaces/{m['namespace']}/backups/{m['name']}")

    print("\n== pg-backup summary (trigger: %s)" % TRIGGER)
    for ref, r in sorted(results.items()):
        print(f"  {ref:40s} {r}")
    for ref in skipped:
        print(f"  {ref:40s} opted out ({OPT_OUT}: disabled)")
    for ref in uncovered:
        print(f"  {ref:40s} UNCOVERED — no backup store wired (namespace not in the pg-backup "
              f"admission policy, or a restored cluster not yet re-wired: docs/postgres.md §Backups)")
    bad = [r for r in results.values() if not r.startswith("completed")] + uncovered
    print(f"== {len(results) - len([r for r in results.values() if not r.startswith('completed')])} completed, "
          f"{len(bad)} problem(s)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
