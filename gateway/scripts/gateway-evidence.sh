#!/usr/bin/env bash
# Raw Allure results → the reviewer's evidence (ADR-156 step 4; oracle-fleet allure-publish.sh's
# `allure_evidence` stage: the single-file report + the fragments; the upload is
# scripts/evidence-publish.sh for the pack, scripts/specs-publish.sh for the report + site):
#
#   devbox run evidence [-- <results-dir> [<out-dir>]]     (defaults: allure-results allure-evidence)
#
# Run AFTER pytest (pyproject addopts writes allure-results/). <out-dir> is the WHOLE reviewer
# pack — CI publishes exactly this directory (scripts/evidence-publish.sh → the gateway-specs bucket,
# evidence/<pr-N|branch>/<sha>.tar.gz), so its root holds:
#   allure-results/ a copy of the raw results (attachments, environment.properties, executor.json)
#   evidence.json   every labelled record across the suite (+ the run's environment.properties)
#   digest.md       every spec rule in page order — tables, findings (incl. the --spec join's
#                   ROW_UNPROVEN / CELL_MISMATCH / ROW_UNSPECIFIED) and the **Hygiene:** block
#   <RULE>.md       one fragment per rule: the spec page's tables joined to the evidence where
#                   the tool can parse them (`--spec`), the plain evidence table otherwise
# and prints the hygiene/finding code counts. The tool runs ONCE PER SPEC PAGE: `--spec` takes one
# page and joins only the --rules headed on it. Pin: scripts/lib/snippets.sh.
# The report leg: scripts/allure-report.sh generates allure-report-single/index.html from the same
# results first (reused when fresh — Allure uids are per-generate), and every fragment's row links
# into it at REPORT_URL (scripts/lib/site.sh — SITE_PREFIX picks the master root or the pr-<N>/
# preview), where scripts/specs-build.sh ships that very index.html beside the site. The site's
# `<details>` fragments are these <RULE>.md (specs-build.sh); scripts/evidence_render.py keeps only
# evidence/evidence.md + its BEGIN/END log block.
set -euo pipefail
cd "$(dirname "$0")/.."
RESULTS="${1:-allure-results}"
OUT="${2:-allure-evidence}"
# shellcheck source=lib/snippets.sh
source scripts/lib/snippets.sh
# shellcheck source=lib/site.sh
source scripts/lib/site.sh

if ! ls "$RESULTS"/*-result.json >/dev/null 2>&1; then
  echo "gateway-evidence: no Allure results under $RESULTS/ — run the suite first (devbox run test)" >&2
  exit 1
fi
rm -rf "$OUT" && mkdir -p "$OUT"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# The report every row link resolves against — generated once per results set.
bash scripts/allure-report.sh "$RESULTS" allure-report-single
REPORT=allure-report-single/index.html
echo "== gateway-evidence: row links → $REPORT_URL"

# Spec pages that head rules, and their rules in page order.
# (specs/evidence/ was the retired evidence_render.py fragment dir — a stale checkout may still carry it.)
mapfile -t pages < <(grep -rlE '^#{2,6} GW-[A-Z0-9-]+\s*$' specs --include='*.md' --exclude-dir=evidence | sort)
all_rules=()
for page in "${pages[@]}"; do
  mapfile -t rules < <(sed -nE 's/^#{2,6} (GW-[A-Z0-9-]+)\s*$/\1/p' "$page")
  all_rules+=("${rules[@]}")
done
csv() { local IFS=,; echo "$*"; }

echo "== gateway-evidence: suite-wide evidence.json + fragments ($RESULTS → $OUT)"
allure_evidence --results "$RESULTS" --out "$OUT" --rules "$(csv "${all_rules[@]}")" \
  --report "$REPORT" --report-url "$REPORT_URL"
mv "$OUT/digest.md" "$scratch/digest-unjoined.md"

{
  echo "# agent-gateway evidence digest"
  echo
  if [ -f "$RESULTS/environment.properties" ]; then
    echo '```properties'
    cat "$RESULTS/environment.properties"
    echo '```'
    echo
  fi
} > "$OUT/digest.md"

for page in "${pages[@]}"; do
  mapfile -t rules < <(sed -nE 's/^#{2,6} (GW-[A-Z0-9-]+)\s*$/\1/p' "$page")
  slug=$(echo "${page#specs/}" | tr '/' '_')
  echo "== gateway-evidence: join $page (${rules[*]})"
  allure_evidence --results "$RESULTS" --out "$scratch/$slug" --spec "$page" --rules "$(csv "${rules[@]}")" \
    --report "$REPORT" --report-url "$REPORT_URL"
  # A joined fragment replaces the plain one; a rule whose tables the tool could not parse keeps it.
  for r in "${rules[@]}"; do
    [ -f "$scratch/$slug/$r.md" ] && cp "$scratch/$slug/$r.md" "$OUT/$r.md"
  done
  { echo "# ${page}"; echo; cat "$scratch/$slug/digest.md"; } >> "$OUT/digest.md"
done

# The raw results ride inside the pack: the reviewer reads <pack>/allure-results/ and
# <pack>/evidence.json from one pack fetch (agents/specs-reviewer-session.sh evidence_fetch).
cp -r "$RESULTS" "$OUT/allure-results"

echo "== gateway-evidence: codes across digest.md"
for code in STEP_FLAT STEP_NOISE UNIT_ONLY_CANDIDATE ATTACH_BULK PARAM_BLOB NAME_BLANK THREAD_BROKEN \
            ROW_UNPROVEN CELL_MISMATCH ROW_UNSPECIFIED; do
  printf '  %-20s %s\n' "$code" "$(grep -c "^- $code " "$OUT/digest.md" || true)"
done
grep -h '^_spec: ' "$OUT"/GW-*.md | sed 's/^/  /' || true
echo "gateway-evidence: $(find "$OUT" -type f | wc -l) files in $OUT/"
