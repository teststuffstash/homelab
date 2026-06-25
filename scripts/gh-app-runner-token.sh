#!/usr/bin/env bash
# Mint a GitHub Actions self-hosted-runner REGISTRATION token from a GitHub App (ADR-081/082).
#
# No human-pasted token: the CI-runner VM runs this at boot to self-register, and you can run it
# by hand to test. It's the core App-minting primitive (JWT -> installation token -> resource
# token) the agent sandboxes will reuse later for repo-scoped tokens.
#
# Inputs (env):
#   GH_APP_ID                 numeric App ID
#   GH_APP_INSTALLATION_ID    installation ID on the org
#   GH_APP_PRIVATE_KEY_FILE   path to the App private key (.pem)
#   GH_RUNNER_ORG             org login (e.g. teststuffstash)
# Output: the registration token on stdout (plain). Add --json for {"token":"..."}.
#
# Deps: openssl, curl, jq (all in devbox). openssl is used explicitly (RS256) — no interactive use.
set -euo pipefail

: "${GH_APP_ID:?}" "${GH_APP_INSTALLATION_ID:?}" "${GH_APP_PRIVATE_KEY_FILE:?}" "${GH_RUNNER_ORG:?}"
[ -r "$GH_APP_PRIVATE_KEY_FILE" ] || { echo "key not readable: $GH_APP_PRIVATE_KEY_FILE" >&2; exit 1; }

b64url() { openssl base64 -e -A | tr '+/' '-_' | tr -d '='; }

now=$(date +%s)
header='{"alg":"RS256","typ":"JWT"}'
# exp <= 10 min; iat backdated 60s for clock skew.
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$GH_APP_ID")
unsigned="$(printf '%s' "$header" | b64url).$(printf '%s' "$payload" | b64url)"
signature=$(printf '%s' "$unsigned" \
  | openssl dgst -sha256 -sign "$GH_APP_PRIVATE_KEY_FILE" -binary | b64url)
jwt="${unsigned}.${signature}"

api="https://api.github.com"
inst_token=$(curl -fsSL -X POST \
  -H "Authorization: Bearer $jwt" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "$api/app/installations/$GH_APP_INSTALLATION_ID/access_tokens" | jq -r '.token')

reg_token=$(curl -fsSL -X POST \
  -H "Authorization: token $inst_token" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "$api/orgs/$GH_RUNNER_ORG/actions/runners/registration-token" | jq -r '.token')

[ -n "$reg_token" ] && [ "$reg_token" != "null" ] || { echo "failed to mint registration token" >&2; exit 1; }

if [ "${1:-}" = "--json" ]; then
  jq -nc --arg token "$reg_token" '{token: $token}'
else
  printf '%s\n' "$reg_token"
fi
