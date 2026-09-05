#!/usr/bin/env bash
# manifest-lint — schema-validate the raw manifests ArgoCD applies (platform-lane tier 1).
#
#   devbox run manifest-lint
#
# WHY: `argocd/resources/**` is the ONE path tier where CI is the only gate — it is deliberately
# unowned in CODEOWNERS, and a merge there IS the deploy. Until this existed the repo's required
# `ci` check was `argocd-validate-pins`, which proves a pinned OCI chart still renders and looks at
# nothing else: a hand-written Deployment with a typo'd field passed CI and failed at sync.
# "Automerge safety is a function of check coverage, not of the path"
# (docs/agents/iac-lane.md §The platform lane).
#
# HONESTY REQUIREMENT: kubeconform cannot check CRs whose CRD schema it doesn't have (ArgoCD
# Applications, AgentStacks, Prometheus rules...). Those are SKIPPED, not validated — and a check
# that reports success while skipping most of its input is the FU-125 / FU-108 / FU-131 failure
# class this platform keeps paying for. So the skip count is printed loudly every run, and a run
# where NOTHING was validated fails. CiliumNetworkPolicy/CiliumClusterwideNetworkPolicy left this
# class 2026-09-05 (homelab#1200): schema-validated below via a VENDORED CRD schema, not fetched —
# see scripts/schemas/README.md for why (offline CI, FU-197) and how to re-generate it on a Cilium
# bump. That schema only covers the CNPs that exist as literal top-level manifests; the CNPs
# rendered inside argocd/resources/agentstack/composition.yaml are go-templated strings inside a
# Crossplane Composition — kubeconform never sees them as a document, so this gate has no opinion
# on them (they stay hand-reviewed, same as the Composition's other embedded kinds).
set -euo pipefail
cd "$(dirname "$0")/.."

DIRS="${*:-argocd/resources argocd/platform}"
K8S_VERSION="${K8S_VERSION:-1.36.1}"

# scripts/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json is kubeconform's own
# CRD-schema layout (lowercase kind); `default` keeps the upstream fetch as the fallback for every
# built-in kind. Order matters: the local vendor is tried first so a CNP never round-trips to the
# network.
SCHEMA_LOCATIONS="-schema-location scripts/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json -schema-location default"

# YAML under these paths is INPUT to something else, never applied: helm values consumed by an
# Application, and kustomize configMapGenerator sources. Listed explicitly rather than auto-skipping
# every doc without a `kind:` — a real manifest that LOST its kind must still fail loudly.
# kustomization.yaml is excluded as a CLASS: kustomize input, not an applied resource — no schema
# exists for it upstream, so it only ever rode the missing-schema skip, and when GitHub raw returns
# a non-404 error for that guaranteed-miss fetch the whole lint reds (PR#1099, 2026-08-31; the
# uncached-schema-fetch flake class is FU-197).
NOT_MANIFESTS='argocd/platform/values/|argocd/resources/otel-collector/otel-config\.yaml|(^|/)kustomization\.yaml$'

echo "manifest-lint: kubeconform ${K8S_VERSION} over ${DIRS}"
files=$(find $DIRS -name '*.yaml' -o -name '*.yml' 2>/dev/null | grep -Ev "$NOT_MANIFESTS" | sort)
[ -n "$files" ] || { echo "manifest-lint: FAIL — no manifests found under ${DIRS}" >&2; exit 1; }

# -ignore-missing-schemas: skip unknown CRs rather than fail (we do not vendor every CRD schema).
# -strict: reject unknown fields in the kinds we DO know — that is the typo class this exists for.
out="$(printf '%s\n' "$files" | xargs kubeconform \
  -kubernetes-version "$K8S_VERSION" -strict -ignore-missing-schemas -summary $SCHEMA_LOCATIONS 2>&1)" || rc=$?
echo "$out"

# Summary line shape: "Summary: N resources found in M files - Valid: V, Invalid: I, Errors: E, Skipped: S"
valid=$(printf '%s' "$out" | sed -n 's/.*Valid: \([0-9]*\).*/\1/p' | tail -1)
skipped=$(printf '%s' "$out" | sed -n 's/.*Skipped: \([0-9]*\).*/\1/p' | tail -1)
: "${valid:=0}"; : "${skipped:=0}"

if [ "${rc:-0}" != "0" ]; then
  echo "manifest-lint: FAIL — kubeconform rejected a manifest (see above)" >&2
  exit 1
fi
if [ "$valid" -eq 0 ]; then
  echo "manifest-lint: FAIL — 0 resources validated (${skipped} skipped). A check that validates" >&2
  echo "  nothing must not report green; either the schemas broke or the paths moved." >&2
  exit 1
fi
echo "manifest-lint: OK — ${valid} validated, ${skipped} SKIPPED (no local CRD schema: Applications,"
echo "  AgentStacks, PrometheusRules…). Skipped resources are NOT checked — vendoring those CRD"
echo "  schemas is what would close the gap (CiliumNetworkPolicy/CiliumClusterwideNetworkPolicy"
echo "  left this class 2026-09-05, homelab#1200 — see scripts/schemas/README.md)."

# ── kustomization completeness (homelab#694, 2026-08-20) ─────────────────────────────────────
# The agent-coordinator app is kustomize-rendered (FU-152): a manifest present in the directory
# but absent from `resources:` produces the WORST drift shape — ArgoCD reads Synced+Healthy while
# the resource silently does not exist (bitten twice: FU-152's origin; #692's Sensor absent until
# #693). Every *.yaml in a kustomized dir must be listed (kustomization.yaml itself excepted).
for kdir in agents/coordinator; do
  kfile="$kdir/kustomization.yaml"
  [ -f "$kfile" ] || continue
  missing=""
  for f in "$kdir"/*.yaml "$kdir"/*.yml; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    [ "$base" = "kustomization.yaml" ] && continue
    grep -qE "^[[:space:]]*-[[:space:]]+${base}[[:space:]]*$" "$kfile" || missing="${missing}${base}"$'\n'
  done
  if [ -n "$missing" ]; then
    echo "manifest-lint: FAIL — manifest(s) in ${kdir}/ absent from ${kfile} resources: (the" >&2
    echo "  Synced-but-nonexistent drift, homelab#694/#693):" >&2
    printf '%s' "$missing" | sed 's/^/    /' >&2
    exit 1
  fi
  echo "manifest-lint: kustomization completeness OK (${kdir})"
done
