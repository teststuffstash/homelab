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
#   var/lib/mgmt/env               the belt's + the main root's credentials — see the TABLE below
#   var/lib/mgmt/main.tfvars       main's gitignored tfvars (proxmox token); provisioning.tfvars likewise
#   var/lib/mgmt/runner-app/…      the runner App key ci-runner.tf reads by path
#   var/lib/mgmt/sentinel/…        the homelab-sentinel App key (ADR-131: the box posts the verdict)
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
# What scripts/mgmt-probe.sh's belt needs for the cone-clean roots (provisioning), the OPNsense
# --check and talosctl — PLUS, since 2026-09-13, the MAIN root's TF_VAR_* set: the operator ruled
# the main root's raw-k8s residue the box's test surface (docs/management-box.md §The test
# surface), so the box plans and applies main (ADR-131 sentinel + the apply loop). main's
# proxmox token rides in main.tfvars (tfvars wins over env — the keepass-env.sh rule).
ENV_TABLE=(
  "TOFU_STATE_KEY_ID=tofu-state-key-id"            # scripts/tofu-state-env.sh (Garage state bucket)
  "TOFU_STATE_SECRET=tofu-state-secret"
  "TOFU_STATE_PASSPHRASE=tofu-state-passphrase"    # the state's own key — shared by nature, never box-scoped
  "CLOUDFLARE_API_TOKEN=cloudflare-write-key"      # tofu/cloudflare plan
  "OPN_API_KEY=opnsense-api-key"                   # scripts/opnsense-playbook.sh --check
  "OPN_API_SECRET=opnsense-api-secret"
  # the main root (scripts/keepass-env.sh's export list, one line each — swap for box-scoped mints as FU-012 minds them)
  "TF_VAR_grafana_admin_password=grafana-admin-password"
  "TF_VAR_ha_prometheus_token=ha-prometheus-token"
  "TF_VAR_infisical_encryption_key=infisical-encryption-key"
  "TF_VAR_infisical_auth_secret=infisical-auth-secret"
  "TF_VAR_infisical_db_password=infisical-db-password"
  "TF_VAR_argocd_github_pat=argocd-github-pat"
  "TF_VAR_ghcr_read_packages_token=homelab-github-actions-runner-read-packages"
  "TF_VAR_infisical_admin_email=infisical-admin-email"
  "TF_VAR_infisical_admin_password=infisical-admin-password"
  "TF_VAR_forgejo_runner_token=forgejo-runner-token"
  # the sentinel's GitHub identity — the homelab-sentinel App (ADR-130/-131; docs/github-apps.yaml)
  "MGMT_GH_APP_ID=github-sentinel-app-id"
  # tofu/github, plan-only on the box (FU-238): the read-only PAT minted by scripts/github-mgmt-pat-bootstrap.sh
  "GITHUB_TOKEN=github-mgmt-readonly-pat"
  "MGMT_GH_APP_INSTALLATION_ID=github-sentinel-installation-id"
)

# ── stage ───────────────────────────────────────────────────────────────────────────────────────
rm -rf "$OUT"
# ⚠ The tree's DIRECTORY modes matter: this tree is extracted over the box's real `/`. On the first
# push (2026-09-13) every intermediate dir was 0700, tar applied that to /, /etc, /var, /var/lib —
# and systemd-resolved (unprivileged) lost /etc/resolv.conf: DNS dead until a chmod by hand. So the
# intermediates mirror the real filesystem (0755); only /var/lib/mgmt (0700) and the FILES (0600)
# are private. The push below ALSO refuses to touch existing directories (--no-overwrite-dir).
install -d -m700 "$OUT"
install -d -m755 "$OUT/etc" "$OUT/etc/ssh" "$OUT/var" "$OUT/var/lib"
install -d -m700 "$OUT/var/lib/mgmt"

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
  echo "TOFU_VAR_DIR=/var/lib/mgmt"
  # tofu/provisioning's matchbox provider reads its gRPC client files by path (variables default to
  # the JAIL's wallet cache, ~/.claude/homelab-matchbox/ — the box's first plan failed on exactly
  # that, 2026-09-13). Same wallet attachments, box-local paths.
  echo "TF_VAR_matchbox_ca=/var/lib/mgmt/matchbox/ca.crt"
  echo "TF_VAR_matchbox_client_cert=/var/lib/mgmt/matchbox/client.crt"
  echo "TF_VAR_matchbox_client_key=/var/lib/mgmt/matchbox/client.key"
  # ...and its proxmox provider SSHes into pve with the seed key (variable defaults to the jail's
  # cache, ~/.claude/homelab-pve-ssh/). THE dangerous credential FU-012 names — the point of the box.
  echo "TF_VAR_proxmox_ssh_private_key_file=/var/lib/mgmt/pve-ssh/id_ed25519"
  # main root: ci-runner.tf reads the runner App's key by path (tf.sh's TF_VAR_github_app_private_key_file)
  echo "TF_VAR_github_app_private_key_file=/var/lib/mgmt/runner-app/private-key.pem"
  # the sentinel + apply loop (scripts/mgmt-sentinel.sh, scripts/mgmt-apply.sh): the App key, where
  # main's state lives on the box (local backend via -state=, ADR-131), the provider cache
  echo "MGMT_GH_APP_KEY_FILE=/var/lib/mgmt/sentinel/app-key.pem"
  # tofu/github's three App keys are VALUES of tofu variables (PEM, multi-line — not env-file-safe):
  # files under this dir, exported per root by scripts/mgmt-root-env/github.sh
  echo "MGMT_CRED_DIR=/var/lib/mgmt/cred"
  echo "MGMT_STATE_DIR=/var/lib/mgmt/state"
  echo "TF_PLUGIN_CACHE_DIR=/var/lib/mgmt/plugin-cache"
  echo "ORG=teststuffstash"
  echo "MGMT_REPO=homelab"
} >> "$ENVF"
echo "  + var/lib/mgmt/env  (${#ENV_TABLE[@]} entries)"

