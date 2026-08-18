# ── observation point ── the diff's verdict, in the vocabulary leg 1 is contracted in. The
# candidate LIST is asserted, not just its length: "22 reduce to 2" is only the acceptance if the
# two are the right two.
printf 'NEW-IDS %s\n' "$(jq length "$WORK/new.json")"
jq -r '.[].id' "$WORK/candidates.json" | sed 's/^/CANDIDATE /'
printf 'CANDIDATES %s\n' "$(jq length "$WORK/candidates.json")"
printf 'SUPPRESSED batch=%s variant=%s\n' "$SUP_BATCH" "$SUP_VARIANT"
# One line for the whole suppressed set, never N rows — folded to one physical line here because
# the digest string carries its own leading blank lines.
printf 'DIGEST-LINE %s\n' "${SUPPRESSED_LINE//$'\n'/}"
