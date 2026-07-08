# oracle-iac — the oracle stack (three-layer topology, sleep-shaped)

_Scaffolded 2026-07-08. The oracle stack reuses the sleep stack's three-layer topology verbatim —
**[`sleep-iac.md`](sleep-iac.md) is the reference design** (ADR-084,
[`patterns/app-owned-resources.md`](patterns/app-owned-resources.md)); this page records only the
oracle-specific deltas and the bring-up record. The stack's product/roadmap design doc is kept out
of this repo._

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

## Bring-up record (completed 2026-07-08 — this order is the recipe for the next stack)

1. `devbox run github-tofu apply` **outside the jail** (admin PAT) — created `oracle-fleet` +
   `oracle-iac` on GitHub (+ rulesets + agent labels). Hit the known new-private-repo 422 (org
   disallows private forking → create-time PATCH fails after the repo is fully configured,
   tainting the resource) — untainted; gotcha documented in `scripts/new-agent-repo.sh` step 2.
2. Click-only: both repos added to the `homelab-agents`, `homelab-reviewer`, `homelab-merge` App
   installations, plus `homelab-deploy` on oracle-iac (matrix: `docs/github-apps.md`).
3. Pushed the seeded `oracle-iac` content to master (its `sync.yaml` run went green on the first
   push — the in-cluster ArgoCD-nudge path works).
4. Merged the homelab changes → the `platform` app-of-apps synced the `oracle` AppProject +
   `oracle-fleet` namespace from `argocd/platform/`.
5. Targeted apply (per `.claude/skills/tofu-apply`):
   `devbox run -- tofu -chdir=tofu apply -target=kubernetes_secret.argocd_repo_oracle_iac -target=helm_release.argocd_apps`
   → the repo credential + the root `oracle` Application. **Strictly after step 3** — never point
   a root app at missing content (`sleep-iac.md` §Risks).
6. Verified: root `oracle` app Synced/Healthy at the seed commit, zero resources (the expected
   healthy state until `apps/` has children); credential labelled `secret-type: repository`;
   the org PAT read oracle-iac (pre-flight `git ls-remote` with the KeePass `argocd-github-pat`).
