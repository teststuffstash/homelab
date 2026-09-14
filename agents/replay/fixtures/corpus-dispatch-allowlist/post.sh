# ── observation point ── not manifest code. The dispatch BODY is the observable the CALL line
# cannot carry: `gh api … --input /tmp/dispatch.json` names a file, not its bytes, so the action
# stream would pin "a dispatch happened" without pinning WHAT it dispatched. Print it compactly
# (one line, so the stream stays line-oriented) — the exact `client_payload` the coordinator
# identity would POST. Reached only on the accept rows: a refusal `exit 1`s inside the block.
jq -c . /tmp/dispatch.json