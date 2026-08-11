# Dependency upgrades — the homelab platform's own path

**This doc owns homelab's own dependency lifecycle**: what a platform dependency bump *should* look
like from proposal through review, test/lint, rollout and monitoring — per dependency class, because
homelab has three different reconciliation regimes and a bump means something different in each.

**Not this doc.** The org-wide **Renovate policy** (threat model, cooldown, the automerge-vs-review
split, the coordinator×Renovate verbs) is [`renovate.md`](renovate.md) — it applies to every repo
the App autodiscovers and is not repeated here. The **app-stack** deploy shapes (app+chart,
operator chart, pod image) are `ROADMAP.md` → *Programs in flight* → "Deploy paths" (FU-051). The
surfaces homelab doesn't reconcile at all are FU-097, same section.

**Tracked by:** **FU-125** (Renovate is silently doing nothing — the §Ground truth finding),
FU-097 (the ruling table this feeds), FU-051 (the app-side sibling), FU-046 (reviewable dep bumps),
**FU-151** (the `automerge` label — §2's mechanical lane — is not set by the `-iac` deploy
producers, so those bumps skip LLM review only by timing), FU-016 (SLSA signing/SBOM). ADR-084
(deploy shape), ADR-093 (Argo as the orchestration engine), ADR-088/089 (the invariants a bump
must not break).

---

## Ground truth first: what Renovate has actually done in homelab

Measured 2026-08-01 from run #115 of `.github/workflows/renovate.yaml` (job logs) and the repo's
PR/branch/issue history. **This section is evidence, not design** — the design below exists because
of it.

**Renovate has never opened a single dependency PR in homelab — and org-wide this is a
REGRESSION, not a never-worked.** FU-014's rollout evidence (archived 2026-07-12; preserved here
because that archive entry expires ~2026-08-16) records real bumps flowing on 2026-07-05/06: a
sleep-tracking docker-digest PR that produced a sleep-iac deploy PR 8 minutes later, plus
devbox-update bumps. sleep-tracking is now one of the four `integration-unauthorized` repos. So
the write path **worked** and then broke somewhere in the 2026-07-06 → 08-01 window — the FU-125
diagnosis should start from *what changed* (App key rotation, permission edit, installation
scope), not from scratch.

| Observation | Evidence |
|---|---|
| Renovate runs every ~6h and has for weeks | 115 workflow runs, **every one `success`** |
| homelab *is* autodiscovered and *is* extracted | run #115: `homelab` first of 10 repos, **97 deps across 36 files** |
| …and then aborts | `result: "repository-changed"` after 43.9s — "Repository has changed during renovation - aborting" |
| **Every other repo aborted too, in the same run** | 6 × `repository-changed`, **4 × `integration-unauthorized`** (sleep-tracking, snore-recorder, oracle-fleet, oracle-iac) |
| Net PRs opened by that run | **zero**, across all ten repos |
| No Dependency Dashboard exists | the global config extends `:dependencyDashboard`; there is no such issue on homelab |
| One orphaned branch | `renovate/pin-dependencies`, pushed **2026-07-27**, SHA-pinning 7 workflow files — **no PR was ever opened for it** |
| The only "renovate" PRs here aren't Renovate's | `runner-image-pin` and `devbox-update` branches — first-party workflows using the App as an author identity |
| Onboarding PR | #2 "Configure Renovate", closed 2026-07-06 — correct, the policy is the global file (`onboarding: false`) |

Two more findings from the same log:

- **Config validation warning, silently tolerated:** `"prPriority" can't be used in
  "vulnerabilityAlerts". Allowed objects: packageRules.` The security fast-track's `prPriority: 10`
  is **dropped**. The rest of the `vulnerabilityAlerts` block is fine.
