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
With a single OPNsense and a single control plane, anything that touches the router, the CPs or
the Proxmox host is instant whole-cluster downtime — so phases B and C run on this residue, where a
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
| **the node diff** (`check_nodes`, 2026-09-21): DECLARED (`tofu output node_install_targets` — the same expression the upgrade verb passes as `--image`) vs LIVE (`talosctl version`, the `schematic` extension), per node, three axes: reachable / version / schematic | that the fleet runs what git says. This is §MB4 layer 1's first half — the diff install-time drift needs, because `talos_machine_configuration_apply` records DELIVERY and Talos honours install-time fields only on the next install, so state is truthful, `plan` is clean, and the node still runs the wrong image (nx-01 after #1717). ⚠ It REPORTS, never fails the probe: a version gap is the normal state of a rollout in progress, and a belt that reds the box on every window teaches everyone to ignore it. Publishes `mgmt_node_drift{node,axis}` (0 = checked and matched, which "no series" cannot say); the "too long" judgement belongs to an alert with a `for:` |
| `ansible --check` on an OPNsense play | the collection + the pinned httpx interpreter + the API credential still work, and the recap's `changed=` count is read for drift — class 9 in [`dependency-upgrades.md`](dependency-upgrades.md) is the sharpest unreconciled-surface gap. ⚠ **A partial belt, by construction:** `ansible-playbook --check` exits 0 even when tasks report `changed` (only a task *error* is non-zero), so the exit code alone proves plumbing, not currency — hence the recap parse; and `oxlorg.opnsense.raw` tasks with `action: post` return `changed=False` in check mode by design, so **advanced-settings drift stays invisible** no matter how the recap is parsed |
| each credential it holds, read once | a rotation did not lock the box out |

The metric *shape* copies the Garage write probe: the verdict **and** a `*_last_run_timestamp`, so
a staleness alert catches "the box is wedged" and not only "the box says no". This is FU-102's
prober contract applied to its first non-stack consumer — the spike's line is that *the prober is
the human*.

The node diff's own alert is the one thing the transport hole below actually blocks, so it has a
second, weaker detector that needs no transport: `kube_node_info` is already scraped and carries
`os_image`, so the CLUSTER can see *that the fleet is split across Talos versions* even though it
cannot see which version is declared. That is `TalosFleetVersionSplit`
(`argocd/resources/talos-substrate/`, `for: 24h` to let a rollout run). The schematic and
reachability axes have no such stand-in — they wait on the transport.

⚠ **The transport is UNBUILT, and it is a decision rather than a detail.** Pushgateway is
"cluster-internal only … never BGP-advertised — internal exhaust plumbing"
(`argocd/resources/pushgateway/service.yaml`), and the write probe reaches it from an in-cluster
CronJob. This box is out-of-cluster by construction, so publishing needs either a deliberate
exposure (a VIP for internal exhaust plumbing — an ip-plan/ADR-088 call, not a config line) or a
different sink. `scripts/mgmt-probe.sh` therefore treats a failed push as reporting-only and never
lets it change the verdict; with `PUSHGATEWAY` unset it does not publish at all.

⚠ **Known hole:** Prometheus is in-cluster, so a cluster-down event blinds the detector. Acceptable
for freshness-class breakage and irrelevant to the local deadman (which needs no alerting to
work), but the spike's "alerts leave by two independent paths" has no second path yet.

### A standing refusal is a THIRD verdict shape, and nothing detects it

*Tracked by: FU-252.*

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

## MB4. The end state — master is truth, the box reconciles (ADR-132)

**Tracked by:** FU-235 (the diff), FU-242 (the substrate spike), FU-244 (flags out of git). The ArgoCD model
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
   a `machines.yaml` typo that would re-image the fleet is caught here, never by the WIP limit.
3. **Sync policy in the declaration.** `reconcile: auto | manual` per node. Compute-tier nodes go `auto`
   first; control planes, hypervisors and the router stay `manual` until ADR-133's CPs and a CARP pair exist.
   A `manual` node still shows its diff as drift; the box does nothing.
