#!/bin/sh
# devbox github-tofu wrapper — assemble EVERYTHING `tofu -chdir=tofu/github apply` needs, then run tofu.
# The tofu/github root is run OUTSIDE the jail (org admin rights the jail PAT lacks). One command:
#
#     devbox run github-tofu plan          # or: apply / destroy / <any tofu subcommand + args>
#
# Sibling of scripts/tf.sh (main root), same dual-path cred resolution. Sources, in order:
#   1. (retired 2026-08-26, ADR-111/homelab#745 — the merge-App org secrets are gone from this root)
#   2. GITHUB_TOKEN  ← the teststuffstash ORG ADMIN token (Administration:R/W on repos+rulesets + Contents:R/W (security.tf) +
#      Issues:R/W for labels), from a SEPARATE KeePass wallet. An already-set GITHUB_TOKEN wins (wallet skipped).
#
# The org-admin token lives in a SEPARATE, dedicated wallet (~/Documents/homelab-admin.kdbx, entry
# `github-homelab-admin`), unlocked by a KEYFILE (~/Documents/homelab-admin.keyx) — non-interactive, no
# prompt. Override with env if it ever moves:
#   GH_ADMIN_KP_DB=<path/to.kdbx>  GH_ADMIN_KP_KEY=<path/to.keyx, empty ⇒ password prompt>  GH_ADMIN_KP_ENTRY=<title>
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# 0. Currency guard (2026-10-16): the root applies from THIS checkout, and on the host that is the
#    shared ~/Projects/homelab tree, which nothing keeps current. A PR merged on origin but not pulled
#    here reads as "0 changed" — the circles reviewer-secret apply (#2639) did exactly that. So
#    plan/apply/destroy REFUSE while origin/master carries tofu/github commits HEAD lacks.
#    GITHUB_TF_ALLOW_STALE=1 overrides (applying a deliberate local state); a failed fetch only warns.
case "${1:-}" in
  plan|apply|destroy)
    if git -C "$ROOT" fetch -q origin master 2>/dev/null; then
      _missing=$(git -C "$ROOT" rev-list --count HEAD..FETCH_HEAD -- tofu/github)
      if [ "$_missing" -gt 0 ] && [ "${GITHUB_TF_ALLOW_STALE:-}" != 1 ]; then
        echo "github-tf: REFUSED — this checkout lacks $_missing origin/master commit(s) touching tofu/github:" >&2
        git -C "$ROOT" log --oneline HEAD..FETCH_HEAD -- tofu/github >&2
        echo "github-tf: pull first (git -C $ROOT pull --rebase), or GITHUB_TF_ALLOW_STALE=1 to run on this tree anyway." >&2
        exit 1
      fi
    else
      echo "github-tf: WARN — could not fetch origin/master; currency of tofu/github unchecked." >&2
    fi
    ;;
esac

# FU-001: the reviewer cred dir is a wallet-materialized cache — regenerate missing files first
# (best-effort; merge/deploy/renovate stay host-side flat files, outside the jail wallet's scope).
bash "$ROOT/scripts/wallet-files.sh" >/dev/null 2>&1 || true

# 1. Resolve EACH App cred dir independently across the candidate roots. Creds can be SPLIT: an App
#    bootstrapped on the HOST lands in the host ~/.claude, one bootstrapped in the JAIL lands in
#    ~/Projects/.claude-data (the jail's ~/.claude, volume-mounted) — the same file may not be under a
#    single root. So never assume one root holds them all (the old single-CRED pick missed the reviewer).
_find_cred() { # $1 = subdir (e.g. homelab-github-reviewer) → echo the dir holding app-id + private-key.pem
  _sub="$1"
  for _d in "${CLAUDE_CRED_DIR:-}" "$HOME/.claude" "$HOME/Projects/.claude-data"; do
    [ -n "$_d" ] && [ -f "$_d/$_sub/app-id" ] && [ -f "$_d/$_sub/private-key.pem" ] || continue
    printf '%s\n' "$_d/$_sub"; return 0
  done
  return 1
}

