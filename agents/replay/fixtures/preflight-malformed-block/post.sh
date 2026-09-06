# ── observation point ── the three rows of the contract, in fixture.yaml's order.

# (1) a well-formed block — the block path, so no meter line.
_rc=0
_v="$(printf -- '---\nBase: goal/12-slug\nClass: build\n---\n\n## Why\n\nprose\n' \
        | ib_get Base "teststuffstash/homelab#1431" agent-session)" || _rc=$?
echo "OUT block_value=${_v} rc=${_rc}" >> "$REPLAY_ACTIONS"

# (2) no block, a legacy line — the value plus exactly one LEGACY-GRAMMAR meter line on stderr.
_rc=0
_v="$(printf -- '## Why\n\nBase: goal/12-slug\n' \
        | ib_get Base "teststuffstash/homelab#1431" agent-session)" || _rc=$?
echo "OUT legacy_value=${_v} rc=${_rc}" >> "$REPLAY_ACTIONS"

# (3) a MALFORMED block — `Nope:` is not one of the 13 grammar keys. ib_get exits 2 INSIDE the
# substitution (where an `exit` would be fail-open), and the refusal happens out here.
_rc=0
_v="$(printf -- '---\nBase: goal/12-slug\nNope: 1\n---\n' \
        | ib_get Base "teststuffstash/homelab#1431" agent-session)" || _rc=$?
echo "OUT malformed_rc=${_rc}" >> "$REPLAY_ACTIONS"
[ "$_rc" -eq 0 ] || ib_refuse_malformed Base "teststuffstash/homelab#1431"

# NEVER REACHED when the pre-flight fails closed — its absence from expected/actions.txt is the
# assertion that the refusal actually exits.
echo "OUT REACHED: dispatch" >> "$REPLAY_ACTIONS"
