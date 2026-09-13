#!/usr/bin/env bash
# mgmt-provision-secrets — the ONLY way a secret reaches the management box (ADR-129,
# docs/management-box.md §Credentials).
#
# The box's NixOS closure holds NO secrets: the repo is public and /nix/store is world-readable, so
# anything the flake can see, everyone can. Secrets are therefore FILES outside the store, borrowing
# the appliance tier's shape (docs/secrets.md §The three tiers: read once at provision, plaintext,
# mode 600) with the Tier-0 WALLET as the store instead of Infisical — the box exists to work when
# the cluster (and so Infisical) is down. `nixos-rebuild test|boot` never touches these paths, so
# an OS/config bump never re-provisions and a rotation never goes through git: re-run this script.
#
# One script, two moments:
#   stage (default)   materialise the tree under $OUT — the `--extra-files` tree nixos-anywhere
#                     ships at INSTALL time (the sshd host key MUST arrive this way: sshd generates
#                     one when the path is empty, and a regenerated key breaks the jail's known_hosts)
#   --push [host]     rsync the same tree onto a RUNNING box (rotation, or the first cred drop after
#                     install). Units read /var/lib/mgmt/env at each start (EnvironmentFile=), so
#                     nothing needs restarting.
#
# What lands where (all root:root, 0600):
#   etc/ssh/ssh_host_ed25519_key   wallet mgmt-ssh-host (minted by scripts/keepass-init.sh)
#   var/lib/mgmt/env               the belt's credentials — see the TABLE below
#   var/lib/mgmt/talosconfig       copied from tofu/talosconfig in THIS checkout
#   var/lib/mgmt/kubeconfig        copied from tofu/kubeconfig  in THIS checkout
#
# ⚠ Doctrine (docs/secrets.md §Minting doctrine — one consumer, one token, at its tier): the entries
# in the table are the JAIL's today, which is the phase-A shortcut. Each row is meant to be swapped
# for a box-scoped entry as those are minted (FU-012's next) — one line per credential, on purpose.
#
# Usage:
#   scripts/mgmt-provision-secrets.sh                 # stage → ~/.claude/homelab-mgmt/extra-files
#   scripts/mgmt-provision-secrets.sh --push          # stage + rsync onto root@192.168.2.53
#   scripts/mgmt-provision-secrets.sh --push 192.168.2.99   # e.g. the installer's DHCP address
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MGMT_HOST_DEFAULT="192.168.2.53"

# Resolve the cred root (the dir holding homelab-keepass/) — jail vs host, like wallet-files.sh.
CRED=""
for d in "${KP_DIR:+$(dirname "$KP_DIR")}" "$HOME/.claude" "$HOME/Projects/.claude-data"; do
  [ -n "$d" ] && [ -f "$d/homelab-keepass/homelab.kdbx" ] && CRED="$d" && break
done
[ -n "$CRED" ] || { echo "FATAL: no wallet found (homelab-keepass/homelab.kdbx) — this runs from the jail/host, never on the box" >&2; exit 1; }
DB="$CRED/homelab-keepass/homelab.kdbx"
KEYF="$CRED/homelab-keepass/homelab.keyx"
OUT="${OUT:-$CRED/homelab-mgmt/extra-files}"

export DEVBOX_QUIET=1
export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"
if command -v keepassxc-cli >/dev/null 2>&1; then kp() { keepassxc-cli "$@"; }
else kp() { (cd "$REPO" && devbox run --quiet -- keepassxc-cli "$@"); }; fi
kp_val() { kp show -q --no-password -k "$KEYF" -a Password "$DB" "$1" 2>/dev/null; }

PUSH=0 HOST="$MGMT_HOST_DEFAULT"
case "${1:-}" in
  --push) PUSH=1; HOST="${2:-$MGMT_HOST_DEFAULT}" ;;
  "") ;;
  *) echo "usage: $0 [--push [host]]" >&2; exit 2 ;;
esac

# ── the TABLE: env var → wallet entry ──────────────────────────────────────────────────────────
# Exactly what scripts/mgmt-probe.sh's belt needs for the cone-clean roots (cloudflare,
# provisioning), the OPNsense --check and talosctl. NOT the main root's TF_VAR_* set — that moves
# when FU-097's table says the box may touch main, not before.
ENV_TABLE=(
  "TOFU_STATE_KEY_ID=tofu-state-key-id"            # scripts/tofu-state-env.sh (Garage state bucket)
  "TOFU_STATE_SECRET=tofu-state-secret"
  "TOFU_STATE_PASSPHRASE=tofu-state-passphrase"    # the state's own key — shared by nature, never box-scoped
  "CLOUDFLARE_API_TOKEN=cloudflare-write-key"      # tofu/cloudflare plan
  "TF_VAR_proxmox_api_token=pve-api-token-matchbox" # tofu/provisioning plan
  "OPN_API_KEY=opnsense-api-key"                   # scripts/opnsense-playbook.sh --check
  "OPN_API_SECRET=opnsense-api-secret"
)

