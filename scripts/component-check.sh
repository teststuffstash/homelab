#!/usr/bin/env bash
# component-check — REPORT-ONLY workload-standards check over everything the ArgoCD layer deploys,
# chart-rendered manifests INCLUDED (docs/agents/iac-lane.md §Assurance layers L0b: this is the
# "render pass" the sentinel names as its v2, standing alone as a CI-side report first).
#
#   devbox run component-check                       # --report over this checkout (exit 0 always)
#   devbox run component-check -- --tree <dir>       # another checkout (a PR clone), same report
#   devbox run component-check -- --enforce          # exit 1 on any finding (wired to nothing yet)
#   devbox run component-check -- --only kargo,argo-rollouts   # a comma list of Applications (debugging)
#   devbox run component-check -- --out <dir>        # keep the rendered manifests
#
# WHAT IT DOES. (1) RENDER: every `argocd/platform/*.yaml` Application — `spec.source` or
# multi-source `spec.sources[]` — has each source turned into plain manifests: a chart source is
# `helm template`d at its pinned targetRevision with the Application's own valuesObject / values /
# `$values/` valueFiles / parameters (OCI registries, classic repos and vendored `argocd/charts/*`
# alike); a homelab git `path:` source is `kubectl kustomize`d when it carries a kustomization.yaml,
# helm-templated when it is a chart dir, else concatenated the way ArgoCD's directory source applies
# it (non-recursive unless `directory.recurse`). (2) EVALUATE: `kyverno apply policy/component/
# <rendered kyverno-policies chart> --audit-warn` per Application — Kyverno is THE rule engine
# (operator ruling, iac-lane.md L0b; no kube-linter/Polaris/kube-score here). (3) REPORT: one
# markdown table per policy on stdout, plus the SERVICES.md coverage check and the list of what the
# render could NOT see.
#
# WHAT IT DOES NOT SEE (printed every run — a check that is silent about its blind spots reports
# green on the FU-125 class): namespaces ArgoCD creates via `CreateNamespace=true` (no manifest);
# `path:` sources in a FOREIGN git repo (gateway-api CRDs — not cloned); ApplicationSets (the
# generator is not expanded); pods templated INSIDE Crossplane Compositions / XRs (strings, not
# documents — the xr-render gate's job); whatever a chart renders only under a `.Capabilities` the
# local template lacks (`--api-versions` is not emulated).
#
# TRUST MODEL. Unlike the sentinel (raw-YAML pass, hostile tree never executed), this EXECUTES the
# PR's chosen charts' templates (helm template = Go templates + `lookup`-less rendering, no hooks
# run). That is fine for a PR-time CI report on this repo (the PR's own CI already runs its code)
# and exactly why the sentinel keeps the render pass as a separate step (v2) rather than inlining it.
# Policies come from THIS checkout's policy/component/, never from --tree.
#
# RULES — three sources, every one Audit (operator rulings 2026-10-25):
#   1. POD SECURITY `restricted` comes from the `kyverno-policies` HELM CHART (kyverno.github.io), rendered
#      at check time at KYVERNO_POLICIES_CHART_VERSION below with `podSecurityStandard=restricted`,
#      `policyType=ValidatingPolicy`, `validationFailureAction=Audit` (the chart's other knobs —
#      `includeOtherPolicies: []`, `background: true` — stay at their defaults): 17 CEL policies, one
#      row per missed control. Never a hand-written PSS policy here. The chart pull is WAN, like the
#      chart pins themselves (diff-ci PUSH_HEAVY).
#   2. The LIBRARY RULES in policy/component/ are VENDORED from kyverno/policies `release-1.19` by
#      scripts/vendor-kyverno-policies.sh (its MANIFEST is the list, its header says why that branch
#      and how each CEL-vs-legacy choice was made from the upstream migration audit; the pin is
#      KYVERNO_POLICIES_REF/SHA there, Renovate-bumped, re-fetched on the bump). restrict-image-
#      registries carries the one LOCAL PATCH (our registry allowlist). Every run re-checks the
#      vendored copy against upstream (`--check`) — drift is a tool error in the report.
#   3. LOCAL: require-namespace-pss-labels, disallow-ingress (headers say why no library rule fits).
# Homelab-specific facts (IP plan, exceptions baseline, storage ledger) are the SENTINEL's business
# (policy/iac/), not this checker's.
#
# SERVICES.md COVERAGE (rule e). Every Application here is either a row in SERVICES.md (the file
# path `argocd/platform/<name>.yaml` or the name as a word in a table row) or matches one of the
# SERVICES_EXEMPT classes — each class names WHY that shape is not a catalog entry. Everything else
# is a finding row. The classes are deliberately shape-based, not a per-name list (enumerated guard
# lists go stale, #2588); a NEW shape earns a class with a reason, a one-off earns a catalog row.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# The chart pin — Renovate's helm customManager reads these two lines (class 18, docs/dependency-classes.yaml):
# renovate: datasource=helm depName=kyverno-policies registryUrl=https://kyverno.github.io/kyverno
KYVERNO_POLICIES_CHART_VERSION=3.9.2
KYVERNO_POLICIES_CHART_REPO=https://kyverno.github.io/kyverno
VENDOR="$HERE/vendor-kyverno-policies.sh"
# the library pin, for the report line only — the vendor script owns it
KYVERNO_POLICIES_REF="$(sed -n 's/^KYVERNO_POLICIES_REF=//p' "$VENDOR")"
KYVERNO_POLICIES_SHA="$(sed -n 's/^KYVERNO_POLICIES_SHA=//p' "$VENDOR")"
POLICY_DIR="${POLICY_DIR:-$ROOT/policy/component}"
K8S_VERSION="${K8S_VERSION:-1.36.1}"   # same default as scripts/manifest-lint.sh (the cluster's line)
HOMELAB_REPO_RE='^https://github\.com/teststuffstash/homelab(\.git)?/?$'

