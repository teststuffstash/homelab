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
# Flags: --run "<cmd>"  --ref <base-branch>  --repo <git-url>  --harness goose|opencode|claude  --model provider/model
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

PROJECT="${1:?usage: agent-session <project> [--run \"<cmd>\"] [--ref <branch>] [--repo <url>] [--harness goose|opencode|claude] [--model provider/model]}"
case "$PROJECT" in --help|-h)  # a bare --help used to be swallowed as the PROJECT name (junk /route + ref-resolve rows, seen live 2026-08-02)
  echo "usage: agent-session <project> [--run \"<cmd>\"] [--ref <branch>] [--repo <url>] [--harness goose|opencode|claude] [--model provider/model] [--task issue-<n>] [--round <r>] [--recipe <path>] [--docker] [--openrouter-secret <name>] [--work-branch <b>] [--no-attach] [--no-arm]"
  exit 0
;; esac
shift || true

# Default to a cheap, multi-provider, CACHED model bounded by the per-session budget cap. The
# per-stack chain (primary + fallbacks) lives in agents/stacks.json; an infra failure here costs one
# STRIKE (re-dispatch on the next chain model), so free/new entries are fair — see
# docs/agents/model-routing.md. Still avoid CLOAKED models as primary (rotated out → 404s mid-run).
RUN_CMD=""; BASE_REF="master"; REPO_URL=""; HARNESS="opencode"; MODEL="openrouter/deepseek/deepseek-v4-flash"; NO_ATTACH=""; OR_SECRET=""; TASK=""; ROUND="1"; WORK_BRANCH=""; DOCKER=""; RECIPE=""; NO_ARM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run)       RUN_CMD="$2"; shift 2;;
    --ref)       BASE_REF="$2"; shift 2;;
    --repo)      REPO_URL="$2"; shift 2;;
    --harness)   HARNESS="$2"; HARNESS_SET=1; shift 2;;
    --model)     MODEL="$2"; MODEL_SET=1; shift 2;;
    --docker)    DOCKER=1; shift;;    # repo needs a real docker daemon (kind/k3d CI gate): kata microVM pod + dind sidecar — stack POLICY, from the AgentStack claim's fixer.docker (counterpart of CI choosing the VM runner)
    --openrouter-secret) OR_SECRET="$2"; shift 2;;  # use a per-SESSION budget key Secret (the coordinator's ephemeral OpenRouterKey) instead of the shared <project>-openrouter
    --task)      TASK="$2"; shift 2;;   # transcript-capture task key: issue-<n> | pr-<n> (§A1 bucket prefix)
    --round)     ROUND="$2"; shift 2;;  # worker round on that task (prefix worker-r<N>)
    --work-branch) WORK_BRANCH="$2"; shift 2;;  # resume an EXISTING remote branch (fix round on a PR branch / a salvaged WIP branch) — the entrypoint checks it out tracking origin, deterministically (old finding C)
    --recipe)    RECIPE="$2"; shift 2;;  # claude harness: launcher BUILDS the run command from this goose recipe path — never LLM-assembled (2026-07-21 #55 incident)
    --no-attach) NO_ATTACH=1; shift;;   # interactive: create + prep the pod, print the attach cmd, don't exec
    --no-arm)    NO_ARM=1; shift;;      # human-gated PR (FU-105 researcher): finalize skips arm-at-open (AGENT_ARM_PR=0); C9 skips research/* branches
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
# ── ADR-096 P3/P4: consult the router at the model-decision seam (POST /route) ──
# AGENT_ROUTER=shadow (default): consult + log the divergence, dispatch unchanged — the ≥1wk
# soak that gates the flip. =authoritative: the decision REPLACES the model — but an explicit
# --model always wins (the ADR override rule; under authoritative, dispatchers stop passing
# --model and the launcher owns the choice, ADR-094). =off: today's behavior exactly.
# The chain is the stacks.json mirror entry for this project's stack (same source the scan
# merges cluster-wins); /route filters it against strikes, cooldowns, class policy and capacity
# server-side and answers a dispatch or a typed defer. Fail-open: unreachable proxy (jail run
# without AGENT_EGRESS_PROXY) → static behavior, one loud line.
AGENT_ROUTER="${AGENT_ROUTER:-shadow}"
if [ "$AGENT_ROUTER" != "off" ]; then
  ROUTER_URL="${AGENT_EGRESS_PROXY:-${AGENT_OPENROUTER_PROXY:-http://openrouter-proxy.agent-egress.svc.cluster.local:8080}}"
  _srow="$(jq -c --arg p "$PROJECT" '[.stacks[] | select(.repos[]? == $p)][0] // {}' "$HERE/stacks.json" 2>/dev/null)" || _srow="{}"
  _chain="$(printf '%s' "$_srow" | jq -c '([.workerModel] + (.workerModelFallbacks // [])) | map(select(. != null))' 2>/dev/null)" || _chain="[]"
  if [ -n "${HARNESS_SET:-}" ]; then  # an explicit --harness bounds the rail this pod can ride
    case "$HARNESS" in
      claude) _chain="$(printf '%s' "$_chain" | jq -c 'map(select(startswith("claude/")))')";;
      *)      _chain="$(printf '%s' "$_chain" | jq -c 'map(select(startswith("claude/") | not))')";;
    esac
  fi
  _req="$(jq -nc --arg stack "$(printf '%s' "$_srow" | jq -r '.name // ""')" \
      --arg task "${TASK:-adhoc}" --arg session "agent-${PROJECT}-${TASK:-adhoc}-r${ROUND}" \
      --arg key_ref "${PROJECT}/${OR_SECRET:-${PROJECT}-openrouter}" \
      --argjson chain "$_chain" \
      --argjson deny "$(printf '%s' "$_srow" | jq -c '.modelDeny // []')" \
      '{stack: $stack, task: $task, role: "worker", session: $session,
        key_ref: $key_ref, chain: $chain, deny: $deny}')"
  _decision="$(curl -fsS --max-time 5 -H "Content-Type: application/json" \
      -d "$_req" "$ROUTER_URL/route" 2>/dev/null)" || _decision=""
  if [ -z "$_decision" ]; then
    echo "→ router: $ROUTER_URL unreachable — static model chain (fail-open, AGENT_ROUTER=$AGENT_ROUTER)"
  else
    _verdict="$(printf '%s' "$_decision" | jq -r '.decision // "?"')"
    _rmodel="$(printf '%s' "$_decision" | jq -r '.model // ""')"
    _rwhy="$(printf '%s' "$_decision" | jq -r '[.reason, .basis, (if .half_open then "half-open" else empty end)] | map(select(. != null and . != "")) | join(",")')"
    echo "→ router(${AGENT_ROUTER}): ${_verdict} ${_rmodel:-—} [${_rwhy}] (static would be: ${MODEL})"
    if [ "$AGENT_ROUTER" = "authoritative" ]; then
      if [ -n "${MODEL_SET:-}" ]; then
        echo "→ router: explicit --model ${MODEL} wins over the routed decision (ADR-096 override rule)"
      elif [ "$_verdict" = "dispatch" ] && [ -n "$_rmodel" ]; then
        MODEL="$_rmodel"
      elif [ "$_verdict" = "defer" ]; then
        _retry="$(printf '%s' "$_decision" | jq -r '.retry_after_s // "?"')"
        echo "→ router: DEFER (${_rwhy}) retry_after=${_retry}s — not dispatching. chain-exhausted means every model is struck/denied for this task: escalate." >&2
        exit 1
      fi
    fi
  fi
fi

