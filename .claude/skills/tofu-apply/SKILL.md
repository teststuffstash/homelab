---
name: tofu-apply
description: >
  Run OpenTofu against the homelab cluster (the tofu/ root) correctly — with the required secret
  vars, the right -chdir, and plan-before-apply. Use whenever applying/planning/destroying any
  tofu in this repo (cluster changes, new k8s workloads, image pins, metal nodes). Triggers:
  "tofu apply", "tofu plan", "deploy <resource> with tofu", "reconcile the cluster".
---

# Run tofu in the homelab

**Use the devbox wrappers — never wire secrets by hand.** `scripts/tf.sh` (invoked by the
wrappers) resolves the cred dir (jail `~/.claude` or host `~/Projects/.claude-data`), sources all
required `TF_VAR_*` from the KeePass wallet + cred files (`scripts/keepass-env.sh`), runs `init`,
and passes your args through. **Always `plan` and review before `apply`** — this hits live
machines.

```bash
devbox run tf-plan                                    # main root (tofu/), secrets auto-sourced
devbox run tf-plan -- -target='kubernetes_deployment.ha'
devbox run tf-apply                                   # review the plan first
devbox run tf-validate                                # syntax-only, no backend/secrets
devbox run github-tofu plan                           # tofu/github root (repos/rulesets/org secrets)
```

The `tofu/provisioning/` root (Matchbox) has separate state and only needs one var:

```bash
export TF_VAR_proxmox_api_token=$(cat ~/.claude/homelab-pve-ssh/api_token_matchbox)
devbox run -- tofu -chdir=tofu/provisioning plan
```

If a plan errors `No value for required variable <x>`, a new required var was added — extend
`scripts/keepass-env.sh` (wallet entry, `keepass-init.sh` to add) rather than exporting ad hoc.

## Gotchas

- ⚠️ **Never `talosctl upgrade` a Proxmox nocloud VM** — bake extensions into the image
  (`image.tf`) and recreate (`-replace`). Metal nodes upgrade fine.
- Pin images by digest after first run (e.g. `unifi.tf`) so a registry tag move can't desync them.
- A targeted apply prints a "Resource targeting is in effect" warning — expected; follow up with a
  full `plan` later to catch drift.
- After applying, verify the real end state (`devbox run nodes`, `kubectl rollout status`, `dig`) —
  don't claim done from the apply output alone.
