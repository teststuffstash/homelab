#!/usr/bin/env bash
# Set/update secret(s) in the homelab Infisical project (prod env, path / by default).
# Auth = the bootstrap instance-admin token (read from the in-cluster secret); reaches
# Infisical via a short-lived port-forward. No secrets on the CLI history beyond your value.
#
#   devbox run infisical-secret API_TOKEN=s3cr3t
#   devbox run infisical-secret KEY1=val1 KEY2=val2
#   INFISICAL_ENV=staging INFISICAL_PATH=/svc devbox run infisical-secret KEY=val
#
# Then consume it with an ExternalSecret (see argocd/resources/extras/demo-externalsecret.yaml).
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -ge 1 ] || { echo "usage: $0 KEY=VALUE [KEY2=VALUE2 ...]   (env: INFISICAL_ENV=prod INFISICAL_PATH=/)" >&2; exit 2; }
export NIX_CONFIG="experimental-features = nix-command flakes" DEVBOX_QUIET=1

KC=(--kubeconfig "${KUBECONFIG:-$PWD/tofu/kubeconfig}")
SVC=svc/infisical-infisical-standalone-infisical
PORT=18080

TOKEN="$(devbox run --quiet -- kubectl "${KC[@]}" -n infisical get secret infisical-bootstrap-secret -o jsonpath='{.data.token}' | base64 -d)"
[ -n "$TOKEN" ] || { echo "no instance-admin token in infisical-bootstrap-secret" >&2; exit 1; }
PGPOD="$(devbox run --quiet -- kubectl "${KC[@]}" -n infisical get pods -l cnpg.io/cluster=infisical-pg -o jsonpath='{.items[0].metadata.name}')"
PROJECT_ID="$(devbox run --quiet -- kubectl "${KC[@]}" -n infisical exec "$PGPOD" -c postgres -- \
  psql -U postgres -d infisical -tAc "select id from projects where slug='homelab';" | tr -d '[:space:]')"
[ -n "$PROJECT_ID" ] || { echo "homelab project not found" >&2; exit 1; }

devbox run --quiet -- kubectl "${KC[@]}" -n infisical port-forward "$SVC" "$PORT:8080" >/tmp/inf-secret-pf.log 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT
until devbox run --quiet -- curl -sf "http://127.0.0.1:$PORT/api/status" >/dev/null 2>&1; do sleep 1; done

devbox run --quiet -- infisical secrets set "$@" \
  --projectId "$PROJECT_ID" --token "$TOKEN" \
  --domain "http://127.0.0.1:$PORT/api" \
  --env "${INFISICAL_ENV:-prod}" --path "${INFISICAL_PATH:-/}"
