#!/usr/bin/env bash
# THE gate for the retro island: `devbox run -- bash islands/retro/scripts/ci.sh` from the repo root
# (diff-ci's `-- bash islands/retro/scripts/ci.sh` row reaches it). One entrypoint:
#   uv sync --frozen → ruff → pytest → evidence pack. Exit codes are never pipe-filtered.
# Runs in the island's own devbox (python 3.15 + uv + jq/awk/diff for the replay oracle); the
# re-exec below enters it when called from the repo-root shell.
set -euo pipefail
ISLAND="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${RETRO_ISLAND_DEVBOX:-}" ]; then
  export RETRO_ISLAND_DEVBOX=1
  cd "$ISLAND"
  exec devbox run -- bash scripts/ci.sh
fi
cd "$ISLAND"
echo "== retro island ci: $(pwd)"
export UV_PYTHON_PREFERENCE="${UV_PYTHON_PREFERENCE:-only-system}"

echo "== uv sync --frozen"
uv sync --frozen --quiet

echo "== ruff check"
uv run --frozen ruff check tests

# The pack is written even on a red suite (the gateway does the same); the pytest exit code decides.
echo "== pytest"
rc=0
uv run --frozen pytest -q || rc=$?

echo "== evidence pack"
bash scripts/evidence.sh allure-results allure-evidence || { [ "$rc" -ne 0 ] || rc=$?; }
exit "$rc"
