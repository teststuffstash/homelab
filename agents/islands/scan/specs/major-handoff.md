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
body is the evidence. Terms: [glossary.md](glossary.md), [docs/glossary.md](../../../../docs/glossary.md).
No use case walks it yet (rule 8 — a candidate for UC-2: a major bump from Renovate to a human merge).

## Interface — the machine half

**[`major-handoff.schema.json`](major-handoff.schema.json)** holds the invocation, the four
headings and the exit contract.

| Requirement | Governs (schema) | Status |
|---|---|---|
| [SCAN-HANDOFF-GATE](#scan-handoff-gate) | `exit`, `evidence` | 🚧 WIP — no evidence pipeline yet (fixture: `major-handoff`) |
| [SCAN-HANDOFF-ARM](#scan-handoff-arm) | `exit`, `evidence.upstream_line` | 🚧 WIP — no evidence pipeline yet (fixture: `major-handoff`) |

### SCAN-HANDOFF-GATE

`major/awaiting-human` is written only when (1) the PR is open and carries `major`; (2) the
reviewer bot (`homelab-reviewer`, `[bot]` suffix normalized) has an APPROVED review submitted
after the newest **non-merge** commit — the reflex's own `bot_approved_head`, replicated by name
(a merge commit, in any of GitHub's three default message shapes, is not new content); (3) that
review's body carries the four headings `Upstream`, `Known issues`, `Platform compatibility`,
`Evidence`, each as a line-anchored `## …` heading or `**…**` label, case-insensitive. Then it
adds `major/awaiting-human` **first**, removes `agent/in-progress` **second** (add-before-remove,
IL-T16) and re-reads the labels to prove the end state (`agents/major-handoff.sh:1-60`).
Exit 0 = handed off; **3** = refused, nothing written (dispatch the reviewer again, never relabel);
**4** = a probe failed before any write (rule #6); **5** = writes issued, end state not proven (a
human looks).

**World:** [`approved`, `recorded-738`](worlds/README.md#family-worlds-fixture-local-worldsname-named-in-rowspsv).

#### Does the handoff write the label?

| description | world | patch | env | expect? |
|---|---|---|---|---|
| handoff | approved | — | — | handoff |
| merge-commit-not-content | approved | merge-commit-after-review | — | handoff |
| merge-remote-not-content | approved | merge-remote-after-review | — | handoff |
| merge-pr-not-content | approved | merge-pr-after-review | — | handoff |
| bot-suffix-normalized | approved | bot-suffix | — | handoff |
| suffixed-headings | approved | suffixed-headings | — | handoff |
| approved-without-headings | approved | strip-headings | — | refused-headings |
| approval-stale | approved | commit-after-review | — | refused-stale |
| not-major-lane | approved | label-not-major | — | refused-not-major |
| no-approval | recorded-738 | — | — | refused-no-approval |
| reviews-unreadable | approved | — | `STUB_GH_pr_view_738=fail` | unreadable |
| end-state-not-proven | approved | verify-still-in-progress | — | not-proven |

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

**World:** `approved`.

#### Does a chart major arm or park?

| description | world | patch | expect? |
|---|---|---|---|
| packaging-only-arms | approved | packaging-unchanged | armed |
| app-moves-parks | approved | app-moves | handoff |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-HANDOFF-ARM.md"

</details>
