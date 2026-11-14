#!/usr/bin/env bash
# Harden the self-hosted Infisical instance (idempotent). Currently: disable open
# sign-ups (only the bootstrap super admin should exist; ADR — single admin for now).
# Server admin config isn't covered by the Infisical TF provider, so it's codified here.
# Auth = a per-run super-admin login (scripts/infisical-login.sh).
#
#   devbox run infisical-harden            # assert allowSignUp=false
#   devbox run infisical-harden -- --check # read-only: print the current allowSignUp
set -euo pipefail
cd "$(dirname "$0")/.."
export NIX_CONFIG="experimental-features = nix-command flakes" DEVBOX_QUIET=1

# shellcheck source=scripts/infisical-login.sh
. ./scripts/infisical-login.sh
JQ="$(devbox run --quiet -- sh -c 'command -v jq')"

# jq -r, not -e: the healthy value IS `false`, which -e reports as exit 1.
if [ "${1:-}" = "--check" ]; then
  v="$("$CURL" -sf -H "Authorization: Bearer $INF_TOKEN" "$INF_HOST/api/v1/admin/config" | "$JQ" -r '.config.allowSignUp')"
  echo "allowSignUp = $v"
  [ "$v" = false ] || [ "$v" = true ] || exit 1
  exit 0
fi

v="$("$CURL" -sf -X PATCH \
  -H "Authorization: Bearer $INF_TOKEN" -H "Content-Type: application/json" \
  -d '{"allowSignUp": false}' "$INF_HOST/api/v1/admin/config" | "$JQ" -r '.config.allowSignUp')"
echo "allowSignUp -> $v"
[ "$v" = false ]
