#!/usr/bin/env bash
# Self-test for scripts/jail-cluster.sh — no cluster. A fake `kubectl` on PATH records every call
# (argv + stdin) and plays the apiserver/pod; the real verb runs against it. Three parts:
#   1. render   — `run --dry-run` against the contract (ADR-167): kata, nx-01, the pinned dind from
#                 agents/images.env, the standard ride dind envelope, priority class, deadline bounds
#   2. policy   — the rendered pod and every row of scripts/fixtures/jail-cluster/vap-cases.tsv
#                 through `kyverno apply` of the live admission policy; the policy's dind pin must
#                 equal agents/images.env
#   3. verb     — run ships the right files, returns the gate's exit code, copies evidence back and
#                 deletes the pod (on failure too); create refusals; list / reap / token
#
#   devbox run jail-cluster-self-test
set -uo pipefail

ROOT="${DEVBOX_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SUT="$ROOT/scripts/jail-cluster.sh"
POLICY="$ROOT/argocd/resources/jail-clusters/admission-policy.yaml"
CASES="$ROOT/scripts/fixtures/jail-cluster/vap-cases.tsv"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; n=0
ok()  { n=$((n + 1)); echo "  ok $*"; }
bad() { n=$((n + 1)); echo "  FAIL $*"; fails=$((fails + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
nogrep() { ! grep -q "$@"; }
all() { local c; for c in "$@"; do eval "$c" || return 1; done; }   # all '<test>' '<test>' … (each one shell test)
export JAIL_CLUSTER_SESSION=selftest

# The pinned dind, read from its home (not from the verb): agents/images.env.
PIN="$(sed -n 's/^AGENT_DIND_IMAGE=//p' "$ROOT/agents/images.env")"
[ -n "$PIN" ] || { echo "jail-cluster-test: no AGENT_DIND_IMAGE in agents/images.env"; exit 1; }

echo "1. render"
M="$TMP/pod.yaml"
bash "$SUT" run --name a --dry-run > "$M"; rc=$?
check "dry-run exits 0" [ "$rc" -eq 0 ]
y() { yq -r "$1" "$M"; }
check "pod name = jc-<session>-<name>"              [ "$(y .metadata.name)" = "jc-selftest-a" ]
check "namespace jail-clusters"                     [ "$(y .metadata.namespace)" = "jail-clusters" ]
check "labels carry session + name"                 [ "$(y '.metadata.labels."jail-cluster/session" + "/" + .metadata.labels."jail-cluster/name"')" = "selftest/a" ]
check "runtimeClassName kata"                       [ "$(y .spec.runtimeClassName)" = "kata" ]
check "pinned to nx-01"                             [ "$(y '.spec.nodeSelector."kubernetes.io/hostname"')" = "nx-01" ]
check "priority class jail-clusters"                [ "$(y .spec.priorityClassName)" = "jail-clusters" ]
check "default deadline 3600 s"                     [ "$(y .spec.activeDeadlineSeconds)" = "3600" ]
check "no SA token in the pod"                      [ "$(y .spec.automountServiceAccountToken)" = "false" ]
check "dind image = agents/images.env pin"          [ "$(y '.spec.initContainers[] | select(.name == "dind") | .image')" = "$PIN" ]
check "dind is a native sidecar"                    [ "$(y '.spec.initContainers[] | select(.name == "dind") | .restartPolicy')" = "Always" ]
# the standard docker ride's dind envelope — 2560Mi request == limit (docs/agents/agentstack.md, rideSize)
check "dind memory 2560Mi request == limit"         [ "$(y '.spec.initContainers[] | select(.name == "dind") | .resources.requests.memory + "/" + .resources.limits.memory')" = "2560Mi/2560Mi" ]
check "dind layer store = ephemeral block PVC"      [ "$(y '.spec.volumes[] | select(.name == "docker-lib") | .ephemeral.volumeClaimTemplate.spec.volumeMode')" = "Block" ]
check "runner gets DOCKER_HOST on the sidecar"      [ "$(y '.spec.containers[0].env[] | select(.name == "DOCKER_HOST") | .value')" = "unix:///docker-run/docker.sock" ]
check "runner gets the nix cache"                   [ -n "$(y '.spec.containers[0].env[] | select(.name == "NIX_CACHE_URL") | .value')" ]
check "runner is agent-base, non-root"              [ "$(y '.spec.containers[0].image | test("^registry.teststuff.net/agent-base:")'):$(y .spec.containers[0].securityContext.runAsNonRoot)" = "true:true" ]
check "no placeholder left"                         nogrep '__[A-Z_]*__' "$M"
bash "$SUT" run --name b --deadline 600 --dry-run > "$TMP/b.yaml"
check "--deadline 600 → activeDeadlineSeconds 600"  [ "$(yq -r .spec.activeDeadlineSeconds "$TMP/b.yaml")" = "600" ]
bash "$SUT" run --name b --deadline 99999 --dry-run >/dev/null 2>&1; rc=$?
check "--deadline over 14400 refused (exit 2)"      [ "$rc" -eq 2 ]
bash "$SUT" run --name 'Sub Agent_7!' --dry-run > "$TMP/c.yaml"
check "name sanitized to a DNS label"               [ "$(yq -r .metadata.name "$TMP/c.yaml")" = "jc-selftest-sub-agent-7" ]

echo "2. policy"
check "policy dind pin == agents/images.env"        grep -qF "'$PIN'" "$POLICY"
verdict() {  # verdict <pod-file> → $GOT = pass|fail|skip|error, the kyverno output in $KOUT (no subshell)
  KOUT="$(kyverno apply "$POLICY" --resource "$1" 2>&1)"
  local sum p f e
  sum="$(grep -oE 'pass: [0-9]+, fail: [0-9]+, warn: [0-9]+, error: [0-9]+' <<<"$KOUT" | head -1)"
  [ -n "$sum" ] || { GOT=error; return; }
  p="$(sed -E 's/pass: ([0-9]+).*/\1/' <<<"$sum")"; f="$(sed -E 's/.*fail: ([0-9]+).*/\1/' <<<"$sum")"
  e="$(sed -E 's/.*error: ([0-9]+).*/\1/' <<<"$sum")"
  if [ "$e" -gt 0 ]; then GOT=error; elif [ "$f" -gt 0 ]; then GOT=fail; elif [ "$p" -gt 0 ]; then GOT=pass; else GOT=skip; fi
}
rows=0
while IFS=$'\t' read -r case want clause patch; do
  case "$case" in ''|'#'*) continue ;; esac
  rows=$((rows + 1))
  yq "$patch" "$M" > "$TMP/case.yaml" 2>"$TMP/yq.err" || { bad "$case: yq patch failed: $(head -1 "$TMP/yq.err")"; continue; }
  if [ "$patch" != "." ] && cmp -s "$M" "$TMP/case.yaml"; then bad "$case: patch changed nothing"; continue; fi
  verdict "$TMP/case.yaml"
  if [ "$GOT" != "$want" ]; then
    bad "$case: want $want, got $GOT"; grep -E 'failed|^[0-9]+ - ' <<<"$KOUT" | sed 's/^/      /'; continue
  fi
  if [ "$want" = fail ] && ! grep -q "jail-clusters-pod-guard ($clause)" <<<"$KOUT"; then
    bad "$case: refused, but not by clause ($clause):"; grep -E '^[0-9]+ - ' <<<"$KOUT" | sed 's/^/      /'; continue
  fi
  ok "$case → $want${clause#-}"
done < "$CASES"
check "decision table has rows" [ "$rows" -ge 20 ]

echo "3. verb (fake kubectl)"
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/ev"
export FAKE="$TMP/state" JAIL_CLUSTER_EVIDENCE_DIR="$TMP/ev"
cat > "$TMP/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
# Records argv (one line per call) in $FAKE/calls; plays the apiserver and the pod's runner.
echo "$*" >> "$FAKE/calls"
args=(); while [ $# -gt 0 ]; do case "$1" in --kubeconfig|-n) shift 2 ;; *) args+=("$1"); shift ;; esac; done
set -- "${args[@]}"
case "$1" in
  create)
    if [ "${2:-}" = token ]; then echo "fake-sa-token"; exit 0; fi
    cat > "$FAKE/created.yaml"
    [ -f "$FAKE/create-err" ] && { cat "$FAKE/create-err" >&2; exit 1; }
    echo "pod/x created" ;;
  wait) [ -f "$FAKE/wait-fail" ] && exit 1; exit 0 ;;
  exec)
    shift; stdin=""; [ "$1" = -i ] && { stdin=1; shift; }; pod="$1"; shift
    while [ "$1" != -- ]; do shift; done; shift
    script="$*"
    case "$script" in
      *"tar -xzf - -C /work/tree"*) tar -tzf - | sort > "$FAKE/shipped" ;;
      *"tar -czf - ."*) mkdir -p "$FAKE/evsrc"; echo proof > "$FAKE/evsrc/nodes.txt"; tar -C "$FAKE/evsrc" -czf - . ;;
      *) [ -z "$stdin" ] || { echo "fake kubectl: the gate exec must not take stdin" >&2; exit 8; }
         echo "GATE-OUTPUT for $pod: ${*: -1}"; exit "$(cat "$FAKE/gate-rc" 2>/dev/null || echo 0)" ;;
    esac ;;
  delete) echo "deleted" ;;
  get) echo "NAME SESSION PHASE"; echo "jc-selftest-a selftest Running" ;;
  config)
    case "$*" in
      *certificate-authority-data*) printf 'Q0FEQVRB' ;;
      *server*) printf 'https://192.0.2.1:6443' ;;
    esac ;;
  *) echo "fake kubectl: unhandled $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$TMP/bin/kubectl"
