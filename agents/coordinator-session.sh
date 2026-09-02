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
#   kubectl --kubeconfig tofu/kubeconfig apply -f agents/coordinator/claude-token.yaml   # ESO → coordinator-claude (+ the proxy ref RBAC)
#   kubectl --kubeconfig tofu/kubeconfig apply -f agents/coordinator/git-token.yaml      # ESO → coordinator-git
#   # the image is built+pushed by CI in the teststuffstash/agent-coordinator repo — no manual build.
#   # LLM auth = the ADR-087 ref rail (FU-066d): the pod holds ref:agent-coordinator/coordinator-claude,
#   # the egress proxy injects the subscription token — no raw ~1y token in any pod.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Jail (cockpit) uses tofu/kubeconfig; inside the reflex pod the file doesn't exist (gitignored,
# absent from the clone) — fall back to the pod ServiceAccount, same pattern as agent-session.sh.
# First exercised by the first autonomous C4/C5 spawn (meta-7): the hardcoded path killed the tick.
if [ -f "${HERE}/../tofu/kubeconfig" ]; then KUBE="--kubeconfig ${HERE}/../tofu/kubeconfig"; else KUBE=""; fi
# kubectl isn't on the bare jail PATH (devbox/nix tool); fall back to the devbox profile.
KUBECTL="$(command -v kubectl || true)"
[ -n "$KUBECTL" ] || KUBECTL="${HERE}/../.devbox/nix/profile/default/bin/kubectl"

# The canonical reconcile-TICK prompt — the exact instruction a future coordinator reflex (a CronJob,
# the LLM sibling of review-reflex.sh) would inject each tick. Kept here as ONE source of truth so an
# interactive first-run (--tick) and the eventual headless reflex (--run-tick) use identical wording.
# Level-triggered, covers BOTH lanes (agent-fix issues + the coordinator-owned `major` devbox PRs).
TICK_PROMPT="You are running IN the coordinator pod: tools (gh/kubectl/python3/jq) are on PATH and called directly — there is NO devbox and NO tofu/kubeconfig here (kubectl auths via the pod ServiceAccount). Do ONE reconcile pass as the coordinator, per your brief (agents/coordinator/README.md). Re-list the world level-triggered, holding no state: open agent-fix issues across the stack repos (actionable = labelled agent/queued) and open PRs labelled major that are not yet major/awaiting-human (the coordinator-owned devbox-bump lane). Pick the single highest-priority actionable item; CLAIM it first (relabel + a one-line plan comment) before investigating; then take exactly the next action its state calls for per the brief. Keep every bit of state in GitHub labels and comments. Never merge by hand and never touch the review reflex armed PRs. If nothing is actionable, say so and stop."

RUN_CMD=""; SEED=""; STACK=""; STACK_REPOS=""; MAIN_REPO="homelab"; BASE_REF="master"; MODEL="opus"; PERM_MODE="bypassPermissions"; NO_ATTACH=""; ITEM=""; WIP_LIMIT="1"; JANITOR=""; DETACH=""
REPO_URL="${REPO_URL:-https://github.com/teststuffstash/homelab.git}"
ORG="${ORG:-teststuffstash}"   # org the stack repos live under (for `gh repo clone <org>/<repo>`)
while [ $# -gt 0 ]; do
  case "$1" in
    --run)             RUN_CMD="$2"; shift 2;;
    --run-tick)        RUN_CMD="$TICK_PROMPT"; shift;;   # headless one tick (the reflex's call)
    --item)            ITEM="$2"; shift 2;;               # ADR-094/FU-086: reconcile ONE unit — "<repo> <issue-N|pr-N> <clause>"
    --wip)             WIP_LIMIT="$2"; shift 2;;          # ADR-097: launcher-owned AGENT_WIP_LIMIT for this item's repo (scan-computed, never LLM-assembled)
    --janitor)         JANITOR=1; shift;;                 # FU-086(4): the daily report-only judgment tick (README §The janitor tick)
    --loop-ns)         LOOP_NS_ARG="$2"; shift 2;;        # FU-080 perStack: run the tick pod in <stack>-agents as agentstack-loop; git creds fetched per-op from the proxy's TokenReview-gated /loop-git-token (no Secrets in that ns)
    --tick)            SEED="$TICK_PROMPT"; shift;;       # interactive, seeded with the canonical prompt
    --seed)            SEED="$2"; shift 2;;               # interactive, seeded with your prompt
    --stack)           STACK="$2"; shift 2;;              # scope this session to a stack (agents/stacks.json)
    --repos)           STACK_REPOS="$2"; shift 2;;        # the stack's repos, space-separated
    --main-repo)       MAIN_REPO="$2"; shift 2;;          # the stack's MAIN repo — cwd + its CLAUDE.md/specs (default homelab)
    --ref)             BASE_REF="$2"; shift 2;;
    --repo)            REPO_URL="$2"; shift 2;;
    --model)           MODEL="$2"; MODEL_SET_EXPLICIT=1; shift 2;;       # sonnet|opus|haiku|fable|<full-id>. Default opus (needs Max); --model sonnet to save.
    --permission-mode) PERM_MODE="$2"; shift 2;;   # default|acceptEdits|plan|auto|dontAsk|bypassPermissions
    --no-attach)       NO_ATTACH=1; shift;;
    --detach)          DETACH=1; shift;;      # ADR-106 (5): headless only — exit at pod-Ready; the POD uploads, pushes its session row, and rings the completion doorbell itself (the caller's mutex must not span the ride)
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

