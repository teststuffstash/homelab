#!/usr/bin/env bash
# facts-check — the ONE predicate for "this facts file can carry a sitting" (islands/intake/rules/intake.md
# §Island facts; homelab#3576, #3578, #3580). Read by the launcher before any model session
# (scripts/sitting.sh — a platform island's docs/intake/<island>.md, a stack island's file in its own
# clone) and by the harness (tests/island-intake-test.sh), so the two cannot disagree.
#
#   bash islands/intake/scripts/facts-check.sh [--sections] <facts file>
#
# Prints one line per shortfall; nothing = the file is usable. Exit 0 = usable, 1 = a shortfall.
#   - the file is missing or empty
#   - `Body shape:` — exactly one line, `Body shape: spec` or `Body shape: edit`
#   - `## Sources` — that exact heading, a table whose header is `| question | read | note |`, and at
#     least one data row with the question and the read filled
#   - `## What a ride can do` — that exact heading and at least one non-blank line under it
# --sections checks the two sections only (the harness's per-shortfall rows).
set -uo pipefail
SECTIONS_ONLY=0
[ "${1:-}" = --sections ] && { SECTIONS_ONLY=1; shift; }
F="${1:-}"
[ -n "$F" ] || { echo "facts-check: usage: facts-check.sh [--sections] <facts file>" >&2; exit 2; }
if [ ! -s "$F" ]; then echo "the facts file does not exist (or is empty)"; exit 1; fi
{
  if [ "$SECTIONS_ONLY" = 0 ]; then
    { [ "$(grep -cE '^Body shape: (spec|edit)$' "$F")" = 1 ] && [ "$(grep -c '^Body shape:' "$F")" = 1 ]; } \
      || echo 'no single `Body shape: spec|edit` line'
  fi
  awk '
    function cells(l,  n, a) { sub(/^[ \t]*\|/, "", l); sub(/\|[ \t]*$/, "", l); n = split(l, a, "|"); return n }
    function cell(l, i,  a) { sub(/^[ \t]*\|/, "", l); sub(/\|[ \t]*$/, "", l); split(l, a, "|"); gsub(/^[ \t]+|[ \t]+$/, "", a[i]); return a[i] }
    /^## / { sec = $0 }
    sec == "## Sources" && /^## Sources$/ { src = 1; next }
    sec == "## What a ride can do" && /^## What a ride can do$/ { ride = 1; next }
    sec == "## Sources" && /^[ \t]*\|/ {
      if (!hdr) { if (tolower(cell($0,1)) == "question" && tolower(cell($0,2)) == "read" && tolower(cell($0,3)) == "note" && cells($0) == 3) hdr = 1; next }
      if ($0 ~ /^[ \t]*\|[ \t:|-]+\|[ \t]*$/) next          # the separator line
      if (cells($0) == 3 && cell($0,1) != "" && cell($0,2) != "") rows++
    }
    sec == "## What a ride can do" && /[^ \t]/ { ridelines++ }
    END {
      if (!src) print "no `## Sources` heading"
      else if (!hdr) print "`## Sources` has no `| question | read | note |` table"
      else if (!rows) print "`## Sources` table has no row"
      if (!ride) print "no `## What a ride can do` heading"
      else if (!ridelines) print "`## What a ride can do` is empty"
    }' "$F"
} > "${TMPDIR:-/tmp}/facts-check.$$" || true
cat "${TMPDIR:-/tmp}/facts-check.$$"
if [ -s "${TMPDIR:-/tmp}/facts-check.$$" ]; then rm -f "${TMPDIR:-/tmp}/facts-check.$$"; exit 1; fi
rm -f "${TMPDIR:-/tmp}/facts-check.$$"; exit 0
