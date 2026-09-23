# ── post.sh ── reached only when the retry did NOT fire (a fired retry exits inside the clause,
# before the doorbell). Echo the decision so the action stream names which side the row is on.
printf '→ post: RETRY_FIRE=[%s] RETRY_CELL=[%s]\n' "${RETRY_FIRE:-}" "${RETRY_CELL:-}"