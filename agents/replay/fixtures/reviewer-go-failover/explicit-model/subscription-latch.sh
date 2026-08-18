#!/usr/bin/env bash
# Fixture stub: Anthropic is latched (return 1)
echo "subscription limited (FU-088, 429): utilization high — deferring subscription dispatch" >&2
exit 1
