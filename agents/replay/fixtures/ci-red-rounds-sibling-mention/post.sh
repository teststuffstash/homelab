# ── observation point ── not scan code. The four products the rest of the ci-red clause branches
# on. `attempts` and `noop_round` decide dispatch-vs-arbitrate; `red_rounds`/`red_rounds_key` are
# what the operator reads in the orphans line and what the cap compares against.
printf 'ATTEMPTS %s\n' "$attempts"
printf 'NOOP %s\n' "${noop_round:-<none>}"
printf 'RED_ROUNDS %s\n' "$red_rounds"
printf 'RED_ROUNDS_KEY %s\n' "$red_rounds_key"
echo "REACHED: end"