# Fixture notes

## FU-249 — the responder paused for a week (PR#1746)

No fixture applies. The change is a data filter on the `responder` Sensor's `alert-dep`
(`agents/coordinator/responder-argo.yaml`) that no Alertmanager webhook can satisfy, so Argo Events
never submits a `respond-*` Workflow. It sits entirely in the Sensor object — before any code the
replay harness exercises (the harness replays the WorkflowTemplate's pod-side blocks; it does not
model Argo Events dependency filtering). The `respond` WorkflowTemplate itself is byte-identical,
so every existing responder fixture keeps asserting exactly what it asserted before. What pins the
pause is live: `responder_triage_sessions_today` flat at 0 while alerts fire, and no `respond-*`
Workflows in `agent-coordinator` (`argo list`). Re-enabling (delete the filter) is the same
no-fixture change in reverse.

## FU-072 — removing the kata endpoint-IP rewrite and `dnsPolicy: None`

No fixture applies. The deleted code (`resolve_ep` plus the three docker-mode rewrites of
`PROXY_URL`/`TS_ENDPOINT`/`PGW_URL`, and the `dnsPolicy: None` + LAN-resolver lines in
`KATA_BLOCK`) sits **outside every `>>>REPLAY:` sentinel** in `agents/agent-session.sh`, and the
harness composes a clause only from marker-delimited blocks (`run.sh` §the sentinel extractor) —
so no fixture can reach it, and none could before the change either.

Marking it would not help. What is left at the first site is a comment; the second is a single
static string assignment (`KATA_BLOCK=$'  runtimeClassName: kata'`). Neither makes a call, so the
action-stream model — the harness's only assertion mode — has nothing to record. Asserting "the
rendered pod spec carries no `dnsPolicy`" needs an assertion over the ASSEMBLED manifest, which is
the same `mode: exec` / template-snapshot extension homelab#1113 asks for below.

What pins this change instead is a live probe, recorded in the PR (#1372) and in
`docs/spikes/kata-service-vip.md`: a kata pod under the enforced fixer CNP reaching
`openrouter-proxy`, `garage` and `prometheus-pushgateway` through their service VIPs, with
`openrouter.ai:443` still denied as the negative control. The regression signature is
`AgentWorkerEgressDropped` carrying a bare pod IP as its Hubble destination.

## homelab#1113 — dispatch-time `bash -n` assembly guard

No fixture applies. The guard added in `agents/reviewer-session.sh` runs **host-side** before a
pod is spawned — it checks the assembled heredocs (`$PREP`, `$TOUCHESPART`, `$UPLOADER`,
`$RUNPART`) with `bash -n` and exits with a FATAL diagnostic before reaching any code that the
replay harness exercises (the pod-side blocks extracted via sentinel markers). The guard's
entire effect is "exit 1 before pod creation", which is outside the replay harness's scope
(the harness stubs `gh`/`kubectl` and replays pod-side blocks; it does not stub `bash -n` or
simulate heredoc assembly).

A fixture that tested the guard would need to:
1. Set up the four heredoc variables with controlled content
2. Run the `bash -n` check
3. Assert the FATAL message on syntax error or silent pass on clean syntax

This is a pure-bash operation with no external calls, so the action-stream assertion model
(the harness's only assertion mode) has nothing to record. A future `mode: exec` or
`mode: exit-code` extension could cover this class.