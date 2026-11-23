# Island intake for a stack repo — the contract

This page is for a stack that wants island intake on one of its repos. It says what you provide,
what the platform provides, what a sitting writes to your issues, and what it never does.

Three terms, used throughout:

- **Island intake** is a daily session (a *sitting*) that reads the open issues nobody has decided
  and leaves each one in exactly one state the agent loop understands: queued for a worker, parked
  on a named fact, closed with evidence, or left standing
  ([`docs/glossary.md`](../../docs/glossary.md) "island intake").
- A **stack island** is a repo whose AgentStack claim declares a facts file for intake. Its name
  is `<stack>/<repo>`: the claim's `metadata.name` and the repo's `name`
  ([`scripts/intake-select.sh`](scripts/intake-select.sh), header §STACK ISLANDS).
- The **facts file** is one markdown file in your repo that tells the sitting what is true of your
  repo and nobody else's. The rules are the platform's and are the same for every island:
  [`rules/intake.md`](rules/intake.md).

Everything here is built and tested by the harness
([`tests/island-intake-test.sh`](tests/island-intake-test.sh)). No stack has turned it on yet, so
nothing on this page has been observed running against a stack repo.

## To turn it on

1. **The `homelab-intake` GitHub App is installed on the repo** — island intake's own App, used
   by nothing else ([`docs/github-apps.yaml`](../../docs/github-apps.yaml)). The sitting reads and
   writes with its token, minted from that App
   ([`agents/coordinator/intake-git.yaml`](../../agents/coordinator/intake-git.yaml)); its writes
   show as `homelab-intake[bot]`. You provide no token and no secret.
2. **The repo is in that token's `repositories` list** (the same file). This is a homelab change:
   ask for it through the platform-request lane
   ([`docs/agents/platform-and-stacks.md`](../../docs/agents/platform-and-stacks.md) §Cross-stack
   demand & escalation). It lands only after the install: a token request naming a repo the App is
   not installed on fails for every repo in the list.
   **A private source repo** your facts file reads that is not the island's repo (your deployment
   repo) is read with a separate read-only token: the row says
   `GH_TOKEN="$INTAKE_READ_GH_TOKEN" gh api repos/<org>/<repo>/…` (or clones with it). That token
   is minted with `contents: read` only
   ([`agents/coordinator/intake-read-git.yaml`](../../agents/coordinator/intake-read-git.yaml)), so
   the sitting cannot write there, whatever the App's grant. To enable it: the operator installs
   `homelab-intake` on that repo, then the repo is added to that file's `repositories` — in that
   order. Until then the row is `seat-only`.
3. **A facts file on the repo's default branch**, with the parts §What you provide lists. Check it
   from any homelab checkout before you declare it:

   ```bash
   bash islands/intake/scripts/facts-check.sh <your clone>/<facts path>
   ```

   No output and exit 0 means it can carry a sitting; otherwise each line names one missing part
   ([`scripts/facts-check.sh`](scripts/facts-check.sh)).
4. **One line in your AgentStack claim**, on the repo's entry:

   ```yaml
   spec:
     repos:
       - name: <repo>
         intake:
           facts: <path of the facts file in that repo>
   ```

   The field is `repos[].intake.facts`
   ([`argocd/resources/agentstack/xrd.yaml`](../../argocd/resources/agentstack/xrd.yaml)): a
   repo-relative path with no leading slash and no dot-led segment. Removing the line turns intake
   off. The platform reads the live claims, so this step needs no homelab commit
   ([`scripts/claims-read.sh`](scripts/claims-read.sh)).
5. **A dry run by hand**, once the claim has synced:

   ```bash
   argo -n agent-coordinator submit --from cronworkflow/island-intake -p island=<stack>/<repo> -p mode=dry-run
   ```

   A dry run writes nothing to GitHub; its log carries every body, label and comment the sitting
   would write ([`rules/intake.md`](rules/intake.md) §Inputs, `mode`). The command needs the right
   to submit workflows in the `agent-coordinator` namespace; if your credentials lack it, ask the
   platform seat to run it. Leave `-p mode=dry-run` off for one real sitting now, or wait for the
   schedule.

## What you provide

