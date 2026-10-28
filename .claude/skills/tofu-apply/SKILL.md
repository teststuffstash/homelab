---
name: tofu-apply
description: >
  Run OpenTofu against the homelab cluster (the tofu/ root) correctly — with the required secret
  vars, the right -chdir, and plan-before-apply. Use whenever applying/planning/destroying any
  tofu in this repo (cluster changes, new k8s workloads, image pins, metal nodes). Triggers:
  "tofu apply", "tofu plan", "deploy <resource> with tofu", "reconcile the cluster".
---

# Run tofu in the homelab

> **Glance first**: [`../GAPS.md`](../GAPS.md) §tofu-apply — unpromoted sightings apply until
> closed (contract: [`../README.md`](../README.md)).

> ⚠ **An `apply` runs inside a [maintenance window](../maintenance-window/SKILL.md)** — baseline
> first, alert watch armed, compared after. A clean plan is not a safe change: the 2026-09-20
> control-plane outage came from a one-line apply whose plan was `12 to change, 0 to destroy`.

**Use the devbox wrappers — never wire secrets by hand.** `scripts/tf.sh` (invoked by the
wrappers) resolves the cred dir (jail `~/.claude` or host `~/Projects/.claude-data`), sources all
required `TF_VAR_*` from the KeePass wallet + cred files (`scripts/keepass-env.sh`), runs `init`,
and passes your args through. **Always `plan` and review before `apply`** — this hits live
machines.

⚠ **Since 2026-09-13 the MAIN root runs ON the management box** (its state + the dangerous
creds live there — ADR-129/-131, FU-012): `devbox run tf-plan|tf-apply` refuse and point at
`mgmt-tf`, which ssh-es to the box and runs tofu from a COMMITTED ref (push your branch first;
`MGMT_REF=origin/<branch>`). The box's own loops plan every PR (`management-sentinel` status)
and apply the allowlisted residue after merge (`management-apply` status) — a human apply is
for what the allowlist refuses. [`docs/management-box.md`](../../../docs/management-box.md) §MB3.

```bash
devbox run mgmt-tf -- plan                            # main root, ON the box, origin/master
MGMT_REF=origin/fix/foo devbox run mgmt-tf -- plan    # a pushed branch
devbox run mgmt-human-plan -- <pr>                    # stage-1-REFUSED PR (providers.tf etc.): read the diff,
                                                      # plan on the box, post the required verdict as a human plan
devbox run mgmt-tf -- apply <plan-id>                 # the id the plan printed — review the plan first
devbox run mgmt-tf -- plan -target='kubernetes_deployment.ha'   # read the plan — -target drags whole resources (FU-248)
devbox run tf-validate                                # syntax-only, no backend/secrets
devbox run github-tofu plan                           # tofu/github root (repos/rulesets/org secrets)
```

**`github-tofu` applies OUTSIDE the jail with the org-admin wallet** (`scripts/github-tf.sh` header,
`tofu/github/README.md` §Run it) — a token that plans cleanly is not a token that can apply: plan
reads, apply writes repository/organization *Administration*, which the jail PAT lacks by design
(promoted 2026-10-26, GAPS tofu-apply-G3).

The `tofu/provisioning/` root (Matchbox) has separate state and only needs one var:

```bash
source scripts/keepass-env.sh   # exports TF_VAR_proxmox_api_token (wallet: pve-api-token-matchbox)
TOFU_STATE_ROOT_DIR="$PWD/tofu/provisioning" . scripts/tofu-state-env.sh   # encrypted Garage state
devbox run -- tofu -chdir=tofu/provisioning plan
```

If a plan errors `No value for required variable <x>`, a new required var was added — extend
`scripts/keepass-env.sh` (wallet entry, `keepass-init.sh` to add) rather than exporting ad hoc.

## Gotchas

- ⚠️ **Never `talosctl upgrade` a Proxmox nocloud VM** — bake extensions into the image
  (`image.tf`) and recreate (`-replace`). Metal nodes upgrade fine.
- ⚠️ **A `machines.yaml` `longhorn_disks` change needs a node REBOOT** (Talos provisions
  `machine.disks` at boot) — so does any other v1alpha1 change Talos cannot take live. Both
  `talos_machine_configuration_apply` resources run `apply_mode = "no_reboot"` (`tofu/talos.tf`,
  `tofu/metal.tf`), so the apply REFUSES it instead of rebooting mid-apply; the reboot is yours,
  inside the window: `scripts/node-maintenance.sh settle <node>` (cordon + move the last replicas)
  or `down <node>` FIRST, then the reboot, then `up <node>`. The reboot is fine; a node carrying
  single-replica volumes rebooting undrained is not. Other documents (VolumeConfig,
  HostnameConfig) are install-time — never refused, never live (promoted 2026-10-26, GAPS
  tofu-apply-G2).
- **A FAILED apply is NOT a no-op.** A provider error mid-apply (a github 403, a Proxmox 500) can
  still persist the PLANNED state, and the next plan then reads `No changes` while the live thing
  differs — invisible and self-sealing (a later apply with the right token is a no-op too). Before
  retrying, read the live object and compare it with `state show`; `apply -refresh-only` may not
  repopulate nested blocks (github rulesets' `required_check`), so the repair is `state rm` +
  `import '<id>'`, then re-plan until the expected diff returns (promoted 2026-10-26, GAPS
  tofu-apply-G3).
- Pin images by digest after first run (e.g. `unifi.tf`) so a registry tag move can't desync them.
- A targeted apply prints a "Resource targeting is in effect" warning — expected; follow up with a
  full `plan` later to catch drift.
- After applying, verify the real end state (`devbox run nodes`, `kubectl rollout status`, `dig`) —
  don't claim done from the apply output alone. **Nor from the exit code alone**: the wrapper has
  returned exit 127 AFTER `Apply complete!` on an apply that had fully landed — a non-zero exit is
  "verify the end state", never "re-run" or "roll back" (promoted 2026-10-26, GAPS tofu-apply-G1).
- **A `proxmox_virtual_environment_vm` change: the post-apply check is `qm config <vmid>` on the
  hypervisor, diffed against the plan's `+`/`~` lines**, before `node-maintenance.sh up`. The
  provider's `1 changed` line is not the end state — pvedaemon has accepted an update that carried
  fewer fields than planned (`journalctl -u pvedaemon | grep 'update VM'` shows what it got); a
  config can also be accepted and the start then fail on a property. Re-plan + re-apply until
  `qm config` matches (promoted 2026-10-26, GAPS tofu-apply-G3 resight).
