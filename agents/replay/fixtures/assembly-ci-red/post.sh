# ── observation point ── not scan code. Closes the PR loop `block:ci-red-select` opened, then
# prints what the clause accumulated: units, the report surface, and the side map the
# dispatch-marker site reads to write `state-fp:assembly-ci-red:` on the PR.
done
printf '%b' "$units" | sed 's/^/UNIT /'
printf '%b' "$orphans" | sed 's/^/ORPHAN /'
for entry in $assembly_red_prs; do printf 'SIDE_MAP %s\n' "$entry"; done
echo "REACHED: end"
