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
#   bash agents/retro-report-floor.sh <in> <out-report.md> <log|report>
#
# The third arg is the CALLER'S declaration of what <in> is — it is not auto-detected, because
# the two shapes are ambiguous exactly where it matters (PR#620 review r1): a cell that dies
# without ever emitting a marker leaves a marker-less RAW session transcript, and transcript
# noise (banners, tool calls, streamed reasoning) clears any content floor a real report would —
# an auto-detect that falls back to "treat as report" would commit the raw log as the report,
# the failure class this helper exists to close.
#   log    — <in> is a RIDE LOG: BOTH markers are REQUIRED. The block between them is extracted
#            with the harvest's OWN extraction: the awk last-complete-block pass below
#            (homelab#1096 — the old repeating sed range concatenated every block) — so the
#            self-check and the harvest can never disagree about what a "report" is
#            (agents/coordinator/retro-argo.yaml, both callers). Missing/partial markers →
#            reason `no-markers`, whatever else the log contains.
#   report — <in> is already a committed, harvested report file (retro-session.sh --review):
#            used AS-IS, floor-checked directly. Markers never appear in a harvested report
#            (extraction strips them), so no marker logic applies.
#
# EXIT 0: a report meeting the floor was written to <out>.
# EXIT 1: missing/empty/under-floor — exactly one reason line on stderr:
#   no-markers                          — a broken/partial marker pair (see above)
#   empty                               — the file to check (input or extracted block) has no bytes
#   under-floor: N content lines < 20   — has content, but not enough of it
set -euo pipefail

IN="${1:-}"; OUT="${2:-}"; MODE="${3:-}"
if [ -z "$IN" ] || [ -z "$OUT" ] || { [ "$MODE" != "log" ] && [ "$MODE" != "report" ]; }; then
  echo "usage: retro-report-floor.sh <in> <out-report.md> <log|report>" >&2
  exit 2
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

fail() { printf '%s\n' "$1" >&2; exit 1; }

if [ ! -f "$IN" ]; then
  fail "empty"
fi

if [ "$MODE" = "log" ]; then
  HAS_BEGIN=0; HAS_END=0
  grep -q 'BEGIN-RETRO-REPORT' "$IN" && HAS_BEGIN=1
  grep -q 'END-RETRO-REPORT' "$IN" && HAS_END=1
  if [ "$HAS_BEGIN" = 1 ] && [ "$HAS_END" = 1 ]; then
    # Complete marker pair — the harvest's own extraction, verbatim.
    # homelab#1096: sed's repeating address range (/BEGIN/,/END/) matches EVERY block and
    # everything BETWEEN them — empty template echoes and inter-block harness text land in the
    # committed report. awk extracts only the LAST complete block, dropping intermediate markers
    # and inter-block text. Both callers (retro-cell self-check and harvest) share this helper,
    # so they can never disagree.
    awk '
      /BEGIN-RETRO-REPORT/ { buf = ""; inside = 1; next }
      /END-RETRO-REPORT/   { inside = 0; last_block = buf; buf = ""; next }
      inside               { buf = buf $0 ORS }
      END                  { printf "%s", last_block }
    ' "$IN" > "$TMP"
    CONTENT_SRC="$TMP"
  else
    # Zero or one marker: no complete report block exists in this log. A marker-less log is
    # NEVER floor-checked as-is here — however long it is, it is transcript, not report
    # (PR#620 review r1: the raw-log shape must fail no-markers, not sneak past the floor).
    fail "no-markers"
  fi
else
  # report mode: the file IS the report (the --review case). Used as-is.
  CONTENT_SRC="$IN"
fi

[ -s "$CONTENT_SRC" ] || fail "empty"

N=$(grep -vcE '^[[:space:]]*$|^#' "$CONTENT_SRC" || true)
[ "$N" -ge 20 ] || fail "under-floor: ${N} content lines < 20"

cp "$CONTENT_SRC" "$OUT"
