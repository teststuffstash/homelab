#!/usr/bin/env bash
# py-compile-lint — every tracked .py must at least parse (homelab#173). The gap it closes: the
# ConfigMap-shipped exporters/proxy (`argocd/resources/**/*.py`) are invisible to manifest-lint
# (it validates the YAML wrapper, never the script inside) and had NO CI check at all — a syntax
# error only surfaced when ArgoCD rolled the pod (#153's fix landed through exactly that blind
# spot). Parse-only on purpose: no imports are executed, so scripts with in-cluster-only deps
# (kopf, kubernetes) still lint anywhere. `python3` is the devbox-pinned interpreter.
#
#   devbox run py-compile-lint
set -euo pipefail
cd "$(dirname "$0")/.."
n="$(git ls-files '*.py' | wc -l)"
[ "$n" -gt 0 ] || { echo "py-compile-lint: PROBE-FAIL — zero .py files found (git ls-files broken?)" >&2; exit 1; }
if ! git ls-files '*.py' | xargs -r python3 -m py_compile; then
  echo "py-compile-lint: FAIL — a tracked .py does not parse (traceback above)" >&2
  exit 1
fi
echo "py-compile-lint: ok ($n files parse)"
