# ── observation point ── not scan code. `uworkbranch` is the clause's own answer to "which
# resumable branch does THIS dispatch carry"; the live dispatch appends it to the `--item` string.
printf 'UWORKBRANCH [%s]\n' "${uworkbranch:-}"
# The clause must run to completion under `set -euo pipefail`, not merely produce the right lines.
echo "REACHED: end"