# The escape read — classify a worker PR's review findings against the issue intake wrote

> Step E of [island intake](intake.md) §The procedure, for each `escape:` input. The sitting that
> follows it already holds the rules home; this page is the classification. Evidence and the
> frozen regression set: [`docs/spikes/island-intake.md`](../../../docs/spikes/island-intake.md) §Run 4.

Island intake wrote the issue body a loop worker then built. The PR's reviewers (code reviewer +
specs reviewer) requested changes. For EACH blocking finding in EACH review round: could it have
been prevented when the issue was written — and by what check? Read-only: your only product is
records in the report (and, through step E, a `file` when a class repeats). REST reads via `gh`,
each object once, no polling.

## Reads
1. The issue: body, every comment (`gh api repos/<owner/repo>/issues/<n>` + `/comments`). Note
   the `intake: review` comment (which findings the review raised, and the author's answers) and
   whether the body was edited after queueing (if you cannot tell, say so).
2. Its parent Goal if it has one (`…/issues/<n>/parent`): body only.
3. The PR: body, every review (`…/pulls/<pr>/reviews`), review comments, issue comments (the
   worker's replies per round). NOT the full diff — `gh pr diff <pr> --name-only`, and read a hunk
   only when a finding cannot be classified without it.
4. The spec section(s) the issue names, as they were BEFORE the PR (`git show <base-sha>:<path>`;
   the PR's base sha is in the PR JSON) — only the requirement section + index row, to judge what
   intake could have read.

## Classify each blocking finding as exactly one of
- **A prescribed** — the defect is IN the issue body (a row, pin, acceptance line, Touches) and the
  worker built it as written.
- **B omitted, in read set** — the body is silent or vague; the deciding fact was readable from the
  rules home's read set (§What you read) when the issue was written. Name the fact and where it was.
- **C omitted, outside read set** — decidable before the ride, but only from a read the rules home
  forbids or does not list (the island's `src/`, tests, another page, a schema, a world file). Name
  the read.
- **D worker** — an implementation / test / evidence defect; the body was right or rightly silent.
- **E process** — a reviewer error or contradiction, a missing reviewer input, a CI/gate/infra
  cause, a finding a LATER round raised that the same reviewer could have raised in round 1 (say
  so: `late`).
For a Goal child also flag **X cross-child** when the finding is a parent↔child or child↔child
inconsistency.

Be strict: A/B/C need a quoted source that existed at filing time; "a better author would have
thought of it" is not evidence — that is D.

## The record — one per finding, under the report's `## Escape records`
```
### PR #<pr> ← issue #<n>  (Goal #<g> | standalone)
rounds: <k> CHANGES_REQUESTED (code: a, specs: b); merged | open
body edited after queueing: yes / no / unknown
| round | reviewer | finding (one line, rule id if cited) | class | evidence (quote ≤ 20 words from body / spec / review) | review: raised as <id> (changed / declined / advisory) / not raised | the intake check that would have caught it (one line; "none" for D/E) |
Tally  A= B= C= D= E= (X=)
Doubts: findings you could not classify with confidence, and why
```
The class step E counts is the letter plus that last column: two records naming the same check
are one class sighted twice.
