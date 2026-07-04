#!/bin/sh
# devbox github-tofu wrapper — assemble EVERYTHING `tofu -chdir=tofu/github apply` needs, then run tofu.
# The tofu/github root is run OUTSIDE the jail (org admin rights the jail PAT lacks). One command:
#
#     devbox run github-tofu plan          # or: apply / destroy / <any tofu subcommand + args>
#
# Sibling of scripts/tf.sh (main root), same dual-path cred resolution. Sources, in order:
#   1. TF_VAR_merge_gh_app_id + TF_VAR_merge_gh_app_private_key  ← the homelab-merge cred dir
#      (~/.claude/homelab-github-merge/{app-id,private-key.pem}), written by github-merge-app-bootstrap.sh.
#      Durable source of truth for the key stays Infisical (MERGE_GH_APP_PRIVATE_KEY); this file is the copy.
#   2. GITHUB_TOKEN  ← the teststuffstash ORG ADMIN token (Administration:R/W on repos+rulesets +
#      Issues:R/W for labels), from a SEPARATE KeePass wallet. An already-set GITHUB_TOKEN wins (wallet skipped).
#
# The org-admin token lives in a SEPARATE, dedicated wallet (~/Documents/homelab-admin.kdbx, entry
# `github-homelab-admin`), unlocked by a KEYFILE (~/Documents/homelab-admin.keyx) — non-interactive, no
# prompt. Override with env if it ever moves:
#   GH_ADMIN_KP_DB=<path/to.kdbx>  GH_ADMIN_KP_KEY=<path/to.keyx, empty ⇒ password prompt>  GH_ADMIN_KP_ENTRY=<title>
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# 1. cred root (jail ~/.claude or host ~/Projects/.claude-data) — same dual-path trick as tf.sh.
CRED=""
for d in "${CLAUDE_CRED_DIR:-}" "$HOME/.claude" "$HOME/Projects/.claude-data"; do
  [ -n "$d" ] && [ -d "$d" ] && CRED="$d" && break
done
[ -n "$CRED" ] || { echo "github-tf: cred dir not found (looked in ~/.claude, ~/Projects/.claude-data; set CLAUDE_CRED_DIR)" >&2; exit 1; }

# 2. homelab-merge App id (non-secret) + private key (Tier-0 file) from the bootstrap cred dir.
MERGE_DIR="${MERGE_CRED_DIR:-$CRED/homelab-github-merge}"
[ -f "$MERGE_DIR/app-id" ] && [ -f "$MERGE_DIR/private-key.pem" ] || {
  echo "github-tf: homelab-merge creds not in $MERGE_DIR — run scripts/github-merge-app-bootstrap.sh" >&2
  echo "           (or restore private-key.pem from Infisical MERGE_GH_APP_PRIVATE_KEY + app-id from the App page)." >&2
  exit 1; }
TF_VAR_merge_gh_app_id="$(cat "$MERGE_DIR/app-id")"
TF_VAR_merge_gh_app_private_key="$(cat "$MERGE_DIR/private-key.pem")"
export TF_VAR_merge_gh_app_id TF_VAR_merge_gh_app_private_key

# 2b. homelab-deploy App (OPTIONAL — only once bootstrapped). Same cred-dir shape; drives sleep-iac's
#     deploy-bump approval bypass + the DEPLOY_APP_ID/KEY Actions secrets. Absent ⇒ the vars keep their
#     "" defaults and tofu skips both, so this root still applies before the deploy App exists.
DEPLOY_DIR="${DEPLOY_CRED_DIR:-$CRED/homelab-github-deploy}"
if [ -f "$DEPLOY_DIR/app-id" ] && [ -f "$DEPLOY_DIR/private-key.pem" ]; then
  TF_VAR_deploy_app_id="$(cat "$DEPLOY_DIR/app-id")"
  TF_VAR_deploy_app_private_key="$(cat "$DEPLOY_DIR/private-key.pem")"
  export TF_VAR_deploy_app_id TF_VAR_deploy_app_private_key
  echo "github-tf: homelab-deploy App id=$TF_VAR_deploy_app_id loaded (DEPLOY_APP_* secrets)" >&2
fi