| Item | Where it lives | Required |
|---|---|---|
| The App installation | GitHub, on your repo | yes |
| The repo's name in the token's list | [`agents/coordinator/intake-git.yaml`](../../agents/coordinator/intake-git.yaml) `repositories` — a homelab change you ask for | yes |
| A source repo's install and its name in the read-only token's list | GitHub, on that repo; [`agents/coordinator/intake-read-git.yaml`](../../agents/coordinator/intake-read-git.yaml) `repositories` — a homelab change you ask for | only if your facts file reads one |
| The claim line | your claim, `repos[].intake.facts` | yes |
| The facts file | your repo, at the path the claim names | yes |

The facts file stays in your repo and is yours to maintain
([ADR-160](../../docs/adr.md)). The sitting reads it in full after the rules
([`rules/intake.md`](rules/intake.md) §Island facts). Its parts:

| Part | Required | What it must say | Read by |
|---|---|---|---|
| `Body shape: spec` or `Body shape: edit` | yes — exactly one such line | the default shape of an issue body the sitting writes for a worker: `spec` carries a `## Spec changes` table of requirement rows, `edit` carries exact replacements and check commands | [`scripts/facts-check.sh`](scripts/facts-check.sh); [`rules/intake.md`](rules/intake.md) §A queue-ready body |
| `## Sources` | yes — a table headed `\| question \| read \| note \|` with at least one row whose question and read are filled | the read set: which read answers which kind of question for your repo, each a command the sitting can run as written. A note of `seat-only` marks a read the sitting's identity cannot make | the same check; [`rules/intake.md`](rules/intake.md) §What you read |
| `## What a ride can do` | yes — at least one non-blank line | the recipe a worker rides and what it refuses, the write tier of your paths, the gates a PR runs, what the worker's pod reaches and what it does not | the same check; [`rules/intake.md`](rules/intake.md) §What you read |
| `## Membership` | no | which open issues the sitting must leave alone, one rule per line (below) | [`scripts/intake-select.sh`](scripts/intake-select.sh) |
| `Operator-only` lines | no | your repo's instances of the closed list's entries (a)–(f): the things that always wait for the operator | [`rules/intake.md`](rules/intake.md) §The procedure, step 3 |
| Sibling sets | no | sets of members that share one contract; without them the sitting runs no parity check | [`rules/intake.md`](rules/intake.md) §The procedure, step 3 |

The shared rows of the rules' read table name the platform's own paths — a worker's ride record
is read under `s3://agent-transcripts/homelab/issue-<n>/`
([`rules/intake.md`](rules/intake.md) §What you read). A read that differs for your repo goes in
your `## Sources`.

**Membership.** A stack island's inputs are every open issue of the repo that is undecided: it
carries no `agent/*` label, is not a Goal (`task/goal`) or a `post-launch:` / `stint:` container,
and has no comment whose first line starts with `intake:`. An optional `## Membership` section
removes issues from that set, one rule per line (a leading `- ` is allowed):

```
exclude label: <label>      an issue carrying exactly that label
exclude title: <ERE>        an issue whose title matches (grep -E, case-sensitive)
```

No section means no exclusion. Other prose in the section is ignored, but any other line that
starts with `exclude` fails the selection, so a typo never widens the set silently
([`scripts/intake-select.sh`](scripts/intake-select.sh), header §STACK ISLANDS).

## What the platform provides

**The schedule.** The CronWorkflow `island-intake` runs daily at 05:00Z and holds one sitting per
island, the platform's islands first, then the stack islands by stack name then repo name, one at
a time ([`agents/coordinator/island-intake-argo.yaml`](../../agents/coordinator/island-intake-argo.yaml)).
An island with no inputs starts no session. One sitting has four hours; an island the run does
not reach is read by the next run. One island's failure does not stop the others.

**The inputs.** The selector ([`scripts/intake-select.sh`](scripts/intake-select.sh)) picks them;
the model never picks its own.

| Source | What it is | Stack island |
|---|---|---|
| pile | the undecided open issues (§Membership above) | yes |
| re-reads | issues an earlier sitting parked (`agent/blocked`, or a latest `intake: seat`), re-tested once the wait is 3 days old and then at most every 7 days — sooner when an issue or PR the wait names has closed or merged since the last re-read | yes |
| escapes | PRs of issues this island's intake queued that drew a changes-requested review | yes |
| dig findings, responder classes | the platform's deep dig and alert responder | no |
| gap rows | `⚑ gap` / `🚧 WIP` rows of an island's spec index | no |
| waits | parking comments, classified against the rule that produced them | no |

