# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).

_Session meta-12 ENDED 2026-07-27 ~13:10Z (operator-directed stop; watches stopped). Sleep
`*.sleep` delegation applied+verified (64c781f); sleep spec-bug queue (#39-47) + sleep-iac#22
are the LOOP's lane; FU-088 latch lifted ~12:55Z (agent-runtime#24 review dispatched — FU-096
tail chain running, see its bullet); FU-108 filed (queue gauge blind to private repos — fix
before trusting AgentQueueStalled)._

- **🔴 SESSION HANDOFF (meta-14, 2026-07-28 ~14:00Z — written at 98% context; a fresh session
  resumes HERE).** WORLD: sleep coordinator RE-ENABLED (sleep-iac#38, CR enabled=true); oracle +
  platform coordinators + the two global reflexes STILL paused (from the earlier "pause the world").
  wk-metal-03 CORDONED (kata block-device broke there under OOM). All watches/monitors DIE with the
  session — re-arm per the meta-coordinate skill.
  SHIPPED THIS SESSION (all on master + deployed): **FU-114** (fixer 3-layer context: launcher env
  card from claim knobs + unify `--recipe` onto goose + `task/*` recipe selection + `.agents/build.yaml`
  + the #67 kind-mirror lesson) — homelab#60/#61 + sleep-tracking#70 merged; **FU-115** (red merge-path
  edge: exporter `maybe_dispatch_cired`→`/coordinate` + content-based `ci-red` scan clause + cap→
  `agent/arbitrate` MP-T13) — homelab#62 merged, exporter deployed. **E2E on #48 PROVEN**: red-doorbell
  fired → `ci-red` dispatched build.yaml → deepseek RAN `docker info`+read mirrors (the behavior change,
  vs r3's blind give-up). FUs filed: FU-114, FU-115, FU-116 (kata storage fragility).
  IN-FLIGHT / NEXT (in priority order):
  1. **FU-112(b) — the OOM-posture fix, HALF DONE.** #63-66 (homelab, closed) were ONE OOM cascade:
     the r4 kata ride pushed wk-metal-03 into memory pressure → OOMController killed the BestEffort
     cilium/longhorn DaemonSets → broke the block-device attach (= FU-116a root cause). APPLIED
     (tofu, master): cilium-agent + longhorn-manager/-driver got memory requests (512/512/256Mi) +
     a new `ContainerMemoryNearLimit` alert (tofu/monitoring.tf). BUT QoS came out **Burstable, not
     Guaranteed** (unresourced init/sidecar containers) → oom_score ~934, INSUFFICIENT. DECISION
     (operator, this session): do the **Talos kubelet reservation** approach instead of chasing
     per-container Guaranteed — on the KATA nodes ONLY (wk-metal-01/02/03; they have the k3d/kind
     memory spikes). Numbers: `systemReserved.memory 384→512Mi`, `kubeReserved.memory 0→256Mi`,
     `evictionHard.memory.available 100Mi→512Mi` (the key one — kubelet evicts the non-critical ride
     ~½GiB before the kernel OOMs; cilium/longhorn are system-node-critical so exempt). Node math:
     cap 7.61GiB, alloc 7.14→~6.6GiB; ride 5.1 + daemon-reqs 1.3 = 6.4 < 6.6, still fits. ⚠ desktops
     + Talos VMs (cp-01/wk-01/wk-02/thinkcentre/hp-01) want the same EVENTUALLY but NOT urgent (no
     kata rides there — different math). NEXT: find the Talos kata-node machine-config patch, add the
     kubelet block, plan, apply, verify (allocatable dropped + a ride still schedules), THEN uncordon
     wk-metal-03. Keep the Burstable requests + the alert.
  2. **#48 test conclusion**: r5 (deepseek, build.yaml) on wk-metal-01 PUSHED a commit (head 399ddaa6
     — real progress: it edited test-integration.sh, tried a new cluster name) but hit ANOTHER kata+dind
     bug: `/var/lib/docker … read-only file system` (block-PVC/overlay corruption, even on wk-metal-01)
     → exit 255. CI still FAILURE. So kata+dind storage is fragile BEYOND wk-metal-03's OOM — a broader
     FU-116/FU-081 concern (the block-PVC re-hotplug + read-only-fs after a dind restart). The FU-115
     ci-red machinery will re-dispatch (r6) or arbitrate at the cap — watch it.
  3. **Phase 4 (operator's plan, still queued)**: switch sleep workerModel→claude/haiku in sleep-iac
     (post-#48-flip was planned) + author the k3d→kind migration task for sleep-tracking (model on
     oracle-fleet scripts/e2e-kind.sh — kind + the `kind_mirror` hosts.toml pattern that #67 needs);
     priority-time it with the FU-110 pin. Do AFTER #48 resolves.
  4. **Uncordon wk-metal-03** once FU-112(b) Talos change lands + verified.
  NOTE: the kata+dind storage fragility (FU-116, read-only-fs / block re-hotplug) may be the real
  blocker for docker rides — bigger than the OOM. The operator flagged "kata is a lot + unfinished."
- **✅ FU-114 + FU-115 SHIPPED + E2E-PROVEN, then blocked on a kata infra bug (meta-14, 2026-07-28
  ~13:00Z).** All merged to master + deployed: FU-114 (env card + `--recipe` unify + `task/*`
  selection + build.yaml + #67 kind-mirror lesson), FU-115 (exporter red-doorbell `maybe_dispatch_cired`
  → `/coordinate` + content-based `ci-red` clause + `RED_ROUNDS_MAX` cap → `agent/arbitrate` MP-T13).
  **E2E test on #48** (sleep coordinator RE-ENABLED sleep-iac#38; pushed 061fcfe to re-fail CI):
  the WHOLE software chain fired — exporter red-edge POST → coordinate-sleep `ci-red` dispatch → ride
  r4 (deepseek) → **L3 picked build.yaml** → and the KEY behavior change: **deepseek ran `docker info`
  + read the mirror vars instead of r3's blind "I can't run k3d"**. THEN hit a kata infra wall:
  **r4 dind CrashLoopBackOff on wk-metal-03 — kata can't re-hotplug the `/dev/docker-scratch` block
  device (FU-081 longhorn-scratch) after a dind restart** (`"Cannot open disk path… No such file"`,
  PVC Bound). Orthogonal to k3d-vs-kind (both need dind+block PVC) → Phase-4 kind won't dodge it.
  Also: r1's ephemeral docker-lib PVC still Bound 18h (ephemeral-PVC GC gap). **PENDING OPERATOR
  DIRECTION** on the kata block-device (investigate/cordon wk-metal-03 / delete-r4-and-re-dispatch /
  own incident+FU). Remaining phases: 4 = switch sleep worker→claude/haiku + author k3d→kind
  migration task (oracle e2e-kind.sh pattern) priority-timed; 5 = meta-coordination (heartbeat armed).
  NOTE: sleep is now UN-paused (coordinator.enabled=true); oracle+platform+global reflexes still paused.
- **🛑 (PARTLY LIFTED) WORLD PAUSED (meta-14, 2026-07-28 ~07:45Z, operator "pause the world").** SLEEP
  re-enabled 2026-07-28 ~12:33Z (sleep-iac#38) for the E2E test — see the bullet above. The loop was
  FROZEN while the operator investigated machinery gaps. State of the freeze (all durable/git):
  - sleep coordinator.enabled=false (sleep-iac#37 merged), oracle coordinator+reviewer=false
    (oracle-iac#256 merged), platform coordinator=false (homelab
    agents/fixer/openrouter-operator/agentstack.yaml). All three verified live = false.
  - Global kill switch: coordinator-reflex + review-reflex suspend=true (homelab reflexes-argo.yaml
    5da23c0), verified suspended. ledger-reflex/model-scout left running (harmless, no dispatch).
  - No jobs were running at pause. Scans still tick but report-only (coordinator.enabled=false).
  - **RESUME** = flip each coordinator.enabled back to true (the 3 -iac/claim files) + suspend
    false on the two reflexes, in git; ArgoCD/Crossplane re-render. Per-stack review-<stack> crons
    were left as-is (idle — no green PRs); oracle review is off, sleep/platform review nominal.
- **The units-only gate fix (homelab#60 MERGED 06:19Z, on master 3cd3160)** — DONE + verified live
  (post-fix scan dispatched ci-red-stale#61). Operator wants to review it deeper. Widened C6 too
  (agent/review closeouts). NOT reverted by the pause.
- **DEEPSEEK #48 TRANSCRIPT FINDINGS (operator asked: did it get a clean `devbox run ci` in-pod?).**
  Read from s3://agent-transcripts/sleep-tracking/issue-48/worker-r3.../run.log via the
  transcripts-viewer PVC (bucket-sync container, /mirror/...). ANSWER: **NO.** r3 (deepseek-v4-flash)
  said verbatim "Actually, I can't run k3d in this environment. Let me focus on what I can do"
  (run.log L2059), ran only the **117 unit tests** (pytest), and self-reported `ci_passed:true`
  off THOSE — never `devbox run ci`/`test-integration` (the k3d/Garage/Grafana gate that's red on
  the runner). manifest: reproduced:false, ci_passed:true, exit clean, harness_exit 0, **0 commits
  pushed** (branch head still r2's 47b61cb6). So it is NOT "works on my machine, fails on the
  runner" — the integration part never ran in-pod. Machinery gaps this exposes (for the operator's
  deeper look — NOT filed as FUs yet, pending the operator's framing):
  1. `ci_passed` is a goose SELF-REPORT and here reflected unit tests, not the real `devbox run ci`
     exit — a worker that can't run the integration gate still reports green. (Lineage:
     TICK-LOG:247 "ci_passed=true + no pr_url must NOT be clean"; archive:258 "ci_passed is not
     False" clean-gate. Next step: finalize should VERIFY ci_passed vs the actual `devbox run ci`
     exit, or the recipe must key ci_passed off the command's real exit, not a schema self-report.)
  2. A no-op round (reproduced:false, 0 commits) on a RED PR exits "clean" AND its run-stats comment
     refreshes PR#61.updatedAt → ci-red-stale staleness clock reset → suppressed ~4h. A round that
     changes nothing on a red PR shouldn't count as progress or reset the timer.
  3. Open question: did r3's ci-red-stale ride actually have docker (kata+dind)? r1/r2 ran k3d fine
     (r1 even OOM'd the node); r3 said it couldn't. Couldn't confirm DOCKER_HOST from the transcript
     — worth checking whether the ci-red-stale/fix-round dispatch preserves fixer.docker=true, or
     deepseek just gave up (weak model). If capability is dropped, a docker-gated CI failure is
     UNFIXABLE by the fix-round path as configured.
  FU-114 3-LAYER BUILD (2026-07-28, world still paused — PRs open, NOT merged, offline-verified only):
  - L1+L3 = **homelab#61** (`fu-114-fixer-context-l1`): render_env_card() (docker+verify/egress/round/
    write-scope from claim knobs) spliced into the recipe at {{PLATFORM_ENV_CARD}} marker (else after
    `instructions: |`, else WARN — never FATAL); unify `--recipe` onto goose (closes the ADR-094 goose
    gap); L3 launcher task/<class>→.agents/<class>.yaml selection; task/{fix,build} in composition
    $platformLabels. NO auto-merge (untested-E2E core machinery — the goose `--recipe` path esp.).
  - L2 = **sleep-tracking#70**: `.agents/build.yaml` (build-task brief) + fix.yaml marker + de-misled
    "no-real-data sandbox". Both recipes valid YAML (yq), one marker each.
  - GOOSE PATH VERIFIED (2026-07-28, goose 1.28.0, throwaway agent-base pod): `--recipe <abs> --params
    issue=N` accepted; `--explain` loads both; `--render-recipe` shows the actual env card (all fields,
    literal, no {{ }} collision) atop instructions + {{ issue }}→48, valid YAML, marker AND fallback
    paths. Only recipe content+path changed; goose exec unchanged. Evidence on homelab#61.
  - RELABEL #48 → task/build = the FINAL step, AFTER #61 merges + ArgoCD renders task/build authoritative
    (doing it before = reconciled away). NEEDS: review both PRs → controlled goose dispatch to verify the
    --recipe path → merge → relabel #48 → (un-pause sleep to run #48 on a capable model).
  4. deepseek-v4-flash is too weak for this task (3 rounds, gave up as "infrastructure not a bug").
     When resuming #48, escalate the worker model (claude/haiku, the planned post-#48 primary, or
     sonnet) — the loop can't self-heal this with the current chain (fallbacks only swap on STRIKES,
     and a clean-but-useless exit is not a strike).
  DESIGN FILED (2026-07-28): the ROOT of gap #1+deepseek's no-docker assumption is now
  **FU-114 / [`docs/agents/fixer-context.md`](fixer-context.md)** — fixer context is three layers
  (platform env card from claim knobs + stack task-type briefs fix/build + deterministic `task/*`
  selection); operator chose launcher-rendered env card + design-doc-first. Build order: L1 env card
  → L2/L3 build.yaml+task label → ci.sh fail-closed. Operator DE-PRIORITIZED forcing `devbox run ci`
  (GitHub CI is the real gate; in-pod ci_passed stays best-effort). OPEN sub-question for the walk:
  did r3's ci-red-stale ride actually get `--docker` (derivation from the claim), or did the
  fix-round dispatch drop it? — decides if gap #3 is real. Next in the top-down walk = L1 build or
  that sub-question, operator's call.
- ~~FU-096~~ COMPLETE — already ARCHIVED in follow-ups-archive.md with in-pod numbers
  (23-25s worst-node; my independent 17:33Z measure on sleep#39 r1 read 23.6s, seed+substituter
  clean). Stale-bullet lesson: the archive, not this file, was current — recheck the tracker
  before extending a remembered chain. (One benign nix warning on rides: RO
  `/stack-cache/store/realisations` — expected, ImageVolume is read-only.)

- **UC-1 agentic arc + schema arc: CLOSED (2026-07-27 ~09:50Z).** Operator bar met kind+prod
  (TICK-LOG carries the full story). Roll 2 live: stamped corpus sha256:3e45daea… + current
  server g60ef627, no pins, #159 gate validating, replicas spread across nodes (6GB
  ImageVolume per node — rollouts ~15-20 min, size deadlines accordingly). #158 DELIVERED (#163
  merged; /healthz readiness verified LIVE in prod, 2/2 Ready) — ALL outage guards enforced. OPERATOR-PACED NEXT: triage 🌱#160 (title resolution) + #84
  prompt-corpus parameterization (the evidenced prerequisite for scheduled prod probing);
  after #84's corpus is prod-valid, the suspended mcp-probe CronWorkflow manifest in
  oracle-iac (operator lane) + #84's gap harvester. #109 operator-paced.
- **SLEEP ROLLOUT — FIRST UNSUPERVISED CYCLES OF THE NEW MACHINERY (role-build session,
  2026-07-27 ~15:30Z).** The sleep coordinator re-enabled (sleep-iac#27) over a queue that
  exercises everything built today: sleep-tracking#48 (system-test gate, lg, chart/.github
  authorized) dispatches FIRST → spec bugs #39-41/#44-47 (xs-sm; #42/#43 dep-held on #48) →
  sleep-iac#22/#25 through the NEW -iac dispatch class (sleep-iac is a fixer since FU-106).
  WATCH posture, not drive: every new clause pays a lesson on its first live run — C6
  merged-closeout+harvest fires on the first merge; arbitrate/ci-red-stale/infra-enrich on
  their triggers; the responder v2 + SLO teeth + deterministic revert run underneath. Sweep
  the platform queue (homelab 🚨 issues) FIRST and run `agents/meta-alert-crosscheck.sh` each
  heartbeat (it caught the multi-alert stdin bug on run 1). Known residuals: FU-095 legs
  a/b/c (evidence program; fusion canary queued as the audit-class candidate), FU-058 first
  hand-fire (wants idle fixer queue + headroom), FU-090 legs b/c, FU-086 compound + cron
  relax, FU-102 blocked on the UC-1 corpus (other lane). Remove this bullet when the first
  full cycle (issue→merge→C6→deploy) is observed clean.
- **Sleep chain post-#48 flip (operator directive 2026-07-27 ~16:00Z)**: scout-#40 entrants
  graduated — sleep-iac#29 (fallbacks + sleep-iac claudeTier:true) auto-merge armed,
  stacks.json mirror synced. NEXT: when sleep-tracking#48 MERGES → one-liner PR to sleep-iac
  flipping `workerModel: claude/haiku` (comment in the claim marks the plan). Operator starts
  the FU-095 router arc themselves. FU-106 gate design SETTLED (2026-07-27 rulings): no human,
  no blocking review — docs/agents/iac-lane.md + iac-lane-fsm.yaml carry it; build list =
  IAC-G01..G06 (rung-0 sleep PostSync smoke first).
- **IAC-LANE BUILD (FU-106) — PARKED FOR A FRESH SESSION (operator, 2026-07-27 ~17:00Z).**
  Design is SETTLED and committed (f75eda7): `docs/agents/iac-lane.md` (doctrine: no human,
  no blocking review; deterministic CI + post-merge machine) + `iac-lane-fsm.yaml` (gap
  register IAC-G01..G06 = the build list, lint-green). Pick up by building in §Build order:
  (1) rung-0 sleep PostSync smoke — author the issue into sleep-iac (spec-anchor IAC-G05,
  xs/sm: PostSync hook Job in the wrapper chart, curl /healthz + one real read, failure →
  sync Failed → existing Degraded path) and let the LOOP build it; (2) IAC-G02 revert
  widening + IAC-G03 cluster-verifying C6 (homelab-side, small); (3) IAC-G04 policy sentinel
  (closes the #28 hole / IAC-G01); (4) IAC-G06 advisory lens; rungs 1/2 wait on oracle
  gateway metering (T3c). Also parked nearby: -iac devops model chain (interim per-repo
  override; FU-095(a) first axis = repo-type). another session is rewriting
  agentstack under FU-080 — agentstack-shaped errors (loop SA/broker/CronWorkflow machinery,
  odd coordinate ticks) are THAT session's lane: observe, don't clear/fix from here; flag to
  the operator only if it looks like unnoticed real damage. Remove this bullet when FU-080
  lands.
- **retro-session CronWorkflow** (FU-058) deployed SUSPENDED — first hand-fire wants: idle
  fixer queue, an ephemeral capped OpenRouterKey (param `retroKeySecret`), subscription
  headroom for cell A. Cross-review legs manual (`agents/retro-session.sh --review`).
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
