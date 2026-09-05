#!/usr/bin/env bash
# epic-dispositions-test.sh — the suite ENTRYPOINT for agents/epic_dispositions.py's own
# `--self-test` (registered as agents/replay/fixtures/epic-dispositions).
#
# WHY A SHELL FILE FOR A PYTHON TEST. The replay harness runs a `mode: suite` fixture as
# `bash "$entrypoint"` (agents/replay/run.sh §run_suite) — it does not honour a shebang — so a
# `.py` entrypoint cannot be registered directly. Same shape and same reason as
# agents/model-id-test.sh. The assertions live in the MODULE (one home); this file only routes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/agents/epic_dispositions.py" --self-test