# 2. homelab-merge App: RETIRED from this root 2026-08-26 (ADR-111 cutover, homelab#745) — the
#    MERGE_GH_APP_* org secrets are gone; the in-cluster updater sources the key via Infisical→ESO.
#    The cred dir (~/.claude/homelab-github-merge/) stays as the bootstrap copy for the App itself.

# 2b-d. deploy / renovate / reviewer Apps (OPTIONAL) → their *_APP_* Actions secrets. Absent ⇒ the tofu
#       vars keep their "" defaults and the count-gated secrets are skipped, so the root still applies.
if DIR="$(_find_cred homelab-github-deploy)"; then
  TF_VAR_deploy_app_id="$(cat "$DIR/app-id")"; TF_VAR_deploy_app_private_key="$(cat "$DIR/private-key.pem")"
  export TF_VAR_deploy_app_id TF_VAR_deploy_app_private_key
  echo "github-tf: homelab-deploy App id=$TF_VAR_deploy_app_id loaded (DEPLOY_APP_* secrets) from $DIR" >&2
fi
if DIR="$(_find_cred homelab-github-renovate)"; then
  TF_VAR_renovate_app_id="$(cat "$DIR/app-id")"; TF_VAR_renovate_app_private_key="$(cat "$DIR/private-key.pem")"
  export TF_VAR_renovate_app_id TF_VAR_renovate_app_private_key
  echo "github-tf: homelab-renovate App id=$TF_VAR_renovate_app_id loaded (RENOVATE_APP_* secrets) from $DIR" >&2
fi
if DIR="$(_find_cred homelab-github-reviewer)"; then
  TF_VAR_reviewer_app_id="$(cat "$DIR/app-id")"; TF_VAR_reviewer_app_private_key="$(cat "$DIR/private-key.pem")"
  export TF_VAR_reviewer_app_id TF_VAR_reviewer_app_private_key
  echo "github-tf: homelab-reviewer App id=$TF_VAR_reviewer_app_id loaded (REVIEWER_APP_* secrets) from $DIR" >&2
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

# FU-238 (2026-09-13): the root's state moved to the encrypted Garage backend (tofu/github/backend.tf,
# use_lockfile=false — the single-writer ruling, docs/tofu-state.md). Same as scripts/tf.sh: source
# the per-ROOT state env (S3 credential + TF_ENCRYPTION, wallet-read; a pre-set environment wins)
# and init here, after the credentials exist — a bare `tofu init` has none and dies first.
TOFU_STATE_ROOT_DIR="$ROOT/tofu/github" . "$ROOT/scripts/tofu-state-env.sh" || exit 1
tofu -chdir="$ROOT/tofu/github" init -input=false >&2
echo "github-tf: GITHUB_TOKEN set → tofu -chdir=tofu/github $*" >&2
[ "${1:-}" = apply ] || exec tofu -chdir="$ROOT/tofu/github" "$@"
tofu -chdir="$ROOT/tofu/github" "$@" || exit $?

# After a successful apply: GitHub private vulnerability reporting ON for every public repo in the org
# (tofu/github/security.tf says why it lives here — no provider resource, provisioners refused). The
# PUT is idempotent; PVR exists for public repos only; never turned off here (one-way, deliberately).
ORG="${TF_VAR_org:-teststuffstash}"   # tofu/github/variables.tf var.org default
repos="$(curl -fsS -H "Authorization: Bearer $GITHUB_TOKEN" -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/orgs/$ORG/repos?type=public&per_page=100" | jq -r '.[] | select(.archived | not) | .full_name')" \
  || { echo "github-tf: PVR — listing public repos failed" >&2; exit 1; }
for r in $repos; do
  curl -fsS -o /dev/null -X PUT -H "Authorization: Bearer $GITHUB_TOKEN" -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$r/private-vulnerability-reporting" \
    || { echo "github-tf: PVR enable failed on $r" >&2; exit 1; }
  echo "github-tf: PVR on: $r" >&2
done
