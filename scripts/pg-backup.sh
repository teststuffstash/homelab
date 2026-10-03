#!/usr/bin/env bash
# pg-backup — the seat's verbs for the CNPG backups-by-default machinery (ADR-147, docs/postgres.md §Backups).
#
#   devbox run pg-backup-now                      # base backup of EVERY CNPG Cluster now, wait for all
#   devbox run pg-backup-wire -- <ns>/<cluster>   # wire a RUNNING cluster to its namespace's store
#
# now — the restore point before a risky change, a Longhorn upgrade above all: Longhorn refuses
#   downgrades, so a bad upgrade is rolled back by restoring. A Job from cronjob/pg-backup with
#   TRIGGER=manual — the daily code path (argocd/resources/pg-backup/pg-backup.py), backups from the
#   PRIMARY so each is restorable the moment it completes. Exit 0 only when every covered Cluster
#   completed and none is UNCOVERED.
#
# wire — the admission policy never wires a running, unwired cluster on its own: changing the
#   primary's archive_command before its pod has the plugin sidecar deadlocks the rolling update's
#   switchover (the old primary cannot archive its last WAL) while CNPG has already emptied the -rw
#   Service — a write outage until switchoverDelay (1 h; 2026-10-03: ~10 min each on grafana-pg and
#   forgejo-pg before the seat broke it). This verb annotates `homelab.io/pg-backup: wire` (the
#   policy's explicit-request condition), waits for the switchover to START, checks the old
#   primary's LSN equals the target's, and fails the old primary over at once (-rw gap ~16 s,
#   measured on infisical-pg and oracle-pg). A replica stuck in its shutdown (it waits on the same
#   archive, up to stopDelay) is restarted after 60 s. A single-instance cluster has no switchover:
#   its one pod restarts in place (wire_single). Run it inside a maintenance window.
set -euo pipefail
cd "$(dirname "$0")/.."
export NIX_CONFIG="experimental-features = nix-command flakes" DEVBOX_QUIET=1
k() { devbox run --quiet -- kubectl --kubeconfig "${KUBECONFIG:-$PWD/tofu/kubeconfig}" "$@"; }
C=cluster.postgresql.cnpg.io
log() { echo "pg-backup: $(date -u +%T) $*" >&2; }

now() {
  local job; job="pg-backup-manual-$(date -u +%Y%m%d%H%M%S)"
  k -n cnpg-system get cronjob pg-backup -o json \
    | jq --arg n "$job" '{apiVersion: "batch/v1", kind: "Job",
          metadata: {name: $n, namespace: "cnpg-system", labels: {"homelab.io/pg-backup": "manual"}},
          spec: (.spec.jobTemplate.spec
                 | .template.spec.containers[0].env = [{name: "TRIGGER", value: "manual"}])}' \
    | k create -f - >/dev/null
  log "job cnpg-system/$job started — waiting (up to 90 min)"
  for _ in $(seq 1 540); do   # bounded; the Job's activeDeadlineSeconds caps it too
    case "$(k -n cnpg-system get job "$job" -o jsonpath='{.status.succeeded}/{.status.failed}' 2>/dev/null || echo /)" in
      1/*|*/1) break ;;
    esac
    sleep 10
  done
  k -n cnpg-system logs "job/$job" | sed -n '/== pg-backup summary/,$p'
  [ "$(k -n cnpg-system get job "$job" -o jsonpath='{.status.succeeded}')" = "1" ]
}

