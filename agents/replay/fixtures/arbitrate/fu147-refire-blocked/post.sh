# ── observation point ── apply the NOOP_ROUND_JQ to the recorded world and emit the result.
# The NOOP_ROUND_JQ variable was defined by the `block:round-evidence` part that ran before this.
# `if` rather than `[ ... ] && printf`: the loop's exit status is its last command's, so a trailing
# empty line would return 1 and take the whole composition down under `set -e` — a harness bug that
# would read as a clause failure.
result="$(printf '%s' "$prjson" | jq -r "$NOOP_ROUND_JQ" 2>/dev/null)" || result=""
printf 'NOOP_RESULT=%s\n' "$result"
echo "REACHED: end"