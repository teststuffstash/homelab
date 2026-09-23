#!/usr/bin/env python3
"""Garage disruption gate — sets the `garage` PodDisruptionBudget from Garage's own signal.

docs/garage.md §Voluntary disruption. Runs as a CronJob every minute in ns garage. Stdlib only.

One question, one answer: may a Garage ZONE be taken down voluntarily right now? Prometheus holds
the answer as the recording rule `garage:disruption_allowed` (argocd/resources/garage-alerts/
prometheusrule.yaml, group garage-disruption — the threshold and its rationale live THERE, not
here). This loop only copies it onto the PDB, where every drain already looks:

    signal == 1                  -> maxUnavailable: 1   (one zone may go)
    signal == 0 / absent / error -> maxUnavailable: 0   (FAIL CLOSED: no voluntary eviction)

An eviction the PDB refuses is a drain that waits; the node-maintenance verbs turn that wait into
a clean refusal (exit 2). Pod READINESS is deliberately not this signal: after a zone returns, all
three peers carry resync backlogs at once, and a backlog-gated readiness would empty the S3
Service. Readiness says "can serve"; this says "can lose a zone".

Manual override (Prometheus down for hours, an emergency needs several windows): annotate the PDB
    garage.teststuff.net/open-until: "<RFC3339 UTC, e.g. 2026-09-22T18:00:00Z>"
and this loop holds it at 1 until then, whatever the signal (GarageDisruptionBudgetOpenAgainstSignal
fires meanwhile — that is correct, it IS open against the signal). Remove the annotation or let
it expire to hand control back. A one-off drain can instead bypass every PDB with
`kubectl drain --disable-eviction` — knowingly.
"""
import datetime, json, os, ssl, sys, time, urllib.error, urllib.parse, urllib.request

NS = os.environ.get("NAMESPACE", "garage")
PDB = os.environ.get("PDB_NAME", "garage")
PROM = os.environ.get("PROM_URL", "http://kube-prometheus-stack-prometheus.monitoring.svc:9090")
SIGNAL = os.environ.get("SIGNAL", "garage:disruption_allowed")
OVERRIDE = "garage.teststuff.net/open-until"
DRY_RUN = os.environ.get("DRY_RUN", "") == "1"

SA = "/var/run/secrets/kubernetes.io/serviceaccount"
K8S = "https://kubernetes.default.svc"


def log(*a):
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), *a, flush=True)


def k8s(method, path, body=None, content_type="application/json"):
    ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt")
    tok = open(f"{SA}/token").read().strip()
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(K8S + path, data=data, method=method)
    req.add_header("Authorization", f"Bearer {tok}")
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", content_type)
    with urllib.request.urlopen(req, timeout=30, context=ctx) as r:
        return json.loads(r.read() or b"{}")


def read_signal():
    """(value, why). value is 1 only for exactly one sample reading exactly 1; anything else is 0."""
    try:
        q = urllib.parse.urlencode({"query": SIGNAL})
        with urllib.request.urlopen(f"{PROM}/api/v1/query?{q}", timeout=20) as r:
            body = json.loads(r.read())
    except Exception as e:  # noqa: BLE001 — every read failure is the same answer: closed
        return 0, f"UNREADABLE ({e!r})"
    if body.get("status") != "success":
        return 0, f"UNREADABLE (status {body.get('status')}: {body.get('error')})"
    res = body.get("data", {}).get("result", [])
    if len(res) != 1:
        return 0, f"UNREADABLE ({len(res)} series for {SIGNAL}, want exactly 1)"
    raw = res[0].get("value", [None, None])[1]
    try:
        v = float(raw)
    except (TypeError, ValueError):
        return 0, f"UNREADABLE (value {raw!r})"
    return (1, "signal=1") if v == 1 else (0, f"signal={raw}")


def override_active(pdb):
    until = ((pdb.get("metadata") or {}).get("annotations") or {}).get(OVERRIDE)
    if not until:
        return False, ""
    try:
        t = datetime.datetime.strptime(until, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        return False, f"override annotation {until!r} is not RFC3339 UTC (YYYY-MM-DDTHH:MM:SSZ) — ignored"
    now = datetime.datetime.now(datetime.timezone.utc)
    if now < t:
        return True, f"OVERRIDE {OVERRIDE}={until} ({int((t - now).total_seconds())}s left)"
    return False, f"override {until} expired — back on the signal"


def main():
    pdb = k8s("GET", f"/apis/policy/v1/namespaces/{NS}/poddisruptionbudgets/{PDB}")
    cur = (pdb.get("spec") or {}).get("maxUnavailable")
    want, why = read_signal()
    ov, ov_why = override_active(pdb)
    if ov_why:
        log(ov_why)
    if ov:
        want = 1
    if cur == want:
        log(f"maxUnavailable={cur} already ({why}); disruptionsAllowed={(pdb.get('status') or {}).get('disruptionsAllowed')}")
        return 0
    log(f"maxUnavailable {cur} -> {want} ({why}{'; ' + ov_why if ov else ''})")
    if DRY_RUN:
        log("DRY_RUN: not patching"); return 0
    k8s("PATCH", f"/apis/policy/v1/namespaces/{NS}/poddisruptionbudgets/{PDB}",
        {"spec": {"maxUnavailable": want}}, content_type="application/merge-patch+json")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # noqa: BLE001 — a k8s read/patch failure: the gate is NOT enforced
        log("ERROR:", repr(e)); sys.exit(1)