# workerModel notation from the AgentStack claim (first used by oracle, oracle-iac#8):
# "claude/<model>" = harness-prefixed — the XRD carries no harness field yet (FU-066's
# fixer.claudeTier is the eventual shape), so the claim encodes the tier in the model string.
# Make it self-executing: the dispatcher passes --model straight from stacks_json and gets the
# claude harness + bare model id; an explicit --harness still wins.
case "$MODEL" in claude/*)
  [ -n "${HARNESS_SET:-}" ] || HARNESS="claude"
  MODEL="${MODEL#claude/}"
;; esac

# Without an explicit --task (interactive/ad-hoc runs) the transcript still lands somewhere findable.
TASK="${TASK:-adhoc-$(date -u +%Y%m%dT%H%M%SZ)}"

# ── --recipe: LAUNCHER-OWNED claude run command (ADR-094 constraints-as-code) ──
# The coordinator brief used to instruct the item session to hand-assemble the base64-carry
# claude invocation — an LLM memory test that failed live 2026-07-21 (#55 r1: the README's
# literal `'$B64'` template shipped un-substituted, a haiku session ran on a garbage system
# prompt until the FU-069 breaker caught it). Now the dispatcher passes the recipe PATH (it has
# the repo clone) and THIS script builds the command deterministically: the whole recipe file is
# base64-carried as the system prompt (goose-format YAML — the model reads it fine, and no
# YAML-parsing dependency exists jail/pod-side), the issue number comes from --task.
if [ -n "${RECIPE:-}" ]; then
  # --recipe is now the launcher-owned path for BOTH harnesses (FU-114: was claude-only; goose
  # used a dispatcher-assembled `--run "goose run --recipe …"`, the ADR-094 gap the #55 incident
  # first exposed on goose). The RUN_CMD is BUILT below, after the environment knobs (--docker,
  # egress) are known — so the platform environment card (FU-114 L1) can be composed from them and
  # injected into the recipe. Here we only VALIDATE and derive launcher-owned flags.
  case "$HARNESS" in claude|goose) ;; *) echo "FATAL: --recipe supports the claude/goose harnesses (got '${HARNESS}'); opencode uses --run" >&2; exit 2;; esac
  [ -f "$RECIPE" ] || { echo "FATAL: --recipe ${RECIPE} not found (pass the dispatcher-side clone's path)" >&2; exit 2; }
  [ -z "$RUN_CMD" ] || { echo "--recipe and --run are mutually exclusive" >&2; exit 2; }
  ISSUE_N="${TASK#issue-}"
  case "$ISSUE_N" in ''|*[!0-9]*) echo "FATAL: --recipe needs --task issue-<N> (got '${TASK}')" >&2; exit 2;; esac
  # A research recipe's PR is human-gated BY DESIGN (FU-105) — derive --no-arm from the recipe
  # name so the un-armed gate is launcher-owned, never a dispatcher memory test (ADR-094; the
  # first live ride was armed by finalize right past the recipe's "do not arm").
  case "$(basename "$RECIPE")" in research*) NO_ARM=1; echo "→ --no-arm derived from research recipe (human-gated PR)";; esac
fi

NS="$PROJECT"

# --docker is STACK POLICY (the claim's fixer.docker), not a dispatcher memory test: derive it
# from the AgentStack claim when the caller didn't pass it (found live 2026-07-18: an item
# session dispatched a docker-repo worker without --docker; the duplicate-dispatch dance cost a
# pod). Explicit --docker always wins; a failed probe leaves it unset and WARNS (the CI gate
# catches a wrong-mode ride — degrade loudly, never guess).
if [ -z "$DOCKER" ] && command -v "$KUBECTL" >/dev/null 2>&1; then
  if claims_json="$("$KUBECTL" $KUBE get agentstacks.platform.teststuff.net -o json 2>/dev/null)"; then
    if [ "$(printf '%s' "$claims_json" | jq -r --arg p "$PROJECT" \
        '[.items[].spec.repos[] | select(.name == $p and (.fixer.docker == true))] | length' 2>/dev/null)" -gt 0 ] 2>/dev/null; then
      DOCKER=1
      echo "→ --docker derived from the AgentStack claim (fixer.docker=true for ${PROJECT})"
    fi
    # FU-114 L1: capture the egress knobs from the SAME claim read for the environment card (below).
    EGRESS_ENFORCE="$(printf '%s' "$claims_json" | jq -r --arg p "$PROJECT" '[.items[].spec.repos[]|select(.name==$p)|.fixer.egress.enforce]|map(select(.!=null))|first // empty' 2>/dev/null)"
    EGRESS_PROFILE="$(printf '%s' "$claims_json" | jq -r --arg p "$PROJECT" '[.items[].spec.repos[]|select(.name==$p)|.fixer.egress.profile]|map(select(.!=null))|first // empty' 2>/dev/null)"
  else
    echo "WARN: agentstacks probe failed — cannot derive --docker; pass it explicitly for docker-gated repos" >&2
  fi
fi
# ── FU-114 L1: the platform ENVIRONMENT CARD (docs/agents/fixer-context.md) ──────────────────
# Composed from the SAME knobs the launcher just used to BUILD this ride (--docker, egress), so it
# is accurate by construction — never the stale "no-real-data sandbox" framing that primed the #48
# ride to assert "I can't run k3d" without ever probing. It states the capability AND the verify
# command, and is injected into the recipe's instructions at the {{PLATFORM_ENV_CARD}} marker
# (deterministic awk-insert, no YAML dependency) so the worker cannot skip reading it.
render_env_card() {
  local mdio="${AGENT_MIRROR_DOCKER_IO-http://192.168.40.20}" mghcr="${AGENT_MIRROR_GHCR-http://192.168.40.21}" ncache="${AGENT_NIX_CACHE_URL-http://192.168.40.23}" dsearch="${AGENT_DEVBOX_SEARCH_HOST-http://192.168.40.27}"
  # ═══ MAINTAINER NOTE — read before editing (this comment is NOT sent to the agent) ═══
  # Everything printf'd below is injected VERBATIM into the stack agent's prompt. Keep that text
  # MINIMAL and stack-agnostic: the rule + the value it needs to ACT, nothing else. All homelab-
  # internal context — the WHY, issue links, FU/ADR ids, incident dates, cross-stack pointers —
  # stays in `#` comments like these and is NOT sent. Litmus: a link/id/"we learned this on <date>"
  # is a COMMENT; something that changes what the agent DOES is CARD TEXT.
  # These rules are duplicated from homelab/CLAUDE.md (goose never auto-loads it); the single-source
  # role×context refactor is FU-117 — note sightings there, don't grow this card ad-hoc.
  printf '%s\n\n' "## Platform environment (generated by the launcher from THIS ride's AgentStack claim — ground truth. VERIFY with the commands rather than assuming; the generic recipe doesn't know your ride's capabilities, this card does.)"

  # WHY: `.devbox/` is a read-only nix profile and a hand-placed binary isn't on CI's PATH — that
  # "green in the ride, red in CI" trap is the one consequence worth telling the agent.
  printf '%s\n' "- **Install tools ONLY via devbox.** Missing a CLI? Add it to \`devbox.json\` (\`devbox add <pkg>@<ver>\`) then \`devbox install\` — reproducible, and exactly what CI runs. NEVER \`curl\`/download a binary: \`.devbox/\` is read-only and a hand-placed binary isn't on CI's PATH, so the gate goes red though it 'worked' for you."

  # WHY: registry mirrors = FU-073/ADR-091 (.40.20/.21); nix-cache = ADR-083 (.40.23); devbox-search
  # = FU-118b (.40.27). The agent needs only the values + that a miss HANGS under the egress CNP.
  printf '%s\n' "- **Package proxies (upstream is egress-blocked — a miss HANGS, it does not error):** \`devbox install\` → \`\$NIX_CACHE_URL\` (${ncache}, automatic); \`devbox add\` resolves via \`\$DEVBOX_SEARCH_HOST\` (${dsearch}, automatic — no WAN needed); container images → docker.io=\`\$REGISTRY_MIRROR_DOCKER_IO\` (${mdio}), ghcr.io=\`\$REGISTRY_MIRROR_GHCR\` (${mghcr}), **HTTP-only**; python → pip/uv against pypi.org + files.pythonhosted.org (open on the python egress profile)."

  # WHY: deliberately NOT a "grep SERVICES.md" rule — the ride clones ONLY /work/repo, never homelab,
  # so it's unreachable; service facts (endpoints/buckets/secret refs) are the ISSUE AUTHOR's job to
  # put in the issue. That responsibility split IS the FU-117 role×context question.
  printf '%s\n' "- **Prior-art before creating anything named** (doc, script, tracker entry) IN THIS REPO: grep the repo's docs/trackers by keyword first — extend, don't duplicate."

  if [ -n "$DOCKER" ]; then
    # WHY: docker-client-in-devbox.json = FU-119; the kind-node-hangs-on-missing-mirror trap =
    # sleep-tracking#67; the reference kind_mirror() impl is oracle-fleet scripts/e2e-kind.sh (and
    # each docker stack's own scripts/test-integration.sh after #71). Card keeps the actionable HOW.
    printf '%s\n' "- **Docker: YES.** A real daemon is live at \`\$DOCKER_HOST\` (\`docker info\` succeeds). The \`docker\`/\`kind\` CLIs come from your \`devbox.json\` (\`docker-client\`+\`kind\`) — if \`docker\` is 'command not found', add \`docker-client\` there (never download). Run \`kind\`/\`k3d\` here for e2e gates. **CRITICAL:** a kind/k3d NODE's own image pulls go to docker.io/ghcr.io and are egress-DENIED → the node never goes Ready and \`create\` times out (looks like 'docker is broken' — it's the MISSING MIRROR). Point the node's containerd at the mirrors BEFORE it starts — kind: \`docker exec <node> tee /etc/containerd/certs.d/<reg>/hosts.toml\` pointing at \`\$REGISTRY_MIRROR_DOCKER_IO\`/\`\$REGISTRY_MIRROR_GHCR\`; k3d: \`--registry-config\`."
  else
    printf '%s\n' "- **Docker: NO.** No daemon in this ride — docker-backed e2e gates run in GitHub CI, not here; don't try to start clusters."
  fi

  if [ "${EGRESS_ENFORCE:-}" = "true" ]; then
    printf '%s\n' "- **Egress: ENFORCED** (profile: ${EGRESS_PROFILE:-baseline}). Only allowlisted hosts are reachable; a miss HANGS. Use the mirrors above; don't reach upstream package/registry hosts directly."
  else
    printf '%s\n' "- **Egress: monitored, not blocked** — calls work; destinations are logged for the allowlist harvest."
  fi

  printf '%s\n' "- **Round ${ROUND}** of ${ROUNDS_MAX:-3} (a CHANGES_REQUESTED review or CI-red-on-your-change costs a round; infra failures don't). Land one tight, correct change."
  printf '%s\n' "- **Write scope:** you can only push a \`fix/\`-prefixed branch and open a PR — master is unreachable (branch protection + token scope). A real boundary, not something to route around."
}

# Build the launcher-owned RUN_CMD from --recipe now that the environment is known (FU-114): render
# the card, splice it into the recipe at the marker, base64-carry the augmented recipe, and wrap the
# harness-specific invocation. Both harnesses read the SAME augmented recipe (goose natively; claude
# as an appended system prompt — it parses the goose YAML fine, agent-runtime#14).
if [ -n "${RECIPE:-}" ]; then
  # FU-114 L3: deterministic task-type recipe selection (docs/agents/fixer-context.md). The
  # dispatcher passes the DEFAULT recipe (.agents/fix.yaml); if the issue carries a `task/<class>`
  # label and a sibling `.agents/<class>.yaml` exists, use THAT — launcher-owned, never LLM-picked
  # (ADR-094). Default is the passed recipe; an unknown class or missing sibling degrades to it loudly.
  if command -v gh >/dev/null 2>&1; then
    TASK_CLASS="$(gh issue view "$ISSUE_N" --repo "${ORG:-teststuffstash}/${PROJECT}" --json labels \
      --jq '[.labels[].name|select(startswith("task/"))|ltrimstr("task/")]|first // empty' 2>/dev/null || true)"
    if [ -n "$TASK_CLASS" ]; then
      if [ -f "$(dirname "$RECIPE")/${TASK_CLASS}.yaml" ]; then
        RECIPE="$(dirname "$RECIPE")/${TASK_CLASS}.yaml"; echo "→ FU-114 L3: recipe .agents/${TASK_CLASS}.yaml selected (task/${TASK_CLASS} label)"
      else
        echo "→ FU-114 L3: issue has task/${TASK_CLASS} but no .agents/${TASK_CLASS}.yaml — using $(basename "$RECIPE")"
      fi
    fi
  fi
  # Splice the env card into the recipe's `instructions` block. Marker-first (the author chose
  # placement); fall back to right after `instructions: |`; WARN + no-card if neither shape is
  # found — NEVER FATAL (a missing marker in one stack's recipe must not wedge the whole loop; the
  # card is a strong aid, not a correctness gate — same degrade-loudly rule as the --docker probe).
  RECIPE_WITH_CARD="$(mktemp)"
  if grep -q '{{PLATFORM_ENV_CARD}}' "$RECIPE"; then
    IND="$(grep -m1 '{{PLATFORM_ENV_CARD}}' "$RECIPE" | sed 's/[^ ].*$//')"
    CARD="$(render_env_card | sed "s/^/${IND}/;s/[[:space:]]*$//")"
    awk -v c="$CARD" '!spliced && /{{PLATFORM_ENV_CARD}}/{print c; spliced=1; next} {print}' "$RECIPE" > "$RECIPE_WITH_CARD"
  elif grep -qE '^[[:space:]]*instructions:[[:space:]]*\|' "$RECIPE"; then
    IND="$(grep -m1 -E '^[[:space:]]*instructions:[[:space:]]*\|' "$RECIPE" | sed 's/[^ ].*$//')  "  # instructions key indent + one level
    CARD="$(render_env_card | sed "s/^/${IND}/;s/[[:space:]]*$//")"
    awk -v c="$CARD" 'p{print c; print ""; p=0} /^[[:space:]]*instructions:[[:space:]]*\|/{p=1} {print}' "$RECIPE" > "$RECIPE_WITH_CARD"
    echo "→ FU-114: env card injected after 'instructions:' (${RECIPE} has no {{PLATFORM_ENV_CARD}} marker)"
  else
    cp "$RECIPE" "$RECIPE_WITH_CARD"
    echo "WARN FU-114: no {{PLATFORM_ENV_CARD}} marker and no 'instructions: |' block in ${RECIPE} — dispatching WITHOUT the environment card" >&2
  fi
  RECIPE_B64="$(base64 -w0 "$RECIPE_WITH_CARD")"; rm -f "$RECIPE_WITH_CARD"
  case "$HARNESS" in
    claude) RUN_CMD="printf '%s' '${RECIPE_B64}' | base64 -d > /tmp/fix-recipe.yaml; claude -p --dangerously-skip-permissions --max-turns ${CLAUDE_MAX_TURNS:-200} --append-system-prompt-file /tmp/fix-recipe.yaml 'The appended system prompt is this repo'\\''s recipe (goose format) with the platform environment card at the top — TRUST the card over any assumption. Follow the recipe exactly; your task is its prompt with issue=${ISSUE_N}. End your final message with the JSON object its response schema describes (single line, all required keys).'";;
    goose)  RUN_CMD="printf '%s' '${RECIPE_B64}' | base64 -d > /tmp/fix-recipe.yaml; goose run --recipe /tmp/fix-recipe.yaml --params issue=${ISSUE_N}";;
  esac
fi

[ -f "$HERE/images.env" ] && . "$HERE/images.env" # pinned agent image versions (no :latest)
IMAGE="${HARNESS_IMAGE:-${AGENT_BASE_IMAGE:-ghcr.io/teststuffstash/agent-base:latest}}"
REPO_URL="${REPO_URL:-https://github.com/teststuffstash/${PROJECT}.git}"
SECRET="${OR_SECRET:-${PROJECT}-openrouter}"  # operator-minted, budget-capped. Default: the shared standing key; the coordinator passes --openrouter-secret to bind a per-session ephemeral key instead
# Idempotency: for TASKED runs the key IS the pod name (workflow.md §Hazards — implemented
# 2026-07-21 after the THIRD double-dispatch escape; tick-level guards all have windows, the API
# server doesn't). `kubectl create` below is the atomic test-and-set: EXISTS = someone owns
# (task, round) — a TERMINAL holder is reaped pre-create (its record lives in GitHub by then),
# a LIVE holder refuses the dispatch. Ad-hoc runs keep timestamp names (no natural key).
case "$TASK" in
  issue-[0-9]*|pr-[0-9]*) POD="agent-${PROJECT}-${TASK//[^a-z0-9]/-}-r${ROUND}";;
  *) POD="agent-${PROJECT}-$(date -u +%H%M%S)";;
esac

# ── Dispatch pre-flight: deterministic guards (FU-042 + the TTL walls, TICK-LOG meta-2 2026-07-09) ──
# The brief's soft judgment failed each of these live: a second coordinator pass double-dispatched an
# in-progress issue (sleep-tracking#10 → conflicting PR #12), and three runs died on stale key/token
# deadlines. Headless task runs only; AGENT_PREFLIGHT=0 to bypass (e.g. deliberate parallel tracks).
if [ -n "$RUN_CMD" ] && [ "${AGENT_PREFLIGHT:-1}" != "0" ]; then
  case "$TASK" in issue-[0-9]*)
    PF_ISSUE="${TASK#issue-}"
    PF_SLUG="${REPO_URL#https://github.com/}"; PF_SLUG="${PF_SLUG%.git}"
    # (a) FU-042: an issue with an OPEN agent PR is alive in the merge path — dispatching a fresh
    # round would fork the work. The legitimate exception is a FIX ROUND resuming that PR's own
    # branch (--work-branch == the PR's headRef); resuming onto any OTHER branch is still a fork.
    # (Gap found live by the round-2 coordinator, 2026-07-09: the first cut refused unconditionally
    # and forced an AGENT_PREFLIGHT=0 workaround.)
    if command -v gh >/dev/null 2>&1; then
      PF_PR_LINE="$(gh pr list --repo "$PF_SLUG" --state open --json number,body,headRefName \
        --jq "[.[] | select(.body | test(\"#${PF_ISSUE}\\\\b\"))][0] | select(.) | \"\(.number) \(.headRefName)\"" 2>/dev/null || true)"
      if [ -n "$PF_PR_LINE" ]; then
        PF_PR="${PF_PR_LINE%% *}"; PF_HEAD="${PF_PR_LINE#* }"
        if [ -z "$WORK_BRANCH" ]; then
          echo "PREFLIGHT REFUSED: issue #${PF_ISSUE} already has open PR #${PF_PR} (${PF_SLUG}, branch ${PF_HEAD}) — resume it with --work-branch ${PF_HEAD}, don't fork it (FU-042)." >&2
          exit 3
        elif [ "$WORK_BRANCH" != "$PF_HEAD" ]; then
          echo "PREFLIGHT REFUSED: --work-branch ${WORK_BRANCH} does not match open PR #${PF_PR}'s branch ${PF_HEAD} — a resume must land on the PR's own branch (FU-042)." >&2
          exit 3
        fi
        echo "→ pre-flight: resuming open PR #${PF_PR} on its branch ${PF_HEAD} (fix round)"
      fi
    fi
    # (b) live-worker cap per project: default WIP=1; a repo with independent TRACK lanes
    # (TRACKS.md) may run one worker per lane — the dispatcher sets AGENT_WIP_LIMIT=<lanes>
    # (added 2026-07-10 when #2/#3 opened the first two-lane parallel dispatch).
    PF_LIMIT="${AGENT_WIP_LIMIT:-1}"
    # phase!=terminal, NOT phase=Running: a kata pod boots in Pending longer than a tick
    # interval — the Running filter double-dispatched #55 across consecutive ticks (2026-07-21).
    PF_LIVE="$("$KUBECTL" $KUBE -n "$NS" get pods -l app=agent-session,project="$PROJECT" \
      --field-selector=status.phase!=Succeeded,status.phase!=Failed --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${PF_LIVE:-0}" -ge "$PF_LIMIT" ]; then
      echo "PREFLIGHT REFUSED: ${PF_LIVE} agent pod(s) Running in ns ${NS} ≥ WIP limit ${PF_LIMIT} (FU-042; AGENT_WIP_LIMIT raises it for multi-track dispatch)." >&2
      exit 3
    fi
    # (d) FU-118: an offline `devbox add` writes a `placeholder-<system>-<pkg>` store path into
    # devbox.lock that commits fine but hard-fails the NEXT round's bootstrap `devbox install`
    # (`path-info --offline` on a nonexistent path) BEFORE the agent runs — an opaque, unrecoverable
    # boot crash the worker can't self-recover from (#71 r4/r5 died identically here). A poisoned
    # lock on the branch we're about to clone means the round is dead on arrival — refuse loudly
    # with the fix instead of dispatching into the crash. THE FIX IS NEVER A MID-RIDE `devbox add`:
    # resolve the tool ONLINE on the stack's master first (jail/CI), commit the real lock, then the
    # ride USES it (the pre-provision pattern — sleep-tracking PR#75 kind, PR#81 docker-client).
    if command -v gh >/dev/null 2>&1 \
       && gh api "repos/${PF_SLUG}/contents/devbox.lock?ref=${WORK_BRANCH:-$BASE_REF}" \
            -H "Accept: application/vnd.github.raw" 2>/dev/null | grep -q 'placeholder-'; then
      echo "PREFLIGHT REFUSED: devbox.lock on ${PF_SLUG}@${WORK_BRANCH:-$BASE_REF} carries a placeholder store path — a \`devbox add\` wrote it while the FU-118(b) search proxy (\$DEVBOX_SEARCH_HOST, .40.27) was unreachable, so the bootstrap \`devbox install\` will boot-crash this round (FU-118). Fix: re-run the add with the proxy up (it resolves in-band → a REAL store path), or resolve on master; never hand-edit the lock." >&2
      exit 3
    fi
  ;; esac
  # (c) session-key freshness: post openrouter-operator#6 the CR surfaces the LIVE key expiry in
  # .status.openrouter.expires_at (the PATCH re-mint bug killed a healthy run at its STALE deadline —
  # the CR spec claimed 20:19, the real key died 18:40). <30 min of real life → refuse; the fix is
  # delete the CR + re-mint (the POST path). Operators without the field → check skipped.
  # claude harness: no OpenRouter key in play — the check would misfire on the standing key.
  PF_EXP=""
  [ "$HARNESS" = "claude" ] || PF_EXP="$("$KUBECTL" $KUBE -n "$NS" get openrouterkeys -o json 2>/dev/null \
    | jq -r --arg s "$SECRET" '[.items[] | select((.spec.secretName // (.metadata.name + "-openrouter")) == $s)][0].status.openrouter.expires_at // empty')"
  if [ -n "$PF_EXP" ]; then
    PF_EXP_S="$(date -d "$PF_EXP" +%s 2>/dev/null || echo 0)"
    if [ "$PF_EXP_S" -gt 0 ] && [ "$PF_EXP_S" -lt $(( $(date +%s) + 1800 )) ]; then
      echo "PREFLIGHT REFUSED: session key ${SECRET} expires at ${PF_EXP} (<30 min real life) — delete the OpenRouterKey CR and re-mint before dispatch (openrouter-operator#6)." >&2
      exit 3
    fi
  fi
fi
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
WORK_BRANCH_ENV=""
if [ -n "$WORK_BRANCH" ]; then
  WORK_BRANCH_ENV=$'        - name: WORK_BRANCH\n          value: "'"$WORK_BRANCH"'"'
fi

# FU-105: human-gated PR — finalize must NOT arm auto-merge (needs the agent-runtime build with
# AGENT_ARM_PR support; an older image ignores the env and the C9 research/* exclusion still
# keeps the PR un-armed after a manual disarm).
ARM_ENV=""
if [ -n "${NO_ARM:-}" ]; then
  ARM_ENV=$'        - name: AGENT_ARM_PR\n          value: "0"'
fi

GOOSE_PROXY_ENV=""; PROXY_URL=""
PROXY_URL="${AGENT_OPENROUTER_PROXY-http://openrouter-proxy.agent-egress.svc.cluster.local:8080}"
if [ "$HARNESS" = "goose" ] && [ -n "$PROXY_URL" ]; then
  GOOSE_PROXY_ENV=$'        - name: OPENROUTER_HOST\n          value: "'"$PROXY_URL"'"'
fi

# ── docker mode (kata microVM + dind sidecar; spike: docs/spikes/kata-ci-gate.md) ──
# Kata guests can't reach cluster-service VIPs (FU-072), so every in-cluster dependency is
# rewritten to a RESOLVED ENDPOINT (pod) IP at dispatch — pod-to-pod works from kata, and the
# egress CNP's toEndpoints rules still match (identity-based). A ride outlives no endpoint here
# in practice (singleton services); when FU-072 lands, delete resolve_ep and the rewrites.
resolve_ep() { # <ns> <svc> → first endpoint IP, empty on failure
  "$KUBECTL" $KUBE -n "$1" get endpoints "$2" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true
}
if [ -n "$DOCKER" ]; then
  if [ -n "$PROXY_URL" ]; then
    EP="$(resolve_ep agent-egress openrouter-proxy)"
    if [ -n "$EP" ]; then
      PROXY_URL="http://${EP}:8080"
      GOOSE_PROXY_ENV=$'        - name: OPENROUTER_HOST\n          value: "'"$PROXY_URL"'"'
      echo "→ docker mode: openrouter-proxy via endpoint IP ${EP} (FU-072 workaround)"
    else
      echo "WARN docker mode: openrouter-proxy endpoint unresolvable — goose/claude LLM egress will fail from the kata guest (FU-072)" >&2
    fi
  fi
fi

# ── claude harness (FU-066): the SUBSCRIPTION worker tier — Haiku by default ──
# Auth is ADR-087 leg A through the proxy's /anthropic upstream: the pod holds ONLY
# `ref:<ns>/claude-session` (a session-key-labeled Secret with data key AUTH_TOKEN —
# operator-created per enabled namespace until it joins the AgentStack claim); the proxy
# resolves the ref, injects the subscription oauth token + the oauth beta header. The unscoped
# ~1y token NEVER sits in a worker pod (unlike the trusted coordinator/reviewer roles, which
# still hold it directly — unify them onto this rail once it has mileage).
# Image = agent-base, same as goose/opencode (it ships the claude CLI + the pre-seeded
# onboarding/trust files since agent-runtime#14): the entrypoint preps the repo, the project
# devbox toolchain (`devbox run ci`) works, and `--docker` (kata+dind) is structurally valid —
# the FU-066(e) coordinator-image interim is retired. Needs AGENT_BASE_IMAGE ≥ the
# agent-runtime#14 build (the deploy-pin bump in images.env); on an older pin the ride fails
# loudly at `claude: command not found` → one strike, no silent damage.
CLAUDE_ENV=""; SUB_LABEL=""
if [ "$HARNESS" = "claude" ]; then
  # FU-088: mark subscription-drawing pods for the concurrency semaphore's label-selector count
  SUB_LABEL=', "homelab.teststuff.net/subscription-session": claude'
  # Tier default: Haiku (fast, ~$0 marginal on subscription). An explicit --model wins.
  if [ "$MODEL" = "openrouter/deepseek/deepseek-v4-flash" ]; then MODEL="haiku"; fi
  GOOSE_MODEL="$MODEL"
  CLAUDE_ENV=$'        - name: ANTHROPIC_BASE_URL\n          value: "'"$PROXY_URL"$'/anthropic"\n        - name: ANTHROPIC_AUTH_TOKEN\n          value: "ref:'"$NS"$'/claude-session"\n        - name: CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC\n          value: "1"'
fi

# ADR-087 / FU-018 leg A (DEFAULT-ON for goose+proxy since 2026-07-10 — acceptance green on
# oracle-fleet#7/PR#12: full cycle incl. salvage-push + PR-open with zero pod credentials;
# AGENT_CRED_INJECT=0 opts out; opencode joined the rail 2026-07-16 — the FU-018 opencode leg:
# its session config points baseURL at the proxy, the pod key is the same opaque ref): the pod
# gets an OPAQUE REF instead of the real OpenRouter key — the egress proxy resolves ref→key
# (label-checked, per-namespace RBAC) and injects upstream. The ref is worthless outside the
# cluster.
OR_KEY_ENV="        - name: OPENROUTER_API_KEY
          valueFrom:
            secretKeyRef: { name: ${SECRET}, key: OPENROUTER_API_KEY }"
CRED_BROKER_ENV=""; OC_INJECT=""
if [ "$HARNESS" = "claude" ]; then
  OR_KEY_ENV=""   # subscription tier: no OpenRouter key at all — the pod's only cred is the claude ref
fi
if [ "${AGENT_CRED_INJECT:-1}" = "1" ] && [ -n "$PROXY_URL" ] && [ "$HARNESS" = "claude" ]; then
  # FU-089: claude rides join the broker path too — they used to lean on the standing in-ns
  # agent-git-token Secret (the optional fallback FU-089 deleted; found live: issue-135 r1,
  # clone died tokenless — the goose/opencode-only gate was the gap).
  echo "→ cred-inject (claude): git tokens fetched per-op from the proxy (FU-089)"
  CRED_BROKER_ENV="        - name: GIT_CRED_BROKER_URL
          value: \"${PROXY_URL}/git-token?ns=${NS}\""
fi
if [ "${AGENT_CRED_INJECT:-1}" = "1" ] && [ -n "$PROXY_URL" ] \
   && { [ "$HARNESS" = "goose" ] || [ "$HARNESS" = "opencode" ]; }; then
  echo "→ cred-inject: pod holds ref:${NS}/${SECRET}; git tokens fetched per-op from the proxy (ADR-087)"
  OR_KEY_ENV="        - name: OPENROUTER_API_KEY
          value: \"ref:${NS}/${SECRET}\""
  # leg B: the entrypoint's credential helper + gh wrapper fetch the live token per operation from
  # the proxy's /git-token endpoint — the env/mount below stay as fallback until FU-020 removes them.
  CRED_BROKER_ENV="        - name: GIT_CRED_BROKER_URL
          value: \"${PROXY_URL}/git-token?ns=${NS}\""
  if [ "$HARNESS" = "opencode" ]; then
    OC_INJECT=1
    # agent-finalize's or_usage() reads the key's usage via OPENROUTER_HOST — under injection the
    # pod key is a ref only the proxy can resolve, so the read MUST ride the proxy (opencode itself
    # ignores this env; its own traffic is routed by the baseURL merged into OC_CONFIG below).
    GOOSE_PROXY_ENV=$'        - name: OPENROUTER_HOST\n          value: "'"$PROXY_URL"'"'
  fi
fi
# Git credentials are broker-only (FU-089): every ride sets GIT_CRED_BROKER_URL and the pod holds
# no standing git Secret at all — the in-ns agent-git-token fallback was deleted with FU-089 (a
# standing token in a workbench-admin namespace was the cross-stack escalation the airlock exists
# to prevent). The per-op proxy fetch TokenReviews the pod's SA (GIT_TOKEN_REQUIRE_AUTH=1).

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
  [ -n "$OC_CONFIG" ] \
    && echo "→ opencode session pin: $(printf '%s' "$PIN_JSON" | jq -r '"\(.pinned_provider.provider) (effective $\(.pinned_provider.effective_per_mtok)/M in)"')" \
    || echo "→ opencode session pin unavailable (registry lookup failed / no eligible provider) — running unpinned"
  # FU-018 opencode leg: under cred injection, route opencode's OpenRouter traffic through the
  # egress proxy (deep-merged into the session config so the pin above survives) — the proxy
  # resolves the ref key exactly as for goose. Without injection opencode stays direct.
  # apiKey must be EXPLICIT here: once the config custom-configures the provider's options
  # (baseURL), opencode skips its env auto-detection and sends NO Authorization header at all —
  # the proxy 401s "Missing Authentication header" (validation ride adhoc-fu018, 2026-07-16).
  # The {env:...} placeholder resolves in-pod, so the ref never lands in the config file either.
  if [ -n "$OC_INJECT" ]; then
    OC_CONFIG="$(jq -cn --argjson base "${OC_CONFIG:-null}" --arg u "${PROXY_URL}/api/v1" '
      ($base // {"$schema": "https://opencode.ai/config.json"})
      * {provider: {openrouter: {options: {baseURL: $u, apiKey: "{env:OPENROUTER_API_KEY}"}}}}')"
    echo "→ opencode via egress proxy: baseURL ${PROXY_URL}/api/v1 (ADR-087; AGENT_CRED_INJECT=0 opts out)"
  fi
  if [ -n "$OC_CONFIG" ]; then
    # base64 keeps the JSON inert through the bash -c → jq -Rs → pod-yaml quoting layers.
    OC_SETUP="printf '%s' '$(printf '%s' "$OC_CONFIG" | base64 -w0)' | base64 -d > /tmp/opencode-session.json; "
    OC_ENV=$'        - name: OPENCODE_CONFIG\n          value: "/tmp/opencode-session.json"'
  fi
fi

if [ -n "$RUN_CMD" ]; then
  # Run the harness, tee its output to a file, then emit the AGENT_RUN_STATS line (agent-finalize
  # parses the run's structured outcome from that file + computes cost/duration). `set +e` so a
  # harness failure still runs finalize; the tee keeps the live stream intact for `kubectl logs -f`.
  # HARNESS_EXIT (the harness's own status, not tee's) feeds the transcript manifest (§A1).
  # All harnesses (incl. claude since agent-runtime#14 / the 2026-07-16 acceptance ride) take the
  # normal in-pod finalize path: tokens/turns + transcripts for subscription runs (FU-066 b). The
  # coordinator-image-era minimal-stats fallback is gone — an AGENT_BASE_IMAGE pin older than
  # agent-runtime#14 would fail loudly at `claude: command not found` long before finalize.
  # FU-120 belt: pin the agent-base harness profile on PATH for finalize. Its `#!/usr/bin/env
  # python3` shebang (+ the git/gh subprocesses it spawns) must resolve even if the ride left PATH
  # in a weird state — #71 r2 crashed here with `env: python3: not found` on a storming kata pod, so
  # the strike/report/salvage never ran. python IS baked + normally on PATH (agent-base/devbox.json,
  # /opt/agent/.devbox), so this guards that anomaly, not a missing dep. `\$PATH` expands in-pod.
  FINALIZE="HARNESS_EXIT=\${PIPESTATUS[0]} PATH=/opt/agent/.devbox/nix/profile/default/bin:\$PATH agent-finalize /tmp/run.log"
  WRAPPED="${OC_SETUP}set +e; { ${RUN_CMD} ; } 2>&1 | tee /tmp/run.log; ${FINALIZE}"
  ARGS="[\"bash\",\"-c\",$(printf '%s' "$WRAPPED" | jq -Rs .)]"
elif [ -n "$OC_SETUP" ]; then
  # Interactive opencode session: write the pin config, then idle for the exec below.
  ARGS="[\"bash\",\"-c\",$(printf '%s' "${OC_SETUP}exec sleep infinity" | jq -Rs .)]"
else
  ARGS="[\"sleep\",\"infinity\"]"       # idle after prep; you exec in below
fi

# §A1 transcript capture (docs/agents/observability-and-retro.md): fetch the WRITE-ONLY key for the
# agent-transcripts bucket and inject it as env VALUES below — a secretKeyRef can't cross namespaces
# (source of truth: agent-coordinator ns, written by the Crossplane Workspace
# agents/coordinator/garage-workspace.yaml; the AgentStack Composition mirrors it into each fixer
# namespace as an ExternalSecret — FU-080 a — and the pod secretKeyRefs it in-ns, so this launcher
# reads NO key material). Best-effort: without the mirror the run proceeds and agent-finalize
# skips the upload loudly.
TS_ENDPOINT="http://garage.garage.svc.cluster.local:3900"; TS_BUCKET="agent-transcripts"
PGW_URL="${AGENT_PUSHGATEWAY_URL:-http://prometheus-pushgateway.monitoring.svc.cluster.local:9091}"
if [ -n "$DOCKER" ]; then # FU-072: service VIPs unreachable from kata guests — ride on endpoint IPs
  EP="$(resolve_ep garage garage)";                          [ -n "$EP" ] && TS_ENDPOINT="http://${EP}:3900" || echo "→ docker mode: garage endpoint unresolvable — transcript upload will be skipped"
  EP="$(resolve_ep monitoring prometheus-pushgateway)";      [ -n "$EP" ] && PGW_URL="http://${EP}:9091" || echo "→ docker mode: pushgateway endpoint unresolvable — run metrics push will fail silently"
fi
"$KUBECTL" $KUBE -n "$NS" get secret agent-transcripts-s3 >/dev/null 2>&1 \
  || echo "→ transcript mirror agent-transcripts-s3 absent in ns ${NS} (claim not synced?) — run proceeds, upload will be skipped"

# Persistent uv (PyPI wheel) cache: if a `agent-uv-cache` PVC exists in the namespace, mount it so
# `devbox run ci`'s `uv sync` fetches wheels once across runs (the nix cache only covers `devbox
# install`). Optional — projects without the PVC just get an ephemeral cache. RWX so concurrent
# agent pods can share it; fsGroup below makes it writable for the non-root user.
UV_MOUNT=""; UV_VOLUME=""; UV_ENV=""
if "$KUBECTL" $KUBE -n "$NS" get pvc agent-uv-cache >/dev/null 2>&1; then
  UV_MOUNT=$'\n        - { name: uv-cache, mountPath: /uv-cache }'
  UV_VOLUME=$'\n    - name: uv-cache\n      persistentVolumeClaim: { claimName: agent-uv-cache }'
  # Point uv at the shared cache ONLY when it's actually mounted. Setting UV_CACHE_DIR=/uv-cache
  # without the mount makes uv `mkdir /uv-cache` at `/`, which the non-root (1000) user can't write —
  # "failed to create directory /uv-cache: Permission denied". Absent the mount, leaving UV_CACHE_DIR
  # unset lets uv fall back to its writable default (~/.cache/uv). Couple the two; never split them.
  UV_ENV=$'        - name: UV_CACHE_DIR\n          value: "/uv-cache"'
fi

# FU-096: the stack's CI-published devbox cache (eval seed + file:// store), mounted read-only
# via a k8s ImageVolume (verified on-cluster, oracle-fleet#106) — the entrypoint seeds ~/.cache
# and adds the substituter so the per-pod `devbox install` skips the eval tax. Mount ONLY when
# the :latest manifest is anonymously pullable (a missing/PRIVATE package would otherwise fail
# the whole pod at image-pull — probe-then-mount, degrade loudly to a cold ride). Anonymous is
# the same auth the kubelet pull uses (no imagePullSecrets on ride pods), so probe ≈ pullable.
# Kata rides included: ImageVolume-under-kata canaried green 2026-07-27 (read-only mount
# readable inside the microVM — both pilot stacks run fixer.docker, so kata IS the common case).
# AGENT_STACK_CACHE=0 opts out.
SC_MOUNT=""; SC_VOLUME=""
if [ "${AGENT_STACK_CACHE:-1}" = "1" ]; then
  SC_IMAGE="ghcr.io/teststuffstash/${PROJECT}/devbox-cache:latest"
  SC_TOKEN="$(curl -fsS --max-time 5 "https://ghcr.io/token?scope=repository:teststuffstash/${PROJECT}/devbox-cache:pull" 2>/dev/null | jq -r '.token // empty')" || SC_TOKEN=""
  if [ -n "$SC_TOKEN" ] && curl -fsSI --max-time 5 -H "Authorization: Bearer $SC_TOKEN" \
       -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json" \
       "https://ghcr.io/v2/teststuffstash/${PROJECT}/devbox-cache/manifests/latest" >/dev/null 2>&1; then
    echo "→ stack devbox-cache: mounting ${SC_IMAGE} (FU-096)"
    SC_MOUNT=$'\n        - { name: stack-cache, mountPath: /stack-cache, readOnly: true }'
    SC_VOLUME=$'\n    - name: stack-cache\n      image: { reference: "'"$SC_IMAGE"'", pullPolicy: Always }'
  else
    echo "→ stack devbox-cache absent for ${PROJECT} (no public :latest at ghcr) — cold bring-up (FU-096: publish via devbox-cache.reusable.yml + make the package public)"
  fi
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

# ── docker-mode pod fragments (kata microVM + dind sidecar; every accommodation is a spike
# finding, docs/spikes/kata-ci-gate.md): RuntimeClass kata schedules onto the kata-labeled
# laptops + tolerates the compute taint by itself. dnsPolicy None + LAN resolver = the FU-072
# workaround. The sidecar preamble: inotify sysctls (kubelet watches), mknod /dev/kmsg (kata
# guests lack it; kubelet/cadvisor hard-requires it — THE spike root cause), MTU clamp 1350,
# mkfs+mount /var/lib/docker from an ephemeral BLOCK PVC (longhorn-scratch, FU-081): kata
# hotplugs a block volume as virtio-blk — the one disk shape where overlay2 works in the guest
# (it can't stack on the virtiofs rootfs, and the earlier 2Gi tmpfs charged the dind cgroup —
# the full kind gate OOMed on image builds). --group=1000 lets the
# non-root agent use the socket; dockerd-entrypoint.sh (not raw dockerd) keeps the dind cgroup-v2
# nesting that gives inner containers the memory controller. Memory envelope: agent 2Gi + dind
# 2560Mi, layer store on disk ≈ the acceptance-proven ~5Gi VM with tmpfs headroom back — the
# ceiling on the 8G laptops (one docker ride per node; kata.tf).
KATA_BLOCK=""; DOCKER_ENV=""; DOCKER_MOUNT=""; DOCKER_VOLUMES=""; DIND_CONTAINER=""
AGENT_LIMITS='{ cpu: "6",    memory: "4Gi" }'   # install is partly CPU-bound; allow burst past 2
# ⚠ MEMORY requests MUST EQUAL limits (no overcommit) for agent workloads — 2026-07-27
# incident: the #48 docker ride requested 2Gi total but its kata VM grows to limits (~5Gi
# incl. RuntimeClass overhead); the scheduler placed it on a node with ~2Gi free and the
# KERNEL global-OOMed wk-metal-03, SIGKILLing longhorn-manager + cilium-agent as collateral.
# The "one docker ride per node" envelope (comment above) is only real if requests SAY so.
# CPU stays overcommitted deliberately: throttling is safe, and cpu=2 requests can't fit
# 2-core kata nodes.
AGENT_REQUESTS='{ cpu: "500m", memory: "4Gi" }'
if [ -n "$DOCKER" ]; then
  AGENT_LIMITS='{ cpu: "2", memory: "2Gi" }'    # heavy lifting moves into the dind sidecar
  AGENT_REQUESTS='{ cpu: "500m", memory: "2Gi" }'
  KATA_BLOCK=$'  runtimeClassName: kata\n  dnsPolicy: "None"\n  dnsConfig:\n    nameservers: ["192.168.2.1"]'
  # Pull-through mirrors (FU-073, argocd/resources/registry-cache/): docker.io rides the mirror
  # via dockerd registry-mirrors (Hub-only by dockerd design); the ghcr mirror is exported for
  # gate scripts (kind: certs.d/hosts.toml into the node, oracle-fleet#35). BGP VIPs, git-pinned —
  # reachable from kata guests where ClusterIPs are not (FU-072). NO upstream fallback once the
  # egress CNP drops the docker.io FQDNs: mirror down ⇒ pulls hang ⇒ AgentWorkerEgressDropped.
  MIRROR_DOCKER_IO="${AGENT_MIRROR_DOCKER_IO-http://192.168.40.20}"
  MIRROR_GHCR="${AGENT_MIRROR_GHCR-http://192.168.40.21}"
  # nix-cache via its BGP VIP (FU-073e): the entrypoint's default is the ClusterIP service DNS,
  # unreachable from a kata guest (FU-072) — without this override a docker ride's `devbox
  # install` fell back to cache.nixos.org over the WAN (~4 min cold, measured 2026-07-14).
  NIX_CACHE_VIP="${AGENT_NIX_CACHE_URL-http://192.168.40.23}"
  DOCKER_ENV=$'        - name: DOCKER_HOST\n          value: "unix:///docker-run/docker.sock"\n        - name: NIX_CACHE_URL\n          value: "'"$NIX_CACHE_VIP"$'"\n        - name: REGISTRY_MIRROR_DOCKER_IO\n          value: "'"$MIRROR_DOCKER_IO"$'"\n        - name: REGISTRY_MIRROR_GHCR\n          value: "'"$MIRROR_GHCR"$'"'
  DOCKER_MOUNT=$'\n        - { name: docker-run, mountPath: /docker-run }'
  DOCKER_VOLUMES=$'\n    - name: docker-run\n      emptyDir: {}\n    - name: docker-lib\n      ephemeral:\n        volumeClaimTemplate:\n          spec:\n            accessModes: ["ReadWriteOnce"]\n            volumeMode: Block\n            storageClassName: longhorn-scratch\n            resources: { requests: { storage: 20Gi } }'
  # NATIVE SIDECAR (initContainers + restartPolicy Always): the kubelet terminates it when the
  # main container completes — without this the pod sat phase=Running on a live dockerd after the
  # agent exited, wedging the WIP=1 pre-flight + the scan's project-WIP hold for 3 DAYS (found
  # 2026-07-21, the post-#56 queue stall).
  DIND_CONTAINER="$(cat <<'DIND'
  initContainers:
    - name: dind
      image: __DIND_IMAGE__
      restartPolicy: Always                   # ← what makes it a sidecar, not a blocking init
      securityContext: { privileged: true }   # root in the microVM only, not on the node (kata)
      command: ["sh", "-c"]
      args:
        - |
          sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512 >/dev/null || true
          mknod /dev/kmsg c 1 11 2>/dev/null || true
          # mount-first, mkfs on failure: busybox blkid exits 0 on a BLANK device, so it can't
          # be the "is it formatted" guard (learned live — dockerd fell back to the virtiofs
          # rootfs and overlay2 refused). Hard-fail instead of letting that happen again.
          mkdir -p /var/lib/docker
          mount /dev/docker-scratch /var/lib/docker 2>/dev/null \
            || { mkfs.ext4 -q /dev/docker-scratch && mount /dev/docker-scratch /var/lib/docker; } \
            || { echo "FATAL: scratch block volume mount failed"; exit 1; }
          mkdir -p /etc/docker && echo '{"mtu": 1350, "storage-driver": "overlay2", "registry-mirrors": ["__MIRROR_DOCKER_IO__"], "insecure-registries": ["__MIRROR_HOST__"]}' > /etc/docker/daemon.json
          exec dockerd-entrypoint.sh dockerd --host=unix:///run/docker.sock --group=1000
      volumeMounts:
        - { name: docker-run, mountPath: /run }
      volumeDevices:
        - { name: docker-lib, devicePath: /dev/docker-scratch }
      resources:
        requests: { cpu: "500m", memory: "2560Mi" }  # = limit (no memory overcommit; wk-metal-03 global-OOM 2026-07-27)
        limits:   { cpu: "2",    memory: "2560Mi" }
DIND
)"
  DIND_CONTAINER="${DIND_CONTAINER/__DIND_IMAGE__/${AGENT_DIND_IMAGE:-ghcr.io/k3d-io/k3d:5-dind}}"
  DIND_CONTAINER="${DIND_CONTAINER/__MIRROR_DOCKER_IO__/${MIRROR_DOCKER_IO}}"
  DIND_CONTAINER="${DIND_CONTAINER/__MIRROR_HOST__/${MIRROR_DOCKER_IO#http://}}"
fi

# FU-088(a): a claude-harness worker draws on the one operator subscription — defer the spawn
# while the egress proxy's 429 latch / utilization threshold / concurrency semaphore says so
# (OpenRouter harnesses are unaffected).
if [ "$HARNESS" = "claude" ] && ! bash "$HERE/subscription-latch.sh"; then
  echo "→ ${PROJECT} claude-tier dispatch deferred — subscription limited (FU-088)"
  exit 0
fi

# FU-088(b): account-level OpenRouter credit gate — credit exhaustion otherwise surfaces only as
# per-pod 402 retry storms AFTER spawn (agent-runtime#8 hard-stops in-pod; this saves the spawn).
# Probes the account's credit balance through the proxy with the pod's own opaque ref — no key
# material touches this launcher. Fail-open on any probe failure.
if [ "$HARNESS" != "claude" ] && [ -n "$PROXY_URL" ] && [ "${AGENT_CREDIT_GATE:-1}" = "1" ]; then
  OR_MIN="${OPENROUTER_MIN_CREDIT:-0.25}"
  credits="$(curl -fsS --max-time 10 -H "Authorization: Bearer ref:${NS}/${SECRET}" \
    "$PROXY_URL/api/v1/credits" 2>/dev/null \
    | jq -r 'try ((.data.total_credits // empty) - (.data.total_usage // 0)) catch empty' 2>/dev/null)" || credits=""
  if [ -n "$credits" ] && awk -v c="$credits" -v m="$OR_MIN" 'BEGIN { exit !(c < m) }'; then
    echo "→ ${PROJECT} dispatch deferred — OpenRouter account credit \$${credits} below the \$${OR_MIN} floor (FU-088b; top up, or OPENROUTER_MIN_CREDIT / AGENT_CREDIT_GATE=0 to override)"
    exit 0
  fi
fi

# The atomic gate: reap a TERMINAL same-key holder, refuse a LIVE one, then `create` (NOT apply —
# apply would silently adopt/patch an existing pod and the whole idempotency story dies).
case "$TASK" in issue-[0-9]*|pr-[0-9]*)
  EXISTING_PHASE="$("$KUBECTL" $KUBE -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "$EXISTING_PHASE" in
    Succeeded|Failed)
      echo "→ reaping terminal same-key pod ${POD} (${EXISTING_PHASE}) before re-dispatch"
      "$KUBECTL" $KUBE -n "$NS" delete pod "$POD" --ignore-not-found >/dev/null 2>&1 || true;;
    "") :;;  # no holder — create proceeds
    *)
      echo "PREFLIGHT REFUSED: pod ${POD} already ${EXISTING_PHASE} — (task=${TASK}, round=${ROUND}) is owned; resume/wait, don't fork (workflow.md idempotency key)." >&2
      exit 3;;
  esac
;; esac
cat <<EOF | "$KUBECTL" $KUBE -n "$NS" create -f - \
  || { echo "PREFLIGHT REFUSED (atomic): create of ${POD} failed — a racing dispatcher won the (task, round) key, or the manifest is invalid (see kubectl error above)." >&2; exit 3; }
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  labels: { app: agent-session, project: ${PROJECT}${SUB_LABEL} }
spec:
  restartPolicy: Never
  # homelab#22: total-session wall clock. No bound existed (200 turns × ~5min slow-model turns
  # ≈ 16h theoretical); 4h matches the session key's TTL (estimate_budget.py --ttl-hours) — past
  # it the ride can only 401-storm anyway. K8s kills with reason DeadlineExceeded; the launcher
  # classifier below maps that to a `timeout` strike, so the chain re-dispatches on the next model.
  activeDeadlineSeconds: ${AGENT_POD_DEADLINE_S:-14400}
  # FU-089: the worker's PROVABLE identity — the proxy's /git-token TokenReviews this SA's
  # projected token (Composition renders the SA per fixer ns; no RBAC grants attached).
  serviceAccountName: agentstack-worker
  terminationGracePeriodSeconds: 5
${AFFINITY}
${KATA_BLOCK}
  securityContext:
    fsGroup: 1000          # make the shared uv-cache RWX volume writable for the non-root (1000) user
${DIND_CONTAINER}
  containers:
    - name: agent
      image: ${IMAGE}
      args: ${ARGS}
      env:
        # devbox self-update phone-home (releases.jetify.com) is DENIED by the egress CNP —
        # correctly, but 3 drops/min per ride kept AgentWorkerEgressDropped warm (2026-07-21).
        # Disable the check instead of widening policy for telemetry. 2026-07-22: the update-check
        # var alone did NOT silence it (live drops to 104.18.18/19.165:443 = releases.jetify.com
        # from a ride that HAD the var) — devbox telemetry is a separate phone-home; belt both.
        - name: DEVBOX_NO_UPDATE_CHECK
          value: "1"
        - name: DO_NOT_TRACK
          value: "1"
        - name: DEVBOX_DISABLE_TELEMETRY
          value: "1"
        # 2026-08-02, third phone-home path: the /usr/local/bin/devbox LAUNCHER (jetify's wrapper
        # script) ignores all of the above — without DEVBOX_USE_VERSION it re-downloads
        # releases.jetify.com/devbox/stable/version whenever ~/.cache/devbox/current-version is
        # older than VERSION_CACHE_TTL (24h default; the devbox-cache PVC keeps the file, so it
        # goes stale between image builds and EVERY ride's first devbox call phones home). A year
        # of TTL pins the launcher to the cached version without hardcoding it here.
        - name: VERSION_CACHE_TTL
          value: "31536000"
        # FU-118(b): `devbox add` resolves through the in-cluster search proxy (VIP, kata-reachable
        # like the other package proxies) instead of the WAN — so a mid-ride add gets a REAL store
        # path in devbox.lock, not the offline `placeholder-*` that boot-crashes the next round.
        # argocd/resources/devbox-search/ + ip-plan.md; the egress CNP allows .40.27 (composition.yaml).
        - name: DEVBOX_SEARCH_HOST
          value: "http://192.168.40.27"
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
        # Retro r1 F6: dispatch timestamp — finalize records queue_wait_s = dispatch → pod
        # start, so ledger wall times stop conflating queue with compute.
        - name: AGENT_DISPATCH_EPOCH
          value: "$(date +%s)"
        - name: AGENT_SESSION_KEY
          value: "${SECRET}"
        - name: AGENT_TS_ENDPOINT
          value: "${TS_ENDPOINT}"
        - name: AGENT_TS_BUCKET
          value: "${TS_BUCKET}"
        # FU-080 (a): the write-only transcripts key is mirrored INTO each fixer namespace by the
        # AgentStack Composition (ClusterSecretStore agent-transcripts) — referenced in-ns, so the
        # launcher never touches key material. optional:true = a namespace without the mirror
        # (claim not synced yet) still runs; agent-finalize skips the upload loudly.
        - name: AGENT_TS_ACCESS_KEY_ID
          valueFrom:
            secretKeyRef: { name: agent-transcripts-s3, key: writer_access_key_id, optional: true }
        - name: AGENT_TS_SECRET_ACCESS_KEY
          valueFrom:
            secretKeyRef: { name: agent-transcripts-s3, key: writer_secret_access_key, optional: true }
        # FU-057 §B1: agent-finalize PUTs this run's cost/duration/outcome here (goose has no OTLP
        # rail). Cross-namespace to the monitoring pushgateway; unset it to disable the push.
        - name: AGENT_PUSHGATEWAY_URL
          value: "${PGW_URL}"
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
        # Second belt behind the runtime storm watchdog (agent-runtime#8, FU-021 — both proven
        # live on sleep-tracking#20): on a dead key goose's final-output continuation loops fresh
        # requests until max_turns (default 1000). 200 clears every legit run measured (owl 72,
        # the pathological qwen loop 187) and bounds anything the watchdog somehow misses.
        - name: GOOSE_MAX_TURNS
          value: "${GOOSE_MAX_TURNS:-200}"
${OR_KEY_ENV}
        # Git credential (ADR-087 leg B / FU-089): the pod holds NO git token — the entrypoint's
        # credential helper + gh wrapper fetch a live token per operation from the proxy's
        # /git-token endpoint, which TokenReviews the pod's SA (GIT_TOKEN_REQUIRE_AUTH=1). The
        # old standing in-ns agent-git-token fallback was deleted with FU-089.
${CRED_BROKER_ENV}
        # Ledger-backfill anchor (FU-057): the operator writes the OpenRouter key HASH into the
        # session Secret; finalize surfaces it in stats so cost_unknown runs stay accountable.
        - name: OPENROUTER_KEY_HASH
          valueFrom:
            secretKeyRef: { name: ${SECRET}, key: KEY_HASH, optional: true }
        # Resume an existing remote branch deterministically (fix rounds / salvaged WIP — finding C).
        # Empty ⇒ the entrypoint forks a fresh agent/<ts> branch from BASE_REF as before.
${WORK_BRANCH_ENV}
${ARM_ENV}
        # docker mode only: the repo's own docker CLI (devbox.json) talks to the dind sidecar.
${DOCKER_ENV}
        # claude harness only (FU-066): proxy base URL + the opaque session ref — no real creds.
${CLAUDE_ENV}
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000           # jetpackio/devbox 'devbox' user; numeric so k8s can verify non-root
        runAsGroup: 1000
        allowPrivilegeEscalation: false
        capabilities: { drop: ["ALL"] }
        seccompProfile: { type: RuntimeDefault }
      resources:
        requests: ${AGENT_REQUESTS}
        limits:   ${AGENT_LIMITS}
      volumeMounts:${UV_MOUNT}${DOCKER_MOUNT}${SC_MOUNT}
  volumes:${UV_VOLUME}${DOCKER_VOLUMES}${SC_VOLUME}
EOF

echo "→ waiting for ${POD} (a cold node may pull the image + nix store for minutes)…"
"$KUBECTL" $KUBE -n "$NS" wait --for=condition=Ready pod/"${POD}" --timeout=600s || true

if [ -n "$RUN_CMD" ]; then
  # Follow logs to termination — resiliently. `logs -f` FAILS while the container is still
  # ContainerCreating (slow image pull), and under set -e + pipefail that used to kill the launcher
  # before ANY post-run bookkeeping — i.e. exactly the runs the strike path exists for died
  # untracked (found live: the FU-021 acceptance run, 2026-07-09). Retry while the pod is
  # Pending/Running; a clean `logs -f` exit means the container terminated. Each attempt restreams
  # from the start, so plain tee keeps RUNLOG = one complete copy.
  RUNLOG="$(mktemp)"
  DEADLINE=$(( $(date +%s) + ${AGENT_LOG_DEADLINE_S:-1800} ))
  while :; do
    if "$KUBECTL" $KUBE -n "$NS" logs -f "${POD}" 2>/dev/null | tee "$RUNLOG"; then break; fi
    PHASE="$("$KUBECTL" $KUBE -n "$NS" get pod "${POD}" -o jsonpath='{.status.phase}' 2>/dev/null || echo Gone)"
    case "$PHASE" in
      Pending|Running|Unknown) ;;
      *) break ;;   # Succeeded/Failed/Gone — grab whatever logs exist below and move on
    esac
    if [ "$(date +%s)" -ge "$DEADLINE" ]; then
      echo "→ gave up following ${POD} after $((${AGENT_LOG_DEADLINE_S:-1800}/60))min (phase: ${PHASE}) — bookkeeping continues on partial logs"
      break
    fi
    sleep 5
  done
  # Terminal-but-empty (pod failed before/without streaming): one non-follow dump so the
  # classification below has something to read.
  [ -s "$RUNLOG" ] || "$KUBECTL" $KUBE -n "$NS" logs "${POD}" > "$RUNLOG" 2>/dev/null || true
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
    # FU-064/FU-043: bookkeeping now runs IN-POD (agent-finalize) so it survives this launcher
    # exiting early (the coordinator path). Everything below is the FALLBACK for pre-mount images /
    # in-pod failures — the *_by_pod flags on the stats line say what already happened.
    ARMED_BY_POD="$(printf '%s' "$STATS" | jq -r '.armed_by_pod // false' 2>/dev/null)"
    COMMENT_BY_POD="$(printf '%s' "$STATS" | jq -r '.stats_comment_by_pod // false' 2>/dev/null)"
    STRIKE_BY_POD="$(printf '%s' "$STATS" | jq -r '.strike_by_pod // false' 2>/dev/null)"
    if [ "$ARMED_BY_POD" = "true" ] && [ "$COMMENT_BY_POD" = "true" ]; then
      echo "→ PR bookkeeping done in-pod (armed + stats comment) — launcher fallback skipped"
      PR_BOOKKEEPING_DONE=1
    else
      PR_BOOKKEEPING_DONE=""
    fi
    if [ -n "$PR_URL" ] && [ -z "$PR_BOOKKEEPING_DONE" ] && [ -n "${GH_TOKEN:-}" ]; then
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
  # Strike semantics apply only to TASKED rides (issue-*/pr-*) — an adhoc ride (validation,
  # experiment) expects no PR; striking it is noise (the finalize-side twin landed in
  # agent-runtime#16 the same day).
  case "$TASK" in issue-*|pr-*) STRIKE_APPLIES=1;; *) STRIKE_APPLIES="";; esac
  if [ -n "$STRIKE_APPLIES" ] && [ -z "$PR_URL" ] && [ "${STRIKE_BY_POD:-false}" != "true" ]; then
    if [ -n "$STATS" ]; then
      # agent-finalize already classified the run (authoritative — it saw the full log + exit code).
      # Its exit_status maps onto the strike taxonomy; anything else (failed/no-output/ci-failed
      # without a PR) is "unknown" — still a strike, just an unclassified one.
      ERR_CLASS="$(printf '%s' "$STATS" | jq -r '
        (.exit_status // "") as $s
        | if $s == "no-artifact" then (.error_class // "no-pr")
          elif (["harness-death","auth-storm","budget-403","timeout"] | index($s)) then $s
          else "unknown" end' \
        2>/dev/null || echo unknown)"
    else
      # No AGENT_RUN_STATS line at all = finalize never ran (the pod died hard / wait timed out) —
      # the PR-less death that used to be invisible. Classify the raw log jail-side with the same
      # signatures agent-finalize uses (that script is the authoritative copy of these patterns).
      # homelab#22: an activeDeadlineSeconds kill leaves no log signature at all — the pod's
      # status.reason is the only evidence, and it maps to the `timeout` strike class.
      POD_REASON="$("$KUBECTL" $KUBE -n "$NS" get pod "$POD" -o jsonpath='{.status.reason}' 2>/dev/null || true)"
      if [ "$POD_REASON" = "DeadlineExceeded" ]; then
        ERR_CLASS="timeout"
      elif grep -qiE -e '-32602|EOF while parsing|response may have been truncated|context_length_exceeded|panicked at' "$RUNLOG"; then
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

  # ROUTER REPORT (ADR-096, M5 attribution): every run's outcome → POST /report on the egress
  # proxy's control plane — run_reports + (for strike-class errors without a PR) the queryable
  # strike row the /route filter reads. The AGENT_STRIKE comment above stays the human/audit
  # twin; this is the machine one. Best-effort + idempotent per session (INSERT OR REPLACE):
  # unreachable off-cluster (jail runs — the ClusterIP doesn't cross the BGP boundary) is fine.
  if [ -n "$PROXY_URL" ] && { [ -n "$STATS" ] || [ -n "${ERR_CLASS:-}" ]; }; then
    _rstack="$(jq -r --arg r "$PROJECT" '.stacks[]|select([.repos[]]|index($r))|.name' "${HERE}/stacks.json" 2>/dev/null | head -1)"
    _report="$(jq -cn --arg session "$POD" --arg task "$TASK" --arg stack "${_rstack:-}" \
      --arg model "$MODEL" --arg round "$ROUND" --arg err "${ERR_CLASS:-}" --arg pr "$PR_URL" \
      --argjson stats "${STATS:-null}" '
      {session: $session, task: $task, stack: $stack, role: "worker",
       round: ($round | tonumber? // 1), model: $model,
       cost_usd: (($stats.cost_usd? // 0) | tonumber? // 0),
       error_class: (if $err != "" then $err else ($stats.error_class? // "") end),
       outcome: (if $pr != "" then "pr" else ($stats.exit_status? // "no-pr") end)}' 2>/dev/null)"
    if [ -n "$_report" ]; then
      curl -fsS -m 5 -X POST -H 'Content-Type: application/json' \
        -d "$_report" "${PROXY_URL}/report" >/dev/null 2>&1 \
        && echo "→ router report posted (${PROXY_URL}/report)" \
        || echo "  (router report unreachable — non-fatal, jail runs land here)"
    fi
  fi
  # FU-085: ring the coordinator doorbell — a tasked worker's terminal state is scan-actionable
  # (C4/C5 re-dispatch, strike chain-walk, C6 bookkeeping). Doorbell, never a work item: the scan
  # re-lists and re-applies the full predicate; a false wake costs `gh` calls, not an LLM tick.
  # Fail-open: unreachable off-cluster (jail runs — the cron backstop covers those).
  if [ -n "$STRIKE_APPLIES" ]; then
    # FU-080 doorbell routing: if PROJECT belongs to a GRADUATED stack, carry {stack,loop_ns} so the
    # global `coordinator` Sensor's per-stack trigger inlines a Workflow INTO <loop_ns> (data-driven).
    # Non-graduated / unresolvable → plain {repo} (the global scan handles it). Best-effort: a miss
    # only costs edge latency — the stack's */10 cron still ticks. loop_ns is <stack>-agents by convention.
    _grad="$(jq -r --arg r "$PROJECT" '.stacks[]|select((.graduated // false)==true)|select([.repos[]]|index($r))|.name' "${HERE}/stacks.json" 2>/dev/null | head -1)"
    if [ -n "$_grad" ] && [ "$_grad" != "null" ]; then
      _door="{\"repo\":\"${PROJECT}\",\"stack\":\"${_grad}\",\"loop_ns\":\"${_grad}-agents\"}"
    else
      _door="{\"repo\":\"${PROJECT}\"}"
    fi
    # Content-Type: application/json so the eventsource PARSES body.repo/stack/loop_ns as fields —
    # without it curl sends form-urlencoded and the whole JSON becomes one body KEY (the Sensor's
    # data filters then can't see body.loop_ns, so the per-stack routing never fires).
    curl -m 5 -s -X POST -H "Content-Type: application/json" -d "$_door" \
      "${AGENT_LOOP_WEBHOOK:-http://agent-loop-eventsource-svc.agent-coordinator.svc.cluster.local:12000}/coordinate" \
      >/dev/null 2>&1 && echo "→ coordinator doorbell rung (/coordinate ${_door})" || true
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
