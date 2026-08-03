#!/bin/sh
# Lint the FU-NNN tracker against its own conventions (see docs/follow-ups.md "Conventions").
#
# FAILS on:
# - DANGLING: an FU id referenced in the repo but defined neither in the tracker nor the rolling
#   archive (an item was deleted but a reference survived — clean up: git grep FU-NNN).
#   References in historical/journal docs (TICK-LOG, ADRs, incidents, retros) are exempt: they
#   record what was true at the time and are never scrubbed.
# - BROKEN-POINTER: an item links a relative doc path that doesn't exist on disk.
#
# WARNS on (never fails — these are operator judgment calls):
# - STALE-ARCHIVE: archive entries past the freshness window (~a month), due for deletion.
# - OVERSIZE: an item over MAX_ITEM_LINES — the detail belongs in a doc, the item is a pointer
#   (CLAUDE.md → "Where things get written down").
# - DONE-MARKER: a resolution marker inside an OPEN item. Either the leg is done and the text is
#   history (move it to the doc) or the whole item is done (archive it). FU-080 sat open at 91
#   lines with zero remaining work because nobody re-read it.
# - NO-BACKLINK: a pointer's target doc never mentions the id, so the two halves can drift
#   apart silently.
# - UNARCHIVED: a checked `- [x]` item still in the tracker — resolution = archive, not tick.
set -eu
cd "$(git rev-parse --show-toplevel)"

TRACKER=docs/follow-ups.md
ARCHIVE=docs/follow-ups-archive.md
EXPIRY_DAYS=35
MAX_ITEM_LINES=10
# Historical/journal paths: references here are legal forever (never scrubbed).
HIST_EXCLUDES=":(exclude)agents/coordinator/TICK-LOG.md :(exclude)docs/adr.md :(exclude)docs/agents/retros :(exclude)docs/incidents"

# "Defined" means the id HAS ITS OWN ENTRY — not merely that the string appears somewhere.
# Matching loosely (plain grep over both files) counts an id mentioned only inside another item's
# "Relates <id>" cross-reference as defined, which let a resolved id stay referenced in shipped
# code comments for weeks while this lint reported clean. Anchor on the entry syntax instead.
# BURNED ids (declared in the tracker header, never reused) count as defined: the declaration IS
# the record, and it is permanent.
defined=$( (grep -oE '^- \[[ x]\] \*\*FU-[0-9]{3}\*\*' "$TRACKER"
            grep -oE 'FU-[0-9]{3} burned' "$TRACKER"
            [ -f "$ARCHIVE" ] && grep -oE '^- \*\*FU-[0-9]{3}\*\*' "$ARCHIVE"
           ) | grep -o 'FU-[0-9][0-9][0-9]' | sort -u)
# shellcheck disable=SC2086 # HIST_EXCLUDES is a list of pathspecs
# The TRACKER's own prose counts as references too (found 2026-08-03: an id expired out of
# the archive but lived on inside two other items' text — invisible to a scan that excludes
# the tracker). Archive prose stays excluded: entries are historical residue by contract.
referenced=$( { git grep -h -o 'FU-[0-9][0-9][0-9]' -- ":(exclude)$TRACKER" ":(exclude)$ARCHIVE" $HIST_EXCLUDES
                grep -v 'Next free id' "$TRACKER" | grep -o 'FU-[0-9][0-9][0-9]'; } | sort -u)

status=0
for id in $referenced; do
  if ! printf '%s\n' "$defined" | grep -qx "$id"; then
    echo "DANGLING $id — referenced but in neither $TRACKER nor $ARCHIVE. Clean up: git grep $id"
    status=1
  fi
done

