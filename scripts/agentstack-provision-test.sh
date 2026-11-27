#!/usr/bin/env bash
# agentstack-provision-test — the gate for AgentStack repos[].provision (ADR-169, docs/patterns/app-owned-resources.md).
# The Composition writes Terraform from stack fields, and kubeconform never runs its templates, so:
#
#   1. RENDER every scripts/fixtures/agentstack-provision/*-xr.yaml through the real function pipeline
#      (the cluster-pinned engine + function binaries, scripts/xr-render-lib.sh);
#   2. every rendered provision Workspace (`<repo>.<name>`) must PARSE as HCL (`tofu fmt`; no
#      provider download — the garage provider is not in nixpkgs, so `tofu validate` would need WAN);
#   3. every ADOPTING Workspace must be EQUIVALENT to expected/<adopt.workspace>.tf, the live legacy
#      module it takes over (scripts/provision-adopt-check.py: same blocks, attributes, outputs) —
#      a non-equivalent adoption would change live buckets/keys/passwords on its first reconcile;
#      an observe-mode one must carry the Observe-only policy and no connection Secret;
#   4. every *-xr.must-fail.yaml must FAIL with the Composition's own guard message (the per-stack
#      bounds: alias space, adoptable Workspaces, Infisical keys, namespaces, grant shapes).
#
#   devbox run -- bash scripts/agentstack-provision-test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
COMPOSITION=argocd/resources/agentstack/composition.yaml
XRD=argocd/resources/agentstack/xrd.yaml
FIX=scripts/fixtures/agentstack-provision
# shellcheck source=scripts/xr-render-lib.sh
. scripts/xr-render-lib.sh
for tool in crossplane tofu yq python3; do
  command -v "$tool" >/dev/null || { echo "agentstack-provision-test: FAIL — '$tool' not on PATH (devbox.json)" >&2; exit 1; }
done
work="$(mktemp -d)"; trap 'xr_stop; rm -rf "$work"' EXIT
xr_start "$ROOT" "$work/xr" || exit 1
fail() { echo "agentstack-provision-test: FAIL — $*" >&2; exit 1; }
# A fixture's metadata.name is `<stack>--<case>`: the tree holds many fixtures per stack, and the
# iac-sentinel's kyverno pass indexes every k8s doc in a PR tree by kind/name — two AgentStacks
# named `oracle` panic it. The Composition keys its bounds on the XR name, so the render gets
# a copy with the `--<case>` suffix cut.
stack_named() { yq '.metadata.name |= sub("--.*$"; "")' "$1" > "$2"; }

rendered=0 adopted=0
for xr in "$FIX"/*-xr.yaml; do
  name="$(basename "$xr" -xr.yaml)"; out="$work/$name.yaml"
  stack_named "$xr" "$work/$name.in.yaml"
  xr_render "$work/$name.in.yaml" "$COMPOSITION" "$XRD" "$out" || { cat "$out.err" >&2; fail "fixture '$name' did not render"; }
  wss="$(yq -N -r 'select(.kind == "Workspace" and (.metadata.name | test("\\."))) | .metadata.name' "$out")"
  [ -n "$wss" ] || fail "fixture '$name' rendered no provision Workspace"
  for ws in $wss; do
    sel="select(.kind == \"Workspace\" and .metadata.name == \"$ws\")"
    yq -r "$sel | .spec.forProvider.module" "$out" > "$work/$ws.tf"
    tofu fmt -no-color - < "$work/$ws.tf" > /dev/null 2> "$work/$ws.fmt" \
      || { cat "$work/$ws.fmt" >&2; nl -ba "$work/$ws.tf" >&2; fail "$name/$ws: the rendered module is not valid HCL"; }
    legacy="$(yq -r "$sel | .metadata.annotations[\"crossplane.io/external-name\"] // \"\"" "$out")"
    policies="$(yq -r -o=json -I=0 "$sel | .spec.managementPolicies" "$out")"
    secret="$(yq -r "$sel | .spec.writeConnectionSecretToRef.name // \"\"" "$out")"
    [ "$(yq -r "$sel | .spec.deletionPolicy" "$out")" = Orphan ] || fail "$name/$ws: deletionPolicy is not Orphan"
    case "$policies" in *Delete*|'["*"]') fail "$name/$ws: management policies $policies include Delete" ;; esac
    if [ -n "$legacy" ]; then
      exp="$FIX/expected/$legacy.tf"
      [ -f "$exp" ] || fail "$name/$ws adopts $legacy but $exp is missing"
      vars=()
      for kv in $(sed -n 's/^# vars: //p' "$exp"); do vars+=(--var "$kv"); done
      python3 scripts/provision-adopt-check.py --legacy "$exp" --composed "$work/$ws.tf" "${vars[@]}" > "$work/$ws.cmp" \
        || { cat "$work/$ws.cmp" >&2; fail "$name/$ws: not equivalent to the legacy module of $legacy"; }
      if [ "$policies" = '["Observe"]' ]; then
        [ -z "$secret" ] || fail "$name/$ws: observe mode must not write a connection Secret"
      else
        [ -n "$secret" ] || fail "$name/$ws: manage mode writes no connection Secret"
      fi
      echo "  ok  $name/$ws ≡ $legacy (${policies})"
      adopted=$((adopted + 1))
    else
      [ -n "$secret" ] || fail "$name/$ws: a new entry writes no connection Secret"
      echo "  ok  $name/$ws (new, $(grep -c '^resource "' "$work/$ws.tf") resource(s), Secret $secret)"
    fi
    rendered=$((rendered + 1))
  done
done
[ "$rendered" -gt 0 ] || fail "no provision Workspace rendered"

guarded=0
for xr in "$FIX"/*-xr.must-fail.yaml; do
  name="$(basename "$xr" -xr.must-fail.yaml)"; out="$work/$name.yaml"
  stack_named "$xr" "$work/$name.in.yaml"
  if xr_render "$work/$name.in.yaml" "$COMPOSITION" "$XRD" "$out"; then fail "fixture '$name' was expected to FAIL rendering (a provision guard), but rendered"; fi
  grep -q 'AgentStack [^ ]* repo [^ ]* provision [^ ]*:' "$out.err" \
    || { cat "$out.err" >&2; fail "fixture '$name' failed for a reason other than a provision guard"; }
  echo "  ok  $name (refused: $(grep -o 'error calling fail: .*' "$out.err" | head -1 | sed 's/^error calling fail: AgentStack //' | cut -c1-120))"
  guarded=$((guarded + 1))
done
[ "$guarded" -gt 0 ] || fail "no *-xr.must-fail.yaml fixture; the provision guards are unproven"
echo "agentstack-provision-test: OK — $rendered provision Workspace(s) render as HCL, $adopted adoption(s) equivalent to their legacy module, $guarded guard fixture(s) refused"
