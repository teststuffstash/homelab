# 2026-09-06 — the switchboard OOMKilled 153 times in a row, and nothing alerted

**Status:** fixed in the scan (label-scoped workflow list) + a fleet outcome belt
(`ArgoWorkflowsFailing`); residuals below. **Impact:** every global `/coordinate` ring from
2026-09-05 ~17:00Z to 2026-09-06 ~10:10Z died before resolving — no repo-dumb ring reached
its stack's doorbell and no capacity fan-out ran for 17 hours. The per-stack crons re-derived
the work on their own cadence (the ADR-120 design's backstop), so the loop kept moving at cron
latency instead of edge latency; nothing was lost, everything was late. Operator-discovered
from the agents-running dashboard ("workflows by phase: 179 failed"), not from an alert.

## Timeline (UTC)

| When | What |
|---|---|
| 09-05 11:00–17:00 | S8's second fan-out sitting: the fleet's retained-workflow count climbs from ~660 to ~980 (review/respond runs under the 7d TTL, 164 `review-*` on the day alone). |
| 09-05 ~17:00 | First `switchboard-*` run OOMKilled (`main: OOMKilled (exit code 137)`, 512 Mi limit). Every run after it dies the same way: 10–19 per hour overnight, 20–73 s into the run. |
| 09-05 → 09-06 | The failed switchboards are themselves retained (`secondsAfterFailure: 86400`), so each one grows the list the next one has to load — a slow self-amplification on top of the day's climb. |
| 09-06 ~11:00 | Operator reads the dashboard. This session's read: 154 switchboard workflows in the namespace, 0 Succeeded, 153 OOMKilled; pod working set peaks 450–504 Mi. |

## Root cause

The scan preamble's **doorbell-collapse** (ADR-106 (5)) absorbs Pending sibling rings before the
first GitHub listing. It did that with an unscoped `kubectl get workflows -o json` in its own
namespace, held the result in a bash variable, and fed it to `jq` through a heredoc. In the
per-stack namespaces that list is a handful of objects. In `agent-coordinator` it is the whole
retained history of the review and responder reflexes — **1,041 Workflow objects, 53 MB of
JSON** on 2026-09-06 — and bash + a second copy for the heredoc + jq's parse tree of it lands
at 450–500 Mi resident. The switchboard's limit is 512 Mi, "sized for a clone + jq, not a board
sweep" (its own comment), which was right about the clone (4.7 MB) and wrong about what the
preamble lists. The threshold was crossed by the 09-05 fan-out day's workflow volume; the same
line had been running under the limit since the collapse shipped.

The Loki tail of every failed run is the same: the `switchboard: ring scope=… (resolver only —
ADR-120)` banner, then nothing — the death is inside the list, before any output.

## Why nothing alerted (the belt audit)

- **No PrometheusRule reads `argo_workflows_*`.** Named as such in the 2026-08-26 reviewer
  404-loop postmortem's belt audit (FU-188 (d), "an `argo_workflows_*` failure consumer or a
  verdict-throughput belt"); not built in the eleven days between. This is that belt's third
  silent instance (08-26 reviewer loop, 08-31/09-02 throttle outages, this).
- **`PodSigkilled` needs a restart.** It keys on container restarts; a workflow pod runs once
  and is never restarted, so an OOMKilled workflow pod is invisible to it by construction.
- **The agent belts watch outputs the switchboard has none of.** `AgentQueueStalled`,
  `AgentRunPhaseSlow`, the dispatch/famine gauges all read the per-stack loops, which kept
  running on cron. A resolver that dies before its first side effect leaves no ledger row, no
  issue, no pushgateway phase — exactly the "liveness ≠ output-watching" shape, one layer up.
- **The dashboard had it** (`argo_workflows_gauge{phase="Failed"}`), and a dashboard is not a
  belt.

## Fix

- **Scan:** the doorbell-collapse list is label-scoped to non-terminal workflows
  (`-l workflows.argoproj.io/completed!=true`); the jq phase filter stays as the belt behind
  the selector. Measured on the live namespace: 0 objects instead of 1,041. The replay fixture
  `agents/replay/fixtures/doorbell/collapse` keeps its recorded world (the stub drops `-l
  <value>` from its key) and its contract legs.
- **Belt:** `ArgoWorkflowsFailing` in `argocd/resources/argo-workflows-alerts/` —
  `sum(increase(argo_workflows_total_count{phase=~"Failed|Error"}[6h])) > 40` for 15m, calibrated
  on the 14-day history (quiet days peak 18–35 per 6h, every incident day 54–133). Fleet-wide
  by necessity: the controller's counter carries no workflow namespace. The description carries
  the class-finding read (namespace + generateName + message, then one Loki tail).

## Residuals

- **`coordinate-perstack-*` exit 141 (SIGPIPE), intermittent** — 8 runs on 2026-09-05/06 across
  platform-agents and oracle-agents, dying ~60 s in right after the doorbell-collapse lines,
  other runs of the same template succeeding. A pipeline writer killed by an early-exiting reader
  under `set -o pipefail`; the three `| grep -q` sites in the scan all feed it small variables,
  so the site is not yet named. Tracked as FU-219.
- **The 154 failed switchboard records** age out on their own 24h TTL; not deleted (they are the
  evidence, and the Loki tails are the same either way).
- **Controller memory** sits at 25% of its 1 Gi limit with ~1,100 retained workflows — the
  "~590 measured 2026-08-18" figure in `WorkflowControllerMemoryNearLimit`'s description is
  stale by 2×; the alert's threshold still has 3× headroom, so left as-is.
