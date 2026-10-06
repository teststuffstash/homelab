# app-moves-parks: the same structured line says the app DID move (`appVersion: A → B`) — the
# human lane holds until the chart has a lease (ADR-150) or a receiver (ADR-149): park, as before.
.reviews |= map(if .state == "APPROVED"
  then .body |= sub("## Upstream\n\n"; "## Upstream\n\nappVersion: 4.1.0 → 4.1.4\n")
  else . end)
