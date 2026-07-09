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
# FU-019 (ADR-078): migrate Pod → agent-sandbox Sandbox CR; scoped SA + RBAC. FU-020/FU-018
# (ADR-081): Cilium egress policy + auth-injecting proxy so the git/LLM tokens are INJECTED, never
# held in the pod; the egress policy must allow the nix cache for `devbox install`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Jail (cockpit) uses tofu/kubeconfig; inside the coordinator pod there is no such file, so fall
# back to the pod's in-cluster ServiceAccount (KUBE empty → kubectl auto-detects in-cluster config).
if [ -f "${HERE}/../tofu/kubeconfig" ]; then KUBE="--kubeconfig ${HERE}/../tofu/kubeconfig"; else KUBE=""; fi
# kubectl isn't on the bare jail PATH (it's a devbox/nix tool); fall back to the devbox profile, then
# to a PATH kubectl (the coordinator image ships one).
KUBECTL="$(command -v kubectl || true)"
[ -n "$KUBECTL" ] || KUBECTL="${HERE}/../.devbox/nix/profile/default/bin/kubectl"
[ -x "$KUBECTL" ] || KUBECTL="kubectl"

PROJECT="${1:?usage: agent-session <project> [--run \"<cmd>\"] [--ref <branch>] [--repo <url>] [--harness goose|opencode] [--model provider/model]}"
shift || true

# Default to a cheap, multi-provider, CACHED model bounded by the per-session budget cap. The
# per-stack chain (primary + fallbacks) lives in agents/stacks.json; an infra failure here costs one
# STRIKE (re-dispatch on the next chain model), so free/new entries are fair — see
# docs/agents/model-routing.md. Still avoid CLOAKED models as primary (rotated out → 404s mid-run).
RUN_CMD=""; BASE_REF="master"; REPO_URL=""; HARNESS="opencode"; MODEL="openrouter/deepseek/deepseek-v4-flash"; NO_ATTACH=""; OR_SECRET=""; TASK=""; ROUND="1"
while [ $# -gt 0 ]; do
  case "$1" in
    --run)       RUN_CMD="$2"; shift 2;;
    --ref)       BASE_REF="$2"; shift 2;;
    --repo)      REPO_URL="$2"; shift 2;;
    --harness)   HARNESS="$2"; shift 2;;
    --model)     MODEL="$2"; shift 2;;
    --openrouter-secret) OR_SECRET="$2"; shift 2;;  # use a per-SESSION budget key Secret (the coordinator's ephemeral OpenRouterKey) instead of the shared <project>-openrouter
    --task)      TASK="$2"; shift 2;;   # transcript-capture task key: issue-<n> | pr-<n> (§A1 bucket prefix)
    --round)     ROUND="$2"; shift 2;;  # worker round on that task (prefix worker-r<N>)
    --no-attach) NO_ATTACH=1; shift;;   # interactive: create + prep the pod, print the attach cmd, don't exec
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
# Without an explicit --task (interactive/ad-hoc runs) the transcript still lands somewhere findable.
TASK="${TASK:-adhoc-$(date -u +%Y%m%dT%H%M%SZ)}"

