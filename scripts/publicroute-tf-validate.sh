#!/usr/bin/env bash
# publicroute-tf-validate.sh — homelab CI gate (#1315). The PublicRoute Composition
# (argocd/resources/publicroute/composition.yaml) TEMPLATES Terraform into a provider-terraform
# Workspace that reconciles against the LIVE Cloudflare zones. kubeconform sees the Composition as
# a valid CR and never reads the module string inside, so PR #1312 shipped schema-invalid
# `cloudflare_ruleset` shapes twice, CI-green both times — and the merged round 3 still fails
# `tofu validate` for EVERY profile (v4 block syntax under the v5 provider, a phase name that does
# not exist, 2026-09-03 scratchpad run). The failure surface was "claim reconciles red after
# merge" — the expensive direction. This gate moves it to the PR:
#
#   1. RENDER each fixture XR through the real function pipeline (`crossplane composition render`,
#      the same function image + Crossplane engine version the cluster runs — one home for both
#      pins: argocd/resources/crossplane/functions.yaml + argocd/platform/crossplane.yaml);
#   2. EXTRACT every rendered Workspace's `spec.forProvider.module`;
#   3. `tofu validate` it against the Cloudflare provider version the ProviderConfig pins
#      (argocd/resources/crossplane/providerconfig.yaml — the gate reads the pin, never restates it).
#   Plus one NEGATIVE fixture: a hostname outside the namespace's delegated subtree must make the
#   template `fail` — the XRD's privilege boundary is a template guard, so prove it still fires.
#
# WAN-free by construction (the FU-130 class): the provider comes from nixpkgs via devbox.json
# (`terraform-providers.cloudflare_cloudflare`, served by the LAN nix cache / the runner warm store)
# through a `filesystem_mirror`; the function images pull through the LAN ghcr mirror (ADR-091,
# plain http — the ARC dind daemon lists the VIP insecure, 29596cd9); the Crossplane engine image
# is docker.io, which dockerd mirrors transparently. Docker IS required (render runs the functions
# as containers) — the jail has none, the ARC runner and ci-runner-01 do.
#
# Engine caveat: the cluster's provider-terraform v1.1.1 embeds Terraform 1.5.5; this gate
# validates with OpenTofu. Provider SCHEMA checks are identical (same provider binary), and every
# defect seen so far was a schema error. Only a language feature OpenTofu accepts and Terraform 1.5
# rejects would slip through — don't use tofu-only syntax in the Composition.
#
#   devbox run publicroute-tf-validate
#   REGISTRY_MIRROR_GHCR=http://192.168.40.21   (default; the pod-only env-card contract)
#   PUBLICROUTE_FUNCTION_REGISTRY=ghcr.io       (override: pull upstream, e.g. off-LAN)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

COMPOSITION=argocd/resources/publicroute/composition.yaml
XRD=argocd/resources/publicroute/xrd.yaml
FUNCTIONS=argocd/resources/crossplane/functions.yaml
PROVIDERCONFIG=argocd/resources/crossplane/providerconfig.yaml
FIXTURES=scripts/fixtures/publicroute
mirror="${REGISTRY_MIRROR_GHCR:-http://192.168.40.21}"
FN_REGISTRY="${PUBLICROUTE_FUNCTION_REGISTRY:-${mirror#*://}}"   # bare ref cannot carry a scheme

