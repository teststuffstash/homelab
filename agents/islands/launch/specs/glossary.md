# Glossary — the launcher's language

One definition per term; other pages link a term instead of repeating it. Platform-wide terms
(stack, AgentStack claim, Goal, `pr-open`, `pr-gate`, ride size class, switchboard) keep their
homelab definitions in [`docs/glossary.md`](../../../../docs/glossary.md). The gateway's terms —
[session](../../../../gateway/specs/glossary.md#session),
[bind](../../../../gateway/specs/glossary.md#bind),
[env pull](../../../../gateway/specs/glossary.md#env-pull),
[rail](../../../../gateway/specs/glossary.md#rail),
[harness](../../../../gateway/specs/glossary.md#harness),
[defer](../../../../gateway/specs/glossary.md#defer),
[cell](../../../../gateway/specs/glossary.md#cell),
[strike](../../../../gateway/specs/glossary.md#strike),
[judge](../../../../gateway/specs/glossary.md#judge) — are the supplier's and are used here in
the supplier's meaning. This file defines only what the launcher coins or narrows.

## ride

One worker pod running one recipe on one `(repo, task, round)`. The launcher creates it and
reports its end; a ride admitted by the gateway is exactly one [session](../../../../gateway/specs/glossary.md#session).

## task

The ride's key on the work item: `issue-<N>`, `pr-<N>`, `research-<N>-<slug>`, or `adhoc-<stamp>`
when none is passed. Only `issue-*` and `pr-*` are **tasked** — strikes, the doorbell and the
same-round re-admission apply to tasked rides only.

## round

The logic-attempt counter on a task (`--round`): a `CHANGES_REQUESTED` review or CI red on the
change costs one. The scan owns it; the launcher carries it into the pod name, the card and every
gateway request, and never advances it.

## attempt

The infra-attempt counter inside one round (`AGENT_GATEWAY_ATTEMPT`, default 1): the launcher's
own re-admission after a counted strike re-enters itself with the same argv and `attempt + 1`.
Sent to the gateway as `post.input.attempt` (GW-SESSIONS-RETRY). Not a round.

## dispatch params

The launcher's argv, written by the scan or the coordinator brief: the repo, `--task`, `--round`,
`--recipe`, `--work-branch`, `--ref`, and the overrides. Launcher-owned (ADR-094): a fact the
launcher can derive (docker, ride size, arming, base branch, recipe class) is derived, never
passed — a flag exists only as an explicit operator override.

## preflight refusal

A refusal before any pod exists: one `PREFLIGHT REFUSED: …` (or `FATAL: …`) line to stderr and a
non-zero exit. No session is held after it (a held session is released on exit), and no comment is
minted — except the goal-budget refusal, which keeps one comment on the goal.

## deferral

A ride that does not start because a read it needs failed or capacity is not there yet: one
`→ dispatch deferred — …` (or `→ gateway(sessions): defer — …`) line and no pod. The next scan pass
retries. Distinct from a refusal: nothing about the issue is wrong. The two exit conventions for it
are [LAUNCH-DISPATCH-EXIT](dispatch.md#launch-dispatch-exit)'s ⚖ row.

## context bundle

The files under `/work/context/` in the pod: `index.txt` (every item, `OK` or `MISSING <why>`),
`issue.md`, and on a fix round `pr.md`, `reviews.md`, `arbitration.md`, `ci-failure.md`
([context.md](context.md)). Fetched by the launcher over REST before the pod exists.

## directive channel

Everything a worker treats as its instructions: the recipe, the card, and the bundle. Only trusted
authors write into it ([trust predicate](#trust-predicate)).

## trust predicate

A comment-shaped source reaches the bundle when its author is a GitHub App (`user.type == "Bot"`)
or carries `author_association` `OWNER`, `MEMBER` or `COLLABORATOR`
(`agents/agent-session.sh` `REPLAY:comment-trust`). Everything else is withheld.

## environment card

The per-ride text the launcher writes into the recipe at its `{{PLATFORM_ENV_CARD}}` marker: the
ground rules verbatim, then the ride's own facts (docker, egress, web research, round, write
scope, base, goal, bundle, spec process, image volumes, feedback tool), each computed from the
knob that built the ride. Design: [../docs/fixer-context.md](../docs/fixer-context.md) §L1.

## salvage verdict

Whether a struck ride's work survives on a branch: `none` (nothing to resume — a re-admission
starts clean), `resumable` (a salvaged branch, a `--work-branch` resume, or finalize could not
tell), `unknown` (an OOM kill — finalize may not have run). Only `none` re-admits automatically.

## key retry

A key-class budget failure (`budget-403-key`): a mint defect, not a model or cell verdict —
`KEY-RETRY:` on the issue, same model, fresh key. Not a strike; on a gateway ride, no outcome is
reported for it.

## the old path

Everything the launcher does to choose a model itself: the `/route` consult, the rail degrade, the
chainless guard, the model-id parse, the FU-088 subscription/Go gates, the router report and the
`/router-status` reads. Taken by every ride that the gateway does not admit
([LAUNCH-ADMIT-NO-MODEL](admission.md#launch-admit-no-model)).
