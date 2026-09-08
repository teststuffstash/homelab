# ── observation point ── not scan code. `uharvest` is the block's whole product: the fields the
# dispatch line appends to `--item`, which is what the coordinator play is ORDERED by. Rendered
# exactly as the scan renders it, so the fixture pins the string the session actually receives.
printf "ITEM repo=%s item=%s clause=%s%s\n" "$urepo" "$uitem" "$uclause" "$uharvest"
# The clause must run to completion under `set -euo pipefail`, not merely produce the right lines.
echo "REACHED: end"
# The bucket body is now composed by the ONE parser's WRITER and posted with `--body-file`
# (ADR-122 (3), homelab#1460 leg 4), so the `gh issue create` CALL line no longer carries it.
# Re-read what was actually written, through the same writer — the assertion is that the machine
# block the scan stamped survives its own parser and carries the goal as `Origin`. `hbbody` is set
# ONLY on the create path, so the rows that find an existing bucket (or emit nothing) print nothing.
if [ -n "${hbbody:-}" ] && [ -f "$hbbody" ]; then
  printf 'BUCKET-BLOCK %s\n' "$(python3 "$IB_PY" json < "$hbbody")"
fi
