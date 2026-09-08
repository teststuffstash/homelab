# ── observation point ── not scan code. Four products of the goal lane, rendered so the fixture
# pins what the REST of the scan then reads: `gacted` (did a lifecycle leg move this goal), `units`
# (did goal-review ALSO emit — it must not, for a goal the lane just acted on) and `orphans` (the
# report surface a human reads). The absence of a `gh issue close` in the CALL stream above is the
# other half of this fixture's contract, and diff asserts absences for free.
printf 'GACTED %s\n' "${gacted:-<none>}"
printf 'UNITS %s\n' "$(printf '%b' "${units:-<none>}" | tr '\n' ' ')"
# `goal_theme_side` (homelab#1423, ADR-126 v1.3.1): the theme nominations + completed themes the
# dispatch site appends to a goal-checkpoint unit's `--item` string — the side value is what the
# checkpoint session reads, so the row pins it, not just the unit.
_themes="$(printf '%s' "${goal_theme_side:-}" | sed 's/^ *//; s/ *$//')"
printf 'THEMES %s\n' "${_themes:-<none>}"
printf 'ORPHANS %s\n' "$(printf '%b' "${orphans:-<none>}" | tr '\n' ' ')"
echo "REACHED: end"
