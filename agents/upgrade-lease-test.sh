#!/usr/bin/env bash
# upgrade-lease-test — the lease CLI (agents/upgrade-lease.sh, ADR-150) against a FAKE kubectl: a
# ConfigMap store on disk that answers get/create/delete/patch the way the API does, plus a fixed
# clock, so every rule in the header is asserted without a cluster:
#   open-new · open-same-sha-noop (the ArgoCD retry rule) · open-other-sha-replaces (new started) ·
#   renew-capped (never past max-end) · confirm-missing-ok · list-expired · vendored copy identical.
#   devbox run upgrade-lease-test   (or: bash agents/upgrade-lease-test.sh)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/store"
export STORE="$T/store" CALLS="$T/calls" FAKE_NOW="2026-10-07T01:00:00Z"
: >"$CALLS"

# ── the fake kubectl: get/create/delete/patch on a per-namespace file store ──────────────────
cat >"$T/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CALLS"
ns=default; args=()
while [ $# -gt 0 ]; do case "$1" in -n) ns="$2"; shift;; --kubeconfig) shift;; *) args+=("$1");; esac; shift; done
set -- "${args[@]}"
d="$STORE/$ns"; mkdir -p "$d"
case "$1 $2" in
  "get configmap")
    if [ "${3:-}" = "-l" ]; then
      items="$(for f in "$d"/*.json; do [ -f "$f" ] && cat "$f"; done | jq -s '.')"
      jq -n --argjson items "$items" '{items: $items}'; exit 0; fi
    [ -f "$d/$3.json" ] || { echo "Error from server (NotFound): configmaps \"$3\" not found" >&2; exit 1; }
    cat "$d/$3.json" ;;
  "create -f")
    doc="$(cat)"; name="$(printf '%s' "$doc" | jq -r .metadata.name)"
    [ -f "$d/$name.json" ] && { echo "Error from server (AlreadyExists): configmaps \"$name\" already exists" >&2; exit 1; }
    printf '%s' "$doc" | jq --arg ts "$FAKE_NOW" '.metadata.creationTimestamp = $ts' >"$d/$name.json"
    echo "configmap/$name created" ;;
  "delete configmap") rm -f "$d/$3.json"; echo "configmap \"$3\" deleted" ;;
  "patch configmap")
    name="$3"; shift 3; p=""; while [ $# -gt 0 ]; do [ "$1" = "-p" ] && p="$2"; shift; done
    jq --argjson p "$p" '.data += $p.data' "$d/$name.json" >"$d/$name.tmp" && mv "$d/$name.tmp" "$d/$name.json"
    echo "configmap/$name patched" ;;
  *) echo "fake kubectl: unhandled: $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$T/bin/kubectl"
export PATH="$T/bin:$PATH"
export LEASE_NOW_CMD="echo $FAKE_NOW"
L="bash $HERE/upgrade-lease.sh"
SUBJ=argocd/platform/kube-prometheus-stack.yaml
fails=0; n=0
j() { jq -r "$1" <<<"$2"; }                      # j <filter> <json>
is() { n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else fails=$((fails+1)); echo "FAIL $1: got '$2' want '$3'"; fi; }
yes() { local name="$1"; shift; n=$((n+1)); if "$@"; then echo "ok   $name"; else fails=$((fails+1)); echo "FAIL $name"; fi; }   # yes <name> <cmd…>
LEASE_FILE="$STORE/agent-coordinator/upgrade-lease-kube-prometheus-stack.json"

# 1. open-new
out="$($L open --subject $SUBJ --chart kube-prometheus-stack --sha aaaa1111 --from 86.3.2 --to 91.8.0 --expect-min 20 --max-min 60 --by test --reason first 2>/dev/null)"
is open-new-name "$(j .name "$out")" upgrade-lease-kube-prometheus-stack
is open-new-started "$(j .started "$out")" "$FAKE_NOW"
is open-new-expected-end "$(j '.["expected-end"]' "$out")" 2026-10-07T01:20:00Z
is open-new-max-end "$(j '.["max-end"]' "$out")" 2026-10-07T02:00:00Z
is open-new-label "$(jq -r '.metadata.labels["homelab.teststuff.net/upgrade-lease"]' "$LEASE_FILE")" true
is open-new-not-expired "$(j .expired "$out")" false

# 2. open-same-sha-noop: a later clock, the same sha → no create, no delete, deadlines untouched
: >"$CALLS"
export LEASE_NOW_CMD="echo 2026-10-07T01:15:00Z"
out="$($L open --subject $SUBJ --chart kube-prometheus-stack --sha aaaa1111 --from 86.3.2 --to 91.8.0 --expect-min 20 --max-min 60 2>/dev/null)"
is same-sha-no-write "$(grep -cE ' (create -f|delete configmap)' "$CALLS")" 0
is same-sha-deadline-kept "$(j '.["expected-end"]' "$out")" 2026-10-07T01:20:00Z

# 3. open-other-sha-replaces: delete + create, a new started / max-end
: >"$CALLS"
out="$($L open --subject $SUBJ --chart kube-prometheus-stack --sha bbbb2222 --from 86.3.2 --to 91.9.0 --expect-min 20 --max-min 60 2>/dev/null)"
is other-sha-delete-then-create "$(grep -oE ' (create -f|delete configmap)' "$CALLS" | awk '{printf "%s ", $1}')" "delete create "
is other-sha-new-sha "$(j .sha "$out")" bbbb2222
is other-sha-new-to "$(j .to "$out")" 91.9.0
is other-sha-new-max-end "$(j '.["max-end"]' "$out")" 2026-10-07T02:15:00Z

# 4. renew-capped: +20 inside the cap moves; +600 is capped at max-end
export LEASE_NOW_CMD="echo 2026-10-07T01:30:00Z"
out="$($L renew --subject $SUBJ --expect-min 20 2>/dev/null)"
is renew-moves "$(j '.["expected-end"]' "$out")" 2026-10-07T01:50:00Z
out="$($L renew --subject $SUBJ --expect-min 600 2>/dev/null)"
is renew-capped "$(j '.["expected-end"]' "$out")" 2026-10-07T02:15:00Z

# 5. list-expired: past the deadline the box's read says expired
export LEASE_NOW_CMD="echo 2026-10-07T03:00:00Z"
out="$($L list 2>/dev/null)"
is list-one-line "$(printf '%s\n' "$out" | wc -l)" 1
is list-expired "$(j .expired "$out")" true
is list-started "$(j .started "$out")" "$FAKE_NOW"

# 6. confirm, then confirm-missing-ok (idempotent), then list is empty
$L confirm --subject $SUBJ 2>/dev/null; rc1=$?
$L confirm --subject $SUBJ 2>/dev/null; rc2=$?
is confirm-rc "$rc1/$rc2" 0/0
yes confirm-deleted test ! -f "$LEASE_FILE"
is list-empty "$($L list 2>/dev/null)" ""

# 7. renew on nothing is a loud failure; a missing flag names the flag
$L renew --subject $SUBJ --expect-min 5 >/dev/null 2>&1; is renew-missing-fails "$?" 2
is open-missing-flag "$($L open --subject $SUBJ 2>&1)" "upgrade-lease: open needs --chart"

# 8. the vendored copy in the hook kustomize dir is byte-identical (the ConfigMap the Jobs run)
yes vendored-copy-identical cmp -s "$HERE/upgrade-lease.sh" "$HERE/../argocd/resources/kube-prometheus-stack-lease/upgrade-lease.sh"

echo "upgrade-lease-test: $((n-fails))/$n ok"
[ "$fails" -eq 0 ]
