#!/usr/bin/env bash
# THE gate for the agent-gateway island: `cd gateway && devbox run ci` (the repo-root devbox's
# `gateway-ci` script and diff-ci's `gateway-ci:^gateway/` row reach this). One entrypoint:
#   uv sync --frozen → ruff → pytest (writes evidence/evidence.json + allure-results/) → spec gate
#   → the two ratchets (join, hygiene) → evidence render → the single-file Allure report → the
#   specs site build + lychee (every link and #anchor of the built site resolves).
# Exit codes are never pipe-filtered (a masked lint once hid a failing gate — CLAUDE.local.md).
set -euo pipefail
cd "$(dirname "$0")/.."
echo "== agent-gateway ci: $(pwd)"
export UV_PYTHON_PREFERENCE="${UV_PYTHON_PREFERENCE:-only-system}"

echo "== uv sync --frozen"
uv sync --frozen --quiet

echo "== ruff check"
uv run --frozen ruff check src tests scripts

echo "== pytest"
uv run --frozen pytest -q

echo "== spec gate"
uv run --frozen python scripts/spec_gate.py

# Spec ⇄ test join ratchet (snippets CONVENTIONS.md v0.6.9 § The lint gate item 6; specs/README.md
# §Rules): per rule, five join counts over the allure-results just produced, held flat against
# scripts/spec-join-baseline.json — exceeding fails, equal or lower passes, the fixing PR lowers the
# line (`allure_snippets_python scripts/spec-join-ratchet.py --write-baseline`). Runs inside the
# pinned wheel's env so it reuses the tool's own join (scripts/lib/snippets.sh).
echo "== spec ⇄ test join ratchet"
# shellcheck source=lib/snippets.sh
source scripts/lib/snippets.sh
allure_snippets_python scripts/spec-join-ratchet.py

# Report-hygiene ratchet (snippets CONVENTIONS § Prime rule of reporting; specs/README.md §Rules):
# the digest's hygiene codes as the SET of (rule · world · case · code) identities, held against
# scripts/spec-hygiene-baseline.json — a new identity is red with the case named; one that stopped
# firing prints "lowered" (re-record with --write-baseline). Declaring this ratchet is what lets
# the specs reviewer's repeat belt narrow to the cases a PR added or changed (snippets v0.6.9).
echo "== report-hygiene ratchet"
allure_snippets_python scripts/spec-hygiene-ratchet.py

echo "== evidence render"
# evidence/evidence.md + the BEGIN/END log block (the per-rule summary a reader outside the job
# can fetch from the run log). The site's fragments no longer come from here: scripts/specs-build.sh
# transcludes the pinned tool's <RULE>.md (scripts/gateway-evidence.sh → allure-evidence/).
uv run --frozen python scripts/evidence_render.py

echo "== allure report"
# allure-report-single/index.html — the run's one self-contained Allure report (open it in a
# browser). CI's gateway-evidence step reuses this generate for the pack's row links.
bash scripts/allure-report.sh

# Every link + #anchor in the BUILT site must resolve (lint gate item 3; lychee, offline — external
# URLs are checked by nothing here). Same build the publisher ships (scripts/specs-publish.sh runs
# specs-build.sh again with the run's evidence); this one carries the run's results too, so the
# joined rows' links into report/index.html are checked as published.
echo "== specs site: build + link/anchor gate"
bash scripts/specs-build.sh
# --exclude: the Allure report is an SPA — '#…' there is a hash ROUTE, not an HTML anchor, so
# fragment-checking it is meaningless; the file's existence is still guaranteed by specs-build.sh.
# Links that LEAVE the island (`../../docs/…` into homelab's docs, `../../agents/…`) are not site
# content — they resolve on GitHub and homelab's `docs-graph-lint` holds them; here they are external.
lychee --offline --include-fragments --no-progress --root-dir "$(pwd)/specs-site" \
  --exclude 'report/index\.html' --exclude '/gateway/(docs|agents|argocd|scripts)/' 'specs-site/**/*.html'

echo "== agent-gateway ci: green"
