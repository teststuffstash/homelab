# The management box (R12) — the out-of-band applier

**Decision:** [`adr.md`](adr.md) ADR-129 (the OS + update shape). **Tracked by:** FU-097 (which
surfaces it may reconcile — its ruling table gates the box's first real job) and FU-012 (the state
and credentials that move here). **End-state it serves:**
[`spikes/no-human-in-the-loop.md`](spikes/no-human-in-the-loop.md) — recovery path 5, and this doc
is the build for the pilot that path's §The pilot's build order sequences.

A box whose only job is to hold the dangerous credentials and `main`'s tofu state and to apply
changes to things it is not part of. No workloads, no storage, the fewest reasons to break — the
spike's phrasing, because **this is the recovery root and a recovery root's own recovery is
manual** (a stick in a drawer). Everything below is shaped by that one sentence.

**The pilot is `thinkcentre`** (retired from cluster duty 2026-09-12): it satisfies the row's key
property — dual-homing is possible, `J7B1`/`J8B4` free on chipset root ports — but it is NOT the
permanent box (27.9 W idle for a box doing almost nothing, no AES-NI on the G840, and an x16 CPU
root port absent for unexplained reasons). The role moves to a Tiny when one appears; the private
hardware register's R12 row carries the supply side. The pilot exists to de-risk the SPEC on a box
nobody depends on.

## The one distinction that shapes the update design

The box must be **live** independently. It does not need to be **fresh** independently
(operator, 2026-09-12). If whatever updates it is down, the box keeps running its current
generation with a slightly older glibc, which is a non-event. That is what makes it acceptable for
the cluster — the thing this box exists to rescue — to drive its updates.

The consequence is not optional: **the apply may be remote, the rollback must be LOCAL.** If a bad
closure lands and the updater then dies, nothing cluster-side can undo it. Same rule the spike
states for every deadman — local to the target.

## MB1. Phases

| | Phase | Deliverable | State |
|---|---|---|---|
| **A** | the box is maintainable | OS installed declaratively, SSH credentials + a rotation scheme, `main`'s tofu state and the dangerous creds moved here (FU-012's other half), the probe + the local deadman | 🔜 **installed 2026-09-13** (NixOS from the stick, generation 2 promoted by `mgmt-confirm`, the belt 4/4 under its unit on the env-file creds; timers masked by design). **`main`'s state + credential set moved here 2026-09-13** (first plan on the box: init 12 s, plan 17 s, No changes). Remaining: the box-scoped credential swap (FU-012) |
| **S** | the management sentinel | plan-on-PR: a required `management-sentinel` status on homelab PR heads, evaluated on this box behind an input allowlist — read-only, so it precedes B and is not gated on FU-097's table | 🔜 BUILT 2026-09-13 (`scripts/mgmt-sentinel.sh` + `mgmt-sentinel.timer`, `policy/mgmt/plan-input.yaml`); the required-context flip is PR#1617, operator-applied — §MB3 |
| **B** | one trivial apply | a `tofu apply` of something nobody depends on — explicitly NOT an unattended control-plane or router operation. The point of the first rollout is the PATH, not the change. **The surface is named (operator, 2026-09-13): the main root's raw-k8s residue** — §The test surface below | 🔜 BUILT 2026-09-13 as the apply LOOP (`scripts/mgmt-apply.sh` + `mgmt-apply.timer`: master moved → plan → every address on the policy's apply allowlist → apply, else refused with a `management-apply` status) — phase C's merge trigger and B's first apply are the same mechanism |
| **C** | triggers | homelab PR merges (the `ROADMAP.md` §Deploy paths gap: a merged change to an unreconciled surface deploys nothing today) + drift detection (the `tofu plan` cron FU-097 asks for) | ⬜ |
| — | *then* the management network | recovery path 2 and the rest of the spike's original order, resumed once the box is dull | ⬜ |

## The test surface — the main root's raw-k8s residue, kept on purpose

The ArgoCD lever ([`dependency-upgrades.md`](dependency-upgrades.md) §Tofu is not one class) moved
the main root's helm releases out in 2026-08 (FU-136) and left a class of **raw `kubernetes_*`
resources that ArgoCD does not need to run** — Home Assistant, UniFi + its Mongo, the monitoring
namespace's dashboards and secrets, the forgejo runner and its CNPG Cluster, the kata RuntimeClass,
the `random_password` → Secret residue. ADR-005 allows all of it to move, and **it stays in tofu
deliberately** (operator ruling, 2026-09-13): it is the one nondestructive thing this box can apply.
With a single OPNsense (and, when this was ruled, a single control plane — three since 2026-09-22,
ADR-133), anything that touched the router, the CPs or the Proxmox host was instant whole-cluster downtime — so phases B and C run on this residue, where a
wrong apply costs a dashboard or a Home Assistant restart, and the quirks get ironed out there.

The sequence, in this order:

