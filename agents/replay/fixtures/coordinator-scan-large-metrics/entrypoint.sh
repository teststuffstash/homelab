#!/usr/bin/env bash
# Suite entrypoint: test that the coordinator-scan SIGPIPE fix works with large metrics payloads
set -euo pipefail

# Source the extracted blocks and bridge
source "$REPLAY_ROOT/agents/coordinator-scan.sh"
source "$SCRIPT_DIR/bridge.sh"
