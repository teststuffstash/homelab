# ── observation point ── not reflex code. `picks` is the jq's raw output: one line per (repo,
# base) lane, `<number> <verdicts> <at-head> <approved-at-head> <headRefName> <issue-key> <base>` —
# exactly what the lane loop below the block splits with `read`. Each line is re-emitted with a
# PICK tag so the action stream stays line-oriented and an EMPTY pick set is visibly empty.
#
# `if` rather than `[ ... ] && printf`: the loop's exit status is its last command's, so a trailing
# empty line would return 1 and take the whole composition down under `set -e`.
printf '%s\n' "$picks" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'PICK %s\n' "$l"; fi
done
# The clause must run to completion under `set -euo pipefail`, not merely produce the right lines.
echo "REACHED: end"
