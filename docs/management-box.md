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
| **A** | the box is maintainable | OS installed declaratively, SSH credentials + a rotation scheme, `main`'s tofu state and the dangerous creds moved here (FU-012's other half), the probe + the local deadman | 🔜 config in `nixos/`, the secrets path built (§Credentials), install pending |
| **B** | one trivial apply | a `tofu apply` of something nobody depends on — dashboard-shaped, explicitly NOT an unattended control-plane or router operation. The point of the first rollout is the PATH, not the change | ⬜ gated on FU-097's table naming the surfaces |
| **C** | triggers | homelab PR merges (the `ROADMAP.md` §Deploy paths gap: a merged change to an unreconciled surface deploys nothing today) + drift detection (the `tofu plan` cron FU-097 asks for) | ⬜ |
| — | *then* the management network | recovery path 2 and the rest of the spike's original order, resumed once the box is dull | ⬜ |

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

The box pulls the **operator-advanced `mgmt-release` ref** on a timer — ⚠ *not* `master`: this
repo auto-merges bot-approved PRs, so following master would let a merged PR rewrite the recovery
root's kernel, bootloader or sshd within the hour. `CODEOWNERS` gained a `/nixos/` row as the
second belt, and if the ref does not exist the pull no-ops loudly rather than falling back. The
cluster at most pokes it. Not fussiness — a
pushed update means something inside the cluster holds a credential that can rewrite the recovery
root, and the spike's §What stays human lists this box beside the CA keys and the Tier-0 wallet as
a trust anchor. Pulling reviewed commits is the same automation with no inbound key, and it takes
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
| `tofu plan` → empty on the **cone-clean** roots only (`cloudflare`, `provisioning`) | toolchain + remote state + encryption passphrase + Garage reachable + no drift. ⚠ NOT "every migrated root": `infisical` is migrated but its provider auth port-forwards into the live cluster, so its plan asserts the cluster is up — the opposite of what this box probes; `main` is local state until FU-012's copy lands here. Measured 2026-09-12: both roots plan EMPTY, which also retires [`tofu-state.md`](tofu-state.md)'s note that `cloudflare` carries a standing 1-change comment drift |
| `talosctl version` against a live node | no client/server skew after a toolchain bump |
| `ansible --check` on an OPNsense play | the collection + the pinned httpx interpreter + the API credential still work, and the recap's `changed=` count is read for drift — class 9 in [`dependency-upgrades.md`](dependency-upgrades.md) is the sharpest unreconciled-surface gap. ⚠ **A partial belt, by construction:** `ansible-playbook --check` exits 0 even when tasks report `changed` (only a task *error* is non-zero), so the exit code alone proves plumbing, not currency — hence the recap parse; and `oxlorg.opnsense.raw` tasks with `action: post` return `changed=False` in check mode by design, so **advanced-settings drift stays invisible** no matter how the recap is parsed |
| each credential it holds, read once | a rotation did not lock the box out |

The metric *shape* copies the Garage write probe: the verdict **and** a `*_last_run_timestamp`, so
a staleness alert catches "the box is wedged" and not only "the box says no". This is FU-102's
prober contract applied to its first non-stack consumer — the spike's line is that *the prober is
the human*.

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
- **A version bump never touches a secret.** `nixos-rebuild test|boot` rebuilds the closure from
  git and leaves `/etc/ssh`, `/var/lib/mgmt` and `/root` alone; only a *reinstall* re-provisions
  (`--extra-files`), and only a *rotation* re-runs the script. Authorized keys are the one credential
  that rotates through git.
- **Which credentials, and whose:** the env file carries exactly what the belt's cone-clean checks
  need (the Garage state key + the state passphrase, the Cloudflare and Matchbox-Proxmox tokens,
  the OPNsense API pair) — the main root's `TF_VAR_*` set moves only when FU-097's table says the
  box may touch `main`. ⚠ Today's entries are the **jail's**, a phase-A shortcut against the
  doctrine's "one consumer, one token, at its tier"; the script's table is one line per credential
  so each swaps for a box-scoped entry as it is minted (FU-012's next). The state passphrase is
  shared by nature — it is the state's key, not a consumer's.
- ⚠ The box is a **consumer** of Tier-0, never its home: the wallet stays with the operator, and the
  scripts that read it (`keepass-env.sh`, `tofu-state-env.sh`, `opnsense-playbook.sh`) all yield to
  a pre-set environment, which is how the same probe runs in the jail (wallet) and on the box (env
  file). Proven 2026-09-13: the belt passes 5/5 from a home with no wallet, the env file alone.

## Open, and deliberately not built yet

| Question | Why it waits |
|---|---|
| Which surfaces may it reconcile? | **FU-097's ruling table is the first deliverable and is unwritten.** Standing the box up before deciding is hardware driving design |
| **The pilot's firmware — UEFI or legacy BIOS?** | read it in the installer (`[ -d /sys/firmware/efi ]`): it sets `bootMode` AND decides whether this box can ever have automatic boot-failure rollback (§Rollback layer 2). The largest unknown in the build |
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
