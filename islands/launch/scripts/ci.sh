#!/usr/bin/env bash
# THE gate for the launch island: `devbox run -- bash islands/launch/scripts/ci.sh` (diff-ci's
# `-- bash islands/launch/scripts/ci.sh` row reaches it). It enters the island's OWN devbox the way
# the root `gateway-ci` task enters gateway/'s, then: uv sync --frozen → ruff → pytest (raw Allure
# results in allure-results/, local only). Never writes under agents/ (the replay runs from a copy).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${LAUNCH_ISLAND_IN_DEVBOX:-}" ]; then
  export LAUNCH_ISLAND_IN_DEVBOX=1
  exec devbox run -- bash scripts/ci.sh
fi

echo "== launch island ci: $(pwd)"
export UV_PYTHON_PREFERENCE="${UV_PYTHON_PREFERENCE:-only-system}"

echo "== uv sync --frozen"
uv sync --frozen --quiet

echo "== ruff check"
uv run --frozen ruff check tests

echo "== pytest"
uv run --frozen pytest -q

echo "== launch island ci: green"
