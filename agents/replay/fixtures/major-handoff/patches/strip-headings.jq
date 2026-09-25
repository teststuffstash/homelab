# approved-without-headings: the bot's APPROVED loses two of the four headings — `Known issues`
# becomes prose and `Evidence` a bare label with no `##`/`**` (the plain `Evidence:` form is NOT a
# heading; the refusal must NAME both). Only the APPROVED review is touched.
.reviews |= map(if .state == "APPROVED"
  then .body |= (sub("## Known issues"; "Known issues, in prose:") | sub("## Evidence"; "Evidence:"))
  else . end)
