#!/bin/sh
# Warm ONE repo's devbox closure into /nix (FU-015 phase 2) — invoked once per repo from its
# own Dockerfile RUN so each closure is its own LAYER (#80 layering fix): an unchanged
# lockfile reuses its cached layer (stable digest) instead of re-baking the whole store.
# A repo whose lockfiles couldn't be staged (private-fetch failure) has an empty warm dir —
# skip, the image still builds; jobs realize that closure via the LAN nix mirror at runtime.
set -e
d="/tmp/warm/$1"
if [ ! -f "$d/devbox.json" ]; then
  echo "── $1: no closure staged, skipping"
  exit 0
fi
echo "── warming closure: $1"
cd "$d"
# The LAN nix-cache VIP is unreachable from the ubuntu-latest builder — go straight upstream
# here; runtime keeps the baked nix.conf order (LAN mirror first).
export NIX_CONFIG="substituters = https://cache.nixos.org"
devbox install
du -sh /nix /home/runner/.cache 2>/dev/null || true
