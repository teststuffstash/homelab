# intake specs — the contract, and how it is worked

The spec root of [island intake](../README.md), in the shape of its siblings
([`../../launch/specs/README.md`](../../launch/specs/README.md),
[`../../scan/specs/README.md`](../../scan/specs/README.md)): **the reviewer reviews the result, not
the diff.** Rows are decision tables of key examples. Unlike the siblings, island intake is running
code ([../README.md](../README.md)), so a row here describes the sitting as it runs, and the
records it cites are live. **The rule files (`../rules/*.md`) are not specified here** — how a
sitting judges is theirs; this root holds what the sitting's surroundings must give it.

## Rules — the pinned process, and what this island adds

The numbered rules 1–11, the test & evidence conventions and the reviewer briefs live ONCE in
allure-behavior-snippets ([ADR-156](../../../docs/adr.md#adr-156--one-portable-specevidence-process-homed-in-allure-behavior-snippets-one-reviewer-runs-two-briefs-2026-10-16)),
pinned by version: **[RULES.md @ v0.6.9](https://github.com/teststuffstash/allure-behavior-snippets/blob/v0.6.9/allure_behavior_snippets/process/RULES.md)**,
**[CONVENTIONS.md @ v0.6.9](https://github.com/teststuffstash/allure-behavior-snippets/blob/v0.6.9/allure_behavior_snippets/process/CONVENTIONS.md)**.
"Rule N" anywhere in this island means rule N there.

What this island adds, by rule:

- **Rule 1 (gate):** reviewer-gated, not codeowner-gated. This root is not yet listed under
  homelab's claim `extraSpecs` (the siblings are, #3379), and the selector's `island_specs_root`
  does not name it, so no sitting reads its rows as gap inputs yet.
- **Rule 3 (IDs):** the prefix is `INTAKE-`; one area so far, `ACCESS`.
- **Rule 5 (evidence):** the tests root is [`../specs-tests/`](../specs-tests/) (its own devbox and
  uv project, apart from `../devbox.json`, which every live sitting installs), run by
  [`../scripts/ci.sh`](../scripts/ci.sh) through `diff-ci` — the pre-push hook and a worker's
  `pr-open`. GitHub CI does not run it yet. A case carries `rule("INTAKE-…")` and the row's
  description as its id, and writes raw Allure results locally; nothing is published, so every row
  stays unproven to the specs reviewer. The Status forms: `🚧 WIP — no evidence publisher for this
  root (<cases> pass locally against <target>)` for a requirement with cases; `🚧 WIP — no evidence
  pipeline yet: missing proof — <what>` for one without; a `⚑ gap` names its date, PR and work
  issue (rule 10). The running code's bash harness (`../tests/island-intake-test.sh`) is not this
  root's evidence; it rides `deep-dig-test`.
- **Rule 9 (external facts):** GitHub REST and ruleset behaviour, marked `> **External:**` at the
  requirement that rests on it, with where it was observed or "verify".
- **Worlds:** a row runs over the declared records at the commit under test, or a recorded GitHub
  answer ([worlds/README.md](worlds/README.md)) — mined, never invented.

## Index

| Requirement | Page | What it pins |
|---|---|---|
| [INTAKE-ACCESS-IDENTITY](access.md#intake-access-identity) | access | which identity the sitting acts as, followed through the declared records |
| [INTAKE-ACCESS-GOAL-BRANCH](access.md#intake-access-goal-branch) | access | the sitting can cut a Goal's branch at the default branch's head |
| [INTAKE-ACCESS-ISSUES](access.md#intake-access-issues) | access | label, comment, close, file, edit, sub-issue |
| [INTAKE-ACCESS-READ-PR](access.md#intake-access-read-pr) | access | a PR's body, reviews and checks |
| [INTAKE-ACCESS-CLONE](access.md#intake-access-clone) | access | homelab and a stack island's repo |
| [INTAKE-ACCESS-GATEWAY](access.md#intake-access-gateway) | access | the gateway admits the sitting's sessions |
| [INTAKE-ACCESS-TRANSCRIPTS](access.md#intake-access-transcripts) | access | ride records read, receipts written |
| [INTAKE-ACCESS-METRICS](access.md#intake-access-metrics) | access | alerts and gauges read, the sitting's gauges pushed |
| [INTAKE-ACCESS-DENIED](access.md#intake-access-denied) | access | no bypass, no unchecked update, no unreviewed change, no administration |
| [INTAKE-ACCESS-OWN-APP](access.md#intake-access-own-app) | access | the ruled target: a dedicated App and its least permission set |