**The outcomes.** Exactly one per input: `queue`, `goal`, `seat`, `fold`, `close`, `requeue`,
`standing`, `split`, `file`, `forward` ([`rules/intake.md`](rules/intake.md) §Outcomes). The
labels it uses are `agent-fix`, `task/fix` or `task/build`, `agent/queued` and `agent/blocked`.

**The closed list.** A sitting parks an item on the operator only for one of six entries: access
or money, an attended or irreversible act, direction, another owner's gate, a pending ruling, an
issue that is not its to close. With no entry it decides, and production feedback corrects a wrong
decision ([ADR-164](../../docs/adr.md); [`rules/intake.md`](rules/intake.md) §The procedure,
step 3).

**Review and repair.** A `queue` or `goal` outcome is reviewed once before it is labelled, by
sessions that did not write it, then repaired once by the author. The review never holds the
queue: the repair ends in the labels whatever the findings say
([`rules/intake.md`](rules/intake.md) §Review and repair). The lens that reads a stack island's
bodies is the unit lens ([`rules/intake-review-unit.md`](rules/intake-review-unit.md)); a run
starts at most 3 lens sessions (`INTAKE_REVIEW_LENS_MAX`, [`scripts/sitting.sh`](scripts/sitting.sh)).

**The receipt and the records.** Each sitting writes `receipt.json`, its inputs, its prompt, its
log, the lens findings and the session transcripts to the platform's transcripts bucket under
`s3://agent-transcripts/homelab/intake-<stack>-<repo>-<day>/`
([`scripts/sitting.sh`](scripts/sitting.sh), step 6). The receipt names the island, its
`island_kind` (`stack`), the `repo` and the `facts` path, and one line per decided input. It is
the ledger: an input with no receipt line is offered again the next day.

**The metrics and alerts.** Every sitting pushes the `island_intake_*` gauges with
`island="<stack>/<repo>"` ([`scripts/sitting.sh`](scripts/sitting.sh), `_push`). Two alerts
watch them ([`argocd/resources/pushgateway/prometheusrule.yaml`](../../argocd/resources/pushgateway/prometheusrule.yaml)):
`IslandIntakeStale` fires for an island that ran before and has not for two days;
`IslandIntakeClaimsUnread` fires when the claims could not be read for two days, which is when
every stack island is skipped. Both are labelled `platform_machinery`: the platform acts on them, not you.

**The identity, tools and reach.** The sitting runs as ServiceAccount `island-intake` in
`agent-coordinator`, read-only on the kube API
([`agents/coordinator/rbac.yaml`](../../agents/coordinator/rbac.yaml)), in the worker base image
plus the island's own [`devbox.json`](devbox.json). It clones your repo's default branch at depth
1 with the push URL disabled, and its sessions run in that clone
([`scripts/sitting.sh`](scripts/sitting.sh), step 0). Its live reads are GETs: Alertmanager,
Prometheus, Loki, the kube API, the ride records, the gateway's views (the same file, LIVE READS).

**Who pays.** The platform. Every session of a sitting is admitted as stack `platform`, role
`coordinator` ([`scripts/sitting.sh`](scripts/sitting.sh), `_admit`;
[`argocd/resources/agent-gateway/policy.json`](../../argocd/resources/agent-gateway/policy.json),
caller `island-intake`). Each island gets at most 2 real sittings a day (`INTAKE_DAILY_MAX`, the
manifest) and at most 3 `queue` outcomes a sitting.

**The rules' own upkeep.** A weekly digest reads the week's changes to the rule files and opens
one report PR for the operator
([`agents/coordinator/island-rules-digest-argo.yaml`](../../agents/coordinator/island-rules-digest-argo.yaml);
the set of files is derived by [`agents/island_rules.py`](../../agents/island_rules.py)). It
covers the rules and the platform's facts files. Your facts file is outside it: its history is
your repo's.

## What a sitting does to your issues

Every write goes to your repo, under the intake App's token (author `homelab-intake[bot]`).

