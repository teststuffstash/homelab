#!/bin/sh
# mermaid-lint — parse-validate every ```mermaid block in TRACKED markdown, so a diagram GitHub
# would refuse to render fails CI instead of being found by a reader (docs/README.md §Conventions:
# diagrams as Mermaid, renders on GitHub). Parse-only via mermaid's own parser under jsdom — no
# browser; deps pinned in scripts/mermaid-lint/package-lock.json. Runs from the repo root (devbox).
set -eu
cd "$(dirname "$0")/.."
d=scripts/mermaid-lint

# npm ci wipes node_modules, so skip it when the installed tree already matches the lockfile
if ! cmp -s "$d/package-lock.json" "$d/node_modules/.package-lock.json" 2>/dev/null; then
  (cd "$d" && npm ci --no-audit --no-fund --loglevel=error)
fi

git ls-files -z -- '*.md' | xargs -0 grep -lZ '```mermaid' -- 2>/dev/null \
  | xargs -0 node "$d/mermaid-lint.mjs"
