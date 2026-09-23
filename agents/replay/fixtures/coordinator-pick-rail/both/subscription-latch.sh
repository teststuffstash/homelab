#!/usr/bin/env bash
# Both rails latched — exit 1 with the reason on stderr; the caller must DEFER, never dispatch.
echo "both rails latched (Anthropic: 429/utilization, Go: limited)" >&2
exit 1
