#!/usr/bin/env bash
# reviewer-optout — THE read of the per-stack `spec.reviewer.enabled` knob (FU-080), for every
# reviewer-dispatch site. One implementation, one failure posture, one message.
#
#   bash agents/reviewer-optout.sh <repo>                # predicate: exit 0 = dispatch, 1 = skip
#   bash agents/reviewer-optout.sh --filter r1 r2 …      # stdout = the repos clear to review
#
# Reasons always go to STDERR (so --filter's stdout stays a clean repo list); both modes are quiet
# on the ordinary "everything enabled" path.
#
# WHY THIS FILE EXISTS (homelab#204). The knob shipped as an inline jq inside review-reflex.sh's
# tick — ONE of THREE dispatch sites. The other two (the `review-perstack` Sensor trigger and the
# global `review` WorkflowTemplate, both in agents/coordinator/review-argo.yaml) never read it, and
# on 2026-08-09 08:00Z the perstack path reviewed, APPROVED and auto-merged agent-runtime#57 while
# the platform claim said `reviewer.enabled: false` — the same minute the reflex tick correctly
# logged "[agent-runtime] skipped — stack reviewer.enabled=false". The main reflex was not wrong;
# it was just not the only reader. That is the two-readers-one-mirror class (⚠ durable warning in
# docs/agents/meta-state.md) instantiated for reviewer dispatch, and the fix for that class is
# never "copy the jq into the second site" — a copy is the next drift, and it drifts silently
# because the site that still works keeps logging the correct line.
#
# ALL THREE SITES converge on agents/reviewer-session.sh, so its guard (next to the FU-088 latch,
# which is there for exactly the same reason) is the choke point that makes both Argo comments'
# claim — "reviewer-session.sh STEP-0 is the final backstop" — true for stack state. It was not:
# STEP 0 is a PROMPT-level self-guard about review history, read by the reviewer after its pod is
# already running on the operator's subscription. A shell guard refuses before the pod exists.
#
# FAIL-CLOSED, on purpose, and this is the one design choice worth arguing with. For a DISABLE
# knob the two failures are not symmetric:
#   • skip a review we should have run  → the review path is LEVEL-TRIGGERED (Sensor edge + a */15
#     CronWorkflow backstop + the ~5-min reflex tick), so the next tick with a readable cluster
#     re-picks the PR. Cost: minutes.
#   • run a review the operator disabled → an APPROVED verdict on a PR whose only intended gate was
#     a human read, and GitHub auto-merge completes it before anyone looks. Cost: the gate itself,
#     unrecoverable without a revert.
# So an unreadable claims read means SKIP, loudly — every stack is "unknown" and unknown is not
# permission. The old inline branch WARNed and reviewed everything anyway (fail-OPEN); that latent
# instance is fixed in the same pass, per the issue's pre-decided posture.
#
# NOT fail-closed: a repo in NO claim at all. That is a KNOWN answer (nothing opted it out), not an
# unknown one, and treating it as a skip would wedge every unclaimed repo — and a fresh cluster —
# out of review forever.
#
# The knob lives ONLY in the cluster claim. agents/stacks.json is the committed mirror and is the
# PROBE-FAILED belt for other fields, but it does NOT carry `reviewer` — teaching it to would be a
# second copy of the very fact this file exists to read once. Don't.
#
# RBAC (checked before choosing fail-closed, 2026-08-09): both dispatch contexts can do this read —
# the global coordinator SA in ns agent-coordinator, and the per-stack `agentstack-loop` SA via the
# `agentstack-loop-claims-read-<stack>` ClusterRoleBinding → ClusterRole `agentstack-claims-read`
# (argocd/resources/agentstack/rbac.yaml:115, composition.yaml:393). A fail-closed guard on a path
# that CANNOT read the claims would brick that lane instead of gating it; if you add a fourth
# dispatch context, grant it that ClusterRole in the same change.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
KUBE=""
[ -f "${HERE}/../tofu/kubeconfig" ] && KUBE="--kubeconfig ${HERE}/../tofu/kubeconfig"
KUBECTL="$(command -v kubectl || true)"
[ -n "$KUBECTL" ] || KUBECTL="${HERE}/../.devbox/nix/profile/default/bin/kubectl"
[ -x "$KUBECTL" ] || KUBECTL="kubectl"

CRD="${AGENTSTACK_CRD:-agentstacks.platform.teststuff.net}"

say() { printf 'reviewer-optout: %s\n' "$*" >&2; }

