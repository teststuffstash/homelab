#!/usr/bin/env bash
# jail-cluster — run a gate that needs a Docker daemon (kind/k3d) in a throwaway pod on nx-01,
# from a jail that has no daemon (ADR-167, docs/jail-clusters.md).
#
# One pod per run, in namespace jail-clusters: a kata microVM with the docker-mode ride's dind
# sidecar and a `runner` container (agent-base: devbox + nix). The verb ships the caller's working
# tree into the runner, runs the command there, streams the log, copies evidence back and deletes
# the pod. The jail needs kubectl only. OPTIONAL by ADR-167/ADR-108: no gate depends on it; when
# it is unavailable, push and let CI run the gate.
#
#   jail-cluster run [--name <n>] [--deadline <s>] [--tree <dir>] [--keep] [--dry-run] -- <command…>
#   jail-cluster list
#   jail-cluster reap [--all | <name>]          (no argument: this session's pods)
#   jail-cluster token [--out <file>] [--duration <d>]  (admin kubeconfig: mint a namespace-scoped
#                                    kubeconfig, ≤ 4h, written OUTSIDE any git work tree)
#
# Inside the pod: cwd = the shipped tree; $JAIL_EVIDENCE_DIR is copied back; docker is on PATH
# (DOCKER_HOST = the dind sidecar), and the registry-mirror / nix-cache env of a docker ride is set.
# Smoke (no island gate exists yet): jail-cluster run -- bash scripts/jail-cluster-smoke.sh
#
# Kubeconfig: $JAIL_CLUSTER_KUBECONFIG, else $KUBECONFIG, else <repo>/tofu/kubeconfig (the seat's
# admin fallback). Subagents and stack jails use a `token` kubeconfig, never the admin one.
# Session label: $JAIL_CLUSTER_SESSION, else the hostname (one jail container = one session).
#
# The pod fragments are NOT copied here: the dind sidecar, its volumes, the mirror env and the
# standard ride memory envelope are EXTRACTED from agents/agent-session.sh at run time (the replay
# harness's extraction contract — one home). A change there that breaks the extraction fails this
# verb loudly; scripts/jail-cluster-test.sh is the check.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS=jail-clusters
NODE=nx-01                    # the ride tier (ADR-159 `large` lives here too); the admission policy pins it
PRIORITY_CLASS=jail-clusters  # value < 0, preemptionPolicy Never (argocd/resources/jail-clusters/)
DEADLINE_DEFAULT=3600
DEADLINE_MAX=14400            # = the admission policy's ceiling and a ride's own 4 h wall clock
TOKEN_MAX_S=14400             # the verb's own ceiling on a minted token (the apiserver sets none here)
SRC="$ROOT/agents/agent-session.sh"

die()  { echo "jail-cluster: $*" >&2; exit 2; }
log()  { echo "→ $*" >&2; }
usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

sanitize() {  # sanitize <string> <maxlen> → DNS-1123 label fragment
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -e 's/--*/-/g' -e 's/^-//' \
    | cut -c "1-$2" | sed 's/-$//'
}
SESSION="$(sanitize "${JAIL_CLUSTER_SESSION:-$(hostname 2>/dev/null || echo jail)}" 20)"
[ -n "$SESSION" ] || SESSION=jail

kubeconfig() {
  local k="${JAIL_CLUSTER_KUBECONFIG:-${KUBECONFIG:-$ROOT/tofu/kubeconfig}}"
  [ -r "$k" ] || die "no readable kubeconfig ($k) — set JAIL_CLUSTER_KUBECONFIG (a subagent: ask the seat for \`jail-cluster token\`)"
  printf '%s' "$k"
}
k() { kubectl --kubeconfig "$KCFG" -n "$NS" "$@"; }

