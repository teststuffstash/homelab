#!/usr/bin/env bash
# garage-upgrade — the two verbs around a Garage version bump: what must hold BEFORE the StatefulSet
# rolls, and what must hold AFTER. Upstream's "minor upgrade" procedure (doc/book/operations/
# upgrading.md: check the cluster's health, `garage repair --all-nodes --yes tables`, then upgrade
# nodes one by one — a bump inside one major keeps protocols and data structures), plus this
# platform's own "may a zone go now" signal and a fresh metadata snapshot as the restore point.
#
#   garage-upgrade.sh preflight [--dry-run]      # refuse (exit 1) unless a roll may start; then snapshot the
#                                                # metadata ONE NODE AT A TIME and run the table repair
#                                                # (--dry-run: checks only)
#   garage-upgrade.sh verify --to <vX.Y.Z>       # retry until every node runs <vX.Y.Z> and the store is
#                                                # healthy and writable; exit 1 at the budget's end
#   common: [--kubeconfig <path>]                # default: in-cluster ServiceAccount
#   env:    PROM_URL        Prometheus base URL; unset = through the API server's service proxy
#           CHECK_BUDGET_S  verify's ONE retry budget for all its checks (default 2400: three zones, each
#                           waits minReadySeconds)
#           REJOIN_WAIT_S   preflight: how long a node may take to rejoin after its snapshot (default 300)
#           SIGNAL_WAIT_S   preflight: how long the signal may take to reopen after the snapshots and the
#                           repair (default 1800). Each preflight wait has its OWN budget, started when the
#                           wait starts — the snapshots before it may run for an hour
#           SNAP_WAIT_S     how long one node's snapshot may take (default 900; the CLI itself gives up
#                           at 5 min while the node keeps writing — 5 m 28 s on wk-metal-01, 2026-11-13)
#
# CALLERS: the seat, by hand, around the merge of a Garage bump (docs/garage.md §Upgrading); later the
# Garage Application's PreSync / PostSync hooks — the same file, no second implementation. The roll
# itself is ArgoCD's sync of argocd/platform/garage.yaml; this script never touches the StatefulSet.
# Exit: 0 ok · 1 a check refused (named on the last line) · 2 usage or tool error.
# Tools: kubectl + jq + curl (the agent-coordinator image, the jail's devbox).
set -uo pipefail

NS="${GARAGE_NS:-garage}"
STS="${GARAGE_STS:-garage}"
POD0="${GARAGE_POD:-garage-0}"
PROM_SVC="${PROM_SVC:-monitoring/services/kube-prometheus-stack-prometheus:9090}"
SIGNAL="${SIGNAL:-garage:disruption_allowed}"
BUDGET="${CHECK_BUDGET_S:-2400}"
PROBE_MAX_AGE_S="${PROBE_MAX_AGE_S:-300}"
SNAP_WAIT_S="${SNAP_WAIT_S:-900}"
REJOIN_WAIT_S="${REJOIN_WAIT_S:-300}"
SIGNAL_WAIT_S="${SIGNAL_WAIT_S:-1800}"
KUBE=()
die() { printf 'garage-upgrade: %s\n' "$*" >&2; exit 2; }

VERB="${1:-}"; [ -n "$VERB" ] || die "usage: preflight [--dry-run] | verify --to <vX.Y.Z>"
shift
DRY=0 TO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --to) TO="${2:-}"; shift ;;
    --kubeconfig) KUBE+=(--kubeconfig "${2:-}"); shift ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

kc() { kubectl "${KUBE[@]}" "$@"; }
garage() { kc -n "$NS" exec "$POD0" -c garage -- /garage "$@" 2>/dev/null; }   # stderr is the RPC handshake chatter
# one instant query → the first sample's value, "" when the result is empty; rc 1 when the query failed
prom() {
  local q="$1" out
  if [ -n "${PROM_URL:-}" ]; then
    out="$(curl -fsS --max-time 15 "$PROM_URL/api/v1/query" --data-urlencode "query=$q")" || return 1
  else
    out="$(kc get --raw "/api/v1/namespaces/${PROM_SVC%%/*}/${PROM_SVC#*/}/proxy/api/v1/query?query=$(jq -rn --arg q "$q" '$q|@uri')")" || return 1
  fi
  printf '%s' "$out" | jq -er 'if .status == "success" then (.data.result[0].value[1] // "") else error("query failed") end'
}

