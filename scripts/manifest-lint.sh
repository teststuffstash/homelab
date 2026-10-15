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

# ── XRD claim-spec defaults (G4 class fix, 2026-10-10) ───────────────────────────────────────
# A schema `default:` under an XRD's spec is stamped by the API server into every STORED XR that
# omits the field; the XR in git lacks it, so each ArgoCD app applying one sits OutOfSync — and
# `ignoreDifferences` cannot hide it under RespectIgnoreDifferences=true (it would never apply
# from git). Bitten each time a defaulted AgentStack field landed (#1688, #2184: every stack's
# agent-fixer app, docs/dependency-upgrades.md §Gap register G4). The rule: a field's default
# lives where it is READ (the Composition's template fallback), never in the schema. Allowlist
# only with an inline reason on the default line: `default: x # xrd-default-ok: <reason>`.
XRD_DEFAULTS_Q='select(.kind == "CompositeResourceDefinition") | .spec.versions[].schema.openAPIV3Schema.properties.spec
  | .. | select(tag == "!!map" and has("default") and (path | .[-1]) != "properties") | .default
  | select((line_comment | test("xrd-default-ok: *[^ ]")) | not) | path | join(".")'
xrd_bad=""
for f in $(printf '%s\n' "$files" | xargs grep -l '^kind: CompositeResourceDefinition' || true); do
  hits="$(yq -r "$XRD_DEFAULTS_Q" "$f")" || { echo "manifest-lint: FAIL — yq could not read XRD $f" >&2; exit 1; }
  [ -n "$hits" ] && xrd_bad="${xrd_bad}$(printf '%s\n' "$hits" | sed "s|^|    $f: |")"$'\n'
done
if [ -n "$xrd_bad" ]; then
  echo "manifest-lint: FAIL — schema default(s) under an XRD's spec (the G4 OutOfSync class). Move" >&2
  echo "  the default into the Composition where the field is read, or allowlist it inline with" >&2
  echo "  '# xrd-default-ok: <reason>' (docs/dependency-upgrades.md §Gap register G4):" >&2
  printf '%s' "$xrd_bad" >&2
  exit 1
fi
echo "manifest-lint: XRD claim-spec defaults OK (none un-allowlisted)"

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

# ── agent-coordinator image-pin equality (FU-152 ruling, homelab#2566) ───────────────────────
# FU-152's ruling: the coordinator image has TWO homes, held equal by a rule. Kustomize supplies the
# tag for everything under agents/coordinator/ (those manifests reference the image UNTAGGED), but it
# cannot reach the literals OUTSIDE that directory — the per-stack loop CronWorkflows in
# argocd/resources/agentstack/composition.yaml and the registry-cache gc-mirrors CronJob — nor
# agents/images.env. Those are hand-written pins, and they drifted: on 2026-10-14 the Composition sat
# at 2026.8.7 and gc-mirrors at 2026.7.25 while the kustomize newTag was 2026.10.12, because the
# deploy-pin sweep rewrote only the two kustomize-reachable files. A stale literal is invisible:
# ArgoCD reports Synced+Healthy and the CronWorkflow runs a two-month-old toolchain.
#
# The rule: every TAGGED `ghcr.io/teststuffstash/agent-coordinator:<tag>` literal in the repo's
# manifests equals agents/coordinator/kustomization.yaml's newTag for that image. Scope is the
# manifests (*.yaml/*.yml) plus any images.env — the pin homes the sweep writes. Deliberately NOT in
# scope, each for a reason:
#   * `*/fixtures/*` — frozen test worlds (gate-drift.sh's is_test() convention); a fixture that pins
#     an old tag is the POINT of the fixture.
#   * the `:latest` fallback default in agents/{coordinator,reviewer}-session.sh — a runtime default,
#     not a pin, and not a manifest.
#   * UNTAGGED references (agents/coordinator/*.yaml, chart-revert, the lease hooks) — kustomize
#     supplies those tags; there is no literal to compare.
COORD_IMAGE='ghcr.io/teststuffstash/agent-coordinator'
COORD_IMAGE_RE='ghcr\.io/teststuffstash/agent-coordinator'
COORD_KUSTOMIZATION='agents/coordinator/kustomization.yaml'

# coord_pin_newtag <root> — the kustomize newTag for the coordinator image (empty if absent).
coord_pin_newtag() {
  yq -r ".images[]? | select(.name == \"${COORD_IMAGE}\") | .newTag" \
    "$1/$COORD_KUSTOMIZATION" 2>/dev/null | head -1
}

# coord_pin_check <root> — paths relative to <root> on stdin. Prints one `file:line: tag` line per
# literal that disagrees with the newTag; returns 1 if any (0 when every literal agrees).
coord_pin_check() {
  local root="$1" want f hit ln tag bad=0
  want="$(coord_pin_newtag "$root")"
  if [ -z "$want" ]; then
    echo "manifest-lint: FAIL — no newTag for ${COORD_IMAGE} in ${COORD_KUSTOMIZATION}: the pin's" >&2
    echo "  source of truth is missing or unreadable, so equality cannot be checked (fail closed)." >&2
    return 1
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$root/$f" ] || continue
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      ln="${hit%%:*}"; tag="${hit##*:}"
      if [ "$tag" != "$want" ]; then
        printf '    %s:%s: %s (newTag is %s)\n' "$f" "$ln" "$tag" "$want"
        bad=1
      fi
    done < <(grep -nEo "${COORD_IMAGE_RE}:[^\"'[:space:]]+" "$root/$f" || true)
  done
  return "$bad"
}

