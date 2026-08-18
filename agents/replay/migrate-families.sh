#!/usr/bin/env bash
# migrate-families.sh — FU-167 cleanup move 5: families become directories.
#
# Reads agents/replay/families.tsv (fixture-dir → family) and emits/executes the `git mv`
# commands that move every actions/suite fixture to `fixtures/<family>/<fixture>/`. The
# table is the committed artifact; this script is how the rename is (re-)applied — run it
# again after a rebase that resurrects old paths (a missing source or an existing target
# is a no-op, not an error).
#
#   bash agents/replay/migrate-families.sh            # execute the moves
#   bash agents/replay/migrate-families.sh --dry-run  # print, don't execute
#
# A fixture dir inside a family drops the `<family>-` name prefix when it carries it
# (c4c5-infeasible-parks → c4c5-infeasible/parks); the `name:` field inside fixture.yaml
# is untouched (zero churn in expected streams and reporting). Tables (`mode: table`) stay
# at depth 1 and are deliberately absent from the table.
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="$HERE/fixtures"
TABLE="$HERE/families.tsv"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1
[ -f "$TABLE" ] || { echo "families.tsv not found: $TABLE" >&2; exit 2; }

n=0; moved=0; skipped=0
while IFS=$'\t' read -r fixture family; do
  case "$fixture" in ''|\#*) continue ;; esac
  n=$((n+1))
  [ -d "$FIX/$fixture" ] || { skipped=$((skipped+1)); continue; }   # already moved (a rebase resurrected nothing)
  inner="$fixture"
  case "$inner" in "$family"-*) inner="${inner#"$family"-}" ;; esac
  target="$FIX/$family/$inner"
  if [ "$DRY" = 1 ]; then
    echo "git mv agents/replay/fixtures/$fixture agents/replay/fixtures/$family/$inner"
    moved=$((moved+1)); continue
  fi
  if [ "$family" = "$fixture" ]; then
    # singleton: the family dir IS the source dir — move via a temp name, then into itself
    if [ -e "$target" ]; then echo "target exists, skipping: $target" >&2; skipped=$((skipped+1)); continue; fi
    tmp="$FIX/$fixture.tmp"
    [ -e "$tmp" ] && { echo "temp path exists: $tmp" >&2; exit 2; }
    git mv "$FIX/$fixture" "$tmp"
    mkdir -p "$FIX/$family"
    git mv "$tmp" "$target"
  else
    mkdir -p "$FIX/$family"
    if [ -e "$target" ]; then echo "target exists, skipping: $target" >&2; skipped=$((skipped+1)); continue; fi
    git mv "$FIX/$fixture" "$target"
  fi
  moved=$((moved+1))
done < "$TABLE"

printf 'families.tsv: %s rows; moved %s, skipped %s\n' "$n" "$moved" "$skipped"
