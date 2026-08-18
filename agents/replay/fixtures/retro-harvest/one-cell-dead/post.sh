# ── observation point ── not harvest code. DEAD_NOTE is ~300 characters of prose that the harvest
# splices into the PR body a few lines below the block; the fixture asserts what must not move
# rather than the wording (fixture.yaml contract 3, the responder SELF_NOTE pattern).
case "$DEAD_NOTE" in
  "")                       echo "DEAD_NOTE: empty — the PR body says nothing about a missing cell" ;;
  *"goose:deepseek/deepseek-v4-pro"*) echo "DEAD_NOTE: names the cell that produced no report" ;;
  *)                        echo "DEAD_NOTE: PRESENT but does not name the dead cell" ;;
esac
case "$DEAD_NOTE" in
  *"one cell's view"*) echo "DEAD_NOTE: warns the reader this is not the cross-checked pair" ;;
  "")                  echo "DEAD_NOTE: no partial-run warning (nothing appended)" ;;
  *)                   echo "DEAD_NOTE: cell named but the not-a-pair warning is MISSING" ;;
esac
