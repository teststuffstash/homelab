#!/usr/bin/env bash
# coordinator-session — run Claude Code as the coordinator in a scoped pod, and attach.
#
# The coordinator is the cockpit's brain (brief: agents/coordinator/README.md). This launcher is the
# sibling of agent-session.sh: where that spawns a per-PROJECT *worker* pod, this spawns the single
# *coordinator* pod — Claude Code, the homelab repo cloned in, subscription auth, and a ServiceAccount
# scoped (rbac.yaml) to spawn workers + mint per-session budget keys. Interactive and headless are the
# same pod; only the command differs.
#
#   bash agents/coordinator-session.sh
#       → interactive: clone homelab, drop you into `claude` loaded with the coordinator brief.
#   bash agents/coordinator-session.sh --tick
#       → interactive, but SEEDED with the canonical reconcile-tick prompt (the exact instruction a
#         future coordinator reflex would inject) as the first turn — supervise the first runs.
#   bash agents/coordinator-session.sh --seed "Work PR #18 on sleep-tracking to major/awaiting-human."
#       → interactive, seeded with YOUR prompt (scope a first run to one item).
#   bash agents/coordinator-session.sh --run "Do one reconcile pass over open agent-fix issues."
#       → headless: `claude -p` runs one pass and the pod self-terminates.
#   bash agents/coordinator-session.sh --run-tick
#       → headless one tick with the canonical prompt — what the eventual reflex CronJob calls.
#
# Bootstrap once (see agents/coordinator/README.md §Bootstrap):
#   kubectl --kubeconfig tofu/kubeconfig apply -f agents/coordinator/rbac.yaml
#   kubectl -n agent-coordinator create secret generic coordinator-claude \
#       --from-literal=CLAUDE_CODE_OAUTH_TOKEN="$(claude setup-token)"   # ~1y subscription token
#   kubectl -n agent-coordinator create secret generic coordinator-git \
#       --from-literal=GH_TOKEN="<a token that can read/label issues + merge PRs>"
#   # the image is built+pushed by CI in the teststuffstash/agent-coordinator repo — no manual build.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KUBE="--kubeconfig ${HERE}/../tofu/kubeconfig"
# kubectl isn't on the bare jail PATH (devbox/nix tool); fall back to the devbox profile.
KUBECTL="$(command -v kubectl || true)"
[ -n "$KUBECTL" ] || KUBECTL="${HERE}/../.devbox/nix/profile/default/bin/kubectl"

# The canonical reconcile-TICK prompt — the exact instruction a future coordinator reflex (a CronJob,
# the LLM sibling of review-reflex.sh) would inject each tick. Kept here as ONE source of truth so an
# interactive first-run (--tick) and the eventual headless reflex (--run-tick) use identical wording.
# Level-triggered, covers BOTH lanes (agent-fix issues + the coordinator-owned `major` devbox PRs).
TICK_PROMPT="Do ONE reconcile pass as the coordinator, per your brief (agents/coordinator/README.md). Re-list the world level-triggered, holding no state: open agent-fix issues across the stack repos (actionable = labelled agent/queued) and open PRs labelled major that are not yet major/awaiting-human (the coordinator-owned devbox-bump lane). Pick the single highest-priority actionable item; CLAIM it first (relabel + a one-line plan comment) before investigating; then take exactly the next action its state calls for per the brief. Keep every bit of state in GitHub labels and comments. Never merge by hand and never touch the review reflex armed PRs. If nothing is actionable, say so and stop."

