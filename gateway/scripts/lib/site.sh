# shellcheck shell=bash
# The published specs site's addresses — ONE home for the scripts that must agree on them:
# scripts/specs-publish.sh uploads there, scripts/gateway-evidence.sh + scripts/specs-build.sh
# write links there (a row's link must name the report the SAME run publishes — Allure test-case
# uids are per-generate, so a link resolves only against the index.html it was read from).
#
#   SITE_URL      the route (ADR-092 delegation → the gateway-specs bucket's web endpoint)
#   SITE_PREFIX   '' on master runs (the bucket root); pr-<N> on PR runs — ci.yaml sets it for the
#                 evidence AND the site publish steps, scripts/specs-pr-purge.sh removes it on close
#   SITE_BASE_URL SITE_URL[/SITE_PREFIX]
#   REPORT_URL    the run's single-file Allure report beside the site (scripts/allure-report.sh →
#                 specs-build.sh → <site>/report/index.html): one copy per site, never per run
SITE_URL="${GATEWAY_SPECS_SITE_URL:-https://gateway-specs.homelab.teststuff.net}"
SITE_PREFIX="${SITE_PREFIX:-}"
SITE_BASE_URL="${SITE_URL}${SITE_PREFIX:+/$SITE_PREFIX}"
REPORT_URL="${SITE_BASE_URL}/report/index.html"
