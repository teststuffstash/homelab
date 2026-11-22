#!/bin/bash
# vendor-garage-chart — (re)build argocd/charts/garage from ONE pinned upstream tag of
# Deuxfleurs/garage (`script/helm/garage`), with the platform's local patches re-applied. The chart
# is vendored so an ArgoCD sync never depends on git.deuxfleurs.fr (argocd/charts/garage/VENDORED.md);
# this script is what makes the vendored copy a function of the pin instead of a hand copy.
#
#   devbox run -- bash scripts/vendor-garage-chart.sh            # rewrite argocd/charts/garage from the pin
#   devbox run -- bash scripts/vendor-garage-chart.sh --check    # exit 1 if a rebuild would change anything (network)
#   devbox run -- bash scripts/vendor-garage-chart.sh --verify   # render the committed chart with the platform's
#                                                                # values and assert every local patch is in the
#                                                                # output (offline; helm + yq — a `ci` leg of
#                                                                # argocd-validate-pins)
#
# TWO CALLERS, one script (the G12 shape — docs/renovate.md §Gotchas; scripts/vendor-kyverno-policies.sh
# is the sibling):
#   the seat   after editing a local patch below — run, `--verify`, review, commit
#   Renovate   the `gitea-tags` customManager bumps the two pin lines below, then this script runs as a
#              `postUpgradeTasks` command on that branch (.github/renovate-global.json), so a Garage bump
#              is BORN with the chart rebuilt. The Renovate container is the SLIM image: bash, curl,
#              git, tar, sed, awk, grep, coreutils — no helm, no yq, no devbox. The default mode and
#              `--check` stay inside that set; only `--verify` needs helm + yq, and it runs in `ci`.
#
# A patch whose anchor line is gone from the new upstream text FAILS the run (exit 2) — the branch is
# then born without the rebuilt chart and `--verify` reds it in `ci`. That is the signal to re-read the
# upstream template and move the anchor by hand; the script never guesses.
#
# PINS — read by Renovate (gitea-tags, depName deuxfleurs/garage) and by scripts/dependency-coverage.py
# (class 20, docs/dependency-classes.yaml). Keep TAG first, SHA next, no blank line between, bare
# 40-hex value. SHA is the commit the tag points at; the fetched archive must carry exactly that id.
GARAGE_CHART_TAG=v2.5.0
GARAGE_CHART_SHA=586726edb0170bb46f604e84fba09e5659610649
set -euo pipefail
cd "$(dirname "$0")/.."
DEST=argocd/charts/garage
APP=argocd/platform/garage.yaml
ARCHIVE="https://git.deuxfleurs.fr/Deuxfleurs/garage/archive/$GARAGE_CHART_TAG.tar.gz"
SERVE_LABEL='garage.teststuff.net/serve-s3: "true"'
die() { echo "vendor-garage-chart: $*" >&2; exit 2; }

MODE="write"
case "${1:-}" in
  --check) MODE=check;;
  --verify) MODE=verify;;
  "") ;;
  -h|--help) sed -n '2,12p' "$0"; exit 0;;
  *) die "unknown arg $1";;