for tool in crossplane tofu yq docker; do
  command -v "$tool" >/dev/null || { echo "publicroute-tf-validate: FAIL — '$tool' not on PATH (devbox.json / a docker daemon)" >&2; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "publicroute-tf-validate: FAIL — no reachable docker daemon (render runs the functions as containers)" >&2; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# ── the pins, each read from its one home ──────────────────────────────────────────────────────
xp_version="v$(yq -r '.spec.source.targetRevision' argocd/platform/crossplane.yaml)"
cf_pin="$(yq -r '.spec.configuration' "$PROVIDERCONFIG" | awk '/cloudflare = \{/,/\}/' | sed -n 's/.*version *= *"\([^"]*\)".*/\1/p')"
[ -n "$cf_pin" ] || { echo "publicroute-tf-validate: FAIL — no cloudflare provider version pin in $PROVIDERCONFIG (required_providers.cloudflare.version)" >&2; exit 1; }
# the nix-packaged provider (devbox profile) — must be the SAME version the cluster pins, or the
# gate validates against something the reconciler will not run
prov_dir="$(ls -d "${DEVBOX_PACKAGES_DIR:?run via devbox}"/libexec/terraform-providers/registry.terraform.io/cloudflare/cloudflare/* 2>/dev/null | head -1 || true)"
[ -n "$prov_dir" ] || { echo "publicroute-tf-validate: FAIL — terraform-providers.cloudflare_cloudflare not in the devbox profile" >&2; exit 1; }
nix_ver="$(basename "$prov_dir")"
[ "$nix_ver" = "$cf_pin" ] || { echo "publicroute-tf-validate: FAIL — ProviderConfig pins cloudflare $cf_pin but devbox.json ships $nix_ver; bump both together (one is what the cluster applies, the other is what this gate validates)" >&2; exit 1; }

# ── functions manifest for render: same images/tags as the cluster, pulled via the LAN mirror ──
# xpkg.crossplane.io fronts ghcr.io/crossplane-contrib; the mirror is a pull-through of ghcr, so
# rewriting the host is all the redirection there is (kind-ci REGISTRY_MIRROR_GHCR pattern).
yq "select(.kind == \"Function\")
    | .spec.package |= sub(\"^xpkg.crossplane.io/\", \"${FN_REGISTRY}/\")
    | .metadata.annotations[\"render.crossplane.io/runtime-docker-pull-policy\"] = \"IfNotPresent\"" \
  "$FUNCTIONS" > "$work/functions.yaml"

# ── tofu: provider from the nix filesystem mirror, no registry access ────────────────────────
# OpenTofu resolves `cloudflare/cloudflare` to registry.opentofu.org; the nix layout is keyed by
# registry.terraform.io (same binaries). Real directories down to <os_arch> with the provider
# FILE symlinked in — tofu's mirror walker does not descend into symlinked directories (a
# symlinked host dir "was not found in any of the search locations", run 33725934501).
for arch_dir in "$prov_dir"/*/; do
  m="$work/mirror/registry.opentofu.org/cloudflare/cloudflare/$nix_ver/$(basename "$arch_dir")"
  mkdir -p "$m"; ln -s "$arch_dir"* "$m/"
done
cat > "$work/tofu.rc" <<EOF
provider_installation {
  filesystem_mirror { path = "$work/mirror" }
}
EOF
export TF_CLI_CONFIG_FILE="$work/tofu.rc" TF_IN_AUTOMATION=1

render() { # <xr-file> <out-file>
  crossplane composition render "$1" "$COMPOSITION" "$work/functions.yaml" \
    --xrd "$XRD" --crossplane-image "docker.io/crossplane/crossplane:${xp_version}" \
    --timeout 3m > "$2" 2> "$2.err"
}

# Fixtures carry the XRD version they are written for (`*-v1alphaN-*`); only those matching the
# Composition's compositeTypeRef run — render refuses a mismatch, and the legacy set stays on
# disk as documentation when the XRD moves (goal #1302: v1alpha1 → v1alpha2). Zero matching
# fixtures of either kind is a FAIL: a version flip must bring its fixtures along.
xr_version="$(yq -r '.spec.compositeTypeRef.apiVersion' "$COMPOSITION")"
matches() { [ "$(yq -r '.apiVersion' "$1")" = "$xr_version" ]; }

echo "publicroute-tf-validate: crossplane ${xp_version}, functions via ${FN_REGISTRY}, cloudflare provider ${cf_pin} (nix), XR ${xr_version}"
validated=0
for xr in "$FIXTURES"/*-xr.yaml; do
  name="$(basename "$xr" -xr.yaml)"
  matches "$xr" || { echo "  --  $name (skipped: fixture is $(yq -r '.apiVersion' "$xr"), composition composes $xr_version)"; continue; }
  if ! render "$xr" "$work/$name.rendered.yaml"; then
    echo "publicroute-tf-validate: FAIL — render of fixture '$name' errored:" >&2; cat "$work/$name.rendered.yaml.err" >&2; exit 1
  fi
  modules="$(yq 'select(.kind == "Workspace") | .spec.forProvider.module' "$work/$name.rendered.yaml")"
  [ -n "$modules" ] && [ "$modules" != null ] || { echo "publicroute-tf-validate: FAIL — fixture '$name' rendered no Workspace module" >&2; exit 1; }
  d="$work/tf-$name"; mkdir -p "$d"
  printf '%s\n' "$modules" > "$d/main.tf"
  cat > "$d/versions.tf" <<EOF
terraform {
  required_providers {
    cloudflare = { source = "cloudflare/cloudflare", version = "${cf_pin}" }
  }
}
EOF
  tofu -chdir="$d" init -backend=false -input=false -no-color >/dev/null 2> "$d/init.err" \
    || { echo "publicroute-tf-validate: FAIL — tofu init for fixture '$name':" >&2; cat "$d/init.err" >&2; exit 1; }
  if ! out="$(tofu -chdir="$d" validate -no-color 2>&1)"; then
    echo "publicroute-tf-validate: FAIL — fixture '$name': the Composition renders Terraform the cloudflare ${cf_pin} provider rejects:" >&2
    echo "$out" >&2
    echo "--- rendered module ($name) ---" >&2; nl -ba "$d/main.tf" >&2
    exit 1
  fi
  n="$(grep -c '^resource "' "$d/main.tf" || true)"
  echo "  ok  $name ($n resource(s) validated)"
  validated=$((validated + 1))
done
[ "$validated" -gt 0 ] || { echo "publicroute-tf-validate: FAIL — no *-xr.yaml fixtures under $FIXTURES" >&2; exit 1; }

# ── negative: the subtree guard must still fire ──────────────────────────────────────────────
guarded=0
for xr in "$FIXTURES"/*-xr.must-fail.yaml; do
  [ -e "$xr" ] || continue
  name="$(basename "$xr" -xr.must-fail.yaml)"
  matches "$xr" || { echo "  --  $name (skipped: fixture is $(yq -r '.apiVersion' "$xr"), composition composes $xr_version)"; continue; }
  guarded=$((guarded + 1))
  if render "$xr" "$work/$name.rendered.yaml"; then
    echo "publicroute-tf-validate: FAIL — fixture '$name' was expected to FAIL rendering (template guard), but rendered" >&2; exit 1
  fi
  grep -q 'PublicRoute .*/.*:' "$work/$name.rendered.yaml.err" \
    || { echo "publicroute-tf-validate: FAIL — fixture '$name' failed for a reason other than the template guard:" >&2; cat "$work/$name.rendered.yaml.err" >&2; exit 1; }
  echo "  ok  $name (guard fired: $(grep -o 'PublicRoute [^"]*' "$work/$name.rendered.yaml.err" | head -1 | cut -c1-100))"
done
[ "$guarded" -gt 0 ] || { echo "publicroute-tf-validate: FAIL — no *-xr.must-fail.yaml fixture for $xr_version; the subtree guard is unproven" >&2; exit 1; }
echo "publicroute-tf-validate: OK — $validated fixture(s) render and validate against cloudflare ${cf_pin}; $guarded guard fixture(s) refused"
