---
name: tofu-apply
description: >
  Run OpenTofu against the homelab cluster (the tofu/ root) correctly — with the required secret
  vars, the right -chdir, and plan-before-apply. Use whenever applying/planning/destroying any
  tofu in this repo (cluster changes, new k8s workloads, image pins, metal nodes). Triggers:
  "tofu apply", "tofu plan", "deploy <resource> with tofu", "reconcile the cluster".
---

# Run tofu in the homelab

Tofu is in `tofu/` (main cluster) and `tofu/provisioning/` (Matchbox). Run it through devbox with
`-chdir` (devbox executes from the repo root). **Always `plan` and review before `apply`** — this
hits live machines.

## Environment

```bash
cd /workspace/homelab
export NIX_CONFIG="experimental-features = nix-command flakes"
# the main tofu/ root needs two secret vars (sourced from the cred files):
export TF_VAR_grafana_admin_password=$(cat ~/.claude/homelab-ha/grafana_admin_password)
export TF_VAR_ha_prometheus_token=$(cat ~/.claude/homelab-ha/prometheus_llat)
# tofu/provisioning/ instead needs:  TF_VAR_proxmox_api_token=$(cat ~/.claude/homelab-pve-ssh/api_token_matchbox)
```

## Plan / apply

```bash
devbox run -- tofu -chdir=tofu plan
devbox run -- tofu -chdir=tofu apply                       # review the plan first
devbox run -- tofu -chdir=tofu apply -target='<addr>'      # scope risky changes
```

## Gotchas

- ⚠️ **Never `talosctl upgrade` a Proxmox nocloud VM** — bake extensions into the image
  (`image.tf`) and recreate (`-replace`). Metal nodes upgrade fine.
- Pin images by digest after first run (e.g. `unifi.tf`) so a registry tag move can't desync them.
- A targeted apply prints a "Resource targeting is in effect" warning — expected; follow up with a
  full `plan` later to catch drift.
- After applying, verify the real end state (`devbox run nodes`, `kubectl rollout status`, `dig`) —
  don't claim done from the apply output alone.
