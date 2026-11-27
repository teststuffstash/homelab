#!/usr/bin/env bash
# Raw Allure results → the island's evidence pack (Goal #3384 child 2; the shape of
# gateway/scripts/gateway-evidence.sh, minus the report and row links):
#
#   bash scripts/evidence.sh [<results-dir> [<out-dir>]]     (defaults: allure-results allure-evidence)
#
# Run AFTER pytest. <out-dir> holds evidence.json, digest.md and one <RULE>.md per labelled rule —
# nothing else: no rendered Allure report, no row links. The pinned tool runs ONCE PER SPEC PAGE
# (`--spec` joins only the --rules headed on that page). The wheel pin is the gateway's own
# (gateway/scripts/lib/snippets.sh, sourced read-only — no second copy). Join/hygiene codes are
# REPORTED, never gated (no ratchet in this child).
set -euo pipefail
cd "$(dirname "$0")/.."
RESULTS="${1:-allure-results}"
OUT="${2:-allure-evidence}"
# shellcheck source=../../../gateway/scripts/lib/snippets.sh
source ../../gateway/scripts/lib/snippets.sh

# page → rules, in page order: the rules this island labels.
PAGES=("specs/guard.md:RETRO-GUARD-EXPR" "specs/cell.md:RETRO-REPORT-FLOOR" "specs/findings.md:RETRO-FINDINGS-BLOCK")

if ! ls "$RESULTS"/*-result.json >/dev/null 2>&1; then
  echo "evidence: no Allure results under $RESULTS/ — run the suite first" >&2
  exit 1
fi
rm -rf "$OUT" && mkdir -p "$OUT"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

all_rules=$(printf '%s\n' "${PAGES[@]}" | cut -d: -f2 | paste -sd, -)
echo "== evidence: evidence.json + fragments ($RESULTS → $OUT)"
allure_evidence --results "$RESULTS" --out "$OUT" --rules "$all_rules"
rm -f "$OUT/digest.md"
{ echo "# retro island evidence digest"; echo; } > "$OUT/digest.md"

for entry in "${PAGES[@]}"; do
  page=${entry%%:*}
  rules=${entry#*:}
  slug=$(echo "${page#specs/}" | tr '/' '_')
  echo "== evidence: join $page ($rules)"
  allure_evidence --results "$RESULTS" --out "$scratch/$slug" --spec "$page" --rules "$rules"
  IFS=, read -ra rl <<< "$rules"
  for r in "${rl[@]}"; do
    [ -f "$scratch/$slug/$r.md" ] && cp "$scratch/$slug/$r.md" "$OUT/$r.md"
  done
  { echo "# ${page}"; echo; cat "$scratch/$slug/digest.md"; } >> "$OUT/digest.md"
done

echo "== evidence: per-rule summary (evidence.json; unproven = ROW_UNPROVEN in digest.md)"
for r in RETRO-GUARD-EXPR RETRO-REPORT-FLOOR RETRO-FINDINGS-BLOCK; do
  printf '  %-20s passed %s · failed %s · unproven %s\n' "$r" \
    "$(jq --arg r "$r" '[.rules[$r][] | select(.status == "passed")] | length' "$OUT/evidence.json")" \
    "$(jq --arg r "$r" '[.rules[$r][] | select(.status != "passed")] | length' "$OUT/evidence.json")" \
    "$(grep -c "^- ROW_UNPROVEN $r " "$OUT/digest.md" || true)"
done
echo "== evidence: codes across digest.md"
for code in STEP_FLAT STEP_NOISE UNIT_ONLY_CANDIDATE ATTACH_BULK PARAM_BLOB NAME_BLANK THREAD_BROKEN \
            ROW_UNPROVEN ROW_UNKEYED HEADER_UNTHREADED CELL_MISMATCH ROW_UNSPECIFIED; do
  printf '  %-20s %s\n' "$code" "$(grep -c "^- $code " "$OUT/digest.md" || true)"
done
grep -h '^_spec: ' "$OUT"/RETRO-*.md | sed 's/^/  /' || true
echo "evidence: files in $OUT/:"
(cd "$OUT" && find . -type f | sort | sed 's|^\./|  |')
