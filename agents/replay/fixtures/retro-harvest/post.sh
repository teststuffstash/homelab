# ── observation point ── shared across all five retro-harvest rows (not harvest code). DEAD_CELL
# is this row's OWN declaration of which cell (if any) it expects the harvest to have lost — set
# via the row's `env:` column, never re-derived from CELL_A/CELL_B, so a row that renames its
# cells without updating DEAD_CELL reds instead of silently asserting the wrong thing.
#
# Two shapes, merged from the two originals (fixture.yaml carries the per-row contract):
#   DEAD_CELL set   — `cell-errored` / `one-cell-dead`: DEAD_NOTE must name the dead cell and warn
#                      the reader this is not the cross-checked pair.
#   DEAD_CELL unset — `slug` / `slug-collision` / `slug-collision-identical`: DEAD_NOTE must stay
#                      empty — a partial-run warning on a complete run would train the reader to
#                      ignore it.
if [ -n "${DEAD_CELL:-}" ]; then
  case "$DEAD_NOTE" in
    "")             echo "DEAD_NOTE: empty — the PR body says nothing about a missing cell" ;;
    *"$DEAD_CELL"*) echo "DEAD_NOTE: names the cell that produced no report" ;;
    *)              echo "DEAD_NOTE: PRESENT but does not name the dead cell" ;;
  esac
  case "$DEAD_NOTE" in
    *"one cell's view"*) echo "DEAD_NOTE: warns the reader this is not the cross-checked pair" ;;
    "")                  echo "DEAD_NOTE: no partial-run warning (nothing appended)" ;;
    *)                   echo "DEAD_NOTE: cell named but the not-a-pair warning is MISSING" ;;
  esac
else
  case "$DEAD_NOTE" in
    "") echo "DEAD_NOTE: empty — nothing appended to the PR body" ;;
    *)  echo "DEAD_NOTE: PRESENT on a run where BOTH cells delivered" ;;
  esac
fi
