# ── observation point ── not launcher code. NIX_ENV is spliced into the pod manifest heredoc
# verbatim, so printing the fragment itself is what puts the real env-entry text into the
# asserted stream (the python-profile-env precedent).
printf 'NIX_ENV:\n%s\n' "$NIX_ENV"