# ── stage ───────────────────────────────────────────────────────────────────────────────────────
rm -rf "$OUT"
install -d -m700 "$OUT" "$OUT/etc/ssh" "$OUT/var/lib/mgmt"

# 1. the sshd host key (attachment — NEVER --stdout, it mangles binaries; export straight to file)
kp attachment-export -q --no-password -k "$KEYF" "$DB" mgmt-ssh-host ssh_host_ed25519_key \
  "$OUT/etc/ssh/ssh_host_ed25519_key" >/dev/null \
  || { echo "FATAL: wallet entry mgmt-ssh-host/ssh_host_ed25519_key missing — run scripts/keepass-init.sh" >&2; exit 1; }
kp attachment-export -q --no-password -k "$KEYF" "$DB" mgmt-ssh-host ssh_host_ed25519_key.pub \
  "$OUT/etc/ssh/ssh_host_ed25519_key.pub" >/dev/null
chmod 600 "$OUT/etc/ssh/ssh_host_ed25519_key"; chmod 644 "$OUT/etc/ssh/ssh_host_ed25519_key.pub"
echo "  + etc/ssh/ssh_host_ed25519_key  (← mgmt-ssh-host)"

# 2. the env file — one read per entry, fail loudly on a missing value (a half-provisioned box is
#    a belt that skips forever)
ENVF="$OUT/var/lib/mgmt/env"
: > "$ENVF"; chmod 600 "$ENVF"
{
  echo "# written by scripts/mgmt-provision-secrets.sh $(date -u +%FT%TZ) — DO NOT EDIT, re-run the script"
  for row in "${ENV_TABLE[@]}"; do
    var="${row%%=*}"; entry="${row#*=}"
    v="$(kp_val "$entry")"
    [ -n "$v" ] || { echo "FATAL: wallet entry '$entry' (for $var) is empty/missing" >&2; exit 1; }
    case "$v" in *"'"*|*$'\n'*) echo "FATAL: value of '$entry' contains a quote/newline — not EnvironmentFile-safe" >&2; exit 1 ;; esac
    printf "%s='%s'\n" "$var" "$v"
  done
  # File-shaped creds live beside this file; talosctl/kubectl honour these natively.
  echo "TALOSCONFIG=/var/lib/mgmt/talosconfig"
  echo "KUBECONFIG=/var/lib/mgmt/kubeconfig"
} >> "$ENVF"
echo "  + var/lib/mgmt/env  (${#ENV_TABLE[@]} entries)"

# 3. talosconfig + kubeconfig from this checkout (gitignored, tofu-generated)
for f in talosconfig kubeconfig; do
  if [ -s "$REPO/tofu/$f" ]; then
    install -m600 "$REPO/tofu/$f" "$OUT/var/lib/mgmt/$f"; echo "  + var/lib/mgmt/$f  (← tofu/$f)"
  else
    echo "  ! tofu/$f missing in this checkout — skipped (the belt's talos/creds checks will skip)" >&2
  fi
done

echo "staged: $OUT"
if [ "$PUSH" = 0 ]; then
  cat <<EOF
install:  nix run nixpkgs#nixos-anywhere -- --extra-files $OUT --flake $REPO/nixos#mgmt root@<installer-ip>
rotate:   $0 --push
EOF
  exit 0
fi

# ── push ────────────────────────────────────────────────────────────────────────────────────────
# Same tree, same paths, onto the running box. --chown because the stage is owned by the jail user.
# Host-key pinning: the box's key IS the wallet's, so pin it from the staged .pub instead of TOFU.
KH="$OUT/known_hosts"
printf '%s %s\n' "$HOST" "$(cut -d' ' -f1,2 "$OUT/etc/ssh/ssh_host_ed25519_key.pub")" > "$KH"
SSH="ssh -o UserKnownHostsFile=$KH -o StrictHostKeyChecking=yes -i $CRED/homelab-pve-ssh/id_ed25519"
rsync -rlpt --chown=root:root -e "$SSH" \
  --exclude known_hosts "$OUT/" "root@$HOST:/"
$SSH "root@$HOST" 'chmod 700 /var/lib/mgmt && chmod 600 /var/lib/mgmt/* /etc/ssh/ssh_host_ed25519_key && ls -l /var/lib/mgmt'
echo "pushed to root@$HOST — units read /var/lib/mgmt/env at their next start; nothing to restart"
