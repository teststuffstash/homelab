# ── observation point ── the round-trip: the floor the brief's escalation advice declares for the
# row's label is the floor `label_map` (the one home) carries. `LABEL` is the row's axis value
# (sm | md | lg). An advice that declares no floor for the label reads `undeclared` and never
# matches — the base advice ("one tier higher") is exactly that.
echo "readme-floor: ${README_FLOOR:-undeclared}"
echo "label-map-floor: ${MAP_FLOOR}"
if [ "${README_FLOOR:-undeclared}" = "$MAP_FLOOR" ]; then echo "consistent: yes"; else echo "consistent: no"; fi
exit 0