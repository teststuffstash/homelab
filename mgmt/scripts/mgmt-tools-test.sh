#!/usr/bin/env bash
# mgmt-tools-test — the box's gate machinery must run with master's devbox toolchain BROKEN (FU-305,
# operator order 2026-10-10). Part of `devbox run mgmt-policy-test` (or: bash mgmt/scripts/mgmt-tools-test.sh).
#
# What a bad devbox.lock on master did: devbox's "overwrite the venv? (y/n)" exited 1 non-interactive
# (2026-10-07), the sentinel's `devbox run yq` read "policy unreadable", and no verdict was posted —
# the revert PR included. So this test:
#   1. puts a POISONED `devbox` first on PATH (exits 1 with that prompt, and records that it was
#      called) and a POISONED devbox.lock in the tree, then drives the sentinel's no-plan path —
#      policy load, the root classifier, stage 1 — over a devbox.lock-only head (the revert's
#      shape): it must classify "no box-held root", and with MGMT_BOX=1 devbox is never invoked;
#   2. pins mgmt_lock_tool's admitted shapes: a store path / nixpkgs rev of the named tool is
#      realised (nix stubbed — no network), anything else is REFUSED;
#   3. lints the box-executed scripts for `devbox run` and the loop units' `path` for devbox — the
#      static half, so a new box script cannot reach for master's toolchain again.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export REPO="$HERE/../.."
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1${2:+ — $2}"; }

# the poisoned devbox: FU-305's exact failure, and a witness file
mkdir -p "$T/bin"
cat >"$T/bin/devbox" <<EOF
#!/usr/bin/env bash
echo "called: \$*" >>"$T/devbox.calls"
echo "Virtual environment exists at \$HOME/.cache/devbox-venv/homelab. Overwrite it? (y/n)" >&2
exit 1
EOF
chmod +x "$T/bin/devbox"
command -v yq >/dev/null 2>&1 || { echo "FATAL yq not on PATH — run through \`devbox run mgmt-policy-test\` (the box gets it from mgmt/nixos)"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL jq not on PATH"; exit 1; }

# ── 1. the revert's path through the sentinel, devbox broken ─────────────────────────────────────
W="$T/repo"; git init -q -b master "$W"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$W/policy/mgmt" "$W/tofu"
cp "$REPO/policy/mgmt/plan-input.yaml" "$W/policy/mgmt/"
echo '{}' >"$W/devbox.json"
printf '{"lockfile_version":"1","packages":{"python3@latest":{"resolved":"github:NixOS/nixpkgs/aaaa#python3"}}}\n' >"$W/devbox.lock"
echo 'x' >"$W/tofu/main.tf"
git -C "$W" add -A && git -C "$W" commit -q -m base
BASE="$(git -C "$W" rev-parse HEAD)"
# the bad bump (master) and its revert (the head under judgment) — both devbox.lock only
sed -i 's/aaaa/bbbb/' "$W/devbox.lock"; git -C "$W" commit -qam bad-bump
git -C "$W" checkout -q -b revert; git -C "$W" revert --no-edit HEAD >/dev/null
HEAD_SHA="$(git -C "$W" rev-parse HEAD)"; git -C "$W" checkout -q master
(
  export PATH="$T/bin:$PATH" MGMT_BOX=1 REPO="$W"
  # shellcheck source=mgmt-lib.sh
  . "$HERE/mgmt-lib.sh"
  pol="$(mgmt_policy_load "$W" master)" || { echo "policy-load-failed"; exit 1; }
  roots="$(git -C "$W" diff --name-only "$BASE" "$HEAD_SHA" | mgmt_roots_touched "$pol")" || { echo "classifier-failed"; exit 1; }
  [ -z "$roots" ] || { echo "roots:$roots"; exit 1; }
  hits="$(mgmt_stage1 "$pol" "$W" "$BASE" "$HEAD_SHA")" || { echo "stage1-failed"; exit 1; }
  [ -z "$hits" ] || { echo "hits:$hits"; exit 1; }
  rm -f "$pol"; echo "noroot"
) >"$T/s1.out" 2>"$T/s1.err"
if [ "$(tail -1 "$T/s1.out")" = noroot ]; then ok "broken-devbox: the revert head classifies 'no box-held surface' (the verdict the sentinel posts)"
else bad "broken-devbox: the sentinel's no-plan path" "$(tail -1 "$T/s1.out") $(tail -2 "$T/s1.err" | tr '\n' ' ')"; fi
if [ ! -s "$T/devbox.calls" ]; then ok "broken-devbox: devbox was never invoked on the box path"
else bad "broken-devbox: devbox was invoked" "$(head -3 "$T/devbox.calls" | tr '\n' ' ')"; fi

# mgmt_x on the box: a tool the closure lacks fails LOUD (127), never via devbox
( export PATH="$T/bin:$PATH" MGMT_BOX=1; . "$HERE/mgmt-tools.sh"; mgmt_x no-such-tool-fu305 ) >/dev/null 2>"$T/x.err"; rc=$?
if [ "$rc" = 127 ] && grep -q "not on the box's PATH" "$T/x.err" && [ ! -s "$T/devbox.calls" ]; then ok "mgmt_x on the box: a missing tool is rc 127 + a line, devbox untouched"
else bad "mgmt_x on the box" "rc=$rc $(cat "$T/x.err")"; fi
# …and in the jail it still falls back to devbox (the old behaviour, by design)
( export PATH="$T/bin:$PATH"; unset MGMT_BOX; . "$HERE/mgmt-tools.sh"; mgmt_x no-such-tool-fu305 ) >/dev/null 2>&1
if grep -q 'called: run --quiet -- no-such-tool-fu305' "$T/devbox.calls" 2>/dev/null; then ok "mgmt_x in the jail: falls back to devbox run"
else bad "mgmt_x in the jail: no devbox fallback"; fi
rm -f "$T/devbox.calls"

# ── 2. mgmt_lock_tool: the admitted lock shapes, and the refusals ────────────────────────────────
# nix stubbed: records the call and materialises <root>/bin/<bin> like a realised path would.
L="$T/lock"; mkdir -p "$L"
lock_case() {  # <name> <want rc> <want-grep in stderr|-> <pkg> <bin> <devbox.lock json>
  local name="$1" want="$2" grepf="$3" pkg="$4" bin="$5" json="$6" out rc
  printf '%s\n' "$json" >"$L/devbox.lock"; rm -rf "$T/roots" "$T/nix.calls"
  out="$(
    export MGMT_TOOLROOTS="$T/roots" BIN="$bin"
    . "$HERE/mgmt-tools.sh"
    nix-store() { echo "nix-store $*" >>"$T/nix.calls"; mkdir -p "$3/bin"; : >"$3/bin/$BIN"; chmod +x "$3/bin/$BIN"; }
    nix() { echo "nix $*" >>"$T/nix.calls"; local l; l="${4}"; mkdir -p "$l/bin"; : >"$l/bin/$BIN"; chmod +x "$l/bin/$BIN"; }
    mgmt_lock_tool "$L" "$pkg" "$bin" 2>"$T/lt.err"
  )"; rc=$?
  if [ "$rc" != "$want" ]; then bad "lock-tool $name" "rc=$rc want $want: $(cat "$T/lt.err")"; return; fi
  if [ "$grepf" != - ] && ! grep -Eq -- "$grepf" "$T/lt.err" "$T/nix.calls" 2>/dev/null; then bad "lock-tool $name" "no '$grepf' in: $(cat "$T/lt.err" "$T/nix.calls" 2>/dev/null)"; return; fi
  ok "lock-tool $name"
}
H=87j6482arv293yb5rpwds5p554c72zmw
R=4975466d324710c576dc11ad614684e6bd8cad8e
lock_case store-path      0 "nix-store --realise --add-root .*/opentofu-87j6482arv29 /nix/store/$H-opentofu-1.13.1" opentofu tofu \
  "{\"packages\":{\"opentofu@latest\":{\"systems\":{\"x86_64-linux\":{\"store_path\":\"/nix/store/$H-opentofu-1.13.1\"}}}}}"
