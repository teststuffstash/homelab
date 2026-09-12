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

## Phases

| | Phase | Deliverable | State |
|---|---|---|---|
| **A** | the box is maintainable | OS installed declaratively, SSH credentials + a rotation scheme, `main`'s tofu state and the dangerous creds moved here (FU-012's other half), the probe + the local deadman | 🔜 config in `nixos/`, install pending |
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
jail, so nothing is typed into an installer UI and the result is what git says. `scripts/talos-usb.sh`
is the existing shape for writing the medium (download + `dd`, run on the HOST where the stick is).

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
| Toolchain — `tofu`, `talosctl`, `ansible`, `openssl` | **`devbox.lock`** (committed, repo root) | the existing weekly [`devbox-update.yaml`](../.github/workflows/devbox-update.yaml) — one synchronized `@latest` re-resolve across repos, auto-merging CI-gated PR. ⚠ Renovate's nix/devbox manager stays disabled on purpose: `@latest` is untrackable ([`renovate.md`](renovate.md) §devbox) | `git revert` the lock commit |
| System closure — kernel, glibc, systemd | `nixos/flake.lock` | the same git flow | a generation; automatic on a never-boots, see Rollback |

This is why the box runs its tools through `devbox run` from a checkout of this repo rather than
from the system closure: **one toolchain pin for the jail and the box**, which is the whole
argument for `devbox.lock` being the pin, and it keeps the system closure tiny.

## The update loop: pull, and the cluster may poke

The box **pulls a reviewed git ref** on a timer; the cluster at most pokes it. Not fussiness — a
pushed update means something inside the cluster holds a credential that can rewrite the recovery
root, and the spike's §What stays human lists this box beside the CA keys and the Tier-0 wallet as
a trust anchor. Pulling reviewed commits is the same automation with no inbound key, and it takes
the jail out of the loop (operator: updates should not be the jail's responsibility).

Internet egress on the box is allowed (operator, 2026-09-12), so the pull needs no in-cluster
mirror to work.

## Detection — the drift belt and the health probe are the same probe

**`tofu plan` returning "No changes" asserts the toolchain, the state's readability, the
credentials and the network path in one read-only call.** A non-empty diff or a non-zero exit is
the alarm either way, which is why FU-097's drift belt and this box's own health check are one
mechanism. The probe set (`scripts/mgmt-probe.sh`, run by a systemd timer on the box):

| Check | Asserts |
|---|---|
| `tofu plan` on each migrated root → empty | toolchain + remote state + encryption passphrase + Garage reachable + no drift |
| `talosctl version` against a live node | no client/server skew after a toolchain bump |
| `ansible --check` on an OPNsense play | the collection + the pinned httpx interpreter + the API credential still work — class 9 is the sharpest `ROADMAP.md` §Deploy paths gap, so this doubles as the router's drift belt |
| each credential it holds, read once | a rotation did not lock the box out |

Results go to **Pushgateway** the way the Garage write probe already does: the verdict *and* a
`*_last_run_timestamp`, so a staleness alert catches "the box is wedged" and not only "the box says
no". This is FU-102's prober contract applied to its first non-stack consumer — the spike's line is
that *the prober is the human*.

⚠ **Known hole:** Prometheus is in-cluster, so a cluster-down event blinds the detector. Acceptable
for freshness-class breakage and irrelevant to the local deadman (which needs no alerting to
work), but the spike's "alerts leave by two independent paths" has no second path yet.

## Rollback — three layers

1. **It boots but the toolchain regressed** → the post-update timer runs the probe set and, on
   failure, `nixos-rebuild --rollback` + reboot. Commit-confirm, the same shape this repo already
   specifies for OPNsense applies — and it works with the cluster face-down, which is the point.
2. **It never boots** (kernel/initrd class) → systemd-boot **boot counting**: the new entry gets N
   tries and the bootloader falls back on its own when a boot never blesses itself. ⚠ **UNVERIFIED**
   — confirm `boot.loader.systemd-boot.bootCounting` exists in the nixpkgs pin before relying on
   it. Until then, kernel-class bumps happen while the box is in arm's reach, because with no BMC
   and no PiKVM nobody can pick a previous entry.
3. **A tool version is wrong for the fleet** → `git revert` the `devbox.lock` commit; the next pull
   returns the old version.

⚠ **The one asymmetry: tofu state format.** A newer `tofu` can write a state version an older
binary refuses to read, and [`tofu-state.md`](tofu-state.md) is explicit that a root which loses
its state plans to **create** everything it already owns. So a toolchain bump's canary is `plan`
only — **never let a first `apply` be the test of a new tofu** — and the timestamped state backups
are the belt. This is also why `main`'s out-of-cone copy belongs here.

## Credentials

- **SSH authorized keys are declarative** (in the flake), so rotation is a diff: add the new key,
  rebuild, verify, remove the old — two commits, never a lockout. The credential's existence and
  scope stay config, only the private half is data: [`secrets.md`](secrets.md) §Minting doctrine.
- **SSH host keys are declared from a wallet attachment**, or a reinstall silently breaks the
  jail's `known_hosts`.
- **Secrets on the box follow the appliance tier**: read from the Tier-0 wallet once at provision
  and written `mode 600`, exactly as the snore-recorder device does. **Not** `sops-nix` — this lab
  rejected it for giving no real at-rest protection when the key shares the disk (`secrets.md`).
- ⚠ The box is a **consumer** of Tier-0, never its home: the wallet stays with the operator.

## Open, and deliberately not built yet

| Question | Why it waits |
|---|---|
| Which surfaces may it reconcile? | **FU-097's ruling table is the first deliverable and is unwritten.** Standing the box up before deciding is hardware driving design |
| `bootCounting` in the pin | one `nix eval` away; the answer changes whether kernel bumps need hands |
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
