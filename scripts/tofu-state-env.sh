# shellcheck shell=bash
# Source me:  . scripts/tofu-state-env.sh
#
# Exports the S3 credentials + endpoint that OpenTofu's `backend "s3"` needs to reach the homelab
# Garage (FU-012). Keeping them in the ENVIRONMENT rather than in `backend.tf` is what lets the
# backend block be committed to a PUBLIC repo: the generated backend.tf carries only bucket, key,
# region, endpoint and the skip_* flags — never a credential.
#
# Design + migration runbook: docs/tofu-state.md.
#
# Resolution order for the key, most durable first:
#   1. the KeePass wallet (Tier-0, docs/secrets.md)      — entries tofu-state-key-id / tofu-state-secret
#   2. the Crossplane connection Secret in-cluster        — bootstrap only, and it says so out loud
# Returns non-zero (without killing your shell) when neither yields a key.

_ts_dir=""
for _d in "${KP_DIR:-}" "$HOME/.claude/homelab-keepass" "$HOME/Projects/.claude-data/homelab-keepass"; do
  [ -n "$_d" ] && [ -f "$_d/homelab.kdbx" ] && _ts_dir="$_d" && break
done

export DEVBOX_QUIET=1
export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"

if command -v keepassxc-cli >/dev/null 2>&1; then
  _ts_kp() { keepassxc-cli "$@"; }
else
  _ts_kp() { devbox run --quiet -- keepassxc-cli "$@"; }
fi
# Always exits 0. A missing wallet entry is an ordinary outcome here (the key may not be minted
# yet), and this file is SOURCED by scripts running `set -e` — a non-zero command substitution
# would kill the caller before it could print why. Learned the hard way, 2026-08-04: the first
# dry run died silently at this line.
_ts_get() {
  [ -n "$_ts_dir" ] || return 0
  _ts_kp show -q --no-password -k "$_ts_dir/homelab.keyx" -a Password "$_ts_dir/homelab.kdbx" "$1" 2>/dev/null || true
}

AWS_ACCESS_KEY_ID="${TOFU_STATE_KEY_ID:-$(_ts_get tofu-state-key-id)}"
AWS_SECRET_ACCESS_KEY="${TOFU_STATE_SECRET:-$(_ts_get tofu-state-secret)}"

# Bootstrap fallback: the key Crossplane just minted, straight from its connection Secret. This is
# for the FIRST run only — a credential that lives only in a k8s Secret is not recoverable when the
# cluster is what you are trying to rebuild, which is the whole point of remote state.
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
  _ts_kc="${KUBECONFIG:-$PWD/tofu/kubeconfig}"
  if [ -f "$_ts_kc" ] && command -v kubectl >/dev/null 2>&1; then
    AWS_ACCESS_KEY_ID="$( { kubectl --kubeconfig "$_ts_kc" -n crossplane-system get secret tofu-state-s3 -o jsonpath='{.data.access_key_id}' 2>/dev/null | base64 -d; } || true)"
    AWS_SECRET_ACCESS_KEY="$( { kubectl --kubeconfig "$_ts_kc" -n crossplane-system get secret tofu-state-s3 -o jsonpath='{.data.secret_access_key}' 2>/dev/null | base64 -d; } || true)"
    [ -n "$AWS_ACCESS_KEY_ID" ] && cat >&2 <<'EOF'
tofu-state-env: ⚠ using the in-cluster connection Secret, NOT the wallet. Persist it now:
    kubectl --kubeconfig tofu/kubeconfig -n crossplane-system get secret tofu-state-s3 \
      -o jsonpath='{.data.access_key_id}' | base64 -d
    kubectl --kubeconfig tofu/kubeconfig -n crossplane-system get secret tofu-state-s3 \
      -o jsonpath='{.data.secret_access_key}' | base64 -d
  → store as wallet entries `tofu-state-key-id` / `tofu-state-secret` (scripts/keepass-init.sh).
EOF
  fi
fi

if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
  echo "tofu-state-env: no Garage state key — wallet entries tofu-state-{key-id,secret} missing and the tofu-state-s3 Secret is unreadable." >&2
  unset -f _ts_kp _ts_get 2>/dev/null
  return 1 2>/dev/null || exit 1
