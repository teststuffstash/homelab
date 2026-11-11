# Glossary — the review island's ubiquitous language

One definition per term. Platform-wide terms keep their homelab definitions in
[`docs/glossary.md`](../../../../docs/glossary.md): **lens**, **specs reviewer**, **context pack**,
stack, AgentStack claim, container. The gateway's terms (session, rail, harness, cell, bind, env
pull, strike) are [`gateway/specs/glossary.md`](../../../../gateway/specs/glossary.md)'s. This
file defines only what the review island coins or narrows.

## content commit

The newest **non-merge** commit of a PR: the content a review is about. A commit is a merge when
its headline starts with one of GitHub's default merge messages (`Merge branch `,
`Merge remote-tracking branch `, `Merge pull request `), because `gh pr view --json commits` exposes
no `parents[]`. An update-branch merge is not new content, so it never moves the content commit.
The code reviewer's exit contract, its standing-aside marker, `review-reflex.sh` and the specs
tick's `JQ_PRELUDE` all use this one definition.

## live verdict

A review by a given identity whose state is `APPROVED` or `CHANGES_REQUESTED` and which was
submitted at or after the [content commit](#content-commit). A `DISMISSED` review is an ended round,
never a verdict. A `COMMENTED` review (GitHub wraps every lone inline comment in one) is never a
verdict.

## terminal

A record that a code-review session leaves on the PR at the content commit, which proves the
session ended on purpose. The [exit contract](verdict.md#review-verdict-terminal) accepts exactly
these:

| terminal | the record | exit |
|---|---|---|
| live-verdict | a [live verdict](#live-verdict) by `homelab-reviewer` | 0 |
| silent-dedup | this session's `SILENT_DEDUP_ASIDE:` record file (an existing aside was reused) | 0 |
| standing-aside | a `homelab-reviewer` comment carrying `<!-- standing-aside head=<content sha8>` | 0 |
| agent-error | the `agent/error` label | 0 |
| (none) | none of the above | the model's rc, or 10 |

## standing aside

The code reviewer's no-verdict terminal for a **precondition**: a state that was true when the
review was queued, stopped being true before it executed, and will settle without a human (merge
state, pending checks, an own verdict already at head, an unreadable issue, an unattributable red
on an un-armed major). It is one comment whose first line carries a machine marker keyed by
(content commit, precondition). The marker is never keyed by pass and never keyed by branch tip.
Its opposite is an **anomaly**: a state that a later dispatch would not change. An anomaly trips
`agent/error` and gets one `AGENT_ERROR:` comment.

## mechanical approval

The specs reviewer's approval that runs no model: a fixed-body `APPROVE` on a PR whose files carry
no specs path and no rule-test path, or whose `touched-rules` finds no rule. It exists because
GitHub counts required approvals repo-wide and a `pull_request` rule cannot be path-scoped
([ADR-155](../../../../docs/adr.md#adr-155--the-specs-reviewer-is-a-second-app-identity-and-the-island-repo-requires-two-approvals-2026-10-16)).

## partial read

A specs-review pass whose model writes `Verdict: PARTIAL READ — <unfinished>`: it did not read the
touched contract in full within its budget. It is no verdict, no error and no round. One
`PARTIAL READ:` comment holds the content commit until a push moves it.

## spec root pair

`{root, tests}`: the repo-relative directory of a repo's spec pages and the directory of the
tests that prove them. The claim's `repos[].specs` carries one pair per repo today, and the
specs tick's per-repo table is the fallback ([REVIEW-SPECS-ROOTS](specs-gate.md#review-specs-roots)).

## doorbell

An event that says "something changed" and carries no work item. `/specs-review` and `/sentinel`
are doorbells: the woken run re-lists every open head itself, and a level cron is the backstop
for a missed ring. The term is the platform's (the `/coordinate` doctrine); this island uses it
unchanged.

## lens posture

A lens's weight in the verdict, either `advisory` (findings are `LENS(<lens>):` follow-ups, and
they never change the verdict) or `blocking` (findings MAY decide it). The claim's `lenses` map
sets the posture per stack. `migration` and `gate-change` are blocking by construction, and no
claim can lower them ([REVIEW-LENS-POSTURE](lenses.md#review-lens-posture)).
