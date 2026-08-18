# ── observation point ── the rank, explicitly. The digest body in the `gh issue create` CALL above
# already carries the order and the columns, but a table read by eye is not an assertion: this
# prints the sort key each candidate was ranked on, so a fallback that stopped falling back
# (agentic → coding → intelligence) reds here with the reason visible.
jq -r 'to_entries[] | "RANK \(.key + 1) \(.value.model) free=\(.value.free) benched=\(.value.bench.benched) score=\(.value.score)"' \
  "$WORK/ranked.json"