fi

# ---------------------------------------------------------------------------
# State encryption (the "encrypted" half of FU-012) — OpenTofu-native, so it does NOT depend on the
# backend supporting SSE. Garage has no server-side encryption, and this is the reason that doesn't
# matter: tofu encrypts the payload before it ever leaves the process (verified 2026-08-04 — the
# written state carries `encrypted_data` and no readable resource attributes).
#
# The whole encryption block rides in TF_ENCRYPTION rather than in a committed .tf file, because a
# passphrase in a public repo is not a passphrase. Wallet entry: `tofu-state-passphrase`.
#
# The unencrypted FALLBACK is opt-in and temporary: it is what lets a migration read the existing
# plaintext state once. Left on permanently it would silently accept a plaintext state forever, so
# it is off by default — set TOFU_STATE_ENC_FALLBACK=1 for the migrating run only.
# Encryption is PER ROOT, not per shell. Exporting TF_ENCRYPTION globally broke `devbox run tf-plan`
# the moment the passphrase existed: the main root's state is still plaintext, and tofu refuses an
# "unencrypted payload without unencrypted method configured". So `auto` (the default) turns it on
# only for a root that has already migrated — `backend.tf` present means the migration wrote its
# state encrypted. Callers name the root via TOFU_STATE_ROOT_DIR; `on` forces it (the migration
# itself needs the passphrase BEFORE it writes backend.tf).
#
# Sourcing this with no root named yields no TF_ENCRYPTION, so a migrated root then fails LOUDLY on
# read rather than being rewritten in plaintext. Fail-closed in the direction that matters.
_ts_enc="${TOFU_STATE_ENC:-auto}"
if [ "$_ts_enc" = auto ]; then
  if [ -n "${TOFU_STATE_ROOT_DIR:-}" ] && [ -f "${TOFU_STATE_ROOT_DIR}/backend.tf" ]; then
    _ts_enc=on
  else
    _ts_enc=off
  fi
fi

_ts_pass=""
if [ "$_ts_enc" = on ]; then
  _ts_pass="${TOFU_STATE_PASSPHRASE:-$(_ts_get tofu-state-passphrase)}"
fi

# if/elif rather than `[ … ] && x=y`: this file is SOURCED into `set -e` scripts, where a trailing
# false test is an aborting command rather than a skipped assignment.
if [ "$_ts_enc" = on ] && [ -n "$_ts_pass" ]; then
  _ts_fallback=""
  if [ "${TOFU_STATE_ENC_FALLBACK:-0}" = "1" ]; then
    _ts_fallback='fallback { method = method.unencrypted.migrate }'
  fi
  TF_ENCRYPTION="$(cat <<EOF
key_provider "pbkdf2" "wallet" {
  passphrase = "${_ts_pass}"
}
method "aes_gcm" "primary" {
  keys = key_provider.pbkdf2.wallet
}
method "unencrypted" "migrate" {}
state {
  method = method.aes_gcm.primary
  ${_ts_fallback}
}
plan {
  method = method.aes_gcm.primary
  ${_ts_fallback}
}
EOF
)"
  export TF_ENCRYPTION
elif [ "$_ts_enc" = on ]; then
  echo "tofu-state-env: ⚠ no \`tofu-state-passphrase\` in the wallet — state would be written UNENCRYPTED." >&2
fi

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_REGION="${AWS_REGION:-garage}" AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-garage}"
# Overriding the endpoint by env (not in backend.tf) keeps ONE committed backend block usable from
# the jail, the host, and a port-forward: `AWS_ENDPOINT_URL_S3=http://127.0.0.1:3900 …`.
export AWS_ENDPOINT_URL_S3="${AWS_ENDPOINT_URL_S3:-${GARAGE_S3_ENDPOINT:-https://s3.teststuff.net}}"
# Garage is not AWS: no IMDS, no STS, no account id. Without this the SDK spends its retry budget
# on 169.254.169.254 before failing with an error that names the wrong thing.
export AWS_EC2_METADATA_DISABLED=true

unset -f _ts_kp _ts_get
unset _ts_dir _ts_kc _ts_pass _ts_fallback _d
