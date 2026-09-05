# ── bridge ── the per-repo scan state both blocks read. Every name is one the shipped script sets
# before the queued loop (`repo`, `openall`, `openall_fetch_rc`, `inprog`, `orphans`), never a
# harness invention. `inprog` is `openall` with the in-progress labels the busy-fps select needs,
# so ONE set of bodies drives both clauses — the same issue seen by the malformed gate and by the
# footprint reader.
repo="homelab"
orphans=""
openall_fetch_rc=0
openall='[
  { "number": 501, "title": "legacy Touches line",
    "labels": [{"name": "agent-fix"}, {"name": "agent/in-progress"}],
    "body": "## Deliverable\nAdd the helper.\n\nTouches: agents/foo.sh\n" },
  { "number": 502, "title": "block-authored twin of 501",
    "labels": [{"name": "agent-fix"}, {"name": "agent/in-progress"}],
    "body": "---\nTouches: agents/foo.sh\n---\n\n## Deliverable\nAdd the helper.\n" },
  { "number": 503, "title": "malformed block — a key outside the grammar",
    "labels": [{"name": "agent-fix"}, {"name": "agent/in-progress"}],
    "body": "---\nTouchez: agents/foo.sh\n---\n\n## Deliverable\nAdd the helper.\n" },
  { "number": 504, "title": "no footprint declared",
    "labels": [{"name": "agent-fix"}, {"name": "agent/in-progress"}],
    "body": "## Deliverable\nAdd the helper.\n" }
]'
inprog="$openall"

# ── seam (ADR-122 (3), homelab#1431) ── the ONE issue-body parser. The scan resolves it beside
# itself; a composition sees config-defaults BEFORE this bridge, so the path is set here.
IB_PY="$REPLAY_ROOT/agents/issue_body.py"