# ── render: the docker-mode ride fragments, extracted, plus this verb's own pod shell ──────────
render() {   # render <pod> <name> <deadline> → manifest on stdout
  local pod="$1" name="$2" deadline="$3" ride dock
  [ -r "$SRC" ] || die "missing $SRC"
  # (1) the ride size envelope — sentinel-delimited (agents/replay/run.sh's extract contract)
  ride="$(awk '$0 == "# >>>REPLAY:ride-size>>>" {f = 1; next} $0 == "# <<<REPLAY:ride-size<<<" {f = 0} f' "$SRC")"
  # (2) the docker-mode pod fragments: the block between the bare `ride_size_envelope` call and
  #     the next sentinel (`# >>>REPLAY:fu088-gates>>>`) — KATA_BLOCK, DOCKER_ENV/MOUNT/VOLUMES,
  #     DIND_CONTAINER with the mirrors and the image substituted
  dock="$(awk 'f && $0 == "# >>>REPLAY:fu088-gates>>>" {exit} f {print} $0 == "ride_size_envelope" {f = 1}' "$SRC")"
  [ -n "$ride" ] && [ -n "$dock" ] || die "cannot extract the docker-mode fragments from $SRC (sentinels moved?)"
  # shellcheck disable=SC1091
  . "$ROOT/agents/images.env"
  # shellcheck disable=SC2034  # inputs read (and outputs written) by the eval'd agent-session.sh spans
  local DOCKER=1 RIDE_SIZE=standard AFFINITY="" AGENT_REQUESTS="" AGENT_LIMITS="" DIND_REQUESTS="" DIND_LIMITS=""
  local KATA_BLOCK="" DOCKER_ENV="" DOCKER_MOUNT="" DOCKER_VOLUMES="" DIND_CONTAINER=""
  # shellcheck disable=SC2034  # scoped here so the eval'd span cannot leak them into the verb
  local MIRROR_DOCKER_IO="" MIRROR_GHCR="" MIRROR_MCR="" NIX_CACHE_VIP=""
  eval "$ride"
  ride_size_envelope >/dev/null
  eval "$dock"
  case "$KATA_BLOCK" in *"runtimeClassName: kata"*) ;; *) die "extracted KATA_BLOCK is not kata — refusing";; esac
  case "$DIND_CONTAINER" in *"- name: dind"*"image: ${AGENT_DIND_IMAGE}"*) ;; *) die "extracted DIND_CONTAINER lacks the pinned dind";; esac
  case "$DIND_CONTAINER" in *__*__*) die "extracted DIND_CONTAINER has an unsubstituted placeholder";; esac
  # every emptyDir gets a sizeLimit (admission policy (n)); the ride's docker-run holds a socket + a toml
  case "$DOCKER_VOLUMES" in *"emptyDir: {}"*) DOCKER_VOLUMES="${DOCKER_VOLUMES//emptyDir: \{\}/emptyDir: { sizeLimit: 64Mi \}}" ;; esac
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${NS}
  labels: { app: jail-cluster, jail-cluster/session: "${SESSION}", jail-cluster/name: "${name}" }
spec:
  restartPolicy: Never
  activeDeadlineSeconds: ${deadline}
  priorityClassName: ${PRIORITY_CLASS}
  serviceAccountName: jail-cluster-runner
  automountServiceAccountToken: false
  enableServiceLinks: false
  terminationGracePeriodSeconds: 5
  nodeSelector: { kubernetes.io/hostname: ${NODE} }
  tolerations:
    - { key: homelab.io/ephemeral, operator: Equal, value: "true", effect: NoSchedule }
${KATA_BLOCK}
  securityContext:
    fsGroup: 1000
${DIND_CONTAINER}
    # the runner's docker/k3d/kubectl CLIs, copied out of the SAME pinned image (no second image)
    - name: tools
      image: ${AGENT_DIND_IMAGE}
      command: ["sh", "-c"]
      args:
        - |
          set -e
          cp "\$(command -v docker)" "\$(command -v k3d)" /jail-tools/
          if command -v kubectl >/dev/null; then cp "\$(command -v kubectl)" /jail-tools/; fi
      securityContext: { runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, allowPrivilegeEscalation: false, capabilities: { drop: ["ALL"] } }
      resources:
        requests: { cpu: "50m", memory: "64Mi", ephemeral-storage: "64Mi" }
        limits:   { cpu: "500m", memory: "64Mi", ephemeral-storage: "256Mi" }
      volumeMounts:
        - { name: jail-tools, mountPath: /jail-tools }
  containers:
    - name: runner
      image: ${AGENT_BASE_IMAGE}
      command: ["sleep", "${deadline}"]
      workingDir: /work
      env:
        - name: DEVBOX_NO_UPDATE_CHECK
          value: "1"
        - name: DO_NOT_TRACK
          value: "1"
        - name: DEVBOX_DISABLE_TELEMETRY
          value: "1"
        - name: JAIL_EVIDENCE_DIR
          value: /work/evidence
