# shellcheck shell=bash
# The allure-behavior-snippets release this island renders evidence with — ONE pin, sourced by
# scripts/gateway-evidence.sh (oracle-fleet scripts/lib/snippets.sh shape; ADR-156 = one portable
# process, pinned per repo). Consumed as a RELEASE WHEEL, never a git clone (anonymous
# git-upload-pack gets rate-limited from the NAT'd WAN IP — oracle-fleet#362). v0.4.2:
# `allure-evidence` reads RAW allure results → evidence.json, <RULE>.md fragments, digest.md,
# `--spec` joins a page's tables to the evidence rows.
SNIPPETS_WHEEL=https://github.com/teststuffstash/allure-behavior-snippets/releases/download/v0.4.2/allure_behavior_snippets-0.4.2-py3-none-any.whl

# allure_evidence <args…> — run the pinned tool's `allure-evidence` console script.
allure_evidence() {
  uv run --no-project --with "allure-behavior-snippets @ ${SNIPPETS_WHEEL}" allure-evidence "$@"
}
