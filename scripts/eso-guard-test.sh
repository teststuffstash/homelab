#!/usr/bin/env bash
# Decision table for the ESO tenancy guards (argocd/resources/extras/eso-guard.yaml, ADR-168). No
# cluster: each row of scripts/fixtures/eso-guard/cases.tsv patches one base object with a yq
# expression and runs it through `kyverno apply` of the live policy file, then asserts the verdict
# and, for a refusal, the clause from kyverno's message.
#
# Each base kind runs against ITS policy only: kyverno CLI evaluates every ValidatingAdmissionPolicy
# in the file against every resource, whatever its matchConstraints say, so a combined run would
# refuse ExternalSecrets by the ClusterSecretStore policy.
#
#   devbox run -- bash scripts/eso-guard-test.sh
set -uo pipefail

ROOT="${DEVBOX_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
POLICY="$ROOT/argocd/resources/extras/eso-guard.yaml"
FIX="$ROOT/scripts/fixtures/eso-guard"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; n=0
ok()  { n=$((n + 1)); echo "  ok $*"; }
bad() { n=$((n + 1)); echo "  FAIL $*"; fails=$((fails + 1)); }

yq 'select(.metadata.name == "eso-infisical-guard")' "$POLICY" > "$TMP/infisical.yaml"
yq 'select(.metadata.name == "eso-clusterstore-scoped")' "$POLICY" > "$TMP/scoped.yaml"
for p in infisical scoped; do
  [ "$(grep -c '^kind: ValidatingAdmissionPolicy$' "$TMP/$p.yaml")" -eq 1 ] || { echo "eso-guard-test: policy $p not found in $POLICY"; exit 1; }
done

verdict() {  # verdict <policy-file> <resource-file> → $GOT = pass|fail|skip|error, kyverno output in $KOUT
  KOUT="$(kyverno apply "$1" --crd-paths "$FIX/crds.yaml" --cluster-wide-resources --resource "$2" 2>&1)"
  local sum p f e
  sum="$(grep -oE 'pass: [0-9]+, fail: [0-9]+, warn: [0-9]+, error: [0-9]+' <<<"$KOUT" | head -1)"
  [ -n "$sum" ] || { GOT=error; return; }
  p="$(sed -E 's/pass: ([0-9]+).*/\1/' <<<"$sum")"; f="$(sed -E 's/.*fail: ([0-9]+).*/\1/' <<<"$sum")"
  e="$(sed -E 's/.*error: ([0-9]+).*/\1/' <<<"$sum")"
  if [ "$e" -gt 0 ]; then GOT=error; elif [ "$f" -gt 0 ]; then GOT=fail; elif [ "$p" -gt 0 ]; then GOT=pass; else GOT=skip; fi
}

rows=0
while IFS=$'\t' read -r case want clause base patch; do
  case "$case" in ''|'#'*) continue ;; esac
  rows=$((rows + 1))
  src="$FIX/base-$base.yaml"
  [ -f "$src" ] || { bad "$case: no base $base"; continue; }
  yq "$patch" "$src" > "$TMP/case.yaml" 2>"$TMP/yq.err" || { bad "$case: yq patch failed: $(head -1 "$TMP/yq.err")"; continue; }
  if [ "$patch" != "." ] && cmp -s <(yq . "$src") "$TMP/case.yaml"; then bad "$case: patch changed nothing"; continue; fi
  pol="$TMP/infisical.yaml"; [ "$base" = css ] && pol="$TMP/scoped.yaml"
  verdict "$pol" "$TMP/case.yaml"
  if [ "$GOT" != "$want" ]; then
    bad "$case: want $want, got $GOT"; grep -E 'failed|Error|^[0-9]+ - ' <<<"$KOUT" | sed 's/^/      /'; continue
  fi
  if [ "$want" = fail ]; then
    tag="eso-infisical-guard ($clause)"; [ "$clause" = s ] && tag="eso-clusterstore-scoped:"
    grep -qF "$tag" <<<"$KOUT" || { bad "$case: refused, but not by $tag"; grep -E '^[0-9]+ - ' <<<"$KOUT" | sed 's/^/      /'; continue; }
  fi
  ok "$case → $want${clause#-}"
done < "$FIX/cases.tsv"
[ "$rows" -ge 25 ] && ok "decision table has $rows rows" || bad "decision table has only $rows rows"

echo "eso-guard-test: $((n - fails))/$n passed"
[ "$fails" -eq 0 ]