# ── resolve model via /route (G-A 8, issue #781) ──────────────────────────────────────────
# The tick/janitor/item session resolves its model through the router. Item sessions pass
# their clause so the router's class policy distinguishes goal-decompose (reasoning tier,
# class=goal-decompose) from ordinary dispatch (class=dispatch, via role_defaults).
# The --model flag value carries TWO cases with opposite routing intent (the ADR-096 override
# rule — the block below distinguishes them): a scan-supplied coordinatorModel is a FALLBACK
# (route consulted, fail-OPEN if the proxy is unreachable); an explicit operator --model is an
# OVERRIDE (route skipped). GOAL_MODEL env survives as the explicit escape hatch for
# goal-decompose items (deleted in the sweep).
# Override-rule home: docs/agents/model-routing.md §M10.
RESOLVE_CLASS=""
if [ -n "$ITEM" ]; then
  # Parse the clause from --item to set the routing class:
  #   "repo=<r> item=<i> clause=goal-decompose ..." → class=goal-decompose
  _item_clause=""
  for _itf in $ITEM; do
    case "$_itf" in
      clause=*) _item_clause="${_itf#clause=}"; break;;
    esac
  done
  case "$_item_clause" in
    goal-decompose|goal-checkpoint) RESOLVE_CLASS="goal-decompose";;
  esac
fi
# ── ADR-096 override rule: explicit operator --model vs scan-supplied default ──
# The same $MODEL variable holds TWO things with opposite routing intent:
#   (a) The scan-supplied coordinatorModel (or the opus default) — SHOULD be a fallback,
#       the route is consulted first. This is the ordinary dispatch path.
#   (b) An operator-passed --model on the command line — IS an explicit override, the
#       route must be skipped.
# We distinguish them by MODEL_SET_EXPLICIT (set when --model was passed to THIS script).
# For (a) → --fallback (route consulted, fail-OPEN to the scan default if routing unreachable).
# For (b) → --model (route SKIPPED, the override wins unconditionally per ADR-096).
# GOAL_MODEL is handled below, not via resolve-model's --model/AGENT_MODEL.
if [ -n "${MODEL_SET_EXPLICIT:-}" ]; then
  # Explicit operator --model: override wins over the route (ADR-096 override rule).
  # resolve-model.sh checks --model / AGENT_MODEL first and exits before calling /route.
  RESOLVED="$(bash "${HERE}/resolve-model.sh" --role coordinator --class "${RESOLVE_CLASS:-dispatch}" --model "$MODEL" --fallback "$MODEL" 2>/dev/null)" || RESOLVED=""
else
  # Scan-supplied default (coordinatorModel) or script default: use as fallback,
  # the route is actually consulted. Fail-OPEN when the proxy is unreachable.
  _fb="${MODEL:-sonnet}"
  [ "$RESOLVE_CLASS" = "goal-decompose" ] && _fb="${GOAL_MODEL:-opus}"
  RESOLVED="$(bash "${HERE}/resolve-model.sh" --role coordinator --class "${RESOLVE_CLASS:-dispatch}" --fallback "$_fb" 2>/dev/null)" || RESOLVED=""
fi
# >>>REPLAY:coordinator-adopt-model>>>
if [ -n "$RESOLVED" ]; then
  echo "→ coordinator model: role=coordinator class=${RESOLVE_CLASS:-dispatch} → ${RESOLVED}" >&2
  # The routed answer is a FULL rail-prefixed id (claude/fable) — the claude CLI takes the BARE
  # alias. Parse through the ONE parser (FU-127, the worker launcher's exact move at its
  # model-id-resolution block); a subscription-rail answer yields MODEL_MODEL=<alias>. Found
  # live 2026-08-23 on goal #818's decompose: PR#801 shipped this adoption un-parsed and the
  # class DEFERRED until PR#813 gave it a chain_head, so the first genuinely-routed session was
  # the first to pass claude/fable verbatim to --model and die at model selection.
  eval "$(python3 "${HERE}/model_id.py" --shell "$RESOLVED")"
  MODEL="${MODEL_MODEL:-$RESOLVED}"
fi
# <<<REPLAY:coordinator-adopt-model<<<
# >>>REPLAY:coordinator-goal-model>>>
# GOAL_MODEL env escape hatch: if set and this is a goal-decompose item, it wins unconditionally.
if [ -n "${GOAL_MODEL:-}" ] && [ "$RESOLVE_CLASS" = "goal-decompose" ]; then
  echo "→ coordinator model: GOAL_MODEL=${GOAL_MODEL} wins (env escape hatch, goal-decompose)" >&2
  MODEL="$GOAL_MODEL"
fi
# <<<REPLAY:coordinator-goal-model<<<

