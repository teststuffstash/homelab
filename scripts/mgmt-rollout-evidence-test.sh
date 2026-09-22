#!/usr/bin/env bash
# mgmt-rollout-evidence-test — the rollout's exercise predicate (scripts/mgmt-rollout-evidence.sh)
# against a FAKE kubectl, talosctl and Prometheus: the type classification from labels + history,
# each type's evidence, and the three exit codes (0 exercised / 1 not yet / 2 cannot tell) —
# including every read failure landing on 2, never on a success-shaped 0 or 1. No cluster.
#   devbox run mgmt-rollout-evidence-test   (also part of `devbox run mgmt-policy-test`)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export F="$T/f"; mkdir -p "$F"
SINCE=1790000000; export EVIDENCE_NOW=$((SINCE + 7200))
iso() { date -u -d "@$1" +%FT%TZ; }
AFTER="$(iso $((SINCE + 600)))"; BEFORE="$(iso $((SINCE - 600)))"

cat >"$T/kubectl" <<'EOF'
#!/usr/bin/env bash
a="$*"
case "$a" in
  "get node "*)                          [ -f "$F/node-fail" ] && exit 1; cat "$F/node.json" ;;
  *"get replicas.longhorn.io"*)          [ -f "$F/lh-fail" ] && exit 1; cat "$F/reps.json" ;;
  *"get volumes.longhorn.io"*)           [ -f "$F/lh-fail" ] && exit 1; cat "$F/vols.json" ;;
  *"get pod kube-apiserver-"*)           cat "$F/apiserver.json" ;;
  "--server "*"get --raw /readyz")       cat "$F/readyz" ;;
  "get pods -A --field-selector "*)      [ -f "$F/pods-fail" ] && exit 1; cat "$F/pods.json" ;;
  *) echo "fake kubectl: unexpected '$a'" >&2; exit 99 ;;
esac
EOF
cat >"$T/talosctl" <<'EOF'
#!/usr/bin/env bash
[ -f "$F/talos-fail" ] && exit 1
case "$*" in
  *"service etcd") cat "$F/etcd-service" ;;
  *"etcd status")  cat "$F/etcd-status" ;;
  *) echo "fake talosctl: unexpected '$*'" >&2; exit 99 ;;
esac
EOF
# Fake Prometheus: answers by query shape; values from $F/p.<key> (absent file = empty result).
cat >"$T/prom" <<'EOF'
#!/usr/bin/env bash
q="$1"
[ -f "$F/prom-fail" ] && { echo '{"status":"error","error":"down"}'; exit 0; }
vec() { if [ -f "$F/p.$1" ]; then printf '[{"metric":{},"value":[0,"%s"]}]' "$(cat "$F/p.$1")"; else echo '[]'; fi; }
raw() { if [ -f "$F/p.$1" ]; then cat "$F/p.$1"; else echo '[]'; fi; }
case "$q" in
  *github_exporter_last_success_timestamp*)                        r="$(vec fresh)" ;;
  "count(max_over_time(github_ci_job_completed_timestamp[1d]))")   r="$(vec family)" ;;
  "(max by (runner_name"*)                                         r="$(raw jobs)" ;;
  "count(label_replace"*)                                          r="$(vec npods)" ;;
  *EphemeralRunner*604800s*)                                       r="$(vec archist)" ;;
  *agent-.+*604800s*)                                              r="$(vec ridehist)" ;;
  *kube_pod_status_phase*)                                         r="$(raw rides)" ;;
  "count(cluster_layout_node_connected"*)                          r="$(vec zone)" ;;
  "min(min_over_time(cluster_layout_node_connected"*)              r="$(vec garage)" ;;
  *) echo "fake prom: unexpected query '$q'" >&2; exit 99 ;;
esac
printf '{"status":"success","data":{"resultType":"vector","result":%s}}\n' "$r"
EOF
chmod +x "$T/kubectl" "$T/talosctl" "$T/prom"
export EVIDENCE_KUBECTL="$T/kubectl" EVIDENCE_TALOSCTL="$T/talosctl" EVIDENCE_PROM_CMD="$T/prom"