| Write | When |
|---|---|
| Labels | `queue`: `agent-fix` + `task/fix` or `task/build` + `agent/queued`. `seat`: `agent-fix` + `agent/blocked` (no label when the body itself keeps the item out of the loop). `requeue`: `agent/blocked` removed, `agent/queued` added |
| One `intake: <outcome> — <reason>` comment | every outcome that writes; a `seat` adds `blocked-on: human` (or `blocked-on: issue=<n>` / `pr=<n>`) on its own line |
| One `intake: review — …` comment | before the outcome comment of a reviewed `queue` or `goal` |
| A body rewrite | `queue`: the issue's body is rewritten to the facts file's body shape |
| A close | `close`, `fold` (the duplicates) and `split` (the input, once its parts are filed) — only where the whose-issue limit quoted below allows it |
| A new issue | `file`, `split`, a Goal and its 2–5 children, a parity gap |
| Sub-issue and `blockedBy` edges, one branch ref | a Goal: its children are bound and ordered, and its `goal/<n>-<slug>` branch is cut |
| A title edit | `forward`: the title only |

The limits, quoted from [`rules/intake.md`](rules/intake.md):

> **No code, no PRs, no edits to the island's files.** Your writes are issues, labels, comments,
> sub-issue and `blockedBy` edges, one branch ref per Goal.

— §Hard limits.

> An issue under the OPERATOR's login may too, weighted by age: the older and staler it is (the
> claim moved, the work merged, the done-when happened), the freer your hand — close it or rewrite
> it on the evidence; a recent one gets light editing only (the machine block, the key rows, a
> narrowed `Touches`) — its intent stays as written

— §Hard limits ([ADR-163](../../docs/adr.md)).

> Any other human's issue is never closed, folded or rewritten: `seat` (entry (f)).

— §Hard limits.

> an item carrying any `agent/*` label or an earlier outcome is not yours this sitting

— §Hard limits (the exception is a re-read, which tests exactly that wait).

> **One comment per outcome**

— §Hard limits.

> **No credential, ever, in a body or comment** — the repo is public.

— §Hard limits.

> **`agent/queued` on the children only. Never on the Goal.**

— §A bot-authored Goal.

> Cap: **at most 3 `queue` outcomes (`requeue` included) per sitting; one Goal's children count as
> one.**

— §The procedure.

These limits are rules the sessions follow, not a narrower credential. The credential is narrow in
its own right: the token's permissions are the ones
[`agents/coordinator/intake-git.yaml`](../../agents/coordinator/intake-git.yaml) lists — it writes
issues and creates branches; it reviews, merges, re-runs and administers nothing
([`specs/access.md`](specs/access.md)).

## What a sitting will not do

- **No dig source.** The platform's deep dig diagnoses the platform's alerts. A stack's alerts
  reach its repo as issues, and those issues are the sitting's inputs. `--source dig` selects
  nothing for a stack island and says so ([`scripts/intake-select.sh`](scripts/intake-select.sh),
  `stack_none`).
- **No wait read.** The classification of parking comments against the rules, and the ledger
  behind it ([`scripts/intake-wait-ledger.py`](scripts/intake-wait-ledger.py)), do not run for a
  stack island (the same function). The re-reads above still do.
- **No gap rows and no rows lens.** The selector declares a specs root for the platform's islands
  only (`island_specs_root`). A stack island therefore gets no gap rows, and the second review
  lens ([`rules/intake-review-rows.md`](rules/intake-review-rows.md)) is recorded as skipped for
  it, whatever its `Body shape:` says: the lens needs a specs root whose `README.md` pins the spec
  process ([`scripts/sitting.sh`](scripts/sitting.sh), `_snippets_process`). A `spec` body on a
  stack island is reviewed by the unit lens alone.
- **No wake-up for your loop.** After queueing on a platform island the sitting rings the
  platform's `/coordinate` once. For a stack island it does not: your own loop's scan finds the
  queued issues on its schedule ([`scripts/sitting.sh`](scripts/sitting.sh), step 7).
- **No second rules file.** A stack island is decided by [`rules/intake.md`](rules/intake.md) and
  its facts file, nothing else.

## Experiments

An experiment is the check a ruling carries against its own reason: a Prometheus query, a threshold
and a window, written before the result and decided from the series afterwards. It is not a rollout
gate; nothing waits for it and nothing is rolled back by it.

- **The section and who writes it.** An issue carries one `## Experiment` section (a prose line and
  one fenced `experiment` block) or the one line `Experiment: none — <why no series can show it>`.
  The sitting writes it with the ruling, from numbers it read; the worker never edits it
  ([`rules/intake.md`](rules/intake.md) §Experiment). The block's format and its loader are
  [`scripts/experiment.py`](scripts/experiment.py) (`load`).
