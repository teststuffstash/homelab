#!/usr/bin/env bash
# reflex-now.sh — manually fire one agent-loop reflex NOW. The reflexes are Argo CronWorkflows
# (ADR-093, agents/coordinator/reflexes-argo.yaml), so this is the kubectl-only equivalent of
# `argo submit --from cronworkflow/<name>` (no argo CLI in devbox): read the CronWorkflow, wrap its
# workflowSpec in a Workflow, create it. Replaces the pre-Argo `kubectl create job --from=cronjob/…`.
#
#   devbox run coordinate-now       →  bash scripts/reflex-now.sh coordinator-reflex
#   devbox run review-reflex-now    →  bash scripts/reflex-now.sh review-reflex
#   bash scripts/reflex-now.sh coordinate-circles circles-agents    # a PER-STACK scan
#
# ⚠ `coordinate-now` fires the GLOBAL scan, which SKIPS every graduated stack (FU-144) — so for a
# graduated stack it wakes a run that prints `skipped ×N` and nothing else. Ring the stack's OWN
# CronWorkflow instead, via the second argument. Measured 2026-08-06 on circles#29: a human
# labelling `agent/queued` rings nothing at all, and the issue waited 8m35s for the `*/30` cron —
# the mono-jail row in workflow.md §Triggers promised an edge that graduation had already killed.
#
# Fire ONCE and let the loop own it — NEVER poll-loop this (the reflexes' `gh … list --json` calls
# are GraphQL against the App installation's 5000/hr pool; that loop is the FU-084 burn). Typical
# use: ring the coordinator right after authoring `agent/queued` issues from the mono jail
# (workflow.md §Triggers ▸ coordinator Sensor). Stack jails have no RBAC here BY DESIGN — they get
# the `/coordinate` webhook doorbell instead (FU-085).
set -euo pipefail
NAME="${1:?usage: reflex-now.sh <cronworkflow-name> [namespace]  (coordinator-reflex | review-reflex | coordinate-<stack>)}"
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
