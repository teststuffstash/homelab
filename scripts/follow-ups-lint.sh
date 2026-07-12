#!/bin/sh
# Lint FU-NNN follow-up references (see docs/follow-ups.md "Conventions").
# - FAILS if an FU id is referenced in the repo but defined neither in the tracker nor the
#   rolling archive (an item was deleted but a reference survived — clean up: git grep FU-NNN).
#   References in historical/journal docs (TICK-LOG, ADRs, retros) are exempt: they record
#   what was true at the time and are never scrubbed.
# - WARNS on archive entries past the freshness window (~a month) — those are due for deletion
#   (+ a scrub of any remaining references in living code/docs). git history keeps the record.
set -eu
cd "$(git rev-parse --show-toplevel)"

TRACKER=docs/follow-ups.md
ARCHIVE=docs/follow-ups-archive.md
EXPIRY_DAYS=35
# Historical/journal paths: references here are legal forever (never scrubbed).
HIST_EXCLUDES=":(exclude)agents/coordinator/TICK-LOG.md :(exclude)docs/adr.md :(exclude)docs/agents/retros"

defined=$( (grep -o 'FU-[0-9][0-9][0-9]' "$TRACKER"; [ -f "$ARCHIVE" ] && grep -o 'FU-[0-9][0-9][0-9]' "$ARCHIVE") | sort -u)
# shellcheck disable=SC2086 # HIST_EXCLUDES is a list of pathspecs
referenced=$(git grep -h -o 'FU-[0-9][0-9][0-9]' -- ":(exclude)$TRACKER" ":(exclude)$ARCHIVE" $HIST_EXCLUDES | sort -u)

status=0
for id in $referenced; do
  if ! printf '%s\n' "$defined" | grep -qx "$id"; then
    echo "DANGLING $id — referenced but in neither $TRACKER nor $ARCHIVE. Clean up: git grep $id"
    status=1
  fi
done

# Freshness warnings on the archive (never fail — deleting is an operator judgment call).
if [ -f "$ARCHIVE" ]; then
  now=$(date +%s)
  grep -o 'FU-[0-9][0-9][0-9]\*\* \*(archived [0-9-]*' "$ARCHIVE" | sed 's/\*\* \*(archived /|/' |
  while IFS='|' read -r id stamp; do
    ts=$(date -d "$stamp" +%s 2>/dev/null) || continue
    age=$(( (now - ts) / 86400 ))
    if [ "$age" -gt "$EXPIRY_DAYS" ]; then
      echo "STALE-ARCHIVE $id — archived ${age}d ago (> ${EXPIRY_DAYS}d): delete the entry + scrub living-code/doc refs"
    fi
  done
fi

echo "follow-ups: $(printf '%s\n' "$defined" | grep -c .) defined (tracker+archive), $(printf '%s\n' "$referenced" | grep -c . || true) ids referenced elsewhere"
exit $status
