# Follow-ups archive (rolling)

Resolved `FU-NNN` items land here, **trimmed to the grep residue**: what shipped, when, the
acceptance evidence, any gotcha. This is a *rolling* buffer, not a permanent record — an entry
stays while the work is fresh (≈a month) so in-flight sessions can still `git grep` the id, then
gets deleted; after that, `git log -S FU-NNN` is the record. `devbox run follow-ups-lint` treats
ids here as still defined (references elsewhere stay legal while archived) and warns when an
entry is past its freshness window. Deleting an expired entry: scrub any remaining references in
living code/docs first (references in the TICK-LOG / `docs/adr.md` are historical and exempt).

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
