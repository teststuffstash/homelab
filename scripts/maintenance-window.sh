#!/usr/bin/env bash
# maintenance-window — the mechanical half of the /maintenance-window skill.
#
#   bash scripts/maintenance-window.sh open  --reason "<what you are doing>" [--alerts A,B,C] [--hours N] [--node <n>]
#   bash scripts/maintenance-window.sh check
#   bash scripts/maintenance-window.sh close
#
# WHY. `agents/seat-window.sh` declares a window to the responder and `node-maintenance.sh`
# opens the Alertmanager silences — both only ever wired for NODE maintenance. Everything else
# the seat does to live infrastructure (a tofu apply, a talosctl patch, a rollout restart, an
# upgrade) had neither, and no before/after comparison at all. On 2026-09-20 a control-plane
# config apply took the cluster's control plane down and the SEAT did not notice: the operator
# did, from Alertmanager, while the session reported success. Nodes stayed `Ready` throughout.
#
# So this does the one thing a human cannot do reliably by eye: it SNAPSHOTS the cluster's
# health signals before the change and DIFFS them afterwards. `check` is the gate — run it
# during and after, and treat any new firing alert as a stop signal, not a footnote.
#
# The checks are the paid lessons of that day, in order of what actually broke:
#   1. firing alert names  — new names since baseline
#   2. sum(up)             — scrape targets lost (48 -> 0 went unnoticed for ~30 min)
#   3. cilium k8s backend  — EVERY apiserver restart drops the 10.96.0.1:443 backend on every
#                            node and Cilium does NOT re-sync it; pods then get "connection
#                            refused" to the API while nodes still read Ready. Seen twice.
#   4. non-Running pods    — controllers crashlooping on a broken API path
#   5. stranded CI         — ARC listeners restart during cluster work and do not re-claim jobs
#                            queued during the gap; they sit in `queued` forever (CiDispatchStalled)
set -euo pipefail

ROOT="${DEVBOX_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
STATE_DIR="${MAINT_STATE_DIR:-$HOME/.claude/maintenance-window}"
BASE="$STATE_DIR/baseline.json"
PROM="${PROM_URL:-http://192.168.40.13:9090}"
export KUBECONFIG="${KUBECONFIG:-$ROOT/tofu/kubeconfig}"
export TALOSCONFIG="${TALOSCONFIG:-$ROOT/tofu/talosconfig}"

# FAIL LOUDLY on a missing kubeconfig. Caught building this script: run from a git worktree, ROOT
# had no tofu/kubeconfig (gitignored, so a fresh worktree lacks it), kubectl fell through to
# localhost:8080, and `open` recorded a cheerful baseline of nodes=0, cilium_backends=0/0 —
# a check that passes because it measured NOTHING. That is precisely the failure class this
# script exists to prevent, so it refuses instead of guessing.
[ -r "$KUBECONFIG" ] || {
  echo "maintenance-window: no readable kubeconfig at $KUBECONFIG" >&2
  echo "  set KUBECONFIG=/path/to/tofu/kubeconfig (a worktree does not have one — use the main checkout)" >&2
  exit 1
}
# The repos whose CI can be stranded by cluster work. Override for a wider sweep.
MAINT_REPOS="${MAINT_REPOS:-homelab oracle-fleet oracle-iac sleep-tracking snore-recorder sleep-iac}"

# The classes a maintenance window structurally produces. Same default as node-maintenance.sh's
# DECLARED_ALERTS plus the control-plane names the 2026-09-20 apply produced.
DEFAULT_ALERTS="KubeAPIDown,KubeletInstanceUnreachable,KubeNodeNotReady,KubeNodeUnreachable,KubePodNotReady,KubeSchedulerInstanceUnreachable,KubeControllerManagerInstanceUnreachable,KubeAggregatedAPIDown,KubeDeploymentReplicasMismatch,KubeDaemonSetRolloutStuck,KubeDaemonSetMisScheduled,CiliumUnreachableNodes,CiliumAgentScrapeDown,TargetDown"

