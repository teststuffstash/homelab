#!/usr/bin/env bash
# Build the browsable specs site into specs-site/ — the oracle-fleet scripts/specs-build.sh shape,
# shared by a local dogfood build (`devbox run specs-build`) and scripts/specs-publish.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/site.sh
source scripts/lib/site.sh

# Evidence fragments BEFORE the build — pymdownx.snippets transcludes .site-evidence/<RULE>.md into
# spec pages at render time (mkdocs.yml, `--8<-- "<RULE>.md"` inside each rule's `<details>`). The
# fragments are the pinned allure-evidence tool's (scripts/gateway-evidence.sh → allure-evidence/:
# a rule's tables joined to the evidence where the tool parses them, the plain evidence table
# otherwise). `devbox run evidence` leaves them behind; a build without them is a valid
# fragment-less build (rule 5's visibly-unverified — the pages render as authored).
rm -rf .site-evidence && mkdir -p .site-evidence
if [ -d allure-evidence ]; then
  find allure-evidence -maxdepth 1 -name 'GW-*.md' -exec cp {} .site-evidence/ \;
fi

echo "== mkdocs: render README.md + specs/ =="
# Stage the island's documentation roots at their paths (mkdocs refuses docs_dir: ".").
rm -rf .site-src && mkdir .site-src
cp -r specs README.md .site-src/
rm -rf .site-src/specs/evidence   # the retired evidence_render.py fragment dir a stale tree may still carry

# The joined render (allure-evidence --spec-page-out; pin in scripts/lib/snippets.sh): on a build
# that carries a run's raw results, every spec page heading rules is rewritten in the STAGED copy —
# a rule whose decision tables join the run's evidence (≥1 description cell == a case id) keeps its
# own columns, each description linking to its case in the single-file report this site serves
# (REPORT_URL, scripts/lib/site.sh), a mark only on a row that is not fine (∅ unproven, ≠ cell
# mismatch); that rule's `<details>` evidence embed is dropped (the table IS the evidence). A rule
# whose tables join nothing keeps its authored tables and its fragment. The committed spec text is
# never touched; a build without allure-results/ renders the pages as authored.
# The report is generated ONCE per results set (scripts/allure-report.sh reuses a fresh one): Allure
# uids are per-generate, so the index.html the links were read from is the one shipped below.
if ls allure-results/*-result.json >/dev/null 2>&1; then
  bash scripts/allure-report.sh allure-results allure-report-single
  echo "== spec pages: join spec tables to this run's evidence (allure-evidence --spec-page-out → $REPORT_URL) =="
  # shellcheck source=lib/snippets.sh
  source scripts/lib/snippets.sh
  scratch=$(mktemp -d)
  trap 'rm -rf "$scratch"' EXIT
  csv() { local IFS=,; echo "$*"; }
  while IFS= read -r page; do
    mapfile -t rules < <(sed -nE 's/^#{2,6} (GW-[A-Z0-9-]+)\s*$/\1/p' "$page")
    allure_evidence --results allure-results --out "$scratch/$(echo "${page#specs/}" | tr '/' '_')" \
      --spec "$page" --rules "$(csv "${rules[@]}")" --spec-page-out ".site-src/$page" \
      --report allure-report-single/index.html --report-url "$REPORT_URL" >/dev/null
  done < <(grep -rlE '^#{2,6} GW-[A-Z0-9-]+\s*$' specs --include='*.md' --exclude-dir=evidence | sort)
fi

# mkdocs via uv --no-project, not the island's lock and not devbox: pymdownx/material must live
# in the same python env as mkdocs, which the nix-packaged mkdocs can't host, and the island's
# uv.lock is the SERVICE's closure, not the docs toolchain's. EXACT pins, the same three
# oracle-fleet builds with (its specs-build.sh): the mkdocs ecosystem forked in 2026-07 (mkdocs
# 2.0 vs properdocs) — unpinned resolution can silently swap the engine under the site.
rm -rf specs-site
uv run --no-project --with mkdocs==1.6.1 --with mkdocs-material==9.7.6 \
  --with pymdown-extensions==11.0.1 mkdocs build --quiet

# The run's Allure report rides beside the site at report/index.html — the one the joined rows
# link into (REPORT_URL). One copy per site (master root, pr-<N>/), overwritten by every publish;
# plain HTML here (openable from specs-site/ directly), gzipped by scripts/specs-publish.sh.
if [ -f allure-report-single/index.html ]; then
  mkdir -p specs-site/report && cp allure-report-single/index.html specs-site/report/index.html
fi

# Directory links in spec text (specs/worlds/, use-cases/uc-1/) must resolve on an object store
# with no listing support: give every output directory that lacks an index.html a generated one.
find specs-site -type d | while read -r d; do
  [ -f "$d/index.html" ] && continue
  {
    echo "<!doctype html><meta charset=utf-8><title>${d#specs-site/}</title><h1>${d#specs-site/}/</h1><ul>"
    for e in "$d"/*; do
      n=$(basename "$e"); [ -d "$e" ] && n="$n/"
      echo "<li><a href=\"$n\">$n</a></li>"
    done
    echo "</ul>"
  } > "$d/index.html"
done
echo "specs-build: specs-site/ ($(find specs-site -type f | wc -l) files$([ -f specs-site/report/index.html ] && echo ', report/index.html included'))"
