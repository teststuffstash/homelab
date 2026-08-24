# ── observation point ── not scan code. Reaching this line IS the dispatch: in the shipped script
# the pr-cap-per-base block that did not `continue` falls through to the lines that append the
# unit to `$iss`.
printf 'DISPATCH #%s (base=%s)\n' "$qnum" "$qbase"
# Close the while loop — the TSV is produced by the SAME jq pipeline as the scan, so this
# fixture proves that the jq extraction works (bases are correctly extracted as strings, and
# no stream truncation occurs after a row with a Base: line).
done < <(printf '%s' "$queued" | jq -r '.[] | [ .number, .title, (([(.body // "") | scan("(?mi)^[ \t]*touches:[ \t]*(.+)$")] | flatten | join(",")) | if . == "" then "-" else . end), ([((.blockedBy // {}).nodes // [])[] | .url | capture("github.com/(?<r>[^/]+/[^/]+)/issues/(?<n>[0-9]+)") | "\(.r)#\(.n)"] | unique | join(", ") | if . == "" then "-" else . end), (if .isPinned then "P" else "-" end), ([.labels[].name | select(startswith("task/"))] | first // "task/fix" | ltrimstr("task/")), ((.parent.number // "") | tostring), (([(.body // "") | scan("(?mi)^[ \t]*base:[ \t]*(.+)$")] | flatten | first // "")) ] | join("|")')
# `orphans` is a \n-joined string; %b expands it so each reported line lands on its own line and
# `diff` stays line-oriented.
printf '%b' "$orphans" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'ORPHAN %s\n' "$l"; fi
done
echo "REACHED: end"