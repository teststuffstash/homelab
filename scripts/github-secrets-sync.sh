#!/bin/bash
# github-secrets-sync.sh — sync cluster-minted credentials into GitHub Actions repo secrets.
#
#     devbox run github-secrets-sync             # sync every mapping row (HOST-side)
#     devbox run github-secrets-sync -- --check  # inventory + source-side existence probe (jail-safe)
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
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KUBE=(kubectl --kubeconfig "$ROOT/tofu/kubeconfig")

# ── THE MAPPING ─────────────────────────────────────────────────────────────────────────────
# repo | namespace | connection Secret | pair (reader|writer) | GitHub secret prefix
# The pair picks which half of the connection Secret ships: <pair>_access_key_id and
# <pair>_secret_access_key → <PREFIX>_ACCESS_KEY_ID and <PREFIX>_SECRET_ACCESS_KEY.
# ⚠ Pick the right half (docs/github-setup.md): a READER pair authenticates and then 403s on
# PUT — publishers take writer, fetch-only workflows take reader.
MAPPING="
teststuffstash/oracle-fleet | oracle-fleet | allure-reports-s3 | writer | ALLURE_S3
teststuffstash/oracle-fleet | oracle-fleet | ert-snapshots-s3  | reader | ERT_S3_READER
teststuffstash/circles      | circles      | circles-specs-s3  | writer | SPECS_S3
"

CHECK=0
if [ "${1:-}" = "--check" ]; then CHECK=1; fi

printf '%s\n' "$MAPPING" | while IFS='|' read -r repo ns conn pair prefix; do
  # trim whitespace; skip blanks/comments
  repo=$(echo "$repo" | tr -d ' '); ns=$(echo "$ns" | tr -d ' ')
  conn=$(echo "$conn" | tr -d ' '); pair=$(echo "$pair" | tr -d ' '); prefix=$(echo "$prefix" | tr -d ' ')
  [ -n "$repo" ] || continue; case "$repo" in \#*) continue;; esac

  id=$("${KUBE[@]}" get secret "$conn" -n "$ns" -o "jsonpath={.data.${pair}_access_key_id}" 2>/dev/null | base64 -d) || id=""
  sec=$("${KUBE[@]}" get secret "$conn" -n "$ns" -o "jsonpath={.data.${pair}_secret_access_key}" 2>/dev/null | base64 -d) || sec=""
  if [ -z "$id" ] || [ -z "$sec" ]; then
    echo "✗ $repo ← $ns/$conn (${pair}): SOURCE UNREADABLE/EMPTY — not touching the GitHub side (rule #6)" >&2
    exit 40
  fi

  if [ "$CHECK" = "1" ]; then
    echo "· $repo  ${prefix}_ACCESS_KEY_ID/_SECRET_ACCESS_KEY  ←  $ns/$conn ${pair} pair (source OK, id ${id:0:6}…)"
    continue
  fi

  ok=1
  printf '%s' "$id"  | gh secret set "${prefix}_ACCESS_KEY_ID"     -R "$repo" || ok=0
  printf '%s' "$sec" | gh secret set "${prefix}_SECRET_ACCESS_KEY" -R "$repo" || ok=0
  if [ "$ok" = "1" ]; then
    echo "✓ $repo  ${prefix}_* ← $ns/$conn ${pair} pair (id ${id:0:6}…)"
  else
    echo "✗ $repo  ${prefix}_* — gh secret set FAILED (403 = this gh auth lacks Secrets write; run on the HOST — docs/github-setup.md)" >&2
    exit 41
  fi
done

# ── SINGLE-VALUE MAPPINGS ───────────────────────────────────────────────────────────────────
# Same contract as the pair table above, for credentials that are ONE value, not an S3 pair:
# repo | namespace | Secret | key in Secret | GitHub secret name
# Source of truth for these is Infisical (ESO materializes the cluster Secret this reads) —
# same write-only-copy rationale, same host-side requirement, same rule #6 on empty sources.
SINGLES="
teststuffstash/oracle-fleet | registry | registry-push-token | token | REGISTRY_PUSH_TOKEN
"
# ^ REGISTRY_PUSH_TOKEN: the ADR-121 first-party registry push credential (user `releaser`) —
#   consumed by oracle-fleet release-corpus.yaml's dual-publish (PR#352).

printf '%s\n' "$SINGLES" | while IFS='|' read -r repo ns sec key ghname; do
  repo=$(echo "$repo" | tr -d ' '); ns=$(echo "$ns" | tr -d ' ')
  sec=$(echo "$sec" | tr -d ' '); key=$(echo "$key" | tr -d ' '); ghname=$(echo "$ghname" | tr -d ' ')
  [ -n "$repo" ] || continue; case "$repo" in \#*) continue;; esac

  val=$("${KUBE[@]}" get secret "$sec" -n "$ns" -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d) || val=""
  if [ -z "$val" ]; then
    echo "✗ $repo ← $ns/$sec (${key}): SOURCE UNREADABLE/EMPTY — not touching the GitHub side (rule #6)" >&2
    exit 40
  fi
  if [ "$CHECK" = "1" ]; then
    echo "· $repo  $ghname  ←  $ns/$sec .$key (source OK, ${val:0:4}…)"
    continue
  fi
  if printf '%s' "$val" | gh secret set "$ghname" -R "$repo"; then
    echo "✓ $repo  $ghname ← $ns/$sec .$key (${val:0:4}…)"
  else
    echo "✗ $repo  $ghname — gh secret set FAILED (403 = this gh auth lacks Secrets write; run on the HOST — docs/github-setup.md)" >&2
    exit 41
  fi
done
echo "github-secrets-sync: done ($( [ "$CHECK" = "1" ] && echo check || echo sync ))"
