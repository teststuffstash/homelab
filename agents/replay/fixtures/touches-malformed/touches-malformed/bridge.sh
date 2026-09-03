# ── bridge ── the per-repo loop variables the lint reads and writes. `openall` is the ONE open-issue
# fetch the whole repo pass shares (agents/coordinator-scan.sh, above the queued loop) — the lint
# makes no call of its own, which is the point: a touches-malformed check that cost an API call
# per tick would not have been written.
#
# SEVEN issues exercising the touches-malformed check:
#   401 — strict grammar Touches: → no report
#   402 — bolded **Touches:** → REPORTED
#   403 — bulleted - Touches: → REPORTED
#   404 — heading ### Touches: → REPORTED
#   405 — italic *Touches:* → REPORTED
#   406 — No Touches line (exclusive `*` sentinel) → not checked
#   407 — Touches: * (strict grammar, wildcard) → not checked
# Source the footprint helper for fp_conflict_strict (the extracted REPLAY block calls it).
. "${REPLAY_ROOT}/agents/footprint.sh"
slug="$IN_SLUG"
repo="$IN_REPO"
openall_fetch_rc=0
orphans=""
openall='[
  { "number": 401, "title": "strict grammar Touches",
    "body": "## Deliverable\nAdd the helper in `agents/coordinator-scan.sh`.\n\nTouches: agents/coordinator-scan.sh\n" },
  { "number": 402, "title": "bolded Touches",
    "body": "## Deliverable\nAdd the helper in `agents/coordinator-scan.sh`.\n\n**Touches:** agents/coordinator-scan.sh\n" },
  { "number": 403, "title": "bulleted Touches",
    "body": "## Deliverable\nAdd the helper in `agents/coordinator-scan.sh`.\n\n- Touches: agents/coordinator-scan.sh\n" },
  { "number": 404, "title": "heading Touches",
    "body": "## Deliverable\nAdd the helper in `agents/coordinator-scan.sh`.\n\n### Touches: agents/coordinator-scan.sh\n" },
  { "number": 405, "title": "italic Touches",
    "body": "## Deliverable\nAdd the helper in `agents/coordinator-scan.sh`.\n\n*Touches:* agents/coordinator-scan.sh\n" },
  { "number": 406, "title": "no Touches line",
    "body": "## Deliverable\nAdd `agents/foo.sh`.\n\nNo touches declared.\n" },
  { "number": 407, "title": "Touches wildcard",
    "body": "## Deliverable\nAdd `agents/foo.sh`.\n\nTouches: *\n" }
]'