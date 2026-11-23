#!/usr/bin/env bash
# THE gate for the scan island (run inside its devbox: `cd islands/scan && devbox run ci`):
#   uv sync --frozen → ruff → pytest. Modelled on gateway/scripts/ci.sh without its site/evidence legs.
set -euo pipefail
cd "$(dirname "$0")/.."
echo "== scan island ci: $(pwd)"
export UV_PYTHON_PREFERENCE="${UV_PYTHON_PREFERENCE:-only-system}"

echo "== uv sync --frozen"
uv sync --frozen --quiet

echo "== ruff check"
uv run --frozen ruff check src tests scripts

echo "== pytest"
uv run --frozen pytest -q