lock_case nixpkgs-rev     0 "nix build --no-link --out-link .*/talosctl-4975466d3247 github:NixOS/nixpkgs/$R#talosctl" talosctl talosctl \
  "{\"packages\":{\"github:NixOS/nixpkgs/$R#talosctl\":{\"resolved\":\"github:NixOS/nixpkgs/$R?lastModified=1#talosctl\"}}}"
lock_case other-package   1 "is not /nix/store/<hash>-opentofu-<version> — refused" opentofu tofu \
  "{\"packages\":{\"opentofu@latest\":{\"systems\":{\"x86_64-linux\":{\"store_path\":\"/nix/store/$H-bash-5.2\"}}}}}"
lock_case not-a-store     1 "refused" opentofu tofu \
  "{\"packages\":{\"opentofu@latest\":{\"systems\":{\"x86_64-linux\":{\"store_path\":\"/tmp/$H-opentofu-1.13.1\"}}}}}"
lock_case foreign-flake   1 "neither a store path nor github:NixOS/nixpkgs/<rev>#talosctl — refused" talosctl talosctl \
  "{\"packages\":{\"github:evil/nixpkgs/$R#talosctl\":{\"resolved\":\"github:evil/nixpkgs/$R#talosctl\"}}}"
lock_case short-rev       1 "refused" talosctl talosctl \
  "{\"packages\":{\"github:NixOS/nixpkgs/nixos-unstable#talosctl\":{}}}"
lock_case no-entry        1 "has no entry" opentofu tofu '{"packages":{}}'
lock_case unparseable     1 "has no entry" opentofu tofu '{not json'
if [ ! -s "$T/nix.calls" ]; then ok "lock-tool: a refused shape never reaches nix"; else bad "lock-tool: nix was called on a refusal" "$(cat "$T/nix.calls")"; fi

