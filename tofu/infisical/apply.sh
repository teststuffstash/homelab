#!/usr/bin/env bash
# Run the Infisical content-as-code root. Mirrors the app-owned-resources pattern:
# port-forward the in-cluster Infisical, derive the provider auth from the live
# instance, then run tofu. State lives in Garage, encrypted (FU-012, docs/tofu-state.md) — it holds
# the client secret, which is precisely why it is not a plaintext file any more.
#
#   bash tofu/infisical/apply.sh plan
#   bash tofu/infisical/apply.sh apply
#
# Provider auth = a per-run super-admin USER login (scripts/infisical-login.sh: wallet creds as
# env, session token lives only for this run). The bootstrap instance-admin token is dead —
# Infisical >= chart 1.12 caps machine-identity tokens at 90d (docs/secrets.md). No secrets are
# passed on the CLI.
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root
export NIX_CONFIG="experimental-features = nix-command flakes" DEVBOX_QUIET=1

KUBECONFIG_PATH="${KUBECONFIG:-$PWD/tofu/kubeconfig}"
# shellcheck source=scripts/infisical-login.sh
. ./scripts/infisical-login.sh
echo "org=$INF_ORG_ID host=$INF_HOST"

export TF_VAR_infisical_host="$INF_HOST"
export TF_VAR_infisical_token="$INF_TOKEN"
export TF_VAR_infisical_org_id="$INF_ORG_ID"
export TF_VAR_kubeconfig="$KUBECONFIG_PATH"

# FU-012: this root's state moved to Garage (2026-08-04), so `init` needs the S3 credential and the
# decryption passphrase before it can read anything. TOFU_STATE_ROOT_DIR is what switches encryption
# on — it keys off this root's backend.tf, so the same line is a no-op on a root that hasn't moved.
export TOFU_STATE_ROOT_DIR="$PWD/tofu/infisical"
. ./scripts/tofu-state-env.sh

devbox run --quiet -- tofu -chdir=tofu/infisical init -input=false >/tmp/inf-init.log 2>&1 || { cat /tmp/inf-init.log; exit 1; }
devbox run --quiet -- tofu -chdir=tofu/infisical "$@"
