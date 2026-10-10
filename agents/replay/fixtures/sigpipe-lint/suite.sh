#!/usr/bin/env bash
# sigpipe-lint suite — the detector's own fixture table, then the repo-wide scan (fixture.yaml).
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1
rc=0
if out="$(python3 scripts/sigpipe-lint.py --self-test 2>&1)"; then echo "✓ $out"; else echo "✗ $out"; rc=1; fi
if out="$(python3 scripts/sigpipe-lint.py 2>&1)"; then echo "✓ ${out##*$'\n'}"; else printf '✗ %s\n' "$out"; rc=1; fi
# THE CLASS, EXECUTED on a long body (2026-10-10): the lint's premise is that a chained stage is a
# writer too. Under the runner's conditions (pipefail + SIGPIPE ignored — run.sh traps it) a 4 MiB
# label list whose FIRST line is the needle: the chain `printf | tr | grep -qx` must read the present
# needle as MISSING (tr takes EPIPE once grep -q exits; 4 MiB cannot fit a 64 KiB pipe, so this is
# deterministic, not a race), and the converted form (`grep -cx … >/dev/null`, a reader that
# consumes everything) must find it. If the first ever passes, the lint is flagging a non-problem.
long="$(set +o pipefail; printf 'agent/claimed,'; head -c 4194304 /dev/zero | tr '\0' 'x')"
# The forbidden shape runs through eval of a quoted string: the lint (rightly) reds it written out.
bad_shape='printf "%s\n" "$long" | tr , "\n" | grep -qx -- agent/claimed'
chain_old() ( set -o pipefail; trap '' PIPE; eval "$bad_shape" 2>/dev/null )
chain_new() ( set -o pipefail; trap '' PIPE; printf '%s\n' "$long" | tr ',' '\n' | grep -cx -- agent/claimed >/dev/null 2>&1 )
if chain_old 2>/dev/null; then echo "✗ long-body chain: printf | tr | grep -qx found the needle — the EPIPE premise did not reproduce"; rc=1
else echo "✓ long-body chain: printf | tr | grep -qx reads a present needle as missing (4 MiB, pipefail)"; fi
if chain_new; then echo "✓ long-body chain: printf | tr | grep -cx >/dev/null finds it (the conversion)"
else echo "✗ long-body chain: the converted form missed a present needle"; rc=1; fi
exit "$rc"
