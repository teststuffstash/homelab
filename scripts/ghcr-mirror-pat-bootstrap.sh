#!/usr/bin/env bash
# ghcr-mirror-pat-bootstrap.sh — mint + wire the upstream credential that lets the ghcr
# pull-through mirror (argocd/resources/registry-cache/mirror-ghcr.yaml, ADR-091) serve the
# org's PRIVATE images — today the oracle corpus (ghcr.io/teststuffstash/oracle-fleet/ert-corpus,
# ~6GB) and the serving image (oracle-fleet-ingester). FU-196 v0: without this, Talos nodes fall
# back to pulling private images from ghcr directly, so a serving-pod move during a ghcr
# outage/429 storm degrades the oracle endpoint (observed 2026-08-30, oracle-fleet#274 bring-up).
#
# Like github-exporter-pat-bootstrap.sh this drives a CLICK-ONLY mint, pushes the value to
# Infisical (source of truth — ESO delivers registry-cache/mirror-ghcr-upstream-auth), and
# verifies. ghcr does NOT accept fine-grained PATs — this must be a CLASSIC PAT, read:packages.
#
# The scoping decision happens at mint time (operator):
#   RECOMMENDED — a MACHINE USER granted per-package Read on ONLY the two packages: the mirror
#     then exposes exactly those to the anonymous LAN (the consequence ADR-091's update accepts).
#   SHORTCUT — a classic PAT on an org-admin account: works identically, but every org package
#     the admin can read becomes LAN-readable through the cache. Bigger consequence, same ADR.
#
# Consequence either way: registry:3 proxy auth is UPSTREAM-only — the mirror itself still
# serves cached content to any LAN/cluster client unauthenticated.
#
# Expiry: recorded as a declared value (GHCR_MIRROR_PULL_EXPIRY) for the FU-156 belt; until
# that gauge exists, rotation is "re-run this script" when the mint reminder fires.
#
# Subcommands:  check | create | secrets | verify [corpus-digest]
# Env (defaults): ORG=teststuffstash  MIRROR=http://192.168.40.21
set -euo pipefail
cd "$(dirname "$0")/.."
export GH_PAGER=cat

ORG="${ORG:-teststuffstash}"
MIRROR="${MIRROR:-http://192.168.40.21}"
PKG_CORPUS="oracle-fleet/ert-corpus"
PKG_INGESTER="oracle-fleet-ingester"
KC=(--kubeconfig "${KUBECONFIG:-$PWD/tofu/kubeconfig}")

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

cmd_check() {
  say "What this sets up"
  cat <<EOF
  1. 'create'  -> prints the exact click path (browser; classic PAT, read:packages) and the
                  per-package access grants for a machine-user mint.
  2. 'secrets' -> prompts for username + token + expiry (no shell history) and pushes
                  GHCR_MIRROR_PULL_{USERNAME,TOKEN,EXPIRY} to Infisical. ESO materialises
                  registry-cache/mirror-ghcr-upstream-auth within its 1h refreshInterval.
                  Then BOUNCE the mirror pod: the env rides 'optional: true' secretKeyRefs,
                  which only land on pod (re)start (the FU-190 class):
                    devbox run -- kubectl ${KC[*]} -n registry-cache delete pod -l app=mirror-ghcr
  3. 'verify'  -> token direct against ghcr for BOTH packages, then the real proof: an
                  ANONYMOUS manifest GET through the mirror VIP ($MIRROR).
  Deploy order never breaks the mirror: without the secret it keeps proxying anonymously.
EOF
}

cmd_create() {
  say "Mint (browser, click-only — classic PAT; ghcr ignores fine-grained PATs)"
  cat <<EOF
  RECOMMENDED (machine user; scopes LAN exposure to exactly these two packages):
    1. Sign in as the machine user (create one if the org has none).
    2. As an org admin, grant it per-package READ:
         https://github.com/orgs/$ORG/packages/container/${PKG_CORPUS//\//%2F}/settings
         https://github.com/orgs/$ORG/packages/container/$PKG_INGESTER/settings
       ("Manage Actions access"/"Invite teams or people" -> the machine user -> Read)
    3. As the machine user: https://github.com/settings/tokens/new
         Note: ghcr-mirror-pull (FU-196)   Expiration: 1 year   Scope: read:packages ONLY
  SHORTCUT (org-admin classic PAT): step 3 only, as yourself — but then EVERY org package
  you can read becomes LAN-readable through the cache. Say which you chose in the ADR row.
  Then run: bash scripts/ghcr-mirror-pat-bootstrap.sh secrets
EOF
}