esac
[[ "$GARAGE_CHART_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "GARAGE_CHART_TAG is not vX.Y.Z"
[[ "$GARAGE_CHART_SHA" =~ ^[0-9a-f]{40}$ ]] || die "GARAGE_CHART_SHA is not a 40-hex commit"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------------------------------------------
# --verify: the committed chart, rendered the way ArgoCD renders it, must show every local patch.
# Offline. This is the gate that catches a patch that applied textually but no longer does its job
# (an anchor that moved into another container, a selector that landed on the wrong Service).
if [ "$MODE" = verify ]; then
  yq -o=yaml '.spec.source.helm.valuesObject' "$APP" > "$tmp/values.yaml"
  rel="$(yq -r '.spec.source.helm.releaseName // .metadata.name' "$APP")"
  helm template "$rel" "$DEST" -n garage -f "$tmp/values.yaml" > "$tmp/out.yaml" \
    || die "--verify: the chart does not render with $APP's valuesObject"
  rc=0
  ok()  { echo "   ✓ $1"; }
  bad() { echo "   ✗ $1"; rc=1; }
  q() { yq ea -r "$1" "$tmp/out.yaml" | grep -v '^---$' | grep -v '^null$' || true; }
  want="$(yq -r '.minReadySeconds // ""' "$tmp/values.yaml")"
  ver="$(yq -r '.appVersion' "$DEST/Chart.yaml")"
  echo "==> $DEST (Garage $ver) rendered with $APP"
  [ "$ver" = "$GARAGE_CHART_TAG" ] && ok "Chart.yaml appVersion == the pin ($GARAGE_CHART_TAG)" \
    || bad "Chart.yaml appVersion '$ver' != GARAGE_CHART_TAG '$GARAGE_CHART_TAG' — run scripts/vendor-garage-chart.sh"
  grep -qF "@ $GARAGE_CHART_TAG " "$DEST/values.yaml" && ok "values.yaml header names the pin" \
    || bad "values.yaml header does not name $GARAGE_CHART_TAG — the chart was not rebuilt from the pin"
  # 1. minReadySeconds reaches the StatefulSet
  got="$(q 'select(.kind == "StatefulSet") | .spec.minReadySeconds')"
  [ -n "$want" ] && [ "$got" = "$want" ] && ok "StatefulSet minReadySeconds = $got" \
    || bad "StatefulSet minReadySeconds is '${got:-unset}', values ask for '${want:-unset}'"
  # 2. the pod template carries the serve-s3 label, the StatefulSet selector does NOT (immutable field)
  [ "$(q 'select(.kind == "StatefulSet") | .spec.template.metadata.labels."garage.teststuff.net/serve-s3"')" = true ] \
    && ok "pod template carries garage.teststuff.net/serve-s3" || bad "pod template lost the serve-s3 label"
  [ -z "$(q 'select(.kind == "StatefulSet") | .spec.selector.matchLabels."garage.teststuff.net/serve-s3"')" ] \
    && ok "StatefulSet matchLabels does not select on it" || bad "serve-s3 leaked into the StatefulSet's immutable matchLabels"
  # 3. exactly the client Service selects on it — never the headless (peer RPC) or the metrics Service
  sel="$(q 'select(.kind == "Service" and .spec.selector."garage.teststuff.net/serve-s3" == "true") | .metadata.name')"
  [ "$sel" = "$rel" ] && ok "only Service/$rel selects on serve-s3" \
    || bad "Services selecting on serve-s3: '$(echo $sel)' — expected exactly '$rel'"
  # 4. the chart's own init container has resources, and the extra init containers follow it
  inits="$(q 'select(.kind == "StatefulSet") | .spec.template.spec.initContainers[].name' | tr '\n' ' ')"
  first="${inits%% *}"
  [ -n "$(q 'select(.kind == "StatefulSet") | .spec.template.spec.initContainers[0].resources.limits.memory')" ] \
    && ok "init container $first has a memory limit" || bad "init container ${first:-?} renders without resources (initResources patch)"
  nextra="$(yq -r '.extraInitContainers | length' "$tmp/values.yaml")"
  for i in $(seq 0 $((nextra - 1))); do
    n="$(yq -r ".extraInitContainers[$i].name" "$tmp/values.yaml")"
    case " $inits" in *" $first "*" $n "*|*" $first $n "*) ok "extra init container $n renders after $first";; *) bad "extra init container $n missing or before $first (rendered: $inits)";; esac
  done
  [ "$nextra" -gt 0 ] || bad "$APP sets no extraInitContainers — the meta-rotate patch asserted nothing"
  [ "$rc" -eq 0 ] && echo "✓ vendor-garage-chart --verify: every local patch is in the rendered output"
  exit "$rc"
fi

