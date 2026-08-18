# ── observation point ── not launcher code. In reviewer-session.sh the statement after the
# currency-gate block is the FU-092 pod-label probe / pod create. These two lines stand in for
# "execution continued past the gate": REACHED proves the gate did not wrongly skip, and POD KEY
# proves the combined probe still derived the 8-char head sha that feeds the FU-092 pod name
# (computed FROM the world JSON's headRefOid, not read back from the gate).
echo "REACHED: past-currency-gate"
echo "POD KEY: ${HEADSHA8:-}"
