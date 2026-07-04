# Follow-ups (the FU tracker)

Running list of loose ends and deferred work — the stuff intentionally not finished yet. Bigger
parked *features* live in `ROADMAP.md` → "Backlog / parked features"; this file is the operational
tracker.

**Conventions (the contract):**

- Every item has a stable id **`FU-NNN`** (3 digits, sequential, **never reused**).
  Next free id: **FU-046**.
- **This file is the only tracker.** Everywhere else — docs, code comments, commit messages —
  reference the id (e.g. `FU-007`), never a free-floating `TODO`. Detailed context may stay near
  the code/doc it concerns; the item here carries the one-liner and links to the detail.
- **Resolving an item:** `git grep FU-NNN`, then delete the item here **and every reference**, in
  the same commit as the fix. `devbox run follow-ups-lint` flags references to ids that no longer
  exist here.
- **Adding an item:** next free id, into the fitting theme section (ids don't encode theme), bump
  the counter above.

_Last updated: 2026-07-02._

## Secrets (the "secret cleanup" track)

- [ ] **FU-001** — Consolidate imperative secrets into the platform (`docs/secrets.md` tiers):
      the `coordinator-claude` Secret (`CLAUDE_CODE_OAUTH_TOKEN`, kubectl-created —
      `agents/coordinator/README.md`) → Infisical/ESO; the `~/.claude/homelab-*` flat-file sprawl
      (opnsense, pve-ssh, matchbox, ha, droplet, cloudflare, aws, forgejo, garage, github-arc)
      → KeePass Tier-0 or Infisical.
- [ ] **FU-002** — The jail GitHub PAT is embedded in the git remote URL (visible in
      `git remote -v`); move it to a git credential helper.
- [ ] **FU-003** — HA `refresh_token` is dead (`invalid_grant`; falling back to `prometheus_llat`).
      Regenerate the refresh/long-lived token (recipe: `docs/runbook.md` → Home Assistant).
- [ ] **FU-004** — Rotate the broad bootstrap `root@pam!tofu` Proxmox token to a scoped `tofu@pve`
      token (`tofu/README.md` has the `pveum` recipe).
- [ ] **FU-005** — Decide whether an Infisical break-glass second admin is worth codifying (one
      super admin today, signups disabled).
- [ ] **FU-006** — Retire the obsolete `SLEEP_FORGEJO_REGISTRY_TOKEN` Infisical key (ghcr cutover
      done 2026-06-25).

## GitOps & platform

- [ ] **FU-007** — **ArgoCD → Forgejo cutover** (offline-resilience goal). Prereq: pull-mirror the
      **homelab** repo itself into Forgejo (the `sleep-lab` org mirrors exist since 2026-06-21).
      Then flip `var.argocd_repo_url` + child-app `repoURL`s and deliver the Forgejo read cred via
      ESO. Procedure: `argocd/README.md` → "Forgejo cutover".
- [ ] **FU-008** — Forgejo orgs/mirrors were created imperatively (one-shot token, since deleted).
      Decide: codify via the Forgejo TF provider vs accept the imperative bootstrap.
- [ ] **FU-009** — Verify the `platform` root app's cosmetic OutOfSync is gone after the
      `ignoreDifferences` fixes in `tofu/argocd.tf`; drop this item if so, tidy if not.
- [ ] **FU-010** — Infisical↔CNPG uses `sslmode=disable` (node-pg rejects CNPG's self-signed
      cert). Fine pod-to-pod; revisit if Cilium transparent encryption lands.
- [ ] **FU-011** — Pin the Crossplane `provider-terraform` package to a digest (currently the
      `:v1.1.1` tag).
- [ ] **FU-012** — Remote/encrypted tofu state backend (every root is local, gitignored state).
- [ ] **FU-013** — Home Assistant `/config` (and other stateful data) backup → Garage S3 with the
      bucket-id in git — the missing "boot-from-git" DR leg (Longhorn replicates in-cluster, it
      doesn't DR). `tofu/homeassistant.tf`.
- [ ] **FU-039** — **Platform self-service via Crossplane** (the "homelab as AWS/Civo" gap): a
      project can already IaC its S3 buckets/keys (ADR-076 Workspaces), OpenRouter keys
      (`OpenRouterKey` CR) and Postgres (CNPG `Cluster` CR) — but **not** its git repos
      (`tofu/github/`, admin PAT outside the jail), HTTPS names (OPNsense ansible), or its own
      ArgoCD AppProject/namespace. Decide per resource: Crossplane provider vs a thin homelab PR
      seam. Prereq for the FU-025 per-stack IaC-repo model.

## CI & dependency automation

- [ ] **FU-014** — **Renovate (auto-update PRs).** **BUILT (2026-07-04), pending operator bootstrap.**
      **Self-hosted** (not the Mend App): a scheduled runner `.github/workflows/renovate.yaml` on the ARC
      tier runs as a dedicated **`homelab-renovate` App** and autodiscovers the repos it's installed on,
      reading each repo's `renovate.json` (sleep-tracking's is trimmed to the live model — python/docker/
      devbox/pre-commit/actions; the stale helm/terraform rules removed). **Hands-off dev-dep bumps** work
      via **reviewer-approves-Renovate**: Renovate labels automerge PRs, `sleep-tracking/.github/workflows/
      renovate-approve.yaml` has the **homelab-reviewer** App post an approving review (a distinct identity
      → *satisfies* required-approval; not a bypass, ADR-084), GitHub merges on CI-green, and the `uv.lock`
      change flows through the automated deploy. Runtime-dep/docker/devbox bumps stay manual review.
      **Operator steps (out-of-jail):** `scripts/github-renovate-app-bootstrap.sh` (create + install on
      sleep-tracking + `secrets`) → `devbox run github-tofu apply` (publishes RENOVATE_APP_* + REVIEWER_APP_*
      secrets) → `gh workflow run renovate.yaml`. Then extend to more repos by installing the App on them.
- [ ] **FU-015** — Custom ARC runner image: bake `xz`/`gh`/devbox + a warm nix store (kills the
      per-job `apt-get` and the ~5 min cold start), and wire the in-cluster nix cache as a
      substituter for runner pods. `docs/ci.md` → "residual costs".
- [ ] **FU-016** — SLSA Phase-1: cosign signing + SBOM + scan on the hosted runners (both tiers).
      Plan: `docs/slsa.md`.
- [ ] **FU-017** — Merge the two runner GitHub Apps (`homelab-arc-…` + `homelab-runner-registrar`)
      — both need only org self-hosted-runners R/W. `docs/github-setup.md` §2.

## Agents

- [ ] **FU-018** — **ADR-081 egress proxy**: inject per-job creds (git/LLM never held in the pod)
      and rewrite the OpenRouter `provider` routing (order / max_price / ignore; prefer *caching*
      providers) — the biggest cost lever. Interim: `opencode.json` `options.provider`. Cost
      autopsy: `agents/README.md` → Operational findings.
- [ ] **FU-019** — Migrate the worker plain `Pod` → agent-sandbox `Sandbox` CR (ADR-078).
      `agents/agent-session.sh`.
- [ ] **FU-020** — Cilium egress lockdown for worker pods (deny-all + allow the proxy and the nix
      cache — without the nix allowance `devbox install` hangs).
- [ ] **FU-021** — goose retry policy: hard-stop on auth/limit errors (it retried a
      budget-exhausted 403 812×).
- [ ] **FU-022** — Pin tool versions in `agent-base` + project `devbox.json` so the baked-toolchain
      cache hits land (`@latest` drifts vs the project lock and re-fetches).
- [ ] **FU-023** — Stats v2: per-request token breakdown via the OpenRouter *activity* API + a
      cross-run Grafana dashboard over the `AGENT_RUN_STATS` Loki lines.
- [ ] **FU-024** — Wire `guardrail: only-free` enforcement in the openrouter-operator (declared,
      not enforced).
- [x] **FU-025 — DONE (2026-07-04, ADR-084)** — **Deploy-versioning + repo-structure rework**: the release→deploy path was
      manual and drifty (`Chart.yaml` vs the `v*` tag vs ArgoCD `targetRevision`). Blocks
      automating coordinator step 7a (`agents/coordinator/README.md`). **Direction (2026-07-02):
      a per-stack `sleep-iac` repo** — the ArgoCD AppProject + app-of-apps for the sleep stack
      (today's homelab `argocd/sleep/` + values + the apps' `infra/` CRs move there) — so app
      repos stay platform-agnostic (standard Helm/Secrets/S3/Postgres, publish image+chart only)
      and a deploy = a version-bump PR in `sleep-iac` with its own CI gates; homelab keeps just
      the platform + a root Application pointing at `sleep-iac`. Homelab-as-a-platform, like
      AWS/Civo. Includes a standalone **Grafana dashboard → GitOps** slice (the Sleep Overview CM
      leaves `tofu/monitoring.tf` for the sleep-tracking ns; datasource/sidecar stay platform-owned)
      and a platform-precreated-namespace `sleep` AppProject. **Full extraction blueprint:
      [`docs/sleep-iac.md`](sleep-iac.md).** **Status (2026-07-04): LIVE** — repo seeded (CI green),
      AppProject + namespaces applied, root app flipped to `sleep-iac//apps` (children Synced/Healthy,
      no prune), `argocd/sleep/` deleted, both app repos' `infra/` emptied, credential dropped, and the
      Grafana dashboard migrated to GitOps. **The deploy path is now fully automated + tested E2E**
      (app-repo `deploy` workflow → auto-merging bump PR in sleep-iac → ArgoCD, near-instant via an
      in-cluster webhook; ADR-084). Coordinator step-7a is a no-op (deploys are hands-off); Renovate
      for our own artifacts was **dropped by decision** (git-sha versions don't order). **Left as a
      done-marked item** (not scrubbed) to keep the `FU-025` provenance in the code/doc comments that
      reference it; the follow-on coordinator-per-stack scope is **FU-045**.
- [ ] **FU-026** — Graduate the coordinator from the hand-driven brief to a durable engine
      (Temporal / Argo Workflows+Events / CRD+controller) — state already lives in labels+CRs, so
      it's a mechanical swap.
- [ ] **FU-027** — One fresh-issue live run to demo the PR stats comment end-to-end (both halves
      are validated separately).
- [ ] **FU-041** — **Agent PRs that fall behind master stall silently**: the ruleset requires an
      up-to-date branch (`strict_required_status_checks_policy`, `tofu/github/repo_rulesets.tf`)
      but nothing updates PR branches (`allow_update_branch=false`), so auto-merge never fires on
      a behind PR. **Deterministic CI serializer — no LLM in the merge path.** Full design (options
      table, diagrams, S/M/L worked examples, platform-scale extrapolation, rollout phases):
      **[`docs/agents/merge-path.md`](agents/merge-path.md)**. Shape: worker arms auto-merge;
      per-repo updater workflow (`adRise/update-pr-branch`, update-before-review) keeps one
      head-of-line PR current; reviewer dispatched only when green+current+unapproved (one review
      per PR); GitHub auto-merge completes. Coordinator stays the issue's owner but as a tool-less
      overseer; the LLM is consulted only at judgment points (conflict, round limit, stale-red).
      Ruled out (details in the doc): GitHub merge queue (Enterprise-Cloud-only on private + split
      process), coordinator-LLM merging, `allonsy-studio/actions-pr-auto-update` (hard-skips bot PRs).
      **BUILT 2026-07-03 (phases 1–3 committed):** updater workflow in both agent repos, review-reflex
      `.sh` + CronJob (`agents/review-reflex.sh`, `agents/coordinator/review-reflex.yaml`), auto-merge
      arming in `agent-session.sh`, `merge-conflict` label in `labels.tf`. **Remaining = operator
      one-time wiring** (all outside the jail unless noted):
      1. Bootstrap the **dedicated `homelab-merge` App** (minimal grant: contents:write + PR/checks/statuses
         read — see docs/github-setup.md §2) — the ONLY blocker for Phase 1:
         `bash scripts/github-merge-app-bootstrap.sh manifest|catch|secrets` (create + install on the agent
         repos + push key to Infisical). Kept separate from homelab-agents so its CI-exposed key stays
         least-privilege (docs/agents/merge-path.md §Updater token).
      2. `devbox run github-tofu apply` (outside jail — the wrapper loads the org admin token + the merge
         id/key, no growing export list) — creates the `MERGE_GH_APP_*` org Actions secrets
         (`actions_secrets.tf`), the `merge-conflict` label (import first if it pre-exists), and, if not
         already applied, `allow_auto_merge=true` on repos.tf. (Set the wrapper's org-admin wallet knobs
         once — `GH_ADMIN_KP_DB`/`GH_ADMIN_KP_KEY`/`GH_ADMIN_KP_ENTRY`, see `scripts/github-tf.sh`.)
      3. `kubectl --kubeconfig tofu/kubeconfig apply -f agents/coordinator/review-reflex.yaml` (Phase 2;
         needs the coordinator bootstrap already done — rbac + coordinator-git + coordinator-claude +
         reviewer-git). Verify: `kubectl -n agent-coordinator create job --from=cronjob/review-reflex reflex-test`.
      4. Optional Phase 4 later (edge-triggers, Renovate levers per FU-014/FU-015) — see the doc's Rollout.
      Then close this item. Phase-3 done also unblocks the stalled live PRs (e.g. sleep-tracking#8 is
      BEHIND+APPROVED+armed today) once the updater's org secrets land.
- [ ] **FU-042** — **Coordinator double-dispatches an already-in-progress issue** (no deterministic
      idempotency). The dispatch guard is soft LLM-judgment in the brief (`agents/coordinator/README.md`
      step 1: "pick one labelled `agent/queued`"), enforced by nothing. Live failure 2026-07-03:
      sleep-tracking#10 was claimed correctly (`agent/queued`→`agent/in-progress`, PR #11 opened), then
      a second coordinator pass ~3h later re-picked the same **`agent/in-progress`** issue, commented a
      fresh "round 1" unaware of #11, and opened a conflicting **PR #12** (both edit
      `tests/integration/fixtures/nights.yaml`). Closed #12, kept #11. The brief *states* the invariant
      "idempotency key `(issue, base-sha, round)` so a re-list never double-spawns" but a stateless LLM
      ignored it. **Fix: make dispatch idempotent deterministically** — refuse to dispatch if the issue
      already has an open linked agent PR **or** carries `agent/in-progress` (a hard pre-flight in
      `agent-session.sh`, or fold dispatch into a reflex like the review path — same philosophy as
      FU-041). Tightening the brief wording alone is insufficient (that's the guard that just failed).
- [ ] **FU-043** — **Auto-merge arming (+ stats comment) is coupled to the dispatcher's lifetime**, so
      an interactively-dispatched PR can be born un-armed and stall silently. `agent-session.sh`'s
      post-run block (arm auto-merge + post the `AGENT_RUN_STATS` PR comment) runs **in the dispatching
      process and blocks until the worker pod finishes (~5 min)**. A **headless** coordinator pass
      (`--run …`) runs it to completion; an **interactive** dispatch that detaches before the worker
      ends skips it entirely. Live proof 2026-07-03: sleep-tracking#11 (dispatched interactively) got
      **no** stats comment and **no** auto-merge (armed by hand at 19:41), while #12 (headless pass) got
      both. Arming is the load-bearing one — an un-armed PR is invisible to the entire merge path
      (updater/reflex/auto-merge) and stalls with no signal. **Fix: make arming independent of the
      dispatcher** — e.g. arm from a reflex/CronJob (arm any open agent PR that isn't armed), or have
      the worker arm its own PR at open (it already has `pull_requests:write`), so it never depends on
      the interactive session surviving. Relates to FU-041 (deterministic merge path) and the
      dispatch-idempotency gap in FU-042.
- [ ] **FU-044** — **LLM oversight of the deploy path: auto-rollback / roll-forward on a broken
      deploy.** The FU-025 deploy pipeline (app-repo build → chart+image at `<calver>-g<sha>` →
      auto-bump PR in `sleep-iac` → ArgoCD sync, see `docs/sleep-iac.md` §Deploy pipeline) merges on
      CI-green but has **no post-deploy health gate** — a chart that renders + passes kubeconform can
      still break at runtime (bad migration, crashlooping CronJob, failing probe). Add a
      coordinator-style overseer that watches the ArgoCD app health after a deploy PR merges and, on
      a broken sync/degraded health: **roll back** (revert the `sleep-iac` bump PR — deterministic,
      no LLM needed for this half) or, better, **roll forward** — dispatch a worker against the app
      repo to fix the breakage. Prereq the operator is doing first: **harden app CI so prod breakages
      are rare** (the roll-back is the safety net, not the primary control). **Direction: do this
      IN-CLUSTER off ArgoCD app-health events, NOT in the GitHub Actions deploy run** — the deploy job
      now ends at "auto-merge armed" (deploy-pin.sh), so post-deploy health/rollback is decoupled from
      CI (e.g. ArgoCD notifications / a small controller watching `Application` health → revert the
      bump PR or dispatch a fixer). Relates to FU-041 (deterministic merge path) and the agent platform
      direction; the ArgoCD-health signal + that in-cluster reactor are the missing pieces.
- [ ] **FU-045** — **Coordinator context is per-STACK, not homelab-only.** `coordinator-session.sh`
      clones just `homelab`, but with the FU-025 three-layer split a stack's deploy truth lives in its
      own `-iac` repo (sleep → `sleep-iac`), so a full "sleep coordinator" context is really
      homelab + sleep-iac + the app repos — and a different stack (`idp`, …) is a different context
      (homelab + its repos). Generalize the single homelab clone into a **per-stack context** (a small
      stack manifest → which repos to clone/observe), and possibly run **one coordinator per stack**
      rather than one homelab-wide. Mostly matters as stacks multiply; today the coordinator doesn't
      need the `-iac` repo in-context because deploys are automatic (it never touches them). Relates to
      FU-026 (durable engine), FU-039 (platform self-service), and the three-layer topology.

## Monitoring & storage

- [ ] **FU-028** — Longhorn schedules manager/engine-image/instance-manager onto the ephemeral
      laptops (compute-only) → `KubeDaemonSetMisScheduled` ×2 + a stale-PDB alert. Scope Longhorn
      off the ephemeral tier (node selector / taint) or silence the two rules.
- [ ] **FU-029** — The Longhorn dashboard "Alerts" panel is empty by design (it's a Grafana
      unified-alerting list; we alert via Prometheus→Alertmanager). Optional: repoint that panel
      to a Prometheus `ALERTS{alertname=~"Longhorn.*"}` query.
- [ ] **FU-030** — Loki 7-day retention: revisit after watching usage
      (`argocd/resources/loki/loki-config.yaml`).

## Hardware & nodes

- [ ] **FU-031** — thinkcentre BIOS → disk-first (it's PXE-first, so every boot pays a PXE timeout;
      disk-first would also make a persistent matchbox flag safe again).
- [ ] **FU-032** — Watch: thinkcentre's one 1Gbps link blip since the cable fix (2026-06-11) and
      wk-metal-02's one unexplained reboot. On recurrence: chase cable/switch-port
      (thinkcentre) resp. battery/power (wk-metal-02, plug `laptop4`).
- [ ] **FU-033** — Before any Talos 1.14 upgrade: apply the `VolumeConfig secure:false` /
      `noexec` patch or `/var` breaks Longhorn v1 (warning in `tofu/longhorn.tf`).
- [ ] **FU-034** — Buy a network Zigbee coordinator (SLZB-06 class) — unblocks local radios
      (ADR-041, Open).

## One-time ops

- [ ] **FU-035** — Click-op: disable ISC DHCPv4 in the OPNsense UI (stopped but still `enable=1`
      in config.xml; no API) for reboot-safety. `docs/runbook.md` → LAN DHCP.
- [ ] **FU-036** — AWS cleanup: delete the orphaned Route53 hosted zone `ZCGRPARGVE3CW` (+ the
      leftover ACM/Sectigo certs its `_*` validation records imply). Needs admin SSO (the jail key
      is read-only). Recipe: `docs/cloudflare.md`. Optionally do it as the first `tofu/aws/` root
      (which would also adopt the audit user, `scripts/aws-bootstrap-audit-user.sh`).
- [ ] **FU-037** — Investigate the standing `kubernetes_deployment.ha` tofu plan drift (a manual
      live change?); reconcile into git or accept it.
- [ ] **FU-038** — Tuya plugs: drop the cloud dependency for local-API polling; then the `/10`
      power correction can go away (`homeassistant/ha-config/packages/power.yaml`).

---

See also `ROADMAP.md` → "Backlog / parked features" (self-hosted SLSA L3 build-out, bare-metal node
suspend/resume, the caching-tier image mirror ADR-070, the edge tier).
