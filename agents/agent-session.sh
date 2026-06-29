#!/usr/bin/env bash
# agent-session — spawn a SCOPED, ephemeral per-project agent pod and attach.
#
# The cockpit→pod handoff: the risky per-project agent run happens in its OWN pod (one repo, that
# project's budget-capped key, its own egress) — NOT in the shared jail, which only orchestrates.
# Interactive and non-interactive are the SAME pod; only the command differs.
#
#   bash agents/agent-session.sh sleep-tracking
#       → interactive: preps the repo, drops you into a shell; run `goose`/`opencode` by hand.
#   bash agents/agent-session.sh sleep-tracking \
#       --run "goose run --recipe .agents/fix.yaml --params issue=42"
#       → headless: runs the recipe to a branch+PR, streams logs, pod self-terminates.
#
# Flags: --run "<cmd>"  --ref <base-branch>  --repo <git-url>  --harness goose|opencode  --model provider/model
#
# TODO (ADR-078/081): migrate Pod → agent-sandbox Sandbox CR; scoped SA + RBAC; Cilium egress
# policy + auth-injecting proxy so the git/LLM tokens are INJECTED, never held in the pod. The
# egress policy must allow the nix cache (cache.nixos.org / a self-hosted attic) for `devbox install`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KUBE="--kubeconfig ${HERE}/../tofu/kubeconfig"
# kubectl isn't on the bare jail PATH (it's a devbox/nix tool); fall back to the devbox profile.
KUBECTL="$(command -v kubectl || true)"
[ -n "$KUBECTL" ] || KUBECTL="${HERE}/../.devbox/nix/profile/default/bin/kubectl"

PROJECT="${1:?usage: agent-session <project> [--run \"<cmd>\"] [--ref <branch>] [--repo <url>] [--harness goose|opencode] [--model provider/model]}"
shift || true

# Default to a real free coder model (the openrouter/free auto-router is flaky on strict output).
RUN_CMD=""; BASE_REF="master"; REPO_URL=""; HARNESS="opencode"; MODEL="openrouter/qwen/qwen3-coder:free"
while [ $# -gt 0 ]; do
  case "$1" in
    --run)     RUN_CMD="$2"; shift 2;;
    --ref)     BASE_REF="$2"; shift 2;;
    --repo)    REPO_URL="$2"; shift 2;;
    --harness) HARNESS="$2"; shift 2;;
    --model)   MODEL="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

NS="$PROJECT"
IMAGE="${HARNESS_IMAGE:-ghcr.io/teststuffstash/agent-base:latest}"
REPO_URL="${REPO_URL:-https://github.com/teststuffstash/${PROJECT}.git}"
SECRET="${PROJECT}-openrouter"          # operator-minted, budget-capped (e.g. sleep-tracking-openrouter)
POD="agent-${PROJECT}-$(date -u +%H%M%S)"
# goose's provider is GOOSE_PROVIDER, so drop the conventional openrouter/ prefix from the model id —
# BUT OpenRouter's own cloaked models (e.g. openrouter/owl-alpha) genuinely live UNDER that namespace,
# so only strip when a vendor/model slug remains (still has a '/'); otherwise keep the full id.
_stripped="${MODEL#openrouter/}"
case "$_stripped" in
  */*) GOOSE_MODEL="$_stripped" ;;   # qwen/qwen3-coder:free → drop prefix
  *)   GOOSE_MODEL="$MODEL" ;;       # openrouter/owl-alpha → keep (cloaked model is in the openrouter/ ns)
esac

if [ -n "$RUN_CMD" ]; then
  ARGS="[\"bash\",\"-c\",$(printf '%s' "$RUN_CMD" | jq -Rs .)]"
else
  ARGS="[\"sleep\",\"infinity\"]"       # idle after prep; you exec in below
fi

cat <<EOF | "$KUBECTL" $KUBE -n "$NS" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  labels: { app: agent-session, project: ${PROJECT} }
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 5
  containers:
    - name: agent
      image: ${IMAGE}
      args: ${ARGS}
      env:
        - name: REPO_URL
          value: "${REPO_URL}"
        - name: BASE_REF
          value: "${BASE_REF}"
        - name: HARNESS
          value: "${HARNESS}"
        # goose reads provider+model from env; opencode auto-detects OPENROUTER_API_KEY and takes
        # the model via \`-m \${MODEL}\` at run time (e.g. \`opencode run -m \$MODEL "…"\`).
        - name: GOOSE_PROVIDER
          value: "openrouter"
        - name: GOOSE_MODEL
          value: "${GOOSE_MODEL}"
        - name: MODEL
          value: "${MODEL}"
        # Auto-approve tool calls: a headless `--run` recipe has no TTY to confirm at, so without this
        # goose blocks forever. The pod is the isolation boundary, so autonomy here is the point.
        - name: GOOSE_MODE
          value: "auto"
        - name: OPENROUTER_API_KEY
          valueFrom:
            secretKeyRef: { name: ${SECRET}, key: OPENROUTER_API_KEY }
        # Scoped ~1h GitHub token minted by the ESO GithubAccessToken generator (per-project,
        # <project>/infra/agent/git-token.yaml) → clone private repos + push branch + open PR.
        # optional:true so sessions still work (public clone) before the agents App exists.
        # v2/ADR-081: injected by the egress proxy instead of held in the pod.
        - name: GH_TOKEN
          valueFrom:
            secretKeyRef: { name: agent-git-token, key: token, optional: true }
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000           # jetpackio/devbox 'devbox' user; numeric so k8s can verify non-root
        runAsGroup: 1000
        allowPrivilegeEscalation: false
        capabilities: { drop: ["ALL"] }
        seccompProfile: { type: RuntimeDefault }
      resources:
        requests: { cpu: "500m", memory: "1Gi" }
        limits:   { cpu: "2",    memory: "4Gi" }
EOF

echo "→ waiting for ${POD} (clone + project devbox install can be slow on a cold nix store)…"
"$KUBECTL" $KUBE -n "$NS" wait --for=condition=Ready pod/"${POD}" --timeout=300s || true

if [ -n "$RUN_CMD" ]; then
  "$KUBECTL" $KUBE -n "$NS" logs -f "${POD}"
  echo "→ run finished. delete with: kubectl -n ${NS} delete pod ${POD}"
else
  echo "→ attached at /work/repo. harnesses are wired to OpenRouter (model: ${MODEL}); try:"
  echo "    goose run -t \"<task>\"        # or: goose run --recipe .agents/fix.yaml --params issue=N"
  echo "    opencode -m \"\$MODEL\"          # TUI   |   opencode run -m \"\$MODEL\" \"<task>\"   # headless"
  echo "  exit leaves the pod up; remove with:  kubectl -n ${NS} delete pod ${POD}"
  "$KUBECTL" $KUBE -n "$NS" exec -it "${POD}" -- bash -c 'cd /work/repo 2>/dev/null; exec bash'
fi
