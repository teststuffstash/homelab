# oracle-iac — the oracle stack (three-layer topology, sleep-shaped)

_Scaffolded 2026-07-08. The oracle stack reuses the sleep stack's three-layer topology verbatim —
**[`sleep-iac.md`](sleep-iac.md) is the reference design** (ADR-084,
[`patterns/app-owned-resources.md`](patterns/app-owned-resources.md)); this page records only the
oracle-specific deltas and the bring-up order (FU-056). The stack's product/roadmap design doc is
kept out of this repo._

## The layers

| Layer | Repo | Role |
|---|---|---|
| app | `oracle-fleet` (private; public later — FU-055) | code + chart only → ghcr artifacts |
| stack IaC | `oracle-iac` (**private permanently**) | apps/ (app-of-apps, `project: oracle`) + values + pins + infra CRs |
| platform | homelab | `oracle` AppProject + precreated `oracle-fleet` ns (`argocd/platform/oracle-*.yaml`), root `oracle` Application + repo credential (`tofu/argocd.tf`) |

## Deltas vs sleep

- **oracle-iac is private** → ArgoCD reads it via the `repo-oracle-iac-github` repository Secret
  (`tofu/argocd.tf`, same org PAT as `repo-homelab-github`) instead of anonymously. If that PAT is
  fine-grained/repo-scoped, oracle-iac must be added to its repository list.
- **One namespace** (`oracle-fleet`), not two — the fleet monorepo is a single deployable stack
  (gateway + MCP servers); more namespaces would need AppProject + namespaces-file additions.
- **Seeded skeleton**: `apps/` is empty (root app syncs clean with zero resources). The first child
  Application, `values/`, and the deploy-bump pipeline (app-repo `deploy.yaml` + `deploy-pin.sh` +
  the `homelab-deploy` App installed on oracle-iac) are wired when the fleet publishes its first
  chart — copy the sleep shapes (`sleep-iac.md` §"Deploy pipeline"). `oracle-iac`'s ruleset already
  matches sleep-iac (`ci` required, `require_approval = false` — mechanical bumps merge on ci-green).

## Bring-up order (FU-056 — strictly in this order)

1. ✅ (2026-07-08) `devbox run github-tofu apply` **outside the jail** (admin PAT) — created
   `oracle-fleet` + `oracle-iac` on GitHub (+ rulesets + agent labels). Hit the known
   new-private-repo 422 (org disallows private forking → create-time PATCH fails after the repo is
   fully configured, tainting the resource) — untainted; gotcha documented in
   `scripts/new-agent-repo.sh` step 2.
2. Click-only: add both repos to the `homelab-agents`, `homelab-reviewer`, `homelab-merge` App
   installations (`docs/github-setup.md` §click-only).
3. Push the seeded `oracle-iac` content (lives at `/workspace/oracle-iac` in the jail) to
   `teststuffstash/oracle-iac` master.
4. Merge the homelab changes → the `platform` app-of-apps syncs the `oracle` AppProject +
   `oracle-fleet` namespace from `argocd/platform/`.
5. `source scripts/keepass-env.sh` then targeted apply:
   `devbox run -- tofu -chdir=tofu apply -target=kubernetes_secret.argocd_repo_oracle_iac -target=helm_release.argocd_apps`
   → seeds the repo credential + the root `oracle` Application. **Not before step 3** — never point
   a root app at missing content (`sleep-iac.md` §Risks).
6. Verify: `kubectl -n argocd get application oracle` → Synced (zero resources is the expected
   healthy state until `apps/` has children).
