# packaging-only-arms (ADR-141 as amended 2026-10-06, later): the bot's APPROVED opens `## Upstream`
# with the lens's structured verdict line `appVersion: unchanged (<v>)` — the chart index says the
# embedded app did not move, so the handoff ARMS auto-merge instead of parking on a human.
.reviews |= map(if .state == "APPROVED"
  then .body |= sub("## Upstream\n\n"; "## Upstream\n\nappVersion: unchanged (v4.1.4)\n")
  else . end)
