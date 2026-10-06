# ── observation point ── not clause code. The selector's products: the run it picked, the first
# line of the log tail it read, and the index line it wrote. `PF_RUN_ID` is the whole point of the
# table — the settled row picks the concluded-failure run, the unsettled row falls back to the
# newest run on the branch.
printf 'RUN %s\n' "${PF_RUN_ID:-<none>}"
printf 'LOG %s\n' "$(printf '%s' "${PF_LOG_TAIL:-}" | head -1)"
printf 'INDEX %s\n' "$(printf '%s' "${PF_INDEX:-}" | tr -d '\n')"
echo "REACHED: end"
