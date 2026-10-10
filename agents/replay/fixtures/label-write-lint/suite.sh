#!/usr/bin/env bash
# label-write-lint suite — the detector's own fixture table, then the agents/ scan (fixture.yaml).
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1
rc=0
if out="$(python3 scripts/label-write-lint.py --self-test 2>&1)"; then echo "✓ $out"; else echo "✗ $out"; rc=1; fi
if out="$(python3 scripts/label-write-lint.py 2>&1)"; then echo "✓ ${out##*$'\n'}"; else printf '✗ %s\n' "$out"; rc=1; fi
exit "$rc"