RUN_CMD=""; SEED=""; BASE_REF="master"; MODEL="sonnet"; PERM_MODE="bypassPermissions"; NO_ATTACH=""
REPO_URL="${REPO_URL:-https://github.com/teststuffstash/homelab.git}"
while [ $# -gt 0 ]; do
  case "$1" in
    --run)             RUN_CMD="$2"; shift 2;;
    --run-tick)        RUN_CMD="$TICK_PROMPT"; shift;;   # headless one tick (the reflex's call)
    --tick)            SEED="$TICK_PROMPT"; shift;;       # interactive, seeded with the canonical prompt
    --seed)            SEED="$2"; shift 2;;               # interactive, seeded with your prompt
    --ref)             BASE_REF="$2"; shift 2;;
    --repo)            REPO_URL="$2"; shift 2;;
    --model)           MODEL="$2"; shift 2;;       # sonnet|opus|haiku|fable|<full-id>. Pro ⇒ sonnet.
    --permission-mode) PERM_MODE="$2"; shift 2;;   # default|acceptEdits|plan|auto|dontAsk|bypassPermissions
    --no-attach)       NO_ATTACH=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

NS="agent-coordinator"
IMAGE="${COORDINATOR_IMAGE:-ghcr.io/teststuffstash/agent-coordinator:latest}"
POD="coordinator-$(date -u +%H%M%S)"
BRIEF="agents/coordinator/README.md"   # loaded as Claude's appended system prompt

# The model/permission flags shared by both modes. The pod IS the isolation boundary (scoped
# SA/RBAC, per-session OpenRouter/git tokens, NO secret-value access) — security lives there, not in
# per-command approval — so the agent runs with permissions skipped by default, like the jail. The
# `--permission-mode bypassPermissions` FLAG form suppresses the one-time bypass dialog (settings'
# defaultMode does NOT — anthropics/claude-code#52501). Pass `--permission-mode default` for a
# supervised session. (rm -rf / and ~ still trip hard circuit breakers; deny rules + hooks still
# apply, regardless of mode.)
COMMON_FLAGS="--model ${MODEL} --append-system-prompt-file ${BRIEF} --permission-mode ${PERM_MODE}"

# Clone the current homelab (public) so the coordinator runs the live brief + launchers + estimator.
PREP="set -e; git clone --depth 1 -b ${BASE_REF} ${REPO_URL} /work/homelab; cd /work/homelab"

# Interactive seed (--tick/--seed): drop the prompt into a pod file at clone time, then attach with it
# as claude's initial positional arg (`claude … "$(cat /work/coord-seed)"` = interactive, seeded). The
# file indirection keeps the (possibly long, quote-bearing) prompt out of the exec command line — the
# value is base64'd through PREP so ANY prompt is quote-safe. RUN_CMD (headless) ignores SEED.
SEED_SUFFIX=""
if [ -z "$RUN_CMD" ] && [ -n "$SEED" ]; then
  SEED_B64="$(printf '%s' "$SEED" | base64 | tr -d '\n')"
  PREP="${PREP}; printf %s '${SEED_B64}' | base64 -d > /work/coord-seed"
  SEED_SUFFIX=' "$(cat /work/coord-seed)"'
fi

if [ -n "$RUN_CMD" ]; then
  WRAPPED="${PREP}; exec claude -p ${COMMON_FLAGS} $(printf '%s' "$RUN_CMD" | jq -Rs .)"
  ARGS="[\"bash\",\"-lc\",$(printf '%s' "$WRAPPED" | jq -Rs .)]"
else
  ARGS="[\"bash\",\"-lc\",$(printf '%s' "${PREP}; sleep infinity" | jq -Rs .)]"
fi

