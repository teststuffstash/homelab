#!/usr/bin/env python3
"""The REPLAY fixtures for the rollout's workload-health hold (FU-278, scripts/mgmt-reconcile-test.sh).

Reconstructs, at instant T, the k8s-shaped dumps `node-maintenance.sh workload-health` reads
(WH_DIR) from kube-state-metrics series in Prometheus: kube_pod_info (owner, node), kube_pod_created,
kube_pod_status_phase, kube_pod_status_ready, kube_pod_container_info (image),
kube_pod_{,init_}container_status_waiting_reason / _terminated_reason, kube_replicaset_owner /
_created / _spec_replicas, kube_deployment_spec_replicas, kube_statefulset_replicas /
_status_update_revision, kube_daemonset_status_desired_number_scheduled.
Approximations: a not-Ready pod's Ready lastTransitionTime = one minute after its last Ready sample
within 2 h (else its creation); a ReplicaSet's "revision" = its creation time (orders them the same
way). pdb.json / clusters.json / agentstacks.json are NOT in KSM: they are the live objects of
2026-09-22 ~14:30Z, trimmed to selector / instances / repo names. The committed dirs keep seven
namespaces (forgejo, forgejo-runner, garage, oracle-fleet, circles, agent-coordinator, cnpg-system);
the full-fleet replay of every pre-window read that day is in the FU-278 PR's body.

    python3 gen.py 2026-09-22T12:54:45Z <outdir>     # needs Prometheus at 192.168.40.13:9090
"""
import json, sys, urllib.request, urllib.parse, datetime, os, collections
PROM = "http://192.168.40.13:9090"
T = sys.argv[1]; out = sys.argv[2]; os.makedirs(out, exist_ok=True)
def q(expr):
    u = PROM + "/api/v1/query?" + urllib.parse.urlencode({"query": expr, "time": T})
    r = json.load(urllib.request.urlopen(u, timeout=60))
    assert r["status"] == "success", r
    return r["data"]["result"]