# Per-stack scope: prepend the stack context to the prompt so the coordinator knows exactly
# which repos are its world this session, and expose it as pod env for forward-compat. Policy will move
# to a Crossplane AgentStack claim in the stack's -iac repo (docs/agents/platform-and-stacks.md); for
# now coordinator-scan.sh passes --stack/--repos from agents/stacks.json.
# ADR-094/FU-086 item mode: the deterministic scan already DECIDED what and when (clause,
# lane-free, deps-closed, dispatchable, capacity) — this session judges HOW for exactly one unit.
# Doorbell semantics: at-least-once delivery means the unit may be stale on arrival; re-read first
# and exit clean when it is. The whole-stack TICK_PROMPT survives as the janitor/manual path.
# homelab#158: the prompt ends with the RAIL RULE. The key mint is the one dispatch step still made by
# LLM judgment (the brief's steps 3-4), which is exactly why it failed the way it did on
# 2026-08-08 — a claudeTier claim's rides deferred on an OpenRouter mint they never needed. The
# launcher enforces the same invariant deterministically for anything it is handed
# (agent-session.sh, homelab#158 leg 1); this sentence is what stops the session from never getting
# there. Launcher-owned text, per ADR-094 — not something the session is expected to remember.
if [ -n "$ITEM" ]; then
  [ -n "$RUN_CMD" ] && { echo "--item and --run/--run-tick are mutually exclusive" >&2; exit 2; }
  RUN_CMD="You are running IN the coordinator pod: tools (gh/kubectl/python3/jq) are on PATH and called directly — there is NO devbox and NO tofu/kubeconfig here (kubectl auths via the pod ServiceAccount). Reconcile EXACTLY ONE work unit as the coordinator, per your brief (agents/coordinator/README.md): ${ITEM} (format: repo, item, clause — the clause is WHY the deterministic scan dispatched you — and OPTIONALLY parent=<n>, meaning this item is one child of GOAL issue #<n>. When parent= is present, re-read that goal BEFORE acting and judge this item against the GOAL's acceptance, not only its own: the goal is what the work is finally measured against, and nothing else in the loop will reconnect the two. If finishing this child would leave the goal's acceptance unreachable, say so on the parent — do not silently widen this item.) FIRST re-read the item's live state (labels, PR/issue state, worker pods): dispatch is at-least-once and level-triggered, so if the unit is no longer actionable — already claimed with a live worker, already armed/approved/merged, labels moved on — say so and EXIT CLEAN having touched nothing. Otherwise CLAIM it (relabel + a one-line plan comment) and take exactly the next action its state calls for per the brief; the judgment calls (triage completeness, budget sizing, arbitration per the meta-4 doctrine) are yours, inside this one item. Do NOT go looking for other work — scheduling (which item, lanes, capacity) is the scan's job, not yours. Keep every bit of state in GitHub labels and comments. Never merge by hand and never touch the review reflex's armed PRs. RAIL RULE (homelab#158, launcher-owned — it overrides any recollection of the brief's dispatch steps): if this repo's claim is claudeTier — its \`workerModel\` is a \`claude/*\` id — the OpenRouter key mint is that ride's FALLBACK rail, not its prerequisite. SKIP the estimate/mint steps entirely and dispatch on the subscription (no \`--openrouter-secret\`; agent-session.sh derives \`--harness claude\` from the model prefix). A failed, rate-limited or deferred key mint must NEVER defer a claude-tier dispatch: on 2026-08-08 four of them deferred on a mint they did not need while the subscription rail sat at 2 of 5 slots. The ONE capacity condition that defers a claude-tier ride is the FU-088 subscription latch, and the launcher probes that itself — so dispatch and let it decide."
fi
# FU-086(4) janitor mode: the ~daily REPORT-ONLY judgment tick (ADR-094 (4) — board-level
# breadth the clause code can't have). Its entire write surface is INERT spec-gap drafts
# (issue-authoring leg b, breaker #1); everything else is read + report.
if [ -n "$JANITOR" ]; then
  [ -n "$RUN_CMD" ] && { echo "--janitor and --item/--run/--run-tick are mutually exclusive" >&2; exit 2; }
  RUN_CMD="You are running IN the coordinator pod: tools (gh/kubectl/python3/jq) are on PATH and called directly — there is NO devbox and NO tofu/kubeconfig here (kubectl auths via the pod ServiceAccount). Run the DAILY JANITOR TICK for this stack, per your brief (§'The janitor tick' in agents/coordinator/README.md): REPORT-ONLY board-level judgment. You dispatch NOTHING, claim nothing, and change NO labels or merge state; your one permitted write is filing INERT draft issues for genuine spec/TRACKS gaps (never agent-fix or agent/queued — loop-safety breaker #1). Work the six sweeps in order — (1) STARVATION: re-list queued/actionable state and compare against recent activity; anything queued or reported for days with zero movement is the headline finding, because a scan-clause bug makes starved work look quiet; (2) ORPHAN AGING: judge the scan's report-only classes (bot-authored 🌱 drafts, queued-blocked, un-armed PRs, footprint-held) for staleness — still valid, or rotting?; (3) DIRECTION-CHANGE: read issues labelled direction-change and summarize what they imply for queued work; (4) CROSS-PR SMELLS: open PRs colliding on files, stale branches, and diffs that escaped their issue's declared Touches: footprint (ADR-097); (5) SPEC GAPS: MAY file inert drafts for real spec/TRACKS gaps, deduped against open issues; (6) TOOL-GAP INVENTORY: aggregate the TOOL_GAP: marker lines across this stack's repos (issue comments + PR bodies, trailing ~30d) as tool × count × sample-need, seeded from the ruled gaps in the brief (README §The janitor tick) — a gap already RULED stays listed with its ruling; the point is visibility, not re-litigation. END with one structured report to stdout: per sweep, findings or explicitly 'clean' — silence is not success; the report is the product. If a finding needs a human, say so loudly in the report — do not act on it."
fi
if [ -n "$STACK" ]; then
  SCOPE="You are the coordinator for the ${STACK} stack; its repos are: ${STACK_REPOS:-see agents/stacks.json}, cloned at /work/<repo>; your cwd is the stack main repo ${MAIN_REPO}. Clones are READ-ONLY reference — your writes remain labels, comments, and merge state via gh. "
  [ -n "$RUN_CMD" ] && RUN_CMD="${SCOPE}${RUN_CMD}"
  [ -n "$SEED" ]    && SEED="${SCOPE}${SEED}"