export PATH="$TMP/bin:$PATH"
echo "fake-admin" > "$TMP/kubeconfig"; export JAIL_CLUSTER_KUBECONFIG="$TMP/kubeconfig"

# a work tree: tracked, untracked, ignored, never-ship, and a tracked file deleted in the worktree
T="$TMP/tree"; mkdir -p "$T/sub" "$T/.devbox/gen" "$T/tofu"
git -C "$T" init -q && git -C "$T" config user.email t@t && git -C "$T" config user.name t
printf 'ignored.txt\n' > "$T/.gitignore"
echo a > "$T/tracked.sh"; echo gone > "$T/deleted.txt"; echo k > "$T/tofu/kubeconfig"
git -C "$T" add -A && git -C "$T" commit -qm init && rm "$T/deleted.txt"
echo b > "$T/sub/untracked.py"; echo c > "$T/ignored.txt"; echo d > "$T/.devbox/gen/x"
echo e > "$T/main.tfstate"; echo f > "$T/.env"; echo g > "$T/id.pem"

run_verb() { : > "$FAKE/calls"; bash "$SUT" run --name a --tree "$T" -- devbox run smoke > "$TMP/out" 2>&1 < /dev/null; }
run_verb; rc=$?
check "run → gate exit 0 passes through"            [ "$rc" -eq 0 ]
check "gate output streamed"                        grep -q "GATE-OUTPUT for jc-selftest-a: smoke" "$TMP/out"
check "created manifest = the dry-run render"       cmp -s "$FAKE/created.yaml" "$M"
check "shipped: tracked + untracked, sorted"        diff -q <(grep -vE '/$' "$FAKE/shipped") <(printf '%s\n' .gitignore sub/untracked.py tracked.sh)
check "pod deleted after the run"                   grep -q "delete pod jc-selftest-a" "$FAKE/calls"
ev="$(ls -d "$TMP"/ev/jc-selftest-a-* 2>/dev/null | head -1)"
check "evidence copied back"                        [ "$(cat "$ev/evidence/nodes.txt" 2>/dev/null)" = proof ]
check "gate log kept locally"                       grep -q GATE-OUTPUT "$ev/gate.log"
echo 3 > "$FAKE/gate-rc"; run_verb; rc=$?
check "run → gate exit 3 passes through"            [ "$rc" -eq 3 ]
check "pod deleted after a failing gate too"        grep -q "delete pod jc-selftest-a" "$FAKE/calls"
rm -f "$FAKE/gate-rc"
: > "$FAKE/calls"; bash "$SUT" run --name a --keep --tree "$T" -- true >/dev/null 2>&1 < /dev/null
check "--keep leaves the pod"                       nogrep "delete pod" "$FAKE/calls"
echo 'Error from server (Forbidden): pods "jc-selftest-a" is forbidden: exceeded quota: jail-clusters, requested: pods=1, used: pods=2, limited: pods=2' > "$FAKE/create-err"
run_verb; rc=$?
check "quota refusal → exit 2, named as the cap"    all '[ "$rc" -eq 2 ]' 'grep -q "cap is reached" "$TMP/out"'
check "  …and nothing exec'd"                       nogrep " exec " "$FAKE/calls"
rm -f "$FAKE/create-err"; touch "$FAKE/wait-fail"
run_verb; rc=$?
check "never Ready → exit 3, pod deleted"           all '[ "$rc" -eq 3 ]' 'grep -q "delete pod jc-selftest-a" "$FAKE/calls"' 
rm -f "$FAKE/wait-fail"
JAIL_CLUSTER_KUBECONFIG="$TMP/missing" KUBECONFIG="" bash "$SUT" run --name a --tree "$T" -- true >/dev/null 2>&1 < /dev/null; rc=$?
check "no kubeconfig → refused (exit 2)"            [ "$rc" -eq 2 ]

