#!/usr/bin/env bash
# retro-session — assemble a retro (or cross-review) brief and launch one CELL of it.
#
# A retro run (FU-058 run-3 shape) = two cells off the SAME brief, then cross-review swapped:
#   bash agents/retro-session.sh oracle --cell claude:opus          --ledger /tmp/ledger.json
#   bash agents/retro-session.sh oracle --cell goose:deepseek/deepseek-v4-pro --ledger /tmp/ledger.json
#   # harvest both reports into docs/agents/retros/, then:
#   bash agents/retro-session.sh oracle --cell goose:deepseek/deepseek-v4-pro \
#        --review docs/agents/retros/<date>-{{stack}}-r3-opus.md
#
# Templates: docs/agents/retros/BRIEF.md + CROSS-REVIEW.md (committed, versioned — the brief
# IS the retro's spec; edit it there, never inline). This script only substitutes
# placeholders and delegates the pod to agents/agent-session.sh (--harness/--model do the
# axis composition; ADR-094 — the launcher owns dispatch, the LLM never assembles it).
#
# Hand-supervised by design (first runs doctrine). Guardrails the OPERATOR still owns:
#   - key: HANDLED HERE since homelab#270 — an OpenRouter cell mints its OWN ephemeral capped
#     OpenRouterKey below and rides that. Set RETRO_OPENROUTER_SECRET=<secret name> only to pin
#     a pre-minted key (that is also how you deliberately re-select the fixer's standing key).
#   - WIP: the pod runs in the stack's fixer namespace and MAY hold its WIP slot
#     (FU-058 P3 wants retro outside the fixer ns — not built yet): launch when the queue
#     is idle, or accept delaying a queued fix.
#   - subscription cells (claude:opus) ride the proxy and the FU-088 headroom gate — a
#     deferral is by design, re-launch later; never bypass.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RETROS="$HERE/../docs/agents/retros"
# The 128KiB per-argv-element ceiling (homelab#242). THIS script is where it was first hit live
# (8rvhd, 2026-08-11): the brief travels base64'd inside the single `--run` string handed to
# agent-session.sh, so the exec below is the first execve() big enough to fail.
. "$HERE/argv-guard.sh"
# $KUBECTL + $KUBE, shared with agent-session.sh: this script now mints the cell's budget key
# itself, and it does that from BOTH environments the launchers run in (the jail, with
# tofu/kubeconfig; the coordinator image, with the pod's ServiceAccount).
. "$HERE/kube.sh"
# The stack→(PROJECT, MAIN_REPO) map — shared with retro-argo.yaml's guard (homelab#588),
# so it has one home instead of two copies.
. "$HERE/retro-project.sh"

STACK="${1:?usage: retro-session <stack> --cell <harness>:<model> (--ledger <json> | --review <report.md>) [--deep-dive-k N]}"
shift
CELL="" LEDGER="" REVIEW="" K=8
while [ $# -gt 0 ]; do case "$1" in
  --cell)        CELL="$2"; shift 2;;
  --ledger)      LEDGER="$2"; shift 2;;
  --review)      REVIEW="$2"; shift 2;;
  --deep-dive-k) K="$2"; shift 2;;
  *) echo "unknown flag $1" >&2; exit 2;;