fi

# ADR-106 (5): detach is a headless-only contract — an interactive pod has a human attached and
# nothing in-pod to hand the follow-through to.
if [ -n "$DETACH" ] && [ -z "$RUN_CMD" ]; then
  echo "--detach requires a headless mode (--run/--run-tick/--item/--janitor)" >&2; exit 2
fi
# The unit-completion doorbell payload (2026-08-05 block below), computed AT LAUNCH for the detach
# path: the pod can't run this launcher's stacks.json lookup after the fact, so the launcher bakes
# the resolved JSON into pod env (CS_DOORBELL_JSON) and the pod rings it after claude exits —
# latch-guarded in-pod exactly like the launcher-side block. ITEM MODE ONLY, unchanged: a janitor
# is report-only and must not chain; `unit: "-"` = "something moved, re-scan" (the scan owns
# scheduling, ADR-094).
DOOR_JSON=""
if [ -n "$DETACH" ] && [ -n "$ITEM" ]; then
  _dgrad="$(jq -r --arg s "$STACK" '.stacks[]|select(.name==$s)|select((.graduated // false)==true)|.name' "${HERE}/stacks.json" 2>/dev/null | head -1)"
  if [ -n "$_dgrad" ] && [ "$_dgrad" != "null" ]; then
    DOOR_JSON="{\"stack\":\"${_dgrad}\",\"loop_ns\":\"${_dgrad}-agents\",\"unit\":\"-\"}"
  else
    DOOR_JSON="{\"repo\":\"${MAIN_REPO}\",\"unit\":\"-\"}"
  fi
fi

NS="${LOOP_NS_ARG:-agent-coordinator}"
POD_SA="agent-coordinator"
if [ -n "${LOOP_NS_ARG:-}" ]; then
  # FU-080 perStack: the loop home holds NO git Secret — the pod fetches its stack-scoped token
  # per-run from the proxy (TokenReview against its own SA). coordinator-git secretKeyRef/volume
  # below are optional:true, so their absence in this ns is inert; GH_TOKEN_FILE won't exist and
  # the gh wrapper falls back to the env this prep exports.
  POD_SA="agentstack-loop"
  # >>>REPLAY:loop-fetch-guard>>>
  # homelab#617: split assignment from export so the curl status reaches the || guard. If `export`
  # masks the curl's exit (the old form), a blind coordinator starts. The assignment propagates
  # the failure, triggering the abort.
  LOOP_FETCH="GH_TOKEN=\"\$(curl -fsS -H \"Authorization: Bearer \$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)\" \"http://openrouter-proxy.agent-egress.svc.cluster.local:8080/loop-git-token?ns=${NS}&role=coordinator\")\" || { echo 'FATAL: loop-git token fetch refused/failed — not running blind'; exit 1; }; export GH_TOKEN; "
  # homelab#1095/ADR-119: the issues-only homelab INTAKE token (dedup-and-extend on the platform
  # repo). NON-FATAL by design — absent/refused degrades to the old create-only behavior, never a
  # new hard dependency (the #1136 clone-token precedent).
  LOOP_FETCH="${LOOP_FETCH}GH_TOKEN_INTAKE=\"\$(curl -fsS -H \"Authorization: Bearer \$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)\" \"http://openrouter-proxy.agent-egress.svc.cluster.local:8080/loop-git-token?ns=${NS}&role=intake\")\" || { echo 'WARN: intake token fetch failed — homelab issue mutations degrade to create-only (homelab#1095)'; GH_TOKEN_INTAKE=\"\"; }; export GH_TOKEN_INTAKE; "
  # <<<REPLAY:loop-fetch-guard<<<
else
  LOOP_FETCH=""
fi
[ -f "$HERE/images.env" ] && . "$HERE/images.env" # pinned agent image versions (no :latest)
IMAGE="${COORDINATOR_IMAGE:-${AGENT_COORDINATOR_IMAGE:-ghcr.io/teststuffstash/agent-coordinator:latest}}"
POD="coordinator-$(date -u +%H%M%S)"
# Janitor pods are date-keyed: a second run the same day collides on create — natural daily dedup.
[ -n "$JANITOR" ] && POD="coordinator-janitor-$(date -u +%Y%m%d)"
# FU-146 (homelab#153 five-dispatch storm): an ITEM session gets a DETERMINISTIC pod name keyed on
# (repo, item) — the atomic dispatch gate below and the scan's session-currency belt both key on it
# (the worker gate's `agent-<project>-issue-<n>-r<k>` shape, transposed to
# `coordinator-<repo>-<item-key>`). Tick/janitor/ad-hoc sessions stay timestamp-shaped above — they
# are not item-keyed and must not collide with each other or with a real item session.
if [ -n "$ITEM" ]; then
  ITEM_REPO=""; ITEM_KEY=""
  for _itf in $ITEM; do
    case "$_itf" in
      repo=*) ITEM_REPO="${_itf#repo=}";;
      item=*) ITEM_KEY="${_itf#item=}";;
    esac
  done
  [ -n "$ITEM_REPO" ] || { echo "--item requires a repo= field (got: ${ITEM})" >&2; exit 2; }
  [ -n "$ITEM_KEY" ]  || { echo "--item requires an item= field (got: ${ITEM})" >&2; exit 2; }
  # Sanitize [^a-z0-9-] → '-' on both halves (repo names and item keys are already that shape; the
  # belt keeps a DNS-1123-safe pod name a hard guarantee, not a convention).
  POD="coordinator-$(printf '%s' "$ITEM_REPO" | tr -c 'a-z0-9-' '-')-$(printf '%s' "$ITEM_KEY" | tr -c 'a-z0-9-' '-')"
