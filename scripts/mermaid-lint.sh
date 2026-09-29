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

# homelab#1247: agent rides were given a kill-switch when `npm ci` here was a silent retry storm
# against a denied registry. Still honoured until a ride drill proves Deno's first fetch through
# the baseline npm mirror (NPM_CONFIG_REGISTRY) — FU-294. GitHub CI never sets it.
if [ "${MERMAID_LINT_NO_INSTALL:-}" = "1" ]; then
  echo "mermaid-lint SKIPPED — MERMAID_LINT_NO_INSTALL=1 (homelab#1247, FU-294); CI is the gate"
  exit 0
fi

# newline-separated names (dash has no `read -d ''`; no tracked path contains a newline)
git ls-files -z -- '*.md' | xargs -0 grep -l '```mermaid' -- 2>/dev/null \
  | while IFS= read -r f; do printf '%s\0' "$f"; cat "$f"; printf '\0'; done \
  | deno run --quiet --no-prompt --frozen --config "$d/deno.json" --lock "$d/deno.lock" "$d/mermaid-lint.ts"
