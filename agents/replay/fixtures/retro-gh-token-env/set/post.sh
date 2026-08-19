# ── observation point ── not launcher code. Mirrors the harness-run-cmd sibling's post.sh: the
# fragment is what the manifest heredoc splices in verbatim, so printing it (not a derived fact
# about it) is what puts the actual env-entry text into the asserted stream.
if [ -n "$RETRO_GH_TOKEN_ENV" ]; then
  printf 'RETRO_GH_TOKEN_ENV (non-empty):\n%s\n' "$RETRO_GH_TOKEN_ENV"
else
  printf 'RETRO_GH_TOKEN_ENV: (empty)\n'
fi
