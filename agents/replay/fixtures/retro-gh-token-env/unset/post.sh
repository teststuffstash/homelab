# ── observation point ── identical to ../set/post.sh (kept as a separate copy rather than a
# `../` reach — the cleanup-move register (README.md move 5) tracks that debt platform-wide, not
# per new family).
if [ -n "$RETRO_GH_TOKEN_ENV" ]; then
  printf 'RETRO_GH_TOKEN_ENV (non-empty):\n%s\n' "$RETRO_GH_TOKEN_ENV"
else
  printf 'RETRO_GH_TOKEN_ENV: (empty)\n'
fi
