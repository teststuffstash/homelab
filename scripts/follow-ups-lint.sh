#!/bin/sh
# Lint FU-NNN follow-up references (see docs/follow-ups.md "Conventions").
# Fails if any FU id is referenced somewhere in the repo but no longer defined in the
# tracker — i.e. an item was resolved/deleted but a reference survived. Reminder:
# resolving an item = `git grep FU-NNN` and delete the item + every reference together.
set -eu
cd "$(git rev-parse --show-toplevel)"

TRACKER=docs/follow-ups.md
defined=$(grep -o 'FU-[0-9][0-9][0-9]' "$TRACKER" | sort -u)
referenced=$(git grep -h -o 'FU-[0-9][0-9][0-9]' -- ":(exclude)$TRACKER" | sort -u)

status=0
for id in $referenced; do
  if ! printf '%s\n' "$defined" | grep -qx "$id"; then
    echo "DANGLING $id — referenced but not in $TRACKER (resolved?). Clean up: git grep $id"
    status=1
  fi
done

echo "follow-ups: $(printf '%s\n' "$defined" | grep -c .) defined, $(printf '%s\n' "$referenced" | grep -c . || true) ids referenced elsewhere"
exit $status