${DOCKER_ENV}
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        allowPrivilegeEscalation: false
        capabilities: { drop: ["ALL"] }
        seccompProfile: { type: RuntimeDefault }
      resources:   # an ESTIMATE (ADR-167): record the first real run's peak and resize
        requests: { cpu: "500m", memory: "1Gi", ephemeral-storage: "2Gi" }
        limits:   { cpu: "4", memory: "1Gi", ephemeral-storage: "10Gi" }
      volumeMounts:${DOCKER_MOUNT}
        - { name: jail-tools, mountPath: /jail-tools }
  volumes:${DOCKER_VOLUMES}
    - name: jail-tools
      emptyDir: { sizeLimit: 512Mi }
EOF
}

# The in-pod wrapper: tools on PATH, nix substituter = the cache (the agent-base entrypoint's rule,
# which `command:` bypasses), wait for dockerd, then the caller's command in the tree.
# shellcheck disable=SC2016
WRAP='export PATH="/jail-tools:$PATH"
if [ -n "${NIX_CACHE_URL:-}" ]; then
  export NIX_CONFIG="experimental-features = nix-command flakes
flake-registry =
substituters = ${NIX_CACHE_URL}?priority=10
extra-trusted-substituters = ${NIX_CACHE_URL}"
fi
mkdir -p "$JAIL_EVIDENCE_DIR"
i=0; until docker info >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -lt 90 ] || { echo "jail-cluster: dockerd not up after 180s" >&2; exit 125; }; sleep 2
done
cd /work/tree && exec "$@"'

# never_ship <repo-relative path> — THE one predicate for what never leaves the jail, whatever
# .gitignore says (scripts/jail-cluster-test.sh builds a tree holding one of each and asserts the tar
# has none): devbox state and .git; any *kubeconfig* / *talosconfig* name; ssh private keys
# (id_rsa, id_ed25519, … — the .pub halves too, they are not gate input); .netrc, .git-credentials,
# .npmrc, .pypirc; .env and every .env*; tofu state and vars (*.tfstate*, *.tfvars*); key files
# (*.pem, *.key, *.p12, *.pfx, *.kdbx, *.keyx).
NEVER_SHIP='(^|/)\.devbox/|(^|/)\.git/|(^|/)[^/]*(kubeconfig|talosconfig)[^/]*$|(^|/)id_(rsa|dsa|ecdsa|ed25519)(_sk)?(\.pub)?$|(^|/)(\.netrc|\.git-credentials|\.npmrc|\.pypirc)$|(^|/)\.env[^/]*$|\.tfstate[^/]*$|\.tfvars[^/]*$|\.(pem|key|p12|pfx|kdbx|keyx)$'
never_ship() { grep -Eq "$NEVER_SHIP" <<<"$1"; }
# ship_tree <dir> → tar.gz on stdout: tracked + untracked-not-ignored files (.gitignore honoured),
# minus never_ship, minus the kubeconfig this verb is using (whatever its name) when it sits inside
# the tree.
ship_tree() {
  local dir="$1" kc="" f
  kc="$(realpath -m "${JAIL_CLUSTER_KUBECONFIG:-${KUBECONFIG:-}}" 2>/dev/null || true)"
  git -C "$dir" ls-files -z -c -o --exclude-standard --deduplicate \
    | while IFS= read -r -d '' f; do
        [ -e "$dir/$f" ] || [ -L "$dir/$f" ] || continue     # tracked but deleted in the worktree
        never_ship "$f" && continue
        if [ -n "$kc" ] && [ "$(realpath -m "$dir/$f")" = "$kc" ]; then
          echo "jail-cluster: NOT shipping $f — it is the kubeconfig in use" >&2; continue
        fi
        printf '%s\0' "$f"
      done \
    | tar -C "$dir" --null --no-recursion -T - -czf -
}

