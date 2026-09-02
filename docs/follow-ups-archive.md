# Follow-ups archive (rolling)

Resolved `FU-NNN` items land here, **trimmed to the grep residue**: what shipped, when, the
acceptance evidence, any gotcha. This is a *rolling* buffer, not a permanent record — an entry
stays while the work is fresh (≈a month) so in-flight sessions can still `git grep` the id, then
gets deleted; after that, `git log -S FU-NNN` is the record. `devbox run follow-ups-lint` treats
ids here as still defined (references elsewhere stay legal while archived) and warns when an
entry is past its freshness window. Deleting an expired entry (ADR-116, the name-anchor ruling):
scrub only the **TODO-shaped** references (`FU: FU-NNN` gap-register cells, `Tracked by` lines —
the lint reds them as TODO-RETIRED); every other reference is a **provenance name** — a stable
coordinate in a never-reused namespace — and stays untouched, forever.

- **FU-196** *(archived 2026-09-02)* — **ghcr single-point-of-dependence for the oracle corpus:
  RESOLVED by ADR-121.** v0 (mirror creds) 2026-08-30; v1 (first-party push-mode registry on
  Garage, `registry.teststuff.net`) built + cut over in one operator-attended session 2026-09-02
  after the #1282 recurrence: PR#1296+quickfixes, oracle-fleet#352 dual-publish, oracle-iac#490
  pin flip, `REGISTRY_PUSH_TOKEN` via the new secrets-sync single-value row (PR#1298).
  Acceptance evidence: wk-01 pulled the 6.4GB corpus from the LAN registry in 6m31s in
  production; dispatch proof run released BOTH targets digest-verified. Residuals live on:
  FU-203 (retention), #1297 (per-blob detection), ingester-image migration = optional later
  (ADR-121 notes it). Gotcha trail in the ADR + the registry manifest headers (debug-port
  collision, ping-must-challenge, RELATIVEURLS, s3 redirect-disable).
- **FU-052** *(archived 2026-08-30)* — **Onboard the remaining app repos: nothing remains.**
  agent-runtime onboarded 2026-08-07/08 (PR#37 — recipes, tests, CODEOWNERS; the claim's fixer
  flip); snore-recorder 2026-08-02 (FU-051's leg — #15 recipes/CalVer/deploy-pin, sleep-iac#57
  fixer block); agent-coordinator stays CONTEXT-ONLY by the kept 2026-07-16 ruling (tier-3 loop
  machinery, no repo-side lane — recorded in the platform claim). New repos enter via
  `new-stack --from` (FU-070). ROADMAP §Onboard reflects the same state.
- **FU-173** *(archived 2026-08-25)* — **Grafana frser plugin pinned 4.0.6.** PR#935 + the
  same-evening syntax quickfix (8bd4dc67): Grafana's background installer parses `id@version`
  — the docs' legacy `id version` space form SPLIT, installed "4.0.6" as its own pluginId and
  crashlooped the new RS (old pod kept serving; the gotcha is now a ⚠ comment at the pin site).
  Verified end-to-end: 4.0.6 in-pod, app Synced/Healthy, `grafana.teststuff.net/api/health` 200.
  Renovate owns the bump from here.
- **FU-149** *(archived 2026-08-25)* — **Responder daily budget = 12: the soak answered LEAVE IT.**
  The 14d read (daily `max(responder_triage_sessions_today)`): ordinary days 0–6, the cap bound
  only on genuine storm days (08-18 the board-clearing/ARC day = 12, 08-24 the pve/Garage
  incident = 11) — which is what a storm cap is for. `RESPONDER_DAILY_MAX` stays 12; a non-storm
  exhaustion re-opens this as a new datum, not this id.
- **FU-184** — **Garage's metadata auto-snapshot never worked; env rebuilt.** `MDB_CP_COMPACT`
  refuses a page-leaked env by arithmetic (mdb.c "page leak or corrupt DB"), and the 08-24 torn
  write left 4,745,586 pages for ~550k live ones — plus 8 freelist records stranded in the main db,
  which is what broke `garage convert-db` too (it also rejects lmdb→lmdb outright, so the tracker's
  original recipe was wrong twice over). Rebuilt by insertion with
  `scripts/garage-forensics/lmdb-rebuild.py` (PR#911): **18.10 GiB → 1.57 GiB**, 67 trees /
  4,279,175 entries exact, every bucket count unchanged, meta volume 62% → 6%. Container limit
  512Mi → 2Gi — a healthy env makes the copy ~15 s instead of ~11 min and the first fast one
  OOM-killed Garage. **Acceptance PASSED same day**: a snapshot completed (1.68 GB, 67 trees,
  4,280,149 entries, zero junk keys, tracking live), no OOM, `restarts=0`. Mechanism:
  [`garage.md`](garage.md) §Durability. Pre-rebuild copies held in
  `backups/garage-meta-20260825-prerebuild/` — delete after ~2026-09-01. (archived 2026-08-25)
- **FU-179** *(archived 2026-08-23)* — strike policy RULED (operator, G-A child homelab#783):
  `ROUTER_STRIKE_ENFORCE` retired as a blacklist knob — 16-day store read = six strikes, five one
  goose-harness class; enforcement would have changed ~1 decision for cents. Strikes stay
  RECORDED; cooldowns carry the residual class. Code deletion rides the G-A legacy sweep
  (deletion site named in `model-routing.md` §M1a). Re-open = post-flip per-model class the
  cooldowns miss → new design with the provider dimension (the #783 thread's legs; future home =
  the ROADMAP G-E candidate). Fan-out → the free-model evidence lane, same candidate.

- **FU-117** *(archived 2026-08-23)* — context-delivery dedup: COMPLETE via stint S4 #762,
  all three legs same day. The role×context×source map lives at
  `docs/agents/roles.md` §Context delivery. #763: `agents/ground-rules.md` = the ONE universal
  source, launcher-injected with a loud degrade (the `-r && -s` guard + the missing/empty/
  unreadable replay trio). #764: homelab CLAUDE.md is facts-only; seat procedure =
  `agents/jail-seat-card.md`, composed by the mono jail's entrypoint into
  `/workspace/homelab/CLAUDE.local.md` (claude-jail#1 — two recipes; stack jails get a
  `STACK_*`-rendered env card and deliberately NO seat card). #765: meta-state durable
  warnings evicted to runbook/card/owned docs. Residual (NOT tracker-held): the fleet
  CLAUDE.md slim-down, inventoried + tiered on the claude-jail#1 thread, executable on the
  operator's word.
- **FU-163** *(archived 2026-08-23)* — glossary + vocabulary pruning: COMPLETE via stint S4
  #762. The glossary is live (`docs/glossary.md`, ⚓-anchored term list); the researcher
  `goal`→mission rename executed (#766/PR#771 — verified: no machine predicate ever read the
  bare label, the legacy labels were already deleted by the authoritative IssueLabels sync;
  `mission` reserved for FU-090(c) graduation); docs-graph-lint check #3 flipped warn→fail
  with anchors widened on measurement (#767/PR#772 — the shadow loop was a pipe-subshell, the
  flip required restructuring). Residual ambiguous-prose "goal" rewords ride docs-cleanup as
  standing practice, not a tracker item.
- **FU-183** *(archived 2026-08-23)* — GithubActionsMinutesHigh flat threshold → pro-rated
  burn expr: SHIPPED by the cluster loop (homelab#746 → PR#756, stint S7 #741) — fires when
  month-to-date usage exceeds the elapsed quota share with a start-of-month floor; promtool rows
  in loop-health.promtool-test. Residual (silence `5400ed94…` self-expires 2026-09-01; a normal
  month evaluates green post-cutover) is #741's acceptance, not a tracker item.
- **FU-176** *(archived 2026-08-19)* — iac-sentinel zero-PR ticks wiped their own pushgateway
  group (empty body = group REPLACE): fixed in `scripts/iac-sentinel.sh` `push_metrics` — a
  per-tick `iac_sentinel_last_run_timestamp_seconds` heartbeat is always appended, so the body
  is never empty; freshness keys on the heartbeat (iac-lane.md §L0b line), engine rows are
  per-evaluated-PR only; `IacSentinelSilent` (pushgateway prometheusrule, warning +
  platform_machinery) belts >30m of silence; the heartbeat rides the CRON-TICK path only — a
  manual --tree bench run must not reset the alert clock (PR#670 review catch). Verified: local
  zero-PR push probe (body = exactly the heartbeat); post-merge acceptance = the heartbeat
  present and advancing in Prometheus.
- **FU-146** *(archived 2026-08-17)* — per-item dispatch hold: all three PR-side clauses shipped
  2026-08-07 and audited clean; the re-opened issue-side leg (the #153 five-dispatch storm — five
  item sessions in 11 min off a merge-storm doorbell cascade) shipped as PR#480
  (`session_atomic_gate` in coordinator-session.sh: item pods named `coordinator-<repo>-<item>`,
  reap-terminal/refuse-live/exit-3, + the scan's session-belt probe at the FU-146 sites and the
  c4c5 `$sess` exclusion; fixtures session-atomic-gate + session-belt-*). Proof: #153 re-queued
  post-merge, rode once, fix merged as #485. Gotcha: `$fpr_issue` under `set -u` on probe failure
  killed the whole scan in review — init + `${fpr_issue:-}`.
- **FU-166** *(archived 2026-08-12)* — meta-watches event-driven, both legs. (a) BUILT: the
  codeowner park is a first-class exporter series (`github_pull_request_codeowner_park` +
  `_reflex_wait`, predicate incl. green baked in) + `CodeownerParkWaiting` >30m alert +
  needs-meta clause 4 reads Prometheus (gh walk demoted to the unreachable-belt) + the
  agent-running cockpit split with clickable repo#N tables. (b) survey VERDICTS: needs-meta →
  absorbed as meta-events source (--once); goal-thread User comments → src_goalcmt (built at
  FU-166(b) filing); alerts/famine → event sources; throughput + alert-crosscheck → heartbeat
  BACKSTOPS by design; handoff-watch → rollout-only; watch-loop → optional. Polls that remain
  are declared backstops. Same-day belts: SEATPR CI-RED clause + CR verdict-timestamp edges.
- **FU-144** *(archived 2026-08-12)* — doorbell fan-out, ruled option (a) receiver-side and BUILT
  same day (the A2 famine PR): the edge-woken global scan resolves a repo-dumb `{repo}` ring to
  {stack, loop_ns} off `stacks_json()` and re-rings `/coordinate` (`coordinator-scan.sh`
  §doorbell-fanout, `doorbell-fanout` replay family). Emitters stay repo-dumb; the map IS
  `stacks_json()` (claims merged over the mirror — no new file; generating the mirror from
  claims remains FU-049). Loop-break = the re-ring's own `loop_ns` + cron wakes never fan out.
  Mechanism doc: workflow.md §Triggers.
- **FU-140** *(archived 2026-08-12)* — per-loop-ns transcript crash-net (#286/PR#294, goal #278).
  First nightly PROVEN 2026-08-12 04:23Z: all four `transcripts-crashnet` jobs Succeeded;
  platform-agents log: `297 uploaded, 0 already marked, 0 failed` to `s3://agent-transcripts/...`.
- **FU-145** *(archived 2026-08-12)* — `AgentCoordinateScanWedged` re-keyed on the deterministic
  scan phase (#283/PR#300 + KSM/pushgateway halves #347/#370), fixture-pinned; the Forbid-cron
  suppression second symptom is FU-168's design. Doc survives: observability-and-retro.md §Part A″.
- **FU-158** *(archived 2026-08-12)* — promtool rules-lint + 13 behaviour fixtures CI-required
  (#288/PR#310 + the estate sweep #331-#336/#351-#353 eradicated the restart-gap class; drift-pin
  #337, yq recipe #344). The presence-vs-behavior blind spot of the jail lane is closed.
- **FU-160** *(archived 2026-08-12)* — ride/dispatch phase metrics end-to-end (goal #278: #287/
  PR#317 launcher, #319/PR#339 dispatch rows, agent-runtime#66/PR#67 in-pod, #324/PR#373 the
  two-dark-phases fix). Live-verified 2026-08-12: all four launcher phases + clone/devbox/llm-loop/
  finalize + ring-to-scan/scan/coordinator-* families in Prometheus. Doc survives: the
  ride-latency spike (shave candidates stay there).
- **FU-162** *(archived 2026-08-12)* — router draw verb + curated pools shipped (#290: draw_slot,
  pools table + edit-time self-test, research-fanout converted, `research-draw-roster` fixture).
  Acceptance ride = FU-126's run 2 (its ordinary work; a defer there files fresh).
- **FU-165** *(archived 2026-08-12)* — the pilot RAN: goal #278 closed VALIDATED 2026-08-12
  (first validated terminal). Evidence dossier = docs/spikes/goal-lane-v1.1-fu165-pilot.md +
  issue-authoring.md §Goal lane versions; v1.2 design = FU-168 + #295 + §M10; the subscription
  budget blind spot (gap a) is chartered post-FU-131 on #278.
- **FU-133** *(archived 2026-08-11)* — Alert-lane correlation, all legs shipped: resolve/dedup/
  dispatch halves earlier; leg (a) filing-side `group_by: [alertname]` pinned (PR#263 — proved
  already-inherited, pinned against root-route drift); leg (c) queue-time currency gate in
  `sq_decide` (PR#274 — `endsAt>now` resolved-test + `refired` body-staleness, skip≠close,
  fail-closed probe). Both loop-authored, bot-reviewed, fixture-pinned. Mechanism doc survives:
  [`iac-lane.md`](agents/iac-lane.md) §"one root cause, N alert issues". IAC-G10's
  window-ownership rule remains open there (not this id's).
- **FU-159** *(archived 2026-08-11)* — Garage meta on the `std` tier saturates under heavy S3
  GET storms (ert-verify parse, homelab#103 trace). **Migration to `longhorn-fast` REJECTED**
  (operator): the tier is single-node Optane of modest speed whose INTENT is scratch for
  disk-write-heavy pods (CI builds), never load-bearing metadata. Accepted as-is — full parses
  are quarterly/attended, the delta job's rate is far lighter; revisit only if a routine
  workload saturates it.
- **FU-143** *(archived 2026-08-07)* — **A goal's child cannot close itself — SHIPPED and
  soak-PROVEN both paths.** The 7-point contract landed 2026-08-06; the first soak failed on its
  input (a PR that never cited its issue → agent-runtime#32, fixed by #34, carried by
  `agent-base:2026.8.7-gf77880d417da`). Proof: circles#40 closed MACHINE-ONLY
  (`queued → in-progress → review → done → closed`, every transition by `homelab-agents-1234[bot]`)
  and #48 (grandchild) closed via PR#53, re-firing `goal-review` to a "goal met" verdict; #32
  proved the atypical six-round path earlier. **The `12e7fcf` C4/C5 goal-child hold STAYS by
  decision** — with finalize guaranteeing the link, linked children close via C6 and never reach
  it, so its cost is ~zero while it still catches genuine abandonment; the `e704c36` strong-link
  guard stays regardless. Mechanism: [`docs/agents/issue-authoring.md`](agents/issue-authoring.md)
  §A child cannot close itself.

- **FU-111** *(archived 2026-08-07)* — **Native `blockedBy` is the ONLY dependency reader; the
  `Depends-on:` body-line reader is retired.** The soak's bar was met: App-authored native edges
  observed flowing through full lifecycles in real scans (circles #30→#31→#32 closed in dependency
  order, author `app/homelab-agents-1234`). The one open body-line holdout, oracle-fleet#84, was
  migrated to a native edge (blocker #83, closed ⇒ gates nothing) BEFORE the reader was removed —
  fleet-wide grep found no other open body-line dep. Shipped: union jq → native-only + cycle
  detector reads the dep's native `blockedBy` (both executed against real circles/oracle-fleet
  data — the FU-146 verify-by-execution bar); authoring play (coordinator README) now native-only,
  a failed edge-create is retry-once-then-escalate since no body line backs it up.
  **Gotcha kept:** `blockedBy` nodes INCLUDE closed blockers (state field present), so the
  downstream open-state check still decides. Doctrine:
  [`docs/agents/issue-authoring.md`](agents/issue-authoring.md) §Dependencies.

- **FU-038** *(archived 2026-08-07)* — **Tuya plugs → local polling, and the cloud fenced off.**
  Shipped: `tuya_local` 2026.7.2 (pinned, `scripts/ha-tuya-local{,-devices}.sh`) polls all 7 devices
  over the LAN and feeds the `sensor.plug_<box>_*` templates. The `/10` deci-watt correction was
  DELETED, not ported — the device profile applies it (verified 358.0 raw → 35.8). Device material
  (`device_id`+`local_key`+LAN IP+version) is in the wallet as `tuya-local`/devices.json; all 7 are
  DHCP-pinned, which is load-bearing because the four protocol-3.5 plugs never answer UDP discovery.
  Egress fenced by `opnsense/tuya-egress.py` (block `tuya_devices` → NOT `rfc1918`).
  **Acceptance:** Tuya cloud reports 7/7 offline while HA keeps reading all of them locally.
  **Gotchas kept:** pf filters only NEW connections — the rule looked broken for 8 minutes until
  existing cloud states were killed (`diagnostics/firewall/kill_states`); `local_key` ROTATES on
  re-pair, so re-pairing means opening the fence and re-extracting; and a device answers only ONE
  local connection at a time, so a probe can "fail" while HA is happily connected.
  Provenance + limits: [`docs/power-measurements.md`](power-measurements.md).

- **FU-142** *(archived 2026-08-05)* — **homelab had no fixer recipe, so the lane was gated but
  undispatchable.** `.agents/fix.yaml` + `.agents/review.md` shipped (`c5db520`), ADAPTED from the
  sleep-iac donor rather than designed — the same copy-paste that produced oracle-iac's pair. Three
  homelab-specific changes: scope is a PATH tier ceiling over the issue's `Touches:` (argocd/resources
  + docs authorable; argocd/platform, tofu, ansible, opnsense, machines human-merged; agents, scripts,
  policy, .github, tofu/github, tofu/cloudflare refuse-and-report — a worker that can edit the
  launcher/scan/reflex is ungated whatever the ruleset says); there is NO `devbox run ci`, so the
  recipe names the lints per path and requires the PR to say which ran; and the PR must reference the
  issue or the scan re-dispatches (agent-runtime#32). GATE settled: `raw.githubusercontent.com` added
  to the fixer's `extraFQDNs` — kubeconform fetches schemas there, and under `enforce: true` the gate
  would fail on a network drop rather than on the manifest. ⚠ `manifest-lint` SKIPS
  PrometheusRule/Application/AgentStack/CNP (no schema): a diff of those kinds passes a validator that
  checked nothing, which the recipe forces the ride to state. homelab#97 unblocked + queued.

- **FU-138** *(archived 2026-08-05)* — **The OpenRouterKey CR is the guardrail now, not the Secret.**
  The Secret's `GUARDRAIL` is written only when the operator MINTS (create/rotate in
  openrouter-operator's handler), so a guardrail change on an already-minted standing key never
  reached it: enforcement died silently and every claim change needed a hand patch. Fixed by making
  the proxy read the CR that owns the Secret (`_cr_guardrail`, matched on `secretName` or the
  `<project>-openrouter` default) and by rendering `guardrail` ALWAYS in the Composition — `none`
  included, which it previously could not express. Fail direction is deliberate: an unreadable or
  absent CR keeps the Secret's field, so pre-CR keys still enforce and a 403 on the list cannot
  disarm a guardrail. Acceptance on a throwaway key, both directions: Secret `only-free` + CR `none`
  → open; Secret `none` + CR `only-free` → 403 pre-spend. Fallout worth keeping: making guardrails
  real exposed two only-free claims on PAID chains (oracle-fleet, fixed in oracle-iac#271;
  openrouter-operator left alone as a policy call) — `stack-lint` KEY-01/KEY-02 now fail on both
  shapes. Relates FU-024, ADR-085.

- **FU-132** *(archived 2026-08-05)* — **Transcripts PVCs moved to `longhorn-single` (repl=1).**
  homelab#94 was a 2-replica transcripts volume that could not place (one schedulable `std` disk),
  hanging a janitor tick 40 min on the attach; the five live volumes had been hand-patched to
  `numberOfReplicas: 1` but nothing in git asked for it, so every new stack re-armed the wedge.
  `agents/coordinator/transcripts-pvc.yaml` + the Composition template now name `longhorn-single`,
  and all five PVCs were deleted and recreated on it (verified: 5/5 Bound, repl=1, `stack-lint`
  PVC-01 green). Safe because the record is Garage, not the volume — checked rather than assumed:
  all 267 session files across the four loop PVCs were already among the bucket's 908 objects.
  Two gotchas: `storageClassName` is immutable so the class edit alone migrates nothing, and the
  deletes stall on `kubernetes.io/pvc-protection` while TERMINATED pods still reference the PVC
  (a Succeeded `coordinator-janitor-*` held it) — delete those pod objects and it completes.

- **FU-139** *(archived 2026-08-05)* — **VM workers now carry kubelet reservations.** FU-112(b) had
  gated the hardening on `kata`, so cp-01/wk-01/wk-02 ran with Talos defaults until the
  OOMController SIGKILLed Longhorn's instance-manager on wk-02 (2026-08-04 18:34:28) → CSI → iSCSI
  `conn error 1020` → EXT4 errors → a 5-pod SandboxChanged storm. The OOMAction record is the
  evidence and set the numbers: it fired on **PSI** (`memory_full_avg10: 6.04`, ~9.3G of 12G in
  use), not on exhaustion — so a flat `MemAvailable` proves nothing — and it scored the Longhorn
  cgroup highest, the worst victim on a storage VM. Reservations don't tune PSI; they change who
  acts first, and the kubelet evicts an ordinary Burstable pod while Longhorn/Cilium are
  system-node-critical and exempt. 512Mi system + 512Mi kube + a 768Mi hard wall (more kubeReserved
  than the kata math: these VMs host the Longhorn DATA plane, whose per-attach processes arrive in
  chunks). Applied in `tofu/talos.tf`, verified in `configz`; wk-02 allocatable 11.73Gi → 10.39Gi,
  no reboot, nothing evicted. Relates FU-112 (archived), FU-082, ADR-044.

- **FU-128** *(archived 2026-08-05)* — **Dispatcher executing backticks from manifest comments —
  FIXED.** Root cause was not the env card: the pod-manifest heredoc in `agents/agent-session.sh`
  is unquoted (`cat <<EOF`, it must expand `${…}`), so the shell command-substitutes backticks
  **anywhere in its body — including `#` comment lines**. Three comments carried them and produced
  the circles fan-out noise verbatim: `` `timeout` `` → "Try 'timeout --help'", `` `devbox add` ``
  → "Usage: devbox add", `` `placeholder-*` `` → "command not found". Escaped (`` \` ``, the shape
  line ~927 already used) + a maintainer note in the heredoc. Acceptance: isolated probe
  reproduced all three symptoms from comment text alone, and the escaped form passes the comments
  through literally with no execution. Gotcha for the next editor: a `#` comment is **not** inert
  inside an unquoted heredoc, and multi-line substitution output would corrupt the YAML rather
  than just print noise.

- **FU-120** *(archived 2026-08-05)* — **`agent-finalize` PATH loss: belt shipped, root cause
  deliberately unconfirmed.** The launcher pins
  `PATH=/opt/agent/.devbox/nix/profile/default/bin` on the finalize call (2026-07-31), so
  bookkeeping can no longer be lost to this class; the #71-r2 crash itself is unreproducible (the
  crash meant no transcript, and the pod log is gone). No non-finalize symptom of the same
  PATH/mount loss has appeared since. Postmortem — including the WRONG original diagnosis
  ("python lives in the devbox env" — it is baked into agent-base) — survives archival:
  [`docs/incidents/2026-07-29-agent-finalize-bookkeeping.md`](incidents/2026-07-29-agent-finalize-bookkeeping.md).
  Reopen a dig only on a non-finalize symptom.

- **FU-068** *(archived 2026-08-05)* — **homelab's fixer scope DECIDED and LIVE — the gate is
  PATH-based, not repo-based.** Shipped 2026-08-04: repo-root `CODEOWNERS` tiers,
  `require_approval`+`require_code_owner_review` on homelab (ruleset `required-approval` verified
  live), homelab in the platform claim with a real `fixer:` block (guardrail `none`, egress
  enforced, `claudeTier: false` per the FU-134 ruling), `labels.tf` retired via
  `devbox run labels-handoff`, and the CLICK done — both Apps installed, verified 2026-08-05 by
  `agent-git-homelab` + `loop-{git,reviewer-git}-platform` all SecretSynced (an uninstalled App
  422s the generator, so a synced token IS the proof). Ordering gotcha worth keeping:
  `require_approval` is repo-WIDE while code-owner review is path-scoped, and the review reflex
  derives its scan set from the claims — flipping before homelab joined a claim would have stalled
  every armed PR on an approval nothing could give. Residue moved, not dropped: extending the
  IAC-G04 sentinel to homelab (so tier 1 `argocd/resources/**` can go back to unowned) is a
  FU-106 next-action. Tiers + rulings:
  [`docs/agents/iac-lane.md`](agents/iac-lane.md) §The platform lane.

- **FU-136** *(archived 2026-08-04)* — **ArgoCD lever COMPLETE, 4 of 4.** metrics-server,
  kube-prometheus-stack, forgejo and garage all off tofu `helm_release` and into
  `argocd/platform/` — tofu class 4 shrank to cilium/longhorn/argo-cd (≈ADR-005's substrate), so
  ArgoCD OutOfSync is the drift belt for the rest and **alert rules are an ordinary GitOps PR**.
  Acceptance per release: `helm template` + `kubectl diff` empty BEFORE the `state rm`, then
  adoption verified to have recreated nothing (pod ages, PVC ages, one Helm release), then
  `prune: true`. Gotchas worth keeping: ArgoCD adopts because it templates and never installs, so
  Application name MUST equal the release name; `helm list`-style `.items[-1:]` sorts release
  secrets LEXICALLY (v9 > v25) and will diff you against an ancient revision; a chart that emits no
  `metadata.namespace` needs `kubectl diff -n <ns>`; garage carried TWO secrets (`rpcSecret` via
  `random_id`, invisible to a `random_password` grep) and its vendored chart had to move to
  `argocd/charts/garage` first. Detail: [`docs/dependency-upgrades.md`](dependency-upgrades.md)
  §"Executing the lever". Relates FU-097, FU-137.

- **FU-086** *(archived 2026-08-03)* — **Item-scoped dispatch COMPLETE — all four knobs.** Core
  2026-07-17 (units + `--spawn` single-item); (2) cron `*/10→*/30` 2026-08-02; (3) **ADR-097
  footprint dispatch** 2026-08-03 (`Touches:` intersection supersedes lane labels; wipmap→
  `--wip`→`AGENT_WIP_LIMIT`; undeclared=exclusive; PR-cap + REPO_MAX_WIP; `footprint-test` ci
  belt — first run caught the `*` glob-expansion bug); (1) **FU-085 compound** 2026-08-03
  (reviewer verdict carries `unit`, Sensor passes through, scan fast-path re-validates scoped +
  dispatches; "-" = full scan; live-verified chain exit on stale verdict); (4) **janitor tick**
  2026-08-03 (daily report-only `janitor-<stack>` cron → `--janitor` session, 5-sweep brief in
  coordinator README; starvation sweep runs on quiet stacks by design). Residuals live
  elsewhere: reviewer Touches-escape rubric + native-edge soak (FU-111), fast-path whitelist
  growth = only if edge volume demands. Mechanism: ADR-094/ADR-097, workflow.md.
- **FU-108** *(archived 2026-08-03)* — **Exporter queue-liveness private-repo fix DONE**: code
  shipped 2026-08-02 (`agent/*` counts ride the PR GraphQL walk, REST Search dropped); operator
  granted the PAT Issues:read 2026-08-03. Acceptance: walk replayed with the in-cluster token —
  `agentIssues` returns real lists on ALL repos incl. private oracle-fleet/sleep-tracking (was
  FORBIDDEN/NULL); no series emitted only because zero open issues carry `agent/*` labels (loop
  drained — absent ≠ zero, honest). Gotcha: the exporter's per-poll "partial data (6 field
  errors)" log line is the KNOWN FU-063a gap (private-repo `statusCheckRollup`; Actions-fallback
  covers CI state) — not an Issues:read failure.
- **FU-113** *(archived 2026-08-02)* — **Responder outcome markers + self-requeue + incident cap
  BUILT** (all three legs): (a) every non-triaging outcome writes a ledger marker
  (`deferred-`/`cap-`/`none-` values that satisfy neither the triage dedup nor the cap); (b) a
  latch defer exits 1 into an Argo retryStrategy (15m→2h ×6) — the edge is never trusted to
  refire; (c) the daily cap counts INCIDENTS (alertname/namespace), 12/day, not raw fingerprints.
  meta-alert-crosscheck understands markers (DEFERRED-STUCK vs UNTRIAGED). Postmortem:
  docs/incidents/2026-07-27-responder-silent-defer.md.
- **FU-112** *(archived 2026-08-02)* — **Platform-pod OOM posture: residual RESOLVED upstream.**
  Both cascade legs were already fixed (launcher requests=limits; kata-node kubelet reservation);
  the engine-image DaemonSet residual verified live: ALL longhorn-system DS (engine-image,
  csi-plugin, manager) carry `priorityClassName: longhorn-critical` (1e9) via the Longhorn
  `priority-class` setting, `applied:true` — declarative, not drift. Postmortem:
  docs/incidents/2026-07-27-kata-ride-oom-cascade.md.
- **FU-115** *(archived 2026-08-02)* — **Immediate no-op detection on the red merge path BUILT,
  marker-free**: the ci-red clause compares the newest `Agent run stats` comment timestamp vs the
  newest NON-merge commit — stats newer = the round pushed nothing → `agent/arbitrate` NOW (skips
  the remaining RED_ROUNDS_MAX budget). Merge commits excluded (nine-review-loop lesson).
  Synthetic-tested both verdicts. The edge + exhaustion cap shipped 2026-07-28 (MP-T12/T13).
- **FU-124** *(archived 2026-08-02)* — **Armed-BEHIND updater nudge built into the scan**: per
  repo, any armed PR with mergeStateStatus=BEHIND gets a direct `PUT /pulls/N/update-branch`
  (idempotent, self-limiting, FAIL-LOUD on 403 — cron sweeper stays the backstop). The meta-watch
  armed-BEHIND >15min belt clause shipped earlier. Live verification rides the next natural BEHIND
  (worst case = today's status quo). Postmortem: docs/incidents/2026-07-31-last-pr-behind-hang.md.
- **FU-121** *(archived 2026-08-02)* — **c4c5 redispatch vs closing-issue race closed**: the scan
  re-probes the issue's state fresh IMMEDIATELY before spending a session on a c4c5 unit (closed →
  skip, logged; probe-fail → permissive, the session's live-state re-read is the belt). The #71 r9
  spurious round was a list-snapshot predating the close.
- **FU-116** *(archived 2026-08-02)* — **Scan janitor widened to Failed ride pods** (their
  ephemeral docker-lib PVCs leaked — one r1 PVC Bound 18h, the scratch-pool-exhaustion regression).
  Failed gets a 2h grace (hard-died rides may hold the only forensics), Succeeded stays 30min.
  Synthetic-tested all four phase×age cases. The kata/read-only-fs legs were OOM-cascade symptoms
  (root cause = FU-112's incident doc).
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
  global by design. Relates FU-048/FU-050/FU-066, ADR-093/ADR-094.
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