- **Which issues are read.** The sitting puts the label `experiment/open` on an issue that carries a
  block, and [`scripts/experiment-read.sh`](scripts/experiment-read.sh) reads the closed issues that
  carry it. It runs as the scheduled workflow's first step, before the sittings, and decides
  nothing if it cannot reach Prometheus or GitHub.
- **The window.** It starts at t0, the merge instant of the pull request that closed the issue. An issue
  no merged PR closes, with a `task/goal` ancestor, merged into a `goal/**` branch (GitHub records no
  closing reference there): its t0 is when that branch reaches the default branch — the merged PR that
  carried it, then each merge of its base onward (a Goal assembly, a themed Goal's theme branch), each
  after the one below. It is `pending` until then, and counts overdue 14 days after the child merged. The window
  ends at the bound, `max_window` after t0 (at most `7d`); a later deploy or restart neither ends nor
  resets it ([`scripts/experiment.py`](scripts/experiment.py), header, `decide`).
- **The four verdicts.** `pass`, `fail`, `pending` (short of samples before the bound) and `no data`
  (short of samples at the bound, or a query that answers nothing — final, never a pass), each a
  function of t0 and the series only ([`scripts/experiment.py`](scripts/experiment.py)).
- **What each writes to an issue** ([`scripts/experiment-read.sh`](scripts/experiment-read.sh),
  header): `pass` and `no data` write one verdict comment and remove `experiment/open`, and change
  no other state; `pending` writes nothing; a decided experiment is never judged twice (the comment
  carries a marker). Two open experiments over overlapping windows on one metric name are named in
  each other's comment; no attribution is attempted.
- **A failed experiment goes back to intake.** `fail` writes the comment, removes the `agent/*`
  labels and reopens the issue, which is then an undecided input for the next sitting, with the
  verdict as a fact ([`rules/intake.md`](rules/intake.md) §Experiment). Under a Goal the child is
  not reopened: the comment is also posted on the Goal's open `post-launch:` sub-issue, else on the
  Goal. Nothing is rolled back.
- **Retention is a limit.** Prometheus holds about 17 days, so a baseline is recorded as a number
  when the ruling is written and never re-read ([`rules/intake.md`](rules/intake.md) §Experiment,
  "Baseline"), and a decided verdict is not derived again.

The platform's read covers the platform repo's issues only; it is not run over a stack repo.

## What stays yours

- **Your own experiments' reader.** The platform's read covers the platform repo only. If your
  issues carry experiments, the reader, its release bound (ending a window when your next release
  reaches production) and its guard stage are yours. The block's format is shared; its authority is
  the oracle stack's, and the loader here refuses what that format does not have
  ([`scripts/experiment.py`](scripts/experiment.py)). See §Experiments.
- **A review sitting of your own.** The platform's review runs inside the sitting and waits for
  nothing outside it. Your own review composes through the two things a sitting respects: an
  `exclude label:` line keeps an issue out until you remove the label, and an issue carrying any
  `agent/*` label is left alone.
- **Your unit split.** How your repo divides into units, and which files a session reads for each,
  live in your repo ([ADR-160](../../docs/adr.md)). To the selector a stack island is one island:
  the whole repo minus its exclusions. The split reaches a sitting only as text in your facts
  file.
- **The facts file.** Its content, its history and its review are your repo's.

## Rulings behind this page

- [ADR-160](../../docs/adr.md) — a stack island's facts live in the stack repo.
- [ADR-163](../../docs/adr.md) — whose issue a sitting may close or rewrite, and the re-reads.
- [ADR-164](../../docs/adr.md) — the closed list.
- The review trial: [`docs/spikes/island-intake.md`](../../docs/spikes/island-intake.md) §Run 4.
- The stack-island decisions (identity, live claims, no dig source, who pays, the name):
  [homelab#3580](https://github.com/teststuffstash/homelab/issues/3580) §Decision.
- The experiment decisions (the block is the oracle stack's, the read is the platform's, no added key):
  [homelab#3586](https://github.com/teststuffstash/homelab/issues/3586), design pins 1–11.

Tracked by: FU-320 (docs/follow-ups.md).
