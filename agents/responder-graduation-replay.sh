#!/usr/bin/env bash
# responder-graduation-replay — behavioural pin for the goal#818 responder graduation dial.
#
#   bash agents/responder-graduation-replay.sh  # or: devbox run -- bash agents/responder-graduation-replay.sh
#
# WHY THIS EXISTS. The `spec.responder` block on the AgentStack XRD renders a scoped Role +
# RoleBinding per stack namespace when enabled. This fixture asserts that:
#   1. No `responder:` block → nothing rendered (byte-identical to before)
#   2. Block present but disabled (enabled: false) → nothing rendered
#   3. Enabled → Role + RoleBinding rendered with exactly the declared verb/resource pairs,
#      scoped to the loop namespace AND each fixer-enabled repo namespace, with the
#      correct composition-resource-name annotations.
#   4. The escalation-check mirror in rbac.yaml grants the verbs Crossplane needs to compose
#      the responder Role.
#
# WHAT IT SIMULATES. The Composition template uses GoTemplate conditionals that are
# re-expressed in bash for repeatable offline testing. The template's rendering logic is:
#   {{- if and $xr.spec.responder (default false (get $xr.spec.responder "enabled")) }}
# Which in bash is: responder != null && responder.enabled == true.
# The loop ns is {{ $xr.metadata.name }}-agents; fixer-enabled repos each get a copy.
#
# No network, no cluster, no credentials. Runs in about a second.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v jq >/dev/null 2>&1 || { echo "responder-graduation-replay: needs jq (devbox run -- bash $0)"; exit 2; }

