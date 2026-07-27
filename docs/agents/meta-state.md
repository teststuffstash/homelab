# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).

_Session meta-11 live 2026-07-26 (~15:30Z bootstrap; both standing watches armed):_

- **UC-1 agentic arc — KIND BAR MET, prod blocked on the corpus roll-forward.** Kind:
  deterministic leg CI-gated (#146/#147/#148) AND the agentic leg PASSED live (goose 1.28 +
  deepseek-v4-flash on ci-runner-01, fixture corpus: canonical UC-1 + 2 hard cases clean,
  4 gaps posted on #84 — 2 real shapes, 2 predicted meta-prompt noise). **PROD: the first
  agentic probe found a REAL OUTAGE** — server/corpus schema skew (#141's `short_name_fold`
  in the rolled server, pre-#141 corpus digest served) crashed the stdio child on every
  statute call, both replicas, pods Ready throughout, no alert. Root-caused by draining the
  gateway's unread child-stderr PIPE via /proc/1/fd/7 (TICK-LOG will carry the day). Filed +
  QUEUED: #152 (respawn/die-fast + honest readiness + stream child stderr), #153 (topology
  spread — dispatched), #155 (corpus schema_version contract — the guard); #151 delivered
  (PR #154 in review); FU-099 filed (synthetic blackbox monitoring — nothing alerted).
  Remediation v2: iac#233's targetRevision rollback was SILENTLY OVERRIDDEN in minutes by
  the evening merges' auto deploy-bumps (lesson: a rollback via the bumped knob loses to the
  next bump) → iac#239 pins mcpServer.image.tag=2026.7.25-gfc4b537 in $values (bumps can't
  move it; loudly commented). Prod pinned+stable (tools/call 200). ⚠ #159 (schema gate,
  gated+merging) makes post-#159 servers REFUSE unstamped corpora — and jbtlm's corpus is
  built by a pre-#159 image = unstamped (user_version 0). REFINED ROLL SEQUENCE:
  (1) jbtlm Succeeded → release corpus → ONE iac PR: new corpus digest + values pin MOVED to
  the post-#157/pre-#159 server tag (casefold schema + /healthz + respawn, NO version gate —
  find it via the deploy-bump for #157's merge commit) — NOT removed;
  (1b) prod probe run 4 = the definitive verdict; then QUEUE fleet#158 (chart healthz);
  (1c) pin-follow workflow-ert to a post-#159 image → start-from=build rerun → FIRST STAMPED
  corpus → second paired iac PR (digest + REMOVE pin entirely) → schema gate live E2E; (2) re-run the prod
  agentic probe (probe-prod.sh on ci-runner-01; ephemeral key
  oracle-fleet-adhoc-probe-uc1-kind expires ~00:50Z — remint if needed) for the true prod
  verdict; (3) after the roll-forward: QUEUE fleet#158 (chart httpGet /healthz readiness — held
  unqueued because the values pin's old image has no /healthz; queueing it earlier = a
  self-inflicted NotReady outage); (4) then the suspended `mcp-probe` CronWorkflow manifest
  (operator lane) + #84 harvester via the loop. #152 DELIVERED (#157 merged through the
  codeowner gate — SRV-SERVE-READINESS contract; respawn+latch, /healthz, stderr streamed). VM cleanup owed: /tmp/probe-* on ci-runner-01 (probe-run.sh holds
  the key+PAT — shred when the prod leg closes), kind cluster `oracle-serve-local` + registry.
- **Pipeline verification run `ert-pipeline-parse-jbtlm`** (Monitor armed): parse SLOW under
  the garage contention (12.6/s at 170k/252k ~19:15Z; ETA parse ~21:00Z, build +~5h).
  Re-verifies latent #140/#141/#143/#144 + first exercise of the #140 build heartbeat + the
  trimmed limits (iac#223). NEXT on Succeeded: verify heartbeat events fired → release the
  corpus (digest-verified through the ADR-095 boundary) → the PAIRED iac roll (corpus digest
  + server forward together — see the schema-skew lesson above); on Failed: read the step's
  JSON events + traceback. wk-01 garage warnings (majfault/sdb IO) expected to clear after.
- **⚠ CONCURRENT SESSION (operator, 2026-07-26 ~18:45Z)**: another session is rewriting
  agentstack under FU-080 — agentstack-shaped errors (loop SA/broker/CronWorkflow machinery,
  odd coordinate ticks) are THAT session's lane: observe, don't clear/fix from here; flag to
  the operator only if it looks like unnoticed real damage. Remove this bullet when FU-080
  lands.
- **retro-session CronWorkflow** (FU-058) deployed SUSPENDED — first hand-fire wants: idle
  fixer queue, an ephemeral capped OpenRouterKey (param `retroKeySecret`), subscription
  headroom for cell A. Cross-review legs manual (`agents/retro-session.sh --review`).
- **FU-015**: observe Monday 2026-07-27's automated cycle (lock bump 03:00 → image cron
  06:00 → self-bump PR → roll; the self-bump is fresh-master-rebased) — then archive.
- **Sleep stack**: unchanged — sleep first goal (specs + evidence + Grafana-in-kind system
  testing, FU-095 prereq block); then FU-044 → FU-080 graduation → FU-095 (c)→(b)→(a).
- **Standing watches (die with the session — re-arm per the skill)**: meta-watch-loop.sh,
  2h heartbeat, plus chain watchers (this session: jbtlm run monitor). Probe lessons live in
  the skill + here: zsh no-word-split hits inline Monitors AND inline Bash — put probes in
  bash script files and DRY-RUN the exact probe under the same interpreter before arming
  (meta-11 burned two monitor generations on this + an invalid jsonpath together); kubectl
  jsonpath canNOT range Argo's .status.nodes (a map) — probe step pods via the
  `workflows.argoproj.io/workflow=<name>` label instead; probe-the-pod-not-the-deploy,
  orphan monitors from dead sessions duplicate events — stop on sight; `mergeStateStatus:
  BLOCKED` is the NORMAL checks-pending state, not stuck (meta-11 false alarm — only DIRTY /
  closed-unmerged / deadline-passed are alarms). Noted benign single: coordinator dispatch
  pod-name (HHMMSS) collided with a <24h-old terminal same-name pod → one tick Error,
  level-trigger re-fired clean; file a class fix only if it recurs.
