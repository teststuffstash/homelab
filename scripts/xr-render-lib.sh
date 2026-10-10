# xr-render-lib.sh — sourced (never executed): docker-free `crossplane composition render` at the
# CLUSTER-PINNED engine + function versions. Shared by scripts/xr-render.sh (render every committed
# claim, diff base↔head) and scripts/publicroute-tf-validate.sh (render fixtures → tofu validate).
#
# Why docker-free: render's default runtime starts the engine + each function as containers, and
# the jail has no docker daemon (the CI runner's dind made every render pay a ~130 s cold pull).
# Instead the binaries are pulled straight out of the pinned OCI images by DIGEST and run locally:
# the engine via `--crossplane-binary`, the functions as `--insecure` gRPC servers on unix sockets
# (render's `Development` runtime annotation). Same bytes the cluster runs, no daemon.
#
# Pins — read from their one home each, never restated here:
#   engine:    argocd/platform/crossplane.yaml  .spec.source.targetRevision + the
#              crossplane.io/engine-image-digest.v<ver> annotation (homelab#1739)
#   functions: argocd/resources/crossplane/functions.yaml  `kind: Function` .spec.package (@sha256)
# Fetch integrity: the pinned digest is the trust root. Every manifest and blob fetched is
# sha256-checked against the digest that named it (index → platform manifest → config/layers), so a
# mirror can only serve the pinned bytes or fail. Unpinned refs (no @sha256) are refused.
#
# Registries (WAN-free by default, the FU-130 class — the ADR-091 pull-through mirrors):
#   xpkg.crossplane.io / ghcr.io → REGISTRY_MIRROR_GHCR      (default http://192.168.40.21)
#   docker.io                    → REGISTRY_MIRROR_DOCKER_IO (default http://192.168.40.20)
#   XR_RENDER_UPSTREAM=1 pulls from the real registries instead (anonymous bearer token).
# Cache: ${XR_RENDER_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/xr-render}/<digest>/bin — content-addressed.
#
# Needs on PATH: curl, jq, yq, tar, sha256sum, crossplane (the CLI — devbox.json crossplane-cli).

xr__die() { echo "xr-render: FAIL — $*" >&2; exit 2; }

# xr__registry_base <ref-host> → base URL to talk the v2 API to
xr__registry_base() {
  if [ "${XR_RENDER_UPSTREAM:-0}" = 1 ]; then
    case "$1" in
      xpkg.crossplane.io|ghcr.io) echo "https://ghcr.io" ;;
      docker.io) echo "https://registry-1.docker.io" ;;
      *) echo "https://$1" ;;
    esac
    return
  fi
  case "$1" in
    xpkg.crossplane.io|ghcr.io) echo "${REGISTRY_MIRROR_GHCR:-http://192.168.40.21}" ;;
    docker.io) echo "${REGISTRY_MIRROR_DOCKER_IO:-http://192.168.40.20}" ;;
    *) echo "https://$1" ;;
  esac
}

XR__ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

# xr__get <base> <repo> <kind: manifests|blobs> <digest> <outfile> — fetch + sha256-verify
xr__get() {
  local base=$1 repo=$2 kind=$3 dg=$4 out=$5 hdr=() tok=""
  if [ "${XR_RENDER_UPSTREAM:-0}" = 1 ]; then
    case "$base" in
      https://ghcr.io) tok=$(curl -fsS "https://ghcr.io/token?scope=repository:${repo}:pull" | jq -r .token) ;;
      https://registry-1.docker.io) tok=$(curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" | jq -r .token) ;;
    esac
    [ -n "$tok" ] && hdr=(-H "Authorization: Bearer $tok")
  fi
  curl -fsSL --retry 3 --connect-timeout 10 -m 300 "${hdr[@]}" -H "Accept: $XR__ACCEPT" \
    -o "$out" "$base/v2/$repo/$kind/$dg" || xr__die "fetch $base/v2/$repo/$kind/$dg"
  [ "sha256:$(sha256sum "$out" | cut -d' ' -f1)" = "$dg" ] \
    || xr__die "digest mismatch on $repo $kind $dg (served bytes do not hash to the pin)"
}