esac; done
[ -n "$CELL" ] || { echo "FATAL: --cell <harness>:<model> required (e.g. claude:opus, goose:deepseek/deepseek-v4-pro)" >&2; exit 2; }
HARNESS="${CELL%%:*}"; MODEL="${CELL#*:}"
# ── ADR-096 override rule: retro cell model = explicit override ──
# The retro --cell flag is MANDATORY — every retro invocation supplies one.
# The cell model is passed as BOTH --fallback and --model (explicit override):
#   --fallback is the resolve-model.sh validation requirement (line 47) and
#              the fail-OPEN literal when /route is unreachable
#   --model    makes resolve-model.sh short-circuit before the /route call,
#              so the cell rides EXACTLY its configured model
# This ensures the A/B experiment axis is preserved: two cells with different
# models ride EXACTLY their configured models, and the router cannot collapse
# them onto one pool pick (G-A #775, fixed for retro in #861).
# The old --fallback-only semantics (issue #782 wiring) let the router's
# dispatch verdict override the cell model, silently destroying the experiment
# axis.  The coordinator-session.sh caller uses the same pattern (line 106).
# Override-rule home: docs/agents/model-routing.md §M10 (the one stated home of the
# ADR-096 override rule; cell = explicit override since #861/PR#864).
MODEL="$(bash "$HERE/resolve-model.sh" --role retro --class audit --cell "$CELL" --fallback "$MODEL" --model "$MODEL")"
retro_project "$STACK" || exit 2

# Next run id from the harvested reports (rN numbering is per-stack).
LAST=$(ls "$RETROS" 2>/dev/null | grep -oE "${STACK}-r[0-9]+" | grep -oE '[0-9]+$' | sort -n | tail -1 || true)
RUN_ID="r$(( ${LAST:-0} + 1 ))"

# Harness-source excerpts: the artifacts findings may target. Fabricators invent APIs exactly
# where they can't read the target (run-2 evidence) — feed the real text.
HARNESS_SRC=$(mktemp)
for f in "$HERE/coordinator/README.md" "$HERE/estimate_budget.py"; do
  [ -f "$f" ] && { printf '### %s (excerpt)\n```\n' "$(basename "$f")"; sed -n '1,60p' "$f"; printf '```\n\n'; } >> "$HARNESS_SRC"
done

BRIEF=$(mktemp /tmp/retro-brief-XXXX.md)
if [ -n "$REVIEW" ]; then
  [ -f "$REVIEW" ] || { echo "FATAL: --review $REVIEW not found" >&2; exit 2; }
  # Content floor (homelab#590, shared with retro-argo.yaml's self-check + harvest — ONE helper,
  # three callers): a cross-review dispatched against a content-free report reviews nothing, and
  # the empty-skeleton shape (a landed report that is only the template's headings) would sail
  # straight past a bare `[ -f ]` check and spend a paid ride reviewing nine lines of nothing.
  REVIEW_FLOOR_OUT="$(mktemp)"; REVIEW_FLOOR_REASON="$(mktemp)"
  if ! bash "$HERE/retro-report-floor.sh" "$REVIEW" "$REVIEW_FLOOR_OUT" report 2>"$REVIEW_FLOOR_REASON"; then
    echo "FATAL: --review $REVIEW does not meet the content floor ($(cat "$REVIEW_FLOOR_REASON")) — a cross-review of it would review nothing." >&2
    rm -f "$REVIEW_FLOOR_OUT" "$REVIEW_FLOOR_REASON"
    exit 1
  fi
  rm -f "$REVIEW_FLOOR_OUT" "$REVIEW_FLOOR_REASON"
  python3 - "$RETROS/CROSS-REVIEW.md" "$BRIEF" "$STACK" "$RUN_ID" "$MAIN_REPO" "$REVIEW" <<'PY'
import sys
tpl, out, stack, run_id, repo, report = sys.argv[1:]
t = open(tpl).read()
t = t.replace("{{STACK}}", stack).replace("{{RUN_ID}}", run_id).replace("{{MAIN_REPO}}", repo)
t = t.replace("{{REPORT}}", open(report).read())
open(out, "w").write(t)
PY
  FIRST_MSG="Read /tmp/retro-brief.md and execute it exactly. Your final message must contain the complete review between the markers it specifies."
else
  [ -f "${LEDGER:-}" ] || { echo "FATAL: --ledger <pain-ranked json> required for the retro leg (assemble from the FU-057 ledger)" >&2; exit 2; }
  python3 - "$RETROS/BRIEF.md" "$BRIEF" "$STACK" "$RUN_ID" "$MAIN_REPO" "$LEDGER" "$K" "$HARNESS_SRC" <<'PY'
