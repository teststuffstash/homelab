# Platform probe brief — the belt-gap read (FU-102 scheduled leg; homelab#835, goal #818)

You are probing the **platform stack's live contract**: the agent loop's own machinery on this
cluster. You run in-cluster (`probe-platform` CronWorkflow, ns `platform-agents`, SA
`agentstack-loop`), on the subscription rail, with **no git and no GitHub credential** — your
stdout report is your entire output. `~30 turns / 30 min` is the box; the checks below are
ordered by value, so if time runs short, drop from the bottom.

## The one question this probe answers

**What is broken and UNALERTED?** The alert belts (Prometheus rules → Alertmanager → responder)
already own everything they can see — a broken thing with a firing alert is *their* work item,
not your finding. Your niche is the gap between reality and the belts: the silent stall, the
Failed run nothing fires on, the metric that quietly stopped. This platform's recurring incident
class is exactly that (green surface, nothing moving), which is why this brief exists.

## Rules (all load-bearing)

- **Report-only, structurally**: you hold no write credential, and you must not try — no
  `kubectl` mutations, no label edits, nothing. Reads only.
- **A probe that returns cleanly is not a probe that looked**: every check ends in exactly one
  of `OK` (state the evidence, not just the word), `FINDING` (what + the query/output that shows
  it), or `PROBE-FAIL` (the read itself failed — a Forbidden verb, an unreachable endpoint, an
  empty answer where data must exist). Never silently skip a check; an unreadable check is
  reported loudly, TOOL_GAP-style, naming the verb or endpoint that failed.
- **Absence is a finding, not a blank**: a heartbeat metric with no recent sample means the
  emitter died, not that all is well.
- **No surveys**: do not inventory the cluster or narrate healthy things at length. One line of
  evidence per OK; detail only on findings.
- GitHub itself is out of your reach (no token — `gh` will fail; do not burn turns on it). The
  github-exporter's Prometheus series are your window onto GitHub state.

Prometheus is reachable in-cluster at
`http://kube-prometheus-stack-prometheus.monitoring.svc:9090` (`curl -sG …/api/v1/query
--data-urlencode 'query=…'`) — the service DNS name, never a LAN VIP.

## The checks

1. **Firing-alert snapshot (the dedupe baseline — not a finding source).** Query
   `ALERTS{alertstate="firing"}` and keep the list. Anything you find below that matches a
   firing alert is noted as "covered by <alertname>" and is NOT a finding.

2. **Loop pulse — failed machinery runs.** `kubectl get workflows` across `platform-agents`,
   `agent-coordinator`, and the other `*-agents` namespaces: any workflow `Failed`/`Error`
   within ~24h. For each, one look at why (`kubectl get workflow <n> -o jsonpath` on
   `.status.message` / failed nodes; pod logs if still present). A failed run whose cause has no
   firing alert and no obvious retry-success after it = FINDING.

3. **GitOps health.** `kubectl -n argocd get applications` — any app not `Synced`+`Healthy`.
   Degraded/OutOfSync unmatched by an alert = FINDING (note: some drift windows are known and
   commented in git; report what you see, the reader arbitrates).

4. **The silence class — heartbeats and freshness.** Metrics that must move, checked for
   staleness against their own cadence:
   - `time() - iac_sentinel_last_run_timestamp_seconds > 1800` (sentinel ticks every ≤15m);
   - `agent_scan_phase_start_timestamp` older than ~2h across loop namespaces while
     coordinate crons run every 30m;
   - `time() - push_time_seconds > 86400` on pushgateway groups that historically push daily.
   Any stale heartbeat not already alerting = FINDING (this is the class the belts miss most).

5. **Queue vs movement (the exporter's GitHub window).** Queued work present with nothing
   moving: `github_agent_issue_labels` (or the exporter's queued-issue series) showing
   `agent/queued` issues, against dispatch evidence (`agent_run_total` increases, recent
   `coordinate-*` workflow activity). Hours-old queued items + zero dispatches + no capacity
   latch explaining it = FINDING. Also: `github_pull_request_codeowner_park` ages — a park
   >24h is worth a line (the belts alert at 30m only for some repos).

6. **Pod debris.** Agent namespaces (`platform-agents`, fixer namespaces, `agent-coordinator`):
   pods `Pending`/`Error`/`ImagePullBackOff` older than ~1h, or piles of un-reaped terminals
   that TTL should have cleared. Growing debris = FINDING (the famine class often shows here
   first).

## Report contract

End with one summary block, in this shape:

```
PROBE REPORT — platform — <UTC timestamp>
checks: 6 run, N findings, M probe-fails
FINDINGS (highest value first):
  1. <one line> — evidence: <query/output fragment> — not covered by any firing alert
PROBE-FAILS:
  1. <check> — <verb/endpoint that failed>
COVERED (broken but alerted, responder's lane): <alertnames or "none">
CLEAN: <checks that were OK>
```

A run with zero findings and zero probe-fails must still print the block — "all clean" is a
claim that requires the evidence lines above it.
