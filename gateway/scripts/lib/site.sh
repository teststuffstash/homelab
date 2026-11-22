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

# site_build_stamp — what a specs-site/ build is keyed on WITHIN one CI job, so the e2e leg can reuse
# the build the publish step just made instead of rendering a third identical site
# (scripts/specs-build.sh writes it to .specs-site.stamp, scripts/e2e-specs-site.sh compares).
# The source tree cannot change inside a job; what does change between the job's builds is the
# evidence fragments (ci.sh's build runs before scripts/gateway-evidence.sh writes them) — so the
# key is the run id + those fragments. Outside CI it prints nothing: no stamp, always rebuild.
site_build_stamp() {
  [ -n "${GITHUB_RUN_ID:-}" ] || return 0
  printf '%s-%s %s\n' "$GITHUB_RUN_ID" "${GITHUB_RUN_ATTEMPT:-1}" \
    "$(find allure-evidence -maxdepth 1 -name 'GW-*.md' 2>/dev/null | LC_ALL=C sort | xargs -r cat | sha256sum | cut -d' ' -f1)"
}
