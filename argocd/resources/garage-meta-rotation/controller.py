#!/usr/bin/env python3
"""Garage metadata rotation controller — the LOOP half of docs/garage.md §Metadata reclamation.

Runs as a CronJob every 15 min in ns garage. Stdlib only (urllib/json/ssl), talks to three APIs:
Prometheus (the trigger: is GarageDiskFillingUp firing on a METADATA volume, and on which pod),
the Garage admin API on the pods (the health gate + the post-seed table repair + convergence),
and the Kubernetes API (the rotation order = a runtime-owned ConfigMap + `delete pod`; the
verdict = the meta-rotate init container's log line). Every run pushes a heartbeat to the
pushgateway; a rotation pushes its result — the belts in prometheusrule.yaml read those.

Trigger, not cron: this polls the ALERT — a rotation happens only while the alert says a zone's
meta volume is >80 %, so cadence follows the workload's churn (ADR-114 addendum (b)).
Health gate (addendum (c)): refuse while any garage pod is not Ready or young, any node is down
or draining, any table has Merkle/insert work queued, any block resync queue is large, a
rotation is pending, or one finished less than COOLDOWN ago. One zone per run, ever.
"""
import json, os, ssl, sys, time, urllib.request, urllib.error, urllib.parse

NS = os.environ.get("NAMESPACE", "garage")
PROM = os.environ.get("PROM_URL", "http://kube-prometheus-stack-prometheus.monitoring.svc:9090")
PG = os.environ.get("PUSHGATEWAY_URL", "http://prometheus-pushgateway.monitoring.svc.cluster.local:9091")
TOKEN = os.environ.get("GARAGE_ADMIN_TOKEN", "")
STATE_CM = os.environ.get("STATE_CM", "garage-meta-rotation-state")
INIT_CONTAINER = os.environ.get("INIT_CONTAINER", "meta-rotate")
POD_SELECTOR = os.environ.get("POD_SELECTOR", "app.kubernetes.io/name=garage")
COOLDOWN = int(os.environ.get("COOLDOWN_S", "43200"))          # one zone per 12 h at most
MIN_POD_AGE = int(os.environ.get("MIN_POD_AGE_S", "600"))
RESYNC_QUEUE_MAX = int(os.environ.get("RESYNC_QUEUE_MAX", "5000"))
READY_TIMEOUT = int(os.environ.get("READY_TIMEOUT_S", "1800"))
CONVERGE_TIMEOUT = int(os.environ.get("CONVERGE_TIMEOUT_S", "3600"))
DRY_RUN = os.environ.get("DRY_RUN", "") == "1"
ALERT = os.environ.get("ALERT_NAME", "GarageDiskFillingUp")

SA = "/var/run/secrets/kubernetes.io/serviceaccount"
K8S = "https://kubernetes.default.svc"


def log(*a):
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), *a, flush=True)


# ---------------------------------------------------------------- Kubernetes
def _k8s_ctx():
    ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt")
    tok = open(f"{SA}/token").read().strip()
    return ctx, tok


def k8s(method, path, body=None, content_type="application/json", raw=False):
    ctx, tok = _k8s_ctx()
    data = None if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
    req = urllib.request.Request(K8S + path, data=data, method=method)
    req.add_header("Authorization", f"Bearer {tok}")
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", content_type)
    with urllib.request.urlopen(req, timeout=60, context=ctx) as r:
        out = r.read()
        return out.decode() if raw else (json.loads(out) if out else {})


def pods():
    sel = urllib.parse.quote(POD_SELECTOR)
    return k8s("GET", f"/api/v1/namespaces/{NS}/pods?labelSelector={sel}")["items"]


def pod_ready(p):
    return any(c.get("type") == "Ready" and c.get("status") == "True" for c in p["status"].get("conditions", []))


def pod_age_s(p):
    t = p["status"].get("startTime") or p["metadata"]["creationTimestamp"]
    return time.time() - time.mktime(time.strptime(t, "%Y-%m-%dT%H:%M:%SZ")) + time.timezone


def get_state():
    try:
        return k8s("GET", f"/api/v1/namespaces/{NS}/configmaps/{STATE_CM}").get("data", {}) or {}
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return {}
        raise


def put_state(data):
    body = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": STATE_CM, "namespace": NS,
            "annotations": {"homelab.io/owner": "garage-meta-rotation controller (runtime state, not in git)"}},
            "data": {k: str(v) for k, v in data.items()}}
    if DRY_RUN:
        log("DRY_RUN would write state", body["data"]); return
    try:
        k8s("PUT", f"/api/v1/namespaces/{NS}/configmaps/{STATE_CM}", body)
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise
        k8s("POST", f"/api/v1/namespaces/{NS}/configmaps", body)


# ------------------------------------------------------------------- Prometheus
def prom(query):
    q = urllib.parse.urlencode({"query": query})
    with urllib.request.urlopen(f"{PROM}/api/v1/query?{q}", timeout=30) as r:
        return json.loads(r.read())["data"]["result"]