4. **Runtime gates = `node-maintenance.sh`'s refusals plus a queue.** WIP 1: no second window before the
   first node is Ready, uncordoned and Longhorn healthy. Preflight refusals stay; above them a fleet floor (no
   window while Longhorn is degraded or a Garage zone is down). One attempt per diff, then a parked failed
   state with an alert — a bad disk must never become a reinstall loop. Talos gives the runtime/install line
   mechanically: the box applies machine configs in `no_reboot` mode, so anything needing a reboot fails the
   apply and lands in a window instead.
5. **Operation state is the controller's.** The open window, the PXE flag, the step reached: held on the box,
   surfaced as status (a metric, a commit status, a meta-event), never a commit. A flag is set and cleared
   inside one sync — which is why `matchbox.tf` holds no per-node group and FU-244 moves today's transient
   flags out of the tracked tree (`flags.local.tf`, gitignored; a live flag shows as drift until unflagged).
6. **BMC duty, split by caller on one inventory.** The same primitives (power, boot-device override, SOL,
   virtual media where Redfish exists) serve two callers: the reconciler for lifecycle on `reconcile: auto`
   nodes (Tinkerbell's Rufio is the prior art — a `Machine` per BMC, power/boot Tasks over bmclib), and the
   human for hypervisor reinstalls and recovery (ISO over virtual media, BIOS over SOL) — a runbook, never a
   loop. `machines.yaml` gains `bmc:` beside `plug:`; `node-maintenance.sh` is the first caller.
7. **Two networks.** The box's second NIC is the management-network leg; the BMCs (today the Nutanix twin's
   two IPMI ports sit on the LAN) move behind it, so nothing but the box can speak to BMC firmware. Static
   addressing, no DHCP, a hosts file. The k3s API (if the spike says yes) binds to loopback; pods reach the
   BMC network through the node's routing.

**The substrate is undecided until FU-242 reports.** The candidate: a single-node k3s from the NixOS module —
no Docker daemon, sqlite, `--disable` for traefik/servicelb/metrics-server, API on loopback — with Flux's
source controller + tofu-controller as the reconcile engine, the whole thing a **Nix closure**: images as
`dockerTools.pullImage` digests, manifests as files (`services.k3s.images` / `manifests` — verify in the
26.05 pin), so `mgmt-confirm`'s gate-and-reboot covers the cluster and `nixos-anywhere` recreates it. Prior
art and why none of it fits as-is: Flux tofu-controller and Burrito (the model, but in-cluster state + creds),
Atlantis (the sentinel by another name, pre-merge apply), Sidero Omni / CAPI+CAPT / Tinkerbell / Metal3 (the
metal half). Spike: [`spikes/tofu-controller-on-the-box.md`](spikes/tofu-controller-on-the-box.md).

**Sequence (operator, 2026-09-16 — box first, CPs second, router last):** the diff belt (FU-235) → the spike
(FU-242) → the impact line → box-run maintenance verbs proven by a human-ordered run → `reconcile: auto` on
the compute tier with WIP 1 → then ADR-133's three control planes (FU-243) → the CARP pair.

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
| Which surfaces may it reconcile? | **FU-097's ruling table is the first deliverable and is unwritten.** Standing the box up before deciding is hardware driving design |
| **The pilot's firmware — UEFI or legacy BIOS?** | **Read 2026-09-13: UEFI-capable, but a CSM firmware whose BIOS-setup priority is authoritative** — a UEFI install landed, yet the firmware re-derives the NVRAM order from the setup list on every boot (legacy entries first), so an `efibootmgr -o` was overwritten and the box booted the stick. So `bootMode = "bios"`: GRUB in the BIOS-boot partition is what the setup's "disk" entry boots, with no NVRAM dependency. Setup order for the pilot: disk first, USB and PXE removed. Automatic boot-failure rollback stays unavailable (it was in this pin regardless) |
| `bootCounting` in the pin | only if that read says UEFI — then one `nix eval` settles it |
| The second alert path | the spike asks for two independent paths out; today there is one, and it is in-cluster |
| How probe results leave the box at all | Pushgateway is cluster-internal and never BGP-advertised, so even the FIRST path is unbuilt — exposing it is an ip-plan/ADR-088 decision (§MB2) |
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