fi
BRIEF="agents/coordinator/README.md"           # relative to /work/homelab (the poll waits on it there)
BRIEF_PATH="/work/homelab/${BRIEF}"            # ABSOLUTE: the cwd is now the stack main repo, not
                                               # necessarily /work/homelab, so the brief (platform
                                               # MECHANISM) must be referenced by full path.

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
# homelab#1136 pattern, applied here 2026-09-02: AUTHENTICATED clone when GH_TOKEN is present
# (LOOP_FETCH exports it just before). This was the ONE clone site #1136 missed — item pods died
# anonymous for ~4h when GitHub 401-throttled anonymous git from the WAN IP (345/347/348/362,
# the same class as #1136's 47 failed workflows). Absent token = the old anonymous behavior.
PREP="set -e; ${LOOP_FETCH}touch /work/session-start; _cu=\"${REPO_URL}\"; [ -n \"\${GH_TOKEN:-}\" ] && _cu=\"\$(printf '%s' \"${REPO_URL}\" | sed \"s|^https://github.com/|https://x-access-token:\${GH_TOKEN}@github.com/|\")\"; timeout 120 git clone --depth 1 -b ${BASE_REF} \"\$_cu\" /work/homelab"

# A coordinator is scoped to a STACK, so clone ALL its repos (--repos) shallow into /work/<repo>
# and run from the stack's MAIN repo (--main-repo, default homelab) — so that repo's CLAUDE.md + specs
# load naturally as cwd context. homelab is already cloned above (skip it). Private repos (oracle-*)
# authenticate via the pod's GH_TOKEN, which `gh repo clone` inherits — so use gh, not bare git. Each
# clone is guarded `|| echo …`: a failed/optional repo is logged LOUDLY but is NON-FATAL (it must not
# kill the tick), and the coordinator falls back to the repo's GitHub URL. Repo names are baked in
# literally (like ${REPO_URL}/${BASE_REF} above), so nothing relies on pod-side var expansion.
CLONE_STEPS=""
for repo in $STACK_REPOS; do
  [ "$repo" = "homelab" ] && continue
  CLONE_STEPS="${CLONE_STEPS}; if [ -d /work/${repo} ]; then echo \"→ ${repo} already present\"; else echo \"→ cloning ${repo}…\"; timeout 120 gh repo clone ${ORG}/${repo} /work/${repo} -- --depth 1 || echo \"⚠ clone of ${repo} FAILED (non-fatal) — coordinator uses its GitHub URL instead\"; fi"
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
  # cwd-agnostic: Claude's project dir slug tracks the cwd (e.g. -work-oracle-fleet vs
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
  # ⚠ RUN_CMD rides the SAME base64-file transport as SEED — never inline it. The old
  # `$(… | jq -Rs .)` pasted a JSON-DOUBLE-QUOTED string into the pod's `bash -lc` line, where
  # bash re-expands: every BACKTICK in the prompt became command substitution IN THE POD
  # (the #162 RAIL RULE's \`workerModel\`/\`--harness\` fragments executed as commands and were
  # STRIPPED from the delivered prompt — caught on the 02:25Z 08-09 heartbeat reading an oracle
  # arbitrate tick; every headless unit since 2026-08-08 20:30Z ran with those holes). jq escapes
  # for JSON, not for shell: backticks and $ are not JSON-special and stay live. The
  # prose-inside-executing-code class, fourth instance.
  RUN_B64="$(printf '%s' "$RUN_CMD" | base64 | tr -d '\n')"
  PREP="${PREP}; printf %s '${RUN_B64}' | base64 -d > /work/coord-run"
  if [ -n "$DETACH" ]; then
    # ADR-106 (5): the launcher leaves at pod-Ready, so everything it used to do after `logs -f`
    # moves IN-POD: the session-duration row and the completion doorbell. Single-quoted heredoc
    # like UPLOAD_FN — everything resolves from POD env at run time.
    DETACH_FN=$(cat <<'SNIP'
detach_post() {
  # FU-160 session row, pushed by the POD into its OWN pushgateway group (role/coordinator-pod):
  # a POST replaces per metric name within a group, so pushing into the launcher's
  # role/coordinator group would delete the coordinator-spinup row the launcher just wrote there.
  if [ -n "${AGENT_PUSHGATEWAY_URL:-}" ] && [ -n "${CS_SESSION_START:-}" ]; then
    printf '%s\n%s\n%s\n' \
      "# TYPE agent_dispatch_phase_seconds gauge" \
      "# HELP agent_dispatch_phase_seconds Seconds one dispatch spent in a COORDINATOR-owned phase above the launcher (FU-160)." \
      "agent_dispatch_phase_seconds{phase=\"coordinator-session\"} $(( $(date -u +%s) - CS_SESSION_START ))" \
      | curl -fsS --max-time 5 --data-binary @- \
          "${AGENT_PUSHGATEWAY_URL}/metrics/job/agent_dispatch_phase/project/${MAIN_REPO:-homelab}/role/coordinator-pod" >/dev/null 2>&1 \
      || echo "detach_post: pushgateway unreachable — session row lost (observability only, never the pass)"
  fi
  # The unit-completion doorbell (payload launcher-resolved, rationale at the launcher-side block
  # below). ⚠ DO NOT ring while the subscription is latched — the doorbell feeds the constraint
  # it waits on (circles#31 spin, 2026-08-06). Fail-open: an unreachable latch rings as before.
  if [ -n "${CS_DOORBELL_JSON:-}" ]; then
    if ! SUBSCRIPTION_TIER=dispatch bash /work/homelab/agents/subscription-latch.sh 2>/dev/null; then
      echo "→ coordinator doorbell SKIPPED — subscription latched; cron backstop owns it"
    else
      curl -m 5 -s -X POST -H "Content-Type: application/json" -d "${CS_DOORBELL_JSON}" \
        "${AGENT_LOOP_WEBHOOK:-http://agent-loop-eventsource-svc.agent-coordinator.svc.cluster.local:12000}/coordinate" \
        >/dev/null 2>&1 && echo "→ coordinator doorbell rung (/coordinate ${CS_DOORBELL_JSON})" || true
    fi
  fi
  return 0
}
SNIP
)
    # CS_SESSION_START opens at the FIRST in-pod instruction, not at claude launch: the streamed
    # path's `coordinator-session` row measured Ready → log-stream-end, which INCLUDES the prep
    # (clone, gh auth). Capturing after ${PREP} silently redefined the metric for every detached
    # dispatch and broke its before/after baseline (bot review, PR#393).
    WRAPPED="CS_SESSION_START=\$(date -u +%s); ${PREP}