# ---------------------------------------------------------------------------------------------------
# fetch the pinned tag, prove it is the pinned commit, take the chart dir + the license
curl -fsSL --retry 3 -o "$tmp/src.tgz" "$ARCHIVE" || die "fetch failed: $ARCHIVE"
# (the reader stops after the first tar header — gzip's SIGPIPE must not trip pipefail)
got="$( (gzip -dc "$tmp/src.tgz" 2>/dev/null || true) | git get-tar-commit-id)" || die "the archive carries no commit id"
[ "$got" = "$GARAGE_CHART_SHA" ] || die "tag $GARAGE_CHART_TAG is commit $got, the pin says $GARAGE_CHART_SHA — a moved tag or a half-bumped pin"
mkdir -p "$tmp/src" "$tmp/out"
tar xzf "$tmp/src.tgz" -C "$tmp/src" --strip-components=1 garage/script/helm/garage garage/LICENSE
SRC="$tmp/src/script/helm/garage"
[ -s "$SRC/Chart.yaml" ] && [ -d "$SRC/templates" ] || die "no chart at script/helm/garage in $GARAGE_CHART_TAG"
# Verbatim upstream, minus what no render reads: the helm-unittest suite and its sample values.
cp -r "$SRC/." "$tmp/out/"
rm -rf "$tmp/out/tests" "$tmp/out/complex-values.yaml"
cp "$tmp/src/LICENSE" "$tmp/out/LICENSE-garage-chart"

# ---------------------------------------------------------------------------------------------------
# LOCAL PATCHES — the ONLY edits to the upstream text; the why of each is VENDORED.md §Local patches.
# Each is an insertion next to an ANCHOR: one exact upstream line (first occurrence). A missing anchor
# is fatal. Insertions, never replacements, so upstream's own lines always survive a bump.
ins() {   # ins <file> <before|after> <anchor line, exact> — the block to insert on stdin
  local f="$tmp/out/$1" where="$2" anchor="$3"
  cat > "$tmp/block"
  grep -qxF -- "$anchor" "$f" || die "$1: anchor not found — '$anchor'. Upstream moved it; re-read the template at $GARAGE_CHART_TAG and fix the patch in this script"
  awk -v a="$anchor" -v w="$where" -v b="$tmp/block" '
    function emit(   l) { while ((getline l < b) > 0) print l; close(b) }
    !done && $0 == a { if (w == "before") { emit(); print } else { print; emit() } done = 1; next }
    { print }' "$f" > "$f.new" && mv "$f.new" "$f"
}
header() {   # header <file> <comment-open> <comment-close> <path to VENDORED.md>
  { printf '%sVendored from Deuxfleurs/garage script/helm/garage @ %s (AGPL-3.0, see %s §License); MODIFIED — see VENDORED.md §Local patches%s\n' "$2" "$GARAGE_CHART_TAG" "$4" "$3"
    cat "$tmp/out/$1"; } > "$tmp/out/$1.new" && mv "$tmp/out/$1.new" "$tmp/out/$1"
}

# templates/service.yaml — the client Service also selects on the serve-s3 label
ins templates/service.yaml after '    {{- include "garage.selectorLabels" . | nindent 4 }}' <<EOF
    # In-cluster S3 clients only. The headless Service (peer RPC) and the metrics Service below
    # deliberately do NOT select on this — a pod pulled from the client path stays a full peer and
    # stays scraped, which is when its metrics matter most.
    $SERVE_LABEL
EOF
header templates/service.yaml '{{- /* ' ' */ -}}' ../VENDORED.md

# templates/workload.yaml — minReadySeconds, the serve-s3 pod label, init resources, extra init containers
ins templates/workload.yaml after '  podManagementPolicy: {{ .Values.deployment.podManagementPolicy }}' <<'EOF'
  {{- with .Values.minReadySeconds }}
  minReadySeconds: {{ . }}
  {{- end }}
