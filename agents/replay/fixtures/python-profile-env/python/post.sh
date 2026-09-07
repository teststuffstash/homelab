# ── observation point ── not launcher code. PYTHON_ENV is spliced into the pod manifest heredoc
# verbatim, so printing the fragment itself (never a derived fact about it) is what puts the real
# env-entry text into the asserted stream.
if [ -n "$PYTHON_ENV" ]; then
  printf 'PYTHON_ENV (non-empty):\n%s\n' "$PYTHON_ENV"
else
  printf 'PYTHON_ENV: (empty)\n'
fi
