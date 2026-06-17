#!/usr/bin/env bash
# Harden the self-hosted Infisical instance (idempotent). Currently: disable open
# sign-ups (only the bootstrap super admin should exist; ADR — single admin for now).
# Server admin config isn't covered by the Infisical TF provider, so it's codified here.
#
#   devbox run infisical-harden
set -euo pipefail
cd "$(dirname "$0")/.."
export NIX_CONFIG="experimental-features = nix-command flakes" DEVBOX_QUIET=1

KC=(--kubeconfig "${KUBECONFIG:-$PWD/tofu/kubeconfig}")
SVC=svc/infisical-infisical-standalone-infisical
PORT=18080

TOKEN="$(devbox run --quiet -- kubectl "${KC[@]}" -n infisical get secret infisical-bootstrap-secret -o jsonpath='{.data.token}' | base64 -d)"
[ -n "$TOKEN" ] || { echo "no instance-admin token in infisical-bootstrap-secret" >&2; exit 1; }

devbox run --quiet -- kubectl "${KC[@]}" -n infisical port-forward "$SVC" "$PORT:8080" >/tmp/inf-harden-pf.log 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT
until devbox run --quiet -- curl -sf "http://127.0.0.1:$PORT/api/status" >/dev/null 2>&1; do sleep 1; done

echo -n "allowSignUp -> "
devbox run --quiet -- curl -s -X PATCH \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"allowSignUp": false}' "http://127.0.0.1:$PORT/api/v1/admin/config" 2>/dev/null \
  | devbox run --quiet -- jq -r '.config.allowSignUp'
