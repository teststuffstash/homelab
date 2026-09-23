#!/bin/bash
# machines-lint — the mechanical currency gate for machines/generate.py outputs (homelab#303)
# and for the Talos version pins that must follow `var.talos_version_worker` (FU-246).
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

# --- check 2: the PXE/USB Talos pins follow var.talos_version_worker (FU-246) -----------------
#
# Three files declare the Talos version a machine BOOTS from outside the cluster's own tofu root
# — the Matchbox PXE assets (ansible), the Matchbox profile that points at them (the provisioning
# root), and the USB fallback. Each carries a "keep in lockstep with var.talos_version_worker"
# comment, and a comment is all that held them: the PXE profile served v1.13.2 while the fleet ran
# v1.13.10, and the next metal node to PXE-boot got the page_table_check kernel and never came up
# (2026-09-21, 19138c44). That bump then drifted again within a day when the fleet moved to
# v1.14.1, and scripts/talos-usb.sh had been missed by it entirely. The comment is now a check.
#
# Why the WORKER version: every PXE/USB install is a worker (the CP nodes are nocloud VMs and one
# PXE'd laptop that installs from the same worker image). Why here: this lint already owns
# "generated/derived things that must follow tofu/variables.tf", and generate.py reads the same
# defaults for the version line it renders into README.md/CLAUDE.md.
tofu_default() {   # tofu_default <variables.tf path> <variable name> -> that variable's string default
  awk -v want="$2" '
    index($0, "variable \"" want "\"") == 1 { inblock = 1; next }
    inblock && /^[[:space:]]*default[[:space:]]*=/ {
      if (match($0, /"[^"]*"[[:space:]]*$/)) {
        print substr($0, RSTART + 1, RLENGTH - 2)
      }
      exit
    }
    inblock && /^}/ { exit }
  ' "$1"
}

want=$(tofu_default tofu/variables.tf talos_version_worker)
if [ -z "$want" ]; then
  echo "machines-lint: FAIL — no string default for var.talos_version_worker in tofu/variables.tf (renamed?)" >&2
  exit 1
fi

# file : the pin as it must read when current : how to grep what it reads now
pin_drift=""
check_pin() {   # check_pin <file> <regex capturing the version> <expected line, for the fix hint>
  got=$(sed -n -E "s@$2@\\1@p" "$1" | head -1)
  if [ -z "$got" ]; then
    echo "machines-lint: FAIL — no Talos version pin found in $1 (moved? adjust this lint with it)" >&2
    exit 1
  fi
  if [ "$got" != "$want" ]; then
    pin_drift="$pin_drift\n  $1: $got  →  $want   ($3)"
  fi
}

check_pin ansible/group_vars/matchbox.yml \
  '^talos_version: (v[0-9]+\.[0-9]+\.[0-9]+)$' \
  're-run: ANSIBLE_CONFIG=ansible/ansible.cfg devbox run -- ansible-playbook ansible/matchbox-talos-assets.yml'
prov=$(tofu_default tofu/provisioning/variables.tf talos_version)
if [ -z "$prov" ]; then
  echo "machines-lint: FAIL — no string default for var.talos_version in tofu/provisioning/variables.tf (renamed?)" >&2
  exit 1
fi
[ "$prov" = "$want" ] || pin_drift="$pin_drift\n  tofu/provisioning/variables.tf: $prov  →  $want   (then apply: devbox run -- tofu -chdir=tofu/provisioning apply)"
check_pin scripts/talos-usb.sh \
  '^TALOS_VERSION="\$\{TALOS_VERSION:-(v[0-9]+\.[0-9]+\.[0-9]+)\}"$' \
  'no apply — the default of the USB fallback'

if [ -n "$pin_drift" ]; then
  # shellcheck disable=SC2059
  printf "machines-lint: FAIL — Talos pins behind var.talos_version_worker ($want):$pin_drift\n" >&2
  echo "  a node that PXE- or USB-boots gets the stale kernel; bump each file, then run the apply named beside it" >&2
  exit 1
fi

echo "machines-lint: PXE/USB Talos pins match var.talos_version_worker ($want)"
exit 0