# mgmt_tree_path: a bad entry fails ITS tool only; the others still land on PATH; a jail no-op
printf '{"packages":{"opentofu@latest":{"systems":{"x86_64-linux":{"store_path":"/nix/store/%s-opentofu-1.13.1"}}},"kubernetes-helm@latest":{"systems":{"x86_64-linux":{"store_path":"/nix/store/%s-kubernetes-helm-4.3.0"}}}}}\n' "$H" "$H" >"$L/devbox.lock"
rm -rf "$T/roots"
out="$(
  export MGMT_TOOLROOTS="$T/roots" MGMT_BOX=1
  . "$HERE/mgmt-tools.sh"
  nix-store() { mkdir -p "$3/bin"; : >"$3/bin/tofu"; : >"$3/bin/helm"; chmod +x "$3/bin/"*; }
  mgmt_tree_path "$L" 2>"$T/tp.err"; echo "rc=$?"; echo "PATH=$PATH"
)"
if grep -q '^rc=1$' <<<"$out" && grep -q "opentofu-87j6482arv29/bin" <<<"$out" && grep -q "kubernetes-helm-87j6482arv29/bin" <<<"$out" \
   && grep -q "talosctl has no entry" "$T/tp.err"; then ok "tree-path: talosctl missing → rc 1, tofu + helm still on PATH"
else bad "tree-path partial" "$out $(cat "$T/tp.err")"; fi
out="$( unset MGMT_BOX; . "$HERE/mgmt-tools.sh"; P0="$PATH"; mgmt_tree_path /nonexistent; echo "rc=$? same=$([ "$PATH" = "$P0" ] && echo y)")"
if [ "$out" = "rc=0 same=y" ]; then ok "tree-path in the jail: a no-op (devbox shell's tools)"; else bad "tree-path jail" "$out"; fi

# ── 3. the static half: no devbox in a box loop ──────────────────────────────────────────────────
# Every mgmt/scripts/mgmt-*.sh runs on the box unless named here (jail/host-side verbs, tests), plus
# the shared verbs the loops call. A comment may name devbox; a command may not.
JAIL_SIDE=" mgmt-state-pull.sh mgmt-provision-secrets.sh mgmt-usb.sh mgmt-human-plan.sh "
hits=""
for f in "$REPO"/mgmt/scripts/mgmt-*.sh "$REPO/scripts/maintenance-window.sh" "$REPO/scripts/controlplane-upgrade.sh" "$REPO/scripts/node-maintenance.sh" \
         "$REPO/scripts/helm-release-evidence.sh" "$REPO/scripts/pg-backup.sh" "$REPO/agents/seat-window.sh"; do
  b="$(basename "$f")"
  case "$b" in *-test.sh) continue ;; esac
  case "$JAIL_SIDE" in *" $b "*) continue ;; esac
  src="$f"
  # mgmt-tf.sh: only its `remote='…'` half runs on the box (the rest is the jail's ssh wrapper + usage)
  if [ "$b" = mgmt-tf.sh ]; then src="$T/mgmt-tf.remote"; awk "/^remote='/{f=1} f{print} f && /^   exit \\\$rc'/{exit}" "$f" >"$src"
    [ -s "$src" ] || { bad "lint: mgmt-tf.sh's remote block not found"; continue; }; fi
  h="$(grep -nE '^[^#]*\bdevbox[[:space:]]+(run|shellenv)\b' "$src" | grep -v 'jail-only fallback (FU-305)' | grep -vE "['\`]devbox[[:space:]]+run|(echo|printf|log|fail|warn|die)[[:space:]]+\"[^\"]*devbox[[:space:]]+run" || true)"   # advice in a message: not a call
  [ -n "$h" ] && hits="$hits$b: $h"$'\n'
done
if [ -z "$hits" ]; then ok "lint: no \`devbox run\` in a box-executed script"
else bad "lint: \`devbox run\` in a box-executed script — use mgmt_x / mgmt_tree_path (mgmt/scripts/mgmt-tools.sh)" "$(printf '\n%s' "$hits")"; fi
NIX="$REPO/mgmt/nixos/hosts/mgmt/default.nix"
for u in mgmt-sentinel mgmt-apply mgmt-lease mgmt-reconcile mgmt-state-snapshot; do
  blk="$(awk -v u="systemd.services.$u = {" 'index($0, u){f=1} f{print} f && /^  };/{exit}' "$NIX")"
  if [ -z "$blk" ]; then bad "nix: unit $u not found in default.nix"; continue; fi
  if grep -E '^[^#]*path[[:space:]]*=' <<<"$blk" | grep -q devbox; then bad "nix: $u's path carries devbox"
  elif ! grep -q 'MGMT_BOX=1' <<<"$blk"; then bad "nix: $u does not set MGMT_BOX=1"
  else ok "nix: $u runs on boxTools, MGMT_BOX=1"; fi
done

echo "mgmt-tools-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
