# ── observation point ── not harvest code. The both-delivered case must append NOTHING to the PR
# body: a partial-run warning on a complete run would train the reader to ignore it. Its sibling
# `retro-harvest-one-cell-dead` pins the populated half.
case "$DEAD_NOTE" in
  "") echo "DEAD_NOTE: empty — nothing appended to the PR body" ;;
  *)  echo "DEAD_NOTE: PRESENT on a run where BOTH cells delivered" ;;
esac