# class-regex::reason — an Application whose NAME matches a class is not expected in SERVICES.md.
SERVICES_EXEMPT=(
  '-alerts$::PrometheusRule bundles for a service that has its own row'
  '(-metrics|-exporter|^blackbox|^smartctl-exporter|^job-health|^kubelet-resource-metrics)$::metrics feeders — scrape targets behind the Prometheus row, not consumable services'
  '(-namespaces|-project|-refgrant)$::tenancy scaffolding per stack (Namespace/AppProject/ReferenceGrant) — the stack is the catalog entry, not its plumbing'
  '(-operator|-crds|-controller|^plugin-barman-cloud|^crossplane-providers|^gateway-api-crds)$::operators/CRDs that serve a catalog row (CNPG, ESO, cert-manager, Crossplane, Gateway API)'
  '(-backup|-probe|-rotation|-disruption|-prepull|-fstrim|-lease|-lease-reader|^chart-revert|^version-sets|^pg-backup|^tofu-state|^opnsense-config-backup|^talos-substrate)$::batch/maintenance jobs and platform plumbing — consumed by nobody, operated by the belt'
  '^(agent-coordinator|agent-fixer|agentstack|publicroute|platform-extras|github-runner-secrets|cf-api-proxy|arc-runners-large|arc-controller)$::agent-platform / CI internals documented in docs/agents/, not platform services (arc-runners IS a row; the large pool + controller ride it)'
)

MODE=report; TREE="$ROOT"; ONLY=""; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --report) MODE=report;;
    --enforce) MODE=enforce;;
    --tree) TREE="$(cd "$2" && pwd)"; shift;;
    --only) ONLY="$2"; shift;;
    --out) OUT="$2"; shift;;
    -h|--help) sed -n '2,12p' "$0"; exit 0;;
    *) echo "component-check: unknown arg $1" >&2; exit 2;;
  esac
  shift
done
[ -d "$TREE/argocd/platform" ] || { echo "component-check: no argocd/platform under $TREE" >&2; exit 2; }
[ -d "$POLICY_DIR" ] || { echo "component-check: no policy dir $POLICY_DIR" >&2; exit 2; }
for t in helm kubectl kyverno yq jq; do command -v "$t" >/dev/null || { echo "component-check: $t not on PATH — run via devbox" >&2; exit 2; }; done

