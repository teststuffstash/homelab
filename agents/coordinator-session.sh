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
TICK_PROMPT="You are running IN the coordinator pod: tools (gh/kubectl/python3/jq) are on PATH and called directly — there is NO devbox and NO tofu/kubeconfig here (kubectl auths via the pod ServiceAccount). Do ONE reconcile pass as the coordinator, per your brief (agents/coordinator/README.md). Re-list the world level-triggered, holding no state: open agent-fix issues across the stack repos (actionable = labelled agent/queued) and open PRs labelled major that are not yet major/awaiting-human (the coordinator-owned devbox-bump lane). Pick the single highest-priority actionable item; CLAIM it first (relabel + a one-line plan comment) before investigating; then take exactly the next action its state calls for per the brief. Keep every bit of state in GitHub labels and comments. Never merge by hand and never touch the review reflex armed PRs. If nothing is actionable, say so and stop."

RUN_CMD=""; SEED=""; STACK=""; STACK_REPOS=""; MAIN_REPO="homelab"; BASE_REF="master"; MODEL="opus"; PERM_MODE="bypassPermissions"; NO_ATTACH=""
REPO_URL="${REPO_URL:-https://github.com/teststuffstash/homelab.git}"
ORG="${ORG:-teststuffstash}"   # org the stack repos live under (for `gh repo clone <org>/<repo>`)
while [ $# -gt 0 ]; do
  case "$1" in
    --run)             RUN_CMD="$2"; shift 2;;
    --run-tick)        RUN_CMD="$TICK_PROMPT"; shift;;   # headless one tick (the reflex's call)
    --tick)            SEED="$TICK_PROMPT"; shift;;       # interactive, seeded with the canonical prompt
    --seed)            SEED="$2"; shift 2;;               # interactive, seeded with your prompt
    --stack)           STACK="$2"; shift 2;;              # scope this session to a stack (agents/stacks.json)
    --repos)           STACK_REPOS="$2"; shift 2;;        # the stack's repos, space-separated
    --main-repo)       MAIN_REPO="$2"; shift 2;;          # the stack's MAIN repo — cwd + its CLAUDE.md/specs (default homelab)
    --ref)             BASE_REF="$2"; shift 2;;
    --repo)            REPO_URL="$2"; shift 2;;
    --model)           MODEL="$2"; shift 2;;       # sonnet|opus|haiku|fable|<full-id>. Default opus (needs Max); --model sonnet to save.
    --permission-mode) PERM_MODE="$2"; shift 2;;   # default|acceptEdits|plan|auto|dontAsk|bypassPermissions
    --no-attach)       NO_ATTACH=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

# Per-stack scope (FU-045): prepend the stack context to the prompt so the coordinator knows exactly
# which repos are its world this session, and expose it as pod env for forward-compat. Policy will move
# to a Crossplane AgentStack claim in the stack's -iac repo (docs/agents/platform-and-stacks.md); for
# now coordinator-scan.sh passes --stack/--repos from agents/stacks.json.
if [ -n "$STACK" ]; then
  SCOPE="You are the coordinator for the ${STACK} stack; its repos are: ${STACK_REPOS:-see agents/stacks.json}, cloned at /work/<repo>; your cwd is the stack main repo ${MAIN_REPO}. Clones are READ-ONLY reference — your writes remain labels, comments, and merge state via gh. "
  [ -n "$RUN_CMD" ] && RUN_CMD="${SCOPE}${RUN_CMD}"
  [ -n "$SEED" ]    && SEED="${SCOPE}${SEED}"
fi

NS="agent-coordinator"
[ -f "$HERE/images.env" ] && . "$HERE/images.env" # pinned agent image versions (no :latest)
IMAGE="${COORDINATOR_IMAGE:-${AGENT_COORDINATOR_IMAGE:-ghcr.io/teststuffstash/agent-coordinator:latest}}"
POD="coordinator-$(date -u +%H%M%S)"
BRIEF="agents/coordinator/README.md"           # relative to /work/homelab (the poll waits on it there)
BRIEF_PATH="/work/homelab/${BRIEF}"            # ABSOLUTE: the cwd is now the stack main repo, not
                                               # necessarily /work/homelab, so the brief (platform
                                               # MECHANISM) must be referenced by full path (FU-045).

