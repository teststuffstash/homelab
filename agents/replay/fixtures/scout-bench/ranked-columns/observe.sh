# ── observation point ── the rank, explicitly. The digest body in the `gh issue create` CALL above
# already carries the order and the columns, but a table read by eye is not an assertion: this
# prints the sort key each candidate was ranked on, so a fallback that stopped falling back
# (agentic → coding → intelligence) reds here with the reason visible.
jq -r 'to_entries[] | "RANK \(.key + 1) \(.value.model) free=\(.value.free) benched=\(.value.bench.benched) score=\(.value.score)"' \
  "$WORK/ranked.json"

# The digest body no longer rides the `gh issue create` CALL line — the filing composes it into
# `$WORK/digest-body.md` and posts `--body-file` (ADR-122 (3), homelab#1460 leg 4). Re-emit the
# file here, newline-escaped exactly the way the PATH-shim stubs record an argv, so every column
# and rank assertion this family was written for survives the move byte for byte. A digest the
# filing gate WITHHELD leaves no file and prints nothing.
if [ -n "${DIGEST_BODY_FILE:-}" ] && [ -f "$DIGEST_BODY_FILE" ]; then
  printf 'DIGEST-BODY %s\n' "$(sed ':a;N;$!ba;s/\n/\\n/g' "$DIGEST_BODY_FILE")"
fi
