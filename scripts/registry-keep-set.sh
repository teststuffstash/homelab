#!/bin/bash
# registry-keep-set.sh — untag old builds of a platform image on the first-party registry
# (registry.teststuff.net, ADR-121), so the daily registry-garbage-collect can reclaim them (FU-274).
#
#     bash scripts/registry-keep-set.sh agent-base            # dry run: print the would-untag set
#     bash scripts/registry-keep-set.sh agent-base --apply    # untag (needs REGISTRY_PUSH_TOKEN)
#     bash scripts/registry-keep-set.sh --self-test           # the selection rule, no network
#
# Run by the image repos' build-image.yaml after a push (agent-runtime, agent-coordinator), from a
# checkout of homelab master. A build is ~4 GB and lands almost daily, so without this the 150Gi
# registry volume fills in weeks.
#
# THE KEEP-SET, per image:
#   1. every tag this checkout of homelab MENTIONS anywhere (images.env, a kustomize newTag, a
#      Composition literal, a fixture) — a pin of any age stays pullable, and so does the tag a
#      revert would restore while its pin is still in the tree;
#   2. the newest KEEP_NEWEST build tags (default 5) — the revert targets that are no longer pinned;
#   3. tags named in KEEP_TAGS (space-separated) — the caller's just-pushed tag;
#   4. every tag that is not a build tag (`latest`), and every tag sharing a digest with a kept one.
# A DELETE is by digest and takes every tag on that digest with it, hence rule 4's second half.
#
# FAIL CLOSED: a tag list that cannot be read, or a tag that does not resolve to a digest, prunes
# NOTHING and exits non-zero. "We did not look" never reads as "nothing to keep".
set -euo pipefail
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
REG_HOST="${REGISTRY_HOST:-registry.teststuff.net}"
KEEP_NEWEST="${KEEP_NEWEST:-5}"
# A build tag: <year>.<month>.<day>-g<sha>, optionally .<run number> (the image repos' "Compute version").
BUILD_TAG_RE='^20[0-9]{2}\.[0-9]{1,2}\.[0-9]{1,2}-g[0-9a-f]{7,}(\.[0-9]+)?$'
ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

# select_prunable <keep-newest> <pinned-tags-file> — "tag digest" lines on stdin; prints the
# "tag digest" lines to untag. Pure: no network, no repo.
select_prunable() {
  local n="$1" pinned="$2" all newest
  all="$(cat)"
  newest="$(awk '{print $1}' <<<"$all" | grep -E "$BUILD_TAG_RE" | sort -V | tail -n "$n" || true)"
  awk -v re="$BUILD_TAG_RE" '
    FILENAME == ARGV[1] { keep[$1] = 1; next }           # pinned + newest + KEEP_TAGS
    { tag[FNR] = $1; dig[FNR] = $2 }
    END {
      for (i in tag) if (tag[i] !~ re || tag[i] in keep) keepdig[dig[i]] = 1
      for (i in tag) if (!(dig[i] in keepdig)) print tag[i], dig[i]
    }' <(cat "$pinned"; printf '%s\n' "$newest") - <<<"$all" | sort -V
}

self_test() {
  local t out want
  t="$(mktemp -d)"; trap 'rm -rf "$t"' RETURN
  printf '%s\n' 2026.10.5-gca94f4a2dd99 > "$t/pinned"
  out="$(select_prunable 2 "$t/pinned" <<'EOF'
latest sha256:ffff
2026.11.12-g7b51771a868d sha256:ffff
2026.11.11-g0ba770de8d02 sha256:eeee
2026.11.10-g8f5cedb3b83f.40 sha256:dddd
2026.11.10-g8f5cedb3b83f sha256:cccc
2026.11.9-gfdb05c16be5e sha256:bbbb
2026.10.5-gca94f4a2dd99 sha256:aaaa
2026.10.4-g111111111111 sha256:aaaa
scratch sha256:9999
EOF
)"
  # kept: latest + scratch (not build tags), the newest two (11.12, 11.11), the pinned 10.5 and
  # 10.4 beside it on the same digest. 11.9 sorts below 11.10 (version order, not string order).
  want=$'2026.11.9-gfdb05c16be5e sha256:bbbb\n2026.11.10-g8f5cedb3b83f sha256:cccc\n2026.11.10-g8f5cedb3b83f.40 sha256:dddd'
  [ "$out" = "$want" ] || { printf 'registry-keep-set self-test: FAIL\n--- got\n%s\n--- want\n%s\n' "$out" "$want" >&2; return 1; }
  : > "$t/pinned"
  out="$(select_prunable 5 "$t/pinned" <<<'2026.11.12-g7b51771a868d sha256:ffff')"
  [ -z "$out" ] || { echo "registry-keep-set self-test: FAIL — a lone tag was selected: $out" >&2; return 1; }
  echo "registry-keep-set self-test: ok"
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; fi
if [ "${1:-}" = "--self-test" ]; then self_test; exit; fi