${UPLOAD_FN}
${DETACH_FN}
set +e; claude -p ${COMMON_FLAGS} \"\$(cat /work/coord-run)\"; RC=\$?; upload_transcripts; detach_post; exit \$RC"
  else
    WRAPPED="${PREP}
${UPLOAD_FN}
set +e; claude -p ${COMMON_FLAGS} \"\$(cat /work/coord-run)\"; RC=\$?; upload_transcripts; exit \$RC"
  fi
  ARGS="[\"bash\",\"-lc\",$(printf '%s' "$WRAPPED" | jq -Rs .)]"
else
  ARGS="[\"bash\",\"-lc\",$(printf '%s' "${PREP}; sleep infinity" | jq -Rs .)]"
fi

# FU-088(a): defer the tick while the subscription is 429-latched — the cron re-fires; a spawn
# now would just die on the same limit. Fail-open from the jail (proxy unreachable = proceed).
if ! SUBSCRIPTION_TIER=dispatch bash "$HERE/subscription-latch.sh"; then
  echo "→ coordinator tick deferred — subscription rate-limited (FU-088 latch)"
  exit 0
fi

# ── DISPATCH PHASE TIMINGS — the coordinator's own two rows (FU-160, homelab#319) ───────────────
# The other half of `agent_dispatch_phase_seconds`; the design note (own metric name, per-stack
# (project, role) group, why NOT the launcher's family) is in agents/coordinator-scan.sh beside its
# `>>>REPLAY:dispatch-phase>>>` block and is not restated here. What is specific to this side:
#
#   coordinator-spinup    `apply` → `condition=Ready`: schedule + image pull + container start.
#                         51s in the spike's specimen — the single biggest line in the dispatch
#                         chain, and the one nobody could attribute after the fact.
#   coordinator-session   Ready → the log stream ends: the whole headless tick as ONE number.
#
# THE FAMILY IS RE-PUSHED WHOLE, for the launcher's reason (homelab#287): the pushgateway replaces
# per metric NAME within a group, so a push carrying only `coordinator-session` would DELETE the
# `coordinator-spinup` series pushed a minute earlier and every dispatch would end holding exactly
# one number. Accumulating also means a tick that dies mid-flight leaves the phase it did complete.
#
# A SEPARATE GROUP from the scan's (`role=coordinator` vs `role=coordinator-scan`) — same reason:
# two processes pushing one metric name into one group means one of them silently wins.
# >>>REPLAY:dispatch-phase-session>>>
CS_PHASE_PGW="${AGENT_PUSHGATEWAY_URL-http://prometheus-pushgateway.monitoring.svc.cluster.local:9091}"
CS_PHASE_FAMILY=""      # every phase closed so far, in exposition format — re-pushed as one family
CS_PHASE_WARNED=""
cs_now() { date -u +%s; }     # replay seam: the wall clock
CS_PHASE_MARK="$(cs_now)"
cs_phase_arm() { CS_PHASE_MARK="$(cs_now)"; }   # open the first phase where the pod is asked for
cs_phase() {   # $1 = coordinator-spinup | coordinator-session — close the open phase and publish
  local phase="${1:-}" now
  case "$phase" in
    coordinator-spinup|coordinator-session) ;;
    *) echo "cs_phase: unknown phase '${phase}' — nothing pushed" >&2; return 0 ;;
  esac
  now="$(cs_now)"
  CS_PHASE_FAMILY="${CS_PHASE_FAMILY}agent_dispatch_phase_seconds{phase=\"${phase}\"} $(( now - CS_PHASE_MARK ))
