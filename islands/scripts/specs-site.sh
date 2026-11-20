#!/usr/bin/env bash
# specs-site.sh — the browsable specs site of ONE island under islands/ (the gateway island's
# site, gateway/scripts/specs-build.sh + specs-publish.sh, for the spec roots that are not the
# gateway's). An island opts in with a `mkdocs.yml` beside its `specs/` (it INHERITs the
# gateway's), a `<island>-specs` website bucket and a route (argocd/resources/agent-gateway/
# garage-workspace.yaml, argocd/resources/homelab-gateway/httproute-<island>-specs.yaml).
#
#   bash islands/scripts/specs-site.sh build   <island>          # → islands/<island>/specs-site/
#   bash islands/scripts/specs-site.sh publish <island>          # build, then mirror to the bucket
#   bash islands/scripts/specs-site.sh purge   <island> <pr>     # remove a closed PR's preview
#
#   master runs (SITE_PREFIX empty) → bucket root → https://<island>-specs.homelab.teststuff.net
#   PR runs   (SITE_PREFIX=pr-<N>)  → pr-<N>/     → …/pr-<N>/   (same route, by path)
#
# What the site shows: the island's README.md + specs/, each rule's decision tables joined to the
# run's evidence where a description cell equals a case id, linking into the run's single-file
# Allure report at report/index.html. The evidence is the island's own suite (its `devbox run ci`,
# which writes allure-results/), run here first: a red or failed suite is reported and the site is
# still built from whatever results it left — this script publishes, the suite's gate is the
# island's own row in scripts/diff-ci.sh. SPECS_SITE_SUITE=skip reuses the results on disk.
#
# Toolchain and pins are the gateway island's — ONE home: the build steps live in
# gateway/scripts/lib/site-build.sh (mermaid + mkdocs pins), the evidence tool pin in
# gateway/scripts/lib/snippets.sh, the verified upload in gateway/scripts/lib/s3-publish.sh, and
# the packages (uv, rclone, allure, npm) in gateway/devbox.json — the script re-enters itself
# inside that devbox. Credentials are the gateway-specs WRITER pair (GATEWAY_SPECS_S3_*, granted on
# every island site bucket by the Workspace above); publish soft-skips without them.
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GW="$ROOT/gateway"

