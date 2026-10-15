#!/usr/bin/env bash
# THE gate for the agent-gateway island: `cd gateway && devbox run ci` (the repo-root devbox's
# `gateway-ci` script and diff-ci's `gateway-ci:^gateway/` row reach this). One entrypoint:
#   uv sync --frozen → ruff → pytest (writes evidence/evidence.json) → spec gate → evidence render.
# Exit codes are never pipe-filtered (a masked lint once hid a failing gate — CLAUDE.local.md).
set -euo pipefail
cd "$(dirname "$0")/.."
echo "== agent-gateway ci: $(pwd)"
export UV_PYTHON_PREFERENCE="${UV_PYTHON_PREFERENCE:-only-system}"

echo "== uv sync --frozen"
uv sync --frozen --quiet

echo "== ruff check"
uv run --frozen ruff check src tests scripts

echo "== pytest"
uv run --frozen pytest -q

echo "== spec gate"
uv run --frozen python scripts/spec_gate.py

echo "== evidence render"
uv run --frozen python scripts/evidence_render.py

echo "== agent-gateway ci: green"