def push(job, grouping, lines):
    """Best-effort pushgateway write — monitoring being down must not stop a rotation."""
    path = f"{PG}/metrics/job/{job}" + "".join(f"/{k}/{v}" for k, v in grouping.items())
    try:
        req = urllib.request.Request(path, data=("\n".join(lines) + "\n").encode(), method="POST")
        urllib.request.urlopen(req, timeout=10).read()
    except Exception as e:  # noqa: BLE001
        log("WARN pushgateway:", e)


# ------------------------------------------------------------------ Garage admin
def admin(pod_ip, method, path, body=None):
    req = urllib.request.Request(f"http://{pod_ip}:3903{path}", method=method,
                                 data=None if body is None else json.dumps(body).encode())
    req.add_header("Authorization", f"Bearer {TOKEN}")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=60) as r:
        out = r.read()
        return json.loads(out) if out else {}


def node_stats(pod_ip):
    """{node_id: {"tables": {name: stats}, "blocks": stats}} from GetNodeStatistics?node=*."""
    res = admin(pod_ip, "GET", "/v2/GetNodeStatistics?node=*")
    out = {}
    for nid, r in (res.get("success") or {}).items():
        out[nid] = {"tables": {t["tableName"]: t for t in (r.get("tableStats") or [])},
                    "blocks": r.get("blockManagerStats") or {}}
    return out, res.get("error") or {}


