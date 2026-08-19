#!/usr/bin/env bash
# retro-report-floor.sh — the ONE content floor for a retro report (homelab#587 leg 3, fixes #590).
#
# Born from the 2026-08-17 unattended fire: the deepseek cell's ride log carried a valid
# BEGIN/END-RETRO-REPORT block whose contents were the report TEMPLATE's bare section headings —
# nine lines, no prose — because the model never filled them in. `[ -s report ]` (both the cell's
# own self-check in retro-argo.yaml and the harvest's extraction) is satisfied by nine bytes just
# as happily as by a real report, so the cell read Succeeded and a human opened
# docs/agents/retros/2026-08-17-oracle-r4-deepseek-v4-pro.md to find only headings. Separately,
# `retro-session.sh --review` checked only `[ -f "$REVIEW" ]` before dispatching a paid
# cross-review ride AGAINST that same empty skeleton.
#
# THE FLOOR: at least 20 content lines, where a content line is neither blank nor a markdown
# heading (`^#`). Derivation, from the two ends of the observed failure shape:
#   - the empty skeleton (docs/agents/retros/2026-08-17-oracle-r4-deepseek-v4-pro.md) is 9 lines,
#     ALL of them headings — 0 content lines.
#   - a real, landed report (docs/agents/retros/2026-08-17-oracle-r4-opus.md, the sibling cell of
#     the same run) is 139 lines / 78 content lines.
#   20 sits with wide margin above the skeleton's 0 and wide margin below a real report's 78 —
#   it separates the two shapes on either side without being tuned to either one.
#
# USAGE:
#   bash agents/retro-report-floor.sh <ride-log-or-report.md> <out-report.md>
#
# INPUT SHAPE (auto-detected, no flag — every caller passes a plain path):
#   - BOTH markers present (BEGIN-RETRO-REPORT and END-RETRO-REPORT): treated as a RIDE LOG. The
#     block between them is extracted with the harvest's OWN extraction command, verbatim —
#     `sed -n '/BEGIN-RETRO-REPORT/,/END-RETRO-REPORT/p' | sed '1d;$d'` — so a self-check and the
#     harvest can never disagree about what a "report" is (agents/coordinator/retro-argo.yaml).
#   - EXACTLY ONE of the two markers present: a report block that was started and never closed
#     (a session cut off mid-write) — reason `no-markers`, no floor check attempted.
#   - NEITHER marker present: not a ride-log wrapper at all — the `--review` case, where $REVIEW
#     is already a committed, harvested report file. Used AS-IS: floor-checked directly.
#
# EXIT 0: a report meeting the floor was written to <out>.
# EXIT 1: missing/empty/under-floor — exactly one reason line on stderr:
#   no-markers                          — a broken/partial marker pair (see above)
#   empty                               — the file to check (input or extracted block) has no bytes
#   under-floor: N content lines < 20   — has content, but not enough of it
set -euo pipefail

IN="${1:-}"; OUT="${2:-}"
if [ -z "$IN" ] || [ -z "$OUT" ]; then
  echo "usage: retro-report-floor.sh <ride-log-or-report.md> <out-report.md>" >&2
  exit 2
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

fail() { printf '%s\n' "$1" >&2; exit 1; }

if [ ! -f "$IN" ]; then
  fail "empty"
fi

HAS_BEGIN=0; HAS_END=0
grep -q 'BEGIN-RETRO-REPORT' "$IN" && HAS_BEGIN=1
grep -q 'END-RETRO-REPORT' "$IN" && HAS_END=1

if [ "$HAS_BEGIN" = 1 ] && [ "$HAS_END" = 1 ]; then
  # Ride log with a complete marker pair — the harvest's own extraction, verbatim.
  sed -n '/BEGIN-RETRO-REPORT/,/END-RETRO-REPORT/p' "$IN" | sed '1d;$d' > "$TMP"
  CONTENT_SRC="$TMP"
elif [ "$HAS_BEGIN" = 1 ] || [ "$HAS_END" = 1 ]; then
  # A report block that was started (or ended) but never completed — a real, distinct failure
  # shape from "no report at all", and not something a floor count can characterize usefully.
  fail "no-markers"
else
  # No marker at all: not a ride-log wrapper — the --review case. Use the file as-is.
  CONTENT_SRC="$IN"
fi

[ -s "$CONTENT_SRC" ] || fail "empty"

N=$(grep -vcE '^[[:space:]]*$|^#' "$CONTENT_SRC" || true)
[ "$N" -ge 20 ] || fail "under-floor: ${N} content lines < 20"

cp "$CONTENT_SRC" "$OUT"
