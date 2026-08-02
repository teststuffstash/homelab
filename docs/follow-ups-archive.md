# Follow-ups archive (rolling)

Resolved `FU-NNN` items land here, **trimmed to the grep residue**: what shipped, when, the
acceptance evidence, any gotcha. This is a *rolling* buffer, not a permanent record — an entry
stays while the work is fresh (≈a month) so in-flight sessions can still `git grep` the id, then
gets deleted; after that, `git log -S FU-NNN` is the record. `devbox run follow-ups-lint` treats
ids here as still defined (references elsewhere stay legal while archived) and warns when an
entry is past its freshness window. Deleting an expired entry: scrub any remaining references in
living code/docs first (references in the TICK-LOG / `docs/adr.md` are historical and exempt).

- **FU-114** *(archived 2026-08-02)* — **Fixer-context L2/L3 BUILT.** L1 env card shipped earlier;
  L2 `build.yaml` on sleep (#48 first task/build) + oracle (#166 port); L3 = task/* label →
  `class=` in scan dispatch units (queued + c4c5) → session uses `.agents/<class>.yaml` verbatim.
  Design + residual (ci.sh fail-closed = operator's call, unscheduled): docs/agents/fixer-context.md.
- **FU-123** *(archived 2026-08-02)* — **In-pod agent-finalize arm-auto-merge ran tokenless since
  FU-089** (6 consecutive un-armed PRs; mount deleted, gh had no GH_TOKEN). Fix: agent-runtime#26 —
  `_fresh_gh_env` fetches broker→mount→env with the SA Bearer. **Acceptance met same day**:
  sleep-tracking#109 (first ride on 2026.8.2-gfbb2b739f806) arrived `armed_by_pod=true` +
  `stats_comment_by_pod=true`. Evidence: docs/incidents/2026-07-29-agent-finalize-bookkeeping.md.
- **FU-109** *(archived 2026-08-02)* — **Subscription latch tiered by consumer weight — shipped
  as ADR-096 P2.** `/anthropic-limit?tier=dispatch|heavy` applies `model-classes.json`
  `tier_thresholds` composed as **max(per-window FU-088 threshold, tier)** — a ~30s dispatch unit
  (coordinator-scan/-session, responder; `SUBSCRIPTION_TIER=dispatch`) now defers at 0.90 on the
  5h window instead of 0.80, while the operator's 7d=0.95 stays binding; heavy ≡ bare probe. The
  FU-088 pod-count semaphore moved server-side (the proxy counts `subscription-session=claude`
  pods cluster-wide, new `openrouter-proxy-semaphore` ClusterRole; the launcher kubectl copy is
  now the belt). Attribution: `anthropic_requests_total{consumer=}` (ref-derived secret name) +
  a stacked dashboard panel — a stalled window is attributable at a glance. Verified via jail
  smoke (tier composition, breaker, semaphore fail-open) + live probe. Relates FU-088 (archived),
  FU-095, FU-113, ADR-096.
- **FU-080** *(archived 2026-08-01)* — **Per-stack coordinator/reviewer rendered from the
  AgentStack claim — COMPLETE; all three stacks graduated.** The stack jail now controls its whole
  loop by construction: the Composition renders `<stack>-agents` + the namespaced `agentstack-loop`
  SA/Role/Bindings, `coordinate-<stack>` + `review-<stack>` CronWorkflows, and the graduated
  doorbell/review edges route data-driven on `body.loop_ns`; loop git tokens are minted centrally
  and served only via the TokenReview-gated `/loop-git-token`, so the loop home holds **zero
  cross-boundary Secrets** (one documented exception: the write-only transcripts S3 key). Oracle
  graduated 2026-07-18; sleep + platform 2026-07-26; the last leg (per-stack review edge) shipped
  as FU-100, archived 2026-07-27 — nothing remained after that. Design, the four claim knobs, the
  credential model and the RBAC/Argo gotchas: [`docs/agents/agentstack.md`](agents/agentstack.md)
  §Decisions + §Operational notes; airlock pattern in `platform-and-stacks.md`. Note carried
  forward: docker-ride dispatch **from the jail** still waits on FU-072; model-scout + ledger stay
  global by design. Relates FU-045/FU-048/FU-050/FU-066, ADR-093/ADR-094.
- **FU-118** *(archived 2026-07-31)* — **Offline rides couldn't `devbox add` a NEW package.** An
  offline add wrote `/nix/store/placeholder-*` into devbox.lock that boot-crashed the NEXT round's
  `devbox install` (#71 r4/r5 died here). Fixed BOTH legs 2026-07-31: **(a)** launcher pre-flight
  (agent-session.sh guard (d)) REFUSES dispatch if the target branch's devbox.lock carries a
  `placeholder-` (belt; verified clean-master no-refuse + synthetic-placeholder caught); **(b)** the
  `devbox-search` caching proxy (`argocd/resources/devbox-search/`, nginx proxy_cache of
  search.devbox.sh, BGP VIP **192.168.40.27**, `DEVBOX_SEARCH_HOST`) — `devbox add` now resolves
  in-band, WAN-free (the resolver returns store paths; the LAN nix cache serves the binary). VERIFIED
  live: `DEVBOX_SEARCH_HOST=http://192.168.40.27 devbox add ripgrep` → REAL store path
  (`/nix/store/…-ripgrep-15.2.0`), no placeholder; X-Cache-Status active; the agent-worker-egress CNP
  allows .40.27 (composition.yaml). `DEVBOX_SEARCH_HOST` override confirmed in the devbox 0.17.5
  binary. SERVICES.md row added; interim (pre-provision on master) stays a valid fallback. Gotcha:
  .40.22 was oracle's gateway VIP (ADR-092) — landed on .40.27.
- **FU-119** *(archived 2026-07-31)* — **`dockerRepos` rides lacked a `docker` CLI** (only
  `$DOCKER_HOST`). kind/k3d shell out to the `docker` binary, not the raw API, so the in-ride gate
  couldn't stand up a cluster (#71-r7 `agent/blocked`). Fixed per-stack via `docker-client`
  (nixpkgs CLI-only) in `devbox.json`: **sleep-tracking PR#81** (2026-07-31, resolved online per
  FU-118, `devbox run -- docker --version` → 29.6.2); **oracle-fleet already carried it**. Both
  docker stacks now run the in-ride kind gate (proven: sleep gate GREEN on the proxmox-vm runner).
  Gotcha: the socket alone is never enough — the CLI is required. NOT done (optional, deferred, low
  value while the per-stack pattern works): the class-fix — bake `docker-client` into agent-base so
  future `dockerRepos` stacks get it without a per-stack add.
- **FU-110** *(archived 2026-07-27, same day as filed)* — **Operator dispatch-priority knob =
  the GitHub issue PIN.** Born when #39 beat #48 (ascending-number order inverted the operator's
  gate-first plan). Shipped in coordinator-scan.sh (99ee5a9): `isPinned` rides the existing list
  call; pinned queued units prepend WITHIN the queued-dispatch clause (in-flight recovery still
  wins); `gh issue pin N` = the knob, max 3/repo caps the ladder. The planned `agent/priority`
  label was REJECTED at implementation: the claim's IssueLabels set is authoritative ("anything
  else gets deleted") — an ad-hoc label self-destructs, and the taxonomy lives in the
  composition (the concurrent FU-080 session's file). Verified live: pinned #48 picked first,
  dep-blocked #42/#43 stay blocked. Blocking-vs-preference split → FU-111.
- **FU-099** *(archived 2026-07-27)* — **Blackbox synthetic monitoring LIVE + verified.** DIY
  blackbox-exporter (argocd/resources/blackbox/, pinned v0.27.0) + Probe CRs: `mcp_post` module
  (JSON-RPC initialize POST; 401=PASS — credential-free gateway-process aliveness, the 5xx/503
  outage signature is the target; the child-exercising tools/call check is the FU-102 prober)
  + cheap GETs on the LAN fronts (grafana/argo/transcripts/specs-oracle). Verified live same
  hour: probe_success=1 on mcp + grafana. `EndpointProbeFailing` (10m, symptom wording) stamps
  `stack: oracle` on oracle endpoints — feeds the responder's explicit-label routing; FU-104
  renders per-stack probes+rules from claims and supersedes the hand list.
- **FU-096** *(archived 2026-07-27)* — **Stack devbox-cache: DONE, target met.** The stack's CI
  publishes `/devbox.lock` + xdg eval seed + the closure as a signed-upstream `file://` nix
  cache (`devbox-cache.reusable.yml`; both stacks publish, packages public); the launcher
  ImageVolume-mounts `:latest` on EVERY ride (kata canaried green) and agent-base seeds
  `~/.cache` behind an exact-lock guard. **Numbers**: jail 54.7s cold-eval → 7.1s seeded;
  in-pod worst-node (kata laptop) install ≈ 23-25s vs the retro-r1 ~35-min bring-up
  pathologies. Honest decomposition: the image's own baked HARNESS eval cache overlaps the
  project pins, so today the seed adds little on top — it carries the DRIFT delta (the exact
  partial-overlap case the entry predicted) and the file:// store makes fetch node-local.
  Paid lessons: cp -rf (image 0444 collisions, agent-runtime#24), `$SEED/devbox` optional,
  probe-then-mount ≈ credless kubelet pull, and the mirror-full corruption incident
  (10Gi PVC → truncated layer writes; purge + 20Gi). Store artifact 852M zstd + 75M xdg.
- **FU-104** *(archived 2026-07-27, same day as filed)* — **SLO as claim policy + teeth: LIVE
  E2E.** Claim `spec.slo {endpoint, module, availability}` → the Composition renders a blackbox
  Probe (FU-099 exporter) + stack-labeled `EndpointProbeFailing` (responder routing precedence)
  + `stack:error_budget_burnt:bool` recording rule + `ErrorBudgetBurnt` (triage:none — the
  teeth act, triage would restate). Teeth: review-reflex parks a burnt stack's repos (both
  global + per-stack paths; fail-open on a dead Prometheus). First consumer oracle
  (oracle-iac#255): composed + rule evaluating (`oracle: burnt=0` verified). Paid lesson (the
  FU-080 class recurring): every composed KIND needs a crossplane RBAC grant or the whole XR
  fails on Informer sync. Single-endpoint v1; an `slos` array is natural XRD growth when a
  second endpoint claims (specs.oracle stays hand-listed in blackbox.yaml until then).
- **FU-092** *(archived 2026-07-27)* — **Reviewer deterministic-name key, DONE (MP-G02 closed).**
  `reviewer-session.sh` pod name = `reviewer-<project>-<pr>-<headsha8>` (head-sha probe with a
  loud timestamp fallback), atomic `kubectl create` (was `apply` — the silent-adopt
  anti-pattern), terminal same-key reap (the dispatch predicate guarantees no verdict at head),
  live holder refuses exit 3. A new push mints a new name; redelivery collides at the API
  server. FSM: MP-T03 gained the anchored guard, gap register down to G01/G04 (+G05 accepted).
- **FU-101** *(archived 2026-07-27, same day as filed)* — **Review lenses: first two LIVE +
  verified.** `agents/lenses/{k8s-prod,helm}.md` (externally-pinned sources + meta-11 incident
  evidence), selected in-pod by `reviewer-session.sh` — deterministic path+diff predicate,
  raw-fetch from public homelab, advisory contract inside the lens file, loud skip on fetch
  failure. Predicate+fetch verified against fleet#106 (chart PR → [helm k8s-prod], 2 briefs
  attached). ASVS + e-ITS stay DESIGN OPTIONS in roles.md §Lenses, each gated on a concrete
  trigger (ASVS: a code-class predicate + first public-endpoint consumer; e-ITS: seeded by the
  FU-105 IdP research output) — not deferred work. Per-stack advisory→blocking knob: build when
  the first lens earns teeth.
- **FU-103** *(archived 2026-07-27, same day as filed; v2 same day)* — **Responder role LIVE.**
  v1 (issue-per-alert on homelab) was E2E-proven (synthetic → homelab#44 in ~30s) then
  REJECTED by the operator same day: machine-rate issue creation pollutes the tracker, and a
  stack alert belongs on the STACK's -iac, homelab only when the stack needs the platform.
  **v2 (live)**: Alertmanager fan-out (`continue: true`) → `/alert` → `responder` Sensor →
  `respond` WorkflowTemplate — per NEW fingerprint ONE inline sonnet triage session
  (subscription semaphore + FU-088 latch + 12/day cap + 24h fp ledger in the `responder-seen`
  cm, namespaced RBAC), cheapest-sufficient outcome: report-only → GitOps quick fix on -iac
  (revert/pin PR, CI-only lane) → ONE inert issue on the stack's -iac/app repo → homelab only
  for platform ns / needs-platform. Belts: fp-issue search before filing, one-issue-max, no
  kubectl mutations, loop-smell → stop. **Full E2E PASSED 2026-07-27 ~12:32Z** (respond-r8sf4):
  deterministic route computed script-side (oracle-fleet → oracle → oracle-iac), fp belts
  checked, synthetic identified, outcome (a) report-only chosen, zero side effects; the latch
  defer leg + ledger dedup verified on the earlier firing. Machinery + graduation dials:
  roles.md §responder.
- **FU-105** *(archived 2026-07-27, same day as filed)* — **Researcher/planner role: first mode
  BUILT + RUN E2E.** sleep-tracking `.agents/research.yaml` + `goal` label + goal issue #36 →
  `agent-session --harness claude --model opus --recipe .agents/research.yaml` (kata ride,
  server-side WebSearch, no egress change) → spec PR sleep-tracking#38: 9 spec pages, 8 SLP-*
  ID areas, **17 ⚖ ambiguities + 9 suspected bugs** (2 independently code-verified: cfg.tz
  never reaches keying; repo dashboard 6×rawSql/0×queryText), ci green, 806s/109 turns on
  subscription. Dual-model review contract ran: sonnet bot APPROVED + Fable second-pass;
  HUMAN merge = the gate. Machinery lesson paid live: finalize's arm-at-open armed the
  human-gated PR → `--no-arm` (launcher-derived from research* recipes, ADR-094) +
  agent-runtime#23 `AGENT_ARM_PR=0` + C9 skips `research/*` branches. Machinery inventory +
  open dials (FU-090(c) dispatch graduation, spec-branch token narrowing) live in roles.md
  §researcher.
- **FU-015** *(archived 2026-07-27)* — **Custom ARC runner image, DONE + cycle proven E2E.**
  `docker/arc-runner/` (runner+xz/gh/jq+nix+devbox+nixcache substituter, warm store + KEPT eval
  cache) built by `runner-image.yaml`, self-bumping the `arc-runners.yaml` pin. Measured: homelab
  ci 180-210s→38s; fleet ci 610s→127s (ensure 94s→5s eval-cache, publish 87s→31s w/ fleet#131).
  First automated Monday cycle observed 2026-07-27: lock-bump cron drifted 3h19m (GitHub
  scheduler) → HARDENED same day (a91de64): the image rebuilds on `devbox.{json,lock}` landing
  on master — the merge IS the trigger; the Monday cron is a freshness fallback only. Full-chain
  proof: build on a91de64 → self-bump PR homelab#43 (fresh-master-rebased path) → auto-merged.
  Gotcha for the record: fixed-offset cron pairs guarantee NO ordering on GitHub — trigger on
  the upstream artifact landing instead. Residuals live elsewhere: FU-096 (agent-base eval
  cache), fleet#129/#130 legacies already merged.
- **FU-107** *(archived 2026-07-27, same day as filed)* — **Agents docs refactor passes, DONE.**
  (a) dedup: capacity story → ONE home (workflow.md §Capacity gates; merge-path compressed to a
  pointer), review-edge path → roles.md/merge-path-fsm pointers, scout → roles.md pointer;
  (b) resolved by DE-DUPLICATION not generation — fewer copies beats generated copies: the
  hand-drawn PR-lifecycle diagram + workflow.md reconciler list replaced with merge-path-fsm.md
  pointers, README ADR mirror table replaced with a link to docs/adr.md (the updater decision-logic
  flowchart KEPT — it documents one transition's logic, not the FSM, no drift pair); (c)
  superseded tracts deleted with git-history pointers (merge-path §Rollout → 6-line done-summary,
  §Open questions → §Decisions, workflow §MVP + polling-first bullets); (d) §Scaling model moved
  → platform-and-stacks.md §Stack economics; (e) generated-tables leg moved into FU-049 (same
  generation class). Deviation note: (b)'s "generate" intent satisfied by removing the drift
  pairs instead of building generators.
- **FU-100** *(archived 2026-07-27)* — **Per-stack review edge routing, SHIPPED** (the last FU-080
  leg). github-exporter `graduated_loop_ns()` (raw `agents/stacks.json`, 600s TTL, fail-soft to the
  plain POST → global-defer-to-cron) adds `{stack, loop_ns}` to /review POSTs; `review-perstack`
  Sensor dep (`body.loop_ns` `.+` regex) inlines a review Workflow INTO `<loop_ns>` as
  `agentstack-loop` running `reviewer-session.sh --loop-ns`; global trigger pinned
  `conditions: review-dep`. Zero new RBAC (the composed `sensor-submit-coordinate` Role's generic
  workflows-create covers it). Verified 2026-07-27 by synthetic graduated POST: perstack workflow
  ran the full chain in `sleep-agents` (broker token → reviewer pod → doorbell) while the global
  twin deferred; in-pod raw fetch confirmed. `*/15` cron stays as the routing-miss backstop.
- **FU-073** *(archived 2026-07-26)* — **Pull-through OCI registry mirrors, COMPLETE (ADR-091).**
  `registry-cache` ns + registry:3 pair (docker.io+ghcr) on BGP VIPs `.40.20/.21`, longhorn-bulk
  cache PVCs; docker-mode rides use the dind `registry-mirrors` + `REGISTRY_MIRROR_*` contract with
  the docker.io FQDNs dropped from the agentstack egress. All consumers shipped: (a) `machine.registries.mirrors`
  on all 8 nodes (in-place, no reboot); (b) ci-runner `daemon.json`; (c) arc-runners owned dind spec;
  (d) `e2e-kind.sh` per-registry `hosts.toml`; (e) `nixcache` LB VIP `192.168.40.23` (launcher passes
  `NIX_CACHE_URL`). Final validation 2026-07-26: a sleep-tracking#32 KATA ride's `devbox install`
  copied nix paths from `http://192.168.40.23` (LAN-speed substitution, not the ~4-min WAN fallback).
  The eval-cache half (nix evaluation tax, not fetch) is separate = FU-096.
- **FU-089** *(archived 2026-07-26)* — **Fixer-ns App private key = workbench escalation hole, CLOSED.**
  The homelab-agents App PRIVATE KEY used to render into every fixer namespace (so the in-ns
  `agent-git-token` generator could run) — but a workbench SA is namespace-admin there, so it
  could read the key and mint tokens for ALL of the App's repos (cross-stack write). Fix = the
  loop-token pattern for worker tokens: the Composition now renders `agent-git-<repo>-gen` +
  `agent-git-<repo>` ExternalSecret CENTRALLY in `agent-coordinator` (never a fixer ns) + an
  `agentstack-worker` SA per fixer ns (TokenReview identity, no grants); the egress proxy's
  `/git-token` serves the label-checked central secret and TokenReviews the pod SA. E2E-verified
  2026-07-25 (probe: /git-token?ns=oracle-fleet serves; bogus ns 404s; old in-ns ES/generators
  GC'd) and ENFORCED 2026-07-26 (`GIT_TOKEN_REQUIRE_AUTH=1`; anon probe → 403 on the rolled pod).
  Final cleanup 2026-07-26: dead standing-Secret fallback (`GIT_FALLBACK_*` → deleted
  `agent-git-token`) dropped from agent-session.sh + composition header corrected. Lessons: a
  composed resource can't MOVE namespaces (rename its composition-resource-name → create-new +
  GC-old); audit the fallback CONSUMERS not just named readers before deleting a Secret (the
  cred-inject gate was goose/opencode-only, so claude rides had silently leaned on the optional
  fallback — issue-135 r1×2, fixed 6c3fd88); probe the POD not the deploy mid-rollout. Relates
  FU-080, FU-020, ADR-087.
- **FU-084** *(archived 2026-07-26)* — **GitHub API rate-limit metrics, COMPLETE.** Exporter
  `collect_rate_limits` over the exporter PAT + per-installation probe tokens for ALL six
  key-reachable Apps (agents/coordinator — THE 2026-07-17 pool — reviewer, renovate, labels LIVE-verified;
  merge + deploy wired but PENDING one operator command each — their keys were never actually
  pushed to Infisical despite setup.md's claim: run `scripts/github-app-bootstrap.sh
  homelab-merge secrets` + `… homelab-deploy secrets` where the cred dirs live, ESO does the
  rest; rl-tokens.yaml GithubAccessToken pattern, metadata-read probes), dashboard
  panel + `GithubRateLimitLow` symptoms alert; SKU-panel visibility split fixed. DECIDED
  out-of-scope: the arc/runner-registrar pools — their keys are deliberately not in Infisical
  (KeePass/in-cluster only) and their sole consumers are the runner controllers, whose
  exhaustion surfaces directly as registration/scale failures. Cron-relax leg lives in FU-086.
- **FU-098** *(archived 2026-07-26)* — **GitHub App permissions: declared state + drift
  verification, COMPLETE.** `docs/github-apps.yaml` = the single source (per-permission why,
  decided absences, all app_ids filled); ONE creation script (`github-app-bootstrap.sh <slug>`,
  manifest from the yaml, all six secrets/verify flows ported, legacy scripts deleted); the
  ⊆-invariant lint in ci (mint-request ⊆ declaration — the fleet#134 422 class); the exporter
  drift belt + `GithubAppPermissionDrift` alert (change flow: PR the yaml → alert rings →
  operator clicks → clears; proven on the workflows:write grant AND it caught the reviewer's
  forgotten grants same day); the human view SERVED at **apps.teststuff.net** (/apps,
  never committed — CI-auto-commit rejected: GITHUB_TOKEN pushes trigger no workflows).
- **FU-091** — Queue-liveness alert (queued work + idle loop must page). *(archived 2026-07-25)*
  Built the day it was filed (2026-07-21) and never closed: `AgentQueueStalled` (queued>0 ∧ zero
  worker pods ∧ zero open PRs, 2h warning) + the `github_agent_issue_labels` gauge live in the
  github-exporter's prometheusrule.yaml — matches the item's spec near-verbatim.
- **FU-050** — coordinator-reflex CronJob + unsuspend autonomy switch. *(archived 2026-07-25)*
  Superseded by the Argo migration: `coordinator-reflex` is an unsuspended Argo CronWorkflow
  (reflexes-argo.yaml) ticking */10 for weeks; the acceptance round ran clean 2026-07-12 and the
  CronJob + suspend switch it documents no longer exist. Red-beyond-T residue moved to FU-086's
  open list (the exporter's CI metrics carry the out-of-band half).
- **FU-062** — Model routing umbrella (chains + strikes + registry + scout). *(archived 2026-07-25)*
  At its own stated close condition: all four legs live (registry, strikes, proxy injection,
  scout+canary), doctrine home = docs/agents/model-routing.md, and FU-095 carries the next
  routing evolution (task-class chains). Two open umbrellas over one doctrine invite drift.
- **FU-031** — thinkcentre BIOS → disk-first. *(archived 2026-07-25, WON'T DO — operator ruling)*
  Stays PXE-first: the slow-PXE pain was the bad cable (fixed 2026-06-11), not the boot order;
  PXE-first keeps machines wipeable without console access, and on a full-lab restart OPNsense
  (which PXE depends on) is the long pole anyway — the timeout doesn't add wall-clock that matters.
- **FU-028** — Longhorn on the ephemeral laptops → KubeDaemonSetMisScheduled/stale-PDB. *(archived 2026-07-25)*
  Overtaken by ADR-089: wk-metal-01 is the bulk storage tier ON PURPOSE (taintToleration +
  disk-selector fence in longhorn.tf). Live-verified: 0 misscheduled DS pods, no PDB alert
  firing. wk-metal-02's idle Longhorn system pods (~200Mi) accepted as toleration blast radius.
- **FU-029** — Longhorn dashboard "Alerts" panel empty by design. *(archived 2026-07-25)*
  Panel 48 repointed to a Prometheus table over `ALERTS{alertname=~"Longhorn.*"}`
  (tofu/dashboards/longhorn.json).
- **FU-030** — Loki 7-day retention: revisit after usage. *(archived 2026-07-25)*
  Measured: 12MiB used of 10Gi after 26 days (ingest verified queryable via the API).
  Retention raised 168h→720h — volume trivial, history is what incidents need.
- **FU-082** — wk-01 OOMController serial kills (BestEffort estate). *(archived 2026-07-25)*
  All legs done across 07-16/17 (requests+alert+rebalance+cluster-wide sweep — see git);
  final residue verified live 2026-07-25: Home Assistant (512Mi req) and unifi-mongo (256Mi
  req) both Burstable, git matches. PodSigkilled alert remains as the sentinel.
- **FU-085** *(archived 2026-07-17)* — **Coordinator edge-trigger BUILT + E2E-proven same day**
  (design was already in workflow.md §Triggers). `/coordinate` endpoint on the agent-loop
  EventSource + `coordinator` Sensor (rateLimit 2/min, `body.repo` scope with `"all"` fallback)
  + the `coordinate` WorkflowTemplate (scan container extracted; carries the `coordinator-scan`
  mutex — Cron `Forbid` doesn't see Sensor submissions — and the FU-088 semaphore); the
  coordinator-reflex CronWorkflow demoted to a `workflowTemplateRef` backstop. Emitters:
  `agent-session.sh` (tasked worker terminal), `reviewer-session.sh` (every verdict),
  devbox-update + renovate ARC workflows; all fail-open off-cluster; doorbell = scope only, never
  state. E2E: in-cluster POST → Sensor → `coordinate-rkd6l` ran the scan with `repo=oracle-fleet`.
  Residual moved to FU-084 (cron `*/10→*/30` after live proving); per-stack render = FU-080;
  Sensor→item-unit submission = FU-086.
- **FU-087** *(archived 2026-07-17)* — **`Depends-on:` dependency lines + scan enforcement
  (ADR-094) — RESOLVED same-day.** Convention (`Depends-on: [<org>/<repo>]#N[, …]` body lines,
  bare `#N` = same repo, closed = satisfied) enforced in `coordinator-scan.sh`: queued ∧ dep open
  → `⏳ queued-blocked` report (level-triggered, no label to rot); dep closed NOT_PLANNED →
  actionable + `premise may be dead` flag; direct A↔B cycle (same- or cross-repo) → human-first
  report, dep probes fail CONSERVATIVELY (rule #6). All three paths E2E-verified live on a
  synthetic pair (agent-coordinator#6/#7, closed). Real graph encoded: oracle-fleet#45→iac#41,
  #50→#43 (#42/#43 had already closed; #46→"SRV P1" is prose, not an issue — left). Doc:
  coordinator README §State machine (incl. the emitter-side authoring rule). jq gotcha: `^…$`
  multiline needs INLINE `(?m)` — the `scan(re; "m")` flags-arg form silently matches nothing.
- **FU-088** *(archived 2026-07-17)* — **Capacity semaphores in the deterministic layer
  (ADR-094): subscription sessions + OpenRouter credit — RESOLVED 2026-07-17, same-day build
  after the second 429 incident (`review-reflex-1784313000`).** (a) The egress proxy (the choke
  point all subscription traffic rides) latches on `/anthropic` 429s AND defers dispatch at
  ≥80% window utilization (`ANTHROPIC_UTIL_THRESHOLD`), harvested passively from the
  `anthropic-ratelimit-unified-{5h,7d}-*` response headers — the same sanctioned source the CLI
  statusline's `rate_limits` block uses (probed live: 0–1 fractions, per-window resets; account
  overage org-disabled). State on `GET /anthropic-limit` + Prometheus `/metrics`
  (`anthropic_subscription_*`), Grafana `claude-subscription` dashboard, alerts
  `SubscriptionDispatchLimited`/`SubscriptionWeeklyPoolLow`. All four launchers gate via
  `agents/subscription-latch.sh` (fail-open off-cluster), which also enforces the proactive
  concurrency semaphore: defer at ≥`SUBSCRIPTION_MAX_RUNNING` (3) Running pods labelled
  `homelab.teststuff.net/subscription-session=claude`. (b) `agent-session.sh` defers OpenRouter
  dispatch when account credit (probed via the proxy with the pod's opaque ref,
  `/api/v1/credits`) is under `OPENROUTER_MIN_CREDIT` ($0.25). Acceptance: unit+live tests of
  verdicts/metrics; live 19:15Z reflex tick honored the paired `reviewer.enabled` knob; live
  probe seeded 5h=0.24/7d=0.48 through the rolled proxy. Fallback never wired by design: the
  unofficial `oauth/usage` endpoint (claude-code#13585 / ryan-knowone/quota-dashboard).
  Same-day addendum: **Argo-native queueing layer** — `subscription-capacity` ConfigMap semaphore
  (`synchronization.semaphores`) on the review-reflex/coordinator CronWorkflows + the `review`
  WorkflowTemplate; over-cap submissions queue "waiting for lock" instead of deferring (Argo sees
  only Argo-run workflows — the latch stays ground truth; per-stack scoping = FU-080's problem).
- **FU-026** *(archived 2026-07-17)* — **Coordinator graduated off the hand-driven CronJob+bash
  substrate → Argo Workflows + Events (ADR-093, Accepted 2026-07-17; the ADR marks this
  discharged by Phase 1).** Live: all four reflexes are Argo CronWorkflows
  (`agents/coordinator/reflexes-argo.yaml` — the k8s CronJob manifests are deleted, the */15
  review CronWorkflow *is* the rollback backstop), the review edge-trigger Sensor is active
  (exporter POSTs reviewable PRs incl. re-review rounds → `review-argo.yaml`), stacks opt in via
  the AgentStack `argo.enabled` render, and the coordinator reflex was **unsuspended 2026-07-17**
  (meta-7) gated per-stack by the FU-080 `coordinator.enabled` knob. Remainder lives elsewhere:
  per-stack loop move (creds ref-rail + `<stack>-agents` ns CronWorkflows) = **FU-080**; oracle
  ingestion DAGs = ADR-093 Phase 2 (oracle-fleet's ING-RT-STEP-CONTRACTS, unbuilt by design).

- **FU-083** *(archived 2026-07-17)* — **agent-finalize no longer misclassifies raw-command adhoc
  rides as failed.** Adhoc tasks (not `issue-*`/`pr-*`) with `harness_exit==0` now classify as
  clean instead of `failed/no-output` — the adhoc branch sits after every failure signature, so
  fix rides are unaffected; review finding added `ci_passed is not False` to the clean gate.
  Shipped agent-runtime#16 (merged 2026-07-16), deployed via deploy-pin
  `agent-base:2026.7.16-g55879b292003` (homelab#30). Not yet re-validated by a live adhoc ride —
  next `--run`-style verification ride doubles as the check.

- **FU-069** *(archived 2026-07-17)* — **Anomaly protocol propagated to every role.** The
  `agent/error` breaker label + `AGENT_ERROR:` comment convention (live for reviews since
  2026-07-12) now also covers: (a) the coordinator scan (excludes `agent/error`, reports
  human-first); (b) the reviewer — homelab-reviewer App got `issues:write` (JWT-verified), STEP 0
  trips the label itself; (a′) the worker recipes — both `.agents/fix.yaml` emit the breaker on
  self-detected loop anomalies (oracle-fleet#39 + sleep-tracking#21, merged 2026-07-17). (c) was
  obsolete by FU-068 (label claim-owned on migrated repos). Side quest: sleep-tracking#21 surfaced
  a pre-existing date-rot test bug (fixtures with absolute June dates vs a rolling now() window) —
  filed #22, the fixer nailed it in 2 rounds (found the SAME rot in a second file), which
  unblocked #21. ⚠ Self-note: don't drive the review reflex with an external 90s poll loop — that
  IS the runaway-dispatch pattern the breaker guards against; fire once, let the reflex own it.

- **FU-024** *(archived 2026-07-17)* — **`guardrail: only-free` ENFORCED + live-fired.** The egress
  proxy 403s any non-`:free` model on an only-free session BEFORE spend (`_guardrail_reject`,
  openrouter-proxy.py; the operator writes GUARDRAIL into the session Secret). Live-fire
  2026-07-17: only-free key + `deepseek-v4-flash` → 403 `cost_usd:0.0` (proxy log shows both the
  router's `claude-haiku-4.5` probe and the target rejected); same key + `tencent/hy3:free` →
  clean `OK`. Exercised for real by the FU-062 model-scout canary leg (which issues only-free
  keys for :free candidates). No honor system left.

- **FU-018** *(archived 2026-07-17)* — **ADR-087 credential injection: COMPLETE on the
  goose+opencode tier.** Opaque-ref LLM creds + broker git tokens; goose default-on since
  2026-07-10 (acceptance oracle-fleet#7/PR#12); opencode leg validated live 2026-07-16
  (proxy `[injected+cred]` 200, usage read via proxy, cost known — needed `apiKey:
  "{env:OPENROUTER_API_KEY}"` explicit in the session config: options-configured providers skip
  opencode's env auto-detection; and a SESSION-key ref — the proxy refuses standing-key refs by
  design, adhoc rides mint one via `estimate_budget.py --emit-cr`). Finale 2026-07-17: env/mount
  git-token fallbacks DROPPED under injection (agent-session.sh `GIT_FALLBACK_*`); canary pod
  verified holding zero git credentials (env grep 0, only the SA volume) and rode clone → LLM →
  transcripts green. claude harness keeps env/mount (no broker leg yet — its creds are already
  refs, FU-066 d). Provider-injection v1 + cost autopsy: agents/README.md.

- **FU-020** *(archived 2026-07-17)* — **Worker egress deny-all: ENFORCED ON ALL THREE STACKS.**
  oracle since 2026-07-10; sleep-tracking + openrouter-operator flipped 2026-07-17 after clean
  monitor harvests (`hubble observe --follow` during canary rides; every destination allowlisted
  or known-benign) + post-flip canaries green under enforce. Known-benign denied set, verified
  live: **models.dev** (opencode registry fetch, degrades gracefully) + **direct openrouter.ai**
  (exactly what the policy stops; proxied path unaffected) — deliberately NOT allowlisted.
  `AgentWorkerEgressDropped` alert + `drop:destinationContext` metrics live since 2026-07-12.
  Harvest lesson: flows must be captured LIVE (ring buffer rotates in minutes). CNP rendered by
  the AgentStack claim (`egress.enforce` dial); monitor mode = new-stack onboarding default. **Per-stack coordinator context: LIVE since 2026-07-08**
  (`coordinator-session.sh` clones all the stack's repos to `/work/<repo>`, cwd = the stack's
  `mainRepo`; deterministic `coordinator-scan` gate + `--stack/--repos` scoping; ran live on
  sleep-tracking#18 and the oracle stack since). Everything the entry still carried was other
  ids' scope, all now closed: claims + one-global-reflex = FU-048 (done 2026-07-12), the
  scheduled tick = FU-050. Closed at the 2026-07-16 agentic-FU review — nothing left under this
  id.

- **FU-048** *(archived 2026-07-16)* — **AgentStack XRD + Composition: BUILT + ALL THREE stacks
  on claims (2026-07-12).** `argocd/resources/agentstack/` renders per-fixer-repo git-token trio,
  standing OpenRouterKey, worker egress CNP (profile + `enforce` dial), proxy-session RBAC,
  storage quota; `stacks_json()` reads claims (stacks.json = committed mirror/lint universe);
  in-cluster reflex path verified three-stacks-from-claims. Gotchas that stay greppable:
  crossplane's SA needs an aggregated ClusterRole for composed kinds (agentstack/rbac.yaml);
  IssueLabels adoption via `crossplane.io/external-name`. The single listed remainder — a
  test-cluster policy field — died with FU-065 (archived 2026-07-14, superseded): the claim's
  `fixer.docker` IS that field. Closed at the 2026-07-16 agentic-FU review.

- **FU-081** *(archived 2026-07-16)* — **Full kind gate now fits the kata ride: `/var/lib/docker`
  moved from 2Gi tmpfs (charged the dind cgroup → OOM 137 mid-build) to a per-ride 20Gi ephemeral
  BLOCK PVC** on the new `longhorn-scratch` SC (replica=1 on the bulk disks, ADR-089 addendum;
  kata hotplugs it virtio-blk — the one disk shape where overlay2 works in the guest). AgentStack
  quota knob `storage.scratch`. Acceptance ride r4 same day: `devbox run e2e` **E2E GREEN in-pod**
  (277s, transcripts `s3://agent-transcripts/oracle-fleet/adhoc-fu081-scratch-pvc/worker-r4-*`) —
  interim CI-only policy retired; prereqs were oracle-fleet#33 (in-pod kubectl resolves empty
  context-ns to the SA ns) + #35 (FU-073d kind-node mirrors). Fixed en route: longhorn-csi-plugin
  DS lacked the ephemeral-taint toleration (NO kata laptop could attach ANY volume — same bridge
  as engine-image, longhorn.tf comment) and busybox blkid exits 0 on a blank device (mkfs guard
  is now mount-first-else-mkfs). Oracle claim declaring `storage: {scratch: 40Gi}` when quotas
  go live = a line in FU-048's world, not tracked separately.

- **FU-077** *(archived 2026-07-16)* — **kata PodSecurity exemption LIVE.** Talos
  `cluster.apiServer.admissionControl` patch on cp-01 (tofu/talos.tf) exempts
  `runtimeClasses: [kata]`; oracle-fleet ns reverted privileged→baseline
  (argocd/platform/oracle-namespaces.yaml). Acceptance: privileged kata pod ADMITTED +
  privileged runc pod REJECTED in a baseline-enforced test ns. ⚠️ Gotcha that cost a ~12-min
  single-CP apiserver outage: Talos MERGES the admissionControl entry with its built-in
  PodSecurity config by plugin name — restating `namespaces: [kube-system]` concatenates into
  a duplicate and PodSecurity refuses to initialize (apiserver exits; KCM crashloops behind
  it and takes minutes of backoff to recover after the fix). Patch ONLY the new field.

- **FU-063** *(archived 2026-07-16)* — **Exporter `ci_state` on private repos: DONE via
  workflow-run join (path a).** No PAT scope reads private-repo check runs (`checks:read` is
  App-only; the check-runs endpoints are absent from the fine-grained-permissions doc; GitHub
  Actions reports check runs, never commit statuses — two wrong scope theories died here, the
  operator caught both). `ci_state_from_runs()` joins `/actions/runs?head_sha=` conclusions
  under the existing `Actions:read` (`headRefOid` added to the PR query). Verified in
  Prometheus same day: oracle-fleet #13/#30/#33 `success`, #31 `pending`. `Commit statuses:
  read` on the PAT is a no-op and can be dropped at leisure.

- **FU-066** *(archived 2026-07-16)* — **claude-code + Haiku subscription worker tier: LIVE, all
  legs.** (a) `fixer.claudeTier` in the AgentStack XRD → claim-rendered `claude-session` ES
  (ESO *adopted* the imperative secret in place — unlike Crossplane); (b) agent-base ships the
  claude CLI (devbox-pinned) + finalize records `subscription:true` + tokens/turns from the
  session jsonl + uploads it as `claude-sessions/` (agent-runtime#14/#15/#16); (c) the dispatch
  recipe translation codified in the coordinator brief; (d) **ref rail everywhere** — coordinator
  + reviewer swapped to `ANTHROPIC_BASE_URL`+ref, legacy `CLAUDE_CODE_OAUTH_TOKEN` data key
  dropped: NO pod holds the raw ~1y token (acceptance: reviewer approved #14; #15 merged fully
  unattended via the reflex; `COORDINATOR-REF-RAIL-OK` probe); (e) retired — claude rides run on
  agent-base with devbox + kata/dind (validation ride: gate `devbox run ci` PASSED in-pod,
  nix closure from the .40.23 VIP). Boundary finding: the FULL oracle kind gate OOMs the kata
  envelope for EVERY harness → **FU-081** (dind exit 137; interim: full-gate verification rides
  CI). Gotchas: nixpkgs wraps claude as `.claude-wrapped` (watchdog pkill), reviewer tokens must
  be scoped per-repo in reviewer-git.yaml, `agents/coordinator/` is ArgoCD-selfHeal (kubectl
  applies revert). Ledger note: pre-#16 adhoc rides show false `failed/no-output` rows.

- **FU-079** *(archived 2026-07-16)* — **Un-armed open PRs invisible to the merge path — backstop
  shipped.** `coordinator-scan`'s orphan clause generalized from dep-only to ANY un-armed open PR
  with no owning lane (automerge/deps-review/major/awaiting-human/merge-conflict/CHANGES_REQUESTED/
  agent/error all excluded); arm-at-open noted as operator discipline in merge-path.md §Arming is
  the boundary. Born from oracle-fleet#16 (stacked PR born un-armed → stuck at ci "Expected", then
  BEHIND). Report-only by design — the fix is `gh pr merge --auto` or an explicit parking label.

- **FU-057** *(archived 2026-07-16)* — **Retro P2: retro-facts reflex + cross-run dashboards, LIVE.**
  Shipped 2026-07-09/10 (agent-runtime#7 + homelab `fu057-fu061-observability`, merged; polish
  524c331/7224d20): `exit_status`+`error_class` classifier in agent-finalize, pushgateway +
  `agent_run_*` metrics, four dashboards (model-health, running-agents/stall-detector, cost, +
  the agent-issue drill-down), goose sessions.db rendering in the viewer, `agents/ledger.py` +
  `ledger-reflex` CronJob, KEY_HASH end-to-end, NegativeCost/InfraDeathBurst rules. Acceptance
  (verified live 2026-07-16): pushgateway serves `agent_run_cost_usd` for the real oracle-fleet
  runs with exit/error labels; ledger-reflex green on its 30-min cadence ("1 already ledgered");
  all 4 dashboard ConfigMaps synced; #8 ride evidence on the drill-down (c686645). Residue moved
  to FU-058 (`key_hash` activity-API backfill) + FU-063 (stall detector's true CI-green).

- **FU-061** *(archived 2026-07-16)* — **Transcript taxonomy unified — viewer groups by
  issue/project.** Shipped with FU-057: reviewer resolves PR→issue via `closingIssuesReferences`,
  coordinator keys `<mainRepo>/_ticks/`, agent-finalize adds `issue`, and the viewer sync rewrites
  each jsonl `cwd` / goose `working_dir` to `/<project>--issue-<N>` so one issue's
  coordinator+worker+reviewer sessions collapse into one group. Verified on the real issue-1 slice
  (4 goose worker sessions + the reviewer jsonl regroup correctly); viewer deployed and serving.
  Gotcha: cchv labels by cwd *basename* → the leaf is `<project>--issue-<N>` with role-round in the
  filename/session name (a path-shaped `/<project>/issue-<N>/<role>-rN` would scatter).

- **FU-003** *(archived 2026-07-15)* — **HA token regenerated → long-lived.** The dead
  `refresh_token`/`access_token` (401, `invalid_grant`) are gone; `ha-access-token` in the KeePass
  wallet is now a fresh **long-lived** token (~10y, use directly as Bearer — no refresh flow),
  minted via the websocket `auth/long_lived_access_token` cmd, authing with the still-valid
  `ha-prometheus-token` (no password/MFA needed). Verified HTTP 200; wallet round-trips the value.
  Obsolete `ha-refresh-token` entry + its `keepass-init.sh` seed removed; runbook HA §token recipe
  rewritten. Gotcha: websocket handshake needs HTTP/2 disabled on the HAProxy frontend (already is).

- **FU-004** *(archived 2026-07-15)* — **Proxmox token scoped down.** Broad bootstrap
  `root@pam!tofu` replaced by `tofu@pve!provisioner` (`TerraformProv` role, priv list per
  `tofu/README.md`), value swapped in the gitignored `tofu/terraform.tfvars`. `devbox run tf-plan`
  → "No changes" (token authenticates + refreshes all Proxmox VM state), *then* `root@pam!tofu`
  revoked. End state: new token API 200, old 401; `root@pam` keeps only its `matchbox` token
  (separate, untouched). `terraform.tfvars` stays the source tofu reads (per `scripts/tf.sh`); a
  recovery copy of the value is in the wallet as `pve-api-token-tofu`.

- **FU-002** *(archived 2026-07-15)* — **Jail GitHub PAT out of remote URLs → git credential
  helper.** Mono jail: `tools/jail-entrypoint.sh` writes an ephemeral `~/.git-credentials` from
  `GH_TOKEN` + injects `credential.helper store` via `GIT_CONFIG_*` env (`~/.gitconfig` is a busy
  bind-mount → EBUSY); guarded on `GH_TOKEN` so oracle's stack jail is a no-op. All clones scrubbed
  to plain URLs (`new-project.md` Kind 2 fixed); leaked `github_pat_11AALWBOQ0…` rotated 2026-07-15.
  Live-verified after a real jail restart: plain-URL pushes to homelab + claude-jail via the store.
  Gotchas: the parent `/workspace` clone itself was missed by the first scrub; and a push that
  fails 401 (e.g. a leftover stale embedded token) makes git *erase* the matching store entry —
  auth then stays broken until the next jail restart rewrites the file.

- **FU-078** *(archived 2026-07-15)* — **opnsense-acme role signs + polls after create.** The role
  no longer stops at the cert SPEC: it now re-lists certs, signs any spec'd cert with
  `statusCode != "200"` (`POST acmeclient/certificates/sign/<uuid>` — catches fresh creates AND
  prior create-but-never-signed), and polls `certificates/search` (retries 24×5s) until issued,
  so the haproxy play binds a real cert instead of an empty one (the trap that bit forgejo
  2026-06-11 + oracle-specs 2026-07-14). Idempotent — steady-state 200 certs are skipped, no
  re-issue. Signing uses OPNsense's stored CF creds, so token-less cert-adding runs sign too.
  Shipped alongside ADR-092 (its wildcard cert issues through this same path). Jinja filters
  validated against sample data; live-verification rides the ADR-092 rollout (the `*.oracle`
  wildcard is the first cert through the new sign+poll path).

- **FU-008** *(archived 2026-07-14)* — **Forgejo repo/org bootstrap: decided → keep imperative.**
  Forgejo is deliberately *not* in homelab's GitHub IaC — the standing mechanism is `new-project.md`
  Kind 3 (org via API, repo via `tea`, push over SSH with the dedicated `~/.claude/homelab-forgejo/`
  key; this is how `sleep-lab` was made). FU-008's "one-shot token, since deleted" premise is stale:
  the creds are now durable in KeePass — `forgejo-api-token`, `forgejo-rasmus-password`,
  `forgejo-gpg-keyid` (`scripts/keepass-init.sh`) + the `forgejo-keys` SSH/GPG attachments
  (`scripts/wallet-files.sh`). No gitea/forgejo TF provider (would duplicate the recipe + contradict
  the design). Exercised: moved `rasmus/{therapy,car-fleet,presentations}` onto Forgejo this way.

- **FU-042** *(archived 2026-07-14)* — **Deterministic dispatch pre-flight** (af8e2e1, 2026-07-09):
  `agent-session.sh` refuses dispatch on open-linked-PR (unless `--work-branch` resumes that PR's
  own branch), Running-worker ≥ WIP limit, or a <30-min session key. Exercised in anger: the
  refuse path fired live 2026-07-09 (and got the work-branch refinement); the resume path carried
  issue #8 round 2 clean through the 2026-07-12 supervised acceptance round.

- **FU-043** *(archived 2026-07-14)* — **Auto-merge arming decoupled from the dispatcher**: in-pod
  `agent-finalize` arms + posts stats (`armed_by_pod`/`stats_comment_by_pod`), launcher path kept
  as fallback. TICK-LOG: "in-pod bookkeeping perfect 3/3" — armed on every round regardless of
  dispatcher lifetime.

- **FU-064** *(archived 2026-07-14)* — **Freshness-wall fixes**: (a) harness-owned terminal push —
  `agent-finalize` pushes any committed branch at terminal time; fired IN ANGER through the broker
  on oracle-fleet#7 (TICK-LOG). (b) git token as live volume mount — shipped (agent-runtime
  09cd3e0), then superseded by ADR-087 broker tokens default-on. Acceptance rounds ran on
  oracle-fleet#7/#8 (not #1 as originally planned — #1's walls were the evidence, not the venue).

- **FU-065** *(archived 2026-07-14)* — **In-sandbox test clusters: SUPERSEDED by `fixer.docker`**
  (2026-07-14). The item's endgame — "test-cluster tier as a per-stack AgentStack policy field" —
  shipped as the docker knob: kind/k3d inside a kata microVM ride, proven on all 3 laptops
  (docs/spikes/kata-ci-gate.md). The kata runtime made the originally-ruled-out
  kind-in-a-pod path the winner; rung 1 (envtest+chainsaw, unprivileged in-pod) stays available
  repo-side for API-only operators without any platform work; rung 2 (vcluster) dropped.

- **FU-074** *(archived 2026-07-14)* — **k3d/kind-in-kata acceptance: SOLVED, repeatable.**
  Root cause of all post-reinstall hangs: kata guests lack `/dev/kmsg` and kubelet (cadvisor)
  hard-requires it — k3s died *after* its apiserver was up, so k3d saw only a silent log-stream
  timeout (and rolled back the evidence). Fix = `mknod /dev/kmsg c 1 11` in the pod script;
  acceptance manifest (digest-pinned `:5-dind`) then **PASSED ×2 back-to-back**, cluster up in
  21–38s; kind v0.32.0 confirmed working too (Ready in 19s) and fails identically without the
  fix. Full story + kata debugging gotchas (exec-EBUSY, ctl-sidecar pattern, k3d `--no-rollback`,
  kind journal wins for postmortems) in `docs/spikes/kata-ci-gate.md`. Reinstall-mystery re-check
  split out as FU-076.

- **FU-075** *(archived 2026-07-14)* — **WireGuard endpoint freshness: ddclient on OPNsense**
  (chosen over the Telia static-IP fee). New `opnsense-ddclient` role: os-ddclient plugin
  (ensure-installed in the play), native backend, Cloudflare service, `checkip: if`/wan (public
  IP, no external lookup), credential = the SAME zone DNS token ACME holds (no new secret).
  Acceptance: record broken to `192.0.2.1` via CF API -> cache cleared -> ddclient PATCHed it back
  to the WAN IP. **Gotchas:** plugin API namespace is `dyndns`, NOT `ddclient`; plugin installs
  are refused until the base is current ("Installation out of date" -> updated 26.1.8->26.1.11_6,
  no reboot needed despite the status_msg claiming so); ddclient only writes when the WAN IP
  differs from its *cached* `current_ip` -- to force a write, clear `current_ip` via
  `accounts/setItem` then `service/reconfigure` (recipe in runbook).
- **FU-071** *(archived 2026-07-13)* — **All 8 legacy HAProxy VIPs migrated `192.168.2.x` →
  `192.168.3.0/24`** (ADR-088; last octet mirrors the backend `40.x`). Zero client blip via
  temporary dual-binds over the 3600s Unbound-TTL window, then trimmed; stale aliases/overrides
  API-deleted; all 9 services + forgejo SSH verified live on `3.x` only. **Incident during the
  trim:** the `vip_settings/reconfigure` FLUSHED FRR's kernel routes (all `40.x` black-holed
  ~25 min; BGP looked Established throughout) — recovery = real FRR stop/start (`restart` API is
  a no-op); gotcha documented in `group_vars/opnsense.yml` header + runbook.
- **FU-001** *(archived 2026-07-13)* — **Secret consolidation into the platform tiers, complete.**
  `coordinator-claude` → Infisical + ESO (`agents/coordinator/claude-token.yaml`; ns
  agent-coordinator fully GitOps'd). ALL `~/.claude` flat-file secrets → the KeePass wallet
  (`keepass-init.sh`, byte-verified) with `scripts/wallet-files.sh` regenerating file-shaped
  caches (SSH keys/certs/PEMs/p12/esphome `secrets.yaml`); string readers converted
  (`keepass-env.sh` grew `CLOUDFLARE_API_TOKEN`/`ACME_CF_TOKEN`/`TF_VAR_proxmox_api_token`;
  opnsense-playbook/garage-s3/tf/github-tf wallet-first). Acceptance: all three tofu roots plan
  "No changes" on wallet creds; garage + OPNsense verified live. Retired originals parked in
  `~/.claude/.fu001-retired/` — **operator: `rm -rf` after a soak week**. Out of scope: host-side
  `homelab-github-{merge,deploy,renovate}` creds (out-of-jail admin tier, FU-068 doctrine).
- **FU-006** *(archived 2026-07-12)* — Retire the obsolete `SLEEP_FORGEJO_REGISTRY_TOKEN`
  Infisical key (ghcr cutover 2026-06-25). Verified already absent from Infisical (`secrets_v2`
  query via the CNPG pod, 2026-07-12) — had been deleted without closing the item.
- **FU-009** *(archived 2026-07-12)* — `platform` root app cosmetic OutOfSync after the
  `ignoreDifferences` fixes in `tofu/argocd.tf`. Verified Synced/Healthy 2026-07-12.
- **FU-014** *(archived 2026-07-12)* — **Self-hosted Renovate rollout, LIVE end-to-end.**
  `homelab-renovate` App on all 7 agent repos; shared classification in
  `.github/renovate-global.json`; merge-path callers as reusable org workflows. Caller PRs
  agent-runtime#5 + agent-coordinator#4 merged 2026-07-06; scheduled runs green (3×/day); first
  real bumps flowed (sleep-tracking docker digest 2026-07-05 → sleep-iac deploy PR 8 min later;
  devbox-update bumps 2026-07-06). Living doc: `docs/renovate.md`.
- **FU-021** *(archived 2026-07-12)* — goose auth-storm hard-stop. Root cause (goose v1.28.0):
  the agent reply loop retries 401/403 unbounded (812× on a budget-exhausted key). Fix = the
  runtime storm watchdog (agent-runtime#8 → #11) + `GOOSE_MAX_TURNS=200` belt in
  `agent-session.sh`. Acceptance sleep-tracking#20: 200 auth failures in 21s → watchdog kill →
  `error_class=auth-storm` → `AGENT_STRIKE:` comment. Provenance: agent-runtime code comments,
  `docs/agents/model-routing.md`.
- **FU-022** *(archived 2026-07-12)* — Weekly synchronized `devbox update` across all repos
  (toolchain-lock alignment for nix-cache/bake hits; `scripts/devbox-update.sh`). Operator ran it
  2026-07-10 ("messy — not all projects had automerge/ci wired, but all resulting PRs merged");
  residual onboarding polish belongs to FU-052's lint. Majors are human-gated + coordinator-owned
  (proven via helm 3→4, see FU-047).
- **FU-025** *(archived 2026-07-12)* — Three-layer repo topology + automated deploy pipeline
  (app repo → auto-merging bump PR in `sleep-iac` → ArgoCD). Done 2026-07-04. The durable record
  is **ADR-084** + `docs/sleep-iac.md`; follow-on scopes: FU-045 (per-stack coordinator), FU-044
  (post-deploy rollback).
- **FU-035** *(archived 2026-07-12)* — ISC DHCPv4 disabled in the OPNsense UI (the one-time
  click-op for reboot-safety after the dnsmasq migration; no API for it). Operator-confirmed done.
- **FU-037** *(archived 2026-07-12)* — Standing `kubernetes_deployment.ha` tofu plan drift.
  Gone: targeted plan clean ("No changes") 2026-07-12 — the manual live change was reconciled by
  an intervening apply.
- **FU-041** *(archived 2026-07-12)* — Behind-master agent PRs stall silently → the deterministic
  merge-path CI serializer (updater workflow + review reflex + auto-merge; no LLM in the
  mechanics). Proven E2E on sleep-tracking#14, 2026-07-05. The durable record is
  `docs/agents/merge-path.md`.
- **FU-047** *(archived 2026-07-12)* — `major` devbox bumps are coordinator-owned (un-armed →
  outside the review reflex); reviewer runs migration-investigation mode. Proven E2E on
  sleep-tracking#18 (helm 3→4: reviewer pinned the exact fix, worker applied, human merged),
  2026-07-05. Durable record: `docs/agents/merge-path.md` escalation table + coordinator README.
- **FU-060** *(archived 2026-07-12)* — `coordinator-git` token covers all stack repos
  (`agents/coordinator/git-token.yaml`); the remaining check passed (token resolved the oracle
  repos on the next tick, TICK-LOG). Lesson kept in the TICK-LOG: the pod's 403 meant "can't
  verify from here", not "not installed" — check in-repo sources of truth (`docs/github-apps.md`)
  before declaring external blockers.
