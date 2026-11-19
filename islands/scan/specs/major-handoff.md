---
id: IF-SCAN-MAJOR-HANDOFF
use-cases: []
schema: major-handoff.schema.json
---
# `major-handoff.sh <owner/repo> <pr>` — the only writer of `major/awaiting-human`

*Is this un-armed `major` dependency bump ready for a human to merge — or, if its app did not move,
ready to merge itself?* The coordinator session owns an un-armed `major` PR end to end (brief
§Dependency major bumps): investigate while red, fix within budget, get the reviewer's migration
lens. Step 5 — the handoff to a human — is this script, never a hand relabel: on 2026-09-25 two
`major` PRs were relabelled with `reviews: []` because a label a model can apply is advice, not
mechanism (homelab#1987; ADR-094: the LLM judges, launcher-owned shell acts). The caller branches
on the exit code; the script posts no comment — the label is the record, the reviewer's approval
body is the evidence. Terms: [glossary.md](glossary.md), [docs/glossary.md](../../../docs/glossary.md).
No use case walks it yet (rule 8 — a candidate for UC-2: a major bump from Renovate to a human merge).

## Interface — the machine half

**[`major-handoff.schema.json`](major-handoff.schema.json)** holds the invocation, the fields of
the PR read the gate requires (`pr_read`), the four headings and the exit contract.

| Requirement | Governs (schema) | Status |
|---|---|---|
| [SCAN-HANDOFF-GATE](#scan-handoff-gate) | `exit`, `evidence` | 🚧 WIP → #3490 — rule-labelled tests in islands/scan/tests/test_major_handoff.py over recorded world `pr-handoff`; no evidence publisher for this root (comparison: `major-handoff`) |
| [SCAN-HANDOFF-ARM](#scan-handoff-arm) | `exit`, `evidence.upstream_line` | 🚧 WIP → #3490 — rule-labelled tests in islands/scan/tests/test_major_handoff.py over recorded world `pr-handoff`; no evidence publisher for this root (comparison: `major-handoff`) |

### SCAN-HANDOFF-GATE

`major/awaiting-human` is written only when (1) the PR is open and carries `major`; (2) the
reviewer bot (`homelab-reviewer`, `[bot]` suffix normalized) has an APPROVED review submitted
after the newest **non-merge** commit — the reflex's own `bot_approved_head`, replicated by name
(a merge commit, in any of GitHub's three default message shapes, is not new content); (3) that
review's body carries the four headings `Upstream`, `Known issues`, `Platform compatibility`,
`Evidence`, each as a line-anchored `## …` heading or `**…**` label, case-insensitive; the heading name is matched at the start of the line, and a
suffix after a separator on the same line (e.g. `## Evidence — re-review at new head <sha>`) still
counts, while a name with no separator (`## Evidenced`) does not. Then it
adds `major/awaiting-human` **first**, removes `agent/in-progress` **second** (add-before-remove,
IL-T16) and re-reads the labels to prove the end state (`agents/major-handoff.sh:1-60`).
Exit 0 = handed off; **3** = refused, nothing written (dispatch the reviewer again, never relabel);
**4** = a probe failed before any write (rule #6); **5** = writes issued, end state not proven (a
human looks).

⚖ An answer to the PR read that lacks a field the schema's `pr_read` requires is unreadable: exit 4,
nothing written, no default substituted (the old member reads an absent field as null). ⚖ Removing
a claim label that is already absent (the DELETE answers 404) is success; the label re-read still
decides the end state. ⚖ A heading line may end CRLF.

**World:** [`pr-handoff`](worlds/README.md#recorded-worlds-worldsname--here). Every row starts from
the recording with these overrides: the PR is open; its newest non-merge commit is older than the
reviewer bot's APPROVED review; that review's body carries the four headings; after the writes the
label re-read lists `major/awaiting-human` and not `agent/in-progress`. A row's cells override that
state.

The `expect?` literals of both tables on this page:

| literal | writes issued, in order | exit | the printed refusal names |
|---|---|---|---|
| handoff | add `major/awaiting-human`; remove `agent/in-progress`; then the label re-read | 0 | — |
| armed | arm auto-merge (squash); remove `agent/in-progress`; then the pull re-read | 0 | — |
| refused-headings | none | 3 | `heading` |
| refused-stale | none | 3 | `predates` |
| refused-not-major | none | 3 | `major` |
| refused-no-approval | none | 3 | `no APPROVED review` |
| unreadable | none | 4 | — |
| not-proven | add `major/awaiting-human`; remove `agent/in-progress`; then the label re-read | 5 | — |

⚖ The four `refused-*` literals differ only in the words the refusal prints, checked as
containment. The alternative is one `refused` literal, which loses the distinction the four rows
are named for.

#### Does the handoff write the label?

| description | world | labels | newest commit | bot review | fault | expect? |
|---|---|---|---|---|---|---|
| handoff | pr-handoff | `major`, `agent/in-progress` | content, before the approval | APPROVED, four headings | — | handoff |
| merge-commit-not-content | pr-handoff | `major`, `agent/in-progress` | merge, after the approval: `Merge branch 'master' into <head>` | APPROVED, four headings | — | handoff |
| merge-remote-not-content | pr-handoff | `major`, `agent/in-progress` | merge, after the approval: `Merge remote-tracking branch '<remote>/master' into <head>` | APPROVED, four headings | — | handoff |
| merge-pr-not-content | pr-handoff | `major`, `agent/in-progress` | merge, after the approval: `Merge pull request #<n> from <owner>/<head>` | APPROVED, four headings | — | handoff |
| bot-suffix-normalized | pr-handoff | `major`, `agent/in-progress` | content, before the approval | APPROVED by `homelab-reviewer[bot]`, four headings | — | handoff |
| suffixed-headings | pr-handoff | `major`, `agent/in-progress` | content, before the approval | APPROVED, four headings, one written `## Evidence — re-review at new head <sha>` | — | handoff |
| approved-without-headings | pr-handoff | `major`, `agent/in-progress` | content, before the approval | APPROVED, no headings | — | refused-headings |
| approval-stale | pr-handoff | `major`, `agent/in-progress` | content, after the approval | APPROVED, four headings | — | refused-stale |
| not-major-lane | pr-handoff | `dependencies`, `agent/in-progress` | content, before the approval | APPROVED, four headings | — | refused-not-major |
| no-approval | pr-handoff | `major`, `agent/in-progress` | content | none (`reviews` is empty) | — | refused-no-approval |
| reviews-unreadable | pr-handoff | `major`, `agent/in-progress` | content, before the approval | APPROVED, four headings | the PR read fails | unreadable |
| end-state-not-proven | pr-handoff | `major`, `agent/in-progress` | content, before the approval | APPROVED, four headings | the label re-read after the writes still lists `agent/in-progress` | not-proven |
| answer-lacks-field ⚖ | pr-handoff | `major`, `agent/in-progress` | content, before the approval | APPROVED, four headings | the PR read's answer has no `commits` field | unreadable |
| claim-already-absent ⚖ | pr-handoff | `major` | content, before the approval | APPROVED, four headings | the DELETE of `agent/in-progress` answers 404 | handoff |
| crlf-approval-body ⚖ | pr-handoff | `major`, `agent/in-progress` | content, before the approval | APPROVED, four headings, body lines ending CRLF | — | handoff |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-HANDOFF-GATE.md"

</details>

### SCAN-HANDOFF-ARM

The one exception: a **packaging-only chart major** — a chart whose embedded app version did not
move is a `major` by semver only (ADR-141 as amended 2026-10-06). When the approval at head opens
its `## Upstream` section with the structured line `appVersion: unchanged (<v>)` (line-anchored,
case-insensitive; the migration lens writes it, `agents/lenses/migration.md` §Charts), the gate
**arms auto-merge** (`gh pr merge --auto --squash`) instead of parking, removes the claim, and
proves the end state on the REST pull endpoint (`auto_merge` set, claim gone); exit 0 with an
`→ ARMED (packaging-only chart major …)` line. An `appVersion: A → B` line, or none, is the human
lane of [SCAN-HANDOFF-GATE](#scan-handoff-gate). The structured verdict line decides, never a
label a human sets.

**World:** [`pr-handoff`](worlds/README.md#recorded-worlds-worldsname--here). Both rows start from
the `handoff` row's state of [SCAN-HANDOFF-GATE](#scan-handoff-gate); the `expect?` literals are
that section's legend.

#### Does a chart major arm or park?

| description | world | first line of the review's `## Upstream` section | expect? |
|---|---|---|---|
| packaging-only-arms | pr-handoff | `appVersion: unchanged (v4.1.4)` | armed |
| app-moves-parks | pr-handoff | `appVersion: 4.1.0 → 4.1.4` | handoff |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-HANDOFF-ARM.md"

</details>
