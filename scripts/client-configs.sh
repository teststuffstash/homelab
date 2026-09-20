#!/usr/bin/env bash
# Refresh the client configs (kubeconfig / talosconfig) for the MAIN root from the authoritative
# state — which since 2026-09-13 lives on the management box, not in this checkout (FU-012,
# ADR-129/-131). Used by `devbox run kubeconfig` and `devbox run talosconfig`.
#
# Why this exists as a script instead of the old one-liner. `devbox run kubeconfig` used to be
#
#     tofu -chdir=tofu output -raw kubeconfig > tofu/kubeconfig
#
# which reads tofu/terraform.tfstate — a file the state migration LEFT BEHIND in the jail. It is
# not an error path: tofu answers happily from the stale copy, so the verb silently rewrites
# tofu/kubeconfig from a snapshot of the cluster as it was before the migration. That bit during
# the ADR-133 endpoint cutover (2026-09-20): the stale state still renders the old
# https://192.168.2.51:6443 endpoint, so one reflexive `devbox run kubeconfig` would have undone
# the VIP cutover on the very file every later step reads. scripts/tf.sh already refuses the main
# root for plan/apply; this verb had no such guard because it only READS — and reading the wrong
# state is exactly the failure.
#
# Both files are also placed on the BOX (/var/lib/mgmt/{kubeconfig,talosconfig}), because the box
# runs the maintenance verbs (cp-upgrade, node-maintenance) and the apply loop against them; a
# refresh that updated only the jail would leave the two halves pointing at different endpoints.
set -euo pipefail

# Write into the checkout devbox is running for, falling back to script-relative for a bare
# `bash scripts/client-configs.sh`. Named explicitly rather than inferred: these two files are
# read by every later step, so "which tree did it land in" must never be a guess.
ROOT="${DEVBOX_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
WHICH="${1:?usage: client-configs.sh kubeconfig|talosconfig|both}"
MGMT_HOST="${MGMT_HOST:-192.168.2.53}"

CRED=""
for d in "$HOME/.claude" "$HOME/Projects/.claude-data" "${CLAUDE_CRED_DIR:-}"; do
  [ -n "$d" ] && [ -d "$d/homelab-pve-ssh" ] && CRED="$d" && break
done
[ -n "$CRED" ] || { echo "client-configs: cred dir not found (homelab-pve-ssh/)" >&2; exit 1; }
KEY="$CRED/homelab-pve-ssh/id_ed25519"

fetch_one() {
  local name="$1" dest="$ROOT/tofu/$name" tmp
  tmp="$(mktemp)"
  # mgmt-tf prints its own banner line to stdout before tofu's output; drop it and the ssh notice.
  bash "$ROOT/scripts/mgmt-tf.sh" output -raw "$name" 2>/dev/null \
    | grep -v '^mgmt-tf:' | grep -v 'Pseudo-terminal will not be allocated' > "$tmp"
  # Fail closed: a truncated or error-shaped answer must never overwrite a working config.
  head -1 "$tmp" | grep -qE '^(apiVersion|context):' \
    || { echo "client-configs: $name from the box does not look like a config — refusing to write" >&2; rm -f "$tmp"; exit 1; }
  install -m 600 "$tmp" "$dest"
  rm -f "$tmp"
  scp -q -i "$KEY" -o StrictHostKeyChecking=accept-new "$dest" "root@$MGMT_HOST:/var/lib/mgmt/$name"
  ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "root@$MGMT_HOST" "chmod 600 /var/lib/mgmt/$name"
  echo "wrote tofu/$name + $MGMT_HOST:/var/lib/mgmt/$name"
}

case "$WHICH" in
  kubeconfig) fetch_one kubeconfig ;;
  talosconfig) fetch_one talosconfig ;;
  both) fetch_one kubeconfig; fetch_one talosconfig ;;
  *) echo "usage: client-configs.sh kubeconfig|talosconfig|both" >&2; exit 64 ;;
esac
