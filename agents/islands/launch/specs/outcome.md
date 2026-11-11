---
id: IF-OUTCOME
use-cases: [UC-1]
schema: outcome.schema.json
---
# The ride's end — one class, reported where it is counted

*How did the ride end, and who needs to know?* When the launcher follows a headless ride to its
end, it reduces the end to one class, reports it to the gateway before releasing the session
([GW-SESSIONS-OUTCOME](../../../../gateway/specs/endpoints/sessions.md#gw-sessions-outcome) owns
the vocabulary and the strike store), may re-admit the same round once the gateway has excluded the
struck cell, rings its stack's doorbell, and has published its own phase timings along the way. The
redrawn contract is one typed outcome per ride, to the one store that counts it; the comment
grammar and the router report that preceded it are `⚑ gap` rows
([context-and-autonomy.md §Interfaces](../../../../docs/spikes/context-and-autonomy.md#interfaces-are-redrawn-at-the-cut-operator-2026-10-05),
"Observability"; ADR-103 (2)).

**The precondition every row below shares:** the launcher process outlives the ride. In the
cluster dispatch path the launcher runs inside a coordinator session's time-bounded shell and is
often killed mid-follow (`agents/agent-session.sh` run-phase clause, :125–170: the `ride` phase
survived on 5 of 24 rides measured 2026-08-12). The in-pod finalize carries its own bookkeeping for
that case (the `*_by_pod` flags on its stats line); the gateway outcome has no in-pod twin — ⚑ gap:
a killed launcher reports no outcome and releases nothing, and the session ends by the gateway's
reaper ([GW-SESSIONS-LIVENESS](../../../../gateway/specs/endpoints/sessions.md#gw-sessions-liveness))
with no strike counted.

## Interface — the machine half

| requirement | schema path | written to |
|---|---|---|
| [LAUNCH-OUTCOME-CLASSIFY](#launch-outcome-classify) | `err_class` | — (the launcher's state) |
| [LAUNCH-OUTCOME-GATEWAY](#launch-outcome-gateway) | `gateway_outcome` | `POST /sessions/{id}/outcome`, then `DELETE /sessions/{id}`; a re-entry of the launcher |
| [LAUNCH-OUTCOME-STRIKE-COMMENT](#launch-outcome-strike-comment) | `strike_line`, `key_retry_line`, `router_report` | an issue comment; `POST <proxy>/report` |
| [LAUNCH-OUTCOME-ROUTE-RETRY](#launch-outcome-route-retry) | `route_retry` | a re-entry of the launcher |
| [LAUNCH-OUTCOME-DOORBELL](#launch-outcome-doorbell) | `doorbell` | `POST <loop webhook>/coordinate` |
| [LAUNCH-OUTCOME-PHASES](#launch-outcome-phases) | `run_phase` | the Pushgateway |

## Requirement index

| Requirement | section | Status |
|---|---|---|
| [LAUNCH-OUTCOME-CLASSIFY](#launch-outcome-classify) | the class | 🚧 WIP — no evidence pipeline yet (fixtures: `strike-quota-classifier`, `router-report-*`; the stats-line arm and the pod-reason arms beyond the two budget branches are unpinned) |
| [LAUNCH-OUTCOME-GATEWAY](#launch-outcome-gateway) | the class | 🚧 WIP — no evidence pipeline yet (fixture: `gateway-outcome`) · ⚑ gap: no outcome when the launcher does not outlive the ride (above) |
| [LAUNCH-OUTCOME-STRIKE-COMMENT](#launch-outcome-strike-comment) | old contract | ⚑ gap: `AGENT_STRIKE:` / `KEY-RETRY:` comments and `POST /report` are still written on every tasked ride, gateway rides included (the scan's fleet reader greps the comments) |
| [LAUNCH-OUTCOME-ROUTE-RETRY](#launch-outcome-route-retry) | old contract | ⚑ gap: the old same-round retry reads `/router-status` and needs `routerMode: authoritative` (fixture: `strike-retry`) |
| [LAUNCH-OUTCOME-DOORBELL](#launch-outcome-doorbell) | signals | 🚧 WIP — no evidence pipeline yet (fixture: `strike-retry`, its `doorbell-ring` block; the graduated-stack row has none) |
| [LAUNCH-OUTCOME-PHASES](#launch-outcome-phases) | signals | 🚧 WIP — no evidence pipeline yet (fixture: `run-phase-metric`) |

## The class

### LAUNCH-OUTCOME-CLASSIFY

A tasked ride whose finalize did not already strike (`strike_by_pod` false) is reduced to one class
(`REPLAY:strike-classifier`, :3466–3589). **The stats line first:** finalize's last
`AGENT_RUN_STATS {…}` line maps `exit_status` to the class — `no-artifact` → its `error_class`
(default `no-pr`); `budget-403` → `budget-403-key` / `budget-403-account` / `http-403-other` /
`budget-403`; `harness-death` with `error_class: turn-cap` → `turn-cap`; `harness-death`,
`auth-storm`, `timeout` → themselves; anything else `unknown`, refined from the run log
(`Configuration is invalid` → `harness-death`; opencode's auto-rejected permission → `harness-fault`;
an `UnknownError` → `harness-death`). **No stats line:** the pod's reason (`DeadlineExceeded` →
`timeout`, `OOMKilled` → `oom`), then the run log's signatures in a fixed order — config-invalid,
`harness-fault`, goose `-32602` / truncation / `context_length_exceeded` / a panic, `UnknownError`,
a 429 quota line (`quota`), the key-limit line (`budget-403-key`), insufficient credit / 402
(`budget-403-account`), a generic quota/budget line (`budget-403`), goose's output-cap `final_output`
pair (`turn-cap`), three or more auth failures (`auth-storm`), a timeout line (`timeout`), else
`unknown`. The class then decides the kind: a **strike** (`harness-death`, `harness-fault`,
`auth-storm`, `timeout`, `quota`, `budget-403-account`, `http-403-other`, `turn-cap`, `oom`, and any
class on a ride that opened no PR), a [key retry](glossary.md#key-retry) (`budget-403-key`), or
neither (`budget-403` — an estimator or cap problem, escalated). A ride with a PR and no strike
signature is clean.

**World:** `launcher-vars` + a pod-reason answer and a run log.

#### The raw-log budget split

Legend: `log_line` = the matched run-log line; `kind?` = strike / key retry / neither;
`err_class?` = the class.

| description | world | log_line | kind? | err_class? |
|---|---|---|---|---|
| strike-quota-classifier (account) | launcher-vars | `Error: insufficient credit to complete the request` | strike (with `match=`) | budget-403-account |
| strike-quota-classifier (residual) | launcher-vars | `budget exceeded` | neither | budget-403 |
| strike-quota-classifier (key) | launcher-vars | `key limit exceeded` | key retry | budget-403-key |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-OUTCOME-CLASSIFY.md"

</details>

### LAUNCH-OUTCOME-GATEWAY

On a gateway ride the class becomes **one** outcome in the supplier's vocabulary, reported to
`POST /sessions/{id}/outcome` before the release (`REPLAY:gateway-outcome`, :3635–3709). A tasked
ride that struck (or that finalize struck) reports its class when it is a vocabulary member
(`harness-death`, `harness-fault`, `auth-storm`, `timeout`, `provider-5xx`, `no-pr`, `unknown`,
`turn-cap`, `tool-loop`); `quota` reports `harness-gave-up`; every other class reports `unknown`;
the launcher's finer class rides as `subclass` when it differs. A tasked ride with neither a strike
nor a key retry reports `clean`. A key retry reports nothing (a mint defect is not a model or cell
fact). An untasked ride reports `clean` only when its stats say `clean` or its pod `Succeeded`, else
nothing. Rounds are not outcomes: a `CHANGES_REQUESTED` or a red CI on the change is the scan's
round, never sent (GW-SESSIONS-OUTCOME, "Rounds ≠ strikes"). A failed report warns and counts
nothing. Then the session is released.

When the answer counted a strike, the ride is tasked, its [salvage verdict](glossary.md#salvage-verdict)
is `none`, and the attempt is within `AGENT_GATEWAY_AUTO_ATTEMPTS` (default 2), the launcher
re-enters itself with its original argv and `AGENT_GATEWAY_ATTEMPT = attempt + 1` — the same round,
no coordinator hop; the gateway's walk excludes the struck cell
([GW-SESSIONS-RETRY](../../../../gateway/specs/endpoints/sessions.md#gw-sessions-retry)). Otherwise
one line says why not and the coordinator decides. An OOM kill makes the salvage `unknown` (finalize
may not have run), so it never re-admits.

The vocabulary the launcher never emits — `no-verdict`, `wrong-verdict`, `invented-findings`,
`repetition`, `stream-incomplete`, `refused` — is a reviewer's, a judge's or the gateway's own.

**World:** `launcher-vars` with `GW_SESSIONS=1`, session `0123abcd`; `gw-outcome-strike` where the
row's answer counts one.

#### What is reported, and whether the round re-admits

Legend: `ride` = the row's condition (`vars.sh`); `body?` = the outcome body sent (`—` = none);
`readmit?` = re-entry at `attempt + 1`, or why not.

| description | world | ride | body? | readmit? |
|---|---|---|---|---|
| off | launcher-vars | not a gateway ride | — | — |
| tasked-clean | launcher-vars | tasked, no strike | `{class: clean}` | — |
| tasked-strike-retry | gw-outcome-strike | tasked, strike `harness-death`, salvage none, attempt 1 | `{class: harness-death}` | attempt 2 |
| pod-strike | gw-outcome-strike | finalize struck `timeout` | `{class: timeout}` | attempt 2 |
| quota-gave-up ⚖ | gw-outcome-strike | strike `quota` | `{class: harness-gave-up, subclass: quota}` | attempt 2 |
| harness-fault | gw-outcome-strike | strike `harness-fault` (harness scope) | `{class: harness-fault}` | attempt 2 |
| tasked-cap-reached | gw-outcome-strike | strike `timeout` at attempt 3 | `{class: timeout}` | no — cap 2 |
| tasked-salvage | gw-outcome-strike | strike `harness-death`, `--work-branch` set | `{class: harness-death}` | no — salvage resumable |
| oom-no-readmit ⚖ | gw-outcome-strike | strike `oom` | `{class: unknown, subclass: oom}` | no — salvage unknown |
| key-retry-silent ⚖ | launcher-vars | key retry `budget-403-key` | — | — |
| report-fails | launcher-vars | strike `harness-death`, the POST fails | `{class: harness-death}` (WARN, nothing counted) | no |
| adhoc-succeeded | launcher-vars | untasked, pod `Succeeded` | `{class: clean}` | — |
| adhoc-stats-clean | launcher-vars | untasked, stats `exit_status: clean`, pod Running | `{class: clean}` | — |
| adhoc-failed | launcher-vars | untasked, pod `Failed` | — | — |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-OUTCOME-GATEWAY.md"

</details>

## Old contract

### LAUNCH-OUTCOME-STRIKE-COMMENT

The old strike store is an issue comment (`REPLAY:strike-line-format`, :3590–3632; posted at
:3768–3800): a strike posts `AGENT_STRIKE: model=<m> error_class=<c> round=<r> session=<pod>`
(+ ` match=<line>` for a budget match, + ` provider=<p>` when the router report or the stats name
one), a key retry posts `KEY-RETRY: …` in the same shape, each followed by the last 15 log lines in
a `<details>` block. The first line's format is a machine interface: the scan's fleet reader greps
it. Alongside, every tasked ride with stats or a class posts the router report
`POST <proxy>/report {session, task, stack, role: worker, round, model, rail, cost_usd, error_class,
outcome}` (`REPLAY:router-report`, :3711–3748; the pod also gets `AGENT_REPORT_URL`).

⚑ gap — both run on gateway rides too: a gateway ride's strike is counted by the gateway
([LAUNCH-OUTCOME-GATEWAY](#launch-outcome-gateway)) AND written as a comment AND reported to the old
router. The redrawn contract is the gateway's outcome as the one store and one typed event per ride
outcome for observability (ADR-103 (2): machine residue out of timelines); the comment's readers
(the fleet reader in `coordinator-scan.sh`, the chain walk) move first
([../docs/launcher-routing.md](../docs/launcher-routing.md#the-strike-comment-and-its-readers)).

**World:** `launcher-vars` + the proxy seam (`curl` shadowed).

#### The router report's credential

Legend: `ride` = the ride shape; `auth?` = the report's `Authorization` header.

| description | world | ride | auth? |
|---|---|---|---|
| router-report-adhoc | launcher-vars | untasked, subscription rail | none |
| router-report-no-ref | launcher-vars | tasked, subscription rail (no key ref) | none |
| router-report-session-ref | launcher-vars | tasked, per-session OpenRouter key | `Bearer ref:homelab/homelab-session-1268` |
| router-report-strike-by-pod | launcher-vars | finalize struck, per-session key | `Bearer ref:homelab/homelab-session-1268-pod-struck` |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-OUTCOME-STRIKE-COMMENT.md"

</details>

### LAUNCH-OUTCOME-ROUTE-RETRY

The old path's same-round retry (`REPLAY:strike-retry`, :3829–3955; Goal #1640 acceptance 4): a
strike ∧ salvage `none` ∧ the class in the router's serving classes (read from `/router-status`) or
`turn-cap` ∧ a known provider ∧ that `(model, provider, class)` cell not already retried ∧ fewer than
2 retries on the task ∧ a chainless stack under `routerMode: authoritative` ⇒ re-run the round with
`--model`, `--openrouter-secret` and a goose `--harness` stripped, so `/route` picks again. Otherwise
one line names the failing condition and the doorbell rings as usual.

⚑ gap — superseded on gateway rides by [LAUNCH-OUTCOME-GATEWAY](#launch-outcome-gateway)'s
re-admission (the gateway holds the strikes, the launcher holds only the attempt); on a gateway ride
`AGENT_ROUTER=off`, so this retry never fires there. Deleted with the old path.

**World:** `launcher-vars` (the `RT_*` knobs in the `env` column).

#### When the old retry fires

Legend: `condition` = the row's `RT_*` knobs; `fires?` = re-run with the cell excluded.

| description | world | condition | fires? |
|---|---|---|---|
| fires-serving-timeout | launcher-vars | strike `timeout`, provider openrouter, salvage none | yes (attempt 1/2) |
| fires-by-pod-tool-loop | launcher-vars | finalize struck `tool-loop`, provider from stats | yes |
| fires-turn-cap | launcher-vars | strike `turn-cap` | yes |
| fires-probe-fallback | launcher-vars | `/router-status` blank in-process, the probe URL answers | yes |
| retry-dispatch-failed | launcher-vars | the re-run exits 1 | yes, then falls through to the doorbell |
| no-retry-cell-seen | launcher-vars | the cell already retried | no |
| no-retry-task-cap | launcher-vars | 2 retries on the task | no |
| no-retry-salvage-pushed | launcher-vars | a salvaged branch pushed | no |
| no-retry-salvage-resuming | launcher-vars | `--work-branch` set | no |
| no-retry-salvage-unknown | launcher-vars | salvage undetermined | no |
| no-retry-nonserving | launcher-vars | `harness-death` | no |
| no-retry-no-strike | launcher-vars | no strike | no |
| no-retry-router-unreachable | launcher-vars | `/router-status` unreadable | no |
| no-retry-empty-provider | launcher-vars | no provider known | no (fail-closed line) |
| no-retry-chained-stack | launcher-vars | a stack with a `workerModel` chain | no |
| no-retry-shadow-mode | launcher-vars | `routerMode: shadow` | no |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-OUTCOME-ROUTE-RETRY.md"

</details>

## Signals

### LAUNCH-OUTCOME-DOORBELL

Every tasked ride's end that the launcher sees rings its stack's doorbell — `POST
<AGENT_LOOP_WEBHOOK>/coordinate` with `{repo, unit: "-"}`, plus `stack` and `loop_ns:
<stack>-agents` for a graduated stack — so the scan's next pass runs now instead of on its schedule
(`REPLAY:doorbell-ring`, :3961–3985). Best-effort: a failed ring is silent, and the
[switchboard](../../../../docs/glossary.md) routes a repo-only ring to its stack. A ride that
re-admits or retries exits before the ring; the re-entered launcher rings at its own end.

**World:** `launcher-vars`, webhook `http://doorbell.test/coordinate`.

| description | world | stack_row | body? |
|---|---|---|---|
| no-retry-cell-seen | launcher-vars | not graduated | `{"repo":"test-project","unit":"-"}` |
| a graduated stack | launcher-vars | `graduated: true`, stack `oracle` | `{"repo":…,"stack":"oracle","loop_ns":"oracle-agents","unit":"-"}` |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-OUTCOME-DOORBELL.md"

</details>

### LAUNCH-OUTCOME-PHASES

The launcher publishes the two phases it owns as they close, so a degraded node cache or a slow
dispatch is measurable after the fact: `agent_run_phase_seconds{phase="dispatch-gates"}` (argv to
the pod create) and `{phase="pod-spinup"}` (create to Ready), pushed as one gauge family to
`<pushgateway>/metrics/job/agent_run_phase/project/<repo>/issue/<n>/round/<r>/role/worker` on each
close (`REPLAY:run-phase-metric`, :172–208). The list ends at pod-Ready by design: a phase the launcher
could close only if it outlived the ride would be missing on most rides (the precondition above);
the in-pod breakdown is finalize's. An unknown phase name pushes nothing; an unreachable Pushgateway
warns once and never affects the ride.

**World:** `launcher-vars`, five launcher processes dispatching `openrouter-operator#42` round 2.

| description | world | phases_closed | pushes? |
|---|---|---|---|
| run-phase-metric | launcher-vars | dispatch-gates, pod-spinup | one push per close, the family re-pushed whole |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-OUTCOME-PHASES.md"

</details>