# 2c. homelab-renovate App (OPTIONAL) → RENOVATE_APP_* secrets for the self-hosted Renovate runner.
RENOVATE_DIR="${RENOVATE_CRED_DIR:-$CRED/homelab-github-renovate}"
if [ -f "$RENOVATE_DIR/app-id" ] && [ -f "$RENOVATE_DIR/private-key.pem" ]; then
  TF_VAR_renovate_app_id="$(cat "$RENOVATE_DIR/app-id")"
  TF_VAR_renovate_app_private_key="$(cat "$RENOVATE_DIR/private-key.pem")"
  export TF_VAR_renovate_app_id TF_VAR_renovate_app_private_key
  echo "github-tf: homelab-renovate App id=$TF_VAR_renovate_app_id loaded (RENOVATE_APP_* secrets)" >&2
fi

# 2d. homelab-reviewer App (OPTIONAL, REUSED) → REVIEWER_APP_* secrets for the renovate-approve reflex.
REVIEWER_DIR="${REVIEWER_CRED_DIR:-$CRED/homelab-github-reviewer}"
if [ -f "$REVIEWER_DIR/app-id" ] && [ -f "$REVIEWER_DIR/private-key.pem" ]; then
  TF_VAR_reviewer_app_id="$(cat "$REVIEWER_DIR/app-id")"
  TF_VAR_reviewer_app_private_key="$(cat "$REVIEWER_DIR/private-key.pem")"
  export TF_VAR_reviewer_app_id TF_VAR_reviewer_app_private_key
  echo "github-tf: homelab-reviewer App id=$TF_VAR_reviewer_app_id loaded (REVIEWER_APP_* secrets)" >&2
fi

# 3. org admin token → GITHUB_TOKEN (unless already exported). Read from the separate KeePass wallet.
if [ -z "${GITHUB_TOKEN:-}" ]; then
  # The dedicated org-admin wallet (see header). Keyfile-unlocked; set GH_ADMIN_KP_KEY="" for a password wallet.
  GH_ADMIN_KP_DB="${GH_ADMIN_KP_DB:-$HOME/Documents/homelab-admin.kdbx}"
  GH_ADMIN_KP_KEY="${GH_ADMIN_KP_KEY-$HOME/Documents/homelab-admin.keyx}"
  GH_ADMIN_KP_ENTRY="${GH_ADMIN_KP_ENTRY:-github-homelab-admin}"
  [ -f "$GH_ADMIN_KP_DB" ] || { echo "github-tf: org-admin wallet $GH_ADMIN_KP_DB not found — set GH_ADMIN_KP_DB (and GH_ADMIN_KP_ENTRY / optional GH_ADMIN_KP_KEY). Or export GITHUB_TOKEN yourself." >&2; exit 1; }

  # keepassxc-cli directly if present, else via devbox (mirrors scripts/keepass-env.sh).
  if command -v keepassxc-cli >/dev/null 2>&1; then _kp() { keepassxc-cli "$@"; }
  else export DEVBOX_QUIET=1 NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"; _kp() { devbox run --quiet -- keepassxc-cli "$@"; }; fi

  if [ -n "$GH_ADMIN_KP_KEY" ] && [ -f "$GH_ADMIN_KP_KEY" ]; then
    GITHUB_TOKEN="$(_kp show -q --no-password -k "$GH_ADMIN_KP_KEY" -a Password "$GH_ADMIN_KP_DB" "$GH_ADMIN_KP_ENTRY")"
  else
    # password-protected wallet: keepassxc-cli prompts on the terminal (interactive `devbox run` is a TTY).
    GITHUB_TOKEN="$(_kp show -q -a Password "$GH_ADMIN_KP_DB" "$GH_ADMIN_KP_ENTRY")"
  fi
  export GITHUB_TOKEN
fi
[ -n "${GITHUB_TOKEN:-}" ] || { echo "github-tf: no GITHUB_TOKEN (wallet entry '$GH_ADMIN_KP_ENTRY' empty?) — need org Administration:R/W + Issues:R/W." >&2; exit 1; }

echo "github-tf: merge App id=$TF_VAR_merge_gh_app_id + key loaded; GITHUB_TOKEN set → tofu -chdir=tofu/github $*" >&2
exec tofu -chdir="$ROOT/tofu/github" "$@"
