# FU-1990 Part 2: Workflow Pin-Revert Chain — Design Document

**Date:** 2026-09-26  
**Status:** Implemented  
**Extends:** #1990 (the major-bump review lens)

## Problem

When a Renovate PR bumps a GitHub Action pin (`.github/workflows/*.yml`) and the CI fails after merge, the operator must manually:
1. Identify the failing workflow's newest merged change
2. Determine if it was a pin-only PR (every changed line is `uses: owner/repo@sha # tag`)
3. Revert the merge commit
4. Close any open Renovate PR that re-opens the same pin version (Renovate won't re-propose closed versions)
5. Create a revert PR with auto-merge

This is deterministic, mechanical work — exactly the class the platform automates.

## Solution

Extend the existing `deploy-revert-argo.yaml` machinery (FU-044's deterministic half) with a NEW trigger on `GithubWorkflowRunFailed` for master/main branch failures. The workflow checks if the newest merged PR was pin-only and reverts it if so.

## Architecture

### 1. EventSource Endpoint

**File:** `agents/coordinator/review-argo.yaml`

Added `/workflow-failed` webhook endpoint to the `agent-loop` EventSource:
```yaml
workflow-failed:
  port: "12000"
  endpoint: /workflow-failed
  method: POST
```

The EventSource Service is `agent-loop-eventsource-svc.agent-coordinator.svc.cluster.local:12000`.

### 2. Alertmanager Routing

**File:** `argocd/platform/values/kube-prometheus-stack.yaml`

Added a new receiver `deploy-pin-revert` pointing to `/workflow-failed`:
```yaml
- name: deploy-pin-revert
  webhook_configs:
    - send_resolved: false
      url: http://agent-loop-eventsource-svc.agent-coordinator.svc.cluster.local:12000/workflow-failed
```

Added a route for `GithubWorkflowRunFailed` with `continue: true` so it reaches BOTH the pin-revert chain AND the responder triage lane:
```yaml
- continue: true
  matchers:
    - alertname = "GithubWorkflowRunFailed"
  receiver: deploy-pin-revert
```

The `continue: true` is critical — it lets the alert fall through to the existing `agent-responder` route, so the triage lane ALSO sees the failure. The two paths compose:
- **deploy-pin-revert**: deterministic revert of pin-only PRs (this chain)
- **agent-responder**: triage session investigates the root cause (when not paused)

### 3. Sensor Dependency + Trigger

**File:** `agents/coordinator/deploy-revert-argo.yaml`

Added a new dependency on the `workflow-failed` event:
```yaml
- name: workflow-failed-dep
  eventSourceName: agent-loop
  eventName: workflow-failed
```

Added a new trigger that submits the `workflow-pin-revert` WorkflowTemplate:
```yaml
- rateLimit: { unit: Minute, requestsPerUnit: 4 }
  template:
    name: submit-workflow-pin-revert
    conditions: "workflow-failed-dep"
    argoWorkflow:
      operation: submit
      source:
        resource:
          apiVersion: argoproj.io/v1alpha1
          kind: Workflow
          metadata:
            generateName: workflow-pin-revert-
            namespace: agent-coordinator
          spec:
            workflowTemplateRef: { name: workflow-pin-revert }
            arguments:
              parameters:
                - name: payload
                  value: "{}"
      parameters:
        - src: { dependencyName: workflow-failed-dep, dataKey: body }
          dest: spec.arguments.parameters.0.value
```

### 4. WorkflowTemplate: `workflow-pin-revert`

**File:** `agents/coordinator/deploy-revert-argo.yaml` (appended)

The workflow logic:

#### Step 1: Parse the Alert Payload
Alertmanager POSTs a JSON payload with an `alerts[]` array. Extract the first firing alert on master/main branch:
```bash
ALERT="$(jq -c '.alerts[] | select(.status == "firing") | select(.labels.branch == "master" or .labels.branch == "main") | .labels' /tmp/alert.json | head -1)"
```

Extract: `owner`, `repo`, `workflow`, `branch`.

#### Step 2: Find the Revert Candidate
Find the newest merged PR within the revert window (default 120 minutes) whose files touch `.github/workflows/`:
```bash
gh pr list --repo "$SLUG" --state merged --limit 10 \
  --json number,title,headRefName,mergedAt,mergeCommit,files \
  --jq '[.[] | select((.headRefName | startswith("revert-")) | not) | select(.mergedAt >= $cutoff) | select(.files[]?.path | startswith(".github/workflows/"))] | sort_by(.mergedAt) | last'
```

Exclude `revert-*` branches (never revert a revert). Fail-closed: no candidate = report-only.

#### Step 3: Ledger Check
Idempotency: one revert decision per (repo, merge-sha). Keyed on the merge commit in the `responder-seen` ConfigMap:
```bash
KEY="wf-$(printf '%s' "${SLUG}-${SHA}" | sha256sum | cut -c1-16)"
```

#### Step 4: Pin-Only Predicate
Check if EVERY changed line in the diff is a `uses:` pin line (the third shape from `scripts/pin-only-lint.sh`):
```bash
PIN_LINE_RE='^[-+][[:space:]]*(- )?uses:[[:space:]]*[A-Za-z0-9-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}[[:space:]]+#[[:space:]]+v[0-9]+(\.[0-9]+){0,2}$'
```

**Fail-closed:** empty/unreadable diff = FAIL, never "no offending lines found". If any line does NOT match the regex, the PR is outside the revert class → report-only.

#### Step 5: Close Renovate PRs That Re-Open the Same Pin
Extract the removed pins (the NEW versions we're reverting FROM):
```bash
REMOVED_PINS="$(printf '%s\n' "$CONTENT_LINES" | grep '^-[^-]' | sed -E 's/.../\2/')"
```

For each removed pin, search for open Renovate PRs mentioning that pin's SHA:
```bash
gh pr list --repo "$SLUG" --state open --search "$SHORT_SHA" --json number,title,author \
  --jq '.[] | select(.author.login == "renovate[bot]") | .number'
```

Verify the PR body mentions the pin, then close it with a comment:
```bash
gh pr close "$pr" --repo "$SLUG" --comment "Closing: this pin was reverted by the workflow-pin-revert chain (FU-1990). Renovate will not re-propose a closed version."
```

**Idempotent:** closing an already-closed PR is fine.

#### Step 6: Revert the Merge Commit
Clone the repo, create a revert branch, revert the merge commit, push, create a PR with auto-merge:
```bash
BR="revert-wf-$(printf '%s' "$SHA" | cut -c1-8)"
git checkout -b "$BR"
git revert --no-edit "$SHA"
git push origin "$BR"
gh pr create --repo "$SLUG" --base master --head "$BR" \
  --title "revert: ${TITLE} (auto-rollback — workflow '$WF' failed post-merge)" \
  --body "FU-1990 deterministic rollback: ..."
gh pr merge --auto --squash "$PR" --repo "$SLUG"
```

The branch name is deterministic, so a racing instance hits `already-exists` and exits idempotently.

## Idempotency & Safety

1. **Branch name**: `revert-wf-<sha8>` — deterministic, second attempt hits already-exists
2. **Ledger**: `responder-seen` ConfigMap keyed on `wf-<repo>-<sha>` — one revert decision per (repo, merge-sha)
3. **Fail-closed**: every probe failure is loud and report-only (no revert on bad data)
4. **Pin-only predicate**: empty/unreadable diff = FAIL, never "no offending lines found"
5. **Renovate close**: idempotent (closing an already-closed PR is fine)
6. **Rate limit**: 4 requests/minute on the Sensor trigger

## Composition with Responder Lane

Alertmanager routes `GithubWorkflowRunFailed` to BOTH:
- `deploy-pin-revert` (this chain) — deterministic revert of pin-only PRs
- `agent-responder` (triage lane, when not paused) — investigates the root cause

The two paths are independent and compose:
- A revert does not prevent a triage
- A triage does not prevent a revert
- The revert stops the bleeding deterministically; the triage investigates why it broke

## Testing

The workflow can be tested by:
1. Merging a pin-only PR that bumps a GitHub Action to a broken SHA
2. Observing the CI failure on master
3. Checking the `workflow-pin-revert-*` Workflow runs in the `agent-coordinator` namespace
4. Verifying the revert PR is created and auto-merges on CI green
5. Verifying any open Renovate PR that re-opens the same pin is closed

## Future Work

- **Monitoring**: add a Prometheus alert if the revert chain fires more than N times/day (a flapping pin is a deeper problem)
- **Metrics**: export a gauge `workflow_pin_revert_total{repo, workflow}` to track revert frequency
- **Dashboard**: panel showing revert PRs over time, by repo

## References

- FU-044: the original deploy-revert chain (ArgoCD Degraded apps)
- FU-1990: the major-bump review lens (part 1)
- `scripts/pin-only-lint.sh`: the pin-only predicate (third shape)
- ADR-084: the CI-only lane (no approval gate by design)
- ADR-100: Renovate action pin doctrine