# xr_fetch_bin <image-ref-with-@sha256> → prints the path of the image's entrypoint binary
# (linux/amd64), extracted from its layers. Cached by the pinned digest.
xr_fetch_bin() {
  local ref=$1 cache root dg host repo base w m pm cfg ep p t i
  case "$ref" in *@sha256:*) ;; *) xr__die "unpinned image ref '$ref' (needs @sha256:<digest>)";; esac
  dg="${ref##*@}"; repo="${ref%@*}"; repo="${repo%:*}"   # strip @digest, then :tag
  host="${repo%%/*}"; repo="${repo#*/}"
  cache="${XR_RENDER_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/xr-render}/${dg#sha256:}"
  if [ -x "$cache/bin" ]; then echo "$cache/bin"; return; fi
  base=$(xr__registry_base "$host")
  w=$(mktemp -d); root="$w/root"; mkdir -p "$root"
  xr__get "$base" "$repo" manifests "$dg" "$w/top.json"
  m="$dg"
  if jq -e '.manifests' "$w/top.json" >/dev/null; then
    m=$(jq -r '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64")][0].digest // empty' "$w/top.json")
    [ -n "$m" ] || xr__die "$ref has no linux/amd64 manifest"
    xr__get "$base" "$repo" manifests "$m" "$w/m.json"
  else
    cp "$w/top.json" "$w/m.json"
  fi
  cfg=$(jq -r .config.digest "$w/m.json")
  xr__get "$base" "$repo" blobs "$cfg" "$w/cfg.json"
  ep=$(jq -r '.config.Entrypoint[0] // empty' "$w/cfg.json")
  [ -n "$ep" ] || xr__die "$ref has no Entrypoint"
  i=0
  for l in $(jq -r '.layers[].digest' "$w/m.json"); do
    xr__get "$base" "$repo" blobs "$l" "$w/layer"
    tar -xzf "$w/layer" -C "$root" --no-same-owner --no-same-permissions 2>/dev/null \
      || tar -xf "$w/layer" -C "$root" --no-same-owner 2>/dev/null || xr__die "untar layer $l of $ref"
    rm -f "$w/layer"; i=$((i + 1))
  done
  # resolve the entrypoint inside the extracted rootfs (absolute symlinks are rootfs-relative —
  # the engine's /bin/crossplane points into its /nix/store)
  p="$ep"; case "$p" in /*) ;; *) p="/usr/local/bin/$p";; esac
  for _ in 1 2 3 4 5 6 7 8; do
    [ -L "$root$p" ] || break
    t=$(readlink "$root$p"); case "$t" in /*) p="$t";; *) p="$(dirname "$p")/$t";; esac
  done
  [ -f "$root$p" ] || xr__die "$ref: entrypoint $ep not found in its $i layer(s)"
  mkdir -p "$cache"; cp "$root$p" "$cache/bin.tmp"; chmod 0755 "$cache/bin.tmp"; mv "$cache/bin.tmp" "$cache/bin"
  chmod -R u+w "$w"; rm -rf "$w"   # nix-store layers extract read-only
  echo "$cache/bin"
}

# xr_pins <repo-root> — sets XR_ENGINE_VERSION, XR_ENGINE_REF and XR_FN_NAMES/XR_FN_REFS (arrays)
# from the cluster's pin files under <repo-root> (a checkout or an extracted base tree).
xr_pins() {
  local r=$1 ver dgst
  ver=$(yq -r '.spec.source.targetRevision' "$r/argocd/platform/crossplane.yaml")
  dgst=$(yq -r ".metadata.annotations[\"crossplane.io/engine-image-digest.v${ver}\"]" "$r/argocd/platform/crossplane.yaml")
  [ -n "$dgst" ] && [ "$dgst" != null ] || xr__die "no crossplane.io/engine-image-digest.v${ver} annotation in argocd/platform/crossplane.yaml"
  XR_ENGINE_VERSION="v$ver"
  XR_ENGINE_REF="docker.io/crossplane/crossplane:v${ver}@${dgst}"
  XR_FN_NAMES=(); XR_FN_REFS=()
  while IFS=$'\t' read -r n p; do
    [ -n "$n" ] || continue
    XR_FN_NAMES+=("$n"); XR_FN_REFS+=("$p")
  done < <(yq -r 'select(.kind == "Function") | [.metadata.name, .spec.package] | @tsv' "$r/argocd/resources/crossplane/functions.yaml")
  [ "${#XR_FN_NAMES[@]}" -gt 0 ] || xr__die "no Function in $r/argocd/resources/crossplane/functions.yaml"
}

# xr_start <repo-root> <workdir> — fetch the pinned binaries, start every function as a local gRPC
# server on a unix socket, write <workdir>/functions.yaml (Development runtime) and set
# XR_ENGINE_BIN + XR_FUNCTIONS. Call xr_stop when done (the caller's EXIT trap).
XR_FN_PIDS=()
xr_start() {
  local r=$1 w=$2 i bin sock
  xr_pins "$r"
  mkdir -p "$w"
  XR_ENGINE_BIN=$(xr_fetch_bin "$XR_ENGINE_REF") || exit 2
  XR_FUNCTIONS="$w/functions.yaml"; : > "$XR_FUNCTIONS"
  for i in "${!XR_FN_NAMES[@]}"; do
    bin=$(xr_fetch_bin "${XR_FN_REFS[$i]}") || exit 2
    sock="$w/fn-$i.sock"; rm -f "$sock"
    "$bin" --insecure --network=unix --address="$sock" > "$w/fn-$i.log" 2>&1 &
    XR_FN_PIDS+=($!)
    cat >> "$XR_FUNCTIONS" <<EOF
---
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: ${XR_FN_NAMES[$i]}
  annotations:
    render.crossplane.io/runtime: Development
    render.crossplane.io/runtime-development-target: unix://$sock
spec:
  package: ${XR_FN_REFS[$i]}
EOF
  done
  for i in "${!XR_FN_NAMES[@]}"; do   # wait for every socket (≤10 s)
    for _ in $(seq 1 100); do [ -S "$w/fn-$i.sock" ] && break; sleep 0.1; done
    [ -S "$w/fn-$i.sock" ] || { cat "$w/fn-$i.log" >&2; xr__die "function ${XR_FN_NAMES[$i]} did not start"; }
  done
}
xr_stop() { local p; for p in "${XR_FN_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; XR_FN_PIDS=(); }

# xr_render <xr-file> <composition> <xrd> <out> — one render; stderr to <out>.err; returns its rc
xr_render() {
  crossplane composition render "$1" "$2" "$XR_FUNCTIONS" --xrd "$3" \
    --crossplane-binary "$XR_ENGINE_BIN" --timeout "${XR_RENDER_TIMEOUT:-2m}" > "$4" 2> "$4.err"
}