q() { curl -s --max-time 20 --data-urlencode "query=$1" "$PROM/api/v1/query" 2>/dev/null; }
firing() { curl -s --max-time 20 "$PROM/api/v1/alerts" 2>/dev/null | jq -r '[.data.alerts[]|select(.state=="firing")|.labels.alertname]|unique'; }
targets_up() { q 'sum(up)' | jq -r '.data.result[0].value[1] // "0"'; }
# Only HARD-failed pods. Deliberately not "everything that is not Running": a cluster with an
# agent loop in it always has pods in ContainerCreating/Init/Pending, and a gate that cries wolf
# on normal churn is a gate people stop reading. The states below do not clear on their own.
POD_BAD_STATES='CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerError|InvalidImageName|^Error$|Init:Error|Init:CrashLoopBackOff'
pods_bad_list() { kubectl get pods -A --no-headers 2>/dev/null | awk -v re="$POD_BAD_STATES" '$4 ~ re {print $1"/"$2" ("$4")"}'; }
pods_bad() { pods_bad_list | wc -l | tr -d ' '; }
node_count() { kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' '; }

# How many cilium agents still hold a backend for the in-cluster apiserver Service.
# Prints "<have> <missing> <unknown>". The three-way split is deliberate: a `kubectl exec` into a
# cilium agent fails intermittently, and counting a flaky exec as "backend missing" produced a
# false ⚠ the first time this ran. An unreliable gate is a gate that gets ignored, so "could not
# tell" is reported as itself and never as a failure. Each agent gets two attempts.
cilium_backends() {
  local have=0 missing=0 unknown=0 p out ok
  for p in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name 2>/dev/null); do
    ok=0; out=""
    for _ in 1 2; do
      if out="$(kubectl -n kube-system exec -i "$p" -c cilium-agent -- cilium-dbg service list 2>/dev/null)" \
         && [ -n "$out" ]; then ok=1; break; fi
      sleep 1
    done
    if [ "$ok" -ne 1 ]; then unknown=$((unknown+1)); continue; fi
    if awk '$2=="10.96.0.1:443/TCP"' <<<"$out" | grep -q '=>'; then have=$((have+1)); else missing=$((missing+1)); fi
  done
  echo "$have $missing $unknown"
}

# Runs stuck in `queued` for longer than the grace period — the ARC-stranded class.
stranded_ci() {
  local grace="${1:-600}" now r out
  now="$(date -u +%s)"
  for r in $MAINT_REPOS; do
    out="$(gh run list --repo "teststuffstash/$r" --limit 30 \
            --json status,createdAt,databaseId,name,headBranch \
            -q '.[]|select(.status=="queued")|"\(.createdAt) \(.databaseId) \(.name) [\(.headBranch)]"' 2>/dev/null || true)"
    [ -n "$out" ] || continue
    while read -r line; do
      [ -n "$line" ] || continue
      local ts age
      ts="$(date -u -d "${line%% *}" +%s 2>/dev/null)" || continue
      age=$(( now - ts ))
      [ "$age" -gt "$grace" ] && echo "  $r $line (queued ${age}s)"
    done <<EOF
$out
EOF
  done
}

snapshot() {
  # A zero node count means kubectl answered nothing useful — refuse rather than bank an empty
  # baseline that every later `check` would compare favourably against.
  local n; n="$(node_count)"
  [ "${n:-0}" -gt 0 ] || { echo "maintenance-window: kubectl returned 0 nodes — refusing to snapshot" >&2; exit 1; }
  local cil; cil="$(cilium_backends)"
  jq -n --argjson alerts "$(firing)" \
        --arg up "$(targets_up)" --arg pods "$(pods_bad)" \
        --arg have "${cil%% *}" --arg missing "$(cut -d' ' -f2 <<<"$cil")" \
        --arg unknown "${cil##* }" --arg nodes "$n" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{at:$at, alerts:$alerts, up:($up|tonumber), pods_bad:($pods|tonumber),
          cilium_have:($have|tonumber), cilium_missing:($missing|tonumber),
          cilium_unknown:($unknown|tonumber), nodes:($nodes|tonumber)}'
}

