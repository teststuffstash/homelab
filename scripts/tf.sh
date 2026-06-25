#!/bin/sh
# devbox tf wrapper — source the out-of-repo secrets, then run tofu against tofu/.
# Used by `devbox run tf-plan` / `tf-apply`. Resolves creds in the jail (~/.claude) OR on the host
# (~/Projects/.claude-data) — same dual-path trick as scripts/garage-s3.sh — so the SAME
# `devbox run tf-plan` works in both. Pass extra tofu args through, e.g. `devbox run tf-plan -target=...`.
#
# What lives where (see docs/secrets.md tiering):
#   - wallet (KeePass, Tier-0)  → grafana/ha/infisical_*/argocd PAT/forgejo runner token (keepass-env.sh)
#   - file   (Tier-0)          → GitHub App private key (resolved below), like proxmox_ssh_private_key_file
#   - tfvars                   → proxmox_api_token + non-secret IDs (github_app_id/installation_id, ci_runner_*)
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# Resolve the out-of-repo cred root (the dir that holds homelab-keepass/, homelab-runner-app/, …).
CRED=""
for d in "${CLAUDE_CRED_DIR:-}" "$HOME/.claude" "$HOME/Projects/.claude-data"; do
  [ -n "$d" ] && [ -d "$d/homelab-keepass" ] && CRED="$d" && break
done
[ -n "$CRED" ] || { echo "tf.sh: cred dir not found (looked in ~/.claude, ~/Projects/.claude-data; set CLAUDE_CRED_DIR)" >&2; exit 1; }

export KP_DIR="$CRED/homelab-keepass"
# Key FILES whose tofu defaults are baked to the jail path (/home/node/.claude/...) — re-point them
# at the resolved cred dir so the same run works on the host too. (Don't set these in tfvars, or
# tfvars overrides these env vars.)
export TF_VAR_proxmox_ssh_private_key_file="$CRED/homelab-pve-ssh/id_ed25519"
export TF_VAR_github_app_private_key_file="$CRED/homelab-runner-app/private-key.pem"

# Wallet exports (returns non-zero — and aborts under set -e — if the wallet is missing).
. "$ROOT/scripts/keepass-env.sh"

exec tofu -chdir="$ROOT/tofu" "$@"