# --------------------------------------------------------------------- the loop
def main():
    now = int(time.time())
    push("garage_meta_rotation", {"instance": "controller"}, [f"garage_meta_rotation_controller_last_run_timestamp {now}"])

    firing = prom(f'ALERTS{{alertname="{ALERT}",alertstate="firing",volume="metadata"}}')
    targets = sorted({r["metric"].get("pod", "") for r in firing} - {""})
    if not targets:
        log("idle: no firing", ALERT, "on a metadata volume"); return 0
    log("trigger:", ALERT, "firing on", targets)

    state = get_state()
    if state.get("STATE") == "pending":
        age = now - int(state.get("STARTED_AT", "0") or 0)
        if age < CONVERGE_TIMEOUT + READY_TIMEOUT:
            log(f"refuse: rotation gen={state.get('ROTATE_GENERATION')} of {state.get('ROTATE_TARGET')} pending for {age}s"); return 0
        log(f"stale pending rotation ({age}s) — marking failed")
        state.update({"STATE": "failed", "RESULT": "stale-pending"}); put_state(state)
        push("garage_meta_rotation", {"pod": state.get("ROTATE_TARGET", "unknown")}, ["garage_meta_rotation_last_result 1"])
    last = int(state.get("FINISHED_AT", "0") or 0)
    if now - last < COOLDOWN:
        log(f"refuse: last rotation finished {now - last}s ago (< COOLDOWN {COOLDOWN}s)"); return 0

    ps = pods()
    by_name = {p["metadata"]["name"]: p for p in ps}
    for p in ps:
        if not pod_ready(p):
            log("refuse: pod not Ready:", p["metadata"]["name"]); return 0
        if pod_age_s(p) < MIN_POD_AGE:
            log("refuse: pod younger than", MIN_POD_AGE, "s:", p["metadata"]["name"]); return 0
    target = next((t for t in targets if t in by_name), None)
    if target is None:
        log("refuse: firing pods", targets, "are not garage pods", sorted(by_name)); return 1
    any_ip = by_name[target]["status"]["podIP"]

    status = admin(any_ip, "GET", "/v2/GetClusterStatus")
    nodes = status.get("nodes", [])
    for n in nodes:
        if not n.get("isUp") or n.get("draining"):
            log("refuse: node not healthy:", n.get("hostname"), n.get("id"), "isUp", n.get("isUp"), "draining", n.get("draining")); return 0
    target_id = next((n["id"] for n in nodes if n.get("hostname") == target), None)
    if not target_id:
        log("refuse: no garage node with hostname", target); return 1
    stats, errs = node_stats(any_ip)
    if errs:
        log("refuse: GetNodeStatistics errors:", errs); return 0
    for nid, s in stats.items():
        for tname, t in s["tables"].items():
            if t.get("merkleQueueLen", 0) or t.get("insertQueueLen", 0):
                log(f"refuse: node {nid} table {tname} has queued work merkle={t.get('merkleQueueLen')} insert={t.get('insertQueueLen')}"); return 0
        rq = s["blocks"].get("resyncQueueLen", 0)
        if rq > RESYNC_QUEUE_MAX:
            log(f"refuse: node {nid} block resync queue {rq} > {RESYNC_QUEUE_MAX}"); return 0
    mp = next((n.get("metadataPartition") for n in nodes if n["id"] == target_id), None) or {}
    log(f"gate passed — rotating {target} ({target_id}); meta partition avail={mp.get('available')} total={mp.get('total')}")

    gen = int(state.get("ROTATE_GENERATION", "0") or 0) + 1
    state = {"ROTATE_TARGET": target, "ROTATE_GENERATION": gen, "STATE": "pending", "STARTED_AT": now,
             "NODE_ID": target_id, "FINISHED_AT": state.get("FINISHED_AT", "0"), "RESULT": ""}
    put_state(state)
    if DRY_RUN:
        log("DRY_RUN: would delete pod", target); return 0
    old_uid = by_name[target]["metadata"]["uid"]
    k8s("DELETE", f"/api/v1/namespaces/{NS}/pods/{target}")
    log("deleted pod", target, "— waiting for the StatefulSet to recreate it")

    t0 = time.time(); p = None
    while time.time() - t0 < READY_TIMEOUT:
        time.sleep(10)
        try:
            p = k8s("GET", f"/api/v1/namespaces/{NS}/pods/{target}")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                continue
            raise
        if p["metadata"]["uid"] != old_uid and pod_ready(p):
            break
    else:
        log("FAIL: pod", target, "not Ready within", READY_TIMEOUT, "s")
        state.update({"STATE": "failed", "RESULT": "ready-timeout"}); put_state(state)
        push("garage_meta_rotation", {"pod": target}, ["garage_meta_rotation_last_result 1"]); return 1
    ready_s = int(time.time() - t0)

    logs = k8s("GET", f"/api/v1/namespaces/{NS}/pods/{target}/log?container={INIT_CONTAINER}", raw=True)
    verdict = next((l for l in logs.splitlines() if l.startswith("meta-rotate: ") and l.split()[1] in ("ROTATED", "SKIP", "ROTATE-FAIL")), "")
    log("init container said:", verdict or logs.strip().splitlines()[-1:] )
    kv = dict(x.split("=", 1) for x in verdict.split()[2:] if "=" in x) if verdict else {}
    if not verdict.startswith("meta-rotate: ROTATED"):
        state.update({"STATE": "failed", "RESULT": verdict or "no-verdict"}); put_state(state)
        push("garage_meta_rotation", {"pod": target}, ["garage_meta_rotation_last_result 1"])
        if verdict.startswith("meta-rotate: ROTATE-FAIL") and "LOST" in verdict:
            admin(p["status"]["podIP"], "POST", f"/v2/LaunchRepairOperation?node={target_id}", {"repairType": "tables"})
            log("launched native repair tables on the emptied node")
        return 1

    admin(p["status"]["podIP"], "POST", f"/v2/LaunchRepairOperation?node={target_id}", {"repairType": "tables"})
    log("launched repair tables on", target, "— waiting for convergence with its peers")
    t1 = time.time(); converged = False
    while time.time() - t1 < CONVERGE_TIMEOUT:
        time.sleep(30)
        try:
            stats, errs = node_stats(p["status"]["podIP"])
        except Exception as e:  # noqa: BLE001
            log("WARN stats:", e); continue
        me = stats.get(target_id)
        if not me or errs:
            continue
        busy = [t for t, s in me["tables"].items() if s.get("merkleQueueLen", 0) or s.get("insertQueueLen", 0)]
        behind = []
        for tname in ("object", "version", "block_ref"):
            mine = me["tables"].get(tname, {}).get("items", 0)
            peak = max(s["tables"].get(tname, {}).get("items", 0) for s in stats.values())
            if peak and mine < peak * 0.995:
                behind.append(f"{tname} {mine}/{peak}")
        if not busy and not behind:
            converged = True; break
        log("not yet:", "busy" if busy else "", busy, "behind" if behind else "", behind)
    done = int(time.time())
    result = 0 if converged else 1
    state.update({"STATE": "done" if converged else "failed", "RESULT": "converged" if converged else "converge-timeout",
                  "FINISHED_AT": done, "OLD_BYTES": kv.get("old_bytes", "0"), "NEW_BYTES": kv.get("new_bytes", "0")})
    put_state(state)
    push("garage_meta_rotation", {"pod": target}, [
        f"garage_meta_rotation_last_result {result}",
        f"garage_meta_rotation_last_success_timestamp {done if converged else 0}",
        f"garage_meta_rotation_old_bytes {kv.get('old_bytes', 0)}",
        f"garage_meta_rotation_new_bytes {kv.get('new_bytes', 0)}",
        f"garage_meta_rotation_seed_seconds {kv.get('seconds', 0)}",
        f"garage_meta_rotation_ready_seconds {ready_s}",
        f"garage_meta_rotation_converge_seconds {done - int(t1)}",
    ])
    log(("DONE" if converged else "FAIL") + f": {target} gen={gen} old_bytes={kv.get('old_bytes')} new_bytes={kv.get('new_bytes')} seed={kv.get('seconds')}s ready={ready_s}s converge={done - int(t1)}s")
    return result


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # noqa: BLE001
        log("ERROR:", repr(e)); sys.exit(2)
