#!/usr/bin/env bash
# Build the browsable specs site into specs-site/ — the oracle-fleet scripts/specs-build.sh shape,
# shared by a local dogfood build (`devbox run specs-build`) and scripts/specs-publish.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

# Evidence fragments BEFORE the build — pymdownx.snippets transcludes specs/evidence/<RULE>.md
# into spec pages at render time (mkdocs.yml). `devbox run ci` leaves them behind (pytest →
# evidence/evidence.json → evidence_render.py); a build without a prior ci run re-renders from
# whatever evidence.json exists, and none at all is a valid fragment-less build (rule 5's
# visibly-unverified).
mkdir -p specs/evidence
if [ -f evidence/evidence.json ]; then
  uv run --frozen python scripts/evidence_render.py
fi

echo "== mkdocs: render README.md + specs/ =="
# Stage the island's documentation roots at their paths (mkdocs refuses docs_dir: ".").
rm -rf .site-src && mkdir .site-src
cp -r specs README.md .site-src/

# mkdocs via uv --no-project, not the island's lock and not devbox: pymdownx/material must live
# in the same python env as mkdocs, which the nix-packaged mkdocs can't host, and the island's
# uv.lock is the SERVICE's closure, not the docs toolchain's. EXACT pins, the same three
# oracle-fleet builds with (its specs-build.sh): the mkdocs ecosystem forked in 2026-07 (mkdocs
# 2.0 vs properdocs) — unpinned resolution can silently swap the engine under the site.
rm -rf specs-site
uv run --no-project --with mkdocs==1.6.1 --with mkdocs-material==9.7.6 \
  --with pymdown-extensions==11.0.1 mkdocs build --quiet

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
echo "specs-build: specs-site/ ($(find specs-site -type f | wc -l) files)"
