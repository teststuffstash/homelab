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

The `tofu/` root has **9 required (no-default) secret vars** — `proxmox_api_token` is in
`tofu/terraform.tfvars` (auto-loaded); the rest come from cred files + the homelab **KeePass**
(Tier-0). ⚠ Even a `-target`ed run needs ALL of them set (tofu validates the whole config before
scoping), so source the full block every time:

```bash
cd /workspace/homelab
export NIX_CONFIG="experimental-features = nix-command flakes"

# file-based creds (~/.claude/):
export TF_VAR_grafana_admin_password=$(cat ~/.claude/homelab-ha/grafana_admin_password)
export TF_VAR_ha_prometheus_token=$(cat ~/.claude/homelab-ha/prometheus_llat)
export TF_VAR_forgejo_runner_token=$(cat ~/.claude/homelab-forgejo/runner-token)

# Tier-0 secrets from the homelab KeePass (keyfile-only, NO master password; keepassxc-cli is a
# nix tool, not on the bare PATH):
KP="$HOME/.claude/homelab-keepass"; KCLI="$PWD/.devbox/nix/profile/default/bin/keepassxc-cli"
kp(){ "$KCLI" show -s -a Password --no-password --key-file "$KP/homelab.keyx" "$KP/homelab.kdbx" "$1"; }
export TF_VAR_argocd_github_pat=$(kp argocd-github-pat)
export TF_VAR_infisical_encryption_key=$(kp infisical-encryption-key)
export TF_VAR_infisical_auth_secret=$(kp infisical-auth-secret)
export TF_VAR_infisical_db_password=$(kp infisical-db-password)
export TF_VAR_infisical_admin_password=$(kp infisical-admin-password)

# tofu/provisioning/ (separate root) instead needs:
#   export TF_VAR_proxmox_api_token=$(cat ~/.claude/homelab-pve-ssh/api_token_matchbox)
```

If a future `tofu plan` errors `No value for required variable <x>`, a new required var was added —
add it here, sourced from KeePass (`kp <entry>`; list entries with
`$KCLI ls --no-password --key-file "$KP/homelab.keyx" "$KP/homelab.kdbx"`) or a `~/.claude/` cred file.

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
