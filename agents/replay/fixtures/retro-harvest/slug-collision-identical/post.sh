# ── observation point ── not harvest code. Both cells delivered, so the partial-run warning must
# stay empty here exactly as in the sibling fixtures: the cell-index disambiguation renames files
# and must not touch the DEAD/N bookkeeping on its way past.
case "$DEAD_NOTE" in
  "") echo "DEAD_NOTE: empty — nothing appended to the PR body" ;;
  *)  echo "DEAD_NOTE: PRESENT on a run where BOTH cells delivered" ;;
esac
