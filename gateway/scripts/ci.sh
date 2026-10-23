#!/usr/bin/env bash
# THE gate for the agent-gateway island: `cd gateway && devbox run ci` (the repo-root devbox's
# `gateway-ci` script and diff-ci's `gateway-ci:^gateway/` row reach this). One entrypoint:
#   uv sync --frozen → ruff → pytest (writes evidence/evidence.json + allure-results/) → spec gate
#   → evidence render → the single-file Allure report.
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
# evidence/evidence.md + the BEGIN/END log block (the per-rule summary a reader outside the job
# can fetch from the run log). The site's fragments no longer come from here: scripts/specs-build.sh
# transcludes the pinned tool's <RULE>.md (scripts/gateway-evidence.sh → allure-evidence/).
uv run --frozen python scripts/evidence_render.py

echo "== allure report"
# allure-report-single/index.html — the run's one self-contained Allure report (open it in a
# browser). CI's gateway-evidence step reuses this generate for the pack's row links.
bash scripts/allure-report.sh

echo "== agent-gateway ci: green"