WORK="$(mktemp -d)"
if [ -n "$OUT" ]; then mkdir -p "$OUT"; RENDER="$(cd "$OUT" && pwd)"; else RENDER="$WORK/render"; mkdir -p "$RENDER"; fi
trap 'rm -rf "$WORK"' EXIT
FINDINGS="$WORK/findings.tsv"; : > "$FINDINGS"        # app \t policy \t resource \t message
NOTSEEN="$WORK/notseen.txt"; : > "$NOTSEEN"            # one line per blind spot hit
RENDERLOG="$WORK/render.tsv"; : > "$RENDERLOG"         # app \t source \t docs \t status
TOOLERR="$WORK/toolerr.txt"; : > "$TOOLERR"
APPNAMES="$WORK/apps.txt"; : > "$APPNAMES"
nfind=0; nerr=0

log() { printf '%s\n' "$*" >&2; }
count_docs() { grep -c '^kind:' "$1" 2>/dev/null || true; }

# ── 0: the policy set — render the PSS chart, verify the vendored library copy ─────────────
# Pod Security `restricted` as the kyverno-policies chart renders it (rule source 1 in the header).
# `kyvernoVersion` is "autodetect" by default (reads the cluster's Deployment) — we pass the CLI's own
# version so the chart picks the templates for the engine that evaluates them.
PSS_DIR="$WORK/pss"; mkdir -p "$PSS_DIR"
kyv_ver="$(kyverno version 2>/dev/null | sed -n 's/^Version: v\{0,1\}//p')"; [ -n "$kyv_ver" ] || kyv_ver=1.19.1
if ! helm template kyverno-policies kyverno-policies --repo "$KYVERNO_POLICIES_CHART_REPO" --version "$KYVERNO_POLICIES_CHART_VERSION" \
    --set podSecurityStandard=restricted --set policyType=ValidatingPolicy --set validationFailureAction=Audit \
    --set "kyvernoVersion=$kyv_ver" --kube-version "$K8S_VERSION" > "$PSS_DIR/kyverno-policies.yaml" 2> "$WORK/pss.err"; then
  echo "component-check: FAIL — kyverno-policies chart $KYVERNO_POLICIES_CHART_VERSION did not render (the checker, not the tree, is broken):" >&2
  tail -5 "$WORK/pss.err" >&2; exit 2
fi
npss="$(grep -c '^kind: ValidatingPolicy' "$PSS_DIR/kyverno-policies.yaml" || true)"
[ "$npss" -gt 0 ] || { echo "component-check: FAIL — kyverno-policies chart rendered 0 policies" >&2; exit 2; }
# the vendored copy must be what the pin says it is — drift is a tool error, never silently evaluated
if ! vendor_out="$(bash "$VENDOR" --check 2>&1)"; then
  { echo "== policy/component/ vendored copy out of sync with kyverno/policies $KYVERNO_POLICIES_REF @ ${KYVERNO_POLICIES_SHA:0:12} (run scripts/vendor-kyverno-policies.sh):"; printf '%s\n' "$vendor_out" | sed -n '1,12p'; } >> "$TOOLERR"
  nerr=$((nerr+1))
fi

