# ── observation point ── not launcher code. HOST_ALIASES is the variable the pod-spec heredoc
# splices in verbatim. Print it so the assertion stream captures the rendered hostAliases block.
if [ -n "$HOST_ALIASES" ]; then
  printf 'HOST_ALIASES (non-empty):\n%s\n' "$HOST_ALIASES"
else
  printf 'HOST_ALIASES: (empty)\n'
fi