# The model/permission flags shared by both modes. The pod IS the isolation boundary (scoped
# SA/RBAC, per-session OpenRouter/git tokens, NO secret-value access) — security lives there, not in
# per-command approval — so the agent runs with permissions skipped by default, like the jail. The
# `--permission-mode bypassPermissions` FLAG form suppresses the one-time bypass dialog (settings'
# defaultMode does NOT — anthropics/claude-code#52501). Pass `--permission-mode default` for a
# supervised session. (rm -rf / and ~ still trip hard circuit breakers; deny rules + hooks still
# apply, regardless of mode.)
COMMON_FLAGS="--model ${MODEL} --append-system-prompt-file ${BRIEF_PATH} --permission-mode ${PERM_MODE}"

# Clone the current homelab (public) so the coordinator runs the live brief + launchers + estimator.
# The /work/session-start marker is the "what did THIS session write" baseline the exit-trap upload
# diffs the transcripts PVC against (the PVC accumulates across sessions).
PREP="set -e; touch /work/session-start; git clone --depth 1 -b ${BASE_REF} ${REPO_URL} /work/homelab"

# FU-045: a coordinator is scoped to a STACK, so clone ALL its repos (--repos) shallow into /work/<repo>
# and run from the stack's MAIN repo (--main-repo, default homelab) — so that repo's CLAUDE.md + specs
# load naturally as cwd context. homelab is already cloned above (skip it). Private repos (oracle-*)
# authenticate via the pod's GH_TOKEN, which `gh repo clone` inherits — so use gh, not bare git. Each
# clone is guarded `|| echo …`: a failed/optional repo is logged LOUDLY but is NON-FATAL (it must not
# kill the tick), and the coordinator falls back to the repo's GitHub URL. Repo names are baked in
# literally (like ${REPO_URL}/${BASE_REF} above), so nothing relies on pod-side var expansion.
CLONE_STEPS=""
for repo in $STACK_REPOS; do
  [ "$repo" = "homelab" ] && continue
  CLONE_STEPS="${CLONE_STEPS}; if [ -d /work/${repo} ]; then echo \"→ ${repo} already present\"; else echo \"→ cloning ${repo}…\"; gh repo clone ${ORG}/${repo} /work/${repo} -- --depth 1 || echo \"⚠ clone of ${repo} FAILED (non-fatal) — coordinator uses its GitHub URL instead\"; fi"
done
# Only surface gh auth (and clone) when there's actually a private/extra repo to fetch. `gh repo clone`
# needs the pod's GH_TOKEN (coordinator-git) to reach the private oracle-* repos — verify it's wired
# before relying on it (non-fatal: public repos clone anonymously anyway).
if [ -n "$CLONE_STEPS" ]; then
  PREP="${PREP}; echo '→ gh auth (for private stack repos):'; gh auth status 2>&1 | head -3 || echo '⚠ gh not authed — private stack repos may fail to clone'${CLONE_STEPS}"
fi
# cd into the stack's main repo — but if its clone FAILED (private repo the token can't reach yet),
# fall back to /work/homelab rather than dying under `set -e`: a missing repo must never kill the tick.
PREP="${PREP}; cd /work/${MAIN_REPO} 2>/dev/null || { echo \"⚠ main repo ${MAIN_REPO} not cloned — falling back to cwd /work/homelab\"; cd /work/homelab; }"

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

