# FU-1990 Part 2: Workflow Pin-Revert Chain — Design Document

**Date:** 2026-09-26  
**Status:** Implemented  
**Extends:** #1990 (the major-bump review lens)

## Problem

When a Renovate PR bumps a GitHub Action pin (`.github/workflows/*.yml`) and the CI fails after merge, the operator must manually:
1. Identify the failing workflow's newest merged change
2. Determine if it was a pin-only PR (every changed line is `uses: owner/repo@sha # tag`)
3. Revert the merge commit
4. Keep the same version from merging again when Renovate re-proposes it (a merged PR is not a rejected one)
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

#### Step 5: Record the Reverted Pins (the refusal happens later, in CI)
Renovate re-proposes a merged-then-reverted version on its next run — a MERGED PR is not a rejected one — and that re-opened PR does not exist yet at revert time. So the chain only RECORDS: the `+` lines of the original PR's diff (the versions reverted FROM) go into the revert PR body as one machine-readable line:
```
reverted-pins: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 docker/login-action@…
```
The refusal is `scripts/pin-only-lint.sh` check (e), which runs inside every platform repo's required `ci` (b609c1e8): it reads the `reverted-pins:` lines of the repo's merged `revert-wf-*` PRs from the last 30 days (REST, fail-closed), and an added SHA named there fails the lint — so the re-proposed PR stays RED until Renovate moves it to a newer release, on which it greens on its own. One home for the rule, and CI is the gate for both the mechanical (`automerge`) and the lens-reviewed (`major`) lane; a reflex-side close could only ever have covered the first.

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
gh pr edit "$PR" --add-label automerge --add-label dependencies   # the reflex approves this label pair
gh pr merge --auto --squash "$PR" --repo "$SLUG"
```

The platform repos require one approving review (tofu/github `protected_repos`); the `automerge` + `dependencies` labels are what make the renovate-approve reflex post it (Bot author, distinct identity), so the revert merges with no human touch. Without the labels the revert PR would sit BLOCKED — the gap the 2026-09-27 pre-drill read found.

The branch name is deterministic, so a racing instance hits `already-exists` and exits idempotently.

## Idempotency & Safety

1. **Branch name**: `revert-wf-<sha8>` — deterministic, second attempt hits already-exists
2. **Ledger**: `responder-seen` ConfigMap keyed on `wf-<repo>-<sha>` — one revert decision per (repo, merge-sha)
3. **Fail-closed**: every probe failure is loud and report-only (no revert on bad data)
4. **Pin-only predicate**: empty/unreadable diff = FAIL, never "no offending lines found"
5. **Re-proposal refusal**: `pin-only-lint` check (e), keyed on the `reverted-pins:` lines of merged `revert-wf-*` PRs (30-day window); a refused PR is red, never closed
6. **Rate limit**: 4 requests/minute on the Sensor trigger

## Composition with Responder Lane

Alertmanager routes `GithubWorkflowRunFailed` to BOTH:
- `deploy-pin-revert` (this chain) — deterministic revert of pin-only PRs
- `agent-responder` (triage lane, when not paused) — investigates the root cause

The two paths are independent and compose:
- A revert does not prevent a triage
- A triage does not prevent a revert
- The revert stops the bleeding deterministically; the triage investigates why it broke

## Testing — the drill (2026-09-27, PASSED)

Run once on agent-coordinator as the chain's own identity (`homelab-agents[bot]`), no human touch
from the bad merge to the merged revert. Record: homelab#1990 (comment of 2026-09-27) and
`agents/coordinator/TICK-LOG.md` 2026-09-27.

1. agent-coordinator#20: `actions/create-github-app-token` v1 → v1.0.0 (whose `app_id`/`private_key`
   inputs break the `deploy-pin` job), `automerge`+`dependencies`, armed → reflex approved →
   `ci` (pin-only-lint third shape) green → auto-merged 09:10Z.
2. master `build-image` failed 09:11Z → `GithubWorkflowRunFailed` 09:17:43Z → Alertmanager
   `deploy-pin-revert` → EventSource `/workflow-failed` → Sensor → `workflow-pin-revert-snrj9`.
3. **Two defects the drill found that two code reviews had passed:** the `coordinator-git` mint
   lacked `workflows: write` (the first push was refused — homelab PR#2005), and the candidate
   query `gh pr list --jq --arg cutoff …` had never worked (`gh --jq` takes only the expression;
   swallowed into "no candidate" — PR#2006, same line in the FU-044 `deploy-revert` template).
4. Re-fired from the saved payload after #2006 synced (09:33:57Z): candidate #20 found, ledger
   key written, revert **#21** opened labelled + armed with `reverted-pins:` → reflex approved
   09:35:41Z → auto-merged 09:37:17Z → master `build-image` green → alert resolved.
   **Alert → merged revert: ~3.5 minutes.**

To repeat the drill: a pin-only PR whose new SHA resolves upstream (the lint requires it) but whose
version breaks a PUSH-ONLY workflow on master; open it as the App so the whole lane is exercised;
the replay fixtures `workflow-pin-revert-candidate` / `workflow-pin-revert-merge-lane` pin the two
steps the drill found broken. Re-fire without a fresh failure: `kubectl -n agent-coordinator create`
a Workflow with `workflowTemplateRef: workflow-pin-revert` and the Alertmanager payload as the
`payload` parameter (the ledger is keyed on the merge SHA, so a handled merge is skipped).

## Part 3 — tofu Deployment image bumps: `tofu-image-revert` (2026-09-28, #1988's class row)

The same chain, third template, for the class ADR-140 (as amended) makes armable: an image tag
Renovate's terraform manager rewrites on a `kubernetes_deployment` in `tofu/` (the `docker:dind`
sidecar of the forgejo runner was the first, #2037). The [management box](../management-box.md) applies the merge
unattended (`kubernetes_deployment.*` is allowlisted), the Deployment rolls, and if the roll does
not complete the lane reverts it — no human in the loop.

| leg | pin chain (Part 2) | image chain (Part 3) |
|---|---|---|
| detector | `GithubWorkflowRunFailed` (master) | `KubeDeploymentRolloutStuck` — kube-prometheus default, `Progressing=false` for 15 m; the Deployment's `progressDeadlineSeconds` (600 s) sets the condition. With `RollingUpdate max_unavailable 0` the OLD pods keep serving while the new ReplicaSet is stuck (ImagePullBackOff, crash loop) |
| route | receiver `deploy-pin-revert` → `/workflow-failed` | receiver `deploy-rollout-revert` → `/rollout-stuck`, `continue: true` (the responder still triages) |
| candidate | newest merge ≤120 m touching `.github/workflows/` | the merges ≤180 m touching `tofu/` (wider: hourly pull + 600 s deadline + 15 m `for`) walked NEWEST-FIRST; the first whose files are all `tofu/*.tf`, whose diff passes the predicate AND whose files declare the stuck Deployment wins — a later, unrelated tofu merge or a newer bump on another Deployment never masks the bump; an unreadable diff aborts the walk (report-only) |
| predicate | every line `uses: owner/repo@sha # tag` | every line `image = "<registry/path>[:tag][@sha256:…]"` — the fourth pin shape (`scripts/pin-only-lint.sh` check (f)) |
| coupling | (the failed workflow is the merged file) | a changed file must DECLARE the stuck Deployment: `name = "<deployment>"` grepped from the tree, never inferred from the alert |
| memory | `reverted-pins:` → check (e) refuses the SHA | `reverted-images:` → check (f) refuses the ref for `REVERT_MEMORY_DAYS` — runs on any PR that adds an `image =` line under `tofu/` |
| branch | `revert-wf-<sha8>` | `revert-img-<sha8>` |
| ledger key | `wf-<hash>` | `ri-<hash>` |
| recovery | CI green on master | the box applies the revert on its next hourly pull — recovery ≤ ~1 h after the alert, service intact throughout (the old pods never left) |
| the apply | n/a | `wait_for_rollout = false` on the Deployment (the drill, 2026-09-28): the provider's default waited 10 min for the new ReplicaSet and turned a bad tag into an ERRORED box apply ("half-applied? human") on a change the cluster had already taken. In this lane the roll is the alert's to judge, so the apply writes the object and returns |

What arms the class: ADR-141 as amended 2026-09-28 — `.github/renovate-global.json`'s terraform
docker-datasource majors are ARMED and keep `major` (the lens reviews them, its APPROVED completes
the merge); non-majors already rode the terraform `automerge` rule. Shape required first, per
Deployment: 2 replicas + zero-unavailable rollout + a PDB (`tofu/forgejo-runner.tf`, PR#2078); an
RWO singleton (`Recreate`) never gets it and stays on the human lane.

Replay pins: `tofu-image-revert-candidate` (the `--jq`-literal candidate read),
`tofu-image-revert-merge-lane` (reverted refs from the `+` lines, labels before arming),
`tofu-image-revert-coupling-{match,mismatch}` (the tree read). The drill: a bad tag on the forgejo
runner's `dind` image opened as the App, merged by the reflex, stuck by the cluster, reverted by
this chain, applied by the box — recorded in `agents/coordinator/TICK-LOG.md` when run.

## Part 4 — chart-pin revert: the `chart-revert` receiver (2026-10-05, operator ruling)

The fourth class, and the first NOT hosted on the chain. After the seat's read of PR #2254 (the
argo-workflows 1.1.1 → 2.0.8 chart major, merged in a window) the operator ruled that argo-workflows
chart majors merge on their own the way terraform provider majors do (ADR-141 as amended
2026-10-04: armed, `major` kept, the lens's APPROVED completes the merge) — behind a detector and a
revert actor. The detector is step 1, `ArgoControllerSilent`
(`argocd/resources/argo-workflows-alerts/`, group `argo-workflows-heartbeat`, `triage: now`: the
agent-coordinator namespace completed no workflow for 30 m, fails closed via `or vector(0)`). The
actor is this part.

**Why outside Argo's cone.** Parts 1–3 run ON Argo Workflows — one Sensor, four WorkflowTemplates.
A chart bump that breaks the Argo controller breaks the chain that would revert it, the
[dependency-cone rule](../dependency-upgrades.md) (§4 Rollout: an actor is only safe outside the
change's dependency cone). Considered and rejected: the management box (holds no PR-writing
credential; widening an App permission is operator-only) and a GitHub Actions workflow on ARC
(schedule lag 1–5 h unless webhook-triggered). Chosen: **an in-cluster webhook receiver** —
`argocd/resources/chart-revert/`, a plain Deployment in `agent-coordinator` fed by an Alertmanager
route, reusing the chain's script logic, image (`ghcr.io/teststuffstash/agent-coordinator`: git,
gh, python3) and credential (the `coordinator-git` Secret, mounted as a file and re-read per run —
the token lives ~1 h). Argo Workflows and Argo Events are not on its path; Alertmanager, CoreDNS,
GitHub and the ESO-refreshed token are.

| leg | provider chain (deploy-revert-argo.yaml) | chart receiver (Part 4) |
|---|---|---|
| detector | `MgmtApplyErroredOnNewProvider` | `ArgoControllerSilent` (30 m silent + 5 m `for`) |
| route | receiver `deploy-provider-revert` → EventSource `/provider-errored` | receiver `chart-revert` → `http://chart-revert.agent-coordinator.svc.cluster.local:8080/alert`, `continue: true` (the responder still triages), `group_wait: 10s` |
| host | Argo Events Sensor → Workflow pod | Deployment `chart-revert`, one worker thread, serial |
| candidate | the lockfile commit that introduced the version | newest MERGED PR ≤120 m whose squash commit touched `argocd/platform/argo-workflows.yaml`; `revert-*` heads never |
| predicate | provider-pin-only (`mgmt_provider_pin_commit`) | **pin-only**: the squash commit touched exactly that one file, and every changed line that is not a `#` comment is a `targetRevision:` line — exactly one version removed, one added, different. #2254's diff rewrote the pin's comment block and passes; a values edit, a blank line, a second file does not |
| stale guard | master's lockfile still pins the version | master's file still pins the bumped version — else `already` |
| ledger | `responder-seen` ConfigMap + branch name | **branch name only**: `revert-chart-<sha8>` exists → `already` (no kubectl, no RBAC) |
| memory | `reverted-providers: <name>@<version>` → check (g) | `reverted-charts: argo-workflows@<new version>` — the body's LAST line; pin-only-lint's chart memory reads it from merged `revert-chart-*` PRs |
| lane | `automerge`+`dependencies`, armed | same — labels BEFORE arming (the `labeled` event fires the reflex), `gh pr merge --auto --squash` |
| report | the pod log (gap G10) | `/metrics`, scraped: the counter is the durable report |

**Payload contract.** Alertmanager webhook v4 on `POST /alert`. Every alert with `status=firing`
and an alertname in the receiver's `TARGETS` table (`ArgoControllerSilent` → file
`argocd/platform/argo-workflows.yaml`, chart `argo-workflows`) is queued and the POST returns 200
at once (a clone + revert outruns a webhook timeout; a re-delivery is a no-op by the ledger).
Everything else: ignored, 200; malformed JSON: 400. **Drill:** labels `drill="true"` and
`drill_pr=<n>` (label or annotation) skip the 120-minute window and target that MERGED PR — still
pin-only, still ledgered, and the PR body says DRILL. A drill alert without a numeric `drill_pr`,
or naming an unmerged PR, is `error`, never a fall-through to the window. The drill for this
chain is a real patch bump of the chart, reverted on a synthetic alert (the seat runs it).

**Outcomes and metrics.** One decision per alert, one JSON line on stdout (Alloy → Loki) and one
increment of `chart_revert_alerts_total{outcome}`: `reverted` (PR open, labelled, armed),
`already` (branch exists, or master no longer pins the bumped version), `no_candidate` (no merge
touched the file in the window — not a rollback case, the responder/operator lane owns it),
`not_pin_only` (outside the revert class — **what stays human**: a bump that also edited values,
or a merge that touched more than the pin, is read by a person; the counter says so, the responder
session says why), `conflict` (`git revert` conflicted — aborted, nothing pushed, never forced),
`error` (an unreadable `gh`/`git` read, no token, a bad drill — fail closed, no revert on bad
data). All six are pre-initialised at 0 so `increase()` sees the first one.
`chart_revert_last_run_timestamp_seconds` is the last decision; `chart_revert_webhooks_total{result=
queued|ignored|bad_request}` proves delivery; `up{job="chart-revert"}` is the scrape. Tests:
`devbox run chart-revert-self-test` (the predicate on the real #2254 patch, payload parsing, the
ledger decision, and the whole walk against a scripted gh/git).

## Part 5 — the lock shape: `workflow-pin-revert` admits a lock-only merge (2026-10-07, class 7 armed)

The fifth class rides the FIRST chain unchanged in trigger and actor: `GithubWorkflowRunFailed` on
master → the `workflow-pin-revert` WorkflowTemplate. What changed when devbox lock majors were armed
([`dependency-upgrades.md`](../dependency-upgrades.md) §2 Review — the ruling lives there, no ADR):
the candidate query admits a merge whose EVERY file is a `devbox.lock` beside the workflow-touching
ones; such a merge is pin-only by construction (the lock IS the resolved pin set), so the `uses:`
grammar is skipped; the branch is `revert-lock-<sha8>`; the memory line is `reverted-locks:
<name>@<version> …` — every package whose resolved version the merge moved, read from the clone
(`git show <sha>^:devbox.lock` vs `<sha>:devbox.lock`, the lock's +/- lines carry versions without
their package) — consumed by `pin-only-lint` check (i). Outside the class, by the same file test: a
worker-adapted lock PR (lock + a fixture, the #2262/#2362 shape) — the responder lane owns that. The
one consumer the chain can fire on today is `runner-image.yaml` (push to master, `devbox.lock` in its
paths); `ci.yaml` on master re-runs what the PR already proved. Drill pending (§Next steps 10 there).
Replay: `workflow-pin-revert-candidate` (the widened call line) + `workflow-pin-revert-lock-candidate`
(a lock-only merge is the candidate).

## Future Work

- **Monitoring**: add a Prometheus alert if the revert chain fires more than N times/day (a flapping pin is a deeper problem)
- **Metrics**: export a gauge `workflow_pin_revert_total{repo, workflow}` to track revert frequency (Part 4's receiver already exports its own `chart_revert_alerts_total{outcome}` — the chain's templates still report to the pod log only, gap G10)
- **Dashboard**: panel showing revert PRs over time, by repo

## References

- FU-044: the original deploy-revert chain (ArgoCD Degraded apps)
- FU-1990: the major-bump review lens (part 1)
- `scripts/pin-only-lint.sh`: the pin-only predicate (third shape)
- ADR-084: the CI-only lane (no approval gate by design)
- ADR-100: Renovate action pin doctrine
