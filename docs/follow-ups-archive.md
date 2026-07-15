# Follow-ups archive (rolling)

Resolved `FU-NNN` items land here, **trimmed to the grep residue**: what shipped, when, the
acceptance evidence, any gotcha. This is a *rolling* buffer, not a permanent record — an entry
stays while the work is fresh (≈a month) so in-flight sessions can still `git grep` the id, then
gets deleted; after that, `git log -S FU-NNN` is the record. `devbox run follow-ups-lint` treats
ids here as still defined (references elsewhere stay legal while archived) and warns when an
entry is past its freshness window. Deleting an expired entry: scrub any remaining references in
living code/docs first (references in the TICK-LOG / `docs/adr.md` are historical and exempt).

- **FU-002** *(archived 2026-07-15)* — **Jail GitHub PAT out of remote URLs → git credential
  helper.** Mono jail: `tools/jail-entrypoint.sh` writes an ephemeral `~/.git-credentials` from
  `GH_TOKEN` + injects `credential.helper store` via `GIT_CONFIG_*` env (`~/.gitconfig` is a busy
  bind-mount → EBUSY); guarded on `GH_TOKEN` so oracle's stack jail is a no-op. All clones scrubbed
  to plain URLs (`new-project.md` Kind 2 fixed); leaked `github_pat_11AALWBOQ0…` rotated 2026-07-15.
  Live-verified after a real jail restart: plain-URL pushes to homelab + claude-jail via the store.
  Gotchas: the parent `/workspace` clone itself was missed by the first scrub; and a push that
  fails 401 (e.g. a leftover stale embedded token) makes git *erase* the matching store entry —
  auth then stays broken until the next jail restart rewrites the file.

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
