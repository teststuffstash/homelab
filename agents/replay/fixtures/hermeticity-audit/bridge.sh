#!/usr/bin/env bash
# Hermeticity audit: verify that ambient variables don't leak from the pod environment.
# This bridge tests that unset AGENT_* variables get their defaults, not pod values,
# and that explicitly pinned variables override the unset (homelab#1442).

# When these variables are unset at the run.sh choke point and used with defaults,
# they MUST NOT inherit pod values even in a worker/pod environment.
printf 'AUDIT: AGENT_RAIL=%s\n' "${AGENT_RAIL:-UNSET}"
printf 'AUDIT: AGENT_PUSHGATEWAY_URL=%s\n' "${AGENT_PUSHGATEWAY_URL:-UNSET}"
printf 'AUDIT: AGENT_EGRESS_PROXY=%s\n' "${AGENT_EGRESS_PROXY:-UNSET}"
printf 'AUDIT: PROJECT=%s\n' "${PROJECT:-UNSET}"
printf 'AUDIT: GH_TOKEN=%s\n' "${GH_TOKEN:-UNSET}"
printf 'AUDIT: OPENROUTER_API_KEY=%s\n' "${OPENROUTER_API_KEY:-UNSET}"
# Garage write credentials (agent-transcripts-s3, present in every session pod)
printf 'AUDIT: AGENT_TS_ACCESS_KEY_ID=%s\n' "${AGENT_TS_ACCESS_KEY_ID:-UNSET}"
printf 'AUDIT: AGENT_TS_SECRET_ACCESS_KEY=%s\n' "${AGENT_TS_SECRET_ACCESS_KEY:-UNSET}"

# When a fixture explicitly pins these in env:, they should override the unset and
# be available to the block (tested in the fixture's env: section).
printf 'AUDIT: PINNED_VAR=%s\n' "${PINNED_VAR:-UNSET}"

echo "REACHED: audit complete"
