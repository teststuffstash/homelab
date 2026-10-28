#!/bin/bash
# vendor-kyverno-policies — (re)fetch the kyverno/policies library rules that policy/component/
# carries, from ONE pinned commit of the `release-1.19` branch, each file rewritten as a generated
# header + the verbatim upstream body. scripts/component-check.sh evaluates them (report-only).
#
#   devbox run -- bash scripts/vendor-kyverno-policies.sh            # rewrite policy/component/ from the pin
#   devbox run -- bash scripts/vendor-kyverno-policies.sh --check    # exit 1 if a re-fetch would change anything
#
# TWO CALLERS, one script (the G12 shape — docs/renovate.md §Gotchas, scripts/upstream-alerts-refresh.sh
# is the first):
#   the seat   after editing MANIFEST below (add/drop a rule, change a local patch) — run, review, commit
#   Renovate   the `git-refs` customManager bumps KYVERNO_POLICIES_SHA below, then this script runs as
#              a `postUpgradeTasks` command on that branch (.github/renovate-global.json), so a library
#              bump is BORN with every vendored file re-fetched; component-check's report on the branch
#              shows what the new upstream text changes. The Renovate container is the SLIM image:
#              bash, curl, sed, awk, grep, coreutils — no yq, no jq, no devbox (and nothing to
#              `install-tool` here). Keep it that way.
#
# WHY release-1.19, NOT main (operator ruling 2026-10-25). main has removed every legacy ClusterPolicy
# and is mid-migration to the CEL types (`.github/legacy-policy-migration.json` on main: 462 removed,
# 172 equivalent / 122 partial / 168 missing replacements). `release-1.19` matches our CLI minor
# (kyverno 1.19.x, devbox.lock) and still carries BOTH the legacy `best-practices/`, `other/`, `argo/`
# ClusterPolicy dirs and the `-vpol` CEL dirs, so per rule we take the variant WITHOUT a behavioural
# gap: `equivalent` in the audit → the CEL file; `partial`/`missing` → the legacy ClusterPolicy (the
# CLI evaluates both kinds). The audit's `reason` text for every partial pick is in that file's
# header (`# choice:`), verbatim. The library publishes no release tags, so the pin is a branch head.
#
# PINS — the two lines below are read by Renovate (git-refs digest, depName kyverno/policies) and by
# scripts/dependency-coverage.py (class 18, docs/dependency-classes.yaml). Keep REF first, SHA next,
# no blank line between, bare 40-hex value.
KYVERNO_POLICIES_REF=release-1.19
KYVERNO_POLICIES_SHA=282e77f6d54e1e1a636190ff2dacc3d02c2d689c
#
# MANIFEST — one line per vendored file: `<upstream path>|<local file>|<choice>|<note>`.
#   choice  cel      the `-vpol` CEL ValidatingPolicy — the audit marks it `equivalent` to the legacy rule
#           legacy   the kyverno.io/v1 ClusterPolicy — the audit marks the CEL file `partial` (reason in
#                    the note) or `missing`; or the rule only exists as legacy
#   note    free text for the header; the audit's `reason` quoted for every `partial`
# Every rule is audit-only upstream (validationFailureAction: Audit / validationActions: [Audit]) —
# a rule that is not would need a local patch, which only PATCHES below may apply.
# Skipped on purpose (operator 2026-10-25): require-drop-all, require-drop-cap-net-raw (inside the PSS
# restricted profile component-check renders from the kyverno-policies chart), disallow-empty-ingress-
# host, disallow-helm-tiller, require-labels, application-prevent-default-project (platform
# Applications use `default` by design).
MANIFEST='
best-practices-vpol/require-pod-requests-limits/require-pod-requests-limits.yaml|require-pod-requests-limits.yaml|cel|audit: equivalent — "Both require nonempty CPU/memory requests and memory limits on every regular, init and ephemeral Pod container, with Audit/background behavior."
best-practices/disallow-latest-tag/disallow-latest-tag.yaml|disallow-latest-tag.yaml|legacy|audit: CEL file PARTIAL — "Target checks explicit image tags and :latest only on regular containers; legacy checks regular, init and ephemeral containers in both rules. Init/ephemeral tag checks are omitted."
best-practices/require-ro-rootfs/require-ro-rootfs.yaml|require-ro-rootfs.yaml|legacy|audit: CEL file PARTIAL — "Read-only-root-filesystem predicate is retained, but target requires it for init and ephemeral containers as well as regular containers; legacy checks only regular containers. This changes accepted workloads."
best-practices/require-probes/require-probes.yaml|require-probes.yaml|legacy|audit: CEL file PARTIAL — "Target checks at least one liveness/readiness/startup probe, but changes Audit to Deny and expands regular containers to init/ephemeral containers. Its explicit CronJob match also reads spec.template rather than spec.jobTemplate.spec.template."
best-practices/restrict-image-registries/restrict-image-registries.yaml|restrict-image-registries.yaml|legacy|audit: CEL file PARTIAL — "target mixes pods and pods/ephemeralcontainers in match resources and loses default controller autogeneration. CLI apply to a Deployment using example:test produced no target evaluation, whereas legacy Pod rules autogenerate controller checks." LOCAL PATCH: the allowlist (see PATCHES in scripts/vendor-kyverno-policies.sh)
best-practices/disallow-default-namespace/disallow-default-namespace.yaml|disallow-default-namespace.yaml|legacy|audit: CEL file PARTIAL — "legacy disables autogen and explicitly limits controllers to DaemonSet/Deployment/Job/StatefulSet, while target leaves default autogeneration enabled, additionally covering ReplicaSet/ReplicationController/CronJob."
best-practices/check-deprecated-apis/check-deprecated-apis.yaml|check-deprecated-apis.yaml|legacy|audit: CEL file PARTIAL — "Target covers the five removal cohorts (1.25/1.26/1.27/1.29/1.32) and relevant API versions/kinds, but validationActions=Deny changes the legacy Audit-only behavior."
best-practices-vpol/restrict-node-port/restrict-node-port.yaml|restrict-node-port.yaml|cel|audit: equivalent — "Same Service NodePort prohibition and Audit/background behavior."
best-practices/restrict-service-external-ips/restrict-service-external-ips.yaml|restrict-service-external-ips.yaml|legacy|audit: CEL file PARTIAL — "Target allows explicitly empty externalIPs lists, whereas the legacy CEL requires the field to be absent and the pattern uses a negation anchor forbidding it."
best-practices/disallow-cri-sock-mount/disallow-cri-sock-mount.yaml|disallow-cri-sock-mount.yaml|legacy|audit: CEL file PARTIAL — "Target checks all four socket families, but replaces exact negative path patterns with unanchored regular expressions with unescaped dots. For example a hostPath ending dockerXsock or /var/run/docker.sock.backup is newly rejected."
other-vpol/restrict-wildcard-verbs/restrict-wildcard-verbs.yaml|restrict-wildcard-verbs.yaml|cel|audit: equivalent — "Same Role/ClusterRole '"'"'*'"'"' verb prohibition."
other-vpol/restrict-wildcard-resources/restrict-wildcard-resources.yaml|restrict-wildcard-resources.yaml|cel|audit: equivalent — "Same Role/ClusterRole '"'"'*'"'"' resource prohibition."
other/restrict-escalation-verbs-roles/restrict-escalation-verbs-roles.yaml|restrict-escalation-verbs-roles.yaml|legacy|audit: CEL file PARTIAL — "Target additionally rejects '"'"'*'"'"' in all three dimensions, so wildcard-only RBAC permissions change from permitted to prohibited." (restrict-wildcard-verbs/-resources already own the wildcard case)
other-vpol/restrict-binding-clusteradmin/restrict-binding-clusteradmin.yaml|restrict-binding-clusteradmin.yaml|cel|audit: equivalent — "Same roleRef.name != cluster-admin requirement on both binding kinds."
other-vpol/restrict-binding-system-groups/restrict-binding-system-groups.yaml|restrict-binding-system-groups.yaml|cel|audit: equivalent — "All three binding subject prohibitions retained: system:anonymous, system:unauthenticated and system:masters."
other-vpol/restrict-secret-role-verbs/restrict-secret-role-verbs.yaml|restrict-secret-role-verbs.yaml|cel|audit: equivalent — "Same get/list/watch prohibition for Secret rules in both Role and ClusterRole."
other/restrict-clusterrole-nodesproxy/restrict-clusterrole-nodesproxy.yaml|restrict-clusterrole-nodesproxy.yaml|legacy|audit: CEL file PARTIAL — "Legacy flattening denies when nodes/proxy occurs in any rule and core API group occurs in any rule. Target correlates both in the same rule and dereferences rule.resources without guarding nonResourceURLs rules. Not the same accepted set."
other-vpol/restrict-sa-automount-sa-token/restrict-sa-automount-sa-token.yaml|restrict-sa-automount-sa-token.yaml|cel|audit: equivalent — "Same ServiceAccount automountServiceAccountToken=false requirement."
other-vpol/prevent-bare-pods/prevent-bare-pods.yaml|prevent-bare-pods.yaml|cel|audit: equivalent — "Same Pod ownerReferences presence check with autogen disabled; no controller templates rejected as bare Pods."
argo/application-field-validation/application-field-validation.yaml|application-field-validation.yaml|legacy|audit: MISSING — "No eligible CEL target validates Application source path/chart exclusivity and destination server/name exclusivity"; legacy is the only form
argo/applicationset-name-matches-project/applicationset-name-matches-project.yaml|applicationset-name-matches-project.yaml|legacy|audit: MISSING — "No eligible target matches ApplicationSet and requires spec.template.spec.project to equal metadata.name"; legacy is the only form
'
# PATCHES — the ONLY edits applied to an upstream body, each a sed expression keyed by local file.
# restrict-image-registries ships a placeholder allowlist (`eu.foo.io/* | bar.io/*`, "requires
# customization"); ours is the platform's registry set: the three public registries the manifests
# pull from (ghcr.io, docker.io, quay.io), registry.k8s.io (metrics-server et al.), mcr.microsoft.com
# (the Playwright image class), the two platform services whose vendor publishes nowhere else
# (xpkg.crossplane.io — Crossplane packages; code.forgejo.org — Forgejo's images), the first-party
# push registry (registry.teststuff.net, ADR-121) and the ADR-091 pull-through mirror VIPs
# (192.168.40.20 docker.io · .21 ghcr · .31 mcr — SERVICES.md §Registry mirrors) that kata rides and
# VMs pull through. A bare `nginx:1.2` (implicit docker.io) is a finding by construction — the glob
# needs the host — and that is the reading, not a defect (2026-10-25 master: every registry finding
# but one is a bare Docker Hub ref; the one is infisical's redis subchart default on mirror.gcr.io).
REGISTRY_ALLOWLIST='ghcr.io/* | docker.io/* | quay.io/* | registry.k8s.io/* | mcr.microsoft.com/* | xpkg.crossplane.io/* | code.forgejo.org/* | registry.teststuff.net/* | 192.168.40.20/* | 192.168.40.21/* | 192.168.40.31/*'
patch_body() {   # patch_body <local file> <body file> — in place
  case "$1" in
    restrict-image-registries.yaml)
      sed -i "s#image: \"eu.foo.io/\* | bar.io/\*\"#image: \"$REGISTRY_ALLOWLIST\"#" "$2"
      grep -cF -- "$REGISTRY_ALLOWLIST" "$2" >/dev/null || { echo "vendor-kyverno-policies: restrict-image-registries: upstream placeholder allowlist not found — the PATCH no longer applies, re-read the upstream file" >&2; exit 2; };;
  esac
}
set -euo pipefail
cd "$(dirname "$0")/.."
DEST=policy/component
RAW="https://raw.githubusercontent.com/kyverno/policies/$KYVERNO_POLICIES_SHA"
CHECK=false
case "${1:-}" in
  --check) CHECK=true;;
  "") ;;
  -h|--help) sed -n '2,8p' "$0"; exit 0;;
  *) echo "vendor-kyverno-policies: unknown arg $1" >&2; exit 2;;
