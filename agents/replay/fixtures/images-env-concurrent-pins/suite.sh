#!/usr/bin/env bash
# images-env-concurrent-pins suite (fixture.yaml has the condition). For every ordered pair of
# `*_IMAGE=` pins in the COMMITTED agents/images.env: fork two branches from one base, apply each
# producer's edit, squash-merge the first onto the base (what auto-merge does), then merge the new
# master into the second branch (what the updater's update-branch does) — that merge must be clean
# and carry BOTH new values.
#
# The producer edits are the deploy-pin jobs' own sed expressions, copied as INPUT SHAPE (they live
# in other repos; this file cannot source them):
#   agent-runtime/.github/workflows/build-image.yaml deploy-pin:
#     sed -i -E "s#^(${VAR}=).*#\1${NEWREF}#" agents/images.env
#   agent-coordinator/.github/workflows/build-image.yaml deploy-pin: the same line, plus
#     sed -i -E "s#^(\s+newTag: ).*#\1${TAG}#" agents/coordinator/kustomization.yaml
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1
ROOT="$PWD"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
rc=0
# merge-tree --write-tree (the real-merge seam below) is git >= 2.38; an older git would print usage
# and read as a CONFLICT, so refuse loudly instead.
git merge-tree --write-tree HEAD HEAD >/dev/null 2>&1 || { echo "✗ git $(git --version) lacks merge-tree --write-tree (need >= 2.38)"; exit 1; }
ok()  { echo "✓ $*"; }
bad() { echo "✗ $*"; rc=1; }

# pin_edit <var> → the producer's edit for <var> (cwd = the synthetic repo)
pin_edit() {
  local var="$1" tag; tag="2099.1.1-g$(printf '%s' "$var" | sha1sum | cut -c1-12)"
  sed -i -E "s#^(${var}=).*#\1example.invalid/${var,,}:${tag}#" agents/images.env
  if [ "$var" = AGENT_COORDINATOR_IMAGE ]; then
    sed -i -E "s#^(\s+newTag: ).*#\1${tag}#" agents/coordinator/kustomization.yaml
  fi
  printf '%s' "$tag"
}

# replay <repo-dir> <var1> <var2> → 0 when merging var2's branch after var1 landed is clean and
# both new tags are present in the merged images.env; prints the reason otherwise.
replay() {
  local R="$1" v1="$2" v2="$3" t1 t2 tree merged
  git -C "$R" checkout -q -B first base && t1="$(cd "$R" && pin_edit "$v1")" \
    && git -C "$R" commit -qam "deploy: $v1" || { echo "edit $v1 failed"; return 1; }
  git -C "$R" checkout -q -B second base && t2="$(cd "$R" && pin_edit "$v2")" \
    && git -C "$R" commit -qam "deploy: $v2" || { echo "edit $v2 failed"; return 1; }
  # `first` is master after its squash-merge (one commit on the base); update-branch merges it
  # into `second`. merge-tree --write-tree exits 1 on a conflict (git ≥2.38).
  if ! tree="$(git -C "$R" merge-tree --write-tree second first 2>&1)"; then
    echo "CONFLICT merging $v2 after $v1: ${tree##*$'\n'}"; return 1
  fi
  tree="${tree%%$'\n'*}"
  merged="$(git -C "$R" show "$tree:agents/images.env")"
  case "$merged" in *"$t1"*) ;; *) echo "merged images.env lost $v1's tag $t1"; return 1 ;; esac
  case "$merged" in *"$t2"*) ;; *) echo "merged images.env lost $v2's tag $t2"; return 1 ;; esac
  return 0
}

mkrepo() {   # mkrepo <dir> <images.env content file>
  mkdir -p "$1/agents/coordinator"
  cp "$2" "$1/agents/images.env"
  cp "$ROOT/agents/coordinator/kustomization.yaml" "$1/agents/coordinator/kustomization.yaml"
  git -C "$1" init -q -b base && git -C "$1" add -A && git -C "$1" commit -qm base
}

# ── 1. the detector can fail: the PRE-FIX shape (#2454/#2455 — the two pins adjacent) must
# CONFLICT. Expected from git's merge rule: changes on adjacent lines form one hunk → conflict.
printf '%s\n' '# pins' \
  'AGENT_BASE_IMAGE=ghcr.io/teststuffstash/agent-base:2026.10.10-gecc27ef3a872' \
  'AGENT_COORDINATOR_IMAGE=ghcr.io/teststuffstash/agent-coordinator:2026.10.10-g56f8197a03de' \
  '# tail' > "$T/prefix.env"
mkrepo "$T/prefix" "$T/prefix.env"
if why="$(replay "$T/prefix" AGENT_COORDINATOR_IMAGE AGENT_BASE_IMAGE)"; then
  bad "pre-fix adjacent shape merged clean — the replay cannot see the #2455 conflict"
else
  case "$why" in CONFLICT*) ok "pre-fix adjacent shape conflicts, as #2455 did ($why)" ;;
    *) bad "pre-fix adjacent shape failed for the wrong reason: $why" ;; esac
fi

# ── 2. the committed file: every ordered pair of pins merges clean.
mkrepo "$T/live" "$ROOT/agents/images.env"
mapfile -t vars < <(grep -oE '^[A-Z_]+_IMAGE=' "$ROOT/agents/images.env" | tr -d =)
[ "${#vars[@]}" -ge 2 ] || bad "fewer than two *_IMAGE pins in agents/images.env (${#vars[@]}) — nothing to replay"
for a in "${vars[@]}"; do
  for b in "${vars[@]}"; do
    [ "$a" != "$b" ] || continue
    if why="$(replay "$T/live" "$a" "$b")"; then ok "$a lands, then $b merges clean (both tags kept)"
    else bad "$a then $b: $why — keep an unchanged line between pins (images.env header)"; fi
  done
done
exit "$rc"
