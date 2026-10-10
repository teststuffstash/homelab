#!/usr/bin/env bash
# shellcheck shell=bash
# mgmt-tools — how the management box's loops reach a tool (FU-305; operator order 2026-10-10).
# SOURCED by mgmt-lib.sh, mgmt-probe.sh, mgmt-reconcile.sh, mgmt-state-snapshot.sh. Never run.
#
# THE RULE: the gate's own machinery never depends on the tree it is judging — nor on master's
# devbox toolchain, which a bad `devbox.lock` on master wedges (FU-305: a Python bump's venv prompt
# silenced the sentinel, so every PR — the fix included — sat BLOCKED; the 2026-10-10 lock drill
# found the same for the revert PR). No `devbox run` on the box: `mgmt-policy-test` greps for it.
# The split, per tool (docs/management-box.md §"Two pins, two revert paths, one git"):
#
#   box closure  — yq, kubectl, jq, curl, openssl, git, awscli2, bash/coreutils/…: the
#                  box's OWN flake (mgmt/nixos, pinned flake.lock) on each unit's `path`. Resolved
#                  from PATH by mgmt_x. A tool missing there FAILS LOUD on the box (MGMT_BOX=1,
#                  set by the units) — never a silent reach for devbox.
#   tree-locked  — tofu, talosctl, helm: the version IS part of the change the loop acts on (tofu
#                  state format; the Talos client↔cluster minor; helm 4 vs 3 apply semantics).
#                  Read from <tree>/devbox.lock as DATA — jq over the lock, the store path / nixpkgs
#                  rev validated by shape, realised through nix from the signed binary cache.
#                  devbox itself never runs: no devbox.json, no init_hook, no plugin venv. <tree> =
#                  the tree the loop ACTS from — its own clone of MASTER (the sentinel's too: a PR
#                  head's devbox.lock is never read). Providers stay the planned tree's
#                  `.terraform.lock.hcl` — the provider-pin gate plans the HEAD's, unchanged.
#
# In the JAIL (MGMT_BOX unset) everything resolves from PATH — `devbox run mgmt-policy-test`, a
# `devbox shell` — and a tool missing from PATH falls back to `devbox run` from $REPO, the old way.

# mgmt_x <tool> [args…] — run a toolchain binary. rc 127 + a line on stderr when the box lacks it.
mgmt_x() {
  if command -v "$1" >/dev/null 2>&1; then "$@"
  elif [ -n "${MGMT_BOX:-}" ]; then
    echo "mgmt-tools: '$1' is not on the box's PATH — add it to mgmt/nixos (boxTools); the box never reaches for devbox (FU-305)" >&2
    return 127
  else ( cd "${REPO:-$PWD}" && devbox run --quiet -- "$@" ); fi   # jail-only fallback (FU-305)
}

# mgmt_lock_tool <tree> <name> [bin] → the store path (a dir with bin/<bin>, default <name>) devbox.lock
# pins for package <name>,
# realised locally and GC-rooted under $MGMT_TOOLROOTS. rc 1 + why on stderr: no lock, no entry,
# an entry whose shape is not the one admitted, or a path nix could not substitute/build.
# Admitted shapes (anything else is refused — the lock is input, not code):
#   "<name>@<ver>" with systems.x86_64-linux.store_path = /nix/store/<hash>-<name>-<version>
#   "github:NixOS/nixpkgs/<40-hex rev>#<name>" (resolved the same, ?query allowed) → nix build
MGMT_TOOLROOTS="${MGMT_TOOLROOTS:-/var/lib/mgmt/toolroots}"
mgmt_lock_tool() {
  local tree="$1" name="$2" bin="${3:-$2}" lock="$1/devbox.lock" entry sp ref rev root out
  [ -s "$lock" ] || { echo "mgmt-tools: no devbox.lock in $tree" >&2; return 1; }
  entry="$(jq -c --arg n "$name" '[.packages | to_entries[]
             | select((.key | startswith($n + "@")) or (.key | endswith("#" + $n)))] | first // empty' "$lock" 2>/dev/null)" \
    && [ -n "$entry" ] || { echo "mgmt-tools: $name has no entry in $lock" >&2; return 1; }
  sp="$(jq -r '.value.systems["x86_64-linux"].store_path // empty' <<<"$entry")"
  if [ -n "$sp" ]; then
    [[ "$sp" =~ ^/nix/store/[0-9a-df-np-sv-z]{32}-${name}-[0-9][0-9A-Za-z.+_-]*$ ]] \
      || { echo "mgmt-tools: $name's store_path '$sp' is not /nix/store/<hash>-$name-<version> — refused" >&2; return 1; }
    root="$MGMT_TOOLROOTS/$name-${sp:11:12}"
    if [ ! -e "$root/bin/$bin" ]; then
      mkdir -p "$MGMT_TOOLROOTS"
      out="$(nix-store --realise --add-root "$root" "$sp" 2>&1)" \
        || { echo "mgmt-tools: could not realise $sp ($name): $(printf '%s' "$out" | tail -1)" >&2; return 1; }
    fi
  else
    ref="$(jq -r '.key' <<<"$entry")"
    [[ "$ref" =~ ^github:NixOS/nixpkgs/([0-9a-f]{40})#${name}$ ]] \
      || { echo "mgmt-tools: $name's entry '$ref' is neither a store path nor github:NixOS/nixpkgs/<rev>#$name — refused" >&2; return 1; }
    rev="${BASH_REMATCH[1]}"
    root="$MGMT_TOOLROOTS/$name-${rev:0:12}"
    if [ ! -e "$root/bin/$bin" ]; then
      mkdir -p "$MGMT_TOOLROOTS"
      out="$(NIX_CONFIG="experimental-features = nix-command flakes" \
             nix build --no-link --out-link "$root" "github:NixOS/nixpkgs/$rev#$name" 2>&1)" \
        || { echo "mgmt-tools: could not build github:NixOS/nixpkgs/$rev#$name: $(printf '%s' "$out" | tail -1)" >&2; return 1; }
    fi
  fi
  [ -x "$root/bin/$bin" ] || { echo "mgmt-tools: $root has no bin/$bin" >&2; return 1; }
  readlink -f "$root"
}

# mgmt_tree_path <tree> — on the box, PREPEND the tree-locked tools (tofu, talosctl, helm) to PATH.
# rc 1 when one could not be resolved (each why on stderr; the others still land): the caller
# logs it and carries on — the step that needs the missing tool then fails with its own verdict,
# never silently. A no-op in the jail.
mgmt_tree_path() {
  [ -n "${MGMT_BOX:-}" ] || return 0
  local tree="$1" p rc=0 t
  for t in opentofu:tofu talosctl:talosctl kubernetes-helm:helm; do
    if p="$(mgmt_lock_tool "$tree" "${t%%:*}" "${t#*:}")"; then PATH="$p/bin:$PATH"
    else rc=1; fi
  done
  export PATH
  return $rc
}