node() {  # <labels-json>
  printf '{"kind":"Node","metadata":{"name":"n1","labels":%s},"status":{"addresses":[{"type":"InternalIP","address":"10.0.0.9"}]}}' "$1" >"$F/node.json"
}
reset() {
  rm -f "$F"/*
  node '{}'
  echo '{"items":[]}' >"$F/reps.json"; echo '{"items":[]}' >"$F/vols.json"; echo '{"items":[]}' >"$F/pods.json"
  echo 5 >"$F/p.fresh"; echo 40 >"$F/p.family"
  printf 'NODE     10.0.0.9\nID       etcd\nSTATE    Running\nHEALTH   OK\n' >"$F/etcd-service"
  printf 'NODE       MEMBER   DB SIZE   IN USE          LEADER   RAFT INDEX   LEARNER   PROTOCOL   ERRORS\n10.0.0.9   aa11     285 MB    97 MB (34.02%%)   bb22     69716715     false     3.6.14     \n' >"$F/etcd-status"
  echo '{"status":{"conditions":[{"type":"Ready","status":"True"}]}}' >"$F/apiserver.json"
  echo ok >"$F/readyz"
}
pod() {  # <name> <owner-kind|""> <scheduled-iso> <ready True|False> [phase]
  local own=""; [ -n "$2" ] && own="\"ownerReferences\":[{\"kind\":\"$2\"}],"
  jq -c --argjson p "{\"metadata\":{\"namespace\":\"ns\",\"name\":\"$1\",$own\"creationTimestamp\":\"$3\"},\"status\":{\"phase\":\"${5:-Running}\",\"conditions\":[{\"type\":\"PodScheduled\",\"lastTransitionTime\":\"$3\"},{\"type\":\"Ready\",\"status\":\"$4\"}]}}" \
    '.items += [$p]' "$F/pods.json" >"$F/pods.t" && mv "$F/pods.t" "$F/pods.json"
}
replica() {  # <node> <state> <healthyAt-iso> <volume> <robustness>
  jq -c --arg n "$1" --arg s "$2" --arg h "$3" --arg v "$4" '.items += [{spec:{nodeID:$n, healthyAt:$h, volumeName:$v}, status:{currentState:$s}}]' "$F/reps.json" >"$F/r.t" && mv "$F/r.t" "$F/reps.json"
  jq -c --arg v "$4" --arg r "$5" '.items += [{metadata:{name:$v}, status:{robustness:$r}}]' "$F/vols.json" >"$F/v.t" && mv "$F/v.t" "$F/vols.json"
}

pass=0; fail=0
case_() {  # <name> <want-rc> <want-types> [stdout-grep]
  local out rc
  out="$(bash "$HERE/mgmt-rollout-evidence.sh" "${NODE_ARG:-n1}" "${SINCE_ARG:-$SINCE}" 2>"$T/err")"; rc=$?
  if [ "$rc" = "$2" ] && [ "$(grep -c . <<<"$out")" = 1 ] && { [ "$3" = - ] || grep -qF "[$3]" <<<"$out"; } && { [ -z "${4:-}" ] || grep -qE -- "$4" <<<"$out"; }; then
    pass=$((pass+1)); echo "PASS $1 (rc=$rc) $out"
  else fail=$((fail+1)); echo "FAIL $1 — want rc=$2 types [$3]${4:+ /$4/}; got rc=$rc: $out"; sed 's/^/     /' "$T/err"; fi
}

# ── worker (no type of its own) ──
reset; pod web-1 ReplicaSet "$AFTER" True
case_ worker-exercised 0 worker 'web-1'
reset; pod ds-1 DaemonSet "$AFTER" True; pod old-1 ReplicaSet "$BEFORE" True; pod slow-1 ReplicaSet "$AFTER" False
case_ worker-daemonset-old-unready 1 worker 'NOT YET'
reset; pod job-1 Job "$AFTER" False Succeeded
case_ worker-succeeded-job 0 worker
reset; touch "$F/pods-fail"
case_ worker-pods-unreadable 2 worker 'CANNOT TELL'

# ── control plane ──
reset; node '{"node-role.kubernetes.io/control-plane":""}'
case_ cp-healthy 0 cp 'etcd voter healthy'
reset; node '{"node-role.kubernetes.io/control-plane":""}'; sed -i 's/     false     3.6.14/     true      3.6.14/' "$F/etcd-status"
case_ cp-learner 1 cp 'learner'
reset; node '{"node-role.kubernetes.io/control-plane":""}'; sed -i 's/3.6.14     $/3.6.14     alarm:NOSPACE/' "$F/etcd-status"
case_ cp-etcd-errors 1 cp 'NOSPACE'
reset; node '{"node-role.kubernetes.io/control-plane":""}'; printf 'STATE    Running\nHEALTH   Fail\n' >"$F/etcd-service"
case_ cp-etcd-unhealthy 1 cp 'Running/Fail'
reset; node '{"node-role.kubernetes.io/control-plane":""}'; echo '[-]etcd failed' >"$F/readyz"
case_ cp-apiserver-not-serving 1 cp 'readyz'
reset; node '{"node-role.kubernetes.io/control-plane":""}'; touch "$F/talos-fail"
case_ cp-talos-unreachable 2 cp 'CANNOT TELL'

# ── arc: the label is eligibility, the history makes the type ──
arc() { reset; node '{"homelab.io/ephemeral":"true"}'; echo 40 >"$F/p.archist"; echo 3 >"$F/p.npods"; }
arc; echo '[{"metric":{"runner_name":"homelab-ephemeral-x-runner-a","repo":"homelab","job":"ci","run_id":"7"},"value":[0,"1790000900"]}]' >"$F/p.jobs"
case_ arc-job-succeeded 0 arc 'homelab/ci run 7 on homelab-ephemeral-x-runner-a'
arc
case_ arc-no-job 1 arc '3 runner pod'
arc; echo 3600 >"$F/p.fresh"
case_ arc-exporter-stale 2 arc 'last full poll'
arc; rm -f "$F/p.family"
case_ arc-no-completion-series 2 arc 'job-completion series'
arc; rm -f "$F/p.fresh"
case_ arc-exporter-absent 2 arc 'job-completion series'
reset; node '{"homelab.io/ephemeral":"true"}'; echo 2 >"$F/p.archist"; pod web-1 ReplicaSet "$AFTER" True
case_ arc-label-without-history 0 worker
reset; echo 40 >"$F/p.archist"; pod web-1 ReplicaSet "$AFTER" True
case_ arc-history-without-label 0 worker

# ── ride ──
reset; echo 30 >"$F/p.ridehist"; echo '[{"metric":{"namespace":"oracle-fleet","pod":"agent-oracle-fleet-issue-9-r1"},"value":[0,"1"]}]' >"$F/p.rides"
case_ ride-succeeded 0 ride 'agent-oracle-fleet-issue-9-r1'
reset; echo 30 >"$F/p.ridehist"
case_ ride-none-yet 1 ride 'no ride'
# several types: ALL must hold — a ride alone does not end an arc+ride node's soak
arc; echo 30 >"$F/p.ridehist"; echo '[{"metric":{"namespace":"x","pod":"agent-x-1"},"value":[0,"1"]}]' >"$F/p.rides"
case_ arc-ride-half 1 arc,ride 'arc: NOT YET'

# ── storage: longhorn + garage ──
reset; replica n1 running "$AFTER" pvc-a healthy; replica other running "$AFTER" pvc-b healthy
case_ longhorn-rebuilt 0 longhorn 'pvc-a'
reset; replica n1 running "$BEFORE" pvc-a healthy
case_ longhorn-not-since 1 longhorn 'NOT YET'
reset; replica n1 running "$AFTER" pvc-a degraded; replica n1 stopped "$AFTER" pvc-c healthy
case_ longhorn-degraded-or-stopped 1 longhorn 'NOT YET'
reset; touch "$F/lh-fail"; pod web-1 ReplicaSet "$AFTER" True
case_ longhorn-unreadable 2 worker 'cannot list Longhorn'
reset; echo 3 >"$F/p.zone"; echo 1 >"$F/p.garage"; replica n1 running "$AFTER" pvc-a healthy
case_ garage-and-longhorn 0 longhorn,garage 'zone n1 connected'
reset; echo 3 >"$F/p.zone"; echo 0 >"$F/p.garage"
case_ garage-disconnected 1 garage 'min=0'

# ── inputs and reads ──
reset; touch "$F/node-fail"
case_ node-unreadable 2 '?' 'kubectl get node'
reset; touch "$F/prom-fail"; pod web-1 ReplicaSet "$AFTER" True
case_ prometheus-down 2 worker 'CANNOT TELL'
reset; SINCE_ARG=notanumber case_ bad-since 2 - 'usage'
reset; SINCE_ARG=$((EVIDENCE_NOW + 60)) case_ future-since 2 - 'usage'

echo "mgmt-rollout-evidence-test: PASS $pass/$((pass+fail))"
[ $fail = 0 ]
