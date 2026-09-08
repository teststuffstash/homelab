# ── observation point ── the cell-keyed merge and the per-model verdict store, explicitly. The
# digest body in the `gh issue create` CALL above already carries the canary column, but the rules
# (contradiction / common-cause) shape `$WORK/canary.jsonl` and the merge onto the ranked rows —
# print both so a rule that stopped applying reds here with the values visible.
jq -r 'to_entries[] | "ROW \(.key + 1) \(.value.model) benched=\(.value.bench.benched) canary=\(.value.canary // "-")"' "$WORK/ranked.json"
jq -s -r '.[] | "CANARY \(.model) \(.canary_verdict) free=\(.free)"' "$WORK/canary.jsonl"

# The digest body moved off the CALL line onto `--body-file` (ADR-122 (3), homelab#1460 leg 4) —
# re-emit it, newline-escaped as the stubs record an argv, so the canary column stays asserted.
# The WITHHELD rows of this table write no file and print nothing, which is the gate's contract.
if [ -n "${DIGEST_BODY_FILE:-}" ] && [ -f "$DIGEST_BODY_FILE" ]; then
  printf 'DIGEST-BODY %s\n' "$(sed ':a;N;$!ba;s/\n/\\n/g' "$DIGEST_BODY_FILE")"
fi
