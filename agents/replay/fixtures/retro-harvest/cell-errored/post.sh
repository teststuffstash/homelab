# ── observation point ── not harvest code; the same predicate pair the dead-cell sibling uses. The
# note is prose that will legitimately be reworded, so what is asserted is that it EXISTS, NAMES the
# cell, and warns the reader this is not the cross-checked pair (fixture.yaml contract 4).
case "$DEAD_NOTE" in
  "")                                 echo "DEAD_NOTE: empty — the PR body says nothing about a missing cell" ;;
  *"goose:deepseek/deepseek-v4-pro"*) echo "DEAD_NOTE: names the cell that produced no report" ;;
  *)                                  echo "DEAD_NOTE: PRESENT but does not name the dead cell" ;;
esac
case "$DEAD_NOTE" in
  *"one cell's view"*) echo "DEAD_NOTE: warns the reader this is not the cross-checked pair" ;;
  "")                  echo "DEAD_NOTE: no partial-run warning (nothing appended)" ;;
  *)                   echo "DEAD_NOTE: cell named but the not-a-pair warning is MISSING" ;;
esac