REPO="${1:?usage: registry-keep-set.sh <image> [--apply] | --self-test}"
APPLY=0; [ "${2:-}" = "--apply" ] && APPLY=1
AUTH=()
if [ -n "${REGISTRY_PUSH_TOKEN:-}" ]; then AUTH=(-u "releaser:${REGISTRY_PUSH_TOKEN}"); fi
if [ "$APPLY" = 1 ] && [ ${#AUTH[@]} -eq 0 ]; then echo "registry-keep-set: --apply needs REGISTRY_PUSH_TOKEN" >&2; exit 2; fi
BASE="https://${REG_HOST}/v2/${REPO}"

# python3, not jq: the slim ARC runner image does not guarantee jq.
tags="$(curl -sfS "${AUTH[@]}" "${BASE}/tags/list" \
        | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin).get("tags") or []))')" \
  || { echo "registry-keep-set: cannot list ${REG_HOST}/${REPO} tags — pruning NOTHING" >&2; exit 2; }
[ -n "$tags" ] || { echo "${REG_HOST}/${REPO}: nothing tagged — nothing to prune"; exit 0; }

resolved=""
while read -r t; do
  d="$(curl -sfSI "${AUTH[@]}" -H "Accept: ${ACCEPT}" "${BASE}/manifests/${t}" \
        | awk 'tolower($1)=="docker-content-digest:"{gsub("\r","",$2); print $2}')" || d=""
  [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || { echo "registry-keep-set: ${REPO}:${t} did not resolve to a digest — pruning NOTHING" >&2; exit 2; }
  resolved+="${t} ${d}"$'\n'
done <<<"$tags"

pinned="$(mktemp)"; trap 'rm -f "$pinned"' EXIT
# Rule 1: one fixed-string search of the tree for all tags at once; -o prints the tag that matched.
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 \
  || { echo "registry-keep-set: $ROOT is not a git checkout — the pinned set is unreadable, pruning NOTHING" >&2; exit 2; }
build_tags="$(grep -E "$BUILD_TAG_RE" <<<"$tags" || true)"
[ -n "$build_tags" ] || { echo "${REG_HOST}/${REPO}: no build tags — nothing this script prunes"; exit 0; }
{ git -C "$ROOT" grep -ohFf <(printf '%s\n' "$build_tags") -- . || true
  printf '%s\n' ${KEEP_TAGS:-}; } | grep -E "$BUILD_TAG_RE" | sort -u > "$pinned" || true

prunable="$(printf '%s' "$resolved" | select_prunable "$KEEP_NEWEST" "$pinned")"
echo "${REG_HOST}/${REPO}: $(wc -l <<<"$tags") tags, $(grep -c . "$pinned" || true) pinned or named, keep-newest ${KEEP_NEWEST}"
[ -n "$prunable" ] || { echo "✓ every tag is in the keep-set — nothing to untag"; exit 0; }
rc=0
while read -r t d; do
  if [ "$APPLY" != 1 ]; then echo "DRY-RUN would untag ${REPO}:${t} @ ${d}"; continue; fi
  if curl -sfS "${AUTH[@]}" -X DELETE "${BASE}/manifests/${d}" >/dev/null; then
    echo "✓ untagged ${REPO}:${t} @ ${d}"
  else
    echo "registry-keep-set: DELETE ${REPO}:${t} @ ${d} failed — left in place" >&2; rc=1
  fi
done <<<"$prunable"
exit $rc
