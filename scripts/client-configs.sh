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

# Same precedence as scripts/mgmt-tf.sh: an explicit CLAUDE_CRED_DIR wins. Inverted here at
# first (review, #1803): with a stale homelab-pve-ssh cache under ~/.claude, an explicitly-set
# override was silently ignored and the wrong SSH identity went to the box.
CRED=""
for d in "${CLAUDE_CRED_DIR:-}" "$HOME/.claude" "$HOME/Projects/.claude-data"; do
  [ -n "$d" ] && [ -d "$d/homelab-pve-ssh" ] && CRED="$d" && break
done
[ -n "$CRED" ] || { echo "client-configs: cred dir not found (homelab-pve-ssh/)" >&2; exit 1; }
KEY="$CRED/homelab-pve-ssh/id_ed25519"

fetch_one() {
  # ⚠ ONE assignment per `local`. A shell expands every argument of `local` BEFORE it assigns any
  # of them, so the old `local name="$1" dest="$ROOT/tofu/$name"` built dest from an EMPTY name.
  # Two different failures fell out of that, neither of them loud: under `devbox run` the local
  # copy was never written while the script still printed "wrote ... + tofu/<name>", and under a
  # plain `bash scripts/client-configs.sh` it died at this line with "name: unbound variable".
  # The silent half is the dangerous one — it leaves the jail on the OLD endpoint and the box on
  # the new one, which is precisely the split state the comment below says this script exists to
  # prevent. Found 2026-09-21 during the ADR-133 VIP cutover: the box's talosconfig correctly
  # listed all three control planes while tofu/talosconfig still named only cp-01, a day stale.
  local name="$1"
  local dest="$ROOT/tofu/$name"
  local tmp
  tmp="$(mktemp)"
  # mgmt-tf prints its own banner line to stdout before tofu's output; drop it and the ssh notice.
  bash "$ROOT/scripts/mgmt-tf.sh" output -raw "$name" 2>/dev/null \
    | grep -v '^mgmt-tf:' | grep -v 'Pseudo-terminal will not be allocated' > "$tmp"
  # Fail closed: a truncated or error-shaped answer must never overwrite a working config.
  head -1 "$tmp" | grep -qE '^(apiVersion|context):' \
    || { echo "client-configs: $name from the box does not look like a config — refusing to write" >&2; rm -f "$tmp"; exit 1; }
  # The kubeconfig is a CAPTURED resource, not a data source: talos_cluster_kubeconfig renders
  # the endpoint it saw at create time and `plan` never notices it has drifted (FU-259 — the
  # ADR-133 VIP cutover left it on cp-01 for a day). Refuse to hand out a config that dials an
  # address the cluster no longer declares, rather than quietly reinstating the old one on both
  # sides. The tofu-side twin of this guard is the `kubeconfig_endpoint_current` check block.
  if [ "$name" = kubeconfig ]; then
    local declared server
    declared="$(bash "$ROOT/scripts/mgmt-tf.sh" output -raw cluster_endpoint 2>/dev/null \
      | grep -v '^mgmt-tf:' | grep -v 'Pseudo-terminal will not be allocated' | tr -d '[:space:]')"
    server="$(grep -m1 -oE 'server: *\S+' "$tmp" | awk '{print $2}')"
    if [ -n "$declared" ] && [ -n "$server" ] && [ "$declared" != "$server" ]; then
      rm -f "$tmp"
      echo "client-configs: the kubeconfig in state dials $server but the cluster declares $declared — refusing to write." >&2
      echo "  recover: devbox run mgmt-tf -- apply -replace=talos_cluster_kubeconfig.this -target=talos_cluster_kubeconfig.this" >&2
      echo "  then re-run this verb (FU-259, docs/controlplane-ha.md)." >&2
      exit 1
    fi
    [ -n "$declared" ] && [ -n "$server" ] || echo "client-configs: could not compare endpoints (declared='$declared' server='$server') — wrote it unchecked" >&2
  fi
  # THE BOX FIRST, the local copy only once it lands (review, #1803). Written the other way
  # round at first, and `set -e` then turned an unreachable box into exactly the split state this
  # script exists to prevent: the jail already on the new endpoint, /var/lib/mgmt/<name> still on
  # the old one. That divergence bites hardest where it matters most — cp-upgrade and
  # node-maintenance run against the BOX's copy — and it is likeliest mid-cutover, which is
  # precisely when this gets run. Failing with both sides still on the old value is recoverable;
  # failing with them disagreeing is the bug.
  scp -q -i "$KEY" -o StrictHostKeyChecking=accept-new "$tmp" "root@$MGMT_HOST:/var/lib/mgmt/$name" \
    || { echo "client-configs: could not write $name to the box — local copy left untouched" >&2; rm -f "$tmp"; exit 1; }
  ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "root@$MGMT_HOST" "chmod 600 /var/lib/mgmt/$name" \
    || { echo "client-configs: could not chmod $name on the box — local copy left untouched" >&2; rm -f "$tmp"; exit 1; }
  install -m 600 "$tmp" "$dest"
  rm -f "$tmp"
  echo "wrote $MGMT_HOST:/var/lib/mgmt/$name + tofu/$name"
}

case "$WHICH" in
  kubeconfig) fetch_one kubeconfig ;;
  talosconfig) fetch_one talosconfig ;;
  both) fetch_one kubeconfig; fetch_one talosconfig ;;
  *) echo "usage: client-configs.sh kubeconfig|talosconfig|both" >&2; exit 64 ;;
esac
