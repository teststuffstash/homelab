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