esac
[[ "$KYVERNO_POLICIES_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "vendor-kyverno-policies: KYVERNO_POLICIES_SHA is not a 40-hex commit" >&2; exit 2; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

fetch() {   # fetch <upstream path> <out>
  curl -fsSL --retry 3 -o "$2" "$RAW/$1" || { echo "vendor-kyverno-policies: fetch failed: $RAW/$1" >&2; exit 2; }
  [ -s "$2" ] || { echo "vendor-kyverno-policies: empty body: $1" >&2; exit 2; }
}
header() {   # header <upstream path> <local file> <choice> <note>
  local kind; kind=$(awk '/^kind:/{print $2; exit}' "$tmp/body")
  local patched=""; case "$2" in restrict-image-registries.yaml) patched=" — LOCAL PATCH applied (allowlist only; PATCHES in the script)";; esac
  cat <<EOF
# VENDORED from github.com/kyverno/policies — $1
# ref: $KYVERNO_POLICIES_REF @ $KYVERNO_POLICIES_SHA — GENERATED by scripts/vendor-kyverno-policies.sh; do not hand-edit (a
# Renovate SHA bump re-runs the script; the seat runs it after editing its MANIFEST). Body below the
# header is the upstream file verbatim$patched.
# license: Apache-2.0, Copyright The Kyverno Authors — copy in policy/component/LICENSE-kyverno-policies
# (Apache-2.0 §4(a); one-way compatible with this repo's AGPL-3.0; upstream ships no NOTICE file).
# choice: $3 ($kind) — $4
# Evaluated report-only by scripts/component-check.sh.
EOF
}

# the generated set, built in $tmp/out
mkdir -p "$tmp/out"
n=0
while IFS='|' read -r path local choice note; do
  [ -n "$path" ] || continue
  n=$((n+1))
  fetch "$path" "$tmp/body"
  grep -qE '^(  validationFailureAction: Audit|  validationActions:( \[Audit\]| *$))' "$tmp/body" \
    || { echo "vendor-kyverno-policies: $path is not Audit upstream — refusing (the set is audit-only; add a PATCH deliberately or drop the rule)" >&2; exit 2; }
  if grep -qE '^  validationActions: *$' "$tmp/body"; then
    grep -A1 -E '^  validationActions: *$' "$tmp/body" | grep -qE '^ +- Audit$' \
      || { echo "vendor-kyverno-policies: $path validationActions is not [Audit]" >&2; exit 2; }
  fi
  patch_body "$local" "$tmp/body"
  { header "$path" "$local" "$choice" "$note"; cat "$tmp/body"; } > "$tmp/out/$local"
done <<<"$MANIFEST"
[ "$n" -gt 0 ] || { echo "vendor-kyverno-policies: empty MANIFEST" >&2; exit 2; }
fetch LICENSE "$tmp/out/LICENSE-kyverno-policies"

# what is vendored today = every file whose first line carries the VENDORED marker, plus the license
committed=$(grep -l '^# VENDORED from github.com/kyverno/policies' "$DEST"/*.yaml 2>/dev/null || true)
if $CHECK; then
  rc=0
  for f in "$tmp/out"/*; do
    b=$(basename "$f")
    if [ ! -f "$DEST/$b" ]; then echo "vendor-kyverno-policies --check: MISSING $DEST/$b"; rc=1
    elif ! cmp -s "$f" "$DEST/$b"; then echo "vendor-kyverno-policies --check: DRIFT $DEST/$b (re-fetch at $KYVERNO_POLICIES_SHA differs)"; diff -u "$DEST/$b" "$f" | sed -n '1,20p' || true; rc=1; fi
  done
  for f in $committed; do
    [ -f "$tmp/out/$(basename "$f")" ] || { echo "vendor-kyverno-policies --check: STALE $f (vendored, but not in MANIFEST)"; rc=1; }
  done
  [ "$rc" -eq 0 ] && echo "vendor-kyverno-policies --check: $n policies + LICENSE in sync with $KYVERNO_POLICIES_REF @ ${KYVERNO_POLICIES_SHA:0:12}"
  exit "$rc"
fi
for f in $committed; do rm -f "$f"; done
cp "$tmp/out"/* "$DEST/"
echo "vendor-kyverno-policies: wrote $n policies + LICENSE-kyverno-policies to $DEST/ from $KYVERNO_POLICIES_REF @ ${KYVERNO_POLICIES_SHA:0:12}"
