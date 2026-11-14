#!/usr/bin/env bash
# The outside entry (diff-ci's `-- bash islands/scan/scripts/ci.sh` row): enter the island and run its
# devbox `ci` script — the way the root `gateway-ci` task enters gateway/. The gate itself is suite.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
exec devbox run ci
