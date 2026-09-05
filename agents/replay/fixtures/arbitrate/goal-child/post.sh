# ── observation point ── not scan code. `uharvest` is the block's whole product: the fields the
# dispatch line appends to `--item`, which is what the coordinator play is ORDERED by. Rendered
# exactly as the scan renders it, so the fixture pins the string the session actually receives.
printf "ITEM repo=%s item=%s clause=%s%s\n" "$urepo" "$uitem" "$uclause" "$uharvest"
# The clause must run to completion under `set -euo pipefail`, not merely produce the right lines.
echo "REACHED: end"