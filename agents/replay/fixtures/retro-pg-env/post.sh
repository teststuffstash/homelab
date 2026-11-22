# ── observation point ── not launcher code (the retro-gh-token-env post.sh shape): the fragment is
# what the manifest heredoc splices in verbatim, so printing it (not a derived fact about it) is
# what puts the actual env-entry text into the asserted stream.
if [ -n "$RETRO_PG_ENV" ]; then
  printf 'RETRO_PG_ENV (non-empty):\n%s\n' "$RETRO_PG_ENV"
else
  printf 'RETRO_PG_ENV: (empty)\n'
fi
