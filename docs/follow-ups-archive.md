# Follow-ups archive (rolling)

Resolved `FU-NNN` items land here, **trimmed to the grep residue**: what shipped, when, the
acceptance evidence, any gotcha. This is a *rolling* buffer, not a permanent record — an entry
stays while the work is fresh (≈a month) so in-flight sessions can still `git grep` the id, then
gets deleted; after that, `git log -S FU-NNN` is the record. `devbox run follow-ups-lint` treats
ids here as still defined (references elsewhere stay legal while archived) and warns when an
entry is past its freshness window. Deleting an expired entry: scrub any remaining references in
living code/docs first (references in the TICK-LOG / `docs/adr.md` are historical and exempt).

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