# 3a. the Matchbox gRPC client files (wallet entry matchbox-grpc, three attachments)
install -d -m700 "$OUT/var/lib/mgmt/matchbox"
for att in ca.crt client.crt client.key; do
  kp attachment-export -q --no-password -k "$KEYF" "$DB" matchbox-grpc "$att" "$OUT/var/lib/mgmt/matchbox/$att" >/dev/null \
    || { echo "FATAL: wallet entry matchbox-grpc/$att missing" >&2; exit 1; }
  chmod 600 "$OUT/var/lib/mgmt/matchbox/$att"; echo "  + var/lib/mgmt/matchbox/$att  (← matchbox-grpc/$att)"
done
# 3a'. the Proxmox SSH seed key (wallet entry pve-ssh-seed) — ⚠ the same key the box trusts in
#      keys/jail.pub; a box-scoped pve key is on FU-012's list with the other per-consumer mints.
install -d -m700 "$OUT/var/lib/mgmt/pve-ssh"
kp attachment-export -q --no-password -k "$KEYF" "$DB" pve-ssh-seed id_ed25519 "$OUT/var/lib/mgmt/pve-ssh/id_ed25519" >/dev/null \
  || { echo "FATAL: wallet entry pve-ssh-seed/id_ed25519 missing" >&2; exit 1; }
chmod 600 "$OUT/var/lib/mgmt/pve-ssh/id_ed25519"; echo "  + var/lib/mgmt/pve-ssh/id_ed25519  (← pve-ssh-seed/id_ed25519)"
# 3a''. the two GitHub App keys the main root + the sentinel need (same wallet entries wallet-files.sh caches)
install -d -m700 "$OUT/var/lib/mgmt/runner-app" "$OUT/var/lib/mgmt/sentinel"
kp attachment-export -q --no-password -k "$KEYF" "$DB" github-runner-app private-key.pem "$OUT/var/lib/mgmt/runner-app/private-key.pem" >/dev/null \
  || { echo "FATAL: wallet entry github-runner-app/private-key.pem missing" >&2; exit 1; }
chmod 600 "$OUT/var/lib/mgmt/runner-app/private-key.pem"; echo "  + var/lib/mgmt/runner-app/private-key.pem  (← github-runner-app)"
kp attachment-export -q --no-password -k "$KEYF" "$DB" github-sentinel-app private-key.pem "$OUT/var/lib/mgmt/sentinel/app-key.pem" >/dev/null \
  || { echo "FATAL: wallet entry github-sentinel-app/private-key.pem missing" >&2; exit 1; }