# render_chart <app> <idx> <source-json> <dest-ns> <outfile>
render_chart() {
  local app="$1" idx="$2" src="$3" ns="$4" out="$5" repo chart ver url name args=() vf v p pname pval
  repo="$(jq -r '.repoURL' <<<"$src")"; chart="$(jq -r '.chart' <<<"$src")"; ver="$(jq -r '.targetRevision // ""' <<<"$src")"
  name="$(jq -r '.helm.releaseName // ""' <<<"$src")"; [ -n "$name" ] || name="$app"
  [ -n "$ver" ] || { printf '%s\t%s\t0\tNO targetRevision\n' "$app" "chart:$chart" >> "$RENDERLOG"; return 1; }
  case "$repo" in
    oci://*) args=("$name" "${repo%/}/$chart" --version "$ver");;
    http://*|https://*) args=("$name" "$chart" --repo "$repo" --version "$ver");;
    *) args=("$name" "oci://${repo%/}/$chart" --version "$ver");;   # bare registry path (ghcr.io/…, code.forgejo.org/…)
  esac
  args+=(-n "$ns" --kube-version "$K8S_VERSION")
  [ "$(jq -r '.helm.skipCrds // false' <<<"$src")" = "true" ] || args+=(--include-crds)
  if [ "$(jq -r '.helm.valuesObject // "" | type' <<<"$src")" = "object" ]; then
    jq '.helm.valuesObject' <<<"$src" | yq -P '.' > "$WORK/$app-$idx-vo.yaml"; args+=(-f "$WORK/$app-$idx-vo.yaml")
  fi
  v="$(jq -r '.helm.values // ""' <<<"$src")"
  if [ -n "$v" ]; then printf '%s\n' "$v" > "$WORK/$app-$idx-vs.yaml"; args+=(-f "$WORK/$app-$idx-vs.yaml"); fi
  while IFS= read -r vf; do
    [ -n "$vf" ] || continue
    case "$vf" in
      \$values/*) p="$TREE/${vf#\$values/}";;
      /*) p="$vf";;
      *) echo "$app: chart valueFile '$vf' is chart-relative — not resolvable outside ArgoCD, skipped" >> "$NOTSEEN"; continue;;
    esac
    if [ -f "$p" ]; then args+=(-f "$p"); else echo "$app: valueFile $vf not found in tree — skipped" >> "$NOTSEEN"; fi
  done < <(jq -r '.helm.valueFiles // [] | .[]' <<<"$src")
  while IFS=$'\t' read -r pname pval pfs; do
    [ -n "$pname" ] || continue
    if [ "$pfs" = "true" ]; then args+=(--set-string "$pname=$pval"); else args+=(--set "$pname=$pval"); fi
  done < <(jq -r '.helm.parameters // [] | .[] | [.name, (.value|tostring), ((.forceString // false)|tostring)] | @tsv' <<<"$src")
  if helm template "${args[@]}" > "$out" 2> "$WORK/$app-$idx.err"; then
    printf '%s\t%s\t%s\tok\n' "$app" "chart:$chart@$ver" "$(count_docs "$out")" >> "$RENDERLOG"
  else
    printf '%s\t%s\t0\tRENDER FAILED\n' "$app" "chart:$chart@$ver" >> "$RENDERLOG"
    { echo "== $app chart $chart@$ver: helm template failed"; tail -5 "$WORK/$app-$idx.err"; } >> "$TOOLERR"
    nerr=$((nerr+1)); return 1
  fi
}

# render_path <app> <idx> <source-json> <dest-ns> <outfile> — a git path source
render_path() {
  local app="$1" idx="$2" src="$3" ns="$4" out="$5" repo path dir recurse f docs
  repo="$(jq -r '.repoURL' <<<"$src")"; path="$(jq -r '.path' <<<"$src")"
  if ! grep -qE "$HOMELAB_REPO_RE" <<<"$repo"; then
    echo "$app: path source in a FOREIGN repo ($repo $path) — not cloned, not rendered" >> "$NOTSEEN"
    printf '%s\t%s\t0\tforeign repo, skipped\n' "$app" "path:$path" >> "$RENDERLOG"; return 1
  fi
  dir="$TREE/$path"
  [ -d "$dir" ] || { printf '%s\t%s\t0\tpath missing in tree\n' "$app" "path:$path" >> "$RENDERLOG"; echo "$app: $path not in tree" >> "$TOOLERR"; nerr=$((nerr+1)); return 1; }
  if [ -f "$dir/Chart.yaml" ]; then
    # a vendored chart dir (argocd/charts/*): helm template takes the directory directly
    local name; name="$(jq -r '.helm.releaseName // ""' <<<"$src")"; [ -n "$name" ] || name="$app"
    local args=("$name" "$dir" -n "$ns" --kube-version "$K8S_VERSION" --include-crds)
    if [ "$(jq -r '.helm.valuesObject // "" | type' <<<"$src")" = "object" ]; then
      jq '.helm.valuesObject' <<<"$src" | yq -P '.' > "$WORK/$app-$idx-vo.yaml"; args+=(-f "$WORK/$app-$idx-vo.yaml")
    fi
    local vf; while IFS= read -r vf; do
      [ -n "$vf" ] || continue; case "$vf" in \$values/*) vf="$TREE/${vf#\$values/}";; /*) ;; *) vf="$dir/$vf";; esac
      [ -f "$vf" ] && args+=(-f "$vf")
    done < <(jq -r '.helm.valueFiles // [] | .[]' <<<"$src")
    if helm template "${args[@]}" > "$out" 2> "$WORK/$app-$idx.err"; then
      printf '%s\t%s\t%s\tok (vendored chart)\n' "$app" "path:$path" "$(count_docs "$out")" >> "$RENDERLOG"
    else
      printf '%s\t%s\t0\tRENDER FAILED\n' "$app" "path:$path" >> "$RENDERLOG"
      { echo "== $app vendored chart $path: helm template failed"; tail -5 "$WORK/$app-$idx.err"; } >> "$TOOLERR"; nerr=$((nerr+1)); return 1
    fi
    return 0
  fi
  if [ -f "$dir/kustomization.yaml" ] || [ -f "$dir/kustomization.yml" ]; then
    if kubectl kustomize "$dir" > "$out" 2> "$WORK/$app-$idx.err"; then
      printf '%s\t%s\t%s\tok (kustomize)\n' "$app" "path:$path" "$(count_docs "$out")" >> "$RENDERLOG"
    else
      printf '%s\t%s\t0\tKUSTOMIZE FAILED\n' "$app" "path:$path" >> "$RENDERLOG"
      { echo "== $app $path: kubectl kustomize failed"; tail -5 "$WORK/$app-$idx.err"; } >> "$TOOLERR"; nerr=$((nerr+1)); return 1
    fi
    return 0
  fi
  # ArgoCD directory source: every *.yaml/*.yml, non-recursive unless directory.recurse. Comments
  # stripped and kustomize-config docs dropped for the same reasons the sentinel does it
  # (scripts/iac-sentinel.sh §collect: a stranded head comment becomes a kind-less document).
  recurse="$(jq -r '.directory.recurse // false' <<<"$src")"
  : > "$out"
  while IFS= read -r f; do
    docs="$(yq eval-all '(select(tag == "!!map" and .apiVersion != null and .kind != null and (.apiVersion | test("^kustomize\\.config\\.k8s\\.io/") | not))) | ... comments=""' "$f" 2>/dev/null || true)"
    [ -n "$docs" ] && [ "$docs" != "null" ] && printf -- '---\n%s\n' "$docs" >> "$out"
  done < <(if [ "$recurse" = "true" ]; then find "$dir" \( -name '*.yaml' -o -name '*.yml' \) -type f | sort; else find "$dir" -maxdepth 1 \( -name '*.yaml' -o -name '*.yml' \) -type f | sort; fi)
  printf '%s\t%s\t%s\tok (directory)\n' "$app" "path:$path" "$(count_docs "$out")" >> "$RENDERLOG"
}

# evaluate <app> <rendered-file>: kyverno apply, parse "policy P -> resource R failed…" + the
# message line that follows; a run with NO summary line is a tool error, not a finding (the
# sentinel's #1134 discrimination).
# cluster-scoped kinds that must NOT inherit the Application's destination namespace below
CLUSTER_KINDS='^(Namespace|ClusterRole|ClusterRoleBinding|CustomResourceDefinition|MutatingWebhookConfiguration|ValidatingWebhookConfiguration|ValidatingAdmissionPolicy|ValidatingAdmissionPolicyBinding|MutatingAdmissionPolicy|MutatingAdmissionPolicyBinding|PriorityClass|StorageClass|APIService|Node|PersistentVolume|IngressClass|GatewayClass|ClusterPolicy|ClusterIssuer|CiliumClusterwideNetworkPolicy|Provider|Function|Composition|CompositeResourceDefinition|AppProject)$'
evaluate() {
  local app="$1" res="$2" ns="$3" kout krc pol rsc msg line
  [ "$(count_docs "$res")" -gt 0 ] 2>/dev/null || return 0
  # helm emits comment-only documents (an empty CRD file keeps its `# Source:` header) and kyverno
  # refuses the whole file on one ("Object 'Kind' is missing") — same sanitizer as the directory
  # source: comments stripped, kind-less and kustomize-config docs dropped. A namespaced document
  # without metadata.namespace lands in the Application's destination namespace (what ArgoCD does),
  # so the finding names the real namespace rather than kyverno's `default`.
  yq eval-all '(select(tag == "!!map" and .apiVersion != null and .kind != null and (.apiVersion | test("^kustomize\\.config\\.k8s\\.io/") | not)))
    | (select((.kind | test(strenv(CLUSTER_KINDS)) | not) and .metadata.namespace == null) | .metadata.namespace) = strenv(DEST_NS)
    | ... comments=""' "$res" > "$WORK/$app-clean.yaml" 2>/dev/null || true
  res="$WORK/$app-clean.yaml"
  kout="$(kyverno apply "$POLICY_DIR" "$PSS_DIR/kyverno-policies.yaml" --audit-warn --resource "$res" 2>&1)"; krc=$?
  if ! grep -qE '^pass: [0-9]+, fail: [0-9]+' <<<"$kout"; then
    { echo "== $app: kyverno rc=$krc with no summary (tool error, not a finding)"; printf '%s\n' "$kout" | grep -v '^Warning:' | tail -8; } >> "$TOOLERR"
    nerr=$((nerr+1)); return 0
  fi
  pol=""; rsc=""
  while IFS= read -r line; do
    case "$line" in
      "policy "*" -> resource "*" failed"*)
        pol="${line#policy }"; pol="${pol%% -> *}"
        rsc="${line#* -> resource }"; rsc="${rsc%% failed*}";;
      [0-9]*" - "*)
        [ -n "$pol" ] || continue
        msg="${line#* - }"; msg="${msg#* Validation rule \'*\' failed. }"; msg="${msg## }"
        printf '%s\t%s\t%s\t%s\n' "$app" "$pol" "$rsc" "${msg:0:400}" >> "$FINDINGS"
        nfind=$((nfind+1)); pol="";;
    esac
  done <<<"$kout"
}

# ── 1+2: render + evaluate every Application ──────────────────────────────────────────────
for f in "$TREE"/argocd/platform/*.yaml; do
  while IFS= read -r appjson; do
    [ -n "$appjson" ] || continue
    kind="$(jq -r '.kind // ""' <<<"$appjson")"; app="$(jq -r '.metadata.name // ""' <<<"$appjson")"
    [ -n "$app" ] || continue
    if [ "$kind" = "ApplicationSet" ]; then echo "$app: ApplicationSet — generator not expanded, nothing rendered" >> "$NOTSEEN"; continue; fi
    [ "$kind" = "Application" ] || continue
    [ -z "$ONLY" ] || [[ ",$ONLY," == *",$app,"* ]] || continue
    echo "$app" >> "$APPNAMES"
    ns="$(jq -r '.spec.destination.namespace // "default"' <<<"$appjson")"
    if jq -e '.spec.syncPolicy.syncOptions // [] | index("CreateNamespace=true")' <<<"$appjson" >/dev/null; then
      echo "$app: CreateNamespace=true — namespace '$ns' is created by ArgoCD with NO manifest (PSA labels unverifiable here)" >> "$NOTSEEN"
    fi
    combined="$RENDER/$app.yaml"; : > "$combined"; idx=0
    while IFS= read -r src; do
      [ -n "$src" ] || continue
      idx=$((idx+1)); part="$WORK/$app-$idx.yaml"
      if [ "$(jq -r '.chart // ""' <<<"$src")" != "" ]; then
        render_chart "$app" "$idx" "$src" "$ns" "$part" && cat "$part" >> "$combined"
      elif [ "$(jq -r '.path // ""' <<<"$src")" != "" ]; then
        render_path "$app" "$idx" "$src" "$ns" "$part" && { printf -- '\n---\n'; cat "$part"; } >> "$combined"
      else
        : # a `ref:`-only values source — nothing to render
      fi
    done < <(jq -c '([ .spec.source // empty ] + (.spec.sources // [])) | .[]' <<<"$appjson")
    CLUSTER_KINDS="$CLUSTER_KINDS" DEST_NS="$ns" evaluate "$app" "$combined" "$ns"
  done < <(yq -o=json -I=0 'select(.kind == "Application" or .kind == "ApplicationSet")' "$f" 2>/dev/null)
done

# ── rule (e): every Application has a SERVICES.md row or an exempt shape ─────────────────
SVC="$TREE/SERVICES.md"; svc_missing="$WORK/svc-missing.tsv"; : > "$svc_missing"; svc_rows=0; svc_exempt=0
if [ -f "$SVC" ]; then
  svc_table="$(grep -E '^\|' "$SVC")"
  while IFS= read -r app; do
    [ -n "$app" ] || continue
    if grep -qF -- "argocd/platform/$app.yaml" <<<"$svc_table" || grep -qiwE -- "$app" <<<"$svc_table"; then svc_rows=$((svc_rows+1)); continue; fi
    ex=false
    for cls in "${SERVICES_EXEMPT[@]}"; do
      if grep -qE -- "${cls%%::*}" <<<"$app"; then ex=true; break; fi
    done
    if $ex; then svc_exempt=$((svc_exempt+1)); else printf '%s\n' "$app" >> "$svc_missing"; fi
  done < "$APPNAMES"
else
  echo "no SERVICES.md in tree — rule (e) not evaluated" >> "$TOOLERR"; nerr=$((nerr+1))
fi
nsvc="$(grep -c . "$svc_missing" || true)"

# ── 3: report ─────────────────────────────────────────────────────────────────────────────
napps="$(grep -c . "$APPNAMES" || true)"
ndocs="$(awk -F'\t' '{s+=$3} END {print s+0}' "$RENDERLOG")"
echo "## component-check — $MODE mode, tree \`$TREE\`"
echo
echo "Applications: $napps · rendered documents: $ndocs · policy findings: $nfind · SERVICES.md gaps: $nsvc · tool errors: $nerr · policies: \`policy/component/\` (kyverno/policies $KYVERNO_POLICIES_REF @ ${KYVERNO_POLICIES_SHA:0:12}) + $npss PSS \`restricted\` policies (kyverno-policies chart $KYVERNO_POLICIES_CHART_VERSION) · kube-version $K8S_VERSION"
echo
echo "### Render per Application source"
echo
echo "| Application | Source | Docs | Status |"
echo "|---|---|---:|---|"
sort "$RENDERLOG" | awk -F'\t' '{printf "| %s | `%s` | %s | %s |\n", $1, $2, $3, $4}'
echo
echo "### Findings per policy"
echo
if [ "$nfind" -eq 0 ]; then echo "_none_"; else
  while IFS= read -r pol; do
    [ -n "$pol" ] || continue
    n="$(awk -F'\t' -v p="$pol" '$2==p' "$FINDINGS" | grep -c . || true)"
    echo "#### \`$pol\` — $n finding(s)"
    echo
    echo "| Application | Resource | Message |"
    echo "|---|---|---|"
    awk -F'\t' -v p="$pol" '$2==p {gsub(/\|/, "\\|", $4); printf "| %s | `%s` | %s |\n", $1, $3, substr($4, 1, 160)}' "$FINDINGS" | sort
    echo
  done < <(cut -f2 "$FINDINGS" | sort | uniq -c | sort -rn | awk '{print $2}')
fi
echo "### SERVICES.md coverage (rule e)"
echo
echo "$svc_rows Application(s) have a catalog row, $svc_exempt match an exempt class (see SERVICES_EXEMPT in the script header), $nsvc have neither:"
echo
if [ "$nsvc" -gt 0 ]; then
  echo "| Application | Needs |"; echo "|---|---|"
  awk '{printf "| %s | a SERVICES.md row, or a SERVICES_EXEMPT class with a reason |\n", $1}' "$svc_missing"
  echo
fi
echo "### Not seen by this check"
echo
if [ -s "$NOTSEEN" ]; then sort -u "$NOTSEEN" | sed 's/^/- /'; else echo "- (nothing recorded)"; fi
echo "- pods templated inside Crossplane Compositions/XRs (strings, not documents — \`xr-render\` territory); chart branches behind \`.Capabilities.APIVersions\` the local template lacks"
echo
if [ -s "$TOOLERR" ]; then echo "### Tool errors (probe failures, not findings)"; echo; echo '```'; cat "$TOOLERR"; echo '```'; echo; fi

# A run that rendered NOTHING is a broken checker, never a clean one (manifest-lint's honesty rule).
if [ "$ndocs" -eq 0 ]; then echo "component-check: FAIL — 0 documents rendered; the checker, not the tree, is broken" >&2; exit 2; fi
if [ "$MODE" = "enforce" ] && { [ "$nfind" -gt 0 ] || [ "$nsvc" -gt 0 ] || [ "$nerr" -gt 0 ]; }; then
  echo "component-check: ENFORCE — $nfind finding(s), $nsvc catalog gap(s), $nerr tool error(s)" >&2; exit 1
fi
exit 0
