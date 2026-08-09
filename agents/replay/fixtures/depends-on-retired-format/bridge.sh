# ── bridge ── the per-repo loop variables the lint reads and writes. `openall` is the ONE open-issue
# fetch the whole repo pass shares (agents/coordinator-scan.sh, above the queued loop) — the lint
# makes no call of its own, which is the point: a retired-format check that cost an API call per tick
# would not have been written.
slug="$IN_SLUG"
repo="$IN_REPO"
orphans=""
openall='[
  { "number": 225, "title": "delta job: land the manifest + the fleet wiring",
    "body": "## What\nBuild the delta path.\n\nDepends-on: #215\nTouches: infra/delta/\n" },
  { "number": 226, "title": "delta job: wire the fleet side",
    "body": "Notes:\n\n- Touches: fleet/delta/\n- Depends-on: oracle-fleet#215\n" },
  { "number": 227, "title": "prose that only talks about depending on things",
    "body": "This depends on #215 landing first, and the section below depends-on nothing.\n" },
  { "number": 228, "title": "authored the current way — a native edge, no body line",
    "body": "## What\nBuild the fleet side.\n\nTouches: fleet/delta/\n" },
  { "number": 229, "title": "an empty-bodied issue", "body": null }
]'
