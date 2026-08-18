#!/usr/bin/env bash
# touches-check-test.sh — the ADR-097 escape-set verification (homelab#379): synthetic tests
# over the EXACT predicate the reviewer and scan source (agents/touches-check.sh). The helper
# computes which PR paths fall outside the declared Touches: footprint (the escape set) so the
# reviewer can flag governance-path escapes as BLOCKING findings per .agents/review.md.
# Run in ci (devbox run touches-check-test).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/touches-check.sh"

fails=0

# test_escapes <desc> <declared-touches> <changed-paths> <expected-output>
# Verifies that touches_check returns the expected escape set.
test_escapes() {
  local desc="$1" declared="$2" paths="$3" expected="$4"
  local result
  result="$(touches_check "$declared" "$paths" 2>/dev/null || true)"
  if [ "$result" != "$expected" ]; then
    echo "FAIL: $desc"
    echo "  declared: '$declared'"
    echo "  paths: $(printf '%s' "$paths" | tr '\n' ',')"
    echo "  expected: '$expected'"
    echo "  got: '$result'"
    fails=$((fails + 1))
  fi
}

# ── CASE 1: Declared Touches with escapes into governance paths ────────────────────────────
# A PR declaring "agents/reviewer-session.sh" but writing to "agents/coordinator-scan.sh"
# and "docs/agents/issue-authoring.md" should report both as escapes, with governance marking.
test_escapes "declared with governance escapes" \
  "agents/reviewer-session.sh" \
  "$(printf 'agents/reviewer-session.sh\nagents/coordinator-scan.sh\ndocs/agents/issue-authoring.md\n')" \
  "$(printf 'agents/coordinator-scan.sh|governance\ndocs/agents/issue-authoring.md\n')"

# ── CASE 2: No escapes — all changed paths covered by declared Touches ─────────────────────
# A PR declaring "agents/**" should not escape any paths under agents/ or its subdirs.
test_escapes "no escapes — fully declared" \
  "agents/**" \
  "$(printf 'agents/reviewer-session.sh\nagents/coordinator-scan.sh\nagents/replay/README.md\n')" \
  ""

# ── CASE 3: No escapes with multiple declared entries ──────────────────────────────────────
# A PR declaring "agents/reviewer-session.sh, agents/coordinator-scan.sh" should not escape
# those exact files.
test_escapes "no escapes — multiple entries exact match" \
  "agents/reviewer-session.sh, agents/coordinator-scan.sh" \
  "$(printf 'agents/reviewer-session.sh\nagents/coordinator-scan.sh\n')" \
  ""

# ── CASE 4: Undeclared Touches (empty string) — all paths escape ──────────────────────────
# No declared Touches means everything escapes.
test_escapes "undeclared — all paths escape" \
  "" \
  "$(printf 'agents/touches-check.sh\ndocs/agents/issue-lifecycle-fsm.md\nargocd/resources/example.yaml\n')" \
  "$(printf 'agents/touches-check.sh|governance\ndocs/agents/issue-lifecycle-fsm.md\nargocd/resources/example.yaml\n')"

# ── CASE 5: Undeclared Touches (sentinel "*") — all paths escape ──────────────────────────
# The wildcard sentinel * (used for issues without a Touches line) matches everything,
# so all paths are escaped.
test_escapes "undeclared sentinel — all paths escape" \
  "*" \
  "$(printf 'docs/readme.md\nscripts/example.sh\n')" \
  "$(printf 'docs/readme.md\nscripts/example.sh|governance\n')"

# ── CASE 6: Mixed governance and non-governance escapes ──────────────────────────────────
# When some escaped paths are governance and others are not, both should be reported but
# governance ones marked.
test_escapes "mixed governance and regular escapes" \
  "argocd/resources/**" \
  "$(printf 'argocd/resources/example.yaml\nagents/new-file.sh\ndocs/new.md\n')" \
  "$(printf 'agents/new-file.sh|governance\ndocs/new.md\n')"

# ── CASE 7: Declared directory vs escaped subdirs ─────────────────────────────────────────
# A declared "agents/" (normalized to "agents") should cover "agents/subdir/**" paths.
test_escapes "declared dir covers subdir" \
  "agents/" \
  "$(printf 'agents/subdir/deep/file.sh\nagents/toplevel.sh\n')" \
  ""

# ── CASE 8: Path boundaries — similar names should not match ───────────────────────────────
# Declared "agents" should not match "agents-old" or "agents-backup".
# Note: these paths escape but don't match governance patterns (which require exact prefix match).
test_escapes "path boundary — similar names don't match" \
  "agents" \
  "$(printf 'agents-old/file.sh\nagents-backup/other.sh\n')" \
  "$(printf 'agents-old/file.sh\nagents-backup/other.sh\n')"

# ── CASE 9: Escape into .agents/ (governance) ─────────────────────────────────────────────
test_escapes "escape into .agents governance tier" \
  "docs/agents/**" \
  "$(printf 'docs/agents/file.md\n.agents/review.md\n')" \
  ".agents/review.md|governance"

# ── CASE 10: Multiple governance tiers in escapes ──────────────────────────────────────────
# Check that all governance tiers are recognized: agents/**, .agents/**, scripts/**, policy/**,
# .github/**, tofu/github/**, tofu/cloudflare/**
test_escapes "multiple governance tiers" \
  "docs/**" \
  "$(printf 'docs/file.md\nagents/file.sh\nscripts/file.sh\npolicy/rule.rego\n.github/workflow.yaml\ntofu/github/main.tf\ntofu/cloudflare/dns.tf\n')" \
  "$(printf 'agents/file.sh|governance\nscripts/file.sh|governance\npolicy/rule.rego|governance\n.github/workflow.yaml|governance\ntofu/github/main.tf|governance\ntofu/cloudflare/dns.tf|governance\n')"

# ── CASE 11: the replay-tree exemption (ADR-097 addendum, 2026-08-18) ──────────────────────
# A changed path under agents/replay/ is NEVER an escape: the ADR-103 ratchet COMPELS a replay
# touch on every clause PR, and flagging the compelled edit as a governance escape is the
# PR#547 defect. Non-replay escapes in the same diff still report.
test_escapes "replay paths are never escapes" \
  "agents/coordinator-scan.sh" \
  "$(printf 'agents/coordinator-scan.sh\nagents/replay/fixtures/new/fixture.yaml\nagents/replay/README.md\nagents/model-scout.sh\n')" \
  "agents/model-scout.sh|governance"

# ── CASE 12: replay exempt even with an UNDECLARED footprint ────────────────────────────────
test_escapes "replay exempt in the undeclared branch too" \
  "" \
  "$(printf 'agents/replay/fixtures/x/bridge.sh\ndocs/new.md\n')" \
  "docs/new.md"

# ── CASE 13: replay-ADJACENT names still escape with the governance marker ──────────────────
test_escapes "replay-adjacent path is not exempt" \
  "docs/**" \
  "$(printf 'agents/replay-foo/file.sh\n')" \
  "agents/replay-foo/file.sh|governance"

if [ "$fails" -gt 0 ]; then
  echo "touches-check-test: ${fails} FAILED"
  exit 1
fi
echo "touches-check-test: all cases pass"