- **A custom manager resolves nothing:** `Found no results from datasource that look like a version
  (dependency=NixOS/nix)` — the `NIX_VERSION` pin in `docker/arc-runner/Dockerfile` has never been
  updatable (NixOS/nix releases don't match the `github-releases` version shape being asked for).

### Why this matters more than the individual bugs

The workflow is **green**. Nothing anywhere says "Renovate did nothing again." This is the same
failure class as FU-108 (the exporter's Search API silently omitting private repos) and FU-113 (a
deferral that reads as silence): **a probe that reports success while doing nothing is worse than
one that fails**, because it buys false confidence in a supply-chain control that
[`renovate.md`](renovate.md) describes as the first line of defence against a Trivy-style
compromise. The cooldown, the SHA-pinning and the OSV alerts are all real policy — and none of them
have been *applied* to homelab.

**The `integration-unauthorized` half is the regression** — Renovate reads fine, then fails on
write, on repos where writes demonstrably worked on 2026-07-05/06; diff the App's permissions and
installations against that date. **The `repository-changed` half is a race** — Renovate re-checks
the base SHA and aborts if it moved mid-run; six repos hitting it in one pass suggests the ~6h
schedule is colliding with the loop's own push traffic rather than genuine coincidence. Neither is
diagnosed here; both are stated as observed with the evidence attached.

> **Acceptance for "Renovate works in homelab":** a Dependency Dashboard issue exists, and at least
> one `renovate/*` PR has been opened, gated and merged. Until then, treat every claim about
> automated dependency hygiene in this repo as aspirational.

---

## The dependency inventory, and whether a path rule can trigger deployment

homelab has **97 tracked dependencies across 7 managers**. The question "can a path rule trigger
deployment?" has a different answer per class, because homelab runs **three reconciliation regimes**:

- **GitOps (ArgoCD)** — 27 of 34 platform Applications have `syncPolicy.automated`, watching
  `argocd/resources/*`, `argocd/platform/*`, `agents/coordinator`, `agents/fixer/*`. A merge here
  **deploys itself**. A path rule is not just possible, it is already the mechanism.
- **OpenTofu** — plan/apply from the jail is the **deliberate human gate** (FU-097 says keep it). A
  path rule can only *plan and report*; it must never apply.
- **Unreconciled** — ansible (OPNsense, Matchbox), Home Assistant config, the Proxmox host. A merge
  deploys **nothing**. This is the FU-097 gap.

| # | Class | Where pinned | Renovate manager | Path rule → deploy? | What actually happens on merge |
|---|---|---|---|---|---|
| 1 | **Helm charts, GitOps** (crossplane 2.3.2, cnpg 0.28.3, ESO 2.6.0, argo-events 2.4.23, gateway-api CRDs, ARC 0.14.2 ×2) | `argocd/platform/*.yaml` `targetRevision` | `helm-values` (2) + raw YAML | ✅ **yes, already** | ArgoCD auto-syncs. Path rule = the existing Application. ⚠ ARC controller/runners must move **in lockstep** — two files, one version |
| 2 | **In-cluster images** (loki 3.4.2, alloy v1.5.1, otel 0.116.1, pushgateway v1.11.1, blackbox v0.27.0, registry 3.0.0, nginx, python:3.13-slim, docker:29.6.2-dind, aws-cli) | `argocd/resources/*/**.yaml` | `dockerfile`/regex — **mostly unmanaged today** | ✅ **yes** | ArgoCD auto-syncs the manifest. These are the cheapest win: pure GitOps, already path-scoped per resource dir |
| 3 | **First-party images** (agent-base, agent-coordinator, arc-runner) | `agents/images.env`, `argocd/**`, `docker/arc-runner` | n/a — first-party | ✅ **yes, built** | The deploy-pin PR flow (ADR-084). Renovate deliberately never touches our own artifacts (git-sha is unorderable) |
| 4 | **Helm charts, tofu-managed** — now only **cilium, longhorn, argo-cd** (metrics-server, kube-prometheus-stack, forgejo and garage all moved to class 1 on 2026-08-04 — the lever is complete, FU-136 archived) | `tofu/*.tf` | `terraform` (part of the 47) | ⚠ **plan only** | Merge deploys nothing until someone runs `tofu apply` from the jail. A path rule can open a **plan-report** PR comment; applying stays human. What remains is close to ADR-005's substrate — which is the point: "tofu = human-applied" becomes a coherent rule rather than a lump |
| 5 | **Tofu providers** (bpg/proxmox ~0.107, cloudflare ~5.0, github ~6.0, infisical ~0.16) | `tofu/**/versions.tf` | `terraform` | ⚠ **plan only** | Same as 4. Note `~>` ranges mean the *lockfile* is the real pin |
| 6 | **Cluster substrate** (Talos, Kubernetes v1.36.1, Cilium 1.19.1) | `tofu/variables.tf` defaults | `terraform` (weak) | ❌ **no, and must not** | A node-level rollout. ⚠ **Never `talosctl upgrade` a nocloud VM** (ADR-014) — bake the image and recreate. FU-033 gates any 1.14 move |
| 7 | **devbox/nix toolchain** (28 pkgs, all `@latest`) | `devbox.json` / `devbox.lock` | **disabled on purpose** | ❌ n/a | `@latest` is untrackable (it once proposed a 5-year-old gitleaks). Owned by the weekly `devbox-update.yaml` instead — see [`renovate.md`](renovate.md) §Gotchas |
| 8 | **GitHub Actions** (16 deps, 7 files) | `.github/workflows/*` | `github-actions` | ✅ **self-deploying** | The next run uses the merged file. SHA-pinning is the Trivy mitigation — **and it is exactly what's stuck on the orphaned branch** |
| 9 | **Ansible collections/roles** | `ansible/requirements.yml`, `collections/` | `ansible-galaxy` (1) | ❌ **no** | Merge deploys nothing; someone must run `scripts/opnsense-playbook.sh`. The FU-097 gap, sharpest here — this is the router |
| 10 | **arc-runner toolchain ARGs** (DEVBOX_VERSION, NIX_VERSION) | `docker/arc-runner/Dockerfile` | `regex` custom (2) | ✅ yes | `runner-image.yaml` builds and opens the pin PR. ⚠ the NIX_VERSION half resolves nothing (above) |

**The honest summary:** classes 1, 2, 3, 8 and 10 already have a working path→deploy edge. Class 4/5
have a deliberate human gate that should stay but has **no drift detection** between applies. Class
6 is a node rollout that must never be automated. Classes 7 and 9 are outside Renovate entirely, and
**9 is the one that silently does nothing** — a merged OPNsense change sits until a human remembers.

### "Tofu" is not one class — the five roots differ in owner, credential and blast radius

Rows 4–6 above lump five state roots that need different rulings:

| Root | Credential | Ruling |
|---|---|---|
| `tofu/github` | org-admin PAT, **deliberately outside the jail** | **Operator-only.** Nothing automated can even `init` — the "plan-report path rule" is impossible here by standing decision, and should stay so |
| `tofu/cloudflare` | scoped CF token, in jail | Low blast radius (one zone; a bad apply hurts `ha.teststuff.net`, not the updater). Automatable plan, arguably apply |
| `tofu/infisical` | Infisical creds | Slated to leave tofu for ESO/Crossplane — don't invest automation here |
| `tofu/provisioning` | PVE token | PXE content is **inert until the next netboot** — the safest root to automate |
| `tofu/` (main) | PVE token + talosconfig + kubeconfig + KeePass env | **Mixed**: benign helm releases and dashboards next to VM definitions, Talos configs and Cilium — see the ArgoCD lever below |

Two consequences the table above glosses over:

- **Any automated `tofu plan` has a hard prerequisite: FU-012.** Every root's state is local and
  gitignored **in the jail** — no in-cluster or CI process can plan *at all* until state moves to a
  remote backend (or to wherever the automation runs).
- **The main root's lump is reducible: migrate its helm releases to ArgoCD.** Moving
  kube-prometheus-stack, metrics-server, forgejo(+runner) and garage from `helm_release` to
  `argocd/platform/` Applications converts them class 4 → class 1: the path→deploy edge exists
  natively, ArgoCD OutOfSync **is** the drift belt (no plan cron, no FU-012 dependency, no tofu
  creds anywhere), the FU-044 revert extension covers them, and Renovate targets plain YAML
  `targetRevision`s instead of terraform lockfiles. What stays in tofu — Proxmox/Talos/VMs, Cilium
  (day-0 bootstrap, needed before ArgoCD runs), image factory — is then *exactly* the substrate
  that keeps the human gate, which makes "tofu = human-applied" a coherent rule instead of a lump.
  This is a candidate **ruling** for the FU-097 table, and it is *consistent with* ADR-005's
  governing rule ("anything ArgoCD needs in order to run cannot be ArgoCD-managed") — none of the
  four charts above are things ArgoCD needs. Longhorn IS in ADR-005's substrate list, so moving it
  (even as a manual-sync app) would be an ADR-005 addendum, not a quiet migration.

### Executing the lever — the migration order and the one unverified fact

Written 2026-08-04 for a fresh session; the design above is already cleared (ADR-005: none of these
four are things ArgoCD needs in order to run — Longhorn is, which is why it is not on the list).
What remains is mechanical, and dangerous in a specific way: each release is a `tofu state rm` +
an ArgoCD Application that must **adopt** the live Helm release. Get adoption wrong on garage and
you do not get a failed apply, you get an empty bucket.

**The gating fact — SETTLED on metrics-server, 2026-08-04: ArgoCD adopts, and it adopts silently.**
It does not install alongside, because it never installs at all: ArgoCD `helm template`s the chart
and applies the rendered objects, so there is no second Helm release to collide with the first. The
two ownership systems agree *by construction*, not by luck, as long as the **Application name equals
the Helm release name** — the chart renders `app.kubernetes.io/instance: {{ .Release.Name }}`, and
ArgoCD's default `label` tracking wants that same key set to the Application name. Keep those names
equal for every remaining release; that equality is the whole mechanism.

Two consequences worth carrying forward:

- **The live Helm metadata survives and is harmless.** `meta.helm.sh/release-*` annotations and
  `app.kubernetes.io/managed-by: Helm` stay on the objects — ArgoCD's rendered output doesn't
  contain them, so the 3-way merge leaves them alone and they don't show as OutOfSync.
- **The pre-flight is free and it is the real gate.** `helm template <release> <chart> --version
  <same> -n <ns>` piped into `kubectl diff -f -` answers "will adoption change anything?" *before*
  any `state rm`. On metrics-server it came back empty, and the subsequent adoption changed nothing
  (Synced/Healthy, one ReplicaSet, pod start time unmoved). Run it per release; an empty diff is the
  green light, a non-empty one is the whole reason the order is least-valuable-first.

⚠ **Rollback works but does not plan clean** (measured, not assumed). `tofu import` restores
ownership with **0 to destroy** — but the helm provider cannot read `repository` or `values` back
out of a release, so the next plan shows **1 to change, in place**: it re-attaches those two
attributes and recomputes `metadata`. Applying it is a no-op Helm upgrade (revision bump), not a
recreate. Do not read that diff as "the import was wrong" — and do not let step 1's "plan clean
first" rule block a rollback.

**Order, least-valuable first:**

| # | release | why here |
|---|---|---|
| 1 | `metrics-server` | the adoption canary — stateless, instantly rebuildable, nothing depends on its history. **DONE 2026-08-04** (`argocd/platform/metrics-server.yaml`) |
| 2 | `forgejo` (+ runner) | stateful but mirrored from GitHub; recoverable. **DONE 2026-08-04** (`argocd/platform/forgejo.yaml`) — needed TWO conversions (admin + DB) and an ArgoCD OCI repo registration |
| 3 | `kube-prometheus-stack` | losing it blinds every alert built this month, incl. the Longhorn metering. **DONE 2026-08-04** (`argocd/platform/kube-prometheus-stack.yaml` + `values/`) — the release that moves alert rules out of the tofu class |
| 4 | `garage` | LAST, and it needed THREE gates rather than one: a backup (FU-137), *two* secrets behind references (`rpcSecret` comes from `random_id` — invisible to a `random_password` grep), and the vendored chart moved out of `tofu/` to `argocd/charts/garage`. **DONE 2026-08-04** (`argocd/platform/garage.yaml`) |

### The secret-in-values gate — why release 1 was free and 2-4 are not

**Discovered while executing 2026-08-04, and it changes the shape of the remaining work: all three
remaining releases inject a secret into the chart through tofu-rendered Helm values.** The
destination (`argocd/platform/`) is a **public git repo**, so a literal lift-and-shift of the values
block publishes a live credential. metrics-server was the only release with no secret in its values
— which is *also* why it was the free canary, a coincidence worth naming rather than trusting again.

| release | the secret in values | tofu source |
|---|---|---|
| `forgejo` | `gitea.admin.password` **and** `gitea.config.database.PASSWD` | `random_password.forgejo_admin` / `random_password.forgejo_db` |
| `kube-prometheus-stack` | `grafana.adminPassword` | `var.grafana_admin_password` (KeePass wallet via `keepass-env.sh`) |
| `garage` | `GARAGE_ADMIN_TOKEN` as a literal env `value` | `random_password.garage_admin_token` |

So each of 2-4 needs a **preparatory step that release 1 didn't have**: convert the value into a
*reference* to a k8s Secret **while tofu still owns the release**, verify the workload is happy
reading it that way, and only then run the migration sequence. Reference-not-value is the
repo's standing rule for the public repo; this is the same rule arriving at a new surface.

Two consequences:

- **The empty-diff pre-flight is what proves the conversion**, not just the migration. Flipping
  `adminPassword: <literal>` → `admin.existingSecret` re-renders the Deployment (env source
  changes), so that diff will NOT be empty — it is a real, intended change that must go through
  tofu apply first. Only once the release is on the reference does the migration diff go empty
  again. Two separate changes, two separate verifications; collapsing them is how a canary stops
  being a canary.
- **The `random_password` resources outlive the `helm_release`.** They stay in tofu state, feeding
  the k8s Secret the chart now reads — so for forgejo and garage, tofu keeps owning the *secret*
  after it stops owning the *release*. That is fine, and it's the ESO/Infisical migration's
  natural next target (`minimize-tofu` direction), not something the lever has to solve first.

**All three conversions landed 2026-08-04** (FU-136 archived) — the mechanism each chart actually
supported, verified rather than trusted from its docs:

| release | how the secret left the values |
|---|---|
| `forgejo` | `gitea.admin.existingSecret: forgejo-admin-creds` (`-creds` because the CHART owns the name `forgejo-admin`) + `gitea.additionalConfigFromEnvs` carrying `FORGEJO__DATABASE__PASSWD` out of the CNPG `forgejo-pg-app` Secret into init-app-ini |
| `kube-prometheus-stack` | `grafana.admin.existingSecret: grafana-admin` |
| `garage` | the `environment` list took a `valueFrom.secretKeyRef` (`garage-admin-token`) — the mechanism that was least certain, on the one release that is unrecoverable |

The `random_password` resources stayed in tofu state as predicted: tofu still owns the *secrets* for
forgejo and garage after it stopped owning the *releases*.

**Per release, the sequence is the labels-handoff shape** (`scripts/labels-handoff.sh` is the worked
example — dry-run by default, refuses to report success when it cannot see state):

1. `devbox run tf-plan` clean first — never migrate on top of unrelated drift.
2. `tofu state list | grep '^helm_release\.<name>$'` — scoped exactly, never a bare name grep.
2b. The **empty-diff pre-flight** above (`helm template` → `kubectl diff -f -`), while tofu still
   owns the release. Nothing is committed to until it comes back empty.
3. `tofu state rm 'helm_release.<name>'` — tofu FORGETS; Helm and the workload are untouched.
4. Add `argocd/platform/<name>.yaml` pinning the SAME chart version and values, `syncPolicy` with
   `selfHeal` but **`prune: false` on the first sync** — a stray prune is the destructive path.
5. Verify: `kubectl get helmrelease/secret -l owner=helm` still shows ONE release, the workload
   never restarted, and the ArgoCD app reports Synced/Healthy without having recreated anything.
6. Only then flip `prune: true`, and only then start the next release.
7. Remove the `helm_release` block from `tofu/*.tf` in the same commit as step 4, so git never
   claims two owners for one release.

**Rollback at any step:** `tofu import 'helm_release.<name>' <ns>/<name>` puts it back under tofu.
Establish that this works on metrics-server too, before it is needed under pressure.

---

## What a full platform dependency upgrade should look like

Five stages. The point of writing them out is that **today only stages 1–3 exist, and only for some
classes** — stages 4 and 5 are where the gaps are.

### 1. Propose

- **Renovate opens the PR** against the global policy in
  [`renovate-global.json`](../.github/renovate-global.json): 7-day cooldown (security bypasses it),
  Actions SHA-pinned, OSV alerts on, majors always human-gated.
- **The classification decides the lane, not the reviewer's mood:** digest/pin → `automerge`;
  runtime version bumps and base-image minors → `deps-review`; **every** major → `major`, un-armed.
- **First-party artifacts never ride Renovate** — a `2026.<m>.<d>-g<sha>` version doesn't order, so
  the deploy-pin PR opens them (ADR-084).
- *Gap:* none of this currently fires in homelab (see Ground truth).

### 2. Review

- **`automerge` lane** — no human, no LLM. The gate *is* cooldown + CI + the `renovate-approve`
  reflex. A human diffing two SHA-256s is theatre.
- **`deps-review` lane** — the **LLM reviewer** via the merge-path review reflex, not a human
  (FU-046). Harmless → approve → auto-merge. Needs adaptation → `CHANGES_REQUESTED` → a worker
  adapts the code **on the `renovate/*` branch**. Never close the PR: closing is not a terminal
  action — [`renovate.md`](renovate.md) §Coordinator × Renovate explains why (churn, and
  vulnerability PRs are recreated regardless). To abandon an upgrade durably, change the **config**.
- **`major` lane** — un-armed, coordinator-owned, human merges.
- **Platform-specific review question the app lanes don't ask:** *does this bump violate a platform
  invariant?* The ip-plan ranges (ADR-088), storage caps (ADR-089,
  [`storage-ledger.md`](storage-ledger.md)), the `bgp=advertise` label contract, secret
  references-never-values. That's a **policy-as-code** job, not a reading job — the same L0 lane
  `iac-lane.md` §Assurance layers builds for `-iac`.

### 3. Test / lint

What `devbox run ci` gates on a homelab PR today:

| Check | Catches |
|---|---|
| `argocd-validate-pins` | a pinned OCI chart that doesn't render with this repo's values — the class-1 gate |
| `agents-registration-lint` | stacks.json ⊆ coordinator/reviewer token lists |
| `merge-path-lint` | the FSM model drifting from the code |
| `github-apps-lint` | mint sites ⊆ declared App permissions (FU-098) |
| `router-self-test` | the ADR-096 router store |

**What is missing for a dependency bump specifically:**

- **No `tofu validate` / `tofu plan` in CI** for classes 4–6. A provider bump can merge with nobody
  having rendered it. A read-only plan against a **non-live** backend, or at minimum
  `tofu validate` + `fmt -check`, is the cheap version.
- **No `helm template | kubeconform`** for class 2 (raw manifests in `argocd/resources/*`);
  `argocd-validate-pins` covers OCI charts, not the hand-written YAML next to them.
- **No policy-as-code** for the platform invariants above.

### 4. Rollout

This is where the three regimes diverge and where the design work is:

- **GitOps classes (1, 2, 3)** — ArgoCD syncs on merge. The missing piece is **not** the trigger, it
  is the **post-deploy verdict**: ArgoCD health is a *shallow* gate (the meta-11 schema-skew outage
  stayed green on a `tcpSocket` probe). The deterministic revert exists —
  Degraded ≤120m after a `deploy/*` bump → auto-revert PR
  ([`agents/iac-lane.md`](agents/iac-lane.md) §"ArgoCD health is NOT the post-deploy gate", FU-044)
  — but it is scoped to `-iac` deploy bumps, **not to a platform chart bump merged into homelab**.
  **⚖ Extending it wholesale is REJECTED (operator, 2026-08-04).** The platform barely has the
  trigger — only first-party image pins move as `deploy/*` (class 3), while classes 1/2/4 move by
  chart-version bumps and hand edits — and revert is not free for the stateful ones (garage, CNPG:
  CRD/schema downgrade, PVC expectations, data-layer skew), with no second net if the revert also
  fails. The extension is scoped to the **reversible class**: a first-party image pin, no
  CRD/schema migration, no data-layer coupling. Everything else Degraded goes to the responder as
  an alert + report-only issue. Ruling + precondition:
  [`agents/iac-lane.md`](agents/iac-lane.md) §"Auto-revert does NOT generalize to the platform"
  (IAC-G09).
- **Tofu classes (4, 5)** — keep the human gate. Add the belt FU-097 asks for: a **`tofu plan` cron
  → alert on non-empty diff**, so "merged but not applied" and "live drifted from state" both become
  visible instead of silent. **Prerequisite: FU-012** — state is local + gitignored in the jail, so
  today there is nowhere else that cron *can* run. (Or shrink the class instead: the ArgoCD lever
  above removes the need for the belt on everything it migrates.)
- **Substrate (6)** — a deliberate, staged node rollout: one metal node first, `talosctl health`,
  Longhorn rebuild-complete, then the rest. Never a nocloud VM in place (ADR-014).
- **Unreconciled (9)** — the FU-097 first deliverable. The candidate shape is already precedented:
  an **in-cluster ansible Job** (ArgoCD PostSync or CronWorkflow, creds via ESO), with a nightly
  `--check` diff → alert as the minimum belt even if apply stays manual. ⚠ For **OPNsense**
  specifically the in-cluster Job sits *inside its own blast radius* — see the cone rule below.

**Where the runner sits — the dependency-cone rule.** Belts are read-only (`--check`, `plan`,
drift alerts) and safe to automate anywhere, including in-cluster. **Applies are only safe to
automate from a runner outside the change's dependency cone, or with an out-of-band deadman.**
Concretely: an in-cluster `tofu apply` touching Cilium, ArgoCD, Longhorn or the VM definitions can
sever its own pod's network/storage/node mid-apply — with local state that also means a locked or
half-written state file. An in-cluster ansible Job pushing OPNsense config changes the router that
carries the Job's own network path: a bad apply cuts both the connection *and* every rollback path,
and ArgoCD can't even report the failure anywhere reachable. The commit-confirm shape fixes the
latter: schedule a config restore on the target *before* applying, cancel it only when the
post-apply health probe passes. Matchbox, in the same ansible class, has a near-zero cone (nothing
depends on it until the next PXE boot) — another reason class 9 is not one class. The full
no-human end-state analysis (HA router pair, management network, out-of-band coordinator, what
remains genuinely human): [`spikes/no-human-in-the-loop.md`](spikes/no-human-in-the-loop.md).

### 5. Monitoring

A bump is not done when it merges; it is done when nothing broke. What exists and what doesn't:

| Signal | Exists? | Notes |
|---|---|---|
| ArgoCD app health / sync status | ✅ | shallow — see above |
| Prometheus + Alertmanager → responder triage | ✅ | one bounded LLM session per new fingerprint (FU-103) |
| Blackbox probes on service endpoints | ✅ | FU-099 — seconds-grade, dumb |
| Deep [contract probe](glossary.md) post-deploy | ❌ | the **prober** role ([`agents/roles.md`](agents/roles.md) §prober, FU-102) — the real acceptance signal |
| Storage-cap breach visibility | ❌ | Garage exports **no** metrics at all; Longhorn per-disk unwatched ([`storage-ledger.md`](storage-ledger.md), FU-093) |
| **Renovate liveness** | ❌ | **nothing watches whether Renovate did anything** — the finding at the top of this doc |
| Drift between tofu applies | ❌ | FU-097 |

**The observation window** (`iac-lane.md` §Progressive delivery) is the frame to reuse: sync → health
→ *window* → promote or revert. Today a homelab platform bump has a sync and a shallow health check,
and then nothing is watching.

---

## Next steps, in dependency order

1. **Make Renovate actually run again** — diff the `homelab-renovate` App's permissions and
   installations against 2026-07-06, when writes last demonstrably worked (the regression framing
   above); decide whether the ~6h schedule is racing the loop's push traffic; drop the invalid
   `vulnerabilityAlerts.prPriority`; and either fix or remove the `NIX_VERSION` custom manager. Then
   land the orphaned `renovate/pin-dependencies` branch — SHA-pinning the Actions is the single
   highest-value security item on this page.
2. **Add a Renovate-liveness signal** so the next silent stall is loud: a dashboard-issue-exists
   check, or a `renovate_last_pr_timestamp` gauge on the github-exporter beside the FU-108 fix.
3. ✅ **CI gaps closed 2026-08-04** — `manifest-lint` (kubeconform `-strict`) over
   `argocd/resources/*` and `tofu fmt -check -recursive` are both required checks. Two residues by
   decision, not omission: `tofu validate` stays the local `devbox run tf-validate` gate (a provider
   download per PR, the FU-130 WAN class), and **87 of 154 resources are SKIPPED** for want of a
   local CRD schema — `manifest-lint` prints that count every run and fails if it ever validates
   nothing ([`agents/iac-lane.md`](agents/iac-lane.md) §The platform lane).
4. **Extend the FU-044 deterministic revert** to homelab's own ArgoCD apps **for the reversible
   class only** (first-party image pins — no CRD/schema migration, no data-layer coupling); the
   rest stay responder + report-only, per the ruling in §4 above. Half wired 2026-08-04 (pin-only
   predicate in `deploy-revert-argo.yaml`, unit-exercised, never fired by a real Degraded app).
4b. ✅ **Platform lane's path gate landed 2026-08-04/05** — repo-root `CODEOWNERS` + homelab
   flipped to `require_approval` + `require_code_owner_review` (FU-068), then `.agents/fix.yaml`
   made the lane dispatchable (FU-142): [`agents/iac-lane.md`](agents/iac-lane.md) §The platform lane.
5. **FU-097's ruling table**, with ansible/OPNsense first — it is the only class where a merged
   change reaches a *live network device* by hand or not at all.
6. **The prober (FU-102)** is what turns "it synced" into "it works".