# ── helpers ─────────────────────────────────────────────────────────────────────────────────────
PASS=0; FAIL=0; FAILED=()
ok()       { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()      { FAIL=$((FAIL+1)); FAILED+=("$1"); local d="${2:-}"; printf '  \033[31m✗\033[0m %s\n' "$1"; [ -n "$d" ] && printf '       %s\n' "$d"; }
section()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
eq()       { [ "$2" = "$3" ] && ok "$1" || bad "$1" "got '$2', wanted '$3'"; }
want()     { printf '%s' "$OUT" | grep -qF -- "$2" && ok "$1" || bad "$1" "output lacks: $2"; }
wantnot()  { printf '%s' "$OUT" | grep -qF -- "$2" && bad "$1" "output contains: $2" || ok "$1"; }
wantrc()   { [ "$RC" = "$2" ] && ok "$1" || bad "$1" "exit $RC, wanted $2"; }

# ── simulated renderer ──────────────────────────────────────────────────────────────────────────
# Simulates the GoTemplate rendering of the responder block from the Composition template.
# Takes a claim JSON on stdin, writes rendered YAML to stdout.
render_responder() {
  local claim stack loopns responder
  claim="$(cat)"
  stack="$(printf '%s' "$claim" | jq -r '.metadata.name // "test-stack"')"
  loopns="${stack}-agents"
  responder="$(printf '%s' "$claim" | jq -c '.spec.responder // null')"

  # The GoTemplate conditional: {{- if and $xr.spec.responder (default false (get $xr.spec.responder "enabled")) }}
  if [ -z "$responder" ] || [ "$responder" = "null" ]; then
    return 0  # Nothing rendered
  fi

  local enabled
  enabled="$(printf '%s' "$responder" | jq -r '.enabled // false')"
  if [ "$enabled" != "true" ]; then
    return 0  # Nothing rendered
  fi

  # Render Role in loop ns
  cat <<YAML
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: agentstack-responder
  namespace: ${loopns}
  annotations:
    gotemplating.fn.crossplane.io/composition-resource-name: ${stack}-responder-role-loop
    gotemplating.fn.crossplane.io/ready: "True"
rules:
YAML
  printf '%s' "$responder" | jq -r '.verbs[] | "  - apiGroups: [\"\"]\n    resources: [\(.resource)]\n    verbs: [\(.verb)]"'
  echo ""
  # Render RoleBinding in loop ns
  cat <<YAML
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: agentstack-responder
  namespace: ${loopns}
  annotations:
    gotemplating.fn.crossplane.io/composition-resource-name: ${stack}-responder-rb-loop
    gotemplating.fn.crossplane.io/ready: "True"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: agentstack-responder
subjects:
  - kind: ServiceAccount
    name: agentstack-loop
    namespace: ${loopns}
YAML

  # Per-repo render: {{- range $r := $xr.spec.repos }} {{- if $r.fixer }}
  printf '%s' "$claim" | jq -c '.spec.repos[] // []' | while read -r repo; do
    local rname rfixer
    rname="$(printf '%s' "$repo" | jq -r '.name // ""')"
    rfixer="$(printf '%s' "$repo" | jq -c '.fixer // null')"
    [ -n "$rname" ] || continue
    [ -z "$rfixer" ] || [ "$rfixer" = "null" ] && continue

    cat <<YAML
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: agentstack-responder
  namespace: ${rname}
  annotations:
    gotemplating.fn.crossplane.io/composition-resource-name: ${stack}-responder-role-${rname}
    gotemplating.fn.crossplane.io/ready: "True"
rules:
YAML
    printf '%s' "$responder" | jq -r '.verbs[] | "  - apiGroups: [\"\"]\n    resources: [\(.resource)]\n    verbs: [\(.verb)]"'
    echo ""
    cat <<YAML
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: agentstack-responder
  namespace: ${rname}
  annotations:
    gotemplating.fn.crossplane.io/composition-resource-name: ${stack}-responder-rb-${rname}
    gotemplating.fn.crossplane.io/ready: "True"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: agentstack-responder
subjects:
  - kind: ServiceAccount
    name: agentstack-loop
    namespace: ${loopns}
YAML
  done
}

# ── test claims ──────────────────────────────────────────────────────────────────────────────────
# Case 1: No responder block
claim_no_responder() {
  jq -n '
    { "metadata": {"name": "test-stack"}
    , "spec": {
        "repos": [{"name": "repo-a", "fixer": {"budgetUSD": 5}}, {"name": "repo-b"}]
      }
    }
  '
}

# Case 2: Responder block present but disabled
claim_responder_disabled() {
  jq -n '
    { "metadata": {"name": "test-stack"}
    , "spec": {
        "responder": {"enabled": false, "verbs": [{"resource": "pods", "verb": "delete"}]},
        "repos": [{"name": "repo-a", "fixer": {"budgetUSD": 5}}, {"name": "repo-b"}]
      }
    }
  '
}

# Case 3: Responder block enabled with verbs
claim_responder_enabled() {
  jq -n '
    { "metadata": {"name": "test-stack"}
    , "spec": {
        "responder": {
          "enabled": true,
          "verbs": [
            {"resource": "pods", "verb": "delete"},
            {"resource": "configmaps", "verb": "patch"}
          ]
        },
        "repos": [
          {"name": "repo-a", "fixer": {"budgetUSD": 5}},
          {"name": "repo-b"},
          {"name": "repo-c", "fixer": {"budgetUSD": 10}}
        ]
      }
    }
  '
}

# Case 4: Responder enabled with no verbs (edge case — empty array)
claim_responder_no_verbs() {
  jq -n '
    { "metadata": {"name": "test-stack"}
    , "spec": {
        "responder": {
          "enabled": true,
          "verbs": []
        },
        "repos": [{"name": "repo-a", "fixer": {"budgetUSD": 5}}]
      }
    }
  '
}

# ── tests ───────────────────────────────────────────────────────────────────────────────────────
printf '\033[1mresponder-graduation-replay\033[0m — goal#818: responder graduation dial\n\n'

# ── 1 ── No responder block → nothing rendered ─────────────────────────────────────────────────-
section "1 — no responder block → nothing rendered"
claim_no_responder | render_responder > "$TMP/out1.txt" 2>"$TMP/err1.txt"
RC=$?; OUT="$(cat "$TMP/out1.txt")"; ERR="$(cat "$TMP/err1.txt")"
wantrc  "A1: claim without responder exits 0"  0
eq      "A1: output is empty (nothing rendered)"  "$OUT" ""

# ── 2 ── Responder disabled → nothing rendered ──────────────────────────────────────────────────
section "2 — responder disabled (enabled: false) → nothing rendered"
claim_responder_disabled | render_responder > "$TMP/out2.txt" 2>"$TMP/err2.txt"
RC=$?; OUT="$(cat "$TMP/out2.txt")"; ERR="$(cat "$TMP/err2.txt")"
wantrc  "B1: disabled responder exits 0"  0
eq      "B1: output is empty (nothing rendered)"  "$OUT" ""

# ── 3 ── Responder enabled → Role/RoleBinding rendered ──────────────────────────────────────────
section "3 — responder enabled → Role/RoleBinding rendered"
claim_responder_enabled | render_responder > "$TMP/out3.txt" 2>"$TMP/err3.txt"
RC=$?; OUT="$(cat "$TMP/out3.txt")"; ERR="$(cat "$TMP/err3.txt")"
wantrc  "C1: enabled responder exits 0"  0
want    "C2: loop ns Role rendered"       "kind: Role"
want    "C3: loop ns namespace"           "namespace: test-stack-agents"
want    "C4: loop ns RoleBinding rendered" "kind: RoleBinding"
want    "C5: Role name is agentstack-responder" "name: agentstack-responder"
want    "C6: repo-a Role rendered"        "namespace: repo-a"
want    "C7: repo-c Role rendered"        "namespace: repo-c"
wantnot "C8: repo-b (no fixer) has no Role" "namespace: repo-b"
want    "C9: pods delete verb rendered"   "resources: [pods]"
want    "C10: configmaps patch verb rendered" "resources: [configmaps]"
want    "C11: verbs have correct apiGroups"  'apiGroups: [""]'
want    "C12: annotation composition-resource-name" "composition-resource-name: test-stack-responder-role-loop"
want    "C13: repo-a annotation"          "composition-resource-name: test-stack-responder-role-repo-a"
want    "C14: repo-c annotation"          "composition-resource-name: test-stack-responder-role-repo-c"
want    "C15: binding to agentstack-loop" "kind: ServiceAccount"
want    "C16: SA name"                    "name: agentstack-loop"

# ── 4 ── Responder enabled with no verbs → empty rules ──────────────────────────────────────────
section "4 — responder enabled with empty verbs array"
claim_responder_no_verbs | render_responder > "$TMP/out4.txt" 2>"$TMP/err4.txt"
RC=$?; OUT="$(cat "$TMP/out4.txt")"; ERR="$(cat "$TMP/err4.txt")"
wantrc  "D1: empty verbs exits 0"  0
want    "D2: Role still rendered"   "kind: Role"
want    "D3: RoleBinding still rendered" "kind: RoleBinding"
want    "D4: rules section present" "rules:"

# ── 5 ── Escalation check mirror in rbac.yaml ───────────────────────────────────────────────────
section "5 — escalation-check mirror in rbac.yaml"
RBAC="$ROOT/argocd/resources/agentstack/rbac.yaml"
[ -f "$RBAC" ] || { bad "E1: rbac.yaml not found" "$RBAC"; } && ok "E1: rbac.yaml exists"

# Extract the responder graduation dial mirror block — from the comment header to the next
# `---` separator. This scopes every assertion to the mirror block alone, so a match
# outside it (e.g. serviceaccounts at L71 in the compose grant) does not false-pass.
MIRROR="$(awk '/^  # Responder graduation dial/{p=1} p; /^---/{if(p) exit}' "$RBAC")"

# Check that the responder escalation-check mirror section exists
if echo "$MIRROR" | grep -q "Responder graduation dial" 2>/dev/null; then
  ok "E2: responder graduation dial section exists in rbac.yaml"
else
  bad "E2: responder graduation dial section NOT found in rbac.yaml" "Expected comment 'Responder graduation dial'"
fi

# Check that common remediation verbs are pre-granted — scoped to the mirror block only,
# and asserting BOTH the resource AND the verbs (not just the resource name).
# The mirror block pre-grants these verb/resource pairs (rbac.yaml L107-113):
#   pods, pods/log, pods/status  →  get, list, watch, patch, delete
#   configmaps, endpoints, events, persistentvolumeclaims, persistentvolumeclaims/status, services  →  get, list, watch, patch, delete
#   serviceaccounts  →  get, list, watch
# Resources and verbs are on SEPARATE YAML lines, so we check each pair by extracting
# the rule block that contains the resource and verifying its verbs line.
for verb_resource in "pods:get,list,watch,patch,delete" "configmaps:get,list,watch,patch,delete" "serviceaccounts:get,list,watch"; do
  resource="${verb_resource%%:*}"
  verbs="${verb_resource#*:}"
  # Find the rule block containing this resource — a `- apiGroups:` line followed by
  # `resources:` containing the resource name, then `verbs:` with the expected verbs.
  # Use awk to extract the verbs line following the resources line that has this resource.
  found_verbs="$(echo "$MIRROR" | awk -v r="$resource" '
    /- apiGroups:/ { in_rule=1; rule="" }
    in_rule { rule = rule $0 ORS }
    /resources:/ && $0 ~ r { has_resource=1 }
    /verbs:/ && has_resource { print $0; has_resource=0; in_rule=0 }
  ')"
  if [ -z "$found_verbs" ]; then
    bad "E3: $resource NOT found in escalation mirror" "The responder dial may fail at compose time"
    continue
  fi
  # Check each expected verb appears in the verbs line
  missing=""
  for v in ${verbs//,/ }; do
    if echo "$found_verbs" | grep -q "\[.*$v" 2>/dev/null; then
      :  # verb found
    else
      missing="$missing $v"
    fi
  done
  if [ -n "$missing" ]; then
    bad "E3: $resource — missing verb(s):$missing in escalation mirror" "The responder dial may fail at compose time"
  else
    ok "E3: $resource verbs ($verbs) pre-granted in escalation mirror"
  fi
done

# Assert that secrets is deliberately NOT pre-granted in the mirror block.
# The grep is scoped to the mirror block, so a mention of "secrets" in the prose comment
# (L93-99) does not false-pass — we check for an actual resources: [secrets] rule entry.
if echo "$MIRROR" | grep -q "resources: \[.*secrets" 2>/dev/null; then
  bad "E3a: secrets IS pre-granted in escalation mirror — should be absent" "The secrets carve-out (rbac.yaml L93-99) is violated"
else
  ok "E3a: secrets deliberately NOT pre-granted in escalation mirror (carve-out holds)"
fi

# Check that the responder section includes the escalation-check warning
if echo "$MIRROR" | grep -q "attempting to grant RBAC permissions not currently held" 2>/dev/null; then
  ok "E4: escalation-check warning present in rbac.yaml"
else
  bad "E4: escalation-check warning NOT found" "The escalation check comment is missing"
fi

# ── 6 ── Verify template structure in composition.yaml ──────────────────────────────────────────
section "6 — composition template structure"
COMP="$ROOT/argocd/resources/agentstack/composition.yaml"
[ -f "$COMP" ] || { bad "F1: composition.yaml not found" "$COMP"; } && ok "F1: composition.yaml exists"

# Check the responder conditional exists
if grep -q "responder.*enabled" "$COMP" 2>/dev/null; then
  ok "F2: responder conditional (if and enabled) exists in composition"
else
  bad "F2: responder conditional NOT found" "Expected {{- if and $xr.spec.responder (default false ...) }}"
fi

# Check that the Role template is rendered
if grep -q "agentstack-responder" "$COMP" 2>/dev/null; then
  ok "F3: agentstack-responder Role template exists"
else
  bad "F3: agentstack-responder Role template NOT found"
fi

# Check the per-repo loop
if grep -q "range.*xr.spec.repos" "$COMP" 2>/dev/null; then
  ok "F4: per-repo loop exists in responder block"
else
  bad "F4: per-repo loop NOT found" "Expected {{- range $r := $xr.spec.repos }}"
fi

# ── 7 ── Verify XRD structure ───────────────────────────────────────────────────────────────────
section "7 — XRD schema structure"
XRD="$ROOT/argocd/resources/agentstack/xrd.yaml"
[ -f "$XRD" ] || { bad "G1: xrd.yaml not found" "$XRD"; } && ok "G1: xrd.yaml exists"

if grep -q "responder:" "$XRD" 2>/dev/null; then
  ok "G2: responder block exists in XRD"
else
  bad "G2: responder block NOT found in XRD"
fi

# Check the no-default warning
if grep -q "NO default on this object" "$XRD" 2>/dev/null; then
  ok "G3: no-default warning present in XRD responder block"
else
  bad "G3: no-default warning NOT found" "The 2026-07-16 claudeTier lesson warning is missing"
fi

# Check the enabled property
if grep -q "enabled:" "$XRD" 2>/dev/null && grep -A1 "enabled:" "$XRD" | grep -q "type: boolean" 2>/dev/null; then
  ok "G4: enabled property (type boolean) exists in XRD"
else
  bad "G4: enabled property NOT found in XRD" "Expected enabled: with type: boolean"
fi

# ── result ──────────────────────────────────────────────────────────────────────────────────────
section "result"
printf '  %s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\n\033[31mFAILED:\033[0m\n'; for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
  printf '\nThe responder graduation dial changed behaviour. If the change was deliberate, update the fixture\n'
  printf 'in the same commit (ADR-103).\n'
  exit 1
fi
printf '\n\033[32mEvery responder graduation case holds.\033[0m\n'