"
  CS_PHASE_MARK="$now"
  # No gateway (explicitly disabled) or no project to key on → the clock still advances, nothing is
  # published. Best-effort by construction: a tick that deferred because a metrics sink was down
  # would be a strictly worse bug than the invisibility this metric exists to fix.
  [ -n "$CS_PHASE_PGW" ] && [ -n "$MAIN_REPO" ] || return 0
  printf '%s\n%s\n%s' \
    "# TYPE agent_dispatch_phase_seconds gauge" \
    "# HELP agent_dispatch_phase_seconds Seconds one dispatch spent in a COORDINATOR-owned phase above the launcher (FU-160)." \
    "$CS_PHASE_FAMILY" \
    | curl -fsS --max-time 5 --data-binary @- \
        "${CS_PHASE_PGW}/metrics/job/agent_dispatch_phase/project/${MAIN_REPO}/role/coordinator" >/dev/null 2>&1 \
    || { [ -n "$CS_PHASE_WARNED" ] \
           || echo "cs_phase: pushgateway unreachable (${CS_PHASE_PGW}) — the tick is unaffected; this dispatch contributes no agent_dispatch_phase_seconds (a jail run lands here: the ClusterIP does not cross the BGP boundary)" >&2
         CS_PHASE_WARNED=1; }
  return 0
}
# <<<REPLAY:dispatch-phase-session<<<
cs_phase_arm   # spin-up opens HERE: the FU-088 latch above may exit without a pod ever existing

# FU-146 atomic gate (item sessions): reap a TERMINAL same-key holder, refuse a LIVE one, then
# `create` (NOT apply — apply would silently adopt/patch an existing pod and the whole idempotency
# story dies). Same donor shape as agent-session.sh's issue/pr gate (line ~1459); transposed to the
# deterministic `coordinator-<repo>-<item-key>` pod name. Tick/janitor/interactive sessions keep
# timestamp names and are untouched by the gate (nothing to test-and-set on).
# >>>REPLAY:session-atomic-gate>>>
session_atomic_gate() {
  EXISTING_PHASE="$("$KUBECTL" $KUBE -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "$EXISTING_PHASE" in
    Succeeded|Failed)
      echo "→ reaping terminal same-key pod ${POD} (${EXISTING_PHASE}) before re-dispatch"
      "$KUBECTL" $KUBE -n "$NS" delete pod "$POD" --ignore-not-found >/dev/null 2>&1 || true;;
    "") :;;  # no holder — create proceeds
    *)
      echo "PREFLIGHT REFUSED: coordinator session pod ${POD} already ${EXISTING_PHASE} — this item is being ridden (FU-146); resume/wait, don't fork." >&2
      exit 3;;
  esac
}
# <<<REPLAY:session-atomic-gate<<<
# The item-mode create is the atomic test-and-set: `create` fails with AlreadyExists if a racing
# dispatcher won the (repo, item) key between the gate's read and the create. `session_atomic_gate`
# EXITS 3 on a live holder (not `return`), so the launcher aborts — never falls through to an apply.
if [ -n "$ITEM" ]; then
  session_atomic_gate
  CREATE_CMD="create"
else
  CREATE_CMD="apply"
