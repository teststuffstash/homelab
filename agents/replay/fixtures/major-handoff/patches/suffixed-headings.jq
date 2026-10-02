# suffixed-headings (homelab#2032, 2026-09-28): the lens's re-review wrote the Evidence heading
# with a suffix — `## Evidence — re-review at new head <sha>` — and the old `$`-anchored regex
# refused a complete APPROVED review. The heading WORD is the contract; a suffix after a
# separator passes, and `## Evidenced` (no separator) still does not.
.reviews |= map(if .state == "APPROVED" then .body |= sub("## Evidence\n"; "## Evidence — re-review at new head 79245410\n") else . end)