import sys
tpl, out, stack, run_id, repo, ledger, k, src = sys.argv[1:]
t = open(tpl).read()
t = t.split("-->", 1)[1].lstrip()  # strip the template header comment
for a, b in [("{{STACK}}", stack), ("{{RUN_ID}}", run_id), ("{{MAIN_REPO}}", repo),
             ("{{DEEP_DIVE_K}}", k), ("{{LEDGER_JSON}}", open(ledger).read().strip()),
             ("{{HARNESS_SRC}}", open(src).read())]:
    t = t.replace(a, b)
open(out, "w").write(t)
PY
  FIRST_MSG="Read /tmp/retro-brief.md and execute it exactly. Your final message must contain the complete report between the markers it specifies."
fi
rm -f "$HARNESS_SRC"
grep -q '{{' "$BRIEF" && { echo "FATAL: unsubstituted placeholder in $BRIEF" >&2; exit 1; }

# The brief travels the proven in-pod materialization path (agent-session.sh's own recipe
# pattern): base64 into the run command, decoded to /tmp/retro-brief.md inside the pod.
BRIEF_B64=$(base64 -w0 <"$BRIEF")
DECODE="printf '%s' '${BRIEF_B64}' | base64 -d > /tmp/retro-brief.md"
# GOOSE_MAX_TOKENS as a command-prefix env — it must exist in the POD, not this shell
# (cures the -32602 truncation, run-2 ops lesson).
case "$HARNESS" in
  goose)  RUN="${DECODE}; GOOSE_MAX_TOKENS=16384 goose run --text '${FIRST_MSG}'";;
  claude) RUN="${DECODE}; claude -p --dangerously-skip-permissions --max-turns \${CLAUDE_MAX_TURNS:-200} '${FIRST_MSG}'";;
  *) echo "FATAL: harness '$HARNESS' not wired here (opencode: add when its retro cell is first used)" >&2; exit 2;;
esac

# The hand-off below passes $RUN as ONE argv element, so it is the execve() that fails first — and
# it fails with `Argument list too long` from the exec'ing shell, which names neither the brief nor
# the limit (homelab#242; that is verbatim what 8rvhd's operator saw).
# >>>REPLAY:retro-payload-ceiling>>>
if ! argv_guard "the retro --run payload for ${STACK} ${RUN_ID} (brief ${BRIEF})" "$RUN"; then
  printf '  REFUSED before the hand-off to agent-session.sh — no pod was created.\n' >&2
  printf '  Shrink the brief: the ledger slice is bounded worst-K (retro-argo.yaml), so the growable inputs are\n' >&2
  printf '  --deep-dive-k, the HARNESS_SRC excerpts, and (on a cross-review leg) the report being reviewed.\n' >&2
  exit 1
fi
# <<<REPLAY:retro-payload-ceiling<<<

echo "→ ${STACK} ${RUN_ID} cell ${HARNESS}:${MODEL} — brief $BRIEF ($(wc -c <"$BRIEF") bytes)"
echo "→ harvest: report goes to docs/agents/retros/$(date +%F)-${STACK}-${RUN_ID}-<model>.md via PR"

# ── The cell's OWN capped key (homelab#270, the second half of #248 finding 1) ──────────────────
# A retro ride is not a fixer round and must not draw on the fixer's cap. The empty default used to
# do exactly that: run 3's cell-b died in 8s on a provider "Please retry" and the dead ride still
# spent oracle-fleet's standing budget key. The per-session ephemeral key is the platform's spend
# breaker everywhere else in the loop (coordinator brief §step 4); the retro lane is no longer the
# exception. There is deliberately NO fallback — a mint that fails ends the ride, because "fell back
# to the fixer's key" is the outcome this block exists to prevent, not a degraded mode of it.
# Placed AFTER the argv guard, immediately before the hand-off: a key is minted with a fresh
# `expiresAt` each time (coordinator README §step 4), so a refusal downstream of it would leave a
# live key behind for a ride that never happened.
# >>>REPLAY:retro-session-key>>>
if [ "$HARNESS" = claude ]; then
  # Subscription ride: mints nothing, by RAIL rule (homelab#158). Its spend bound is the turn cap,
  # and the FU-088 headroom gate is what rations it — an OpenRouterKey here would bound nothing.
  echo "→ key: none — ${HARNESS} rides the subscription (no OpenRouter key in play)"