VERB="${1:-}"; ISLAND="${2:-}"
case "$VERB" in build|publish|purge) ;; *) echo "usage: specs-site.sh <build|publish|purge> <island> [<pr-number>]" >&2; exit 2;; esac
[[ "$ISLAND" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "specs-site: island name must be lower-case, got '$ISLAND'" >&2; exit 2; }
DIR="$ROOT/islands/$ISLAND"
[ -f "$DIR/mkdocs.yml" ] && [ -d "$DIR/specs" ] || { echo "specs-site: islands/$ISLAND has no mkdocs.yml + specs/ — not a site root" >&2; exit 2; }

RULE_PREFIX="$(printf '%s' "$ISLAND" | tr '[:lower:]' '[:upper:]')"   # scan → SCAN-… (islands/README.md)
BUCKET="$ISLAND-specs"
SITE_URL="${SPECS_SITE_URL:-https://$ISLAND-specs.homelab.teststuff.net}"
SITE_PREFIX="${SITE_PREFIX:-}"
SITE_BASE_URL="${SITE_URL}${SITE_PREFIX:+/$SITE_PREFIX}"
REPORT_URL="${SITE_BASE_URL}/report/index.html"
ENDPOINT="${GATEWAY_SPECS_S3_ENDPOINT:-https://s3.teststuff.net}"

have_creds() { [ -n "${GATEWAY_SPECS_S3_ACCESS_KEY_ID:-}" ] && [ -n "${GATEWAY_SPECS_S3_SECRET_ACCESS_KEY:-}" ]; }

if [ -z "${SPECS_SITE_INNER:-}" ]; then
  # Outer pass: the island's suite in the island's OWN devbox, then re-enter in the gateway's.
  # Results on disk that are newer than every suite input are this tree's own (a ride's pr-gate ran
  # the island's gate row a moment ago) — reused, never a second two-minute run.
  fresh_results() {
    local newest
    newest=$(find "$DIR/allure-results" -name '*-result.json' -printf '%T@ %p\n' 2>/dev/null | sort -rn | sed -n '1s/^[^ ]* //p')
    [ -n "$newest" ] && [ -z "$(cd "$DIR" && find src tests specs scripts pyproject.toml uv.lock -newer "$newest" -print -quit 2>/dev/null)" ]
  }
  if [ "$VERB" != purge ] && [ "${SPECS_SITE_SUITE:-run}" != skip ] && fresh_results; then
    echo "== specs-site: islands/$ISLAND/allure-results/ is newer than every suite input — reused =="
  elif [ "$VERB" != purge ] && [ "${SPECS_SITE_SUITE:-run}" != skip ]; then
    echo "== specs-site: islands/$ISLAND suite (devbox run ci) → allure-results/ =="
    (cd "$DIR" && devbox run ci) \
      || echo "specs-site: WARNING — islands/$ISLAND suite did not pass; the site is built from the results it left"
  fi
  cd "$GW"
  SPECS_SITE_INNER=1 exec devbox run -- bash "$SELF" "$@"
fi

cd "$DIR"
# shellcheck disable=SC1091
source "$GW/scripts/lib/site-build.sh"
# shellcheck disable=SC1091
source "$GW/scripts/lib/s3-publish.sh"

build() {
  rm -rf .site-evidence .site-src && mkdir -p .site-evidence .site-src
  cp -r specs README.md .site-src/
  rm -rf allure-report-single
  if ls allure-results/*-result.json >/dev/null 2>&1; then
    bash "$GW/scripts/allure-report.sh" "$DIR/allure-results" "$DIR/allure-report-single"
    echo "== spec pages: join spec tables to this run's evidence (→ $REPORT_URL) =="
    # shellcheck disable=SC1091
    source "$GW/scripts/lib/snippets.sh"
    site_join_pages "$RULE_PREFIX" "$REPORT_URL"
  else
    echo "specs-site: no allure-results/ — the pages render as authored, no report"
  fi
  site_stage_mermaid
  echo "== mkdocs: render README.md + specs/ =="
  site_mkdocs_build
  if [ -f allure-report-single/index.html ]; then
    mkdir -p specs-site/report && cp allure-report-single/index.html specs-site/report/index.html
  fi
  site_dir_indexes
  echo "specs-site: islands/$ISLAND/specs-site/ ($(find specs-site -type f | wc -l) files$([ -f specs-site/report/index.html ] && echo ', report/index.html included'))"
}

case "$VERB" in
  build) build ;;
  publish)
    if ! have_creds; then
      echo "specs-site: no S3 credentials in env (GATEWAY_SPECS_S3_*) — build only (local run?)"
      build; exit 0
    fi
    build
    echo "== upload =="
    s3_publish_remote specs "$ENDPOINT" "$GATEWAY_SPECS_S3_ACCESS_KEY_ID" "$GATEWAY_SPECS_S3_SECRET_ACCESS_KEY"
    site_upload "specs:$BUCKET${SITE_PREFIX:+/$SITE_PREFIX}" "$SITE_PREFIX"
    echo "published: $SITE_BASE_URL/  (bucket $BUCKET${SITE_PREFIX:+/$SITE_PREFIX} via $ENDPOINT; report: $REPORT_URL)"
    ;;
  purge)
    N="${3:?usage: specs-site.sh purge <island> <pr-number>}"
    [[ "$N" =~ ^[0-9]+$ ]] || { echo "::error::pr-number must be numeric, got '$N'"; exit 1; }
    have_creds || { echo "::error::GATEWAY_SPECS_S3_* must be set for the close-time prefix purge"; exit 1; }
    s3_publish_remote specs "$ENDPOINT" "$GATEWAY_SPECS_S3_ACCESS_KEY_ID" "$GATEWAY_SPECS_S3_SECRET_ACCESS_KEY"
    site_purge_prefix "specs:$BUCKET/pr-$N"
    ;;
esac
