#!/usr/bin/env bash
# xr-render — render every committed XR/claim of every Crossplane Composition in this repo through
# the real function pipeline, at the CLUSTER-PINNED engine + function versions, docker-free
# (scripts/xr-render-lib.sh has the fetch/pin/runtime mechanics). Output is normalized (resources
# sorted, keys sorted) so two renders compare with a plain `diff`.
#
# Why (G4, docs/dependency-upgrades.md §Gap register): kubeconform sees a Composition as a valid CR
# and never runs its templates, so "does this XRD/Composition/claim change alter what the cluster
# composes?" had no answer short of the live reconcile. #2445 proved the AgentStack default-drop
# render-identical by hand; this makes that proof a tool and a PR gate.
#
#   devbox run xr-render                         render all, print a per-input summary
#   devbox run xr-render -- --out DIR            … and keep the normalized renders in DIR
#   devbox run xr-render -- --diff BASE          render at git ref BASE and at the worktree, print
#                                                the diff; exit 1 if they differ (0 when the
#                                                diff is pin-only, see the CI rule below)
#   devbox run xr-render -- --diff BASE --allow-change   … print it, exit 0 (a declared change)
#   bash scripts/xr-render.sh --pin-only-check BASE_DIR HEAD_DIR   only classify two render trees:
#                                                exit 0 pin-only, 1 not (needs no crossplane)
#   … --claim FILE[@NAMESPACE]                   also render an out-of-repo claim/XR (repeatable),
#                                                e.g. a stack -iac repo's PublicRoute; NAMESPACE is
#                                                the claim's namespace (its ArgoCD destination)
#
# Inputs, discovered (nothing to register): every tracked *.yaml / *.yml / *.yaml.example document
# whose apiVersion group + kind is a Composition's XR kind or its XRD's claim kind, at the version
# the Composition composes (others are listed as skipped — render refuses a version mismatch). A
# claim is rendered as its XR (kind swapped, spec.claimRef from its metadata). A render that FAILS
# is a result too (the template guards, `*.must-fail.yaml`): its error message is the output.
#
# The CI rule (the `ci` step, PR events only): a PR touching a Composition/XRD/claim renders base vs
# head; a non-empty diff fails unless the PR body carries a line `Render-change: <reason>` — the
# author declares the behavior change, the diff is printed either way for the reviewer.
# A PIN-ONLY diff passes undeclared (homelab#2605): every changed line is an `image:` line whose
# repository is the same at base and head and only the tag and/or `@sha256:` digest moved — a
# version bump (Renovate cannot write a body line), never a template change. A tag or digest that
# is added or dropped is not pin-only.
#
# Exit: 0 ok / identical / pin-only (or --allow-change) · 1 the renders differ · 2 tool or render-setup error.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
# shellcheck source=scripts/xr-render-lib.sh
. scripts/xr-render-lib.sh

OUT="" BASE="" ALLOW=false CLAIMS=() PIN_CHECK=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT=$2; shift 2 ;;
    --diff) BASE=$2; shift 2 ;;
    --allow-change) ALLOW=true; shift ;;
    --claim) CLAIMS+=("$2"); shift 2 ;;
    --pin-only-check) PIN_CHECK=("$2" "$3"); shift 3 ;;
    -h|--help) sed -n '2,39p' "$0"; exit 0 ;;
    *) echo "xr-render: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
done
# pin_only <base-dir> <head-dir> → 0 when the two render trees differ only in the tag/digest of
# `image:` lines (the repository unchanged): both trees are copied, on every image line the tag and
# the digest are each replaced by the word PIN (one that is absent stays absent, so adding or
# dropping a tag or digest is NOT pin-only), and the copies must then be identical.
pin_only() {
  local t
  t=$(mktemp -d)
  cp -r "$1" "$t/base"
  cp -r "$2" "$t/head"
  find "$t" -type f -exec sed -E -i \
    -e 's|^([[:space:]]*(- )?image: [^[:space:]@]+)@sha256:[0-9a-f]{64}$|\1@sha256:PIN|' \
    -e 's|^([[:space:]]*(- )?image: [^[:space:]@]+):[^[:space:]:/@]+(@sha256:PIN)?$|\1:PIN\3|' {} +
  if (cd "$t" && diff -rqN base head >/dev/null); then rm -rf "$t"; return 0; fi
  rm -rf "$t"; return 1
}
if [ "${#PIN_CHECK[@]}" -eq 2 ]; then
  if pin_only "${PIN_CHECK[0]}" "${PIN_CHECK[1]}"; then echo "xr-render: pin-only"; exit 0; fi
  echo "xr-render: not pin-only"; exit 1