1. the box proves the path on the residue (phase B, then C's merge-triggered applies);
2. **Renovate updates through the box** — the `ROADMAP.md` G-D goal's next run rides this
   mechanism instead of a jail apply;
3. only then the residue migrates to ArgoCD, and the fleet grows the second OPNsense (CARP pair)
   and the third CP + more Proxmox hosts for the box to operate on — the spike's paths 2 and 3.

Which means the FU-097 table's first rows are ruled: OPNsense, the control planes and the Proxmox
host stay **human-applied until the redundancy exists**; the residue is the box's; `provisioning`
is the belt's canary. The table still has to be written — those are its anchors.

## OS and install

**NixOS**, and the reason is the update criterion rather than taste: this is the one box in the
fleet whose recovery is manual, so an update it cannot undo by itself is the failure that costs
hands. Generations give a rollback that needs no second machine. The fork and the rejected
alternatives are ADR-129.

**Installed once from a USB stick, declaratively.** The stick only gets an SSH-able installer onto
a box with no BMC; the install itself is `disko` + the flake, driven by `nixos-anywhere` from the
jail, so nothing is typed into an installer UI and the result is what git says. `devbox run mgmt-usb`
(`scripts/mgmt-usb.sh`) writes the medium on the HOST where the stick is — it probes and confirms the
target device BEFORE building the flake's `installerIso`, so a wrong device costs nothing.

**Not PXE, yet, and not netboot ever.**

- *Netboot as the running system is ruled out*: a netbooted NixOS has no local generations (the
  closure arrives from the network each boot, so rollback means editing the server), and it would
  make the recovery root depend on Matchbox, on dnsmasq for its address, and on the LAN being up
  to boot at all — the inversion this box exists to remove.
- *PXE as the install path is deferred, not rejected*: it needs a non-Talos asset class in Matchbox
  (whose ansible role syncs Talos assets only) plus the flag→install→**unflag** discipline, or a
  PXE-first box with a live group sits in a reinstall loop (`tofu/provisioning/matchbox.tf`). It
  earns its keep at the **second** install of a config that has stopped churning — i.e. when the
  role moves to the permanent Tiny. Until then the stick has a property PXE cannot have: it works
  with Matchbox, dnsmasq and OPNsense all down, which is the recovery-root property anyway.
- The box stays PXE-first in BIOS harmlessly: an unflagged MAC gets a 404 and boots local disk
  (`provisioning.md`).

## Two pins, two revert paths, one git

"A new tofu broke it" is not an OS question. The toolchain and the system closure are pinned
separately and roll back separately:

| Layer | Pin | Bumped by | Rollback |
|---|---|---|---|
| Toolchain — `tofu`, `talosctl`, `ansible`, `openssl` | **`devbox.lock`** (committed, repo root) | the existing weekly [`devbox-update.yaml`](../.github/workflows/devbox-update.yaml) — one synchronized `@latest` re-resolve across repos, auto-merging CI-gated PR. ⚠ Renovate's nix/devbox manager stays disabled on purpose: `@latest` is untrackable ([`renovate.md`](renovate.md) §Gotchas encountered) | `git revert` the lock commit |
| System closure — kernel, glibc, systemd | `nixos/flake.lock` | the same git flow | a generation; automatic on a never-boots, see Rollback |

This is why the box runs its tools through `devbox run` from a checkout of this repo rather than
from the system closure: **one toolchain pin for the jail and the box**, which is the whole
argument for `devbox.lock` being the pin, and it keeps the system closure tiny.

## The update loop: pull, and the cluster may poke

The box pulls **`master`** on a timer (hourly level; the doorbell of FU-237 (d) is the later edge)
— ADR-129 as **amended 2026-09-14**. The gate is at MERGE, not at a second ref: `CODEOWNERS`
owns `/nixos/`, and `scripts/` + `policy/` stay owned through the ADR-128 trial, so every file the
box executes from its checkout was a human read before it landed. The operator-advanced
`mgmt-release` ref the design was born with (2026-09-12) was a second promotion of commits already
reviewed, not a safety layer — in its two days it was never created, and the box had pull + gate
+ rollback the whole time (the ArgoCD shape: follow the branch, gate the merge, roll back locally).
Two things stay deliberate: **activation is diff-gated** — `mgmt-pull` runs `nixos-rebuild test`
only when `nixos/` changed between the last activated revision and the target, otherwise it just
advances the checkout (the units read `scripts/` and `policy/` at each start, no activation
needed); and **every fetch is authenticated** (`mgmt_git`, the #1637 rule), failing loudly rather
than falling back to anonymous. The cluster at most pokes it. Not fussiness — a
pushed update means something inside the cluster holds a credential that can rewrite the recovery
root, and the spike's §What stays human lists this box beside the CA keys and the Tier-0 wallet as
a trust anchor. Pulling merged commits is the same automation with no inbound key, and it takes
the jail out of the loop (operator: updates should not be the jail's responsibility).

Internet egress on the box is allowed (operator, 2026-09-12), so the pull needs no in-cluster
mirror to work.

## MB2. Detection — the drift belt and the health probe are the same probe

This is the **belt**, not the deadman — it reports, and nothing it says reboots the box
(§Rollback layer 1 says why). **`tofu plan` returning "No changes" asserts the toolchain, the
state's readability, the credentials and the network path in one read-only call.** A non-empty diff or a non-zero exit is
the alarm either way, which is why FU-097's drift belt and this box's own health check are one
mechanism. The probe set (`scripts/mgmt-probe.sh`, run by a systemd timer on the box):

| Check | Asserts |
|---|---|
| `tofu plan` → empty on the **cone-clean** roots only (`provisioning`, and **`github`** since 2026-09-13 — read-only PAT + the three App keys via `scripts/mgmt-root-env/github.sh`, FU-238) | toolchain + remote state + encryption passphrase + Garage reachable + no drift. ⚠ NOT "every migrated root": `infisical` is migrated but its provider auth port-forwards into the live cluster, so its plan asserts the cluster is up — the opposite of what this box probes; **`cloudflare` is the same class** (its cloudflared Deployment half rides the kubernetes provider — found 2026-09-13 on the box, retracting the 2026-09-12 reading that it was cone-clean; the SENTINEL still plans it per PR head with the read-only `homelab-mgmt-read` token, §MB3 — a plan-on-PR may assert the cluster, the belt may not); `main` is local state until FU-012's copy lands here. Measured 2026-09-12 from the jail: `cloudflare` and `provisioning` both plan EMPTY, which retires [`tofu-state.md`](tofu-state.md)'s note that `cloudflare` carries a standing 1-change comment drift |
| `talosctl version` against a live node | no client/server skew after a toolchain bump |
| **the node diff** (`check_nodes`, 2026-09-21; the Kubernetes-facing axes the same day) | DECLARED (`tofu output node_install_targets` — the same expression the upgrade verb passes as `--image` — with its `.ephemeral` install-time half, and `node_declared_k8s`: the labels/taints tofu itself sets, `tofu/outputs.tf`) vs LIVE, per node, seven axes: **reachable** / **version** / **schematic** (`talosctl version`, the `schematic` extension), **registered** (a Node object exists — wk-metal-02's ~12 h, 2026-09-21) / **labels** / **taints** (the Node object, compared over the union of keys tofu declares, so an imperative `kubectl label` on one of those keys is drift too) and **ephemeral_disk** (`volumestatus EPHEMERAL` vs `systemdisk`, plus the selector's `disk.<field>` for the `disk.transport == "nvme"` form) | that the fleet runs what git says. This is §MB4 layer 1 — the diff install-time drift needs, because `talos_machine_configuration_apply` records DELIVERY and Talos honours install-time fields only on the next install, so state is truthful, `plan` is clean, and the node still runs the wrong image (nx-01 after #1717). ⚠ It REPORTS, never fails the probe: a version gap is the normal state of a rollout in progress, and a belt that reds the box on every window teaches everyone to ignore it. Publishes `mgmt_node_drift{node,axis}` (0 = checked and matched, which "no series" cannot say; a read failure publishes no series rather than a false 1); the "too long" judgement belongs to the `MgmtNode*` alerts' `for:` (`argocd/resources/mgmt-metrics/`) |
| **the substrate-currency check** (`check_substrate`, 2026-09-23 — FU-254) | DECLARED (the `default` of `talos_version_{controlplane,worker}` / `kubernetes_version` / `cilium_version` in `tofu/variables.tf`, read straight out of the checkout — deliberately not a `tofu output`: none carries the last two, and `node_install_targets` needs the main state and an initialised root) vs UPSTREAM (each project's GitHub releases, drafts and prereleases dropped). It asserts the one thing every other check here takes for granted: **that the declaration itself is still current, and still inside its project's support window** — Talos 1.13 left community support at the 1.14.0 release (2026-09-03) and the fleet learned it from a conversation, not a mechanism. Renovate cannot fill this: class 6 in [`dependency-upgrades.md`](dependency-upgrades.md) is deliberately "must not auto-deploy". Publishes `mgmt_substrate_minors_behind{component}` (0 = current), `mgmt_substrate_supported{component}` (0 = EOL) and a fetch-age series; the "how long is too long" judgement is `MgmtSubstrateBehind` (7 d, still supported) / `MgmtSubstrateUnsupported` (1 h, past the window) in `argocd/resources/mgmt-metrics/`. ⚠ **The support windows are hand-encoded constants** in the check (Talos: the CURRENT minor only — community support for 1.13 ended on the 1.14.0 release date, so one minor behind is already EOL and Talos skips the `Behind` grace entirely; Kubernetes and Cilium: three minors) — nothing here discovers a policy, so an upstream that changes its window makes the EOL gauge lie quietly until that table is corrected. ⚠ The upstream answer is **cached 6 h**: the belt ticks every 15 min, and a fetch per tick would be ~288 GitHub API calls a day against a 60/hour anonymous per-IP budget for an answer that moves a few times a year. A component whose release list cannot be read publishes NO series rather than a false "current" |
| `ansible --check` on an OPNsense play | the collection + the pinned httpx interpreter + the API credential still work, and the recap's `changed=` count is read for drift — class 9 in [`dependency-upgrades.md`](dependency-upgrades.md) is the sharpest unreconciled-surface gap. ⚠ **A partial belt, by construction:** `ansible-playbook --check` exits 0 even when tasks report `changed` (only a task *error* is non-zero), so the exit code alone proves plumbing, not currency — hence the recap parse; and `oxlorg.opnsense.raw` tasks with `action: post` return `changed=False` in check mode by design, so **advanced-settings drift stays invisible** no matter how the recap is parsed |
| each credential it holds, read once | a rotation did not lock the box out |

The metric *shape* copies the Garage write probe: the verdict **and** a `*_last_run_timestamp`, so
a staleness alert catches "the box is wedged" and not only "the box says no". This is FU-102's
prober contract applied to its first non-stack consumer — the spike's line is that *the prober is
the human*.

**The transport is the textfile collector** (FU-252's ruling, below): the probe writes
`mgmt_probe_<mode>.prom` — the verdict, `mgmt_probe_last_run_timestamp{mode}` and the node diff —
into `/var/lib/node-exporter-textfile/`, which the cluster Prometheus scrapes as job `mgmt-node`.
The Pushgateway path the probe was born with never ran (it needed a deliberate exposure of
cluster-internal plumbing) and is gone. Alerts, in `argocd/resources/mgmt-metrics/`, by how long
each axis may legitimately differ: `MgmtNodeMissing` (reachable/registered, 2 h — longer than a
reinstall window), `MgmtNodeLiveStateDrift` (labels/taints, 1 h — applied live), `MgmtNodeInstallDrift`
(schematic/ephemeral_disk, 24 h — only a window fixes them), and `MgmtBeltStale` /
`MgmtBeltMetricsAbsent` for the belt itself. **`MgmtBeltCheckFailing` (2 h = 8 ticks) reads the
belt's own VERDICTS** — `mgmt_probe_check{check,status}`, published since the beginning with no
rule consuming it, so a check could fail on every tick and say so to nobody: the `talos` skew
check did exactly that from the 2026-09-22 move to v1.14.1 until a seat ran the unit by hand
([FU-286](follow-ups.md)). The **version** axis has no box-side alert:
`TalosFleetVersionSplit` (`argocd/resources/talos-substrate/`, `for: 24h`) already owns the
stalled-rollout case from `kube_node_info`, with no transport at all.

⚠ **Known hole:** Prometheus is in-cluster, so a cluster-down event blinds the detector. Acceptable
for freshness-class breakage and irrelevant to the local deadman (which needs no alerting to
work), but the spike's "alerts leave by two independent paths" has no second path yet.

### A standing refusal is a THIRD verdict shape, and nothing detects it

*Detected since 2026-09-21 (FU-252, archived): `MgmtApplyResidueStanding` + the box-side belts below.*

The shape above has two states — alive, and wedged. The apply loop has a third: **alive, correct,
and saying no for days.** Measured 2026-09-18: `mgmt-apply` refused `main` continuously from
**Sep 14 11:42Z** (`7d9949ee`, 2 addresses outside the allowlist) to `e63b0073` (**8**), restating
*"was REFUSED — waiting for a new commit or a human apply"* **1101 times**. Every tick ran
perfectly. A verdict-plus-`_last_run_timestamp` alert stays GREEN through all of it, because the
verdict is not an error and the timestamp is fresh.

Two properties make it worth its own detector rather than a louder log line:

- **It ratchets.** A refusal writes `refused-rev` and deliberately does not stamp the apply
  baseline, so every later master commit touching the root joins its residue to the same pending
  apply: 2 → 4 → … → 8 in four days. The human apply grows monotonically and gets less reviewable
  the longer it stands — the cost of tolerating it is not flat.
- **Its only surfaces are unwatched.** No `mgmt_*` series exists; nothing scrapes 192.168.2.53 at
  all (`up{instance=~".*2\.53.*"}` = 0 series, 2026-09-18); no alert rule names the box loops. What
  remains is journald on an unscraped box and a red commit **status** on master — and a status is
  not a check-run: `GET /commits/<sha>/check-runs` does not return it, which is exactly how a jail
  session read master as green on 2026-09-18 while four days of refusal sat on HEAD. A reader that
  wants the truth asks `GET /commits/<sha>/status`.

So the metric the loop actually needs is **age of the oldest unapplied residue** (and its address
count), not liveness. **Transport, ruled 2026-09-21 (operator): the hypervisors' pattern** — the
box runs node_exporter with the textfile collector (`nixos/hosts/mgmt/default.nix`, 9100 open to
the LAN only), `mgmt-apply.sh` writes `mgmt_apply_*` on every exit, and the cluster Prometheus
scrapes it as the static job `mgmt-node`. **The residue-age belt is `MgmtApplyResidueStanding`**
(github-exporter, from master's commit status, since 2026-09-18). The box-side belts in
`argocd/resources/mgmt-metrics/` cover what a status cannot show — a loop or box that stopped
posting: `MgmtApplyLoopStale`, `MgmtApplyMetricsAbsent`, `MgmtBoxDown`.

## MB3. The management sentinel — plan-on-PR (ADR-131)

The decision: [`adr.md`](adr.md) ADR-131. The tofu lane has no L1 today ([`agents/iac-lane.md`](agents/iac-lane.md)
§Assurance layers — the manifest diff is the -iac repos'), and it cannot have one anywhere but
here: a plan needs the state and the credentials, and FU-012's whole point is that those leave
the jail for this box and never enter the cluster or the CI plane. So the box evaluates PR heads,
and the design is shaped by the one way it differs from the iac-sentinel (§L0b): **the iac-sentinel
never executes PR content; `tofu plan` does.** It downloads and runs the provider binaries the PR's
`required_providers`/lockfile name, evaluates `data` sources (`external` runs a program, `http`
exfiltrates), reads the PR's locals and var files — all with the root's credentials in the
environment. A worker-authored head is hostile by assumption (the sentinel runs BEFORE review), so
plan-on-PR without a pre-execution gate is remote code execution on the recovery root.

**Two stages, and the first never executes anything:**

| Stage | Reads | Does | Fails as |
|---|---|---|---|
| 1 — input allowlist | the PR tree as DATA, the policy from **master** (`git show origin/master:policy/mgmt/…`), never the PR's copy | for each touched root: the diff vs base may touch only allowlisted file classes (`*.tf` declaration bodies, `*.tfvars.example`, docs) and none of the deny list — `.terraform.lock.hcl`, `required_providers`/`terraform {}` blocks, `backend`/`encryption` config, `data "external"`/`data "http"`, any `provisioner`, `.terraformrc`/CLI-config-shaped files, symlinks, files outside the root | `failure`, rule named |
| 2 — the plan | the head in an **ephemeral worktree** (`git worktree add` under `/var/lib/mgmt/sentinel/`, removed after) — never this box's own checkout, which is the system's source at `master` | `tofu plan -detailed-exitcode -input=false -lock=false -lockfile=readonly` with providers from a **local mirror** pre-populated from master's lockfile (`tofu providers mirror`, refreshed by the pull loop); network reach is the provider APIs the root already needs | engine error → `error` (fail-closed, healed next run); plan error → `failure` |

The first form of the policy is the iac-sentinel's own bash path-rule shape (file classes + a
grep-shaped declaration deny list); Kyverno over `hcl2json` output is the v2 when a rule needs
structure — the same "v2 when serial time reaches job-overhead scale" threshold as §L0b. The file
lives in `policy/mgmt/` (a sibling of `policy/iac/`, whose `*.yaml` glob is Kyverno-only), already
under the `/policy/` CODEOWNERS row — so it is read from master, codeowner-gated, and **lands first
as its own change**: a PR that needs a wider allowlist is red until master's copy widens, exactly the
`policy/iac/exceptions/*` ordering rule.

**Wake — edge + level, and the doorbell carries nothing.** The in-cluster `iac-sentinel` run
(`agents/coordinator/sentinel-argo.yaml`) pokes a socket-activated HTTP doorbell on the box after its
own evaluation; the payload is ignored and the box re-lists open homelab heads itself (the
`/coordinate` doctrine: a doorbell is never a work item), which is what keeps "the cluster may poke
it but holds no credential into it" literally true. A `*:0/5` timer is the level backstop and ships
FIRST — a box that only polls is already correct; the doorbell is the merge-wait optimization. The
unit is a oneshot, so runs serialize by construction.

**Verdict-only leaves the box.** The plan output can carry sensitive attribute values and the
state's shape, so it stays in the journal. What leaves: the `management-sentinel` commit status
(the `post_status` shape of `scripts/iac-sentinel.sh`) and one PR comment listing changed resource
ADDRESSES with add/change/destroy counts from `tofu show -json` — plus, on the same terms, the
NAMES of the outputs whose value the plan changes (that same JSON's `.output_changes` key, read
into the summary's `$out.outputs` side channel) — never values, both under the
`homelab-sentinel` App (ADR-130; the App row in [`github-apps.yaml`](github-apps.yaml) already
grants `statuses`+`pull_requests` write for this). The box holds that App's private key as one more
wallet-provisioned root-only file (§Credentials), so the key sits in two stores — Infisical for the
in-cluster poster, the env tree here — one identity, two seats.

**Scope split, one classifier.** A required context must be present on EVERY head, and the
recovery root must not become the merge gate for doc PRs. So the in-cluster `iac-sentinel` run posts
`management-sentinel: success` for heads whose diff touches no root in the policy's root list, and
the box posts for the rest — both readers of the same master copy of the policy file, so there is
one classifier. The root list: `main` (apply-allowlisted), `provisioning` and, since 2026-09-13,
`github` and `cloudflare` (all plan-only — FU-238: the box holds a read-only PAT plus the App keys the
count-gated org secrets need, and the read-only twin of the Cloudflare write token
(`tofu/cloudflare-token/mgmt-read.tf`), so both plans are clean; applies stay on the host / in the
jail); ansible plays (`--check` of a PR head — the same executes-PR-
content class, the same allowlist) after that.

**Privilege.** The plan runs as its own unix user with its own `EnvironmentFile`
(`/var/lib/mgmt/sentinel.env`), never as root with the belt's file: one consumer, one token, at its
tier — and read-only credential variants where the provider's model allows (Proxmox roles do; the
state key + passphrase cannot be less than a full state read, which is the residual ADR-131 names).
Freshness: `mgmt_sentinel_last_run_timestamp_seconds` beside the belt's, publishable once §MB2's
exit path exists.

**Build order** (FU-237): (1) `policy/mgmt/` allowlist + root list, landed alone; (2)
`scripts/mgmt-sentinel.sh` + unit + timer on the box in SHADOW (verdicts in the journal only);
(3) the App key on the box, status + comment posting; (4) the flip — the context required and
pinned to `homelab-sentinel`'s integration id in `tofu/github/repo_rulesets.tf`, the in-cluster
no-root poster in the same change; (5) the doorbell.

**The execution surface, precisely** (the #1619 review finding): stage 1 judges only the tofu
tree, so stage 2 must execute NOTHING else from the head — `devbox run` resolves `devbox.json`
(whose `init_hook` runs) from its cwd, so every tool call runs from the loop's OWN clone reset to
`origin/master`, tofu is pointed at the worktree by absolute `-chdir`, and the state-env script is
master's copy. A PR's `devbox.json`, `scripts/`, hooks — never executed. The policy also denies
the JSON/auto variants of tfvars and config (`*.tfvars.json`, `*.auto.tfvars*`, `*.tf.json`)
and remote module sources (init would fetch them) — and, since the #1635 review, **new
`kubernetes_*` data sources and `import` blocks**: a plan READS what those name with the root's
credentials, which for the kubernetes provider is the cluster-admin kubeconfig (`main` and
`cloudflare` both ride it; no scoped variant exists yet — FU-012's next mint), and an error
quoted back would make the sentinel an existence oracle for any object from any PR. The same
review narrowed what an errored plan posts: the tofu `Error:` headlines only, never the body.

**What the verdict covers, per root — the reviewer's expectation.** `main`: everything, and the
apply allowlist decides what ships. `provisioning`: everything, plan only. `github`: repo rulesets
(the pinned required checks), org secrets, deploy keys — **not** the 13 `github_repository` settings
nor the org ruleset (GitHub returns those only to an admin-WRITE token, `plan_exclude_types`).
`cloudflare`: the tunnel, its remote config, DNS + DNSSEC, the mTLS pair, the rulesets and the zone
settings — **not** the tunnel TOKEN data source (a credential read no Read group covers; 401 even
under the jail's read-all token) nor its two in-cluster dependents, the cloudflared Secret and
Deployment, which tofu drops with it. In both cases the comment lists what was not planned, with
counts — the set is *state minus what the plan carried*, so an exclusion's dependents are named,
not just the policy's types — with the policy's per-root `plan_exclude_note` as the reason, and
the status description carries the count. A worker, reviewer or coordinator reading a green
`management-sentinel` on a PR that edits repo settings or the cloudflared half should read it as
"the parts the box can see are clean", never as "applied-equivalent".

**An OUTPUT-ONLY plan is a real plan.** A new `output` block gives `plan` exit code 2 with every
RESOURCE a no-op — "save these new output values … without changing any real infrastructure". Read
through resource changes alone that is exit-2-with-an-empty-summary, which is the silent zero the
2026-09-13 false negative installed the INCONSISTENT verdict against (§the `github` root), and it
duly failed the first PR to add one (#1774's `node_install_targets`, 2026-09-18). So the summary
carries a second side channel — `$out.outputs`, the changed output names from `.output_changes`
in `tofu show -json` — and only exit 2 with NEITHER is
inconsistent. The apply loop **applies** such a plan rather than skipping it: outputs live in the
state, so an unapplied one would leave §MB2's drift belt (the same `plan`, its rc the alarm)
reporting `main` as drifted forever. Nothing is offered to the apply allowlist because no address
is touched.

**The install-impact line (ADR-132 §MB4 layer 2, 2026-09-21).** The plan is blind to one class by
construction: Talos honours the schematic, `install.disk`, the EPHEMERAL `VolumeConfig` and
`machine_type` only on the next install, so a head that changes them plans as a clean in-place
config apply (nx-01 after #1717 — §MB4 item 1). So `main`'s verdict carries a second section,
computed from the plan's own `node_install_targets` output (`tofu/outputs.tf` — per node:
schematic, installer, version, role, install disk, EPHEMERAL): its BEFORE is the applied
declaration, its AFTER is this head, and every node whose install-time fields differ is named
with the fields that moved — *"this head changes the install of nx-01 (EPHEMERAL) → one
reinstall window"*. For the upgrade-class axes (schematic, version) the head's value is then
diffed against LIVE by `mgmt-probe.sh`'s own `check_nodes` (fed the head's declaration through
`NODE_TARGETS_JSON`, answers through `NODE_DRIFT_OUT`), so a head that only codifies what already
runs costs no window. Window kinds: **upgrade** (schematic / version / installer — the
`node-maintenance.sh upgrade` path), **reinstall** (install disk / EPHEMERAL / role — Talos never
re-partitions, and `machine_type` is baked at install), **install** (a new node). The same
names-only rule as the rest of the verdict: node names and FIELD names leave the box, never a
schematic id, disk path or selector. The status description gains ` · install: <node> <kind>`
(or ` · install: N windows`); a head that moves no install gets *"Install impact: none"* in the
comment and nothing in the description. It is advisory — the status stays green; the line is
what the codeowner read refuses on, not a gate. Two limits, named: a node that was ALREADY
drifted from live before this head is not listed (that is the belt's `mgmt_node_drift`, §MB2),
and the reinstall-class axes compare head vs applied declaration only — their live reader
(`volumestatus`) is FU-235's next axis. **`machines/machines.yaml` selects `main`** since the
same change (`roots.main.inputs` in the policy): `locals.tf` yamldecodes it, and before this a PR
touching only the inventory got "no box-held surface touched" and was never planned — #1716
onboarded nx-01 that way. The inventory is pure data (no path or exec surface), so stage 1 does
not judge it; the apply loop now sees inventory-only master commits too (and refuses them to a
human apply like any `metal.tf` change outside the allowlist).

**Built 2026-09-13 (steps 1–3 in one PR, since nothing read the policy before its reader
existed):** `policy/mgmt/plan-input.yaml`, `scripts/mgmt-lib.sh` (App token, policy, stage 1,
plan summary), `scripts/mgmt-sentinel.sh`, `scripts/mgmt-apply.sh`, `scripts/mgmt-policy-test.sh`
(`devbox run mgmt-policy-test` — every deny rule fires on a fixture), the two units + `*:0/5`
timers. Deviations from the paragraphs above, each a residual on FU-237: the box posts for
EVERY open head (the in-cluster no-root poster is unbuilt, so the flip — PR#1617, operator-
applied — must wait until posting is reliable); both units run as root off the ONE env file
(the per-role user + env split); no doorbell yet (the timer is the level). **`main`'s state
lives here now** — `/var/lib/mgmt/state/main/terraform.tfstate`, local backend via `-state=`,
the jail's copy frozen as a backup — so the jail's `devbox run tf-plan|tf-apply` REFUSE and
point at **`devbox run mgmt-tf -- <plan|apply|…>`** (`scripts/mgmt-tf.sh`: ssh to the box, a
COMMITTED ref — `MGMT_REF=origin/<branch>` — under the loops' flock). A human apply of main
is therefore push-then-apply from now on; the working tree is not something the box can see.
**And it is plan-then-apply-that-plan** (2026-09-21, FU-248): every `plan` saves itself to
`/var/lib/mgmt/plan/<id>.bin` beside a human-readable `.txt` and a `.meta`, and prints the id;
`apply` takes that id and nothing else — no `-target`, no `-replace`, no bare `apply`. The
scoping lives inside the plan, so a scoped run is still one command pair, but the apply can no
longer be typed differently from the plan a human read. Tofu refuses a plan whose state serial
has moved, which is the "the world changed while you were reading" check that a human cannot
perform reliably; the incident that forced this is
[2026-09-16](incidents/2026-09-16-targeted-apply-replaced-three-vms.md).
`management-apply` is the second status context the App posts: on the master commit the box
applied (or refused) — the "deployed" signal a PR author reads after merge.

### When the box refuses — the human plan (FU-237 (e), 2026-09-16)

A stage-1 refusal posts `failure` on `management-sentinel`, a **required** context, and three
mechanisms interlock: branch protection blocks the merge (correct — the box has not judged the
change), `agents/review-reflex.sh` never dispatches a reviewer (its pick needs every present check
green), and `agents/reviewer-session.sh` stands aside at STEP 0 on a concluded failure. So a PR the
box legitimately declines to plan got **no merge and no review** — first hit on **#1718** (a second
`proxmox` provider instance for the nx-02 hypervisor; `tofu/providers.tf` is a `deny_paths` entry,
so the refusal was exactly right), and every `providers.tf` / `versions.tf` / `backend.tf` /
`*.tfvars` / `*.sh` / `provider "…" {}` change under a planned root is the same shape.

**The ruling (operator, 2026-09-16): the gate stays as it is — the timer never plans a refused
head, and there is no author-based relaxation** (a bot-vs-human split of the refusal was considered
and rejected as a second, messier gate). What was missing was the mechanism behind the policy's own
sentence, *"or gets a human plan in the jail"*: **`devbox run mgmt-human-plan -- <pr>`**
(`scripts/mgmt-human-plan.sh` → ssh → the box's `mgmt-sentinel.sh --human-plan <pr>`). It is the
same sentinel run, for ONE head, ordered by a human who has read the diff — the act `mgmt-tf plan`
already was, with a verdict at the end: stage 1 runs and is **reported, not enforced** (its hits
print in the terminal and in the verdict comment as "overridden"), stage 2 plans as usual, the plan
text is shown in the terminal for the human to read and stays on the box, and the status + comment
post under `homelab-sentinel` — marked **HUMAN PLAN**, overridden rules named — only after a y/N
confirmation on the exact head sha (`--yes` for a seat session; a push during the plan aborts the
post). A later push is a new head the box refuses again; re-read, re-run. The reviewer then reads a
green context whose description says `human plan: … — stage 1 overridden: deny_paths providers.tf`,
so the review knows what the box did not judge on its own.

The apply side has the same wedge and the same clearing act: `mgmt-apply.sh` refuses a master span
that hits stage 1 or leaves the apply allowlist and waits "for a new commit or a human apply" — but
its baseline (`applied-rev`) only ever advanced on its own applies, so every later master carried
the same hit forever. A **full** apply of `origin/master` now stamps the baseline and clears
`refused-rev` on success; a scoped one does not (finish with a full one). Since the plan-id change
that verdict is read from the PLAN's `.meta` — was it unscoped, was it taken from `origin/master` —
rather than from the apply's own flags, which a plan-file apply no longer has.

The probe that found the third gap (same day): a `provider "proxmox" {}` block placed in any other
`.tf` file passed stage 1 — the deny on `providers.tf` was a basename rule and no pattern matched the
block. `deny_patterns` now carries `^[[:space:]]*provider[[:space:]]+"` (the `provider =` meta-argument on
a resource stays allowed), with both cases in `mgmt-policy-test`.

### Talos config applies — the precondition, the toggle, the health gate (FU-097, 2026-09-22)

Until this change every install change needed a human `mgmt-tf apply`: the apply allowlist held
only the raw-k8s residue. The operator ruled that interim (FU-097, the capability ledger with
auto-apply toggles) and asked for a version-bump PR to roll out on merge with no human apply. So
`apply_addresses.main` now also holds `proxmox_download_file.*` (seed images; a VM re-pointing at
one is a `proxmox_virtual_environment_vm` change, which stays outside and refuses the plan whole)
and `talos_machine_configuration_apply.node[…]` / `.metal[…]`. Inside the allowlist is not enough
for a Talos config apply. Three more things stand between the plan and the apply:

1. **The precondition** (`mgmt_talos_gate` in `scripts/mgmt-lib.sh`, read from the plan's own
   `tofu show -json` through the `$out.talos` side channel). Every changed
   `talos_machine_configuration_apply` must be an in-place `update` (a create is an onboarding and
   a delete/replace is a node leaving: rule `talos-action`) whose planned **`apply_mode` is
   `no_reboot`** (rule `talos-apply-mode`; `(unset)` and `(unknown)` refuse too). `no_reboot` is
   what makes the §MB4 item 4 line mechanical: a config Talos can only take by rebooting fails
   the apply and lands in a window instead. The resources declare the attribute (`tofu/talos.tf`,
   `tofu/metal.tf`, #1874). The gate reads it from the PLAN, not from a belief about the source:
   a resource that loses it plans without `no_reboot` and refuses to a human apply. A failure refuses the whole root as before (status
   `failure`, the rule named, the addresses in the journal).
2. **The control-plane toggle**: `roots.main.apply_controlplane_config` in the policy, built
   `false`, **flipped `true` 2026-09-22** (operator: "let it do everything"). It is the first FU-097 toggle. A node whose declared `role` in the plan's
   `node_install_targets` output is `controlplane` stays a human apply while the toggle is off
   (rule `talos-controlplane`). A node the output does not name is refused (`talos-role-unknown`).
   No list of node names exists anywhere in the gate. The operator flips the toggle; the reason it
   starts off is the [2026-09-20](../.claude/skills/maintenance-window/SKILL.md) lesson, where a
   control-plane config apply took the cluster's API path down while every node read `Ready`.
3. **The post-apply health gate**, the unattended form of the seat's `/maintenance-window`. Before
   the apply the loop takes a baseline with `scripts/maintenance-window.sh snapshot`. That is the
   window's own probes: firing alert names, `sum(up)`, cilium's `10.96.0.1:443` apiserver backend
   on every agent, hard-failed pods and the node count. It is the same script with one set of
   verdicts, minus the CI probe (the box has no `gh`). An unreadable baseline is a probe failure:
   no apply, no stamp, and the next tick retries. After a successful apply the loop waits
   `MGMT_POSTCHECK_SETTLE` (180 s), then runs `compare` every 30 s until it gets a clean reading or
   900 s have passed. A clean reading gives `success … · post-check clean`. A regression still
   standing at the deadline sets **`management-apply` to `failure`** with the regressed probes
   named (`main: applied, POST-CHECK regressed: NEW firing alerts: …`). It also writes
   `/var/lib/mgmt/apply/post-check-failed`, which sets `mgmt_apply_post_check_failed` to 1 and
   fires **`MgmtApplyPostCheckFailed`** (`argocd/resources/mgmt-metrics/`, promtool-fixtured).
   **Nothing is reverted.** Under the rollout policy below the default is forward and a revert is
   a human commit. The sha is still stamped because the apply happened. The marker clears on the
   next clean post-check, or by hand (`rm` it) once the cluster is whole. A known overlap: while
   master's head carries that `failure`, the github-exporter reads it as a standing refusal, so
   `MgmtApplyResidueStanding` would also fire if master stayed on that commit for 24 h.

Fixtures: `mgmt-policy-test` feeds synthetic plans through the loop's own digest. It covers
`no_reboot` allowed, `auto`/unset/unknown refused, a CP with the toggle off refused and on
allowed, create/delete/replace refused, an unknown role refused, seed images allowed, a VM change
outside, and the post-check polling (clean, transient, still regressed at the deadline).
`maint-self-test` pins the `snapshot`/`compare` verbs.

### The capability ledger — what the box has been TESTED doing on its own (FU-097)

One row per surface: what the box has done unattended, when, and the evidence, plus its auto-apply
toggle. A surface enters with its first unattended success, never with a belief about what it could
do. Anchors (2026-09-13): the router, the control planes' substrate and Proxmox stay human; the
raw-k8s residue belongs to the box; `provisioning` is the canary. On a box-applied surface the
codeowner read becomes an **intent review** (does the plan + install-impact line do what the issue
asked, given what the fleet and the box already run?). That reviewer instruction is not written yet.

| Surface | Toggle | Tested on its own | Evidence |
|---|---|---|---|
| Main root, raw-k8s residue (the apply allowlist) | always on | since 2026-09-13 | every `management-apply` tick; §The test surface |
| Talos config apply, workers (`no_reboot`, health-gated) | on | 2026-09-22 | #1875; the 1.14.1 bump auto-applied 09:43:54Z, post-check clean |
| Talos config apply, control planes | `apply_controlplane_config` **on** (operator, 2026-09-22) | 2026-09-22 | the same apply, CP rows included |
| Talos install rollout, workers + CPs (`mgmt-reconcile`) | switch + CP toggle on | 2026-09-22 | #1879: 13/13 v1.14.1 09:43→13:17Z, canary per type, CPs last |
| Reconciler park/verify + window close (FU-276) | — | harness only | #1887 (123 cases); not yet exercised live (FU-276 archived 2026-09-22) |
| Rollout workload-health hold (FU-278) | — | harness + replay | #1891 (replay holds on forgejo before cp-01); first live rollout pending (FU-278 archived 2026-09-22) |
| Plan-on-PR sentinel, external roots read-only (github, cloudflare) | plan only, `apply: false` | 2026-09-13 | FU-237/FU-238; cloudflare plans with the read-only `cloudflare-mgmt-read` (verified on the box 2026-09-22) |
| Talos PKI (rotate-ca) | human | — (seat-run FROM the box, 2026-09-22) | FU-264; not a box capability |

## MB4. The end state — master is truth, the box reconciles (ADR-132)

**Tracked by:** FU-235 (the diff), FU-244 (flags out of git). The ArgoCD model
applied to what ArgoCD cannot reach: the tofu roots and the metal fleet. Layers, in build order.

1. **The diff.** `talos_machine_configuration_apply` records *delivery*; Talos honours install-time fields
   (schematic, `install.disk`, the EPHEMERAL `VolumeConfig`) only on the next install. So state is truthful,
   `plan` is clean, and the node runs the wrong image — nx-01 after #1717: `nodeLabels` took, the schematic and
   EPHEMERAL did not. The reconciler's diff is declared (`machines/machines.yaml`, the schematic ids tofu
   outputs) vs live (`talosctl get extensions` — the `schematic` extension's version — and `volumestatus`;
   labels and taints from the API), per node, one gauge each, on the belt (§MB2). It is the detector first,
   the sync's completion condition second.
2. **The pre-merge impact line.** The sentinel's `tofu plan` is blind to this class, so its verdict grows a
   line computed from the PR head's declaration against live: *"this head changes the install of nx-01
   (schematic, EPHEMERAL disk) → one reinstall window"*. That sentence is what the codeowner read refuses;
   a `machines.yaml` typo that would re-image the fleet is caught here, never by the WIP limit. **Built
   2026-09-21** — §MB3 "The install-impact line" (live comparison on the schematic/version axes; the
   layout axes wait on `volumestatus`).
3. **Sync policy in the declaration.** `reconcile: auto | manual` per node. Compute-tier nodes go `auto`
   first; control planes, hypervisors and the router stay `manual` until ADR-133's CPs and a CARP pair exist.
   A `manual` node still shows its diff as drift; the box does nothing. **Built 2026-09-21** — the field in
   `machines/machines.yaml` (absent = manual; `machines/generate.py` refuses `auto` on anything but a Talos
   worker), and **`wk-03` is the one `auto` node** (operator: "live on one node"). **2026-09-22 (FU-273):**
   every Talos node is `auto`, control planes included (ADR-133's three CPs exist; `generate.py` now refuses
   only non-Talos boxes), behind ONE switch — `reconcile_rollout.enabled` — **flipped on 2026-09-22** (operator); off, the
   reconciler owns only `reconcile_rollout.pilot` (wk-03). See
   [The rollout as built](#the-rollout-as-built-fu-273-2026-09-22).
4. **Runtime gates = `node-maintenance.sh`'s refusals plus a queue.** WIP 1: no second window before the
   first node is Ready, uncordoned and Longhorn healthy. Preflight refusals stay; above them a fleet floor (no
   window while Longhorn is degraded, or while a service's PodDisruptionBudget says no; Garage's says
   no while a zone is down or still resyncing, see [garage.md §Voluntary disruption](garage.md#voluntary-disruption--may-a-zone-go-now-2026-09-22)).
   One attempt per diff, then a parked failed
   state with an alert — a bad disk must never become a reinstall loop. Talos gives the runtime/install line
   mechanically: the box applies machine configs in `no_reboot` mode, so anything needing a reboot fails the
   apply and lands in a window instead — **set 2026-09-22** as `apply_mode = "no_reboot"` on both
   `talos_machine_configuration_apply` resources (`tofu/talos.tf`, `tofu/metal.tf`; the provider default
   `auto` reboots). Talos judges only the v1alpha1 document; other documents (VolumeConfig, HostnameConfig)
   are install-time and pass. The config is rendered against a pinned contract
   (`local.talos_config_contract`, `tofu/talos.tf`), not the install version, so a version bump moves
   installers and declared versions only. **Enforced by the apply loop since 2026-09-22:**
   it auto-applies a Talos config change only when the planned `apply_mode` is `no_reboot`, only on workers
   unless `apply_controlplane_config` is on, and brackets it with the health gate — §MB3 "Talos config applies".
5. **Operation state is the controller's.** The open window, the PXE flag, the step reached: held on the box,
   surfaced as status (a metric, a commit status, a meta-event), never a commit. A flag is set and cleared
   inside one sync — which is why `matchbox.tf` holds no per-node group and FU-244 moves today's transient
   flags out of the tracked tree (`flags.local.tf`, gitignored; a live flag shows as drift until unflagged).

**Layers 3–5 as built (2026-09-21): `scripts/mgmt-reconcile.sh`, the `mgmt-reconcile` unit + a
`*:4/10` timer** — hand-rolled, another box loop in the belt/apply style, because the FU-242 spike
ruled the controller substrate out ([`spikes/tofu-controller-on-the-box.md`](spikes/tofu-controller-on-the-box.md)).
Each tick, for the `auto` nodes only:

- **Declared** = `node_install_targets` from `main`'s *applied* state — the expression the upgrade verb
  passes as `--image`, so a merged declaration syncs once the apply path has applied it, never before.
  **Live** = `mgmt-probe.sh`'s own `check_nodes` (`NODE_TARGETS_JSON` = the auto nodes, `DRY_RUN=1`) —
  one diff, used as the trigger and again as the completion condition.
- **A version or schematic gap** → `node-maintenance.sh upgrade <node>`, run INSIDE the oneshot (the
  unit is the window). Everything the verb already refuses on stays the verb's: preflight, its WIP 1
  (another node cordoned or NotReady), the fleet floors (Longhorn degraded, a PodDisruptionBudget
  spanning several nodes already at 0, CNPG instances), the FU-033 gate, the post-install verify. The
  drain respects every PDB; one that does not complete is a refusal (exit 2, uncordoned, retried next
  tick), never a park. The verb knows no service: Garage's "may a zone go" lives in its own budget
  ([garage.md §Voluntary disruption](garage.md#voluntary-disruption--may-a-zone-go-now-2026-09-22)). The loop adds WIP 1 across windows it did
  not open — ANY live [declared window](glossary.md) (`agents/seat-window.sh`'s record) refuses the tick,
  the target's own included (the check runs before the verb opens its window, so a window there is a
  person's hands-on work), unless it is on the target and opened with `--admit-reconciler` — the
  attended sync, 2026-09-22 — and one sync per tick, the rest queued. The record is a sign on the
  door, not a lock (`open` is a blind merge patch; an undeclared drain is invisible to it): the hard
  serialization stays the verb's live WIP 1.
- **One attempt per declared target** (`version/schematic`). The verb's exit 2 is a refusal with nothing
  touched → `pending`, retried next tick. Exit 4 is a declared path no retry can pass — a cross-minor downgrade or a
  skipped minor — → `parked` at once: across a minor Talos backs out only by `talosctl rollback` or a
  reinstall — and `talosctl rollback` only briefly: **after a good boot Talos removes the upgrade
  fallback** (`removing fallback entry` in machined's log — nx-01, 2026-09-22), so it works only in the
  short window after the upgrade reboot; after that a cross-minor back-out is a reinstall. **Within a
  minor, reverting the declaration IS a rollback** (2026-09-22): the verb allows
  a patch downgrade, and Talos's older installer refuses on its own, before touching disk, if the
  running config holds a document it does not know. Any other failure, a zero exit that leaves the diff non-zero, or
  a sync the loop died in (found `syncing` by the next tick) → **`parked`** on that key, never retried.
  A new declared key clears any park. **What the diff reaching zero means depends on the park's
  recorded cause** (FU-276, #1884): a `diff-disagrees` or `impossible` park clears on diff zero — the
  diff is what failed. A **`verb-failed` or `interrupted`** park does not: the version is usually
  already right (nx-01 rebooted onto the target, the verb exited 1 on a hung cilium-agent, and the
  diff "cleared" the park two minutes later with the node off the pod network). It clears only when
  the read-only **`node-maintenance.sh verify <node>`** passes — Ready and uncordoned, Longhorn back,
  the budgets over its pods whole and none spanning nodes at 0, CNPG full, the declared version and
  schematic, and cilium-agent on *that* node Ready and holding the apiserver backend — re-asked every
  tick; until then the node stays `parked`, out of the in-sync set, and the rollout does not count it.
  An unreadable check is a fail. **The failed verb's window** (it deliberately exits 1 with its window
  open) **is closed by the reconciler at park time** — `node-maintenance.sh silence-close <node>`,
  which touches only the verb's own silences and its `--by node-maintenance.sh` declared record, never
  a seat's window — so the broken node's alerts reach a person, the park is the one record, and the
  next tick is not refused by a leftover window until `SILENCE_HOURS` runs out (option (i) of #1884;
  the same on an `interrupted` park). A node the verb left cordoned still stops the next sync through
  the verb's own live WIP 1. By hand: `rm /var/lib/mgmt/reconcile/state.json` once the node is whole.
- **Not reconciled, reported only:** labels/taints (tofu's apply path owns them — `MgmtNodeLiveStateDrift`),
  `ephemeral_disk` (reinstall-class — a human window), anything on a `manual` node. With the rollout
  switch off a declared `controlplane` is refused even if marked `auto`; with it on, a control plane
  syncs through `controlplane-upgrade.sh`, last. The loop never runs tofu.
- **State** = `/var/lib/mgmt/reconcile/state.json`; **status** = `mgmt_reconcile_node_state{node,state}`
  (idle | pending | syncing | parked) + `mgmt_reconcile_sync_started_timestamp_seconds{node}` through the
  textfile. Alerts (`argocd/resources/mgmt-metrics/`, promtool-fixtured): `MgmtReconcileParked` (5m),
  `MgmtReconcileSyncStuck` (a window past 3h; the unit's hard stop is 5h, after which the next tick parks),
  `MgmtReconcileLoopStale` (no evaluation for an hour with no sync open), `MgmtReconcileMetricsAbsent`.
  A long `pending` has no alert of its own — it is `MgmtNodeInstallDrift` / `TalosFleetVersionSplit` at 24h.
- The state machine is fixture-tested against a fake verb: `devbox run mgmt-reconcile-test` (also run by
  `mgmt-policy-test`, which CI runs on every `scripts/mgmt-*` change). The unit is `restartIfChanged =
  false`: a `mgmt-pull` activation must never kill a window mid-install.

Not built here: layer 5's PXE flags (FU-244 — the verb in use is an in-place upgrade, which needs none) and
any sync of the reinstall class.
6. **BMC duty, split by caller on one inventory.** The same primitives (power, boot-device override, SOL,
   virtual media where Redfish exists) serve two callers: the reconciler for lifecycle on `reconcile: auto`
   nodes (Tinkerbell's Rufio is the prior art — a `Machine` per BMC, power/boot Tasks over bmclib), and the
   human for hypervisor reinstalls and recovery (ISO over virtual media, BIOS over SOL) — a runbook, never a
   loop. `machines.yaml` gains `bmc:` beside `plug:`; `node-maintenance.sh` is the first caller.
7. **Two networks.** The box's second NIC is the management-network leg; the BMCs (today the Nutanix twin's
   two IPMI ports sit on the LAN) move behind it, so nothing but the box can speak to BMC firmware. Static
   addressing, no DHCP, a hosts file. The k3s API (if the spike says yes) binds to loopback; pods reach the
   BMC network through the node's routing.

**The substrate is the hand-rolled box loops** — the FU-242 spike (2026-09-21) said NO to tofu-controller; see its §Verdict. The candidate it tested: a single-node k3s from the NixOS module —
no Docker daemon, sqlite, `--disable` for traefik/servicelb/metrics-server, API on loopback — with Flux's
source controller + tofu-controller as the reconcile engine, the whole thing a **Nix closure**: images as
`dockerTools.pullImage` digests, manifests as files (`services.k3s.images` / `manifests` — verify in the
26.05 pin), so `mgmt-confirm`'s gate-and-reboot covers the cluster and `nixos-anywhere` recreates it. Prior
art and why none of it fits as-is: Flux tofu-controller and Burrito (the model, but in-cluster state + creds),
Atlantis (the sentinel by another name, pre-merge apply), Sidero Omni / CAPI+CAPT / Tinkerbell / Metal3 (the
metal half). Spike: [`spikes/tofu-controller-on-the-box.md`](spikes/tofu-controller-on-the-box.md).

**Sequence (operator, 2026-09-16 — box first, CPs second, router last):** the diff belt (FU-235) → the spike
(FU-242) → the impact line → box-run maintenance verbs proven by a human-ordered run → `reconcile: auto` on
the compute tier with WIP 1 → then ADR-133's three control planes (FU-243) → the CARP pair. **Where it stands (2026-09-22):** everything through `reconcile: auto` is built, and the fleet rollout
(CPs included) has been switched ON since 2026-09-22, when it rolled 13/13 nodes to v1.14.1 (#1879). The three CPs are
live (FU-243). The CARP pair is what is left.

### The rollout policy — forward by default, less than a day (FU-273, operator 2026-09-22)

The reconciler syncs one node per tick with WIP 1 and nothing else. That is enough for one `auto` node
and not for a fleet: a symptom two hours after the last node is done meets "what changed in the last
24 hours?", which always names the upgrade, and with every node on the new version the claim cannot
be tested. The rules, ruled before anything below is built:

- **Default forward.** A new alert on its own neither halts nor reverts a rollout, and the responder
  never reverts. Rolling back on the first alert means never moving forward in practice: the symptom may be a fluke or
  a stack's own change, and a single stack's CI that a script update fixes is not a platform verdict.
  **But a broken workload PAUSES it, never reverts it** (FU-278, operator 2026-09-22): a PLATFORM
  workload (any namespace that is not a stack's app namespace) unhealthy since the rollout started, or
  an important stack workload (≥ 2 replicas/instances or a PodDisruptionBudget) unhealthy on the SAME
  revision it had then, holds the next window until it is healthy again or a human acks. A stack
  workload on a new revision, or a stack singleton, is the stack's own business — logged, never a
  hold. The 2026-09-22 rollout is why: wk-04's window moved Forgejo onto hp-01, where it crash-looped
  (the FU-277 DNS trap), and the rollout took cp-01, cp-02 and wk-metal-02 down after it — between
  windows it read node Ready, cilium and multi-node budgets, which a single-replica Deployment never
  moves. [The hold as built](#the-rollout-as-built-fu-273-2026-09-22).
- **Revert is a human commit**, backed by a **differential** signal: worse on upgraded nodes than on
  not-yet-upgraded ones, starting after each node's own upgrade, seen across stacks. Only that
  evidence halts the rollout automatically. Within a minor the reverted declaration is then a
  rollback the reconciler runs (`node-maintenance.sh upgrade` allows a patch downgrade within a minor since #1867, and refuses a cross-minor one with exit 4, which the reconciler parks); across a minor it is `talosctl
  rollback` — only while the upgrade fallback exists, i.e. shortly after the upgrade reboot (Talos
  removes it after a good boot) — or a reinstall.
- **Less than a day, end to end.** Drift from git is a tax: with master at 1.14.2 and the fleet split,
  nobody can say which version a node runs without looking. `TalosFleetVersionSplit` /
  `MgmtNodeInstallDrift` at 24 h are the rollout's deadline, not a threshold to tune.
- **Soak = evidence, in hours, never wall time.** A canary stage ends when each canary TYPE has been
  exercised on the new version, with a timeout: nx-01 after one ride + one ARC job, wk-03 after ARC
  jobs, a storage node after a Longhorn replica rebuilt onto it with its Garage zone healthy, a
  control plane after its etcd member is healthy and its apiserver serves. Time passing on an idle
  node proves nothing.
- **The rollout creates the pressure.** Workloads do not move to a new node on their own (a CNPG
  instance stays where it is until evicted). So a rollout taints every not-yet-upgraded node
  `PreferNoSchedule` (e.g. `homelab.io/talos-behind`) and clears the taint as each one upgrades. Every drain then lands its
  pods on upgraded nodes, and the new version carries real work within hours. That same load is what the
  differential compares. A preference, so it never blocks scheduling when the upgraded nodes are full.
- **One rollout per substrate** (Talos), not a soak matrix per component. Per-component soaks end in
  every node running a unique combination — the 500-feature-flags failure.
- **Order:** the canaries first, then the least dangerous pool first — ephemeral, regular, the Garage/Longhorn zones, the
  control planes — as `node-maintenance.sh order` already ranks them.

**The exercise predicate — built:** `scripts/mgmt-rollout-evidence.sh <node> <since>` answers
"has this node carried its own kind of work on its current install since then?" — exit 0 yes, 1
not yet, 2 cannot tell (any read failed; the caller asks again, and owns the timeout). It types the
node from live facts, never a list, and every type that applies must hold:

| Type | Is one when | Evidence since `<since>` |
|---|---|---|
| control plane | label `node-role.kubernetes.io/control-plane` | etcd service healthy, its member a voter with no errors; `kube-apiserver-<node>` Ready and `/readyz` ok on the node's own IP |
| ARC | label `homelab.io/ephemeral=true` **and** ≥ 14 runner pods there in the 7 d before | ≥ 1 job concluded `success` on a runner pod placed there |
| ride | ≥ 14 worker rides (`agent-<project>-…`, controller-less) there in the 7 d before | ≥ 1 ride created since then reached `Succeeded` there |
| Longhorn | a replica CR placed there | ≥ 1 replica running on a `healthy` volume, either rebuilt since then (`healthyAt`) or reused across the reboot under an instance-manager pod of the current boot (started ≥ min(since, the node's Ready transition): Longhorn keeps a reused replica's old `healthyAt`) |
| Garage | a Garage zone named after the node | the zone connected in every peer's view for 10 min |
| worker | none of the above | ≥ 1 non-DaemonSet pod scheduled since then that is Ready or Succeeded |

A label alone never makes a type: the history threshold is what keeps a node that sees a ride every
few days from holding a stage for days. The ARC job outcome reads
`github_ci_job_completed_timestamp{runner_name,conclusion}` from the GitHub exporter, joined to the
runner pod's node. The runner pod is deleted seconds after its job, and kube-state-metrics saw 6 of
~100 such terminations in 6 h. A stale exporter, or one without that series, reads as "cannot tell",
never as "no job". Fixtures: `devbox run mgmt-rollout-evidence-test`.

**The differential — built:** `MgmtRolloutDifferential` (`argocd/resources/mgmt-metrics/`, group
`mgmt-rollout`) is the one automatic halt. PromQL cannot order version strings, and a rollback
drill moves nodes down. So **upgraded** means "this node's current Talos version first appeared in
the last 2 d" (`kube_node_info{os_image}`). **Behind** means "on a version no node moved to in that
horizon". A node that ran the new version before the horizon is on neither side. The alert compares
two per-node signals, each averaged per node and zero-filled:

- **container-restarts** — containers with a restart in the last hour
- **unready-pods** — scheduled, unfinished pods not Ready, averaged over 30 min

An upgraded node is compared only 75 min after both its version change and its last boot, which
excludes the upgrade's own DaemonSet restarts. It fires when all of these hold for 30 min:

- the upgraded mean is ≥ 3× the behind mean + 1
- the upgraded side has ≥ 3 restarting containers or ≥ 2 unready pods, in ≥ 2 namespaces
- ≥ 2 nodes are still behind

Replayed against 2026-09-21 06:00Z → 2026-09-22 08:00Z (the 1.13.2 → 1.13.10 roll, the wk-03 1.14
canary and its rollback drill), it stayed silent throughout. Without the 75-min settle, the same
replay reads 2.3–3.0 restarts per upgraded node across 3–4 namespaces during the 09-21 roll,
against about 0 behind. That is the reboot transient, and the settle window is what keeps it out of
the comparison. The promtool fixture fails if any single guard is loosened.

**The stages, the repel taint and the halt read — built** (the orchestration, below). The first
two attended bumps (wk-03 1.14.0 → 1.14.1 and the rollback drill) ran before any of it existed;
the switch is flipped after them.

### The rollout as built (FU-273, 2026-09-22)

`scripts/mgmt-reconcile.sh`, same unit and timer, same one-sync-per-tick oneshot — every guarantee
above holds unchanged (WIP 1 incl. declared windows and `--admit-reconciler`, one attempt per
declared key → park, the verb's exit 2 = retried refusal / 4 = parked impossible path,
`restartIfChanged = false`, the metrics). What the switch adds is **which node a tick may sync**:

- **The switch** is `reconcile_rollout.enabled` at the top of `machines/machines.yaml` — a commit,
  so flipping it is reviewable and the box picks it up on its next pull. **On since 2026-09-22**
  (operator; built off, #1876). **Off:** the reconciler owns only `reconcile_rollout.pilot` (wk-03), first candidate in inventory
  order, control planes refused — the pre-rollout behaviour, pinned by running the whole original
  test suite a second time with the switch explicitly off. **To flip:** set `enabled: true` in a
  one-line PR; nothing moves until a declared bump is applied. Flipping it off mid-rollout lifts the
  taints and retires the record; nodes already moved stay where they are.
- **Target.** A rollout moves ONE declared version: the newest declared version among the `auto`
  nodes with a diff. Its members are the nodes declared at it — a node that already runs it (the
  tofu canary override, `var.nodes.*.talos_version`) is a member that is already done. A node
  declared at another version waits, `pending`, for this rollout to end: one rollout at a time.
- **Stage `canary`.** One canary per node **type** — `class/role/schematic/storage`, storage =
  `order`'s GARAGE=yes or LH>0 (`ORDER_FORMAT=tsv`, the ranking's own columns) — the least risky of
  each, synced one per tick in rank order. A type whose member already runs the target uses that
  node and skips the sync. Control planes are never canaries: they go last, and
  `controlplane-upgrade.sh`'s post-check (etcd member healthy, apiserver serving) IS their
  predicate. Then the stage waits until `mgmt-rollout-evidence.sh <node> <synced-at>` exits 0 for
  every canary (1 and 2 = not yet; a missing script = not yet, logged once), bounded by
  `RECONCILE_CANARY_TIMEOUT` (4 h). **On timeout it advances anyway** — default forward — with
  `mgmt_reconcile_rollout_canary_timed_out` = 1 and **`MgmtRolloutCanaryTimedOut`**.
- **Stage `fleet`.** The rest in `node-maintenance.sh order`'s ranking, workers first; a control
  plane only when no worker of the rollout is left to sync, one at a time, through
  `controlplane-upgrade.sh <node>` (which now keeps the same 2/4/1 exit contract: its gates refuse
  with 2, the shared verb's 4 passes through, a failure after the install is 1). A parked node does
  not block the stages — the verb's own WIP 1 does, live.
- **`halted`.** Before any rollout sync the loop reads `ALERTS{alertname="MgmtRolloutDifferential"}`;
  firing — or unreadable (an unreadable gate is a no; **`MgmtRolloutHaltUnreadable`** after 1 h) —
  stops new syncs and lifts the pressure (no more work pushed onto nodes that look worse). It
  resumes where it was when the alert clears. It never reverts anything. The same stage carries the
  workload-health hold (next bullet), read after the differential; the differential's reason wins
  when both apply.
- **The workload-health hold (FU-278).** At rollout start (before the first canary) the loop
  snapshots every workload into `rollout.json` (`.wh.baseline`) through the read-only
  `node-maintenance.sh workload-health` — one JSON line per workload keyed by its TOP OWNER (a pod's
  ReplicaSet → its Deployment; StatefulSet; DaemonSet; a CNPG pod → its `Cluster.postgresql.cnpg.io`;
  other owner kinds as themselves; bare pods — agent rides —, Job/CronJob/Workflow pods, ARC runner
  pods and finished pods excluded), with a **revision** (Deployment: the current ReplicaSet's
  pod-template-hash; StatefulSet: `updateRevision`; DaemonSet/other: the pods' revision hash; CNPG:
  the pods' image), a **class** and a **healthy** verdict. Unhealthy = any counted pod with a
  container or init container in CrashLoopBackOff / Error / ImagePullBackOff / ErrImagePull /
  CreateContainerConfigError, or not Ready for more than `WH_NOT_READY_GRACE` (5 min, from the Ready
  condition's `lastTransitionTime`). **Classes** come from the live AgentStack claims: a stack's app
  namespaces are its claim's repo names (a fixer repo's namespace IS its repo name —
  `argocd/resources/agentstack/xrd.yaml`), the `platform` claim's own repos excluded; everything else
  — `<stack>-agents`, `agent-coordinator`, `forgejo`, `garage`, … — is PLATFORM; a stack workload is
  STACK-IMPORTANT with ≥ 2 replicas/instances or a PDB over its pods, else STACK-SINGLETON. Claims
  unreadable = the whole read unreadable. **The rule**, evaluated right after each window returns and
  again before each next one: a workload unhealthy now that was healthy (or absent) in the snapshot —
  PLATFORM → hold whatever its revision; STACK-IMPORTANT on the snapshot's revision → hold; a new
  revision or a STACK-SINGLETON → logged once per revision. Already unhealthy at the snapshot → never
  holds. An unreadable read, or no baseline yet → hold (`workload-health-unreadable`). The hold is the
  differential's `halted` stage with reason `workload-health`: no new sync, the pressure lifted,
  nothing reverted, each workload named with revision and since-when (the journal, the nodes'
  `pending` reasons, `mgmt_reconcile_rollout_workload_held{workload,class,revision}`). It releases
  when the held workloads are healthy again, or on a **human ack**: `touch
  /var/lib/mgmt/reconcile/workload-health.ack` on the box — every workload held at that moment stops
  holding for the rest of this rollout (`.wh.acked`), the file is consumed, and a workload that goes
  bad later still holds. Not on a revert rollout (the differential's carve-out: the revert is the
  fix). **`MgmtRolloutHeldOnWorkloadHealth`** after 30 min. **Replayed** against 2026-09-22
  (fixtures reconstructed from kube-state-metrics, `scripts/fixtures/workload-health-2026-09-22/`):
  with the 09:45Z baseline it holds at 12:54:45Z — the read before cp-01's sync — on exactly
  `forgejo/Deployment/forgejo@68f79d44d9` (init `configure-gitea` CrashLoopBackOff), and at 10:30:45Z,
  before wk-metal-04's window, on `garage/StatefulSet/garage` (garage-2 not Ready 23 min after its
  zone's window — the backlog ADR-140's budget now answers); every other pre-window read of that day
  is clean.
- **Revert.** A declared target OLDER than the last rollout's is a human revert commit: a `revert`
  rollout with no canary stage, not halted by the differential (that is what asked for it), the
  nodes the last rollout moved first. Within a minor the verb allows it; across one it is exit 4 →
  parked.
- **Supersede.** A NEWER target mid-rollout (a patch merged): the not-yet nodes switch to it and
  skip the intermediate version; the nodes already on the old target wait for the NEXT rollout
  (which, being the same target, starts at `fleet`); the stage restarts at `canary`, because the new
  version has proved nothing yet. Recorded in `superseded[]`. The fleet may briefly hold three
  versions (not-yet, old target, new target) — the price of never re-syncing a node twice in one
  rollout.
- **Pressure.** Every member not on the target carries
  `homelab.io/talos-behind=<target>:PreferNoSchedule`; removed from a node the moment its sync
  completes, from all when the rollout ends, halts, or the switch goes off. Idempotent, and no other
  taint key is ever read or written. The belt's taint axis compares only keys tofu declares, so the
  taint is not drift.
- **State + status.** `/var/lib/mgmt/reconcile/rollout.json` beside `state.json` (its own file:
  `rm state.json` to clear a park must not restart a rollout) — target, kind, stage,
  `started_at`/`stage_since`, canaries by type, evidence times, per-node `synced_at`,
  `superseded[]`. Series: `mgmt_reconcile_rollout_stage{target,kind,stage}`,
  `…_started_timestamp_seconds`, `…_canary_wait_started_timestamp_seconds`,
  `…_canary_exercised{node,type}`, `…_canary_timed_out`, `…_halted{reason}` (`differential`,
  `unreadable`, `workload-health`, `workload-health-unreadable`), `…_workload_held{workload,class,revision}`,
  `…_node_synced_timestamp_seconds{node,target}` — emitted only while the switch is on. The rollout's
  alerts live in `argocd/resources/mgmt-metrics/reconcile-rollout.yaml`; the 24 h deadline is NOT
  re-alerted there — `TalosFleetVersionSplit` / `MgmtNodeInstallDrift` already are it.
- **Unit.** Unchanged: one sync per tick keeps the unit a window, and `TimeoutStartSec = 5h` already
  covers the CP verb (its extra snapshot + cilium roll are minutes on top of the shared verb).
- **Tests:** `devbox run mgmt-reconcile-test` — fake verb, CP verb, ranking, evidence, Prometheus
  and kubectl: canary-per-type selection, the override canary, evidence gating and timeout-forward,
  CPs last via the CP verb, halt + resume (and unreadable), taints on/off without touching other
  keys, supersede, revert, one-rollout-at-a-time, the switch off mid-rollout; the workload-health
  hold (snapshot, each class, the revision split, absent/already-unhealthy, unreadable read and
  baseline, the ack, the after-window read, revert exempt, the 2026-09-22 replay) and the
  `workload-health` read itself against synthetic dumps.

## Rollback — three layers

1. **It boots but the closure is bad** → `mgmt-confirm.service`, started by the pull (never by a
   timer), runs `MODE=gate`: sshd still listening on 22, authorized keys still parse, the gateway
   answers, systemd not degraded, the store writable. None of those may skip. On failure its only
   action is **`systemctl reboot`**, which lands on the untouched boot default because
   `nixos-rebuild test` never promoted anything.
   ⚠ Two rules from the 2026-09-12 review, both load-bearing: **never `--rollback`** (it demotes
   the generation *before* the good one, and on a first update it exits non-zero — under systemd's
   `set -e` script wrapper that would skip the reboot and leave the broken closure live); and the
   gate must test only **box-local** properties, because a gate that fails on a fleet fault would
   power-cycle this box precisely when the cluster is having a bad day. Fleet checks live in the
   **belt** below, which reports and never acts.
2. **It never boots** (kernel/initrd class) → ⛔ **THERE IS NO AUTOMATIC RECOVERY, in either
   bootloader branch.** Settled 2026-09-12 rather than assumed: `bootCounting` **does not exist**
   in this pin (`grep -rn bootCounting` over nixos-26.05 rev `21a67dc` returns nothing), and it is
   a systemd-boot feature regardless, while the config ships `bootMode = "bios"` pending a firmware
   read. So a kernel or initrd that activates cleanly and then fails to boot needs **hands** — with
   no BMC and no PiKVM nobody can pick a previous entry remotely. Accepted limit of the pilot; it
   is also the strongest argument for the permanent box being UEFI with vPro. Do kernel-class
   bumps while someone can reach the power button.
3. **A tool version is wrong for the fleet** → `git revert` the `devbox.lock` commit; the next pull
   returns the old version.

⚠ **The one asymmetry: tofu state format.** A newer `tofu` can write a state version an older
binary refuses to read — **general OpenTofu behaviour, NOT verified against our pin and recorded
nowhere in this repo**, so treat it as the conservative assumption it is. What the corpus does say
is the cost if it bites: a root that loses its state "does not fail loudly — it plans to **create**
everything it already owns" ([`tofu-state.md`](tofu-state.md)). So a toolchain bump's canary is `plan`
only — **never let a first `apply` be the test of a new tofu** — and the timestamped state backups
are the belt. This is also why `main`'s out-of-cone copy belongs here.

## Credentials

**The closure holds no secrets, structurally:** the repo is public and `/nix/store` is
world-readable, so anything the flake can see, every process can. That single fact shapes all of
this section.

- **SSH authorized keys are declarative** (`nixos/hosts/mgmt/keys/*.pub`, read by the flake), so
  rotation is a diff: add the new key, rebuild, verify, remove the old — two commits, never a
  lockout. Only the PUBLIC half is there — the credential's existence and scope stay config, the
  private half is data: [`secrets.md`](secrets.md) §Minting doctrine (precedent: `tofu/ci-runner.tf`
  commits a pubkey the same way). ⚠ Track them: a flake sees only tracked files. `jail.pub` is the
  pve-ssh-seed key the jail already uses for Proxmox; the operator's laptop key is the second.
- **Everything else is a FILE outside the store, placed by ONE script** —
  `scripts/mgmt-provision-secrets.sh`. It stages a tree from the Tier-0 wallet
  (`~/.claude/homelab-mgmt/extra-files/`: the sshd host key at `etc/ssh/`, the belt's credentials
  as `var/lib/mgmt/env`, plus `talosconfig`/`kubeconfig` beside it, all root-only `0600`) and that
  tree is what `nixos-anywhere --extra-files` ships at **install**; `--push` rsyncs the same tree
  onto the running box for a **rotation**. Units read the env file via `EnvironmentFile=` at each
  start, so a rotation restarts nothing. This borrows the appliance tier's FILE shape (read once at
  provision, plaintext, mode 600) with the **wallet** as the store — the snore-recorder appliance
  reads from Infisical, which this box cannot (in-cluster, i.e. the dependency it exists to escape),
  so it is a new pattern, not an inherited one. **Not** `sops-nix`/agenix: the lab rejected them for
  giving no real at-rest protection when the key shares the disk (`secrets.md` §Why no SOPS).
- **The host key is wallet data, not config** (`mgmt-ssh-host`, minted once by `keepass-init.sh`):
  `services.openssh.hostKeys` only names the path — sshd *generates* a key when the path is empty,
  and a reinstall that regenerates it silently breaks the jail's `known_hosts`. So `--extra-files`
  is not optional. The push path pins the box's host key from that same wallet entry instead of
  trusting on first use.
- **`/var/lib/mgmt/state/` is DATA, and a reinstall wipes it.** The main root's state lives
  nowhere else — so a reinstall restores it from a snapshot before anything plans:
  [`tofu-state.md`](tofu-state.md) §Snapshots (the mechanism, both copies, the restore recipe).
- **A version bump never touches a secret.** `nixos-rebuild test|boot` rebuilds the closure from
  git and leaves `/etc/ssh`, `/var/lib/mgmt` and `/root` alone; only a *reinstall* re-provisions
  (`--extra-files`), and only a *rotation* re-runs the script. Authorized keys are the one credential
  that rotates through git.
- **Which credentials, and whose:** the env file carries exactly what the belt's cone-clean checks
  need (the Garage state key + the state passphrase, the Cloudflare token — the read-only
  `homelab-mgmt-read` since FU-238's cloudflare leg, the write key before — and the Matchbox-Proxmox token,
  the OPNsense API pair) **and, since 2026-09-13, the main root's `TF_VAR_*` set** (the
  `keepass-env.sh` list, one table line each) + `main.tfvars` + the runner App key
  `ci-runner.tf` reads by path + the `homelab-sentinel` App key, plus the file-shaped ones the `provisioning` root reads by path — the
  Matchbox gRPC client files and the **Proxmox SSH seed key** (found one plan at a time on the
  box's first day, 2026-09-13) — and the root's gitignored `terraform.tfvars`. The main root's
  `TF_VAR_*` set moves only when FU-097's table says the box may touch `main`. ⚠ Today's entries are the **jail's**, a phase-A shortcut against the
  doctrine's "one consumer, one token, at its tier"; the script's table is one line per credential
  so each swaps for a box-scoped entry as it is minted (FU-012's next). The state passphrase is
  shared by nature — it is the state's key, not a consumer's. The **sentinel's** own env file
  (§MB3's per-role split) is still a residual: today one env file serves the belt, the sentinel
  and the apply loop.
- ⚠ The box is a **consumer** of Tier-0, never its home: the wallet stays with the operator, and the
  scripts that read it (`keepass-env.sh`, `tofu-state-env.sh`, `opnsense-playbook.sh`) all yield to
  a pre-set environment, which is how the same probe runs in the jail (wallet) and on the box (env
  file). Proven 2026-09-13: the belt passes 4/4 **under its unit on the installed box**, the env
  file alone; the gate 5/5 under `mgmt-confirm`, which promoted generation 2.

## Open, and deliberately not built yet

| Question | Why it waits |
|---|---|
| Which surfaces may it reconcile? | Answered per surface by evidence, not a ruling table: §The capability ledger (FU-097). The intent-review reviewer instruction is still unwritten |
| **The pilot's firmware — UEFI or legacy BIOS?** | **Read 2026-09-13: UEFI-capable, but a CSM firmware whose BIOS-setup priority is authoritative** — a UEFI install landed, yet the firmware re-derives the NVRAM order from the setup list on every boot (legacy entries first), so an `efibootmgr -o` was overwritten and the box booted the stick. So `bootMode = "bios"`: GRUB in the BIOS-boot partition is what the setup's "disk" entry boots, with no NVRAM dependency. Setup order for the pilot: disk first, USB and PXE removed. Automatic boot-failure rollback stays unavailable (it was in this pin regardless) |
| `bootCounting` in the pin | only if that read says UEFI — then one `nix eval` settles it |
| The second alert path | the spike asks for two independent paths out; today there is one, and it is in-cluster |
| The management network | recovery path 2, after phase C — the topology work, not the box work |
| A CI gate on `nixos/` | the repo's CI is a list of `devbox run` steps; a `nix flake check` step wants the nix cache warm on the runner first |

## Prior art worth knowing before trusting NixOS here

This lab's one lived NixOS-on-hardware attempt was **abandoned**: snore-recorder pivoted from
NixOS-on-Pi to Raspberry Pi OS Lite + systemd (2026-06-25, that repo's `CLEANUP.md`) after a
runtime USB-boot problem on ARM. It does not transfer to an x86 box with a local disk, but it does
mean nobody here has run NixOS in anger — which is exactly what the pilot is for.

And the snore deployment shape is NOT the model for updating this box: its ansible Job runs
**inside the cluster**, and pointing that at the recovery root would put the cluster in the root's
dependency cone. It is also deployment, not OS upgrade.
