#!/usr/bin/env bash
# The gate for island intake's SPEC ROOT (specs/): `devbox run -- bash islands/intake/scripts/ci.sh`
# (diff-ci's `-- bash islands/intake/scripts/ci.sh` row reaches it). It enters the tests root's OWN
# devbox (specs-tests/devbox.json — never islands/intake/devbox.json, which every live sitting's
# bootstrap installs), then: uv sync --frozen → ruff → pytest (raw Allure results in
# specs-tests/allure-results/, local only). The running code's bash harness
# (tests/island-intake-test.sh) is not run here: it rides deep-dig-test.
set -euo pipefail
cd "$(dirname "$0")/../specs-tests"

if [ -z "${INTAKE_SPECS_IN_DEVBOX:-}" ]; then
  export INTAKE_SPECS_IN_DEVBOX=1
  exec devbox run -- bash ../scripts/ci.sh
fi

echo "== intake island specs ci: $(pwd)"
export UV_PYTHON_PREFERENCE="${UV_PYTHON_PREFERENCE:-only-system}"

echo "== uv sync --frozen"
uv sync --frozen --quiet

echo "== ruff check"
uv run --frozen ruff check tests

echo "== pytest"
uv run --frozen pytest -q

echo "== intake island specs ci: green"
