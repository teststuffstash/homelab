#!/usr/bin/env bash
# pg-backup-now — take a base backup of EVERY CNPG Cluster now and wait for all of them (ADR-147).
# The restore point before a risky change — a Longhorn upgrade above all: Longhorn refuses
# downgrades, so a bad upgrade is rolled back by restoring from backup (docs/postgres.md §Backups).
#
#   devbox run pg-backup-now            # Job from cronjob/pg-backup with TRIGGER=manual; exit = its verdict
#
# Same code path as the daily CronJob (argocd/resources/pg-backup/pg-backup.py), so a green here is
# also proof the daily path works. Exit 0 only when every covered Cluster completed and none is
# UNCOVERED; the Job's log (printed) names each Cluster's result.
set -euo pipefail
cd "$(dirname "$0")/.."
export NIX_CONFIG="experimental-features = nix-command flakes" DEVBOX_QUIET=1
k() { devbox run --quiet -- kubectl --kubeconfig "${KUBECONFIG:-$PWD/tofu/kubeconfig}" "$@"; }
job="pg-backup-manual-$(date -u +%Y%m%d%H%M%S)"
k -n cnpg-system get cronjob pg-backup -o json \
  | jq --arg n "$job" '{apiVersion: "batch/v1", kind: "Job",
        metadata: {name: $n, namespace: "cnpg-system", labels: {"homelab.io/pg-backup": "manual"}},
        spec: (.spec.jobTemplate.spec
               | .template.spec.containers[0].env = [{name: "TRIGGER", value: "manual"}])}' \
  | k create -f - >/dev/null
echo "pg-backup-now: job cnpg-system/$job started — waiting (up to 90 min)" >&2
# Bounded: complete OR failed ends the wait; the Job's own activeDeadlineSeconds caps it too.
for _ in $(seq 1 540); do
  s=$(k -n cnpg-system get job "$job" -o jsonpath='{.status.succeeded}/{.status.failed}' 2>/dev/null || echo "/")
  case "$s" in 1/*|*/1) break ;; esac
  sleep 10
done
k -n cnpg-system logs "job/$job" | sed -n '/== pg-backup summary/,$p'
[ "$(k -n cnpg-system get job "$job" -o jsonpath='{.status.succeeded}')" = "1" ]
