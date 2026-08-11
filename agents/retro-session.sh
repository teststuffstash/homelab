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
#   - key: goose cells want an EPHEMERAL capped key ($0.05 floor — $0.01 403'd mid-finalize
#     in run 1): declare an OpenRouterKey CR, then export RETRO_OPENROUTER_SECRET=<secret
#     name> before launching; else the ride uses the project's fixer budget key (warned).
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
case "$STACK" in
  oracle) PROJECT=oracle-fleet; MAIN_REPO=teststuffstash/oracle-fleet;;
  sleep)  PROJECT=sleep-tracking; MAIN_REPO=teststuffstash/sleep-tracking;;
  *) echo "FATAL: unknown stack '$STACK' (add its project/main-repo mapping here)" >&2; exit 2;;
esac

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

[ -n "${RETRO_OPENROUTER_SECRET:-}" ] || [ "$HARNESS" = claude ] || \
  echo "⚠ RETRO_OPENROUTER_SECRET not set — the ride will spend the ${PROJECT} fixer budget key (mint an ephemeral capped OpenRouterKey and pass its Secret name; \$0.05 floor — \$0.01 403'd mid-finalize in run 1)" >&2

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
EXTRA=()
[ -n "${RETRO_OPENROUTER_SECRET:-}" ] && EXTRA+=(--openrouter-secret "$RETRO_OPENROUTER_SECRET")
exec bash "$HERE/agent-session.sh" "$PROJECT" \
  --harness "$HARNESS" --model "$MODEL" \
  --task "retro-${RUN_ID}${REVIEW:+-xrev}" \
  "${EXTRA[@]}" \
  --run "$RUN"