# §A1 transcript capture (docs/agents/observability-and-retro.md): mirror the session's NEW
# transcript JSONL (vs the /work/session-start marker) from the transcripts PVC to the
# agent-transcripts bucket. Defined as a FUNCTION snippet used two ways: headless pods run it
# in-pod after claude (the pod runs to completion — an exec from outside can't reach it anymore);
# interactive pods stay up (sleep infinity), so the launcher's exit trap execs it. Best-effort by
# design: a failed upload never fails the session; the nightly transcripts-sync CronJob is the
# crash net. Single-quoted heredoc: everything resolves from POD env at upload time.
UPLOAD_FN=$(cat <<'SNIP'
upload_transcripts() {
  [ -n "${AGENT_TS_ACCESS_KEY_ID:-}" ] || { echo "transcripts: no S3 key in pod (agent-transcripts-s3 Secret absent?) — upload skipped"; return 0; }
  command -v s5cmd >/dev/null 2>&1 || { echo "transcripts: s5cmd not in this image — upload skipped (bump AGENT_COORDINATOR_IMAGE)"; return 0; }
  # cwd-agnostic (FU-045): Claude's project dir slug tracks the cwd (e.g. -work-oracle-fleet vs
  # -work-homelab), but discovery is by mtime vs the session-start marker, so the slug never matters.
  FILES=$(find /home/node/.claude/projects -name '*.jsonl' -newer /work/session-start 2>/dev/null)
  [ -n "$FILES" ] || { echo "transcripts: no new session files — nothing to upload"; return 0; }
  TS=$(date -u +%Y%m%dT%H%M%SZ)
  # FU-061: project = the stack's MAIN repo (not the STACK name — the old oracle/tick-* split
  # scattered one issue's work across "oracle" vs "oracle-fleet"); task = _ticks (a coordinator tick
  # is a reconcile pass, not tied to one issue). Bucket key <project>/_ticks/coordinator-r1-<ts>/.
  PREFIX="s3://${AGENT_TS_BUCKET}/${MAIN_REPO:-homelab}/_ticks/coordinator-r1-${TS}"
  export AWS_ACCESS_KEY_ID="$AGENT_TS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AGENT_TS_SECRET_ACCESS_KEY" AWS_REGION=garage
  jq -n --arg role coordinator --arg project "${MAIN_REPO:-homelab}" --arg task "_ticks" --arg stack "${STACK:-}" \
        --arg model "${MODEL:-}" --arg key coordinator-claude --arg pod "${HOSTNAME:-}" --arg files "$FILES" \
        '{role:$role, project:$project, task:$task, stack:$stack, round:1, model:$model, session_key:$key, pod:$pod,
          files:($files|split("\n")|map(sub(".*/";""))), grafana_query:("{pod=\""+$pod+"\"}")}' > /tmp/manifest.json
  for f in $FILES; do
    s5cmd --endpoint-url "$AGENT_TS_ENDPOINT" cp "$f" "${PREFIX}/$(basename "$f")" || echo "transcripts: upload FAILED for $f (non-fatal)"
  done
  s5cmd --endpoint-url "$AGENT_TS_ENDPOINT" cp /tmp/manifest.json "${PREFIX}/manifest.json" || echo "transcripts: manifest upload FAILED (non-fatal)"
  echo "transcripts: uploaded → ${PREFIX}"
}
SNIP
)

if [ -n "$RUN_CMD" ]; then
  # Headless: claude runs to completion, then the pod itself uploads (no exec window afterwards).
  WRAPPED="${PREP}