# Per-item checks. awk splits the tracker into open-item blocks and emits "<id>|<lines>|<body>".
# An item = its header line + indented continuation lines ONLY. Anything else (blank line,
# section header, prose, a checked item) ends it — without that, the last item of every section
# absorbed the following "## Header" into its line count and body.
items=$(awk '
  /^- \[ \] \*\*FU-[0-9][0-9][0-9]\*\*/ {
    if (id != "") print id "|" n "|" body
    match($0, /FU-[0-9][0-9][0-9]/); id = substr($0, RSTART, RLENGTH); n = 0; body = $0
    n = 1; next
  }
  id != "" && /^      / { n++; body = body " " $0; next }
  id != "" { print id "|" n "|" body; id = "" }
  END { if (id != "") print id "|" n "|" body }
' "$TRACKER")

# A checked-off item still sitting in the tracker: resolution means ARCHIVING in the same commit,
# not ticking the box (see Conventions).
grep -n '^- \[x\]' "$TRACKER" | while IFS=: read -r ln rest; do
  echo "UNARCHIVED line $ln — a checked item in the tracker: move it to $ARCHIVE ($(printf '%s' "$rest" | grep -o 'FU-[0-9][0-9][0-9]' | head -1))"
done

# Markers that mean "this leg finished" — history, not deferred work.
DONE_RE='✅|\*\*DONE|\*\*SHIPPED|\*\*FIXED|\*\*DELIVERED|\*\*BUILT|\*\*VERIFIED|\*\*VALIDATED'

printf '%s\n' "$items" | while IFS='|' read -r id n body; do
  [ -n "$id" ] || continue

  if [ "$n" -gt "$MAX_ITEM_LINES" ]; then
    echo "OVERSIZE $id — ${n} lines (> ${MAX_ITEM_LINES}): move the detail to a doc, leave a pointer"
  fi

  if printf '%s' "$body" | grep -qE "$DONE_RE"; then
    echo "DONE-MARKER $id — a resolution marker inside an open item: move it to the doc, or archive the item"
  fi

  # Relative markdown links out of the tracker: verify the target exists and backlinks the id.
  # Anchored links (foo.md#section) count too — the anchor is stripped before the file check.
  printf '%s' "$body" | grep -oE '\]\([a-zA-Z0-9._/-]+\.md(#[A-Za-z0-9_-]+)?\)' |
    sed -e 's/^](//' -e 's/)$//' -e 's/#.*$//' | sort -u |
  while read -r rel; do
    [ -n "$rel" ] || continue
    target="docs/$rel"
    case "$rel" in ../*) target="$(printf '%s' "$rel" | sed 's|^\.\./||')" ;; esac
    if [ ! -f "$target" ]; then
      echo "BROKEN-POINTER $id — links $rel but docs/$rel does not exist"
      echo "FAIL" >> "${TMPDIR:-/tmp}/fu-lint-$$"
    elif ! grep -q "$id" "$target"; then
      echo "NO-BACKLINK $id — $target never mentions $id; add a 'Tracked by:' line so the two can't drift"
    fi
  done
done

if [ -f "${TMPDIR:-/tmp}/fu-lint-$$" ]; then
  rm -f "${TMPDIR:-/tmp}/fu-lint-$$"
  status=1
fi

# Freshness warnings on the archive (never fail — deleting is an operator judgment call).
# Two entry formats exist in the wild and BOTH must be seen: the stamp may follow the id
# (`- **FU-118** *(archived 2026-07-31)* — …`) or trail the entry (`- **FU-050** — … *(archived …)*`).
# Matching only the first left 8 entries permanently invisible to this check.
if [ -f "$ARCHIVE" ]; then
  now=$(date +%s)
  awk '
    /^- \*\*FU-[0-9][0-9][0-9]\*\*/ {
      if (id != "" && stamp != "") print id "|" stamp
      match($0, /FU-[0-9][0-9][0-9]/); id = substr($0, RSTART, RLENGTH); stamp = ""
    }
    id != "" && stamp == "" && match($0, /\(archived [0-9][0-9-]*/) {
      stamp = substr($0, RSTART + 10, RLENGTH - 10)
    }
    END { if (id != "" && stamp != "") print id "|" stamp }
  ' "$ARCHIVE" |
  while IFS='|' read -r id stamp; do
    ts=$(date -d "$stamp" +%s 2>/dev/null) || continue
    age=$(( (now - ts) / 86400 ))
    if [ "$age" -gt "$EXPIRY_DAYS" ]; then
      echo "STALE-ARCHIVE $id — archived ${age}d ago (> ${EXPIRY_DAYS}d): delete the entry + scrub living-code/doc refs"
    fi
  done
fi

open_items=$(printf '%s\n' "$items" | grep -c . || true)
tracker_lines=$(wc -l < "$TRACKER" | tr -d ' ')
echo "follow-ups: $(printf '%s\n' "$defined" | grep -c .) defined (tracker+archive), $(printf '%s\n' "$referenced" | grep -c . || true) ids referenced elsewhere"
echo "            ${open_items} open items in ${tracker_lines} lines (cap ${MAX_ITEM_LINES}/item)"
exit $status