# --- the checks: each prints one line of evidence on success, the reason on failure ---------------
signal_open() {
  local v; v="$(prom "$SIGNAL")" || { echo "Prometheus did not answer for $SIGNAL"; return 1; }
  [ "$v" = 1 ] || { echo "$SIGNAL is '${v:-absent}', not 1 — a zone may not go now (docs/garage.md §Voluntary disruption)"; return 1; }
  echo "$SIGNAL = 1"
}
pods_ready() {
  kc -n "$NS" get statefulset "$STS" -o json | jq -er '
    (.spec.replicas) as $n
    | if (.status.readyReplicas // 0) == $n and (.status.updatedReplicas // 0) == $n and .status.currentRevision == .status.updateRevision
      then "\($n)/\($n) ready on revision \(.status.updateRevision)"
      else "StatefulSet not settled: ready \(.status.readyReplicas // 0), updated \(.status.updatedReplicas // 0) of \($n); revisions \(.status.currentRevision) / \(.status.updateRevision)" | halt_error(1) end' 2>&1
}
# `garage status`: the HEALTHY NODES table, one row per node, version in the last column
nodes_on() {   # nodes_on <version|""> — "" = any ONE version, all nodes agreeing
  local want="$1" out healthy failed versions n
  out="$(garage status)" || { echo "garage status failed on $POD0"; return 1; }
  healthy="$(printf '%s\n' "$out" | awk '/^==== HEALTHY NODES ====/{f=1; next} /^====/{f=0} f && $1 ~ /^[0-9a-f]{16}$/ {print $NF}')"
  failed="$(printf '%s\n' "$out" | awk '/^==== FAILED NODES ====/{f=1; next} /^====/{f=0} f && $1 ~ /^[0-9a-f]{16}$/' | wc -l)"
  n="$(kc -n "$NS" get statefulset "$STS" -o jsonpath='{.spec.replicas}')" || return 1
  versions="$(printf '%s\n' "$healthy" | sort -u | tr '\n' ' ')"; versions="${versions% }"
  [ "$failed" -eq 0 ] || { echo "$failed failed node(s) in garage status"; return 1; }
  [ "$(printf '%s\n' "$healthy" | grep -c .)" -eq "$n" ] || { echo "garage status lists $(printf '%s\n' "$healthy" | grep -c .) healthy node(s), the StatefulSet has $n"; return 1; }
  case "$versions" in *" "*) echo "nodes disagree on the version: $versions"; return 1 ;; esac
  [ -z "$want" ] || [ "$versions" = "$want" ] || { echo "nodes run $versions, expected $want"; return 1; }
  echo "$n healthy nodes on $versions"
}
cluster_healthy() {
  local v; v="$(prom 'min(cluster_healthy)')" || { echo "Prometheus did not answer for cluster_healthy"; return 1; }
  [ "$v" = 1 ] || { echo "min(cluster_healthy) is '${v:-absent}' — a partition is missing a replica"; return 1; }
  echo "every partition has all replicas up"
}
writable() {
  local ok age
  ok="$(prom 'min(garage_write_probe_success)')" || { echo "Prometheus did not answer for the write probe"; return 1; }
  age="$(prom 'time() - max(garage_write_probe_last_run_timestamp)')" || return 1
  [ "$ok" = 1 ] || { echo "the write probe's last run did not succeed on every leg (min = '${ok:-absent}')"; return 1; }
  [ -n "$age" ] && [ "${age%.*}" -le "$PROBE_MAX_AGE_S" ] || { echo "the write probe last ran ${age:-?} s ago (max $PROBE_MAX_AGE_S)"; return 1; }
  echo "write probe green ${age%.*} s ago"
}

