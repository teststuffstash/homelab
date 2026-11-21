#!/usr/bin/env bash
# Build the browsable specs site into specs-site/ — the oracle-fleet scripts/specs-build.sh shape,
# shared by a local dogfood build (`devbox run specs-build`) and scripts/specs-publish.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/site.sh
source scripts/lib/site.sh
# shellcheck source=lib/site-build.sh
source scripts/lib/site-build.sh

# Evidence fragments BEFORE the build — pymdownx.snippets transcludes .site-evidence/<RULE>.md into
# spec pages at render time (mkdocs.yml, `--8<-- "<RULE>.md"` inside each rule's `<details>`). The
# fragments are the pinned allure-evidence tool's (scripts/gateway-evidence.sh → allure-evidence/:
# a rule's tables joined to the evidence where the tool parses them, the plain evidence table
# otherwise). `devbox run evidence` leaves them behind; a build without them is a valid
# fragment-less build (rule 5's visibly-unverified — the pages render as authored).
rm -f .specs-site.stamp   # rewritten only when this build completes (site_build_stamp, lib/site.sh)
rm -rf .site-evidence && mkdir -p .site-evidence
if [ -d allure-evidence ]; then
  find allure-evidence -maxdepth 1 -name 'GW-*.md' -exec cp {} .site-evidence/ \;
fi

echo "== mkdocs: render README.md + specs/ =="
# Stage the island's documentation roots at their paths (mkdocs refuses docs_dir: ".").
rm -rf .site-src && mkdir .site-src
cp -r specs README.md .site-src/
rm -rf .site-src/specs/evidence   # the retired evidence_render.py fragment dir a stale tree may still carry
# Spec pages link recorded fixtures as spec text (the codex capture bundle, the live catalog answers
# — worlds are public and discussable); stage them so those links resolve on the site too.
mkdir -p .site-src/tests && cp -r tests/fixtures .site-src/tests/fixtures

# The joined render (site_join_pages, scripts/lib/site-build.sh): on a build that carries a run's
# raw results, every spec page heading rules is rewritten in the STAGED copy, its decision tables
# joined to the run's evidence and linking into the single-file report this site serves
# (REPORT_URL, scripts/lib/site.sh). A build without allure-results/ renders the pages as authored.
# The report is generated ONCE per results set (scripts/allure-report.sh reuses a fresh one): Allure
# uids are per-generate, so the index.html the links were read from is the one shipped below.
if ls allure-results/*-result.json >/dev/null 2>&1; then
  bash scripts/allure-report.sh allure-results allure-report-single
  echo "== spec pages: join spec tables to this run's evidence (allure-evidence --spec-page-out → $REPORT_URL) =="
  # shellcheck source=lib/snippets.sh
  source scripts/lib/snippets.sh
  site_join_pages GW "$REPORT_URL"
fi

# The pinned flowchart renderer + the pinned mkdocs toolchain (both in scripts/lib/site-build.sh).
site_stage_mermaid
site_mkdocs_build

# The run's Allure report rides beside the site at report/index.html — the one the joined rows
# link into (REPORT_URL). One copy per site (master root, pr-<N>/), overwritten by every publish;
# plain HTML here (openable from specs-site/ directly), gzipped by scripts/specs-publish.sh.
if [ -f allure-report-single/index.html ]; then
  mkdir -p specs-site/report && cp allure-report-single/index.html specs-site/report/index.html
fi

# Every output directory gets an index.html (object store, no listing support).
site_dir_indexes
stamp=$(site_build_stamp)
[ -z "$stamp" ] || printf '%s\n' "$stamp" > .specs-site.stamp
echo "specs-build: specs-site/ ($(find specs-site -type f | wc -l) files$([ -f specs-site/report/index.html ] && echo ', report/index.html included'))"
