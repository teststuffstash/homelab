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
  # homelab#1247: in agent rides the egress CNP denies registry.npmjs.org (no node profile), so
  # `npm ci` here was a silent retry storm (~12k POLICY_DENIED/24h) on every md-touching ride.
  # The launcher sets MERMAID_LINT_NO_INSTALL=1 unconditionally (agents/agent-session.sh env
  # card, the DEVBOX_NO_UPDATE_CHECK precedent): under it, skip the install AND the lint with a
  # loud line instead of attempting the registry — GitHub CI never sets the var and stays the
  # gate that actually parses the diagrams.
  if [ "${MERMAID_LINT_NO_INSTALL:-}" = "1" ]; then
    echo "mermaid-lint SKIPPED — registry installs disabled in this environment (MERMAID_LINT_NO_INSTALL=1, homelab#1247); node_modules not populated, CI is the gate"
    exit 0
  fi
  (cd "$d" && npm ci --no-audit --no-fund --loglevel=error)
fi

git ls-files -z -- '*.md' | xargs -0 grep -lZ '```mermaid' -- 2>/dev/null \
  | xargs -0 node "$d/mermaid-lint.mjs"
