# ── observation point ── the cell-keyed merge and the per-model verdict store, explicitly. The
# digest body in the `gh issue create` CALL above already carries the canary column, but the rules
# (contradiction / common-cause) shape `$WORK/canary.jsonl` and the merge onto the ranked rows —
# print both so a rule that stopped applying reds here with the values visible.
jq -r 'to_entries[] | "ROW \(.key + 1) \(.value.model) benched=\(.value.bench.benched) canary=\(.value.canary // "-")"' "$WORK/ranked.json"
jq -s -r '.[] | "CANARY \(.model) \(.canary_verdict) free=\(.free)"' "$WORK/canary.jsonl"
