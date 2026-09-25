# bot-suffix-normalized: the reviewer's login arrives as `homelab-reviewer[bot]` (the REST-vs-
# GraphQL suffix mismatch the reflex normalizes with sub("\\[bot\\]$"; "")). Same verdict.
.reviews |= map(if (.author.login == "homelab-reviewer") then .author.login = "homelab-reviewer[bot]" else . end)
