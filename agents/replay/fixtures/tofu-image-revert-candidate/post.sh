printf 'PRNUM=%s SHA=%s TITLE=%s\n' "$PRNUM" "$SHA" "$TITLE"
printf 'FILES=%s\n' "$(printf '%s' "$FILES" | tr '\n' ' ')"
