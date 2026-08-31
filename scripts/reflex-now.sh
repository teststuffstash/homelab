#!/usr/bin/env bash
# reflex-now.sh — manually fire one agent-loop reflex NOW. The reflexes are Argo CronWorkflows
# (ADR-093, agents/coordinator/reflexes-argo.yaml), so this is the kubectl-only equivalent of
# `argo submit --from cronworkflow/<name>` (no argo CLI in devbox): read the CronWorkflow, wrap its
# workflowSpec in a Workflow, create it. Replaces the pre-Argo `kubectl create job --from=cronjob/…`.
#
#   devbox run review-reflex-now    →  bash scripts/reflex-now.sh review-reflex
#   bash scripts/reflex-now.sh coordinate-circles circles-agents    # a PER-STACK scan
#
# ⚠ There is NO global coordinator to fire any more (ADR-120): the `coordinator-reflex` cron and
# `devbox run coordinate-now` retired 2026-08-31 — the global surface is the SWITCHBOARD (Sensor
# edge only; resolves repo-dumb rings, fans out capacity). To wake a stack, ring ITS OWN
# CronWorkflow via the second argument (`coordinate-<stack> <stack>-agents`), or
# `devbox run ring <stack>` for the webhook path.
#
# Fire ONCE and let the loop own it — NEVER poll-loop this (the reflexes' `gh … list --json` calls
# are GraphQL against the App installation's 5000/hr pool; that loop is the FU-084 burn). Typical
# use: ring the coordinator right after authoring `agent/queued` issues from the mono jail
# (workflow.md §Triggers ▸ coordinator Sensor). Stack jails have no RBAC here BY DESIGN — they get
# the `/coordinate` webhook doorbell instead (FU-085).
set -euo pipefail
NAME="${1:?usage: reflex-now.sh <cronworkflow-name> [namespace]  (review-reflex | coordinate-<stack> | janitor-<stack>)}"
NS="${2:-agent-coordinator}"
HERE="$(cd "$(dirname "$0")" && pwd)"
KUBECTL=(kubectl)
[ -f "${HERE}/../tofu/kubeconfig" ] && KUBECTL=(kubectl --kubeconfig "${HERE}/../tofu/kubeconfig")
"${KUBECTL[@]}" -n "$NS" get cronworkflow "$NAME" -o json \
  | jq --arg n "$NAME" --arg ns "$NS" '{apiVersion: "argoproj.io/v1alpha1", kind: "Workflow",
      metadata: {generateName: ($n + "-manual-"), namespace: $ns,
                 labels: {"workflows.argoproj.io/cron-workflow": $n, "manual-fire": "true"}},
      spec: .spec.workflowSpec}' \
  | "${KUBECTL[@]}" create -f -