fi

for t in crossplane yq jq curl tar sha256sum git; do
  command -v "$t" >/dev/null || { echo "xr-render: FAIL — '$t' not on PATH (run via devbox)" >&2; exit 2; }
done

work=$(mktemp -d); trap 'xr_stop; rm -rf "$work"' EXIT

# render_tree <tree-root> <file-list-cmd…> → normalized renders under $work/out/<label>/
render_tree() {
  local tree=$1 out=$2; shift 2
  local comp xrd group kind ckind ver f n i doc slug in tag
  mkdir -p "$out"
  xr_start "$tree" "$work/rt-$(basename "$out")"
  echo "xr-render: [$(basename "$out")] crossplane ${XR_ENGINE_VERSION}, functions: $(for i in "${!XR_FN_NAMES[@]}"; do printf '%s ' "${XR_FN_REFS[$i]##*/}"; done | sed 's/@sha256:[0-9a-f]*//g')"
  "$@" > "$work/files"
  # every Composition, paired with the XRD that defines its compositeTypeRef
  for comp in $(grep -lE '^kind: Composition$' $(grep -E '\.ya?ml$' "$work/files" | sed "s|^|$tree/|") 2>/dev/null || true); do
    group=$(yq -r '.spec.compositeTypeRef.apiVersion' "$comp"); ver="$group"; group="${group%/*}"
    kind=$(yq -r '.spec.compositeTypeRef.kind' "$comp")
    xrd=""
    for f in $(grep -lE '^kind: CompositeResourceDefinition$' $(grep -E '\.ya?ml$' "$work/files" | sed "s|^|$tree/|") 2>/dev/null || true); do
      if [ "$(yq -r '.spec.group + "/" + .spec.names.kind' "$f")" = "$group/$kind" ]; then xrd=$f; break; fi
    done
    [ -n "$xrd" ] || { echo "xr-render: FAIL — no XRD in the tree defines $group/$kind (composition ${comp#"$tree"/})" >&2; exit 2; }
    ckind=$(yq -r '.spec.claimNames.kind // ""' "$xrd")
    n=$(yq -r '.metadata.name' "$comp")
    mkdir -p "$out/$n"
    # candidate inputs: tracked yaml mentioning the XR or claim kind
    {
      grep -lE "^kind: (${kind}${ckind:+|$ckind})\$" $(sed "s|^|$tree/|" "$work/files") 2>/dev/null || true
    } | while read -r f; do
      [ "$f" = "$comp" ] || [ "$f" = "$xrd" ] && continue
      i=0
      while [ "$i" -lt "$(yq -N 'document_index' "$f" | wc -l)" ]; do
        render_doc "$f" "$i" "${f#"$tree"/}" "" "$comp" "$xrd" "$ver" "$kind" "$ckind" "$out/$n"
        i=$((i + 1))
      done
    done
    for in in "${CLAIMS[@]+"${CLAIMS[@]}"}"; do
      f="${in%@*}"; tag=""; [ "$f" != "$in" ] && tag="${in##*@}"
      [ -f "$f" ] || { echo "xr-render: FAIL — --claim $f: no such file" >&2; exit 2; }
      grep -qE "^kind: (${kind}${ckind:+|$ckind})\$" "$f" || continue
      i=0
      while [ "$i" -lt "$(yq -N 'document_index' "$f" | wc -l)" ]; do
        render_doc "$f" "$i" "claim:$(basename "$f")" "$tag" "$comp" "$xrd" "$ver" "$kind" "$ckind" "$out/$n"
        i=$((i + 1))
      done
    done
  done
  xr_stop
}

# render_doc <file> <doc-index> <label> <claim-namespace> <comp> <xrd> <xr-apiVersion> <xr-kind> <claim-kind> <outdir>
render_doc() {
  local f=$1 i=$2 label=$3 ns=$4 comp=$5 xrd=$6 ver=$7 kind=$8 ckind=$9 od=${10} doc slug k av
  doc="$work/doc.yaml"
  yq "select(document_index == $i)" "$f" > "$doc"
  k=$(yq -r '.kind' "$doc"); av=$(yq -r '.apiVersion' "$doc")
  if [ "$k" != "$kind" ] && { [ -z "$ckind" ] || [ "$k" != "$ckind" ]; }; then return 0; fi
  slug=$(printf '%s' "$label" | tr '/:' '__')
  if [ "$i" -gt 0 ]; then slug="$slug#$i"; label="$label#$i"; fi
  if [ "$av" != "$ver" ]; then
    echo "  --  ${od##*/} $label (skipped: $av, composition composes $ver)"; return 0
  fi
  if [ "$k" = "$ckind" ]; then   # claim → its XR, the way the claim controller binds it
    NS="${ns:-$(yq -r '.metadata.namespace // "default"' "$doc")}" K="$kind" \
      yq -i '.spec.claimRef = {"apiVersion": .apiVersion, "kind": .kind, "name": .metadata.name, "namespace": strenv(NS)}
             | .kind = strenv(K) | del(.metadata.namespace)' "$doc"
  fi
  if xr_render "$doc" "$comp" "$xrd" "$work/r.yaml"; then
    yq -o=json -I=0 '.' "$work/r.yaml" | jq -s -S \
      'sort_by(.kind, (.metadata.namespace // ""), (.metadata.name // ""), (.metadata.annotations["crossplane.io/composition-resource-name"] // ""))' \
      | yq -P -p=json '.[] | split_doc' > "$od/$slug.yaml"
    echo "  ok  ${od##*/} $label ($(grep -c '^kind: ' "$od/$slug.yaml") object(s))"
  else
    { echo "# RENDER ERROR"; sed 's/^/# /' "$work/r.yaml.err"; } > "$od/$slug.yaml"
    echo "  !!  ${od##*/} $label (render error: $(grep -v '^$' "$work/r.yaml.err" | tail -1 | tail -c 140))"
  fi
}

head_files() { git -C "$ROOT" ls-files -- '*.yaml' '*.yml' '*.yaml.example'; }

if [ -z "$BASE" ]; then
  o="${OUT:-$work/out}"
  render_tree "$ROOT" "$o/head" head_files
  [ -n "$OUT" ] && echo "xr-render: renders in $OUT/head"
  exit 0
fi

# ── diff mode ──────────────────────────────────────────────────────────────────────────────────
git rev-parse -q --verify "$BASE^{commit}" >/dev/null \
  || git fetch -q --depth 1 origin "$BASE" \
  || { echo "xr-render: FAIL — cannot resolve base '$BASE'" >&2; exit 2; }
base_files() { git -C "$ROOT" ls-tree -r --name-only "$BASE" | grep -E '\.(ya?ml|yaml\.example)$'; }
mkdir -p "$work/base-tree"
# only the yaml (858 files, ~4 MB vs the 26 MB tree): pins, XRDs, Compositions and inputs all are
base_files | (cd "$ROOT" && xargs git archive "$BASE" --) | tar -x -C "$work/base-tree"
base_list() { (cd "$work/base-tree" && find . -type f | sed 's|^\./||'); }
o="${OUT:-$work/out}"
render_tree "$work/base-tree" "$o/base" base_list
render_tree "$ROOT" "$o/head" head_files
find "$o" -type f -exec touch -d @0 {} +   # stable diff headers
if d=$(cd "$o" && diff -ruN base head); then
  echo "xr-render: IDENTICAL — every input renders the same at $BASE and at the worktree"
  exit 0
fi
echo "xr-render: the renders DIFFER (base $BASE → worktree):"
printf '%s\n' "$d"
if pin_only "$o/base" "$o/head"; then
  echo "xr-render: PIN-ONLY — every changed line is an image tag/digest on an unchanged repository; no declaration needed"
  exit 0
fi
if $ALLOW; then
  echo "xr-render: render change declared (--allow-change / the PR's 'Render-change:' line) — not failing"
  exit 0
fi
echo "xr-render: FAIL — this change alters what the Composition renders. If that is intended, say so: add a line 'Render-change: <reason>' to the PR body (CI) / pass --allow-change (local)." >&2
exit 1