# One node's metadata snapshot, judged by the NODE, not by the CLI: `garage meta snapshot` returns
# "Timeout" after 5 min while the node finishes anyway, so a failed call is not a failed snapshot —
# the node's own log line is ("Metadata db snapshot finished", after this call's start).
snapshot_node() {   # snapshot_node <pod>
  local pod="$1" since out end
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if out="$(kc -n "$NS" exec "$pod" -c garage -- /garage meta snapshot 2>/dev/null)"; then echo "created"; return 0; fi
  end=$((SECONDS + SNAP_WAIT_S))
  while [ "$SECONDS" -lt "$end" ]; do
    if kc -n "$NS" logs "$pod" -c garage --since-time="$since" 2>/dev/null | grep -q 'Metadata db snapshot finished'; then
      echo "finished after the CLI gave up ($(printf '%s' "$out" | tr '\n' ' ' | cut -c1-80))"; return 0
    fi
    sleep 15
  done
  echo "no 'Metadata db snapshot finished' in $pod's log within ${SNAP_WAIT_S}s of $since"; return 1
}

once() {   # once <name> <fn…> — one attempt; a failure ends the run
  local name="$1" out; shift
  if out="$("$@" 2>&1)"; then echo "ok   $name — $out"; else echo "FAIL $name — $out"; echo "garage-upgrade $VERB: REFUSED at $name"; exit 1; fi
}
deadline=$((SECONDS + BUDGET))
arm() { deadline=$((SECONDS + $1)); budget_s="$1"; }   # arm <seconds> — a fresh budget for the retries that follow
budget_s="$BUDGET"
retry() {  # retry <name> <fn…> — every 20 s until the armed deadline
  local name="$1" out; shift
  while :; do
    if out="$("$@" 2>&1)"; then echo "ok   $name — $out"; return 0; fi
    if [ "$SECONDS" -ge "$deadline" ]; then echo "FAIL $name — $out"; echo "garage-upgrade $VERB: NOT confirmed at $name after ${budget_s}s"; exit 1; fi
    sleep 20
  done
}

case "$VERB" in
  preflight)
    once disruption-signal signal_open
    once statefulset-settled pods_ready
    once nodes-agree nodes_on ""
    once write-probe writable
    if [ "$DRY" = 1 ]; then echo "garage-upgrade preflight: checks hold (dry run — no repair launched, no snapshot taken)"; exit 0; fi
    # the restore point: a compacted metadata snapshot on every node, taken now (the 6 h auto snapshot
    # may be hours old) — ONE NODE AT A TIME, each rejoined before the next starts: `--all` on top of
    # the table repair made the slowest zone unreachable to its peers for ~2 min (2026-11-13 16:41Z).
    n="$(kc -n "$NS" get statefulset "$STS" -o jsonpath='{.spec.replicas}')" || { echo "FAIL meta-snapshot — could not read the StatefulSet"; exit 1; }
    for i in $(seq 0 $((n - 1))); do
      once "meta-snapshot-$STS-$i" snapshot_node "$STS-$i"
      arm "$REJOIN_WAIT_S"
      retry "nodes-agree-after-$STS-$i" nodes_on ""
    done
    # upstream's pre-step for a minor upgrade: a full sync of the metadata tables on every node
    out="$(garage repair --all-nodes --yes tables)" || { echo "FAIL repair-tables — the launch failed: $out"; echo "garage-upgrade preflight: REFUSED at repair-tables"; exit 1; }
    echo "ok   repair-tables — launched on all nodes"
    # the repair and the snapshot are load: the roll starts from the same signal they were launched on
    arm "$SIGNAL_WAIT_S"
    retry disruption-signal-after signal_open
    echo "garage-upgrade preflight: a roll may start"
    ;;
  verify)
    [[ "$TO" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "verify needs --to vX.Y.Z"
    # the target version first: before the sync starts the OLD revision reads as settled too
    retry nodes-on-target nodes_on "$TO"
    retry statefulset-settled pods_ready
    retry cluster-healthy cluster_healthy
    retry write-probe writable
    echo "garage-upgrade verify: confirmed — every node on $TO, healthy, writable"
    ;;
  *) die "unknown verb: $VERB (preflight | verify)" ;;
esac
