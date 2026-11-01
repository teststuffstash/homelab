# shellcheck shell=bash
# The allure-behavior-snippets release this island renders evidence with — ONE pin, sourced by
# scripts/gateway-evidence.sh (oracle-fleet scripts/lib/snippets.sh shape; ADR-156 = one portable
# process, pinned per repo). Consumed as a RELEASE WHEEL, never a git clone (anonymous
# git-upload-pack gets rate-limited from the NAT'd WAN IP — oracle-fleet#362). `allure-evidence`
# reads RAW allure results → evidence.json, <RULE>.md fragments, digest.md; `--spec` joins a page's
# tables to the evidence rows. v0.5.2 = the join reads `||`-divided decision tables and plain
# sub-sections (0 → 14 of 14 rules joined here); v0.6.x = rule 11 (the requirement describes the
# system, never its tests), the header IS the parameter list, ROW_UNKEYED + HEADER_UNTHREADED in the
# digest (the GW-REDACT walkthrough, 2026-10-23); v0.6.2 = prose rules soft, unproven facts MARKED (rule 11);
# v0.6.4 = `evidence-pack --mask-descriptions`, the specs reviewer's staged read (rows-brief check 10).
# v0.6.7 = the finding contract keeps a surviving blocking finding in the verdict until it carries a
# permitted disposition (an existing open issue + the page marker) — snippets#43.
# v0.6.8 = pass1-prior.tsv (the prior rounds' pass-2 rulings reach the masked pass as keys, snippets#46)
# + touched-rules scopes the glossary source by changed term, CommonMark fences (#48); v0.6.9 = the
# hygiene-repeat belt escalates only cases the PR added or changed, `**Cases:**` + [added|changed|
# unchanged|no baseline] marks in the digest — the exemption applies only where the consuming repo
# declares a hygiene ratchet (#49/#50); the gateway suite declares none yet, so its belt is unchanged.
# Bump TOGETHER with SNIPPETS_VERSION in
# agents/specs-reviewer-session.sh (the reviewer's context pack) — one process, two consumers.
SNIPPETS_WHEEL=https://github.com/teststuffstash/allure-behavior-snippets/releases/download/v0.6.9/allure_behavior_snippets-0.6.9-py3-none-any.whl

# allure_evidence <args…> — run the pinned tool's `allure-evidence` console script.
allure_evidence() {
  uv run --no-project --with "allure-behavior-snippets @ ${SNIPPETS_WHEEL}" allure-evidence "$@"
}
