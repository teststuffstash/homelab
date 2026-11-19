# The wait read — classify a wait against the rules that produced it

> Step W of [island intake](intake.md) §The procedure, for each `wait:` input — the mirror of
> [the escape read](intake-escape.md): escape reads what island intake let through too early, this
> page reads what it held back on a human. The sitting that runs it already holds the rules home and
> the island's facts file. A wait is a claim about one fact (ADR-163); this read asks whether the
> rules made that claim necessary. Evidence and open questions:
> [`docs/spikes/island-intake.md`](../docs/spikes/island-intake.md).

A `wait:` input is ONE parking comment — a comment whose `blocked-on:` marker is `human`, or an
`intake: seat` with no marker — on one item of the island, selected by `intake-select.sh --source
wait`. An item that waited several times arrives as several inputs, one record each. The row says
who wrote it (`writer`: `intake` — an `intake:` comment, whoever's login; `lane` — a bot that is not
intake, such as a ride's stop; `human`), when (`parked_at`), and, for a released wait, what released
it (`release`: `operator` — any comment, label change or close under a non-bot login, the operator's
login being the operator; `reread` — the intake bot's own later ruling; `lane` — another bot) and
when (`released_at`). A standing wait carries how many re-reads left it `unchanged`.

For EACH input: was the fact it waited on really a human's — and if not, which line of the rules
home caused the wait, or where a missing line belongs? Read-only: your product is records in the
report and, for a rule line at the bar, one proposal record. REST reads via `gh`, each object once,
no polling.

## Reads
1. The item: body, every comment (`gh api repos/<owner/repo>/issues/<n>` + `/comments`), the events
   only when the comments do not show the release. Find the parking comment by its timestamp and
   what came after it.
2. Every spec line, facts line or recorded ruling the wait cites, at the commit that stood when the
   wait was written (`git show <sha>:<path>`, the last default-branch commit before `parked_at`);
   for a released wait, the same lines at the release.
3. The rules home at that commit: the intake brief and the island's facts file — the lines that
   produced the outcome (§Outcomes `seat`, procedure step 3, the facts file's operator-only lines)
   and the lines that could have decided it instead.
4. A live read only when the wait names a live fact (an endpoint, an alert, a merged PR), only to
   show the fact was decidable, and only from the brief's read set. Show the read.

## Classify each wait as exactly one of
- **H human** — the fact was the operator's: a credential or a mint, a maintenance window, money
  above the Goal ceiling, a new credential or egress, a ruling the facts file reserves, a Goal only
  a human may admit. Name the facts or rules line that reserves it. A correct wait.
- **R decidable, in read set** — the deciding fact was readable from the rules home's read set
  when the wait was written, and the rules either sent it to `seat` anyway or had no line that let
  the sitting decide. Name the fact and where it was, and the rule line that caused the wait or the
  place a missing line belongs.
- **O decidable, outside read set** — decidable then, but only from a read the rules home forbids
  or does not list. Name the read.
- **U not judgeable yet** — still parked, nothing released it, and you cannot show it was
  decidable. Say what would settle it.

Be strict: R and O need a quoted source that existed when the wait was written. A release is
evidence about the fact, not proof of the class: an operator answering a fork the rules left open
is H; an operator answering with a fact already on the page is R. A wait whose `writer` is not
`intake` is classified the same way and its record names its writer; its rule line is in that
writer's brief, which this read names but proposes no edit to — and it never counts toward the
island's tally.

## The record — one per input, under the report's `## Wait records`
```
### wait <owner/repo>#<n> @ <parked_at>  writer: <intake | lane | human> (<login>)
released: <released_at> by <operator | reread | lane> via <comment | label | close> | standing
asked: "<the parking line, ≤ 25 words>"
legwork on the page: options <yes|no> · facts verified <yes|no> · lean <yes|no>
class: H | R | O | U
fact: <the deciding fact — where it was (path:line@sha, issue, read); quote ≤ 20 words>
rule: <file>@<sha> caused "<the line's first eight words>"          (one line per rule line)
rule: <file>@<sha> missing after "<first eight words of the line it would follow>"
direction: narrow-stall | add-decision | add-read | fix-spec-prose | none
widens: yes | no
Doubts: <what you could not settle, and why>
```
`rule:` lines are the key. A `caused` key is the file plus the line's first eight words; a
`missing` key is the file plus the first eight words of the line the missing one would FOLLOW
(the heading, when it would open a section). Words are compared lower-cased, markdown and
punctuation stripped, so a line that moved is the same key. An H record names the reserving line
with `caused` — it confirms a line, never proposes an edit. `widens: yes` = the edit the record
points at would let intake decide without the operator something it now sends to `seat`.

After each record print its machine copy, one line, outside any code fence (the launcher parses it;
the `wait` id is the input's id verbatim):
```
INTAKE-WAIT: {"wait": "<input id>", "class": "H|R|O|U", "rules": [{"file": "<path>", "mark": "caused|missing", "words": "<eight words>"}], "direction": "<direction>", "widens": true|false, "fact": "<one line>"}
```

## When a rule line repeats
One sighting changes nothing. Earlier sittings' records reach you only through the ledger: write
this sitting's `INTAKE-WAIT` objects, one per line, to `/tmp/wait/records.jsonl`, then run
`python3 gateway/scripts/intake-wait-ledger.py --records /tmp/wait/prior.json --records
/tmp/wait/records.jsonl` — it prints every key, the distinct ITEMS behind it, and `AT-BAR` on a
key whose R or O records stand on two or more distinct items (intake-written waits only). Two
parking comments of one item are one item.

For each key at the bar, and only those, write ONE proposed edit under `## Wait proposals`: the
diff against the file the key names, and one machine line
```
INTAKE-WAIT-PROPOSAL: {"file": "<path>", "mark": "caused|missing", "words": "<the key's eight words>", "diff": "<unified diff>", "widens_authority": true|false}
```
The launcher re-runs the ledger and keeps a proposal only at the bar, with the items behind it
from the ledger. The edit:
- replaces or narrows the text the records name where it can; it adds a line only where the
  records name a missing one;
- carries rules only — no issue number, no model id, no vendor name, no date; history stays in the
  records;
- states its replay: the recorded wait cases (`agents/island-intake-fixtures/wait-cases/`) whose
  expected ruling it changes, and those it must not;
- sets `widens_authority: true` when any record behind it says `widens: yes` — that class is read
  individually, never batched with the rest.
A proposal is a record, not a write: nothing is filed, branched or pushed from this step.
