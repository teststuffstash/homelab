# ── observation point ── not scan code. The products the ci-red clause branches on, plus the
# orphans line the ci-red-gate emits and the unit line the dispatch section emits.
# Close the for loop opened in bridge.sh.
done
printf 'ATTEMPTS %s\n' "$attempts"
printf 'NOOP %s\n' "${noop_round:-<none>}"
printf 'RED_ROUNDS %s\n' "$red_rounds"
printf 'RED_ROUNDS_KEY %s\n' "$red_rounds_key"
printf 'ORPHANS %s\n' "$orphans"
printf 'UNITS %s\n' "$units"
echo "REACHED: end"