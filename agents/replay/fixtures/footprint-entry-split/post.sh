# ── observation point ── not clause code. The three readers' verdicts on the same pair: HOLD is
# fp_conflict's answer, STRICT is fp_conflict_strict's, ESCAPES is touches_check's. A correct
# splitter makes them agree — an annotated entry covers its bare path in all three.
_esc="$(printf '%s' "$ESCAPES" | tr '\n' ',')"
printf 'HOLD %s\n' "$HOLD"
printf 'STRICT %s\n' "$STRICT"
printf 'ESCAPES [%s]\n' "${_esc%,}"