# --self-test: the equality rule must FAIL on a mismatched literal and PASS on an aligned tree. Runs
# on EVERY invocation (a temp tree and a few greps) so the failure branch is exercised in the same CI
# run whose verdict depends on it — a gate whose negative path never runs is decoration (the
# agents-registration-lint probe-control pattern).
coord_pin_self_test() {
  local d tag old out rc=0
  tag='2026.10.12-gd303a3b5bd8d.27'; old='2026.8.7-gd6dc9ced82f2'
  d="$(mktemp -d)"
  mkdir -p "$d/agents/coordinator" "$d/argocd/resources/agentstack" "$d/argocd/resources/registry-cache"
  printf 'images:\n  - name: %s\n    newTag: %s\n' "$COORD_IMAGE" "$tag" > "$d/$COORD_KUSTOMIZATION"
  printf 'kind: X\nimage: %s:%s\n' "$COORD_IMAGE" "$tag" > "$d/argocd/resources/agentstack/composition.yaml"
  printf 'kind: X\nimage: %s:%s\n' "$COORD_IMAGE" "$tag" > "$d/argocd/resources/registry-cache/gc-mirrors.yaml"
  printf 'AGENT_COORDINATOR_IMAGE=%s:%s\n' "$COORD_IMAGE" "$tag" > "$d/agents/images.env"
  local files="$COORD_KUSTOMIZATION
argocd/resources/agentstack/composition.yaml
argocd/resources/registry-cache/gc-mirrors.yaml
agents/images.env"
  # positive control: the aligned tree passes.
  if ! printf '%s\n' "$files" | coord_pin_check "$d" >/dev/null; then
    echo "manifest-lint: SELF-TEST FAILED — the aligned fixture did not pass" >&2; rc=1
  fi
  # negative control 1: a stale literal in a manifest fails AND names file:line.
  if [ "$rc" = 0 ]; then
    printf 'kind: X\nimage: %s:%s\n' "$COORD_IMAGE" "$old" > "$d/argocd/resources/agentstack/composition.yaml"
    out="$(printf '%s\n' "$files" | coord_pin_check "$d" || true)"
    case "$out" in
      *"argocd/resources/agentstack/composition.yaml:2:"*) ;;
      *) echo "manifest-lint: SELF-TEST FAILED — a stale Composition literal did not fail naming file:line (got: ${out:-<no output>})" >&2; rc=1;;
    esac
  fi
  # negative control 2: images.env is IN scope (the FU-152 ruling names it explicitly).
  if [ "$rc" = 0 ]; then
    printf 'kind: X\nimage: %s:%s\n' "$COORD_IMAGE" "$tag" > "$d/argocd/resources/agentstack/composition.yaml"
    printf 'AGENT_COORDINATOR_IMAGE=%s:%s\n' "$COORD_IMAGE" "$old" > "$d/agents/images.env"
    out="$(printf '%s\n' "$files" | coord_pin_check "$d" || true)"
    case "$out" in
      *"agents/images.env:1:"*) ;;
      *) echo "manifest-lint: SELF-TEST FAILED — a stale images.env literal did not fail naming file:line (got: ${out:-<no output>})" >&2; rc=1;;
    esac
  fi
  # negative control 3: no newTag at all is a FAIL, not a silent pass (fail closed).
  if [ "$rc" = 0 ]; then
    printf 'images:\n  - name: ghcr.io/other/thing\n    newTag: %s\n' "$tag" > "$d/$COORD_KUSTOMIZATION"
    if printf '%s\n' "$files" | coord_pin_check "$d" >/dev/null 2>&1; then
      echo "manifest-lint: SELF-TEST FAILED — a missing newTag passed instead of failing closed" >&2; rc=1
    fi
  fi
  rm -rf "$d"
  return "$rc"
}
coord_pin_self_test || exit 1

# The scan set: tracked manifests + any images.env, minus the frozen fixture worlds. `--others` so a
# locally-added-but-unstaged manifest is seen too (CI's tree is fully committed either way).
coord_files="$(git ls-files -z --cached --others --exclude-standard | tr '\0' '\n' \
  | grep -E '(\.ya?ml$|(^|/)images\.env$)' | grep -Ev '(^|/)fixtures/' || true)"
[ -n "$coord_files" ] || { echo "manifest-lint: FAIL — the coordinator pin scan selected no files; the file list is broken (fail closed)" >&2; exit 1; }
if ! coord_out="$(printf '%s\n' "$coord_files" | coord_pin_check .)"; then
  echo "manifest-lint: FAIL — agent-coordinator image literal(s) disagree with ${COORD_KUSTOMIZATION}'s" >&2
  echo "  newTag (FU-152: two homes, one rule — the deploy-pin sweep rewrites them together):" >&2
  printf '%s\n' "$coord_out" >&2
  exit 1
fi
echo "manifest-lint: agent-coordinator image pins OK (every literal equals the kustomize newTag)"
