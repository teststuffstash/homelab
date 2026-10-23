#!/usr/bin/env bash
# Raw Allure results → ONE self-contained report: allure-report-single/index.html (oracle-fleet
# allure-publish.sh's `allure generate --single-file` — #397/#499: one object a browser opens, not
# the ~3.5k-file multi-file tree).
#
#   devbox run report [-- <results-dir> [<out-dir>]]     (defaults: allure-results allure-report-single)
#
# Runs after the suite (pyproject addopts writes allure-results/): from scripts/ci.sh — the answer to
# "is there an Allure report I can open?" is <out-dir>/index.html — and from scripts/gateway-evidence.sh
# before its join. Allure test-case uids are PER-GENERATE: a row link (the pack's fragments, the
# site's joined tables) resolves only against the index.html it was read from, so a report that is
# newer than every result file is reused, never regenerated — the one gateway-evidence.sh joins
# against is the one scripts/specs-build.sh ships at <site>/report/index.html. Plain HTML here;
# scripts/specs-publish.sh gzips it at upload (the #547 shape). The `allure` CLI: devbox.json.
set -euo pipefail
cd "$(dirname "$0")/.."
RESULTS="${1:-allure-results}"
OUT="${2:-allure-report-single}"

if ! ls "$RESULTS"/*-result.json >/dev/null 2>&1; then
  echo "allure-report: no Allure results under $RESULTS/ — run the suite first (devbox run test)" >&2
  exit 1
fi
if [ -f "$OUT/index.html" ] && [ -z "$(find "$RESULTS" -newer "$OUT/index.html" -print -quit)" ]; then
  echo "allure-report: $OUT/index.html is newer than every file in $RESULTS/ — reused (uids are per-generate)"
  exit 0
fi
allure generate --single-file "$RESULTS" -o "$OUT" --clean >/dev/null
echo "allure-report: $OUT/index.html ($(stat --format=%s "$OUT/index.html") bytes) — open it in a browser"
