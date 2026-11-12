#!/bin/sh
# mermaid-lint — parse-validate every ```mermaid block in TRACKED markdown, so a diagram GitHub
# would refuse to render fails CI instead of being found by a reader (docs/README.md §Conventions:
# diagrams as Mermaid, renders on GitHub). Parse-only via mermaid's own parser under linkedom — no
# browser. Runs from the repo root (devbox).
#
# ADR-143: the parser runs under Deno with NO permissions. This wrapper reads the files and pipes
# them in as NUL-separated `path\0content\0` pairs, so mermaid and its whole dependency tree see no
# env, no filesystem (not even the gitignored secrets in this checkout), no network, no subprocess.
# Deno never runs npm lifecycle scripts; `--frozen` refuses any resolution the committed deno.lock
# does not already pin (integrity-checked), and deno.json's minimumDependencyAge keeps every
# resolved version — transitive ones included — at least 7 days old when the lock is regenerated.
set -eu
cd "$(dirname "$0")/.."
d=scripts/mermaid-lint

# Fetch the locked deps FIRST, bounded, through the LAN npm cache (SERVICES.md §npm cache; the NAME —
# Deno cannot use an IP registry, ADR-143). A fresh ARC runner has no deno cache, and a stalled
# registry.npmjs.org download inside the pipeline below had no timeout: deno never read stdin, `cat`
# blocked on the full pipe, and the ci job hung to GitHub's 6 h limit holding a runner (2026-11-12,
# two runs). Fetching separately keeps that failure loud and short; the integrity hashes in
# deno.lock still decide what is accepted, whichever registry serves the bytes.
export NPM_CONFIG_REGISTRY="${NPM_CONFIG_REGISTRY:-http://npm-cache.teststuff.net/}"
fetch() { timeout 180 deno cache --quiet --frozen --config "$d/deno.json" --lock "$d/deno.lock" "$d/mermaid-lint.ts"; }
fetch || { echo "mermaid-lint: dependency fetch failed or stalled (registry $NPM_CONFIG_REGISTRY) — retrying once" >&2; fetch; }

# newline-separated names (dash has no `read -d ''`; no tracked path contains a newline)
git ls-files -z -- '*.md' | xargs -0 grep -l '```mermaid' -- 2>/dev/null \
  | while IFS= read -r f; do printf '%s\0' "$f"; cat "$f"; printf '\0'; done \
  | timeout 300 deno run --quiet --no-prompt --frozen --config "$d/deno.json" --lock "$d/deno.lock" "$d/mermaid-lint.ts"
