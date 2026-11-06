# shellcheck shell=bash
# The allure-behavior-snippets release this island renders evidence with — ONE pin, sourced by
# scripts/gateway-evidence.sh, scripts/specs-build.sh and scripts/ci.sh (oracle-fleet
# scripts/lib/snippets.sh shape; ADR-156 = one portable process, pinned per repo). Consumed as a
# RELEASE WHEEL, never a git clone (anonymous git-upload-pack gets rate-limited from the NAT'd WAN
# IP — oracle-fleet#362). `allure-evidence` reads RAW allure results → evidence.json, <RULE>.md
# fragments, digest.md; `--spec` joins a page's tables to the evidence rows. v0.5.2 = the join reads
# `||`-divided decision tables and plain sub-sections; v0.6.x = rule 11 (the requirement describes
# the system, never its tests), the header IS the parameter list, ROW_UNKEYED + HEADER_UNTHREADED in
# the digest; v0.6.2 = prose rules soft, unproven facts MARKED (rule 11); v0.6.3 = expected columns
# end in `?` (argname `expected_<name>`), the `||` divider read but retired; v0.6.4 =
# `evidence-pack --mask-descriptions`, the specs reviewer's staged read (rows-brief check 10);
# v0.6.7 = a surviving blocking finding stays in the verdict until it carries a permitted
# disposition (snippets#43); v0.6.8 = pass1-prior.tsv + touched-rules scoped by glossary term
# (snippets#46/#48); v0.6.9 = the hygiene-repeat belt escalates only the cases a PR added or changed
# (`**Cases:**` + [added|changed|unchanged] marks in the digest) — the exemption applies where the
# consuming repo DECLARES a hygiene ratchet (snippets#49/#50): this island's is
# scripts/spec-hygiene-ratchet.py, declared in specs/README.md §Rules.
# Bump TOGETHER with SNIPPETS_VERSION in
# agents/specs-reviewer-session.sh (the reviewer's context pack) — one process, two consumers.
SNIPPETS_WHEEL=https://github.com/teststuffstash/allure-behavior-snippets/releases/download/v0.6.9/allure_behavior_snippets-0.6.9-py3-none-any.whl

# allure_evidence <args…> — run the pinned tool's `allure-evidence` console script.
allure_evidence() {
  uv run --no-project --with "allure-behavior-snippets @ ${SNIPPETS_WHEEL}" allure-evidence "$@"
}

# allure_snippets_python <script.py> [args…] — run an island script that imports the pinned tool
# (`from allure_behavior_snippets import evidence`) inside the wheel's environment, so the island
# reuses the tool's own join and hygiene computation instead of re-implementing them
# (scripts/spec-join-ratchet.py, scripts/spec-hygiene-ratchet.py — the two ratchets in scripts/ci.sh).
allure_snippets_python() {
  uv run --no-project --with "allure-behavior-snippets @ ${SNIPPETS_WHEEL}" python "$@"
}
