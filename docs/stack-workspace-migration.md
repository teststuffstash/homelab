# Stack Workspaces → AgentStack `repos[].provision` (ADR-169 migration)

> Decision: [ADR-169](adr.md). The new field and its bounds:
> [patterns/app-owned-resources.md](patterns/app-owned-resources.md#buckets-keys-and-passwords-reposprovision-adr-169).
> This page is the migration of the eleven LIVE stack-authored Workspaces and what stays open until it
> is done. Transient: delete it (keep the ADR) once the last row is migrated and the whitelist is gone.

**The hole, until step 6 lands:** the `oracle`, `sleep` and `circles` AppProjects whitelist the
cluster-scoped `tf.upbound.io/Workspace`, so a merged stack-repo Workspace runs any Terraform in
provider-terraform: its ServiceAccount reads `secrets` cluster-wide, and the default ProviderConfig
carries the Garage admin token, the Infisical writer identity and the Cloudflare proxy. The new field
does not close that by itself; removing the whitelist entry does, and only after every row below has
moved. See also [§What else stays open](#what-else-stays-open) — the whitelist is not the only path.

## Inventory (live, 2026-11-25)

Every Workspace is cluster-scoped, `providerConfigRef: default`, `managementPolicies: ["*"]`, Synced and
Ready. State: Secret `tfstate-<name>-garage` in `crossplane-system` (provider-terraform names the Terraform
workspace after the external-name, which is the object name). Each connection Secret carries a
CONTROLLER ownerReference to its Workspace. Paths are on `master` of the stack repo.

| Workspace | Manifest (ArgoCD app) | Creates | Providers | Writes → read by | deletionPolicy |
|---|---|---|---|---|---|
| `allure-reports-garage` | `oracle-iac//oracle-fleet/infra/allure-workspace.yaml` (`oracle-fleet`) | buckets `allure-reports` 20Gi, `oracle-specs` 5Gi website; keys `allure-reports-{writer,reader}` (rw / ro on both) | garage | Secret `oracle-fleet/allure-reports-s3` → workflow-retention, workflow-edge-contract; GitHub secrets via `scripts/github-secrets-sync.sh` | Delete |
| `ert-snapshots-garage` | `…/infra/garage-workspace.yaml` (`oracle-fleet`) | bucket `ert-snapshots` 120Gi; keys writer rw, reader ro | garage | `oracle-fleet/ert-snapshots-s3` → ert pipeline/delta workflows, sweep, ro job, the ingester app, workbench scripts, github-secrets-sync | Delete |
| `ert-whatif-garage` | `…/infra/whatif-garage-workspace.yaml` (`oracle-fleet`) | buckets `ert-whatif` 4Gi, `ert-whatif-{control,candidate}` 18Gi each; key `ert-whatif-runner` rw on the three + ro on `ert-snapshots` (data lookup) | garage | `oracle-fleet/ert-whatif-s3` → workflow-whatif, workflow-retention | Delete |
| `oracle-feedback-applier-password` | `…/infra/feedback-applier-workspace.yaml` (`oracle-fleet`) | `random_password` (32, keeper gen 1) → Infisical `ORACLE_FEEDBACK_PG_APPLIER_PASSWORD` | random, infisical | no Secret; Infisical → oracle-iac `feedback-applier-externalsecret.yaml` (CNPG managed role + retention node) | Delete |
| `oracle-feedback-ro-password` | `…/infra/feedback-ro-workspace.yaml` (`oracle-fleet`) | `random_password` (32, gen 1) → Infisical `ORACLE_FEEDBACK_PG_RO_PASSWORD` | random, infisical | no Secret; Infisical → oracle-iac `feedback-ro-externalsecret.yaml`, homelab `argocd/resources/postgres/oracle-feedback-ro-externalsecret.yaml` (Grafana datasource) | Delete |
| `circles-auth-secrets` | `circles-iac//circles/auth/auth-secrets-workspace.yaml` (`circles-auth`) | 4 `random_password`: `encryption_key` 48 (prevent_destroy, no keeper), `static_api_key` 48, `oidc_client_secret` 48, `cookie_secret` 32 (gen 1) | random | `circles/circles-auth` → oauth2-proxy, pocket-id, pocket-id-seed, `scripts/passkey-login-link.sh` | Delete |
| `circles-source-garage` | `circles-iac//circles/infra/source-workspace.yaml` (`circles-infra`) | bucket `circles-source` 64Mi; keys writer rw, reader ro | garage | `circles/circles-source-s3` → circles chart values; github-secrets-sync | Delete |
| `circles-specs-garage` | `…/infra/specs-workspace.yaml` (`circles-infra`) | bucket `circles-specs` 1Gi website; keys writer rw, reader ro | garage | `circles/circles-specs-s3` → github-secrets-sync (CI publish) | Delete |
| `sleep-specs-garage` | `sleep-iac//sleep-tracking/specs-workspace.yaml` (`sleep-tracking`) | bucket `sleep-specs` 1Gi website; keys writer rw, reader ro | garage | `sleep-tracking/sleep-specs-garage-conn` (bucket id + writer only) → sleep-iac specs-publish workflow | **Orphan** |
| `sleep-tracking-garage` | `sleep-iac//sleep-tracking/garage-workspace.yaml` (`sleep-tracking`) | buckets `sleep-band` 5Gi, `sleep-db` 2Gi; keys `sleep-band-writer` rw band, `sleep-ingester` ro band, `sleep-ingester-rw` rw db — all IMPORTED, so their secrets were never in state | garage | `sleep-tracking/sleep-tracking-garage-conn` (bucket ids only; no reader found); key secrets live in Infisical from the old tofu | **Orphan** |
| `snore-recorder-garage` | `sleep-iac//snore-recorder/garage-workspace.yaml` (`snore-recorder`) | bucket `sleep-snore` 5Gi; key `sleep-snore-writer` write-only; ro grant to the `sleep-ingester` key (by id) | garage, infisical | `snore-recorder/snore-recorder-garage-conn` (no reader found) + Infisical `SNORE_S3_{ACCESS_KEY_ID,SECRET_KEY}` → the bedside device | Delete |

**If a Workspace object is deleted:** its connection Secret is garbage-collected at once (the
ownerReference), whatever the policy. With `Delete` the provider then runs `terraform destroy`:
generated passwords and their Infisical keys are deleted (the ExternalSecrets behind them go
stale-then-failing), Garage keys and grants are deleted (every consumer's credential dies), and the
bucket delete is refused by Garage while the bucket holds objects (per Garage's admin API; not tried
here), leaving the CR stuck Terminating with the data intact. `circles-auth-secrets` stops at
`encryption_key`'s `prevent_destroy`. With `Orphan` nothing outside the cluster changes.
**If it is replaced** (renamed), the new object starts an EMPTY state: new keys and passwords are
created and the bucket create fails on the taken alias — a rotation surprise plus a broken Workspace.
Hence: adopt the existing state, never recreate.

## The sequence (per Workspace; batch a stack's rows per step)

The adopting entry runs the Composition's Terraform in the legacy state (`crossplane.io/external-name`
= the legacy name) with the legacy Terraform names (`tfName`), so the plan is EMPTY: no move, no
replace. `scripts/fixtures/agentstack-provision/{oracle,circles,sleep}-adopt-xr.yaml` are the eleven
entries, ready to copy; `devbox run -- bash scripts/agentstack-provision-test.sh` proves each one
equivalent to the live module (`expected/`, captured 2026-11-25). A row whose legacy manifest has
changed since must be re-captured and re-checked first.

| # | Step | Who | Verify (read-only) |
|---|---|---|---|
| 0 | This platform PR merges (field + bounds + gate). Nothing renders until a claim uses it. | platform | `kubectl explain agentstacks.spec.repos.provision`; live AgentStacks unchanged (xr-render of the three stack claims is identical) |
| 1 | Add the entry to the stack's AgentStack with `adopt: {workspace: <legacy>, mode: observe}`. Renders `<repo>.<name>` with management policy Observe only and NO connection Secret: it only plans (provider-terraform plans with `-lock=false`, so it never touches the state or the legacy object). | stack PR (`<stack>-iac//<repo>/agent/agentstack.yaml`) | `kubectl get workspace <repo>.<name>` → `READY=True` (= empty plan); `python3 scripts/provision-adopt-check.py --live <legacy> <repo>.<name>` → equivalent; `.status.atProvider.outputs` equal to the legacy's. Not Ready = the fields differ: fix the entry, nothing happened. |
| 2 | Legacy manifest: annotate `crossplane.io/paused: "true"` and set `deletionPolicy: Orphan` (the two sleep rows have Orphan already). Module untouched. | stack PR | legacy `Synced` reason `ReconcilePaused`; `.spec.deletionPolicy` = Orphan |
| 3 | Release the connection Secret: `kubectl -n <ns> patch secret <secret> --type=json -p '[{"op":"remove","path":"/metadata/ownerReferences"}]'` — Crossplane writes only a Secret it controls or nobody does. Skip for the two feedback rows (no Secret). | **operator** (or the stack's jail: namespace admin) | `ownerReferences` empty; key list unchanged |
| 4 | Flip the entry to `mode: manage`: full policies minus Delete, `deletionPolicy: Orphan`, `writeConnectionSecretToRef` = the legacy Secret. The first apply is empty and the Secret is taken over in place — consumers see no gap. | stack PR | `<repo>.<name>` Synced+Ready; Secret's controller = `Workspace/<repo>.<name>`; the `*_access_key_id` values unchanged (compare digests, never print secrets); the next consumer run green (a workflow, the ExternalSecret `SecretSynced`, a pod restart where one reads the Secret at start) |
| 5 | Retire the legacy object: delete its manifest (ArgoCD prunes; the paused CR waits on its finalizer), then remove the finalizer: `kubectl patch workspace.tf.upbound.io <legacy> --type=merge -p '{"metadata":{"finalizers":null}}'`. Paused + Orphan = no destroy runs. **Never unpause a legacy object.** | stack PR, then **operator** (cluster-scoped; no stack identity can) | legacy gone; `tfstate-<legacy>-garage` still present; `<repo>.<name>` Ready; `mc ls` with the reader key shows the data |
| 6 | After the last row: drop the eleven names from `$provisionTenancy.adopt`, remove `tf.upbound.io/Workspace` from `argocd/platform/{oracle,sleep,circles}-project.yaml`, land the [admission guard](#interim-guard-option) in Deny without the frozen-legacy clause. | platform PR | ArgoCD apps of the three stacks Synced; `kubectl get workspaces` shows no stack tracking-id |

Notes per row: `allure-reports` carries a hand-applied Garage lifecycle rule (`runs/`, 30 days) — the
bucket is never recreated, so it survives. `ert-whatif`'s grant on `ert-snapshots` is a data lookup
and migrates in any order. The `sleep-tracking` keys have no secret in state, so that entry writes no
key outputs (`outputs: false`), exactly as today. `snore-recorder`'s ingester grant names the key by id
(`externalGrants`). `random` is not version-pinned in the ProviderConfig (legacy behaviour, unchanged).

## Interim guard (option)

A ValidatingAdmissionPolicy that closes the Workspace path through ArgoCD WITHOUT touching a live
Workspace — the ADR-168 `eso-guard.yaml` shape:

- not judged: requests from `crossplane-system:crossplane` (composed Workspaces: the Composition's
  fixed Terraform), `system:masters` (break-glass), and UPDATEs that leave `spec.forProvider`,
  `providerConfigRef`, `writeConnectionSecretToRef`, `publishConnectionDetailsTo` unchanged (pause,
  deletionPolicy, finalizers, deletes — steps 2 and 5 pass);
- admitted otherwise only from the ArgoCD controller for a Workspace whose tracking-id names a
  platform app (`agent-coordinator`, `argo-artifacts`, `agent-gateway`, `garage-write-probe`,
  `logging`, `opnsense-config-backup`, `tofu-state`);
- so it refuses: any NEW Workspace from a stack app, and any change to what an existing stack
  Workspace runs or where it writes (a stack quota bump waits for its `provision` entry).

Evidence (2026-11-25): `kubectl create --dry-run=server` of the policy + a Deny binding is accepted.
`kyverno apply` against all 24 live Workspaces, evaluated as CREATE (the CLI has no oldObject): the 9
platform ones pass, the 5 composed are not judged, the 11 stack ones are refused — correct for a CREATE.
**Not proven:** that a re-apply of an UNCHANGED stack Workspace is not judged (it rests on the API
server's defaulting making `object.spec` equal `oldObject.spec`). A server-side dry-run cannot show it
without the policy installed, so it is not in the ADR-169 PR. Cheapest proof: land it with
`validationActions: [Warn, Audit]`, read the audit log over a day of syncs, then switch to Deny.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata: {name: workspace-tenancy-guard}
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - {apiGroups: [tf.upbound.io], apiVersions: ["*"], operations: [CREATE, UPDATE], resources: [workspaces]}
  matchConditions:
    - name: not-composed-not-breakglass
      expression: >-
        request.userInfo.username != 'system:serviceaccount:crossplane-system:crossplane' &&
        !('system:masters' in request.userInfo.groups)
    - name: create-or-run-change
      expression: >-
        request.operation == 'CREATE' ||
        object.spec.forProvider != oldObject.spec.forProvider ||
        object.spec.?providerConfigRef != oldObject.spec.?providerConfigRef ||
        object.spec.?writeConnectionSecretToRef != oldObject.spec.?writeConnectionSecretToRef ||
        object.spec.?publishConnectionDetailsTo != oldObject.spec.?publishConnectionDetailsTo
  variables:
    - name: app
      expression: >-
        has(object.metadata.annotations) && 'argocd.argoproj.io/tracking-id' in object.metadata.annotations
        ? object.metadata.annotations['argocd.argoproj.io/tracking-id'].split(':')[0] : ''
    - name: platformApps
      expression: >-
        ['agent-coordinator', 'argo-artifacts', 'agent-gateway', 'garage-write-probe', 'logging',
         'opnsense-config-backup', 'tofu-state']
  validations:
    - expression: >-
        request.userInfo.username == 'system:serviceaccount:argocd:argocd-application-controller' &&
        variables.app in variables.platformApps
      messageExpression: >-
        'workspace-tenancy-guard: Workspace ' + object.metadata.name + ' from ArgoCD app "' + variables.app +
        '" may not be created or change what it runs; a stack asks through AgentStack repos[].provision (ADR-169)'
```

A separate least-privilege ProviderConfig was considered and rejected as the interim: a stack's
module would still run inside the provider pod, whose ServiceAccount reads every Secret, and a module
can name any ProviderConfig.

## What else stays open

Removing the whitelist entry (step 6) closes the stack AppProjects' path only. Two more paths reach the
`default` AppProject (`sourceRepos: *`, destinations `*/*`, `clusterResourceWhitelist: */*`), verified
live 2026-11-25:

- the `agent-fixer` ApplicationSet (`argocd/platform/agent-fixer.yaml`) syncs
  `<stack>-iac//<repo>/agent/` — where each stack's AgentStack and workbench RBAC live — as
  `agent-fixer-<repo>` in project `default`;
- the root `oracle`/`sleep`/`circles` Applications (`tofu/argocd.tf`, project `default`) sync
  `<stack>-iac//apps`, whose child Applications choose their own `spec.project`.

So a stack-repo merge can still apply a Workspace — or any cluster-scoped object — through either. The
guard above keys on the ArgoCD app name, so it covers the first path; the second can name a child
Application after a platform app. Closing both is a separate platform change (a per-stack project for
the claim dirs, and a pinned `spec.project` for the stacks' child Applications).