chmod 600 "$OUT/var/lib/mgmt/sentinel/app-key.pem"; echo "  + var/lib/mgmt/sentinel/app-key.pem  (← github-sentinel-app)"
# 3a'''. tofu/github's App keys + ids (FU-238) — the wallet-files.sh cache layout, under /var/lib/mgmt/cred
for app in deploy renovate reviewer; do
  d="$OUT/var/lib/mgmt/cred/homelab-github-$app"; install -d -m700 "$OUT/var/lib/mgmt/cred" "$d"
  kp attachment-export -q --no-password -k "$KEYF" "$DB" "github-$app-app" private-key.pem "$d/private-key.pem" >/dev/null \
    || { echo "FATAL: wallet entry github-$app-app/private-key.pem missing" >&2; exit 1; }
  v="$(kp_val "github-$app-app-id")"; [ -n "$v" ] || { echo "FATAL: wallet entry github-$app-app-id missing" >&2; exit 1; }
  printf '%s' "$v" > "$d/app-id"; chmod 600 "$d/private-key.pem" "$d/app-id"
  echo "  + var/lib/mgmt/cred/homelab-github-$app/{app-id,private-key.pem}  (← github-$app-app)"
done
# 3b. per-root var files the jail keeps gitignored in the checkout — a fresh clone on the box has
#     none, and `plan` fails on the first variable without a default (ssh_public_keys, 2026-09-13).
#     Public keys, so config not secret, but they live where the jail keeps them: ride along.
for root in provisioning main; do
  src="$REPO/tofu/$root/terraform.tfvars"; [ "$root" = main ] && src="$REPO/tofu/terraform.tfvars"
  if [ -s "$src" ]; then
    install -m600 "$src" "$OUT/var/lib/mgmt/$root.tfvars"; echo "  + var/lib/mgmt/$root.tfvars  (← ${src#"$REPO"/})"
  else
    echo "  ! ${src#"$REPO"/} missing — the box's plan of that root will fail on its variables" >&2
  fi
done
# ⚠ Proxmox tokens ride in the tfvars, NEVER the env: a TF_VAR_ in the env that a tfvars overrides
# at plan time makes `tofu apply <saved plan>` fail with "Mismatch between input and plan variable
# value" (the env is re-read at apply, the tfvars is not — found on the box 2026-09-13). main's
# token is in main.tfvars already; provisioning's (the jail sets it via env) is appended here.
_pt="$(kp_val pve-api-token-matchbox)"; [ -n "$_pt" ] || { echo "FATAL: wallet entry pve-api-token-matchbox missing" >&2; exit 1; }
grep -q '^proxmox_api_token' "$OUT/var/lib/mgmt/provisioning.tfvars" 2>/dev/null || printf 'proxmox_api_token = "%s"\n' "$_pt" >> "$OUT/var/lib/mgmt/provisioning.tfvars"
echo "  + var/lib/mgmt/provisioning.tfvars  (+ proxmox_api_token ← pve-api-token-matchbox)"
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
# Same tree, same paths, onto the running box — tar over ssh (rsync is in neither the jail nor the
# closure, found on the first push 2026-09-13). Root extracts with --no-same-owner, so the files
# stop being the jail user's; modes travel in the archive (0600).
# ⚠ chmod ONLY the provisioned files, by name: the loops' clones, worktrees and the provider cache
# live under /var/lib/mgmt too, and a `find -type f -exec chmod 600` there stripped every
# executable bit (devbox hooks, provider binaries) — exit 126 on the box, 2026-09-13.
# Host-key pinning: the box's key IS the wallet's, so pin it from the staged .pub instead of TOFU.
KH="$OUT/known_hosts"
printf '%s %s\n' "$HOST" "$(cut -d' ' -f1,2 "$OUT/etc/ssh/ssh_host_ed25519_key.pub")" > "$KH"
tar -C "$OUT" --exclude known_hosts -cf - . \
  | ssh -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes -i "$CRED/homelab-pve-ssh/id_ed25519" "root@$HOST" \
      'tar -C / --no-same-owner --no-overwrite-dir -xf - && chmod 700 /var/lib/mgmt /var/lib/mgmt/matchbox /var/lib/mgmt/pve-ssh /var/lib/mgmt/runner-app /var/lib/mgmt/sentinel && chmod 700 /var/lib/mgmt/cred /var/lib/mgmt/cred/* && chmod 600 /var/lib/mgmt/env /var/lib/mgmt/*.tfvars /var/lib/mgmt/talosconfig /var/lib/mgmt/kubeconfig /var/lib/mgmt/matchbox/* /var/lib/mgmt/pve-ssh/* /var/lib/mgmt/runner-app/* /var/lib/mgmt/sentinel/app-key.pem /var/lib/mgmt/cred/*/* /etc/ssh/ssh_host_ed25519_key && ls -l /var/lib/mgmt'
echo "pushed to root@$HOST — units read /var/lib/mgmt/env at their next start; nothing to restart"
