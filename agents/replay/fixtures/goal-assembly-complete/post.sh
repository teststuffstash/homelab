# ── observation point ── not scan code. Three products of the goal lane, rendered so the fixture
# pins what the REST of the scan then reads: `gacted` (did a lifecycle leg move this goal), `units`
# (did goal-review ALSO emit — it must not, for a goal the lane just acted on) and `orphans` (the
# report surface a human reads). The absence of a `gh issue close` in the CALL stream above is the
# other half of this fixture's contract, and diff asserts absences for free.
printf 'GACTED %s\n' "${gacted:-<none>}"
printf 'UNITS %s\n' "$(printf '%b' "${units:-<none>}" | tr '\n' ' ')"
printf 'ORPHANS %s\n' "$(printf '%b' "${orphans:-<none>}" | tr '\n' ' ')"
echo "REACHED: end"
