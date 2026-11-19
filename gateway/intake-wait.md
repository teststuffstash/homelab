# The wait read — classify a wait intake wrote against the rules that produced it

> The mirror of [the escape read](intake-escape.md): escape reads what island intake let through
> too early, this page reads what it held back on a human. Run per `wait:` input by a sitting
> that already holds the rules home ([island intake](intake.md)) and the island's facts file. A
> wait is a claim about one fact (ADR-163); this read asks whether the rules made that claim
> necessary. Evidence and open questions: [`docs/spikes/island-intake.md`](../docs/spikes/island-intake.md).

A `wait:` input is `<owner/repo>#<n>` (an issue) or `<owner/repo>#<n> pr=<pr>` (a `pr-hold`):
an item whose `intake:` ruling, or a ride's comment, parked it `blocked-on: human` — still
parked, or released since. For EACH such wait: was the fact it waited on really a human's, and
if not, which line of the rules home caused the wait, or which line was missing? Read-only: your
only product is records in the report and, when a rule line repeats, one `file`. REST reads via
`gh`, each object once, no polling.

## Reads
1. The item: body, every comment (`gh api repos/<owner/repo>/issues/<n>` + `/comments`); for a
   `pr-hold`, the PR's body and comments too. Find the comment that parked it (`blocked-on: human`)
   and what came after: a later `intake:` ruling with another outcome, a human comment, a label
   change (`…/issues/<n>/events`, only when the comments do not show it), each with its timestamp.
   Name who wrote the parking comment: an intake sitting, a ride, a human.
2. Every spec line, facts line or recorded ruling the wait cites, read at the commit that stood
   when the wait was written (`git show <sha>:<path>` — the last commit on the default branch
   before the parking comment). For a released wait, also the same lines at the release.
3. The rules home as it stood at that commit: the intake brief and the island's facts file,
   only the lines that produced the outcome (§Outcomes `seat`, procedure step 3, §Island facts'
   operator-only lines) and the lines that could have decided it instead.
4. A live read only when the wait names a live fact (an endpoint, an alert, a merged PR) and you
   need it to show the fact was decidable — and only from the brief's read set. Show the read.

## Classify each wait as exactly one of
- **H human** — the fact was the operator's: a credential or a mint, a maintenance window, money
  above the Goal ceiling, a new credential or egress, a ruling the facts file reserves, a Goal
  only a human may admit. Name the facts or rules line that reserves it. A correct wait.
- **R decidable, in read set** — the deciding fact was readable from the rules home's read set
  when the wait was written, and the rules either sent it to `seat` anyway or had no line that
  let the sitting decide. Name the fact and where it was, and the rule line that caused the wait
  or the place a missing line belongs.
- **O decidable, outside read set** — decidable then, but only from a read the rules home forbids
  or does not list. Name the read.
- **U not judgeable yet** — still parked, nothing released it, and you cannot show it was
  decidable. Say what would settle it.

Be strict: R and O need a quoted source that existed when the wait was written. A release by a
human comment is evidence about the fact, not proof of the class: an operator answering a fork
the rules left open is H; an operator answering "why does this need me?" with a fact already on
the page is R. A wait written by a ride or a reviewer, not by intake, is classified the same way
and its record says so; its rule line is in the writer's brief, which this read names but does not
propose edits to.

## The record — one per wait, under the report's `## Wait records`
```
### wait #<n> (issue | pr-hold #<pr>)  island: <island>
parked: <date> by <intake | ride | human> · released: <date> by <re-read: <outcome> | human comment | label> | still parked
days parked: <d>
asked: "<the parking line, ≤ 25 words>"
legwork on the page: options <yes|no> · facts verified <yes|no> · lean <yes|no>
class: H | R | O | U
fact: <the deciding fact — where it was (path:line@sha, issue, read); quote ≤ 20 words>
rule: <file>@<sha>:<lines> "<the line's first eight words>" caused | missing   (one line per rule line)
direction: narrow-stall | add-decision | add-read | fix-spec-prose | none
widens: yes | no
Doubts: <what you could not settle, and why>
```
`rule:` lines are the key: two records whose `rule:` lines name the same file and the same first
eight words are one rule line sighted twice, whatever the line numbers. An H record names the
reserving line with `caused` — it confirms a line, never proposes an edit. `widens: yes` = the
edit the record points at would let intake decide without the operator something it now sends to
`seat`.

## When a rule line repeats
One sighting changes nothing. A rule line named by R or O records on **two or more distinct
items** (this sitting's, or `wait-prior:` records from earlier receipts — read, never
re-classified) gets ONE proposed edit, written under `## Wait proposals` and `file`d as one issue
against the file that would carry it: `Touches` = that file, `Origin` = the items, both records
quoted, the diff in the body. Filed, not ruled here (the sitting of the island that owns that file
rules it). The edit:
- replaces or narrows the text the records name where it can; it adds a line only where the
  records name a missing one;
- carries rules only — no issue number, no model id, no vendor name, no date; history stays in the
  records and the issue;
- states its replay: the recorded wait cases whose expected ruling it changes, and those it must
  not (`replay: no cases` while none are recorded);
- is titled `widens:` first when any record behind it says `widens: yes` — that class is read
  individually, never batched with the rest.
A rule line already filed whose file has not changed since writes nothing — the open issue is the
record.
