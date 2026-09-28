printf 'PRNUM=%s SHA=%s TITLE=%s\n' "$PRNUM" "$SHA" "$TITLE"
printf 'FILES=%s\n' "$(printf '%s' "$FILES" | tr '\n' ' ')"
printf 'CONTENT_LINES=%s\n' "$(printf '%s' "$CONTENT_LINES" | tr '\n' '|')"
