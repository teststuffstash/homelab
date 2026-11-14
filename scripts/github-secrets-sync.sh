#!/bin/bash
# github-secrets-sync.sh — sync cluster-minted credentials into CI repo secrets: GitHub Actions,
# and Forgejo Actions for rows whose repo is written `forgejo:<owner>/<repo>` (the name predates
# the second forge; it stays because every pointer below names it).
#
#     devbox run github-secrets-sync                     # sync every mapping row (HOST-side)
#     devbox run github-secrets-sync -- --check          # inventory + source probe (jail-safe)
#     devbox run github-secrets-sync -- --forge forgejo  # only the Forgejo rows (jail-safe)
#
# THE MAPPING TABLE BELOW IS THE ONE HOME of "which repo secret is a copy of which cluster
# credential" (operator direction 2026-08-26, after the 08-24 Garage rebuild left three stale
# copies that had to be re-derived by hand — docs/garage.md §metadata-restore sweep, third
# consumer class). docs/github-setup.md and the garage restore runbook POINT here; new-stack.sh
# step G adds a row here when a stack grows a publish workflow.
#
# Design (docs/github-setup.md §Garage-read secrets — the ruling this script implements rather
# than replaces): the VALUE's source of truth is the Crossplane Workspace connection Secret,
# never KeePass/tofu — a GitHub Actions secret is a write-only COPY that no reconcile can heal,
# so re-creation of the cluster key (rotation, a metadata restore) makes every copy stale. This
# script makes re-syncing the copies one command instead of an archaeology session.
#
# Runs HOST-side: the jail PAT deliberately lacks the GitHub Secrets permission (verified 403,
# docs/github-setup.md), so `gh secret set` needs the operator's own gh auth (or a
# secrets-capable GITHUB_TOKEN in env — gh honours it). A 403 fails loudly per row, never
# silently. Cluster reads ride tofu/kubeconfig, present on both sides of the jail boundary.
#
# Forgejo rows write through the Forgejo API (`PUT /repos/<o>/<r>/actions/secrets/<name>`) with the
# wallet's `forgejo-api-token` (owner identity), so they run from the jail too. The token and the
# value travel as a 0600 header file and stdin, never argv. --check on a Forgejo row also lists
# the repo's secret NAMES (write-only values; the names are the copy's existence proof). Why a
# copy and not an ESO PushSecret: that would park a token with repo WRITE on the target in the
# cluster (Forgejo token scopes are per-scope, not per-repo) — for rasmus/life, exactly the
# cluster access the publish model exists to avoid.
set -euo pipefail
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
KUBE=(kubectl --kubeconfig "$ROOT/tofu/kubeconfig")

# ── THE MAPPING ─────────────────────────────────────────────────────────────────────────────
# repo | namespace | connection Secret | pair (reader|writer) | GitHub secret prefix
# The pair picks which half of the connection Secret ships: <pair>_access_key_id and
# <pair>_secret_access_key → <PREFIX>_ACCESS_KEY_ID and <PREFIX>_SECRET_ACCESS_KEY.
# ⚠ Pick the right half (docs/github-setup.md): a READER pair authenticates and then 403s on
# PUT — publishers take writer, fetch-only workflows take reader.
MAPPING="
forgejo:rasmus/life         | circles      | circles-source-s3 | writer | CIRCLES_SOURCE_S3
teststuffstash/oracle-fleet | oracle-fleet | allure-reports-s3 | writer | ALLURE_S3
teststuffstash/oracle-fleet | oracle-fleet | ert-snapshots-s3  | reader | ERT_S3_READER
teststuffstash/circles      | circles      | circles-specs-s3  | writer | SPECS_S3
teststuffstash/homelab      | agent-egress | gateway-specs-s3  | writer | GATEWAY_SPECS_S3
"