# extract_evidence <tgz> <dir> — the pod's tar is untrusted: refuse it whole if any member is
# absolute or has a `..` segment, extract without owners/permissions, then delete every symlink
# (nothing in the evidence dir may point outside it).
extract_evidence() {
  local tgz="$1" dir="$2" bad
  bad="$(tar -tzf "$tgz" 2>/dev/null | grep -E '^/|(^|/)\.\.(/|$)' | head -3)" || true
  if [ -n "$bad" ] || ! tar -tzf "$tgz" >/dev/null 2>&1; then
    echo "jail-cluster: WARN evidence REFUSED (absolute or .. member, or unreadable): ${bad:-unreadable}" >&2
    return 0
  fi
  tar -xzf "$tgz" -C "$dir" --no-same-owner --no-same-permissions
  find "$dir" -type l -print -delete | sed 's/^/jail-cluster: dropped evidence symlink /' >&2
  rm -f "$tgz"
}

cmd_run() {
  local name="" deadline="$DEADLINE_DEFAULT" tree="" keep="" dry=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="${2:-}"; shift 2 ;;
      --deadline) deadline="${2:-}"; shift 2 ;;
      --tree) tree="${2:-}"; shift 2 ;;
      --keep) keep=1; shift ;;
      --dry-run) dry=1; shift ;;
      --) shift; break ;;
      *) die "run: unknown argument '$1' (the command goes after --)" ;;
    esac
  done
  [ $# -gt 0 ] || [ -n "$dry" ] || die "run: no command — jail-cluster run [opts] -- <command…>"
  case "$deadline" in ''|*[!0-9]*) die "run: --deadline takes seconds";; esac
  [ "$deadline" -ge 60 ] && [ "$deadline" -le "$DEADLINE_MAX" ] || die "run: --deadline must be 60..$DEADLINE_MAX"
  [ -n "$name" ] || name="r$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  name="$(sanitize "$name" 30)"; [ -n "$name" ] || die "run: --name sanitizes to nothing"
  local pod="jc-${SESSION}-${name}"
  if [ -n "$dry" ]; then render "$pod" "$name" "$deadline"; return 0; fi

  tree="${tree:-$(git rev-parse --show-toplevel 2>/dev/null)}" || true
  [ -n "$tree" ] && git -C "$tree" rev-parse --git-dir >/dev/null 2>&1 || die "run: --tree must be a git work tree (got '${tree:-cwd}')"
  KCFG="$(kubeconfig)"
  local manifest out err rc=0 ev
  manifest="$(render "$pod" "$name" "$deadline")"
  ev="${JAIL_CLUSTER_EVIDENCE_DIR:-${TMPDIR:-/tmp}/jail-cluster}/${pod}-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$ev/evidence"

  # A pod past its deadline (or done) stays as an object with its scratch PVC, and still holds the
  # PVC quota until deleted. Clear every finished rig pod first — the PVC is the pod's ephemeral
  # volume (owned by it), so the garbage collector removes it after the pod.
  k delete pods -l app=jail-cluster --field-selector=status.phase==Failed --wait=false >/dev/null 2>&1 || true
  k delete pods -l app=jail-cluster --field-selector=status.phase==Succeeded --wait=false >/dev/null 2>&1 || true
  if ! err="$(printf '%s\n' "$manifest" | k create -f - 2>&1 >/dev/null)"; then
    case "$err" in
      *"exceeded quota"*) die "the jail-cluster cap is reached (ResourceQuota $NS) — \`jail-cluster list\`, wait or reap. $err" ;;
      *AlreadyExists*|*"already exists"*) die "pod $pod already exists — another --name, or \`jail-cluster reap $name\`" ;;
      *) die "create of $pod refused: $err" ;;
    esac
  fi
  if [ -z "$keep" ]; then
    # shellcheck disable=SC2064
    trap "kubectl --kubeconfig '$KCFG' -n '$NS' delete pod '$pod' --wait=false --ignore-not-found >/dev/null 2>&1 || true" EXIT
  fi
  log "pod $NS/$pod created (deadline ${deadline}s, evidence → $ev)"
  if ! k wait --for=condition=Ready "pod/$pod" --timeout="${JAIL_CLUSTER_START_TIMEOUT:-300}s" >/dev/null; then
    echo "jail-cluster: $pod did not become Ready — pending on nx-01 capacity, preempted, or refused at start:" >&2
    k get pod "$pod" -o wide >&2 || true
    k get events --field-selector "involvedObject.name=$pod" >&2 || true
    exit 3
  fi
  log "shipping $(git -C "$tree" rev-parse --short HEAD 2>/dev/null || echo '?')+worktree from $tree"
  ship_tree "$tree" | k exec -i "$pod" -c runner -- sh -c 'mkdir -p /work/tree && tar -xzf - -C /work/tree' \
    || die "shipping the tree into $pod failed"
  log "running: $*"
  set +e
  k exec "$pod" -c runner -- bash -c "$WRAP" jail-cluster "$@" 2>&1 < /dev/null | tee "$ev/gate.log"
  rc="${PIPESTATUS[0]}"
  set -e
  if k exec "$pod" -c runner -- sh -c 'cd "$JAIL_EVIDENCE_DIR" && tar -czf - .' > "$ev/evidence.tgz" 2>/dev/null; then
    extract_evidence "$ev/evidence.tgz" "$ev/evidence"
  else
    echo "jail-cluster: WARN evidence copy-back failed (the gate's exit stands)" >&2
  fi
  log "exit $rc · log + evidence: $ev${keep:+ · pod KEPT: jail-cluster reap $name}"
  return "$rc"
}