cmd_open() {
  local reason="" alerts="$DEFAULT_ALERTS" hours=2 node=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) reason="$2"; shift 2 ;;
      --alerts) alerts="$2"; shift 2 ;;
      --hours)  hours="$2";  shift 2 ;;
      --node)   node="$2";   shift 2 ;;
      *) echo "unknown arg: $1" >&2; exit 64 ;;
    esac
  done
  [ -n "$reason" ] || { echo "open: --reason is required (it is what the responder reads)" >&2; exit 64; }
  mkdir -p "$STATE_DIR"
  echo "== baseline =="
  snapshot | tee "$BASE" | jq -r '"  at=\(.at) targets_up=\(.up) alerts=\(.alerts|length) hard_failed_pods=\(.pods_bad) cilium[have=\(.cilium_have) missing=\(.cilium_missing) unknown=\(.cilium_unknown)] nodes=\(.nodes)"'
  local args=(open --reason "$reason" --alerts "$alerts" --hours "$hours"
              --note "opened by scripts/maintenance-window.sh; baseline in $BASE")
  [ -n "$node" ] && args+=(--node "$node")
  bash "$ROOT/agents/seat-window.sh" "${args[@]}"
}

cmd_check() {
  [ -f "$BASE" ] || { echo "check: no baseline — run 'open' first" >&2; exit 1; }
  local b; b="$(cat "$BASE")"
  local now; now="$(snapshot)"
  local rc=0
  echo "== check vs baseline ($(jq -r .at <<<"$b")) =="

  local new; new="$(jq -r --argjson b "$b" '[.alerts[]|select(. as $a | ($b.alerts|index($a))|not)]|join(", ")' <<<"$now")"
  if [ -n "$new" ]; then echo "  ⚠ NEW firing alerts: $new"; rc=2; else echo "  ok  no new firing alerts"; fi

  local u0 u1; u0="$(jq -r .up <<<"$b")"; u1="$(jq -r .up <<<"$now")"
  if [ "$(printf '%.0f' "$u1")" -lt "$(printf '%.0f' "$u0")" ]; then
    echo "  ⚠ scrape targets DOWN: $u0 -> $u1"; rc=2
  else echo "  ok  scrape targets: $u0 -> $u1"; fi

  local ch cm cu; ch="$(jq -r .cilium_have <<<"$now")"; cm="$(jq -r .cilium_missing <<<"$now")"; cu="$(jq -r .cilium_unknown <<<"$now")"
  if [ "$cm" -gt 0 ]; then
    echo "  ⚠ cilium: $cm agent(s) have NO backend for 10.96.0.1:443 (have=$ch unknown=$cu)"
    echo "       → pods get 'connection refused' to the API. Fix: kubectl -n kube-system rollout restart ds/cilium"
    rc=2
  else
    echo "  ok  cilium apiserver backend: have=$ch missing=0 unknown=$cu"
    [ "$cu" -gt 0 ] && echo "       (unknown = exec did not answer twice; re-run check rather than acting on it)"
  fi

  local p0 p1; p0="$(jq -r .pods_bad <<<"$b")"; p1="$(jq -r .pods_bad <<<"$now")"
  if [ "$p1" -gt "$p0" ]; then
    echo "  ⚠ hard-failed pods: $p0 -> $p1"
    pods_bad_list | sed 's/^/       /'
    rc=2
  else echo "  ok  hard-failed pods: $p0 -> $p1"; fi

  local ci; ci="$(stranded_ci 600)"
  if [ -n "$ci" ]; then
    echo "  ⚠ CI runs stranded in queued (ARC listeners do not re-claim across a restart):"
    echo "$ci"
    echo "       → gh run cancel <id> --repo teststuffstash/<r>; wait for completed/cancelled; gh run rerun <id>"
    rc=2
  else echo "  ok  no CI runs stranded in queued"; fi

  return $rc
}

cmd_close() {
  echo "== final check =="
  local rc=0; cmd_check || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo
    echo "REFUSING to close: the cluster is not back to baseline. Fix the ⚠ lines above, re-run"
    echo "check, and close only when it is clean (or close --force if you are deliberately"
    echo "leaving a known-open item, and SAY SO)."
    [ "${FORCE:-0}" = 1 ] || return "$rc"
  fi
  bash "$ROOT/agents/seat-window.sh" close --all
  rm -f "$BASE"
}

case "${1:-}" in
  open)  shift; cmd_open "$@" ;;
  check) shift; cmd_check ;;
  close) shift; [ "${1:-}" = "--force" ] && FORCE=1; cmd_close ;;
  *) echo "usage: maintenance-window.sh open --reason <s> [--alerts A,B] [--hours N] [--node n] | check | close [--force]" >&2; exit 64 ;;
esac