# ── SINGLE-VALUE MAPPINGS ───────────────────────────────────────────────────────────────────
# Same contract as the pair table above, for credentials that are ONE value, not an S3 pair:
# repo | namespace | Secret | key in Secret | GitHub secret name
# Source of truth for these is Infisical (ESO materializes the cluster Secret this reads) —
# same write-only-copy rationale, same host-side requirement, same rule #6 on empty sources.
SINGLES="
teststuffstash/oracle-fleet      | registry | registry-push-token | token | REGISTRY_PUSH_TOKEN
teststuffstash/agent-runtime     | registry | registry-push-token | token | REGISTRY_PUSH_TOKEN
teststuffstash/agent-coordinator | registry | registry-push-token | token | REGISTRY_PUSH_TOKEN
"
# ^ REGISTRY_PUSH_TOKEN: the ADR-121 first-party registry push credential (user `releaser`) —
#   consumed by oracle-fleet release-corpus.yaml's dual-publish (PR#352), and by the build-image.yaml
#   of agent-runtime and agent-coordinator, which publish ONLY there: both images carry the Claude
#   Code binary, which is not ours to hand out from a public ghcr package (FU-274).

CHECK=0; FORGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --forge) FORGE="${2:?--forge github|forgejo}"; shift ;;
    *) echo "usage: $0 [--check] [--forge github|forgejo]" >&2; exit 2 ;;
  esac
  shift
done
# A typo'd forge would skip every row and still print "done" — the stale-copy failure this exists to prevent.
case "$FORGE" in ""|github|forgejo) ;; *) echo "✗ --forge must be github or forgejo, got '$FORGE'" >&2; exit 2 ;; esac

FORGEJO_API="${FORGEJO_API:-https://forgejo.teststuff.net/api/v1}"
FJ_HDR=""
trap '[ -z "$FJ_HDR" ] || rm -f "$FJ_HDR"' EXIT
# The Forgejo auth header, read from the wallet once, into a 0600 file (curl -H @file). Called
# ONCE in the main shell below, before the loops: the loops and `printf | put_secret` are
# subshells, so a lazy call there would mint a file per call that the EXIT trap never sees.
fj_header() {
  local d tok
  for d in "${KP_DIR:-}" "$HOME/.claude/homelab-keepass" "$HOME/Projects/.claude-data/homelab-keepass"; do
    [ -n "$d" ] && [ -f "$d/homelab.kdbx" ] && break
  done
  tok=$(devbox run --quiet -- keepassxc-cli show -q --no-password -k "$d/homelab.keyx" -a Password \
        "$d/homelab.kdbx" forgejo-api-token 2>/dev/null) || tok=""
  [ -n "$tok" ] || { echo "✗ wallet entry forgejo-api-token unreadable" >&2; exit 42; }
  FJ_HDR=$(umask 077; mktemp)
  printf 'Authorization: token %s\n' "$tok" > "$FJ_HDR"
}

forge_of() { case "$1" in forgejo:*) echo forgejo ;; *) echo github ;; esac; }

# put_secret <repo> <name>  — the value on stdin.
put_secret() {
  case "$1" in
    forgejo:*)
      local code
      code=$(jq -Rs '{data: .}' | curl -s -o /dev/null -w '%{http_code}' -X PUT -H @"$FJ_HDR" \
        -H 'Content-Type: application/json' --data-binary @- \
        "$FORGEJO_API/repos/${1#forgejo:}/actions/secrets/$2") || code=000
      case "$code" in 201|204) return 0 ;; *) echo "  Forgejo PUT $2 → HTTP $code" >&2; return 1 ;; esac ;;
    *) gh secret set "$2" -R "$1" ;;
  esac
}

# check_names <repo> <name>...  — Forgejo only: are the copies present (by name)?
check_names() {
  case "$1" in forgejo:*) ;; *) return 0 ;; esac
  local have n miss=""
  have=$(curl -sf -H @"$FJ_HDR" "$FORGEJO_API/repos/${1#forgejo:}/actions/secrets?limit=100" | jq -r '.[].name') \
    || { echo "  ✗ could not list $1 secrets" >&2; return 1; }
  shift
  for n in "$@"; do grep -qx -- "$n" <<< "$have" || miss="$miss $n"; done
  if [ -n "$miss" ]; then echo "  ⚠ copy MISSING on the forge:$miss"; else echo "  ✓ copies present on the forge"; fi
}
if [ "$FORGE" != github ] && grep -q '^ *forgejo:' <<< "$MAPPING$SINGLES"; then
  fj_header