# ── the ONE read ────────────────────────────────────────────────────────────────────────────────
# Guarded twice on purpose. `kubectl get -o json` prints a syntactically VALID empty List to STDOUT
# while writing "Error from server (Forbidden)" to stderr and exiting 1 — verified live from a
# worker pod, 2026-08-09. A caller that only captured stdout would parse `{"items":[]}` as "no
# stack opted out" and dispatch: fail-open, silently, exactly the bug this file is closing. So the
# exit status is authoritative, AND the payload must actually carry an `items` array.
CLAIMS=""
probe_claims() {
  CLAIMS="$("$KUBECTL" $KUBE get "$CRD" -o json 2>/dev/null)" || return 1
  printf '%s' "${CLAIMS:-null}" | jq -e 'type == "object" and (.items | type == "array")' >/dev/null 2>&1 || return 1   # :-null — jq 1.6 exits 0 on EMPTY input (homelab#377)
  return 0
}

# Repos whose stack set `reviewer.enabled: false`, one per line. The XRD defaults the field to
# `true`, so the API server materializes it on every claim and `== false` means EXPLICITLY off —
# an absent/null value is never an opt-out. `.spec.repos[]` entries are objects with `.name`; the
# string form is tolerated the way reviewer-session.sh tolerates it in the mirror.
disabled_repos() {
  printf '%s' "$CLAIMS" | jq -r '
    .items[]
    | select(.spec.reviewer.enabled == false)
    | .metadata.name as $stack
    | .spec.repos[]?
    | (if type == "object" then .name else . end)
    | select(. != null)
    | "\(.) \($stack)"' 2>/dev/null
}

# ── MCP knob read (#1041) ──────────────────────────────────────────────────────────────────────
# Expose the stack-wide spec.mcp.{endpoint,tools} for a given repo, from the SAME claims read.
# The MCP endpoint is stack-wide, not per-repo — find the stack whose repos include this project.
# Absent = no MCP attached. Callers source this file and call mcp_knob().
# Usage: mcp_knob <repo>  →  prints "endpoint|tools" (| separated) or empty string.
mcp_knob() {
  local repo="$1"
  printf '%s' "$CLAIMS" | jq -r --arg p "$repo" '
    .items[]
    | select(any(.spec.repos[]; .name == $p))
    | "\(.spec.mcp.endpoint // "")|\(.spec.mcp.tools // [])"
    | select(startswith("|") | not)' 2>/dev/null | head -1
}

usage() { echo "usage: reviewer-optout.sh <repo> | --filter <repo>… | --lens-map <repo> | --mcp-knob <repo>" >&2; exit 2; }
[ $# -gt 0 ] || usage

MODE="predicate"
if [ "$1" = "--lens-map" ]; then
  # Output a JSON map of lens → posture for the given repo from the SAME single claim read.
  # Uses the shared CLAIMS read (probe_claims) so it costs no extra cluster call; fail-closed
  # on an unreadable claim (returns "{}", exit 1).
  _map_repo="$2"
  if ! probe_claims; then
    say "claims read PROBE-FAILED (kubectl get $CRD) — lens posture is UNKNOWN; returning empty map (advisory for all lenses)."
    exit 1
  fi
  printf '%s' "$CLAIMS" | jq -r --arg repo "$_map_repo" '
    .items[]
    | select(.spec.repos[]? | (if type == "object" then .name else . end) == $repo)
    | .spec.lenses // {}
  ' 2>/dev/null || echo "{}"
  exit 0
fi
if [ "$1" = "--filter" ]; then MODE="filter"; shift
elif [ "$1" = "--mcp-knob" ]; then MODE="mcp-knob"; shift
fi
[ $# -gt 0 ] || usage

if ! probe_claims; then
  # Loud, and it names the consequence rather than just the symptom — a WARN nobody can act on is
  # how the fail-open branch survived three weeks.
  say "claims read PROBE-FAILED (kubectl get $CRD) — reviewer.enabled is UNKNOWN for every stack;"
  say "  SKIPPING reviewer dispatch for: $* (fail-CLOSED, homelab#204). The review path is"
  say "  level-triggered: a tick with a readable cluster re-picks these PRs. If this repeats, the"
  say "  dispatch context is missing the agentstack-claims-read ClusterRole."
  exit 1   # --filter prints nothing: no repo is clear to review
fi

DISABLED="$(disabled_repos)"

allowed() {  # allowed <repo> → 0 clear, 1 opted out (reason on stderr)
  _stack="$(printf '%s\n' "$DISABLED" | awk -v r="$1" '$1 == r { print $2; exit }')"
  [ -n "$_stack" ] || return 0
  say "[$1] skipped — stack '$_stack' set reviewer.enabled=false (AgentStack claim)"
  return 1
}

if [ "$MODE" = "filter" ]; then
  for r in "$@"; do allowed "$r" && printf '%s\n' "$r"; done
  exit 0
fi
if [ "$MODE" = "mcp-knob" ]; then
  mcp_knob "$1"
  exit 0
fi
allowed "$1"
