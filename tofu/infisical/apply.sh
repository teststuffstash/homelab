#!/usr/bin/env bash
# Run the Infisical content-as-code root. Mirrors the app-owned-resources pattern:
# port-forward the in-cluster Infisical, derive the provider auth from the live
# instance, then run tofu. State is local + gitignored (holds the client secret).
#
#   bash tofu/infisical/apply.sh plan
#   bash tofu/infisical/apply.sh apply
#
# Provider auth = the bootstrap-created Instance Admin Identity token (non-expiring),
# read from the infisical-bootstrap-secret. No secrets are passed on the CLI.
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root
export NIX_CONFIG="experimental-features = nix-command flakes" DEVBOX_QUIET=1

KUBECONFIG_PATH="${KUBECONFIG:-$PWD/tofu/kubeconfig}"
KC=(--kubeconfig "$KUBECONFIG_PATH")
SVC=svc/infisical-infisical-standalone-infisical
PORT=18080

TOKEN="$(devbox run --quiet -- kubectl "${KC[@]}" -n infisical get secret infisical-bootstrap-secret -o jsonpath='{.data.token}' | base64 -d)"
[ -n "$TOKEN" ] || { echo "no instance-admin token in infisical-bootstrap-secret — is autoBootstrap done?" >&2; exit 1; }

echo "port-forward $SVC -> 127.0.0.1:$PORT"
devbox run --quiet -- kubectl "${KC[@]}" -n infisical port-forward "$SVC" "$PORT:8080" >/tmp/inf-pf.log 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT
until devbox run --quiet -- curl -sf "http://127.0.0.1:$PORT/api/status" >/dev/null 2>&1; do sleep 1; done

# org id isn't in the token (organizationId=null) and the list-orgs API is restricted for
# a machine identity, so read it from the Infisical DB (any CNPG instance can SELECT it).
PGPOD="$(devbox run --quiet -- kubectl "${KC[@]}" -n infisical get pods -l cnpg.io/cluster=infisical-pg -o jsonpath='{.items[0].metadata.name}')"
ORG_ID="$(devbox run --quiet -- kubectl "${KC[@]}" -n infisical exec "$PGPOD" -c postgres -- \
  psql -U postgres -d infisical -tAc 'select id from organizations order by "createdAt" limit 1;' | tr -d '[:space:]')"
[ -n "$ORG_ID" ] || { echo "could not derive org id from the Infisical DB" >&2; exit 1; }
echo "org=$ORG_ID host=http://127.0.0.1:$PORT"

export TF_VAR_infisical_host="http://127.0.0.1:$PORT"
export TF_VAR_infisical_token="$TOKEN"
export TF_VAR_infisical_org_id="$ORG_ID"
export TF_VAR_kubeconfig="$KUBECONFIG_PATH"

devbox run --quiet -- tofu -chdir=tofu/infisical init -input=false >/tmp/inf-init.log 2>&1 || { cat /tmp/inf-init.log; exit 1; }
devbox run --quiet -- tofu -chdir=tofu/infisical "$@"
