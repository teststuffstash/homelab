# launch — the ride launcher island

**What it is.** The launcher turns one dispatch decision (a scan or coordinator saying "ride
issue N of repo R, round r") into one running worker pod, and turns that pod's end into one
outcome. In between it reads the issue, refuses what must not ride, asks the
[agent gateway](../../../gateway/README.md) whether the ride may run and on what, assembles the
worker's context (the environment card inside the recipe, the context bundle beside it), writes
the pod, follows it, and reports how it ended. It is the consumer side of the gateway's
`POST /sessions` ([UC-1](../../../gateway/specs/use-cases/uc-1-worker-ride.md)) and the producer of
everything a worker sees before its first tool call. Island cut:
[context-and-autonomy.md §C8](../../../docs/spikes/context-and-autonomy.md#c8-the-agent-loop-island-re-measured-on-the-october-window-second-jail-2026-11-01).

## Membership

Code stays where it is; this list is the island.

| member | what it is | runtime-read? |
|---|---|---|
| [`agents/agent-session.sh`](../../agent-session.sh) | the launcher (4 016 lines, 56 `REPLAY:` clause markers) | — |
| [`agents/gateway-admit.sh`](../../gateway-admit.sh) | the shared admission helper (`gw_admit`, `gw_admit_lane`, `gw_release`) — sourced by 4 other launchers and 5 Argo manifests | sourced |
| [`agents/pr-open.sh`](../../pr-open.sh) | written into every recipe ride as `/work/bin/pr-open` (ADR-157) | copied into the pod |
| [`agents/recipe-lint.sh`](../../recipe-lint.sh) | the recipe YAML gate the launcher runs before a pod exists | executed |
| [`agents/estimate_budget.py`](../../estimate_budget.py) | the per-session cap estimator + `--emit-cr` | executed |
| [`agents/model_id.py`](../../model_id.py) + [`agents/model-id-test.sh`](../../model-id-test.sh) | the one model-id parser (old contract — see [specs/admission.md](specs/admission.md#launch-admit-no-model)) | imported |
| [`agents/ground-rules.md`](../../ground-rules.md) | universal worker rules, injected verbatim into every env card | **yes — never move** |
| [`.agents/fix.yaml`](../../../.agents/fix.yaml), [`.agents/build.yaml`](../../../.agents/build.yaml), [`.agents/probe.md`](../../../.agents/probe.md) | homelab's own recipes (fixer, build class, prober) | **yes — never edit from here** |
| replay families (source = a member above) | `agents/replay/fixtures/{argv-max-turns, base-arm-*, major-arm-guard-*, preflight-malformed-block, goal-ancestor, goal-budget-gate, goal-budget-refusal, gateway-admit, gateway-sessions, gateway-env-pull, gateway-outcome, harness-enforce-default, harness-run-cmd, cred-inject-unconditional, context-prefetch*, agent-session-paginated-reviews, ci-failure-run-select, pf-cm-init, fu042-*, env-card-*, specs-process, image-volumes, context-repos-prelude, opencode-session-config, opencode-hostaliases, nix-registry-env, python-profile-env, ride-size, argv-payload, run-phase-metric, transcript-mirror-probe, post-merge-push, strike-quota-classifier, router-report-*, strike-retry, model-id-carrier, go-rail-latch, fu088-ladder, route-request, resolve-model, pick-rail}` | — |

**Not members, though §C8 grouped them here** (consumed, owned elsewhere):
[`agents/resolve-model.sh`](../../resolve-model.sh) — the launcher never calls it (0 call sites);
its callers are the coordinator, scan, retro, dig, intake, responder and fix-debounce launchers.
[`agents/subscription-latch.sh`](../../subscription-latch.sh) — the launcher calls it once (the
`--pick-rail` ladder); review-reflex, reviewer-session, coordinator-session and four manifests
call it too. [`agents/machine-comment.sh`](../../machine-comment.sh) and
[`agents/goal-budget.sh`](../../goal-budget.sh) — shared with the scan (the one machine channel;
the `Budget:` arithmetic). All four are seam libraries in §Interfaces' sense; both routing ones
are old contract that the gateway retires.

## Consumer contracts

**Exposes** (what other islands call or read):

| interface | consumer | page |
|---|---|---|
| the launcher CLI — argv, exit code, stderr verdict lines | scan (coordinator brief, `coordinator-scan.sh`), retro, research-fanout, drills | [specs/dispatch.md](specs/dispatch.md) |
| `gw_admit` / `gw_admit_lane` / `gw_release` (rc + `GW_*` outputs) | every launcher the gateway admits (coordinator, reviewer, retro, research, dig, intake, responder, fix-debounce) | [specs/admission.md](specs/admission.md) |
| the worker pod — env per harness, harness command, labels | agent-runtime (finalize), the gateway's env pull, monitoring | [specs/pod.md](specs/pod.md) |
| the context bundle (`/work/context/*`) and the environment card | the worker (any harness), the recipe author | [specs/context.md](specs/context.md) |
| the ride outcome — gateway outcome, `AGENT_STRIKE:` / `KEY-RETRY:` comments, doorbell, `agent_run_phase_seconds` | gateway (strikes), scan (fleet reader, doorbell), monitoring | [specs/outcome.md](specs/outcome.md) |
| the budget estimate (`estimate_budget.py` JSON / CR) | coordinator brief, retro-session, research-fanout, goal-budget | [specs/budget.md](specs/budget.md) |

**Consumes:**

| from | what | contract |
|---|---|---|
| scan | dispatch params (argv) — launcher-owned per ADR-094 | [specs/dispatch.md](specs/dispatch.md) |
| gateway | `POST /sessions` (bound), `POST /sessions/{id}/outcome`, `DELETE /sessions/{id}`; the pod's own `POST /sessions/{id}/env` | [GW-SESSIONS-ADMIT](../../../gateway/specs/endpoints/sessions.md#gw-sessions-admit), [GW-SESSIONS-PULL](../../../gateway/specs/endpoints/sessions.md#gw-sessions-pull), [GW-SESSIONS-OUTCOME](../../../gateway/specs/endpoints/sessions.md#gw-sessions-outcome), [GW-SESSIONS-RELEASE](../../../gateway/specs/endpoints/sessions.md#gw-sessions-release), [GW-SESSIONS-AUTH](../../../gateway/specs/endpoints/sessions.md#gw-sessions-auth) |
| claim | the AgentStack read (`repos[].fixer.{docker, rideSize, egress, imageVolumes}`, `repos[].specs`, `spec.mcp`) and the `stacks.json` mirror row | `argocd/resources/agentstack/xrd.yaml` |
| GitHub | the issue, its comments, the PR, its reviews and check runs (REST only) | [specs/context.md](specs/context.md) |
| agent-runtime | the pod's `AGENT_RUN_STATS` line (finalize) | [specs/outcome.md](specs/outcome.md) |
| old proxy (until it retires) | `/route`, `/router-status`, `/opencode-limit`, `/anthropic-limit`, `/report`, `/git-token` | ⚑ gap rows on [specs/admission.md](specs/admission.md#launch-admit-no-model) and [specs/outcome.md](specs/outcome.md) |

## Read set

A session working on this island loads: this README, [`specs/`](specs/README.md), the touched
clause of the member file, its replay fixture, and the supplier page it consumes
([`gateway/specs/endpoints/sessions.md`](../../../gateway/specs/endpoints/sessions.md) — the
section the clause cites, not the page). Island-owned design prose:
[docs/fixer-context.md](docs/fixer-context.md) (the worker's three context layers) and
[docs/launcher-routing.md](docs/launcher-routing.md) (the launcher's half of the old routing
rules). Never the whole of `docs/agents/`.

## Revert class

Pods clone master: the coordinator pod runs the launcher from its master checkout, so a bad
launcher change is reverted by a **revert PR** (no image pin). `gateway-admit.sh` is sourced by
the same checkout. Recipes in stack repos revert in their own repo.

## Open

- The gateway path is platform-only and opt-in (`AGENT_GATEWAY=sessions`, FU-270); every other
  stack rides the old self-routing path ([admission.md](specs/admission.md#launch-admit-no-model)).
- No evidence pipeline: the replay families prove clauses, but nothing renders them into these
  pages ([specs/README.md](specs/README.md) §Rule 5).
- Exit codes mix two defer conventions (exit 0 and exit 1) —
  [LAUNCH-DISPATCH-EXIT](specs/dispatch.md#launch-dispatch-exit).
- Unspecced clauses (fixtures exist, no page): ride size, nix/python/npm env, hostAliases,
  argv-payload ceiling, transcript mirror probe, post-merge-push, the retro-ride env
  (`retro-gh-token-env`, `retro-pg-env` — the retro island's lane through this launcher).
