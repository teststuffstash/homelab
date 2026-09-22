# Spike — Flux tofu-controller as the [management box](../management-box.md)'s controller substrate

**Record:** FU-242 (archived 2026-09-21). **Status:** RUN 2026-09-21. **Verdict: NO. Keep the hand-rolled loops** (§Verdict
below). Adopting it, or retiring the spike, is the operator's call. Written 2026-09-16 from the design sitting that produced
ADR-132; design: [`management-box.md`](../management-box.md) §MB4. **Nothing runs on the box during this spike** — the box is the recovery root and a spike is the
thing not yet trusted. **Where:** a throwaway VM, created by hand and deleted after; plain k3s +
Flux + tofu-controller. It ran on `nx-02`, not `pve`, because nx-02 has more room for VMs (operator, 2026-09-21). Phase two, if phase one says yes: the same VM built as a NixOS closure
(`services.k3s.images` / `manifests`), which is also the dry run for the box.

## The question

Can a single-node k3s on the box, running Flux + tofu-controller, replace `mgmt-sentinel.sh` /
`mgmt-apply.sh` / `mgmt-probe.sh` as the reconciler ADR-132 describes — with the box's constraints intact:
state and credentials never leave the box, plan text never leaves it, the timer-driven loops' fail-closed
semantics kept or bettered, one closure = the whole cluster?

## What must be answered (kill-order)

1. **Versions.** Does it drive OUR pinned OpenTofu (`devbox.lock`) and the provider mirror
   (`-lockfile=readonly`), or does its runner image dictate tofu/provider versions? A third toolchain beside
   the jail's and the box's is FU-240's skew again.
