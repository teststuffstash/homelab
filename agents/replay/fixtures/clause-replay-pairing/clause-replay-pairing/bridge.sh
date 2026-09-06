# ── bridge ── the per-repo loop variables the lint reads and writes. `openall` is the ONE open-issue
# fetch the whole repo pass shares (agents/coordinator-scan.sh, above the queued loop) — the lint
# makes no call of its own, which is the point.
#
# SIX issues exercising the clause-replay-pairing check:
#   701 — Touches a clause file, no agents/replay/** → REPORTED
#   702 — Touches a clause file, also declares agents/replay/** → not reported
#   703 — Touches a clause file (by prefix), no agents/replay/** → REPORTED
#   704 — Touches no clause file → not checked
#   705 — No Touches line (exclusive `*` sentinel) → not checked
#   706 — Empty body → not checked
# Source the footprint helper for fp_conflict_strict (the extracted REPLAY block calls it).
. "${REPLAY_ROOT}/agents/footprint.sh"
slug="$IN_SLUG"
repo="$IN_REPO"
# homelab#853: clause_files is hoisted (before the per-repo loop) plus a parity assertion
# that reads ci.yaml's ratchet regex. The fixture tests the per-issue pairing check only,
# so set PARITY_ISSUES empty (no drift) and provide the canonical list.
clause_files="agents/model-scout.sh
agents/coordinator-scan.sh
agents/review-reflex.sh
agents/reviewer-session.sh
agents/reviewer-optout.sh
agents/machine-comment.sh
agents/goal-budget.sh
agents/agent-session.sh
agents/retro-session.sh
agents/argv-guard.sh
agents/coordinator/reflexes-argo.yaml
agents/coordinator/review-argo.yaml
agents/coordinator/reviewer-git.yaml
agents/coordinator/coordinate-argo.yaml
agents/coordinator/responder-argo.yaml
agents/coordinator/retro-argo.yaml
agents/coordinator/fix-debounce-argo.yaml
agents/coordinator/deploy-revert-argo.yaml"
if [ "${PARITY_DRIFT:-0}" = "1" ]; then
  PARITY_ISSUES="  PARITY FAIL: \`agents/coordinator/reviewer-git.yaml\` matches ratchet regex but is missing from \`clause_files\`\n"
else
  PARITY_ISSUES=""
fi
mainrepo=homelab
openall_fetch_rc=0
orphans=""
openall='[
  { "number": 701, "title": "clause touched, no replay",
    "body": "## Deliverable\nUpdate `agents/coordinator-scan.sh` to add the clause-replay check.\n\nTouches: agents/coordinator-scan.sh\n" },
  { "number": 702, "title": "clause touched, replay declared",
    "body": "## Deliverable\nUpdate `agents/coordinator-scan.sh` to add the clause-replay check.\n\nTouches: agents/coordinator-scan.sh, agents/replay/**\n" },
  { "number": 703, "title": "clause touched via prefix, no replay",
    "body": "## Deliverable\nUpdate `agents/coordinator/coordinate-argo.yaml` for the workflow.\n\nTouches: agents/coordinator/\n" },
  { "number": 704, "title": "no clause touched",
    "body": "## Deliverable\nAdd a shared helper `agents/foo.sh`.\n\nTouches: argocd/resources/\n" },
  { "number": 705, "title": "no Touches line",
    "body": "## Deliverable\nUpdate something in `agents/model-scout.sh`.\n\nNo touches declared.\n" },
  { "number": 706, "title": "empty body", "body": null }
]'

# ── seam (ADR-122 (3), homelab#1431) ── the ONE issue-body parser. The scan resolves it beside
# itself; a composition sees config-defaults BEFORE this bridge, so the path is set here.
IB_PY="$REPLAY_ROOT/agents/issue_body.py"
