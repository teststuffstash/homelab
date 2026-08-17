#!/bin/bash
# machines-lint — the mechanical currency gate for machines/generate.py outputs (homelab#303).
#
# machines/machines.yaml is the one machine inventory; machines/generate.py regenerates
# machines/README.md, machines/machines.html, and the marker-delimited hosts/versions blocks in
# the repo-root README.md and CLAUDE.md. Nothing checked in CI that those outputs are current —
# an edit to machines.yaml without re-running the generator silently reopens generated-block
# drift. This lint is that gate: it fails (exit 1) naming the drifted file(s) + the fix, and
# exits 0 when everything is current.
#
# Method: run the generator against a TEMP COPY of its inputs+outputs and compare — the working
# tree is never modified. generate.py locates everything via __file__ (HERE = the script's own
# dir, ROOT = its parent), so mirroring machines/ + tofu/variables.tf + README.md + CLAUDE.md
# into a temp dir preserves the relative structure and lets the generator run unchanged against
# the copy. A full-file `cmp` is the right comparison for README.md/CLAUDE.md too: the generator
# only rewrites the marker regions there, so any difference means stale generated content.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/machines" "$tmp/tofu"

# Inputs the generator reads (machines/machines.yaml, tofu/variables.tf) + the files it writes
# (machines/README.md, machines/machines.html, README.md, CLAUDE.md). Copying the whole
# machines/ dir keeps generate.py beside its yaml and the two machines/* outputs it fully rewrites.
cp machines/machines.yaml machines/generate.py machines/README.md machines/machines.html "$tmp/machines/"
cp tofu/variables.tf "$tmp/tofu/"
cp README.md CLAUDE.md "$tmp/"

# Run the generator against the copy. `set -e` aborts here (with the trap cleaning up) if it dies.
devbox run -- python3 "$tmp/machines/generate.py" >/dev/null

drift=""
for f in machines/README.md machines/machines.html README.md CLAUDE.md; do
  if ! cmp -s "$f" "$tmp/$f"; then
    drift="$drift $f"
  fi
done

if [ -n "$drift" ]; then
  echo "machines-lint: FAIL — generated output is stale for:$drift" >&2
  echo "  fix: edit machines/machines.yaml, then re-run: devbox run -- python3 machines/generate.py" >&2
  exit 1
fi

echo "machines-lint: machines/generate.py outputs are current (machines/README.md, machines/machines.html, README.md, CLAUDE.md)"
exit 0