2. **Our roots as they are.** `main` with `-state=` on a local file; the Garage roots with `TF_ENCRYPTION`
   and `scripts/tofu-state-env.sh` in the runner's environment; per-root credentials from Secrets. Spike
   against the two READ-ONLY roots only (`github`, `cloudflare` — FU-238's plan-only shape): they can plan
   and can change nothing.
3. **The approval model.** `approvePlan` takes a plan id a human commits to git — the human plan as a commit
   on master. See it end to end: plan appears → id lands → apply runs. Compare with `mgmt-human-plan`.
4. **Drift-only mode and visibility.** Where the plan text lives (a Secret in the mini cluster = inside the
   box: "verdict only leaves the box" holds?), what surfaces as status, whether the `management-sentinel`
   commit status can be posted from a notification instead of bash.
5. **Failure legibility.** An unreachable provider, an erroring plan, a stuck state lock: named states with
   an alert path, or silent retries (the responder incident's shape)? What does `kubectl get terraform` show
   at 03:00 to a seat that has never seen the thing?

## What would settle it

Five yes/no answers plus one measured number (RSS of the mini cluster idle). **Yes** = adopt for the box,
ADR-132 gets its mechanism, the bash loops become the fallback. **No** on 1 or 2 = keep hand-rolling and
retire this spike with the reason. **No** on 5 alone = adopt with a belt written first.

## Out of scope

Metal lifecycle (Tinkerbell/Rufio), the management network, control planes — ADR-132/-133 sequence them
after this. Nothing here touches `nixos/hosts/mgmt/`.

## Findings (run 2026-09-21)

**The rig.** VM 9420 `spike-fu242` on nx-02 was a Debian 12 cloud image with 4 vCPU and 6 GiB. Its
disk sat on nx-02's empty `local-lvm` pool, away from `nvme-thin`, where cp-02, wk-04 and
ci-runner-02 live. It took a DHCP lease (.193), was declared nowhere, and was deleted at the end
together with its disk.
The stack was k3s v1.36.4+k3s1 (traefik, servicelb and metrics-server disabled), Flux v2.9.5
(source, notification and kustomize controllers) and the tofu-controller Helm chart 0.16.5 with
runner `ghcr.io/flux-iac/tf-runner:v0.16.5`.
Three `Terraform` objects ran:

- `github` and `cloudflare` were `planOnly` against the real Garage state, following FU-238's
  plan-only shape.
- `dummy` was a `terraform_data` plus `local_file` root served by a git repo on the VM itself. It
  was the only root allowed to apply, so the approval and failure paths could be exercised without
  a write credential.

The credentials were read-only: `github-mgmt-readonly-pat`, `cloudflare-mgmt-read`, the Garage
state key and `TF_ENCRYPTION` assembled by `scripts/tofu-state-env.sh`. They reached the runner
pods as one Secret through `envFrom`. Nothing was applied to either real root, and no lock was
taken on either one, since both run `use_lockfile = false`.
Deliberately withheld: the three App private keys `mgmt-root-env/github.sh` exports (write-capable
identities — so `github` planned the six count-gated org secrets as destroys plus one
`workflow_push_guard` bypass-actor change, which is exactly what that hook's comment predicts
without the keys) and the cluster-admin kubeconfig `mgmt-root-env/cloudflare.sh` symlinks (so
`cloudflare`'s `kubernetes_*` half was excluded; the rest planned **No changes**, matching the box).

**Side finding (MB4 layer 7): k3s's API cannot be bound to loopback.** Running
`--bind-address 127.0.0.1` breaks every in-cluster client. The `kubernetes` Service endpoint
stays `<node-ip>:6443`, so source-controller, CoreDNS and local-path all crash-looped with
`dial tcp 10.43.0.1:443: connection refused`. Any k3s on the box therefore needs a host firewall
on 6443, not a loopback bind.

### 1. Versions: NO as shipped, yes only through a shim

- **The runner image carries its own toolchain.** It holds OpenTofu **1.12.1**, while
  `devbox.lock` pins **1.12.5**. That is a third toolchain, which is FU-240's shape again.
- **`upgradeOnInit` defaults to `true`** (`+kubebuilder:default:=true`). tofu-controller then runs
  `init -upgrade=true`, which ignores the lock file and floats providers within the constraints.
  So the default is the version skew this question exists to catch.
- **The binary can be replaced.** The runner looks tofu up on `$PATH` (`runner/server.go`,
  `exec.LookPath`). Setting `PATH` and mounting `/nix/store` read-only from the host (a NixOS box
  has it natively) made the runner report `OpenTofu v1.12.5`.
- **The provider mirror works:** `TF_CLI_CONFIG_FILE` pointing at a `filesystem_mirror` built by
  `tofu providers mirror` from master's lock files.
- **`-lockfile=readonly` cannot be expressed:**
  - terraform-exec refuses `TF_CLI_ARGS_init` and `TF_CLI_ARGS_plan` in the runner environment
    (`manual setting of env var "TF_CLI_ARGS_plan" detected`).
  - terraform-exec always passes `-upgrade=<bool>`, and tofu rejects that next to
    `-lockfile=readonly`.
  - It only worked with a `tofu` **wrapper script** first on `PATH` that rewrote the arguments.

### 2. Our roots as they are: NO, not as they are

- **Garage + `TF_ENCRYPTION` + per-root creds from a Secret: yes.** State decrypts in the runner,
  and the saved plan that tofu-controller stores (Secret `tfplan-default-<name>`, gzip) is
  AES-GCM ciphertext under our passphrase, because `TF_ENCRYPTION` carries a `plan {}` block.
- **The root's own `backend.tf` is not usable as it is.** `backendConfig.disable: true` is the
  documented way to say "use mine", and tofu-controller then plans **without `-out`**
  (`controllers/tf_controller_plan.go`). Every run died with `error saving plan secret … open
  tfplan: no such file`. The workaround is a copy of the S3 block in `backendConfig.customConfiguration`,
  which is written out as `backend_override.tf`. That puts the backend in two places, and they
  drift apart.
- **`main`'s local-file state shape works.** `backend "local" { path = "/state/…" }` on a hostPath
  wrote state, serial 1, on the dummy root.
- **The policy's `plan_exclude_types` have no field.** tofu-controller has `targets` but no
  `exclude`, and the environment route is blocked (above). The same wrapper had to compute
  `-exclude=` from `tofu state list`, which is `mgmt_root_excludes` again, re-implemented inside
  the runner.
- **File-shaped credentials** (the App PEMs, and the kubeconfig as a file) would go in through
  `varsFrom` and volume mounts. The spike did not exercise this, because those credentials were
  withheld.

### 3. The approval model: `approvePlan` cannot be a commit on master in a monorepo

- **Committing the approval moves the revision it approves.** tofu-controller names a plan
  `plan-<branch>-<sha[:10]>` after the source revision. With the `Terraform` object in the same
  repo as the root, which is homelab's shape, committing `approvePlan: plan-master-c9e1d9d526`
  moved master to `fbae2eb`. The controller re-planned as `plan-master-fbae2eba10` and waited
  again, and it kept doing so on every approval.
- **It works from a second repo.** With the object in a separate "approvals" repo, approving
  `plan-master-008b9beb99` applied in under 15 s.
- **Approval is a prefix match** (`strings.HasPrefix(pending, approvePlan)`,
  `controllers/tf_controller_apply.go`). `approvePlan: "plan"` would approve any plan, so a lint
  would have to guard the approval itself.
- **Staleness is checked by name, not by content.** Before a manual apply the controller
  re-plans and compares plan *names*. At an unchanged revision, a world that changed since the
  human read the plan still produces the same name, and the fresh plan the human never read is
  applied. `mgmt-tf`'s plan-id apply is stronger: it applies the saved binary, and tofu refuses it
  once the state serial has moved (FU-248, [`management-box.md`](../management-box.md) §MB3).
- **Compared with `mgmt-human-plan`,** that path is a human-ordered plan of one PR head with a
  y/N on the exact sha. It has no counterpart here, because tofu-controller plans the *tracked
  branch*, not PR heads. The branch planner is a separate component, and the spike did not
  install it.

### 4. Drift-only mode and visibility: yes for detection, no for a status poster

- **Drift is detected and shown as a condition.** `local_file` content was tampered on the host.
  One interval later (2 min) the object went `Ready=False reason=DriftDetected`, with a
  `DriftDetected` event and `status.lastDriftDetectedAt`, and nothing was re-applied without
  approval. `planOnly: true` on the real roots gave `Ready=True "Plan no changes"` (cloudflare) or
  `Ready=Unknown TerraformPlannedWithChanges` (github).
- **The plan text stays inside the mini-cluster, but in three places:**
  - the encrypted Secret above;
  - `storeReadablePlan: human` → a **plaintext ConfigMap** `tfplan-default-<name>`;
  - on drift, the **plan text inside the condition message** of the object.

  "Verdict only leaves the box" holds only while the k3s API itself never leaves the box.
- **No notification path.** Flux 2.9's `Alert.spec.eventSources[].kind` enum rejects `Terraform`
  (the API server refuses the object). So the `management-sentinel` commit status cannot come from
  notification-controller.
- **No usable metric either.** tofu-controller exports `gotk_reconcile_duration_seconds` per
  object but no condition or readiness metric. Reading the verdict out takes a poller, meaning
  bash or a kube-state-metrics custom-resource config.

### 5. Failure legibility: NO. Lock and plan errors are named, a hung provider is silent

- **Stuck lock: named, and it heals on release.** A host process held the `fcntl` lock on the
  dummy's state file. The object went `Ready=False` with `error acquiring the state lock` and the
  full tofu error in the message. It retried every interval (`status.reconciliationFailures` 13
  after 5 min). Within 30 s of the lock being released it showed a fresh pending plan.
  `spec.tfstate.forceUnlock` exists as an opt-in.
- **Erroring plan: named.** The cloudflare root without its kubeconfig went `Ready=False
  TFExecPlanFailed`, with the tofu error in the message and a `ReconciliationFailed` Warning event.
- **Unreachable provider** (`GITHUB_BASE_URL` → TEST-NET `192.0.2.1`): **silent.** The runner's
  `tofu plan` and the github provider process were still alive after **36 min**, and the object
  was still `Reconciling=True / Ready=Unknown "Terraform Planning"`. There were zero events and
  no `reconciliationFailures` count, past even the controller's `--runner-rpc-timeout` default of
  30 min. This is the responder incident's shape exactly: a liveness-looking state with no output.
- **At 03:00,** `kubectl get terraform` gives a one-line reason per root that a stranger can read.
  Nothing pages, though: no Alert can select these objects and there is no condition metric
  (§4). Silent retry is the default, and the alerting belt would have to be written first.

### The measured number

**About 1.4 GiB idle** (summed RSS, three `Terraform` objects suspended, no runner pods; guest
`free` showed 1322 MiB used). The two largest parts:

- `k3s-server` alone was 697 MiB, with containerd 182 MiB.
- The four Flux and tofu-controller pods came to ~335 MiB. kustomize-controller (118 MiB) was
  there only for the approval test.

Every planning root adds a runner pod on top: tofu plus its providers, for the length of the
plan.

### Phase two, as a note only

Phase one said no, so phase two was not built. A `nix eval` against the pin (`nixos-26.05`
`21a67dc`, `nixosConfigurations.mgmt`) confirms `services.k3s.images`, `.manifests`,
`.autoDeployCharts`, `.disable` and `.extraFlags` all exist. The pin's k3s is 1.35.7+k3s1 and
`fluxcd` 2.9.4 is packaged. tofu-controller is not, so it would come in as `dockerTools.pullImage`
digests, and the runner image would have to be rebuilt from Nix to carry devbox's tofu instead of
the image's own.

## Verdict

**NO. Keep hand-rolling; the bash loops stay the mechanism.** Question 5 is a no as well (a hung provider is silent). The rule under §What would settle it is
"No on 1 or 2 = keep hand-rolling", and both came back no in their as-is form:

- **Question 1:** pinning our toolchain and mirror took a `tofu` wrapper script inside the runner.
- **Question 2:** the root's backend had to be copied, and the policy's excludes had to be
  recomputed in that same wrapper.

The wrapper *is* `mgmt-lib.sh`'s plan logic. It just moved into a container.

Question 3 is the deeper mismatch. Its approval model cannot express "the human plan as a commit on
master" in a monorepo, it matches by prefix, and it checks staleness by revision name, all weaker
than the FU-248 plan-id apply the box already has.

Two pieces of evidence are worth keeping for any later substrate question:

- the drift condition and the failure states read well from `kubectl`;
- a k3s on the box cannot bind its API to loopback.

Retiring FU-242 on this reason, or amending ADR-132's "decided by the spike" line, is for the
operator.