NS="$PROJECT"
[ -f "$HERE/images.env" ] && . "$HERE/images.env" # pinned agent image versions (no :latest)
IMAGE="${HARNESS_IMAGE:-${AGENT_BASE_IMAGE:-ghcr.io/teststuffstash/agent-base:latest}}"
REPO_URL="${REPO_URL:-https://github.com/teststuffstash/${PROJECT}.git}"
SECRET="${OR_SECRET:-${PROJECT}-openrouter}"  # operator-minted, budget-capped. Default: the shared standing key; the coordinator passes --openrouter-secret to bind a per-session ephemeral key instead
POD="agent-${PROJECT}-$(date -u +%H%M%S)"
# goose's provider is GOOSE_PROVIDER, so drop the conventional openrouter/ prefix from the model id —
# BUT OpenRouter's own *cloaked* models (e.g. a bare `openrouter/<codename>`) genuinely live UNDER
# that namespace, so only strip when a vendor/model slug remains (still has a '/'); otherwise keep it.
_stripped="${MODEL#openrouter/}"
case "$_stripped" in
  */*) GOOSE_MODEL="$_stripped" ;;   # openrouter/deepseek/deepseek-v4-flash → deepseek/deepseek-v4-flash
  *)   GOOSE_MODEL="$MODEL" ;;       # openrouter/<cloaked-codename> → keep (it's in the openrouter/ ns)
esac

# ADR-081 v1 (FU-062 §M4, GOOSE ONLY): goose cannot carry OpenRouter `provider` prefs, so its
# OpenRouter traffic rides the in-cluster egress proxy, which injects the per-model provider pin
# into chat/completions bodies (argocd/resources/openrouter-proxy/ — provider-injection only in
# v1; cred injection + Cilium lockdown stay FU-018/FU-020). Opt out with
# AGENT_OPENROUTER_PROXY="" for direct egress (e.g. the proxy is down and it's striking runs).
GOOSE_PROXY_ENV=""
if [ "$HARNESS" = "goose" ]; then
  PROXY_URL="${AGENT_OPENROUTER_PROXY-http://openrouter-proxy.agent-egress.svc.cluster.local:8080}"
  if [ -n "$PROXY_URL" ]; then
    GOOSE_PROXY_ENV=$'        - name: OPENROUTER_HOST\n          value: "'"$PROXY_URL"'"'
  fi
fi

# FU-018 interim leg (FU-062 / model-routing.md §M4, OPENCODE ONLY): the prompt cache lives at the
# provider, so per-request provider roulette destroys it — pin the SESSION to the registry's
# effective-cheapest cache-supporting tools-capable provider. Rendered as a per-session opencode
# config (OPENCODE_CONFIG merges under the repo's own opencode.json, so a project override wins);
# allow_fallbacks:true keeps the run alive if the pin is down, and max_price (2× the pinned
# provider's headline prompt $/M) blocks the expensive-lottery fallback (the $5.79 qwen incident).
# goose deliberately gets NOTHING here — it cannot carry provider prefs; that's the ADR-081 proxy.
OC_SETUP=""; OC_ENV=""
if [ "$HARNESS" = "opencode" ]; then
  PIN_JSON="$(python3 "$HERE/estimate_budget.py" --model "$MODEL" --lookup 2>/dev/null || true)"
  # order carries the ROUTING slug — OpenRouter matches tags ("deepinfra"), display names no-op.
  OC_CONFIG="$(printf '%s' "$PIN_JSON" | jq -c --arg m "$GOOSE_MODEL" '
    select(.pinned_provider != null) |
    {"$schema": "https://opencode.ai/config.json",
     provider: {openrouter: {models: {($m): {options: {provider: {
       order: [.pinned_provider.slug // .pinned_provider.provider],
       allow_fallbacks: true,
       max_price: {prompt: ((.pinned_provider.prompt * 2 * 10000 | ceil) / 10000)}
     }}}}}}}' 2>/dev/null || true)"
  if [ -n "$OC_CONFIG" ]; then
    echo "→ opencode session pin: $(printf '%s' "$PIN_JSON" | jq -r '"\(.pinned_provider.provider) (effective $\(.pinned_provider.effective_per_mtok)/M in)"')"
    # base64 keeps the JSON inert through the bash -c → jq -Rs → pod-yaml quoting layers.
    OC_SETUP="printf '%s' '$(printf '%s' "$OC_CONFIG" | base64 -w0)' | base64 -d > /tmp/opencode-session.json; "
    OC_ENV=$'        - name: OPENCODE_CONFIG\n          value: "/tmp/opencode-session.json"'
  else
    echo "→ opencode session pin unavailable (registry lookup failed / no eligible provider) — running unpinned"
  fi
fi

if [ -n "$RUN_CMD" ]; then
  # Run the harness, tee its output to a file, then emit the AGENT_RUN_STATS line (agent-finalize
  # parses the run's structured outcome from that file + computes cost/duration). `set +e` so a
  # harness failure still runs finalize; the tee keeps the live stream intact for `kubectl logs -f`.
  # HARNESS_EXIT (the harness's own status, not tee's) feeds the transcript manifest (§A1).
  WRAPPED="${OC_SETUP}set +e; { ${RUN_CMD} ; } 2>&1 | tee /tmp/run.log; HARNESS_EXIT=\${PIPESTATUS[0]} agent-finalize /tmp/run.log"
  ARGS="[\"bash\",\"-c\",$(printf '%s' "$WRAPPED" | jq -Rs .)]"
elif [ -n "$OC_SETUP" ]; then
  # Interactive opencode session: write the pin config, then idle for the exec below.
  ARGS="[\"bash\",\"-c\",$(printf '%s' "${OC_SETUP}exec sleep infinity" | jq -Rs .)]"
else
  ARGS="[\"sleep\",\"infinity\"]"       # idle after prep; you exec in below
fi

# §A1 transcript capture (docs/agents/observability-and-retro.md): fetch the WRITE-ONLY key for the
# agent-transcripts bucket and inject it as env VALUES below — a secretKeyRef can't cross namespaces
# (workers run in the project ns; the key lives in agent-coordinator, written by the Crossplane
# Workspace agents/coordinator/garage-workspace.yaml). Best-effort: without the key the run proceeds
# and agent-finalize skips the upload loudly. Jail kubeconfig reads it as admin; the coordinator SA
# has a resourceNames-scoped get on exactly this Secret (agents/coordinator/rbac.yaml).
TS_ENDPOINT="http://garage.garage.svc.cluster.local:3900"; TS_BUCKET="agent-transcripts"
TS_KEY_ID="$("$KUBECTL" $KUBE -n agent-coordinator get secret agent-transcripts-s3 -o jsonpath='{.data.writer_access_key_id}' 2>/dev/null | base64 -d || true)"
TS_KEY_SECRET="$("$KUBECTL" $KUBE -n agent-coordinator get secret agent-transcripts-s3 -o jsonpath='{.data.writer_secret_access_key}' 2>/dev/null | base64 -d || true)"
[ -n "$TS_KEY_ID" ] || echo "→ transcript-capture key unavailable (agent-transcripts-s3 in agent-coordinator) — run proceeds, upload will be skipped"

# Persistent uv (PyPI wheel) cache: if a `agent-uv-cache` PVC exists in the namespace, mount it so
# `devbox run ci`'s `uv sync` fetches wheels once across runs (the nix cache only covers `devbox
# install`). Optional — projects without the PVC just get an ephemeral cache. RWX so concurrent
# agent pods can share it; fsGroup below makes it writable for the non-root user.
UV_MOUNT=""; UV_VOLUME=""; UV_ENV=""
if "$KUBECTL" $KUBE -n "$NS" get pvc agent-uv-cache >/dev/null 2>&1; then
  UV_MOUNT=$'      volumeMounts:\n        - { name: uv-cache, mountPath: /uv-cache }'
  UV_VOLUME=$'  volumes:\n    - name: uv-cache\n      persistentVolumeClaim: { claimName: agent-uv-cache }'
  # Point uv at the shared cache ONLY when it's actually mounted. Setting UV_CACHE_DIR=/uv-cache
  # without the mount makes uv `mkdir /uv-cache` at `/`, which the non-root (1000) user can't write —
  # "failed to create directory /uv-cache: Permission denied". Absent the mount, leaving UV_CACHE_DIR
  # unset lets uv fall back to its writable default (~/.cache/uv). Couple the two; never split them.
  UV_ENV=$'        - name: UV_CACHE_DIR\n          value: "/uv-cache"'
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
        # §A1 transcript capture context: agent-finalize uploads run.log + the goose session dir +
        # manifest.json to s3://agent-transcripts/<project>/<task>/worker-r<round>-<ts>/. The key is
        # write-only (append-only exhaust; no list/get) and injected as VALUES — see the fetch above.
        - name: AGENT_TASK
          value: "${TASK}"
        - name: AGENT_ROUND
          value: "${ROUND}"
        - name: AGENT_SESSION_KEY
          value: "${SECRET}"
        - name: AGENT_TS_ENDPOINT
          value: "${TS_ENDPOINT}"
        - name: AGENT_TS_BUCKET
          value: "${TS_BUCKET}"
        - name: AGENT_TS_ACCESS_KEY_ID
          value: "${TS_KEY_ID}"
        - name: AGENT_TS_SECRET_ACCESS_KEY
          value: "${TS_KEY_SECRET}"
        # FU-057 §B1: agent-finalize PUTs this run's cost/duration/outcome here (goose has no OTLP
        # rail). Cross-namespace to the monitoring pushgateway; unset it to disable the push.
        - name: AGENT_PUSHGATEWAY_URL
          value: "${AGENT_PUSHGATEWAY_URL:-http://prometheus-pushgateway.monitoring.svc.cluster.local:9091}"
        # goose reads provider+model from env; opencode auto-detects OPENROUTER_API_KEY and takes
        # the model via \`-m \${MODEL}\` at run time (e.g. \`opencode run -m \$MODEL "…"\`).
        - name: GOOSE_PROVIDER
          value: "openrouter"
        - name: GOOSE_MODEL
          value: "${GOOSE_MODEL}"
        # goose→OpenRouter via the ADR-081 egress proxy (emitted only for goose, see above).
${GOOSE_PROXY_ENV}
        - name: MODEL
          value: "${MODEL}"
        # Per-session opencode provider pin (FU-018 interim, emitted ONLY when the pin config is
        # written by the command prefix above — same couple-the-two rule as UV_ENV below).
${OC_ENV}
        # Persistent uv wheel cache: env emitted ONLY when the agent-uv-cache PVC is mounted (UV_ENV),
        # so an unmounted /uv-cache never gets set as the cache dir. See the UV_ENV note above.
${UV_ENV}
        # Auto-approve tool calls: a headless --run recipe has no TTY to confirm at, so without this
        # goose blocks forever. The pod is the isolation boundary, so autonomy here is the point.
        - name: GOOSE_MODE
          value: "auto"
        # FU-021 interim bound: on a dead key (budget-403/revoked 401) goose's final-output
        # continuation loops fresh requests until max_turns — default 1000 (measured: 530 auth
        # failures, exit 0, no PR). goose v1.28 has NO per-error-class stop, so cap the loop; 200
        # clears every legit run measured (owl 72, the pathological qwen loop 187). The real
        # storm hard-stop is agent-runtime#8.
        - name: GOOSE_MAX_TURNS
          value: "${GOOSE_MAX_TURNS:-200}"
        - name: OPENROUTER_API_KEY
          valueFrom:
            secretKeyRef: { name: ${SECRET}, key: OPENROUTER_API_KEY }
        # Scoped ~1h GitHub token minted by the ESO GithubAccessToken generator (per-project,
        # sleep-iac/<project>/agent/git-token.yaml) → clone private repos + push branch + open PR.
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
  PR_URL=""
  if [ -n "$STATS" ]; then
    echo "→ stats: $STATS"
    PR_URL="$(printf '%s' "$STATS" | jq -r '.pr_url // empty' 2>/dev/null)"
    if [ -n "$PR_URL" ] && [ -n "${GH_TOKEN:-}" ]; then
      # ARM AUTO-MERGE — mandatory post-PR step (FU-041, docs/agents/merge-path.md §Chosen design ▸1).
      # The deterministic merge path only ever touches auto-merge-armed PRs: the updater keeps armed PRs
      # current, the review reflex only reviews armed PRs, and GitHub completes an armed PR the moment
      # approval + CI land. An un-armed PR is invisible to all of it and stalls. Squash keeps master linear
      # (matches the reviewer-session.sh header + repos.tf squash config). Idempotent — re-arming is a no-op.
      echo "→ arming auto-merge (squash) on ${PR_URL}"
      gh pr merge "$PR_URL" --auto --squash 2>&1 | tail -1 || echo "  (arm failed — non-fatal; coordinator re-arms in step 6)"
      GRAFANA_URL="${GRAFANA_URL:-https://grafana.teststuff.net}"
      PANES="$(jq -cn --arg pod "$POD" '{ag:{datasource:"loki",queries:[{refId:"A",expr:("{pod=\""+$pod+"\"}"),datasource:{type:"loki",uid:"loki"}}],range:{from:"now-6h",to:"now"}}}')"
      LOGS_URL="${GRAFANA_URL}/explore?schemaVersion=1&orgId=1&panes=$(jq -rn --arg p "$PANES" '$p|@uri')"
      BODY="$(printf '%s' "$STATS" | jq -r --arg logs "$LOGS_URL" --arg task "$TASK" '
        "🤖 **Agent run stats**\n\n" +
        "| metric | value |\n|---|---|\n" +
        "| model | `\(.model // "?")` (\(.harness // "?")) |\n" +
        "| cost | $\(.cost_usd // 0) |\n" +
        "| duration | \(.duration_s // 0)s |\n" +
        "| reproduced | \(.reproduced // "?") |\n" +
        "| ci_passed | \(.ci_passed // "?") |\n" +
        "| error_class | `\(if ((.error_class // "") == "") then "clean" else .error_class end)` |\n" +
        "| coverage | \(.coverage_pct // "?")% |\n" +
        "| node / pod | `\(.node // "?")` / `\(.pod // "?")` |\n\n" +
        "[📜 run logs in Grafana](\($logs))\n" +
        "🗂 transcripts: `s3://agent-transcripts/\(.project // "?")/\($task)/` · [viewer](https://transcripts.local.teststuff.net)"')"
      echo "→ posting stats comment to ${PR_URL}"
      gh pr comment "$PR_URL" --body "$BODY" 2>&1 | tail -1 || echo "  (comment failed — non-fatal)"
    fi
  fi

  # STRIKE BOOKKEEPING (FU-062, docs/agents/model-routing.md §M1): a run that terminates WITHOUT an
  # open PR is an infra strike candidate — classify it and post ONE structured comment to the ISSUE
  # (not a PR: there is none). That comment IS the strike store: state lives in GitHub, and the
  # coordinator greps `AGENT_STRIKE:` in issue comments to blacklist the model for this task and
  # pick the next chain entry. Keep the first line's format STABLE — it's the machine interface.
  if [ -z "$PR_URL" ]; then
    if [ -n "$STATS" ]; then
      # agent-finalize already classified the run (authoritative — it saw the full log + exit code).
      # Its exit_status maps onto the strike taxonomy; anything else (failed/no-output/ci-failed
      # without a PR) is "unknown" — still a strike, just an unclassified one.
      ERR_CLASS="$(printf '%s' "$STATS" | jq -r '
        (.exit_status // "") as $s
        | if (["harness-death","auth-storm","budget-403","timeout"] | index($s)) then $s else "unknown" end' \
        2>/dev/null || echo unknown)"
    else
      # No AGENT_RUN_STATS line at all = finalize never ran (the pod died hard / wait timed out) —
      # the PR-less death that used to be invisible. Classify the raw log jail-side with the same
      # signatures agent-finalize uses (that script is the authoritative copy of these patterns).
      if grep -qiE -e '-32602|EOF while parsing|response may have been truncated|context_length_exceeded|panicked at' "$RUNLOG"; then
        ERR_CLASS="harness-death"
      elif grep -qiE 'insufficient (credit|quota|fund)|402 payment|payment required|quota exceeded|budget exceeded|key limit exceeded|out of credit' "$RUNLOG"; then
        ERR_CLASS="budget-403"
      elif [ "$(grep -ciE 'authentication failed|401 unauthorized|403 forbidden|invalid api key|no auth credentials' "$RUNLOG")" -ge 3 ]; then
        ERR_CLASS="auth-storm"
      elif grep -qiE 'context deadline exceeded|request timed out|operation timed out' "$RUNLOG"; then
        ERR_CLASS="timeout"
      else
        ERR_CLASS="unknown"
      fi
    fi
    STRIKE_LINE="AGENT_STRIKE: model=${MODEL} error_class=${ERR_CLASS} round=${ROUND} session=${POD}"
    echo "→ no PR opened — ${STRIKE_LINE}"
    ISSUE_N=""
    case "$TASK" in issue-[0-9]*) ISSUE_N="${TASK#issue-}";; esac
    SLUG=""
    case "$REPO_URL" in https://github.com/*) SLUG="${REPO_URL#https://github.com/}"; SLUG="${SLUG%.git}";; esac
    if [ -n "$ISSUE_N" ] && [ -n "$SLUG" ] && [ -n "${GH_TOKEN:-}" ]; then
      # ~~~ fences (not ```) so backticks inside log lines can't break out of the block.
      STRIKE_BODY="$(printf '%s\n\n<details><summary>last 15 log lines (%s)</summary>\n\n~~~text\n%s\n~~~\n\n</details>\n' \
        "$STRIKE_LINE" "$POD" "$(tail -n 15 "$RUNLOG")")"
      echo "→ posting strike comment to ${SLUG}#${ISSUE_N}"
      gh issue comment "$ISSUE_N" --repo "$SLUG" --body "$STRIKE_BODY" 2>&1 | tail -1 \
        || echo "  (strike comment failed — non-fatal; the strike still shows in these logs)"
    else
      echo "  (no issue task / non-GitHub repo / no GH_TOKEN — strike not posted, logged above only)"
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
