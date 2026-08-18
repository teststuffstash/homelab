# ── observation point ── not harvest code. Both cells delivered, so the partial-run warning must
# stay empty here exactly as in `retro-harvest-slug`: the collision guard renames files and must
# not touch the DEAD/N bookkeeping on its way past. Its sibling `retro-harvest-one-cell-dead` pins
# the populated half.
case "$DEAD_NOTE" in
  "") echo "DEAD_NOTE: empty — nothing appended to the PR body" ;;
  *)  echo "DEAD_NOTE: PRESENT on a run where BOTH cells delivered" ;;
esac