${UPLOAD_FN}
set +e; claude -p ${COMMON_FLAGS} $(printf '%s' "$RUN_CMD" | jq -Rs .); RC=\$?; upload_transcripts; exit \$RC"
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
        # Per-stack scope (FU-045): which stack + repos this coordinator owns this session, and the
        # stack's main repo (the cwd). Exposed as env for forward-compat with the AgentStack claim.
        - name: STACK
          value: "${STACK}"
        - name: AGENT_REPOS
          value: "${STACK_REPOS}"
        - name: MAIN_REPO
          value: "${MAIN_REPO}"
        # Provenance for the transcript manifest (docs/agents/observability-and-retro.md §A1).
        - name: MODEL
          value: "${MODEL}"
        # A0 standard rail: Claude Code exports OTLP metrics+logs (GenAI conventions) to the
        # in-cluster collector (argocd/resources/otel-collector/) → Loki + Prometheus. Telemetry
        # only — transcripts stay the durable record. Override endpoint with OTLP_ENDPOINT.
        - name: CLAUDE_CODE_ENABLE_TELEMETRY
          value: "1"
        - name: OTEL_METRICS_EXPORTER
          value: "otlp"
        - name: OTEL_LOGS_EXPORTER
          value: "otlp"
        - name: OTEL_EXPORTER_OTLP_PROTOCOL
          value: "http/protobuf"
        - name: OTEL_EXPORTER_OTLP_ENDPOINT
          value: "${OTLP_ENDPOINT:-http://otel-collector.monitoring.svc.cluster.local:4318}"
        - name: OTEL_RESOURCE_ATTRIBUTES
          value: "service.name=claude-code,role=coordinator,stack=${STACK:-none}"
        # Transcript capture (§A1): the WRITE-ONLY key for the agent-transcripts bucket, same-ns
        # Secret written by the Crossplane Workspace (agents/coordinator/garage-workspace.yaml).
        # optional:true → sessions still run before the Workspace has reconciled (upload skips).
        - name: AGENT_TS_ENDPOINT
          value: "http://garage.garage.svc.cluster.local:3900"
        - name: AGENT_TS_BUCKET
          value: "agent-transcripts"
        - name: AGENT_TS_ACCESS_KEY_ID
          valueFrom:
            secretKeyRef: { name: agent-transcripts-s3, key: writer_access_key_id, optional: true }
        - name: AGENT_TS_SECRET_ACCESS_KEY
          valueFrom:
            secretKeyRef: { name: agent-transcripts-s3, key: writer_secret_access_key, optional: true }
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

# Interactive sessions: the pod stays up (sleep infinity), so when THIS launcher exits (user left
# claude / detached), exec the upload function in the pod. Headless pods upload in-pod instead —
# their container has already run to completion by the time the launcher exits.
if [ -z "$RUN_CMD" ]; then
  upload_transcripts_via_exec() {
    "$KUBECTL" $KUBE -n "$NS" exec "${POD}" -- bash -lc "${UPLOAD_FN}
upload_transcripts" \
      || echo "→ transcript upload skipped (pod gone or upload failed — the nightly sync covers it)"
  }
  trap 'exit 130' INT TERM   # convert signals to a normal exit so the EXIT trap below still runs
  trap upload_transcripts_via_exec EXIT
fi

if [ -n "$RUN_CMD" ]; then
  "$KUBECTL" $KUBE -n "$NS" logs -f "${POD}" || true
  echo "→ pass finished. delete with: kubectl -n ${NS} delete pod ${POD}"
else
  # `wait --for=condition=Ready` fires the instant the container process starts — it does NOT gate on
  # the in-container `git clone` (headless sequences clone→claude in one command, but the interactive
  # attach is a separate exec that can outrun the clone). Poll for the brief file so we never attach
  # `claude --append-system-prompt-file ${BRIEF}` before the clone has written it.
  "$KUBECTL" $KUBE -n "$NS" exec "${POD}" -- bash -lc "until [ -f ${BRIEF_PATH} ]; do sleep 0.5; done" 2>/dev/null || true
  ATTACH="kubectl --kubeconfig tofu/kubeconfig -n ${NS} exec -it ${POD} -- bash -lc 'cd /work/${MAIN_REPO} 2>/dev/null || cd /work/homelab; exec claude ${COMMON_FLAGS}${SEED_SUFFIX}'"
  echo "→ coordinator pod ${POD} ready (brief: ${BRIEF}; model: ${MODEL}${SEED:+; seeded})."
  if [ -n "$NO_ATTACH" ]; then
    echo "→ attach the interactive coordinator from a real terminal:"
    echo "    ${ATTACH}"
    echo "  remove when done:  kubectl --kubeconfig tofu/kubeconfig -n ${NS} delete pod ${POD}"
  else
    echo "  exit leaves the pod up; remove with:  kubectl -n ${NS} delete pod ${POD}"
    "$KUBECTL" $KUBE -n "$NS" exec -it "${POD}" -- bash -lc 'cd /work/'"${MAIN_REPO}"' 2>/dev/null || cd /work/homelab; exec claude '"${COMMON_FLAGS}${SEED_SUFFIX}"
  fi
fi