fi
cat <<EOF | "$KUBECTL" $KUBE -n "$NS" "$CREATE_CMD" -f - \
  || { echo "PREFLIGHT REFUSED (atomic): ${CREATE_CMD} of ${POD} failed — a racing dispatcher won the (repo, item) key, or the manifest is invalid (see kubectl error above)." >&2; exit 3; }
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  labels: { app: agent-coordinator, "homelab.teststuff.net/subscription-session": claude }
spec:
  restartPolicy: Never
  # This is a BARE pod — no Job, no controller, no owner. Without a deadline a wedge at any phase
  # hangs forever and only surfaces via KubePodNotReady 15+ min later (homelab#94: the janitor sat
  # 40min in ContainerCreating on a volume that could not attach, while its two sibling namespaces
  # completed in seconds). activeDeadlineSeconds counts from pod START, so it reaps Pending wedges
  # too, not just runaway sessions. Matches the Argo coordinate/review ticks (1800) with headroom;
  # ride pods use their own 4h key-TTL bound (agent-session.sh).
  activeDeadlineSeconds: ${COORDINATOR_POD_DEADLINE_S:-3600}
  terminationGracePeriodSeconds: 5
  serviceAccountName: ${POD_SA}
  containers:
    - name: coordinator
      image: ${IMAGE}
      args: ${ARGS}
      env:
        - name: HOME
          value: "/home/node"
        # Per-stack scope: which stack + repos this coordinator owns this session, and the
        # stack's main repo (the cwd). Exposed as env for forward-compat with the AgentStack claim.
        - name: STACK
          value: "${STACK}"
        - name: AGENT_REPOS
          value: "${STACK_REPOS}"
        - name: MAIN_REPO
          value: "${MAIN_REPO}"
        # ADR-097: the scan-computed worker-parallelism allowance for this item's repo. The
        # session's agent-session.sh invocations inherit it (its WIP pre-flight reads this env),
        # so the raise stays launcher-owned end-to-end — the LLM never assembles the number.
        - name: AGENT_WIP_LIMIT
          value: "${WIP_LIMIT}"
        # Provenance for the transcript manifest (docs/agents/observability-and-retro.md §A1).
        - name: MODEL
          value: "${MODEL}"
        # ADR-106 (5) detach: the pod pushes its own session row and rings the launcher-resolved
        # completion doorbell (detach_post). CS_DOORBELL_JSON is empty on streamed/non-item runs,
        # which no-ops the in-pod block. The gateway var mirrors the scan's '-' default (an
        # explicitly EMPTY value stays a disable, only unset gets the cluster default).
        - name: AGENT_PUSHGATEWAY_URL
          value: "${AGENT_PUSHGATEWAY_URL-http://prometheus-pushgateway.monitoring.svc.cluster.local:9091}"
        - name: CS_DOORBELL_JSON
          value: '${DOOR_JSON}'
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
        # Subscription auth rides the ADR-087 ref rail (FU-066d): the pod holds only an opaque ref;
        # the egress proxy's /anthropic upstream resolves it (session-key label + the Role in
        # claude-token.yaml) and injects the ~1y oauth token + the oauth beta header. The raw token
        # never sits next to checked-out code. NB: do NOT also set ANTHROPIC_API_KEY or
        # CLAUDE_CODE_OAUTH_TOKEN — they take auth precedence over this path.
        - name: ANTHROPIC_BASE_URL
          value: "http://openrouter-proxy.agent-egress.svc.cluster.local:8080/anthropic"
        - name: ANTHROPIC_AUTH_TOKEN
          value: "ref:agent-coordinator/coordinator-claude"
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
# FU-160: `|| true` above is load-bearing for this row too — a pod that never went Ready still
# spent that time, and a timed-out wait must publish the number rather than lose it.
cs_phase coordinator-spinup

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
  if [ -n "$DETACH" ]; then
    # ADR-106 (5): stop at pod-Ready. The pod owns the transcript upload, its own session row
    # (role/coordinator-pod group) and the completion doorbell (detach_post) — so the caller's
    # `coordinator-scan` mutex is held for spin-up minutes, never for a streamed session.
    echo "→ detached: ${NS}/${POD} runs the session in-pod; delete with: kubectl -n ${NS} delete pod ${POD}"
    exit 0
  fi
  "$KUBECTL" $KUBE -n "$NS" logs -f "${POD}" || true
  # FU-160: the headless tick as one number. Only this branch closes it — an interactive session is
  # driven by a human at a terminal, so "how long did it take" is not a platform latency at all.
  cs_phase coordinator-session
  echo "→ pass finished. delete with: kubectl -n ${NS} delete pod ${POD}"
  # ── Doorbell on unit completion (2026-08-05) ────────────────────────────────────────────────
  # A finishing RIDE has rung /coordinate since FU-085; a finishing COORDINATOR never did, so every
  # hop of a multi-step chain waited for the next */30 cron. The goal lane (FU-090 leg (c)) is the
  # worst case because its chain is long and each step is seconds of work:
  #   child PR merges -> close the child -> goal-review -> sibling dispatches
  # Three cron waits = up to 90 minutes of dead time. Measured live: circles#24 merged 16:09,
  # goal-review fired 16:30.
  # ITEM MODE ONLY. A janitor tick is report-only and must not chain; an interactive session has a
  # human driving it. `unit: "-"` = "something moved, re-scan" rather than naming the next unit —
  # the scan owns scheduling (ADR-094), and it is the thing that knows what became actionable.
  # Termination: the scan emits "nothing actionable" and stops when the board drains, and the
  # coordinator-scan MUTEX serialises ticks, so this speeds the loop up rather than multiplying it.
  # ⚠ If a scan bug ever made work look permanently actionable this would spin — that is the FU-069
  # anomaly-breaker's job, not this doorbell's. Fail-open: a doorbell that cannot be rung must never
  # fail the pass that already succeeded.
  if [ -n "${ITEM:-}" ]; then
    _cgrad="$(jq -r --arg s "$STACK" '.stacks[]|select(.name==$s)|select((.graduated // false)==true)|.name' "${HERE}/stacks.json" 2>/dev/null | head -1)"
    if [ -n "$_cgrad" ] && [ "$_cgrad" != "null" ]; then
      _cdoor="{\"stack\":\"${_cgrad}\",\"loop_ns\":\"${_cgrad}-agents\",\"unit\":\"-\"}"
    else
      _cdoor="{\"repo\":\"${MAIN_REPO}\",\"unit\":\"-\"}"
    fi
    # ⚠ DO NOT ring while the subscription is latched — the doorbell feeds the constraint it is
    # waiting on (2026-08-06, circles#31). Observed spin, three cycles in eight minutes:
    #   scan → item session → FU-088 defers the dispatch → session ends → RINGS → scan → …
    # The deferral is correct; the retry shape is not. Coordinator sessions are themselves
    # labelled `subscription-session: claude`, so each lap of that loop SPENDS the very capacity
    # it is spinning for, and nothing bounds it but session duration (~2-3 min). With the 7d
    # window binding (0.80 vs the heavy tier's 0.8) that is days of self-sustaining burn.
    # A woken scan can only dispatch work that will defer for the same reason, so the ring buys
    # nothing here. The `*/30` cron backstop still covers any non-subscription work — this trades
    # ≤30 min of edge latency, while limited, against an unbounded loop. Level-triggered wins.
    # Fail-open exactly like the tick gate above: an unreachable proxy rings as before.
    if ! SUBSCRIPTION_TIER=dispatch bash "$HERE/subscription-latch.sh" 2>/dev/null; then
      echo "→ coordinator doorbell SKIPPED — subscription latched; ringing would re-dispatch work that defers again (cron backstop owns it)"
    else
      curl -m 5 -s -X POST -H "Content-Type: application/json" -d "$_cdoor" \
        "${AGENT_LOOP_WEBHOOK:-http://agent-loop-eventsource-svc.agent-coordinator.svc.cluster.local:12000}/coordinate" \
        >/dev/null 2>&1 && echo "→ coordinator doorbell rung (/coordinate ${_cdoor})" || true
    fi
  fi
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