cat <<EOF | "$KUBECTL" $KUBE -n "$NS" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  labels: { app: agent-coordinator }
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 5
  serviceAccountName: agent-coordinator
  containers:
    - name: coordinator
      image: ${IMAGE}
      args: ${ARGS}
      env:
        - name: HOME
          value: "/home/node"
        # Subscription auth (Pro/Max): a ~1y token from \`claude setup-token\`, kept in a Secret.
        # NB: do NOT also set ANTHROPIC_API_KEY here — it would take auth precedence over this.
        - name: CLAUDE_CODE_OAUTH_TOKEN
          valueFrom:
            secretKeyRef: { name: coordinator-claude, key: CLAUDE_CODE_OAUTH_TOKEN, optional: true }
        # gh/git ops: read+label issues, open/merge PRs across the project repos. The coordinator-git
        # token is a ~1h GitHub App token that ESO re-mints ~hourly — too short for a long session if
        # frozen as an env var. So ALSO mount it as a file (below) and point the image's gh-wrapper at
        # it via GH_TOKEN_FILE; the wrapper reads the LIVE token per call. The env stays as a fallback
        # for the pre-wrapper image.
        - name: GH_TOKEN
          valueFrom:
            secretKeyRef: { name: coordinator-git, key: GH_TOKEN, optional: true }
        - name: GH_TOKEN_FILE
          value: "/var/run/coordinator-git/GH_TOKEN"
      volumeMounts:
        - { name: coordinator-git, mountPath: /var/run/coordinator-git, readOnly: true }
        # Persist Claude Code session transcripts (the interactive session's only "log"). Mounts a
        # subdir of ~/.claude so the image-baked settings.json / .claude.json are untouched.
        - { name: transcripts, mountPath: /home/node/.claude/projects }
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        allowPrivilegeEscalation: false
        capabilities: { drop: ["ALL"] }
        seccompProfile: { type: RuntimeDefault }
      resources:
        requests: { cpu: "250m", memory: "512Mi" }
        limits:   { cpu: "2",    memory: "2Gi" }
  securityContext:
    fsGroup: 1000          # make the RWX transcripts volume writable for the non-root (1000) user
  volumes:
    # kubelet keeps a mounted Secret current as ESO re-mints it (~1min lag) — the gh-wrapper reads the
    # live token from here so a multi-hour session never uses a stale 1h token.
    - name: coordinator-git
      secret: { secretName: coordinator-git, optional: true }
    # Durable, shared transcript store (RWX) — survives pod deletion, accumulates across sessions.
    # optional via a claim that must exist; if absent, the pod won't start, so it's part of bootstrap.
    - name: transcripts
      persistentVolumeClaim: { claimName: coordinator-transcripts }
EOF

echo "→ waiting for ${POD} (clone)…"
"$KUBECTL" $KUBE -n "$NS" wait --for=condition=Ready pod/"${POD}" --timeout=180s || true

if [ -n "$RUN_CMD" ]; then
  "$KUBECTL" $KUBE -n "$NS" logs -f "${POD}" || true
  echo "→ pass finished. delete with: kubectl -n ${NS} delete pod ${POD}"
else
  # `wait --for=condition=Ready` fires the instant the container process starts — it does NOT gate on
  # the in-container `git clone` (headless sequences clone→claude in one command, but the interactive
  # attach is a separate exec that can outrun the clone). Poll for the brief file so we never attach
  # `claude --append-system-prompt-file ${BRIEF}` before the clone has written it.
  "$KUBECTL" $KUBE -n "$NS" exec "${POD}" -- bash -lc "until [ -f /work/homelab/${BRIEF} ]; do sleep 0.5; done" 2>/dev/null || true
  ATTACH="kubectl --kubeconfig tofu/kubeconfig -n ${NS} exec -it ${POD} -- bash -lc 'cd /work/homelab; exec claude ${COMMON_FLAGS}${SEED_SUFFIX}'"
  echo "→ coordinator pod ${POD} ready (brief: ${BRIEF}; model: ${MODEL}${SEED:+; seeded})."
  if [ -n "$NO_ATTACH" ]; then
    echo "→ attach the interactive coordinator from a real terminal:"
    echo "    ${ATTACH}"
    echo "  remove when done:  kubectl --kubeconfig tofu/kubeconfig -n ${NS} delete pod ${POD}"
  else
    echo "  exit leaves the pod up; remove with:  kubectl -n ${NS} delete pod ${POD}"
    "$KUBECTL" $KUBE -n "$NS" exec -it "${POD}" -- bash -lc 'cd /work/homelab; exec claude '"${COMMON_FLAGS}${SEED_SUFFIX}"
  fi
fi
