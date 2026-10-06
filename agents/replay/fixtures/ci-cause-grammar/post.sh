# ── observation point ── not clause code. The reader's verdict on the marker line: the three
# fields the ledger row carries. A tolerant capture names the whole `<job>/<step>` (spaces and
# all); the strict one drops the marker entirely (`<no-match>`).
printf 'JOB_STEP %s\n' "$JOB_STEP"
printf 'CLASS %s\n' "$CLASS"
printf 'BASIS %s\n' "$BASIS"