EOF
ins templates/workload.yaml after '        {{- include "garage.labels" . | nindent 8 }}' <<EOF
        # The S3 CLIENT path selects on this label as well as the base selector labels, so a
        # single pod can be pulled out of it during a metadata/zone rebuild without losing its
        # peer RPC (garage-headless), its replica role, or its metrics scrape. Removed by hand for
        # the duration of a rotation — docs/garage.md §The build-out step 8. Never in the
        # StatefulSet's own matchLabels: that field is immutable.
        $SERVE_LABEL
EOF
ins templates/workload.yaml before '          volumeMounts:' <<'EOF'
          {{- with .Values.initResources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
EOF
ins templates/workload.yaml before '      containers:' <<'EOF'
        {{- with .Values.extraInitContainers }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
EOF
header templates/workload.yaml '{{- /* ' ' */ -}}' ../VENDORED.md

# values.yaml — the three local keys, appended (position in a values file means nothing)
header values.yaml '# ' '' ./VENDORED.md
cat >> "$tmp/out/values.yaml" <<'EOF'

# ---------------------------------------------------------------------------------------------------
# LOCAL PATCHES (not upstream, see VENDORED.md) — appended by scripts/vendor-garage-chart.sh.
# -- resources for the chart's own `garage-init` init container (upstream sets none). Requests + a
# memory limit are the platform standard.
initResources: {}
# -- extra init containers rendered verbatim after the chart's own garage-init. Used for the metadata
# rotation seed (docs/garage.md §Metadata reclamation).
extraInitContainers: []
# -- StatefulSet minReadySeconds — the rollout waits this long after a pod is Ready before touching
# the next, so a restarted quorum member has rejoined its peers before another goes down
# (2026-09-09 07:22Z: all three cycled in 31 s, quorum lost).
minReadySeconds: 0
EOF

# VENDORED.md is hand-written prose with three generated lines: the pin block.
chart_ver="$(sed -n 's/^version: *//p' "$tmp/out/Chart.yaml" | tr -d '"')"
app_ver="$(sed -n 's/^appVersion: *//p' "$tmp/out/Chart.yaml" | tr -d '"')"
[ "$app_ver" = "$GARAGE_CHART_TAG" ] || die "Chart.yaml at $GARAGE_CHART_TAG says appVersion '$app_ver' — upstream tagged without bumping the chart; the image tag would not follow the pin"
[ -f "$DEST/VENDORED.md" ] || die "$DEST/VENDORED.md is missing"
sed -e "s|^- Tag:    .*|- Tag:    $GARAGE_CHART_TAG|" \
    -e "s|^- Commit: .*|- Commit: $GARAGE_CHART_SHA|" \
    -e "s|^- Chart:  .*|- Chart:  $chart_ver  (appVersion Garage $app_ver)|" "$DEST/VENDORED.md" > "$tmp/out/VENDORED.md"
grep -q "^- Commit: $GARAGE_CHART_SHA\$" "$tmp/out/VENDORED.md" || die "VENDORED.md lost its '- Tag: / - Commit: / - Chart:' block"

# ---------------------------------------------------------------------------------------------------
if [ "$MODE" = check ]; then
  if out="$(diff -r "$DEST" "$tmp/out" 2>&1)"; then
    echo "vendor-garage-chart --check: $DEST in sync with Deuxfleurs/garage $GARAGE_CHART_TAG @ ${GARAGE_CHART_SHA:0:12} (chart $chart_ver)"
    exit 0
  fi
  echo "vendor-garage-chart --check: DRIFT — $DEST is not what the pin + this script's patches produce:"
  printf '%s\n' "$out" | sed -n '1,30p'
  exit 1
fi
find "$DEST" -mindepth 1 -delete
cp -r "$tmp/out/." "$DEST/"
echo "vendor-garage-chart: rebuilt $DEST from Deuxfleurs/garage $GARAGE_CHART_TAG @ ${GARAGE_CHART_SHA:0:12} (chart $chart_ver, 5 local patches)"