elif [ -n "${RETRO_OPENROUTER_SECRET:-}" ]; then
  echo "→ key: RETRO_OPENROUTER_SECRET=${RETRO_OPENROUTER_SECRET} — operator-pinned, nothing minted"
else
  # One key per (run, cell): two OpenRouter cells in the same run must not share one cap, or the
  # first to spend it strands the second. Lowercased + punctuation-stripped because this becomes a
  # k8s object name — the same slug rule the harvest applies to the report filename.
  SESSION="retro-${RUN_ID}${REVIEW:+-xrev}-$(printf '%s' "${MODEL##*/}" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9.-')"
  KEY_CR="$(mktemp /tmp/retro-key-XXXX.yaml)"
  # THE TIER IS FORCED, and that is the deliberate part. estimate_budget.py's band models a FIXER
  # round — requests_per_round × context × rounds — and on a real brief it returns ~$0.54 → tier lg
  # ($2.00), which caps nothing on a lane whose measured spend is $0.02–0.08 per cell (runs 1+2
  # over 9 models, observability-and-retro.md §B2). The retro lane has direct measurement where the
  # estimator has a heuristic, so the sizing comes from the measurement: $0.08 × the estimator's own
  # ×2.0 buffer = $0.16 → the smallest tier, xs/$0.25 (#248 finding 1's arithmetic, verbatim). That
  # also clears the $0.05 floor run 1 taught by 5×. The estimate is still computed and still lands
  # in the ride log next to the cap: the day a cell's true cost approaches $0.25, the log says so
  # before the 403 does. --rounds 1 because a cell is one ride and there are no fix rounds.
  if ! python3 "$HERE/estimate_budget.py" --model "$MODEL" --rounds 1 --issue-file "$BRIEF" \
       --label agent-budget/xs --project "$PROJECT" --session "$SESSION" --emit-cr > "$KEY_CR"; then
    echo "FATAL: budget estimate failed for ${MODEL} — no capped key, no ride (the ${PROJECT} fixer key is NOT the fallback)" >&2
    exit 1
  fi
  # Read the CR's OWN fields rather than reconstructing either name: metadata.name and secretName
  # differ by a `-session-` infix, and reconstructing the Secret from the CR name is precisely what
  # crash-loops a worker on "secret not found" (coordinator README §step 5).
  # Uses python3 (shape-agnostic — handles both inline flow and block style metadata, so emit_cr
  # is free to change rendering without breaking the retro lane). python3 is already a hard
  # dependency of this exact code path (estimate_budget.py two lines above).
  read -r KEY_NAME KEY_SECRET <<< "$(python3 - "$KEY_CR" <<'PY'
import sys, re

with open(sys.argv[1]) as f:
    text = f.read()

# Build a simple key-value map from the YAML, handling both inline flow
# { key: val, ... } and block style key: val indentation.
data = {}
section = None

for line in text.splitlines():
    # Inline flow: metadata: { name: foo, namespace: bar, ... }
    # Depth-matched brace scan: finds the matching '}' for the first '{', so nested
    # objects (e.g. labels: { budget-tier: xs }) don't truncate the inner content
    # before later keys (homelab#1075 — a key-order reshape of emit_cr that placed a
    # nested object before 'name' would silently empty KEY_NAME under the old
    # first-brace-pair split).
    m = re.match(r'^(\w+):\s*\{', line)
    if m:
        section = m.group(1)
        start = line.index('{')
        depth = 0
        end = start
        for i in range(start, len(line)):
            if line[i] == '{':
                depth += 1
            elif line[i] == '}':
                depth -= 1
                if depth == 0:
                    end = i
                    break
        inner = line[start:end]
        for k, v in re.findall(r'(\w+):\s*([^\s,}]+)', inner):
            data[f"{section}.{k}"] = v.strip('"')
        continue

    # Section header (block style): metadata:
    m = re.match(r'^(\w+):\s*$', line)
    if m:
        section = m.group(1)
        continue

    # Indented key: value (block style)
    m = re.match(r'^\s+(\w+):\s*(.*)', line)
    if m and section:
        data[f"{section}.{m.group(1)}"] = m.group(2).strip()

name = data.get('metadata.name')
secret = data.get('spec.secretName')
if name and secret:
    print(name, secret)
else:
    sys.exit(1)
PY
)"
  if [ -z "$KEY_NAME" ] || [ -z "$KEY_SECRET" ]; then
    echo "FATAL: could not read name/secretName out of the emitted CR ($KEY_CR) — estimate_budget.py's emit_cr shape moved" >&2
    exit 1
  fi
  # DELETE, then apply: re-minting an existing CR name takes the operator's PATCH path, and
  # OpenRouter's PATCH cannot extend a key's real expires_at (openrouter-operator#6, proven live
  # 2026-07-09 — the key died at its ORIGINAL deadline mid-run). A created CR POSTs a fresh key
  # with its full TTL window, which is what a re-fired cell needs.
  "$KUBECTL" $KUBE -n "$PROJECT" delete openrouterkey "$KEY_NAME" --ignore-not-found >/dev/null 2>&1 || true
  if ! "$KUBECTL" $KUBE -n "$PROJECT" apply -f - < "$KEY_CR" >&2; then
    echo "FATAL: could not apply ${KEY_NAME} in ${PROJECT} — refusing to ride on the fixer's standing key. Deliberate override: RETRO_OPENROUTER_SECRET=${PROJECT}-openrouter" >&2
    exit 1
  fi
  # Wait on the CR's status, never on the Secret: this identity mints and observes keys and has no
  # Secret-VALUE access (agents/coordinator/rbac.yaml). Dispatching before the operator stamps the
  # hash is dispatching into a Secret that does not exist yet.
  KEY_HASH=""; WAITED=0
  while [ "$WAITED" -lt 120 ]; do
    KEY_HASH="$("$KUBECTL" $KUBE -n "$PROJECT" get openrouterkey "$KEY_NAME" \
      -o jsonpath='{.status.openrouter.hash}' 2>/dev/null || true)"
    if [ -n "$KEY_HASH" ]; then break; fi
    sleep 2; WAITED=$((WAITED + 2))
  done
  if [ -z "$KEY_HASH" ]; then
    echo "FATAL: ${KEY_NAME} applied, but the openrouter-operator stamped no .status.openrouter.hash within 120s — no key, no ride. Check the operator: kubectl -n ${PROJECT} describe openrouterkey ${KEY_NAME}" >&2
    exit 1
  fi
  export RETRO_OPENROUTER_SECRET="$KEY_SECRET"
  echo "→ key: minted ${KEY_NAME} (ns ${PROJECT}) → Secret ${KEY_SECRET}"
fi
# <<<REPLAY:retro-session-key<<<
EXTRA=()
[ -n "${RETRO_OPENROUTER_SECRET:-}" ] && EXTRA+=(--openrouter-secret "$RETRO_OPENROUTER_SECRET")
exec bash "$HERE/agent-session.sh" "$PROJECT" \
  --harness "$HARNESS" --model "$MODEL" \
  --task "retro-${RUN_ID}${REVIEW:+-xrev}" \
  "${EXTRA[@]}" \
  --run "$RUN"
