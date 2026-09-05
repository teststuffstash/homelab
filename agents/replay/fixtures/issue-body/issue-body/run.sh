#!/usr/bin/env bash
# The suite entrypoint for the `issue-body` fixture: the parser's own `--self-test` (the
# assertions live beside the grammar they check — agents/issue_body.py). Nothing else belongs
# here; a case goes in the module, not in this shim.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../../.." && pwd)"
exec python3 "$ROOT/agents/issue_body.py" --self-test