cmd_secrets() {
  need devbox
  printf 'GitHub username the PAT belongs to: '; read -r GH_USER
  printf 'Token (ghp_..., input hidden): ';       read -rs GH_TOKEN; echo
  printf 'Expiry date (YYYY-MM-DD, from the mint page): '; read -r GH_EXPIRY
  [ -n "$GH_USER" ] && [ -n "$GH_TOKEN" ] && [ -n "$GH_EXPIRY" ] || die "all three are required"
  say "Pushing to Infisical (homelab project, prod env)"
  devbox run infisical-secret "GHCR_MIRROR_PULL_USERNAME=$GH_USER" \
                              "GHCR_MIRROR_PULL_TOKEN=$GH_TOKEN" \
                              "GHCR_MIRROR_PULL_EXPIRY=$GH_EXPIRY"
  say "Done. ESO refreshes within 1h; kick it + bounce the mirror pod:"
  cat <<EOF
  devbox run -- kubectl ${KC[*]} -n registry-cache annotate externalsecret mirror-ghcr-upstream-auth force-sync=\$(date +%s) --overwrite
  devbox run -- kubectl ${KC[*]} -n registry-cache delete pod -l app=mirror-ghcr
  bash scripts/ghcr-mirror-pat-bootstrap.sh verify
EOF
}

cmd_verify() {
  need curl; need jq
  local digest="${1:-}"
  say "1/3 token direct against ghcr (both packages resolve a token + manifest HEAD)"
  local user token
  user=$(devbox run -- kubectl "${KC[@]}" -n registry-cache get secret mirror-ghcr-upstream-auth -o jsonpath='{.data.username}' | base64 -d) || die "secret not materialised (ESO synced?)"
  token=$(devbox run -- kubectl "${KC[@]}" -n registry-cache get secret mirror-ghcr-upstream-auth -o jsonpath='{.data.password}' | base64 -d)
  for pkg in "$PKG_CORPUS" "$PKG_INGESTER"; do
    local t
    t=$(curl -sf -u "$user:$token" "https://ghcr.io/token?scope=repository:$ORG/$pkg:pull" | jq -r .token) || die "token exchange failed for $pkg"
    curl -sf -o /dev/null -H "Authorization: Bearer $t" \
      -H "Accept: application/vnd.oci.image.index.v1+json" \
      -H "Accept: application/vnd.oci.image.manifest.v1+json" \
      -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
      -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
      "https://ghcr.io/v2/$ORG/$pkg/tags/list" || die "authed tags/list failed for $pkg"
    echo "  $pkg: OK"
  done
  say "2/3 mirror pod started AFTER the secret existed (optional secretKeyRef only resolves at pod start)"
  # The env NAMES sit in the pod spec whether or not the secret resolved — a spec grep false-passes
  # on a pod that rolled before the mint (bitten 2026-08-30, first verify run). Compare timestamps.
  local pod_start sec_created
  pod_start=$(devbox run -- kubectl "${KC[@]}" -n registry-cache get pod -l app=mirror-ghcr -o jsonpath='{.items[0].status.startTime}')
  sec_created=$(devbox run -- kubectl "${KC[@]}" -n registry-cache get secret mirror-ghcr-upstream-auth -o jsonpath='{.metadata.creationTimestamp}')
  if [ -n "$pod_start" ] && [ -n "$sec_created" ] && [ "$pod_start" \< "$sec_created" ]; then
    warn "pod started ($pod_start) BEFORE the secret existed ($sec_created) — its env is empty; bounce it (see 'check') and re-run verify"
  else
    echo "  pod start $pod_start >= secret $sec_created: OK"
  fi
  say "3/3 ANONYMOUS pull of a private manifest through the mirror ($MIRROR)"
  if [ -z "$digest" ]; then
    digest=$(grep -oE 'sha256:[0-9a-f]{64}' "$PWD/../oracle-iac/values/oracle-fleet-ingester.yaml" 2>/dev/null | head -1) || true
    [ -n "$digest" ] || die "pass the corpus digest as arg (couldn't read oracle-iac values)"
  fi
  curl -sf -o /dev/null \
    -H "Accept: application/vnd.oci.image.manifest.v1+json" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    "$MIRROR/v2/$ORG/$PKG_CORPUS/manifests/$digest" \
    && say "PASS — the mirror serves the private corpus to the LAN (FU-196 v0 live)" \
    || die "mirror could not serve $digest (pod bounced? creds right? see mirror logs)"
}

case "${1:-check}" in
  check)   cmd_check ;;
  create)  cmd_create ;;
  secrets) cmd_secrets ;;
  verify)  shift || true; cmd_verify "${1:-}" ;;
  *) die "usage: $0 {check|create|secrets|verify [corpus-digest]}" ;;
esac