: > "$FAKE/calls"; bash "$SUT" list >/dev/null
check "list reads the labelled pods"                grep -q "get pods -l app=jail-cluster" "$FAKE/calls"
: > "$FAKE/calls"; bash "$SUT" reap a >/dev/null
check "reap <name> deletes this session's pod"      grep -q "delete pod jc-selftest-a" "$FAKE/calls"
: > "$FAKE/calls"; bash "$SUT" reap >/dev/null
check "reap (bare) deletes this session's pods"     grep -q "delete pods -l app=jail-cluster,jail-cluster/session=selftest" "$FAKE/calls"
: > "$FAKE/calls"; bash "$SUT" reap --all >/dev/null
check "reap --all deletes every jail pod"           grep -q "delete pods -l app=jail-cluster --wait=false" "$FAKE/calls"
: > "$FAKE/calls"; bash "$SUT" token --out "$TMP/sa.kubeconfig" --duration 30m 2>/dev/null; rc=$?
check "token writes a kubeconfig"                   all '[ "$rc" -eq 0 ]' "grep -q 'token: \"fake-sa-token\"' \"\$TMP/sa.kubeconfig\""
check "  …scoped to jail-clusters, mode 600"        all "grep -q 'namespace: jail-clusters' \"\$TMP/sa.kubeconfig\"" '[ "$(stat -c %a "$TMP/sa.kubeconfig")" = 600 ]' 
check "  …minted for the SA with the duration"      grep -q "create token jail-cluster --duration 30m" "$FAKE/calls"
bash "$SUT" token >/dev/null 2>&1; rc=$?
check "token without --out refused (never printed)" [ "$rc" -eq 2 ]

echo
[ "$fails" -eq 0 ] || { echo "jail-cluster-test: $fails of $n check(s) FAILED"; exit 1; }
echo "jail-cluster-test: OK — $n checks"
