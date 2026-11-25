# launch — the ride launcher island

**This directory is the starting CONTRACT of a component to be built fresh, not a description of
running code.** The launch island will be written new under `islands/launch/`, beside the old
launcher it replaces — the way [`gateway/`](../../gateway/README.md) replaced the old router —
against the pages in [specs/](specs/README.md). The location is **provisional** (the final home is
the operator's call). The files under [What this replaces](#what-this-replaces--still-live) are
the running launcher and stay authoritative until a separate switch-over change; **nothing live
reads or calls anything under `islands/`.** Carved from the spike PR #3147
(`agents/islands/launch/`, 2026-11-07/08); index: [islands/README.md](../README.md).

**What it is.** The launcher turns one dispatch decision (a scan or coordinator saying "ride
issue N of repo R, round r") into one running worker pod, and turns that pod's end into one
outcome. In between it reads the issue, refuses what must not ride, asks the
[agent gateway](../../gateway/README.md) whether the ride may run and on what, assembles the
worker's context (the environment card inside the recipe, the context bundle beside it), writes
the pod, follows it, and reports how it ended. It is the consumer side of the gateway's
`POST /sessions` ([UC-1](../../gateway/specs/use-cases/uc-1-worker-ride.md)) and the producer of
everything a worker sees before its first tool call. Island cut: the one measured on the PR #3147 branch (C8 of its `context-and-autonomy.md` — not on master).

## What this replaces — still live

The old members — the running launcher. A build reads them to explain a difference, never as its source
([Built from the specs](../README.md#built-from-the-specs-never-copied); their replay families are the comparison); this directory edits none of them. "Runtime-read" marks the
files the new component will read in place, never copy:

| member | what it is | runtime-read? |
|---|---|---|
| [`agents/agent-session.sh`](../../agents/agent-session.sh) | the launcher (4 067 lines and 56 distinct `REPLAY:` clause markers on master, 2026-11-14) | — |
| [`agents/gateway-admit.sh`](../../agents/gateway-admit.sh) | the shared admission helper (`gw_admit`, `gw_admit_lane`, `gw_release`) — sourced by 4 other launchers and 5 Argo manifests | sourced |
| [`agents/pr-open.sh`](../../agents/pr-open.sh) | written into every recipe ride as `/work/bin/pr-open` (ADR-157) | copied into the pod |
| [`agents/recipe-lint.sh`](../../agents/recipe-lint.sh) | the recipe YAML gate the launcher runs before a pod exists | executed |
| [`agents/estimate_budget.py`](../../agents/estimate_budget.py) | the per-session cap estimator + `--emit-cr` | executed |
| [`agents/model_id.py`](../../agents/model_id.py) + [`agents/model-id-test.sh`](../../agents/model-id-test.sh) | the one model-id parser (old contract — see [specs/admission.md](specs/admission.md#launch-admit-no-model)) | imported |
| [`agents/ground-rules.md`](../../agents/ground-rules.md) | universal worker rules, injected verbatim into every env card | **yes — never move** |
| [`.agents/fix.yaml`](../../.agents/fix.yaml), [`.agents/build.yaml`](../../.agents/build.yaml), [`.agents/probe.md`](../../.agents/probe.md) | homelab's own recipes (fixer, build class, prober) | **yes — never edit from here** |
| replay families (source = a member above; read-only — the comparison) | `agents/replay/fixtures/{argv-max-turns, base-arm-*, major-arm-guard-*, preflight-malformed-block, goal-ancestor, goal-budget-gate, goal-budget-refusal, gateway-admit, gateway-sessions, gateway-env-pull, gateway-outcome, harness-enforce-default, harness-run-cmd, cred-inject-unconditional, context-prefetch*, agent-session-paginated-reviews, ci-failure-run-select, pf-cm-init, fu042-*, env-card-*, specs-process, image-volumes, context-repos-prelude, opencode-session-config, opencode-hostaliases, nix-registry-env, python-profile-env, ride-size, argv-payload, run-phase-metric, transcript-mirror-probe, post-merge-push, strike-quota-classifier, router-report-*, strike-retry, model-id-carrier, go-rail-latch, fu088-ladder, route-request, resolve-model, pick-rail}` | — |

**Not members, though the spike's cut grouped them here** (consumed, owned elsewhere):
[`agents/resolve-model.sh`](../../agents/resolve-model.sh) — the launcher never calls it (0 call sites);
its callers are the coordinator, scan, retro, dig, intake, responder and fix-debounce launchers.
[`agents/subscription-latch.sh`](../../agents/subscription-latch.sh) — the launcher calls it once (the
`--pick-rail` ladder); review-reflex, reviewer-session, coordinator-session and four manifests
call it too. [`agents/machine-comment.sh`](../../agents/machine-comment.sh) and
[`agents/goal-budget.sh`](../../agents/goal-budget.sh) — shared with the scan (the one machine channel;
the `Budget:` arithmetic). All four are seam libraries in §Interfaces' sense; both routing ones
are old contract that the gateway retires.

## Consumer contracts

The contracts the new build must honour — today's consumers of the old members, which must not
notice the switch-over.

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
| gateway | `POST /sessions` (bound), `POST /sessions/{id}/outcome`, `DELETE /sessions/{id}`; the pod's own `POST /sessions/{id}/env` | [GW-SESSIONS-ADMIT](../../gateway/specs/endpoints/sessions.md#gw-sessions-admit), [GW-SESSIONS-PULL](../../gateway/specs/endpoints/sessions.md#gw-sessions-pull), [GW-SESSIONS-OUTCOME](../../gateway/specs/endpoints/sessions.md#gw-sessions-outcome), [GW-SESSIONS-RELEASE](../../gateway/specs/endpoints/sessions.md#gw-sessions-release), [GW-SESSIONS-AUTH](../../gateway/specs/endpoints/sessions.md#gw-sessions-auth) |
| claim | the AgentStack read (`repos[].fixer.{docker, rideSize, egress, imageVolumes}`, `repos[].specs`, `spec.mcp`) and the `stacks.json` mirror row | `argocd/resources/agentstack/xrd.yaml` |
| GitHub | the issue, its comments, the PR, its reviews and check runs (REST only) | [specs/context.md](specs/context.md) |
| agent-runtime | the pod's `AGENT_RUN_STATS` line (finalize) | [specs/outcome.md](specs/outcome.md) |
| old proxy (until it retires) | `/route`, `/router-status`, `/opencode-limit`, `/anthropic-limit`, `/report`, `/git-token` | ⚑ gap rows on [specs/admission.md](specs/admission.md#launch-admit-no-model) and [specs/outcome.md](specs/outcome.md) |

## Read set

A session building this island loads: this README, [`specs/`](specs/README.md), the one page its
change touches, the replay fixture its requirement names (read-only — the comparison), the old clause
of `agent-session.sh` it replaces (read to explain a difference), and the supplier page it
consumes ([`gateway/specs/endpoints/sessions.md`](../../gateway/specs/endpoints/sessions.md) — the
section the clause cites, not the page). Design prose, linked where a page leans on it:
[docs/agents/fixer-context.md](../../docs/agents/fixer-context.md) (the worker's three context
layers) and [docs/agents/model-routing.md](../../docs/agents/model-routing.md) (the old routing
rules the gateway retires — the launcher's carriers and strike ladder). Never the whole of
`docs/agents/`.

## Revert class

**Today:** nothing deploys from here and nothing live reads it — a revert PR, no runtime effect.
The old launcher runs from the coordinator pod's fresh `master` checkout (`gateway-admit.sh` is
sourced from the same checkout), so a bad change to it is also a **revert PR** (no image pin);
recipes in stack repos revert in their own repo. **At switch-over** (a later, separate change —
`seat`): the new launcher inherits that class unless its build adds an image.

## Open

- The gateway path is platform-only and opt-in (`AGENT_GATEWAY=sessions`, env-only, no claim
  field — FU-270); every other stack rides the old self-routing path
  ([admission.md](specs/admission.md#launch-admit-no-model)). The new build admits only through
  `POST /sessions`.
- Evidence is local and partial: `tests/` (run by `scripts/ci.sh`, gated at `pr-open` via `diff-ci` and in required `ci`, #3391)
  runs 12 page-sourced cases against `src/launch/gateway_admit.py` and the `gateway-admit` replay
  family as a comparison (`tests/compare/`) between `agents/gateway-admit.sh` and that component,
  every remaining difference ruled in `tests/compare/gateway-admit.rulings.tsv`;
  no other family runs, nothing is published, and nothing renders into these pages
  ([specs/README.md](specs/README.md) §Rule 5).
- Exit codes mix two defer conventions (exit 0 and exit 1) —
  [LAUNCH-DISPATCH-EXIT](specs/dispatch.md#launch-dispatch-exit).
- Unspecced clauses (fixtures exist, no page): ride size, nix/python/npm env, hostAliases,
  argv-payload ceiling, transcript mirror probe, post-merge-push, the retro-ride env
  (`retro-gh-token-env`, `retro-pg-env` — the retro island's lane through this launcher).
- The specs cite old-launcher lines as `agent-session.sh:<n>` against the spike's base (4 016
  lines); master has moved — the `REPLAY:` sentinels are the stable anchor.
