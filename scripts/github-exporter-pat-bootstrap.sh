#!/usr/bin/env bash
# github-exporter-pat-bootstrap.sh — mint + wire the token for the in-cluster GitHub poller
# (tofu/github-exporter.tf → tofu/templates/github-exporter.py), which feeds workflow-run
# conclusions + enhanced-billing usage into Prometheus (alerts replace GitHub's failure emails).
#
# Unlike its App-bootstrap siblings (github-{agents,reviewer,merge}-app-bootstrap.sh) this is a
# FINE-GRAINED PAT, not a GitHub App: the enhanced-billing usage endpoint
# (/organizations/{org}/settings/billing/usage) wants an org-admin user token with org
# "Administration: read" (NOT "Plan" — that's the pre-enhanced-billing permission; learned via a
# 403 on 2026-07-07) — a permission App installation tokens don't get. Minting a fine-grained PAT is CLICK-ONLY
# (GitHub has no API for it), so this script drives the clicks, pushes the value to Infisical
# (the source of truth — ESO delivers it to monitoring/github-exporter-token), and verifies.
#
# The PAT (create as the org-admin user):
#   Resource owner: $ORG        Expiration: 1 year (max — the GithubExporterStale alert is the
#                                rotation reminder; re-run this script to rotate)
#   Repository access: All repositories   (the poller auto-discovers new repos — no config drift)
#   Repo permissions:  Actions: Read-only (+ Metadata: Read-only, added automatically)
#   Org permissions:   Administration: Read-only   (billing usage rides org Administration, not Plan)
#
# Subcommands:  check | create | secrets | verify
# Env (defaults): ORG=teststuffstash  INFISICAL_KEY=GITHUB_EXPORTER_TOKEN
set -euo pipefail
cd "$(dirname "$0")/.."
export GH_PAGER=cat

ORG="${ORG:-teststuffstash}"
INFISICAL_KEY="${INFISICAL_KEY:-GITHUB_EXPORTER_TOKEN}"
KC=(--kubeconfig "${KUBECONFIG:-$PWD/tofu/kubeconfig}")

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

cmd_check() {
  need curl; need devbox
  say "What this sets up"
  cat <<EOF
  1. 'create'  -> opens GitHub's fine-grained-PAT page + prints the exact settings (browser,
                  as an org admin of $ORG; token creation has no API).
  2. 'secrets' -> prompts for the token (no shell history) and pushes it to Infisical
                  ($INFISICAL_KEY). ESO then materialises monitoring/github-exporter-token
                  within its 1h refreshInterval (kick it: kubectl annotate externalsecret ...).
  3. 'verify'  -> exercises the token against both APIs, then checks the in-cluster pod.
  Deploy order doesn't matter: tofu apply first just parks the pod on the missing Secret.
EOF
}

cmd_create() {
  local url="https://github.com/settings/personal-access-tokens/new"
  say "Create the fine-grained PAT (browser, logged in as an org ADMIN of $ORG)"
  cat <<EOF
  $url

  Token name:        homelab-github-exporter
  Resource owner:    $ORG                    <- NOT your user; the org must be selected
  Expiration:        1 year (custom, the max)
  Repository access: All repositories
  Permissions:
    Repository -> Actions: Read-only         (Metadata: Read-only is added automatically)
    Organization -> Administration: Read-only  (billing 403s "not accessible" without it; Plan is NOT it)

  Then:  scripts/github-exporter-pat-bootstrap.sh secrets
EOF
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 || true
  elif command -v open >/dev/null 2>&1; then open "$url" >/dev/null 2>&1 || true; fi
}

cmd_secrets() {
  need devbox
  local token="${GITHUB_EXPORTER_TOKEN:-}"
  if [ -z "$token" ]; then
    printf 'Paste the github_pat_... value (input hidden): '
    read -rs token; echo
  fi
  [ -n "$token" ] || die "no token given"
  case "$token" in github_pat_*) ;; *) warn "value doesn't start with github_pat_ — pushing anyway" ;; esac
  say "Pushing to Infisical (homelab/prod) as $INFISICAL_KEY — the source of truth"
  devbox run infisical-secret "$INFISICAL_KEY=$token"
  say "Done. ESO refreshes within 1h; to sync now:"
  cat <<EOF
  devbox run -- kubectl ${KC[*]} -n monitoring annotate externalsecret github-exporter-token \\
      force-sync=\$(date +%s) --overwrite
  Then:  scripts/github-exporter-pat-bootstrap.sh verify
EOF
}

cmd_verify() {
  need curl; need devbox
  local token="${GITHUB_EXPORTER_TOKEN:-}"
  if [ -z "$token" ]; then
    # No arg? Verify with what the cluster actually has — that's the value that matters.
    token="$(devbox run --quiet -- kubectl "${KC[@]}" -n monitoring get secret github-exporter-token \
      -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
    [ -n "$token" ] || die "no token: cluster Secret monitoring/github-exporter-token is empty (run 'secrets' first) and GITHUB_EXPORTER_TOKEN is unset"
    echo "  (verifying the token from the in-cluster Secret)"
  fi

  say "1/3 Actions API (workflow runs on $ORG/homelab)"
  curl -sf -H "Authorization: Bearer $token" -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$ORG/homelab/actions/runs?per_page=1" >/dev/null \
    && echo "  ✅ runs readable" || die "runs 4xx — PAT lacks repo Actions:read or All-repositories access"

  say "2/3 Billing usage API (org Administration:read)"
  curl -sf -H "Authorization: Bearer $token" -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/organizations/$ORG/settings/billing/usage" >/dev/null \
    && echo "  ✅ billing readable" || die "billing 4xx — PAT lacks org Administration:read (or you're not an org admin)"

  say "3/3 In-cluster end state"
  devbox run --quiet -- kubectl "${KC[@]}" -n monitoring get externalsecret github-exporter-token \
    -o jsonpath='ExternalSecret: {.status.conditions[?(@.type=="Ready")].status}{"\n"}' || true
  devbox run --quiet -- kubectl "${KC[@]}" -n monitoring get deploy github-exporter \
    -o jsonpath='Deployment ready: {.status.readyReplicas}/{.spec.replicas}{"\n"}' || true
  echo "  Green ⇒ Prometheus target 'github-exporter' turns up within ~2 min; alerts: monitoring.tf ▸ github group."
}

case "${1:-check}" in
  check)   cmd_check ;;
  create)  cmd_create ;;
  secrets) cmd_secrets ;;
  verify)  cmd_verify ;;
  *) die "unknown subcommand '$1' (check|create|secrets|verify)" ;;
esac
