# ── observation point ── not clause code. The snapshot the strip ran against, rendered so the
# fixture pins WHICH threads were considered and not merely what was written: a candidate set that
# silently shrank to nothing would otherwise look identical to a clean reopen, since the contract's
# other half is an ABSENCE (#77 draws no call) and diff asserts absences for free.
printf 'PRECLOSED%s\n' "$PRECLOSED"
echo "REACHED: end"
