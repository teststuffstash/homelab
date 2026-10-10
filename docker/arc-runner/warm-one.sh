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
# THE BAKED LOCK (operator ruling 2026-10-10, FU-305): keep the pair that just REALISED — after the
# install, so any plugin rewrite devbox made is in it. In-image consumers that must not depend on
# master's lock (the iac-sentinel pod, agents/coordinator/sentinel-argo.yaml) copy it over their
# clone's: a lock that fails to realise fails THIS step, so no image ever carries an unrealisable one.
mkdir -p "/opt/baked/$1"
cp devbox.json devbox.lock "/opt/baked/$1/"
du -sh /nix /home/runner/.cache 2>/dev/null || true