cmd_list() {
  KCFG="$(kubeconfig)"
  k get pods -l app=jail-cluster -L jail-cluster/session,jail-cluster/name \
    -o custom-columns='NAME:.metadata.name,SESSION:.metadata.labels.jail-cluster/session,PHASE:.status.phase,DEADLINE:.spec.activeDeadlineSeconds,CREATED:.metadata.creationTimestamp'
}

cmd_reap() {
  KCFG="$(kubeconfig)"
  case "${1:-}" in
    --all) k delete pods -l app=jail-cluster --wait=false ;;
    "")    k delete pods -l "app=jail-cluster,jail-cluster/session=${SESSION}" --wait=false ;;
    -*)    die "reap: unknown flag '$1'" ;;
    jc-*)  k delete pod "$1" --wait=false ;;
    *)     k delete pod "jc-${SESSION}-$(sanitize "$1" 30)" --wait=false ;;
  esac
}

cmd_token() {
  local out="" dur=2h
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="${2:-}"; shift 2 ;;
      --duration) dur="${2:-}"; shift 2 ;;
      *) die "token: unknown argument '$1'" ;;
    esac
  done
  local secs
  case "$dur" in
    *[0-9]h) secs=$(( ${dur%h} * 3600 )) ;; *[0-9]m) secs=$(( ${dur%m} * 60 )) ;; *[0-9]s) secs=${dur%s} ;;
    *) die "token: --duration takes <n>h, <n>m or <n>s" ;;
  esac 2>/dev/null || die "token: --duration takes <n>h, <n>m or <n>s"
  [ "$secs" -ge 600 ] && [ "$secs" -le "$TOKEN_MAX_S" ] || die "token: --duration must be 10m..4h"
  out="${out:-${JAIL_CLUSTER_TOKEN_DIR:-$HOME/.jail-cluster}/${SESSION}-$(date -u +%Y%m%dT%H%M%SZ).kubeconfig}"
  # never inside a git work tree: `run` ships work trees, and a token there would ride along
  local outdir; outdir="$(dirname "$out")"
  mkdir -p "$outdir" && chmod 700 "$outdir" 2>/dev/null || true
  if git -C "$outdir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "token: --out $out is inside a git work tree — write it outside any checkout (default \$HOME/.jail-cluster/)"
  fi
  KCFG="$(kubeconfig)"
  local server ca tok
  server="$(kubectl --kubeconfig "$KCFG" config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')"
  ca="$(kubectl --kubeconfig "$KCFG" config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
  tok="$(k create token jail-cluster --duration "${secs}s")"
  [ -n "$server" ] && [ -n "$ca" ] && [ -n "$tok" ] || die "token: could not read server/CA or mint the token"
  ( umask 077; rm -f "$out"; cat > "$out" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: homelab
    cluster: { server: "${server}", certificate-authority-data: "${ca}" }
users:
  - name: jail-cluster
    user: { token: "${tok}" }
contexts:
  - name: jail-cluster
    context: { cluster: homelab, user: jail-cluster, namespace: ${NS} }
current-context: jail-cluster
EOF
  )
  log "wrote $out (ServiceAccount $NS/jail-cluster, expires in $dur) — JAIL_CLUSTER_KUBECONFIG=$out"
}

case "${1:-}" in
  run)   shift; cmd_run "$@" ;;
  list)  shift; cmd_list ;;
  reap)  shift; cmd_reap "$@" ;;
  token) shift; cmd_token "$@" ;;
  *) usage ;;
esac
