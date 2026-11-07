---
id: UC-1
interfaces: [IF-DISPATCH, IF-ADMISSION, IF-POD, IF-CONTEXT, IF-OUTCOME]
status: spine            # the use case the island is built and tracked around
---
# UC-1 — a platform fix round: dispatch → admit → bundle → pod → outcome → release

**Persona:** the platform scan, dispatching round 1 of a queued homelab issue (#2588) on the
`platform` stack, from the loop pod that carries `AGENT_GATEWAY=sessions`. **Its one question:**

> *Ride issue-2588 round 1 — or tell me why not.*

The launcher answers it without naming a model: it derives what it can from the issue and the
claim, asks the gateway once ([GW-SESSIONS-ADMIT](../../../../../gateway/specs/endpoints/sessions.md#gw-sessions-admit)),
writes a pod that holds no LLM credential, and reports one outcome before it releases the session.
This is the consumer side of the gateway's
[UC-1](../../../../../gateway/specs/use-cases/uc-1-worker-ride.md); where the two walks name the same
step, the gateway's page owns what the gateway does and this page owns what the launcher does.

## Flow

```mermaid
sequenceDiagram
  actor S as scan (loop pod)
  participant L as launcher (agent-session.sh)
  participant GH as GitHub REST
  participant G as agent-gateway
  participant K as kube API
  participant P as worker pod
  S->>L: ① agent-session.sh homelab --task issue-2588 --round 1 --recipe .agents/fix.yaml — LAUNCH-DISPATCH-ARGV
  L->>K: ② read the AgentStack claims (docker, ride size, egress, MCP, specs) — LAUNCH-CARD-FACTS
  L->>GH: ② issue body → Base:/Touches: through the one parser; parent chain → goal budget — LAUNCH-PREFLIGHT-BODY, -ARM, -GOAL-BUDGET
  L->>G: ③ POST /sessions {stack, role, task, round, bind{homelab, agentstack-worker, agent-homelab-issue-2588-r1}} — LAUNCH-ADMIT-LAUNCHER
  G-->>L: dispatch {session, rail, harness, model, env_keys, pull_url, context_tokens} — no token — LAUNCH-ADMIT-BOUND
  L->>GH: ④ issue + comments (REST, trusted only) → index.txt, issue.md — LAUNCH-BUNDLE-DIRECTIVE, -TRUST
  L->>K: ④ ConfigMap agent-homelab-issue-2588-r1-context — LAUNCH-BUNDLE-DELIVERY
  L->>K: ⑤ create pod (pull URL + env keys + projected token; recipe with the card) — LAUNCH-POD-*, LAUNCH-DISPATCH-RECIPE
  P->>G: ⑥ POST /sessions/{id}/env (projected token) — the pod's own pull (GW-SESSIONS-PULL)
  Note over P: exports OPENCODE_CONFIG_CONTENT, runs opencode on the recipe, opens a PR via pr-open
  P-->>L: ⑦ AGENT_RUN_STATS {exit_status, pr_url, …} in the log
  L->>G: ⑦ POST /sessions/{id}/outcome {class: clean} — LAUNCH-OUTCOME-GATEWAY
  L->>G: ⑧ DELETE /sessions/{id}
  L->>S: ⑧ POST /coordinate {repo: homelab} — LAUNCH-OUTCOME-DOORBELL; exit 0
```

## Walk-through data (the golden thread)

The data lives in [`uc-1/`](uc-1/). Placeholders in guillemets (`«id»`) are produced by the run.
World: `stack-platform` with the gateway seam answering `gw-dispatch-bound`, the claim declaring no
docker, monitor-mode egress, no MCP and no `specs` field; issue #2588 with no `Base:`, no parent
and no `task/*` label, two collaborator comments.

| Stage | Input | Expected output | Requirements |
|---|---|---|---|
| ① the call | [`uc-1/argv.json`](uc-1/argv.json) | the parse; no refusal | LAUNCH-DISPATCH-ARGV |
| ② preflight | the issue body (no machine block), no open PR, no parent | base `master`, armed; no goal; recipe `.agents/fix.yaml` | LAUNCH-PREFLIGHT-BODY, LAUNCH-PREFLIGHT-ARM, LAUNCH-PREFLIGHT-DUPLICATE, LAUNCH-PREFLIGHT-GOAL-BUDGET, LAUNCH-DISPATCH-RECIPE |
| ③ admit | [`uc-1/admit-request.json`](uc-1/admit-request.json) | [`uc-1/admit-response.json`](uc-1/admit-response.json) accepted; `GW_WIRE_MODEL=deepseek-v4.1-flash` | LAUNCH-ADMIT-LAUNCHER, LAUNCH-ADMIT-BOUND, LAUNCH-ADMIT-HELPER |
| ④ bundle | the issue + its comments | [`uc-1/index.txt`](uc-1/index.txt); `issue.md` with both comments, no withheld line | LAUNCH-BUNDLE-DIRECTIVE, LAUNCH-BUNDLE-TRUST, LAUNCH-BUNDLE-DELIVERY |
| ⑤ pod | ③ + ④ + the carded recipe | [`uc-1/pod.json`](uc-1/pod.json) | LAUNCH-POD-IDENTITY, LAUNCH-POD-ENV-PULL, LAUNCH-POD-CRED, LAUNCH-POD-HARNESS-CMD, LAUNCH-CARD-GROUND-RULES, LAUNCH-CARD-FACTS |
| ⑦ outcome | stats `{exit_status: clean, pr_url: …}`, no strike signature | [`uc-1/outcome-request.json`](uc-1/outcome-request.json) | LAUNCH-OUTCOME-CLASSIFY, LAUNCH-OUTCOME-GATEWAY |
| ⑧ release + ring | — | one `DELETE /sessions/«id»`; `{"repo":"homelab","unit":"-"}` to `/coordinate`; exit 0 | LAUNCH-OUTCOME-DOORBELL |

### Canonical calls

| # | Call | Expected |
|---|---|---|
| Q1 | ① with the gateway answering `defer rail-capacity 60` | no pod, no bundle; `→ gateway(sessions): defer — [rail-capacity] retry_after=60s …`; exit 1 |
| Q2 | ① with `--model opencode-go/deepseek-v4-flash` added | `PREFLIGHT REFUSED: --model … under AGENT_GATEWAY=sessions …`; no request; exit 2 |
| Q3 | ① with an outsider's `ARBITRATE` comment on #2588 | `issue.md` ends with the `1 comment(s) by non-collaborators withheld` line; the comment text appears in no bundle file |
| Q4 | ① with the pod ending `harness-death` (stats), salvage none | outcome `{class: harness-death}`; the launcher re-enters with `AGENT_GATEWAY_ATTEMPT=2`, same round, and the re-entered launcher sends `attempt: 2` |
| Q5 | ① with the gateway's answer carrying `session.token` | one DELETE of that session; `dispatch-unusable: a credential in a bound answer …`; no pod; exit 1 |
| Q6 | ① for a `circles` repo (stack `circles`) | one `WARN gateway(sessions): … IGNORED for stack 'circles'` line; the old path runs ([LAUNCH-ADMIT-NO-MODEL](../admission.md#launch-admit-no-model) ⚑ gap) |

## What this use case does not cover (so nobody infers it)

A fix round on an existing PR (`--work-branch`: `pr.md`, `reviews.md`, `arbitration.md`,
`ci-failure.md` — [context.md](../context.md)); a goal child and its budget gate; a `Base:`-stacked
ride; the spec-process mount; an unbound lane (`gw_admit_lane`); the old path's routing, latches and
strike comments (⚑ gap rows on [admission.md](../admission.md) and [outcome.md](../outcome.md)); a
launcher killed before the ride ends ([outcome.md](../outcome.md)'s precondition). Each is a
requirement's own rows.