iso = lambda s: datetime.datetime.fromtimestamp(float(s), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
pods = {}
for r in q("kube_pod_info"):
    m = r["metric"]; k = (m["namespace"], m["pod"])
    pods[k] = {"metadata": {"namespace": m["namespace"], "name": m["pod"], "labels": {},
               "ownerReferences": ([{"kind": m.get("created_by_kind"), "name": m.get("created_by_name"), "controller": True,
                                      "apiVersion": "postgresql.cnpg.io/v1" if m.get("created_by_kind") == "Cluster" else "v1"}]
                                   if m.get("created_by_kind") not in (None, "", "<none>") else [])},
               "spec": {"nodeName": m.get("node"), "containers": []},
               "status": {"phase": "Unknown", "conditions": [], "containerStatuses": [], "initContainerStatuses": []}}
for r in q("kube_pod_container_info"):
    m = r["metric"]; k = (m["namespace"], m["pod"])
    if k in pods: pods[k]["spec"]["containers"].append({"name": m["container"], "image": m.get("image", "")})
for r in q("kube_pod_created"):
    m = r["metric"]; k = (m["namespace"], m["pod"])
    if k in pods: pods[k]["metadata"]["creationTimestamp"] = iso(r["value"][1])
for r in q("kube_pod_status_phase == 1"):
    m = r["metric"]; k = (m["namespace"], m["pod"])
    if k in pods: pods[k]["status"]["phase"] = m["phase"]
# Ready + when it last changed (the lookback: 2h of 1m steps is enough for the replay window)
for r in q('kube_pod_status_ready{condition="true"}'):
    m = r["metric"]; k = (m["namespace"], m["pod"])
    if k in pods:
        st = "True" if r["value"][1] == "1" else "False"
        pods[k]["status"]["conditions"].append({"type": "Ready", "status": st})
# lastTransitionTime of Ready: the last time the value changed, from a range query
ch = q('max_over_time((timestamp(kube_pod_status_ready{condition="true"} == 1))[2h:1m])')
lastready = {(r["metric"]["namespace"], r["metric"]["pod"]): float(r["value"][1]) for r in ch}
for k, p in pods.items():
    for c in p["status"]["conditions"]:
        if c["type"] == "Ready":
            if c["status"] == "False":
                lr = lastready.get(k); cr = p["metadata"].get("creationTimestamp")
                c["lastTransitionTime"] = iso(lr + 60) if lr else cr
            else:
                c["lastTransitionTime"] = p["metadata"].get("creationTimestamp")
def cstat(metric, field, reason_key, init):
    for r in q(metric + " == 1"):
        m = r["metric"]; k = (m["namespace"], m["pod"])
        if k not in pods: continue
        lst = pods[k]["status"]["initContainerStatuses" if init else "containerStatuses"]
        e = next((x for x in lst if x["name"] == m["container"]), None)
        if not e: e = {"name": m["container"], "state": {}}; lst.append(e)
        e["state"][field] = {"reason": m[reason_key]}
cstat("kube_pod_container_status_waiting_reason", "waiting", "reason", False)
cstat("kube_pod_init_container_status_waiting_reason", "waiting", "reason", True)
cstat("kube_pod_container_status_terminated_reason", "terminated", "reason", False)
# init containers: a terminated Error that is ALSO still the current state (not running) — KSM keeps
# the last terminated reason; only count it when the init container is not running and not Completed.
running_init = {(r["metric"]["namespace"], r["metric"]["pod"], r["metric"]["container"]) for r in q("kube_pod_init_container_status_running == 1")}
for r in q('kube_pod_init_container_status_terminated_reason{reason!="Completed"} == 1'):
    m = r["metric"]; k = (m["namespace"], m["pod"])
    if k not in pods or (k + (m["container"],)) in running_init: continue
    lst = pods[k]["status"]["initContainerStatuses"]
    e = next((x for x in lst if x["name"] == m["container"]), None)
    if not e: e = {"name": m["container"], "state": {}}; lst.append(e)
    if "waiting" not in e["state"]: e["state"]["terminated"] = {"reason": m["reason"]}
# ReplicaSets: owner + the hash (name suffix) + a revision stand-in (created time orders them)
rs = {}
for r in q("kube_replicaset_owner"):
    m = r["metric"]; k = (m["namespace"], m["replicaset"])
    own = [{"kind": m["owner_kind"], "name": m["owner_name"], "controller": True}] if m.get("owner_kind") not in (None, "", "<none>") else []
    rs[k] = {"metadata": {"namespace": k[0], "name": k[1], "ownerReferences": own, "labels": {}, "annotations": {}}, "spec": {"replicas": 0}}
for r in q("kube_replicaset_spec_replicas"):
    k = (r["metric"]["namespace"], r["metric"]["replicaset"])
    if k in rs: rs[k]["spec"]["replicas"] = int(float(r["value"][1]))
for r in q("kube_replicaset_created"):
    k = (r["metric"]["namespace"], r["metric"]["replicaset"])
    if k in rs: rs[k]["metadata"]["annotations"]["deployment.kubernetes.io/revision"] = str(int(float(r["value"][1])))
for k, v in rs.items():
    own = v["metadata"]["ownerReferences"]
    if own and own[0]["kind"] == "Deployment" and k[1].startswith(own[0]["name"] + "-"):
        v["metadata"]["labels"]["pod-template-hash"] = k[1][len(own[0]["name"]) + 1:]
# pods of a Deployment's RS carry its hash; StatefulSet/DaemonSet pods their revision (none in KSM by
# default — the replay uses the workload-level revision below)
for k, p in pods.items():
    o = p["metadata"]["ownerReferences"]
    if o and o[0]["kind"] == "ReplicaSet":
        h = rs.get((k[0], o[0]["name"]), {}).get("metadata", {}).get("labels", {}).get("pod-template-hash")
        if h: p["metadata"]["labels"]["pod-template-hash"] = h
deps = [{"metadata": {"namespace": r["metric"]["namespace"], "name": r["metric"]["deployment"]}, "spec": {"replicas": int(float(r["value"][1]))}} for r in q("kube_deployment_spec_replicas")]
sts = {}
for r in q("kube_statefulset_replicas"):
    k = (r["metric"]["namespace"], r["metric"]["statefulset"]); sts[k] = {"metadata": {"namespace": k[0], "name": k[1]}, "spec": {"replicas": int(float(r["value"][1]))}, "status": {}}
for r in q("kube_statefulset_status_update_revision"):
    k = (r["metric"]["namespace"], r["metric"]["statefulset"])
    if k in sts: sts[k]["status"]["updateRevision"] = r["metric"]["revision"]
ds = [{"metadata": {"namespace": r["metric"]["namespace"], "name": r["metric"]["daemonset"]}, "status": {"desiredNumberScheduled": int(float(r["value"][1]))}} for r in q("kube_daemonset_status_desired_number_scheduled")]
w = lambda n, items: json.dump({"items": items}, open(os.path.join(out, n), "w"))
w("pods.json", list(pods.values())); w("replicasets.json", list(rs.values())); w("deployments.json", deps)
w("statefulsets.json", list(sts.values())); w("daemonsets.json", ds)
print(f"{T}: {len(pods)} pods, {len(rs)} rs, {len(deps)} deployments, {len(sts)} sts, {len(ds)} ds")