wire() {
  local ref="${1:?usage: pg-backup.sh wire <ns>/<cluster>}" ns c old t plsn rlsn ep st i
  ns="${ref%%/*}"; c="${ref#*/}"
  old=$(k -n "$ns" get "$C" "$c" -o jsonpath='{.status.currentPrimary}')
  if k -n "$ns" get "$C" "$c" -o jsonpath='{.spec.plugins[*].name}' | grep -q barman-cloud; then
    log "$ref is already wired — nothing to do"; return 0
  fi
  log "$ref: primary $old — requesting the wire"
  k -n "$ns" annotate "$C" "$c" homelab.io/pg-backup=wire --overwrite >/dev/null
  k -n "$ns" get "$C" "$c" -o jsonpath='{.spec.plugins[*].name}' | grep -q barman-cloud \
    || { log "$ref: NOT injected — is $ns in the admission policy's list (store-$ns.yaml)?"; return 1; }
  if [ "$(k -n "$ns" get "$C" "$c" -o jsonpath='{.spec.instances}')" = "1" ]; then
    wire_single "$ns" "$c" "$ref" "$old"; return
  fi
  # Wait for CNPG to start the switchover; restart a replica stuck in its shutdown meanwhile.
  for i in $(seq 1 400); do
    t=$(k -n "$ns" get "$C" "$c" -o jsonpath='{.status.targetPrimary}')
    [ -n "$t" ] && [ "$t" != "$old" ] && break
    if [ $((i % 20)) -eq 0 ]; then
      for p in $(k -n "$ns" get pods -l "cnpg.io/cluster=$c" -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{" "}{end}'); do
        [ "$p" = "$old" ] && continue
        log "$ref: replica $p stuck terminating — restarting it (a replica holds no unique data)"
        k -n "$ns" delete pod "$p" --grace-period=10 --wait=false >/dev/null || true
      done
    fi
    sleep 3
  done
  [ -n "$t" ] && [ "$t" != "$old" ] || { log "$ref: the switchover never started — inspect"; return 1; }
  log "$ref: switchover started → $t (-rw is empty from here)"
  for i in $(seq 1 10); do
    plsn=$(k -n "$ns" exec "$old" -c postgres -- psql -tA -c "select pg_current_wal_lsn()" 2>/dev/null | tail -1)
    rlsn=$(k -n "$ns" exec "$t" -c postgres -- psql -tA -c "select pg_last_wal_replay_lsn()" 2>/dev/null | tail -1)
    [ -n "$plsn" ] && [ "$plsn" = "$rlsn" ] && break
    sleep 2
  done
  [ -n "$plsn" ] && [ "$plsn" = "$rlsn" ] \
    || { log "$ref: LSN mismatch ($old=$plsn, $t=$rlsn) — NOT failing over; -rw stays empty until you act"; return 2; }
  log "$ref: LSN equal ($plsn) — failing $old over"
  k -n "$ns" delete pod "$old" --grace-period=10 --wait=false >/dev/null
  for i in $(seq 1 100); do
    ep=$(k -n "$ns" get endpointslices -l "kubernetes.io/service-name=$c-rw" -o jsonpath='{.items[*].endpoints[*].addresses[*]}' 2>/dev/null)
    [ -n "$ep" ] && { log "$ref: -rw serving again ($ep)"; break; }
    sleep 2
  done
  for i in $(seq 1 60); do
    st=$(k -n "$ns" get "$C" "$c" -o jsonpath='{.status.phase}|{range .status.conditions[*]}{.type}={.status} {end}')
    case "$st" in "Cluster in healthy state|"*ContinuousArchiving=True*) break ;; esac
    sleep 10
  done
  k -n "$ns" annotate "$C" "$c" homelab.io/pg-backup- >/dev/null
  log "$ref: $st"
  case "$st" in "Cluster in healthy state|"*ContinuousArchiving=True*) ;; *) return 1 ;; esac
}

# A single-instance cluster has no switchover: CNPG restarts its one pod in place, and that pod's
# shutdown waits on the same impossible archive (up to stopDelay). Restart it if it hangs — the
# unarchived WAL stays on the volume and the new sidecar archives it. The outage is the restart.
wire_single() {
  local ns=$1 c=$2 ref=$3 pod=$4 st i del
  log "$ref: single instance — CNPG restarts $pod in place (no switchover to wait for)"
  for i in $(seq 1 200); do
    del=$(k -n "$ns" get pod "$pod" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || true)
    [ -n "$del" ] && break
    sleep 3
  done
  if [ -n "$del" ]; then
    for i in $(seq 1 20); do
      k -n "$ns" get pod "$pod" -o jsonpath='{.metadata.deletionTimestamp}' >/dev/null 2>&1 || break
      sleep 3
    done
    if k -n "$ns" get pod "$pod" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null | grep -q .; then
      log "$ref: $pod stuck in its shutdown after 60 s — restarting it"
      k -n "$ns" delete pod "$pod" --grace-period=10 --wait=false >/dev/null || true
    fi
  fi
  for i in $(seq 1 60); do
    st=$(k -n "$ns" get "$C" "$c" -o jsonpath='{.status.phase}|{range .status.conditions[*]}{.type}={.status} {end}')
    case "$st" in "Cluster in healthy state|"*ContinuousArchiving=True*) break ;; esac
    sleep 10
  done
  k -n "$ns" annotate "$C" "$c" homelab.io/pg-backup- >/dev/null
  log "$ref: $st"
  case "$st" in "Cluster in healthy state|"*ContinuousArchiving=True*) ;; *) return 1 ;; esac
}

case "${1:-}" in
  now) now ;;
  wire) shift; wire "$@" ;;
  *) echo "usage: $0 now | wire <ns>/<cluster>" >&2; exit 2 ;;
esac
