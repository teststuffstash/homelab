# ── bridge ── the scan state the pr-cap-per-base block reads.
# Mock queued issues as JSON, simulating the `gh issue list --json ...` output.
# Issue #8491 has `Base: goal/29-p0-complete` — this was the row that caused
# jq to error (scan with capture group returns array, @tsv rejects it) and halt
# the stream, so #8492 never reached the dispatch loop.
# Issue #8492 has no Base: line — defaults to default_branch.
# Issue #8493 has `Base: master` explicitly.
queued='[
  {"number": 8491, "title": "goal-based issue", "body": "Touches: agents/**\nBase: goal/29-p0-complete", "labels": [{"name": "agent-fix"}], "isPinned": false},
  {"number": 8492, "title": "no-base issue after Base row", "body": "Touches: docs/**", "labels": [{"name": "agent-fix"}], "isPinned": false},
  {"number": 8493, "title": "explicit master-base issue", "body": "Touches: chassis/**\nBase: master", "labels": [{"name": "agent-fix"}], "isPinned": false}
]'
# 3 armed PRs against master (≥ cap 3) → holds master-based issues.
# 1 armed PR against goal/29-p0-complete (< cap 3) → dispatches goal-based issues.
per_base_armed="master|3
goal/29-p0-complete|1"
REPO_PR_CAP="${REPO_PR_CAP:-3}"
# FU-199 / #1240 CAP SPLIT: codeowner-parked PRs count against their own bound.
REPO_BLOCKPARK_CAP="${REPO_BLOCKPARK_CAP:-10}"
per_base_blockpark=""
default_branch="master"
# repo is set from the stack name in the scan's outer loop
repo="homelab"
orphans=""
# item_class_push — the scan's per-pass accumulator. Defined here because the extracted
# pr-cap-per-base block now calls it for cap-held items (FU-199 / #1240).
item_class_push() {
  local repo="${1:?}" item="${2:?}" class="${3:?}" who="${4:?}"
  ITEM_CLASS_ROWS="${ITEM_CLASS_ROWS}${repo}|${item}|${class}|${who}|...\n"
}
ITEM_CLASS_ROWS=""

# ── jq extraction assertion ──
# Prove the jq pipeline correctly extracts qbase from real issue-body JSON.
# The scan uses `scan("(?mi)^[ \t]*base:[ \t]*(.+)$")` with `flatten | first`.
# Without `flatten`, the capture group returns an array that @tsv rejects,
# causing jq to halt the stream and truncate the queue.
# With `flatten`, the extraction returns a string and every row emits.
# This assertion is verified BEFORE the while-read loop, so the `read`
# collapsing (a pre-existing issue) does not contaminate the proof.
jq_extraction_ok=1
while IFS= read -r line; do
  num="${line%%|*}"
  rest="${line#*|}"
  base="${rest#*|}"
  case "$num" in
    8491) [ "$base" = "goal/29-p0-complete" ] || { echo "FAIL: #8491 base='$base' expected 'goal/29-p0-complete'"; jq_extraction_ok=0; } ;;
    8492) [ "$base" = "" ] || { echo "FAIL: #8492 base='$base' expected ''"; jq_extraction_ok=0; } ;;
    8493) [ "$base" = "master" ] || { echo "FAIL: #8493 base='$base' expected 'master'"; jq_extraction_ok=0; } ;;
  esac
done < <(printf '%s' "$queued" | jq -r '.[] | [ .number, (([(.body // "") | scan("(?mi)^[ \t]*base:[ \t]*(.+)$")] | flatten | first // "")) ] | join("|")')
[ "$jq_extraction_ok" = 1 ] && echo "JQ_EXTRACTION: OK (all 3 rows emit, bases correct)"
# Also verify the stream truncation case: without `flatten`, the jq errors.
# This is a negative assertion — we expect the broken command to fail.
if printf '%s' "$queued" | jq -r '.[] | [ .number, (([(.body // "") | scan("(?mi)^[ \t]*base:[ \t]*(.+)$")] | first // "")) ] | @tsv' 2>/dev/null; then
  echo "JQ_TRUNCATION: UNEXPECTED SUCCESS (broken jq command should have failed)"
else
  echo "JQ_TRUNCATION: OK (broken jq command correctly errors)"
fi