# shellcheck shell=bash
# The allure-behavior-snippets release this island renders evidence with — ONE pin, sourced by
# scripts/gateway-evidence.sh (oracle-fleet scripts/lib/snippets.sh shape; ADR-156 = one portable
# process, pinned per repo). Consumed as a RELEASE WHEEL, never a git clone (anonymous
# git-upload-pack gets rate-limited from the NAT'd WAN IP — oracle-fleet#362). `allure-evidence`
# reads RAW allure results → evidence.json, <RULE>.md fragments, digest.md; `--spec` joins a page's
# tables to the evidence rows. v0.5.2 = the join reads `||`-divided decision tables and plain
# sub-sections (0 → 14 of 14 rules joined here); v0.6.x = rule 11 (the requirement describes the
# system, never its tests), the header IS the parameter list, ROW_UNKEYED + HEADER_UNTHREADED in the
# digest (the GW-REDACT walkthrough, 2026-10-23); v0.6.2 = prose rules soft, unproven facts MARKED (rule 11).
# Bump TOGETHER with SNIPPETS_VERSION in
# agents/specs-reviewer-session.sh (the reviewer's context pack) — one process, two consumers.
SNIPPETS_WHEEL=https://github.com/teststuffstash/allure-behavior-snippets/releases/download/v0.6.2/allure_behavior_snippets-0.6.2-py3-none-any.whl

# allure_evidence <args…> — run the pinned tool's `allure-evidence` console script.
allure_evidence() {
  uv run --no-project --with "allure-behavior-snippets @ ${SNIPPETS_WHEEL}" allure-evidence "$@"
}
