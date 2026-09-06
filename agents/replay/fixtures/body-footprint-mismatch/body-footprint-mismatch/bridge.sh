# ── bridge ── the per-repo loop variables the lint reads and writes. `openall` is the ONE open-issue
# fetch the whole repo pass shares (agents/coordinator-scan.sh, above the queued loop) — the lint
# makes no call of its own, which is the point: a body-footprint mismatch check that cost an API
# call per tick would not have been written.
#
# SIX issues exercising the body-footprint-mismatch check:
#   301 — Touches covers the path it names → no report
#   302 — Touches prefix covers both paths → no report
#   303 — Touches misses a body path → REPORTED
#   304 — No Touches line (exclusive `*` sentinel) → not checked
#   305 — Touches: * (covers everything) → not checked
#   306 — Empty body → not checked
# Source the footprint helper for fp_conflict_strict (the extracted REPLAY block calls it).
. "${REPLAY_ROOT}/agents/footprint.sh"
slug="$IN_SLUG"
repo="$IN_REPO"
openall_fetch_rc=0
orphans=""
openall='[
  { "number": 301, "title": "all paths covered",
    "body": "## Deliverable\nAdd the helper in `agents/coordinator-scan.sh`.\n\nTouches: agents/coordinator-scan.sh\n" },
  { "number": 302, "title": "prefix scope covers multiple paths",
    "body": "## What\nCreate `agents/foo.sh` and wire `agents/bar/baz.sh`.\n\nTouches: agents/\n" },
  { "number": 303, "title": "body path outside the footprint",
    "body": "## Deliverable\nAdd a shared helper `agents/foo.sh`.\n\nTouches: argocd/resources/\n" },
  { "number": 304, "title": "no Touches line",
    "body": "## Deliverable\nAdd `agents/foo.sh`.\n\nNo touches declared.\n" },
  { "number": 305, "title": "Touches wildcard",
    "body": "## Deliverable\nAdd `agents/foo.sh`.\n\nTouches: *\n" },
  { "number": 306, "title": "empty body", "body": null }
]'

# ── seam (ADR-122 (3), homelab#1431) ── the ONE issue-body parser. The scan resolves it beside
# itself; a composition sees config-defaults BEFORE this bridge, so the path is set here.
IB_PY="$REPLAY_ROOT/agents/issue_body.py"
