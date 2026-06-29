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
RUN_CMD=""; BASE_REF="master"; REPO_URL=""; HARNESS="opencode"; MODEL="openrouter/qwen/qwen3-coder:free"; NO_ATTACH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run)       RUN_CMD="$2"; shift 2;;
    --ref)       BASE_REF="$2"; shift 2;;
    --repo)      REPO_URL="$2"; shift 2;;
    --harness)   HARNESS="$2"; shift 2;;
    --model)     MODEL="$2"; shift 2;;
    --no-attach) NO_ATTACH=1; shift;;   # interactive: create + prep the pod, print the attach cmd, don't exec
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
  # Run the harness, tee its output to a file, then emit the AGENT_RUN_STATS line (agent-finalize
  # parses the run's structured outcome from that file + computes cost/duration). `set +e` so a
  # harness failure still runs finalize; the tee keeps the live stream intact for `kubectl logs -f`.
  WRAPPED="set +e; { ${RUN_CMD} ; } 2>&1 | tee /tmp/run.log; agent-finalize /tmp/run.log"
  ARGS="[\"bash\",\"-c\",$(printf '%s' "$WRAPPED" | jq -Rs .)]"
else
  ARGS="[\"sleep\",\"infinity\"]"       # idle after prep; you exec in below
fi

# Persistent uv (PyPI wheel) cache: if a `agent-uv-cache` PVC exists in the namespace, mount it so
# `devbox run ci`'s `uv sync` fetches wheels once across runs (the nix cache only covers `devbox
# install`). Optional — projects without the PVC just get an ephemeral cache. RWX so concurrent
# agent pods can share it; fsGroup below makes it writable for the non-root user.
UV_MOUNT=""; UV_VOLUME=""
if "$KUBECTL" $KUBE -n "$NS" get pvc agent-uv-cache >/dev/null 2>&1; then
  UV_MOUNT=$'      volumeMounts:\n        - { name: uv-cache, mountPath: /uv-cache }'
  UV_VOLUME=$'  volumes:\n    - name: uv-cache\n      persistentVolumeClaim: { claimName: agent-uv-cache }'
fi

# opencode's Bun runtime needs AVX2 → it SIGILLs ("Illegal instruction") on the older homelab CPUs
# (hp-01, thinkcentre). goose (Rust) runs anywhere. Pin opencode pods to AVX2-capable nodes via the
# homelab.io/cpu-avx2 label (the Proxmox VMs + the Haswell/Broadwell ThinkPads carry it). NB: that
# label is currently set imperatively — codify it in Talos machine.nodeLabels so it survives a node
# reinstall (boot-from-git follow-up).
AFFINITY=""
if [ "$HARNESS" = "opencode" ]; then
  AFFINITY=$'  affinity:\n    nodeAffinity:\n      requiredDuringSchedulingIgnoredDuringExecution:\n        nodeSelectorTerms:\n          - matchExpressions:\n              - { key: homelab.io/cpu-avx2, operator: In, values: ["true"] }'
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
${AFFINITY}
  securityContext:
    fsGroup: 1000          # make the shared uv-cache RWX volume writable for the non-root (1000) user
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
        # Stats context for agent-finalize (project label + which node it ran on).
        - name: PROJECT
          value: "${PROJECT}"
        - name: NODE_NAME
          valueFrom:
            fieldRef: { fieldPath: spec.nodeName }
        # goose reads provider+model from env; opencode auto-detects OPENROUTER_API_KEY and takes
        # the model via \`-m \${MODEL}\` at run time (e.g. \`opencode run -m \$MODEL "…"\`).
        - name: GOOSE_PROVIDER
          value: "openrouter"
        - name: GOOSE_MODEL
          value: "${GOOSE_MODEL}"
        - name: MODEL
          value: "${MODEL}"
        # Persistent uv wheel cache (mounted only if the agent-uv-cache PVC exists; harmless otherwise).
        - name: UV_CACHE_DIR
          value: "/uv-cache"
        # Auto-approve tool calls: a headless --run recipe has no TTY to confirm at, so without this
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
        limits:   { cpu: "6",    memory: "4Gi" }   # install is partly CPU-bound; allow burst past 2
${UV_MOUNT}
${UV_VOLUME}
EOF