fi
# fail_hint <repo> — what a failed write most likely means, per forge.
fail_hint() {
  case "$1" in
    forgejo:*) echo "see the HTTP status above; 401/403 = forgejo-api-token lacks admin on the repo" ;;
    *) echo "403 = this gh auth lacks Secrets write; run on the HOST — docs/github-setup.md" ;;
  esac
}

printf '%s\n' "$MAPPING" | while IFS='|' read -r repo ns conn pair prefix; do
  # trim whitespace; skip blanks/comments
  repo=$(echo "$repo" | tr -d ' '); ns=$(echo "$ns" | tr -d ' ')
  conn=$(echo "$conn" | tr -d ' '); pair=$(echo "$pair" | tr -d ' '); prefix=$(echo "$prefix" | tr -d ' ')
  [ -n "$repo" ] || continue; case "$repo" in \#*) continue;; esac
  [ -z "$FORGE" ] || [ "$(forge_of "$repo")" = "$FORGE" ] || continue

  id=$("${KUBE[@]}" get secret "$conn" -n "$ns" -o "jsonpath={.data.${pair}_access_key_id}" 2>/dev/null | base64 -d) || id=""
  sec=$("${KUBE[@]}" get secret "$conn" -n "$ns" -o "jsonpath={.data.${pair}_secret_access_key}" 2>/dev/null | base64 -d) || sec=""
  if [ -z "$id" ] || [ -z "$sec" ]; then
    echo "✗ $repo ← $ns/$conn (${pair}): SOURCE UNREADABLE/EMPTY — not touching the forge side (rule #6)" >&2
    exit 40
  fi

  if [ "$CHECK" = "1" ]; then
    echo "· $repo  ${prefix}_ACCESS_KEY_ID/_SECRET_ACCESS_KEY  ←  $ns/$conn ${pair} pair (source OK, id ${id:0:6}…)"
    check_names "$repo" "${prefix}_ACCESS_KEY_ID" "${prefix}_SECRET_ACCESS_KEY"
    continue
  fi

  ok=1
  printf '%s' "$id"  | put_secret "$repo" "${prefix}_ACCESS_KEY_ID"     || ok=0
  printf '%s' "$sec" | put_secret "$repo" "${prefix}_SECRET_ACCESS_KEY" || ok=0
  if [ "$ok" = "1" ]; then
    echo "✓ $repo  ${prefix}_* ← $ns/$conn ${pair} pair (id ${id:0:6}…)"
  else
    echo "✗ $repo  ${prefix}_* — secret write FAILED ($(fail_hint "$repo"))" >&2
    exit 41
  fi
done

printf '%s\n' "$SINGLES" | while IFS='|' read -r repo ns sec key ghname; do
  repo=$(echo "$repo" | tr -d ' '); ns=$(echo "$ns" | tr -d ' ')
  sec=$(echo "$sec" | tr -d ' '); key=$(echo "$key" | tr -d ' '); ghname=$(echo "$ghname" | tr -d ' ')
  [ -n "$repo" ] || continue; case "$repo" in \#*) continue;; esac
  [ -z "$FORGE" ] || [ "$(forge_of "$repo")" = "$FORGE" ] || continue

  val=$("${KUBE[@]}" get secret "$sec" -n "$ns" -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d) || val=""
  if [ -z "$val" ]; then
    echo "✗ $repo ← $ns/$sec (${key}): SOURCE UNREADABLE/EMPTY — not touching the forge side (rule #6)" >&2
    exit 40
  fi
  if [ "$CHECK" = "1" ]; then
    echo "· $repo  $ghname  ←  $ns/$sec .$key (source OK, ${val:0:4}…)"
    check_names "$repo" "$ghname"
    continue
  fi
  if printf '%s' "$val" | put_secret "$repo" "$ghname"; then
    echo "✓ $repo  $ghname ← $ns/$sec .$key (${val:0:4}…)"
  else
    echo "✗ $repo  $ghname — secret write FAILED ($(fail_hint "$repo"))" >&2
    exit 41
  fi
done
echo "github-secrets-sync: done ($( [ "$CHECK" = "1" ] && echo check || echo sync ))"