echo "→ waiting for ${POD} (clone + project devbox install can be slow on a cold nix store)…"
"$KUBECTL" $KUBE -n "$NS" wait --for=condition=Ready pod/"${POD}" --timeout=300s || true

if [ -n "$RUN_CMD" ]; then
  RUNLOG="$(mktemp)"
  "$KUBECTL" $KUBE -n "$NS" logs -f "${POD}" | tee "$RUNLOG"
  echo "→ run finished. delete with: kubectl -n ${NS} delete pod ${POD}"

  # End-of-session stats: agent-finalize emitted one AGENT_RUN_STATS json line into the logs (cost,
  # duration, model, and the recipe's outcome). Echo it, and if a PR was opened, post it as a PR
  # comment with a Grafana Explore deep-link to THIS pod's logs — so reviewing the PR is one click
  # from both the stats and the full run logs (no more guessing the pod name). Posted from here (the
  # jail GH_TOKEN can comment) rather than the pod (scoped agent token may lack issues:write).
  STATS="$(grep -ao 'AGENT_RUN_STATS .*' "$RUNLOG" | tail -1 | sed 's/^AGENT_RUN_STATS //')"
  if [ -n "$STATS" ]; then
    echo "→ stats: $STATS"
    PR_URL="$(printf '%s' "$STATS" | jq -r '.pr_url // empty' 2>/dev/null)"
    if [ -n "$PR_URL" ] && [ -n "${GH_TOKEN:-}" ]; then
      GRAFANA_URL="${GRAFANA_URL:-https://grafana.teststuff.net}"
      PANES="$(jq -cn --arg pod "$POD" '{ag:{datasource:"loki",queries:[{refId:"A",expr:("{pod=\""+$pod+"\"}"),datasource:{type:"loki",uid:"loki"}}],range:{from:"now-6h",to:"now"}}}')"
      LOGS_URL="${GRAFANA_URL}/explore?schemaVersion=1&orgId=1&panes=$(jq -rn --arg p "$PANES" '$p|@uri')"
      BODY="$(printf '%s' "$STATS" | jq -r --arg logs "$LOGS_URL" '
        "🤖 **Agent run stats**\n\n" +
        "| metric | value |\n|---|---|\n" +
        "| model | `\(.model // "?")` (\(.harness // "?")) |\n" +
        "| cost | $\(.cost_usd // 0) |\n" +
        "| duration | \(.duration_s // 0)s |\n" +
        "| reproduced | \(.reproduced // "?") |\n" +
        "| ci_passed | \(.ci_passed // "?") |\n" +
        "| coverage | \(.coverage_pct // "?")% |\n" +
        "| node / pod | `\(.node // "?")` / `\(.pod // "?")` |\n\n" +
        "[📜 run logs in Grafana](\($logs))"')"
      echo "→ posting stats comment to ${PR_URL}"
      gh pr comment "$PR_URL" --body "$BODY" 2>&1 | tail -1 || echo "  (comment failed — non-fatal)"
    fi
  fi
  rm -f "$RUNLOG"
else
  ATTACH="kubectl --kubeconfig tofu/kubeconfig -n ${NS} exec -it ${POD} -- bash -c 'cd /work/repo; exec bash -l'"
  echo "→ pod ${POD} ready at /work/repo. harnesses are wired to OpenRouter (model: ${MODEL}); try:"
  echo "    goose run -t \"<task>\"        # or: goose run --recipe .agents/fix.yaml --params issue=N"
  echo "    opencode -m \"\$MODEL\"          # TUI   |   opencode run -m \"\$MODEL\" \"<task>\"   # headless"
  if [ -n "$NO_ATTACH" ]; then
    # A non-TTY caller (orchestrator / jail agent) can prep the pod; you attach the TUI from YOUR
    # terminal. Re-runnable — attach, detach, re-attach without recreating the pod.
    echo "→ attach the interactive TUI from a real terminal:"
    echo "    ${ATTACH}"
    echo "  remove when done:  kubectl --kubeconfig tofu/kubeconfig -n ${NS} delete pod ${POD}"
  else
    echo "  exit leaves the pod up; remove with:  kubectl -n ${NS} delete pod ${POD}"
    "$KUBECTL" $KUBE -n "$NS" exec -it "${POD}" -- bash -c 'cd /work/repo 2>/dev/null; exec bash'
  fi
fi
