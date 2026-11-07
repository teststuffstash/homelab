# Glossary — the intake island's language

One definition per term; pages reference terms instead of repeating them. Platform terms keep
their homelab definitions in [`docs/glossary.md`](../../../../docs/glossary.md) — **island
intake**, **deep dig**, **triage label**, **declared window**, **window claim**,
**remediation-would scoreboard**, **specs reviewer** are defined there and used here unchanged.
This file defines only what the island narrows or names for its contract.

## input

One thing a sitting rules: an open issue (`kind: member` — the island table claims it — or
`kind: attribution`, the agent-loop sitting's bot-filed unclaimed issue) or a `text:` block with
a `source:` line (`FU-NNN`, `meta-state`, `handoff`, `operator`, `dig`). A `dig` input's id is the
finding's bucket key without `.json` (`dig-2026-10-25/dig-r1-…/finding-1`).

## ruling

The one outcome a sitting gives an input, and the writes that carry it
([INTAKE-ADMIT-OUTCOME](intake-ruling.md#intake-admit-outcome)). Its marker is a comment whose
first line starts `intake:`; a ruled issue is never a candidate again
([INTAKE-SELECT-CANDIDATE](intake-select.md#intake-select-candidate)).

## loop-readable state

What an input is left in, read by a machine that already exists — never a new grammar:

| state | what carries it | who reads it |
|---|---|---|
| queued | `agent-fix` + `task/fix\|build` + `agent/queued`, a queue-ready body | the scan's dispatch predicate; launch rides it |
| Goal tree | a `task/goal` issue + 2–5 bound children, the children `agent/queued`, the Goal not | the scan (children); the operator (breaker #1 on the Goal) |
| closed with evidence | `intake: close — <evidence>` / `intake: fold → #n`, the issue closed | nobody — closed is final |
| standing | `intake: standing — <why not now>`, no label | the selector (skips it) |
| blocked on a human | `agent-fix` + `agent/blocked` + `intake: seat — <fact>` + a `blocked-on: human` line | the scan's suppression (`agents/coordinator/README.md` §Blocked-on marker), the board's SOLVE line, the operator |

## key rows

The decision-table rows a queue-ready body carries under `## Spec changes` (an island with
`specs/`) or `## Key rows` (one without): the happy path and the failure modes worth a
conversation (rule 2). On the agent loop the worker turns each key row into one replay fixture
dir ([UC-1](use-cases/uc-1-key-rows-to-fixtures.md)).

## receipt

`island-intake-receipt/v1` — the wired run's record of which inputs it ruled, written by the
shell from the session's `INTAKE-RULED:` lines ([INTAKE-RUN-RECEIPT](intake-receipt.md#intake-run-receipt)).
An APPLY receipt is the dig source's ruled-key; a dry-run receipt rules nothing.

## digest

`deep-dig-digest/v1` — the dig's deterministic selection: candidates, the explained set with
reasons, groups, deferred groups, window history ([dig-digest](dig-digest.md)).

## finding

Two records, never confused: a **dig finding** (`dig-finding/v1`, one per digest group,
[dig-finding](dig-finding.md)) and a **responder finding** (`responder-finding/v1`, one per
triage session, [INTAKE-RESP-FINDING](responder-verdict.md#intake-resp-finding)). The dig's pod
reads its own back (reader key); the responder's cannot (write-only key).

## subject

The failing object an alert is about — `node:<n>`, `workload:<ns>/<name>`, `instance:<ip:port>`,
`repo:<r>`, or the per-class `alert:<name>` — computed by the responder's cascade and reused by
the dig ([INTAKE-RESP-SUBJECT](responder-gates.md#intake-resp-subject)). Never the exporter that
reported it.

## group key

`<onset bucket>|<host>` — the alerts that started in the same `DIG_ONSET_BUCKET_MIN` window on the
same host are one story; `recurring|<host>` for a quiet recurring candidate, `solo:<fp>` for an
alert with no parseable `startsAt` ([INTAKE-DIG-GROUP](dig-digest.md#intake-dig-group)).

## fix verdict

The responder session's diagnosis on the issue it filed — `fix-verdict: fix` (a change in a repo
durably fixes it) or `fix-verdict: report-only` — read back by the shell through the parser.
A diagnosis, never a dispatch: `fix` earns the inert `agent-fix` label and a `/fix-verdict` ring;
queueing is fix-debounce's ([INTAKE-RESP-FIX-VERDICT](responder-verdict.md#intake-resp-fix-verdict)).

## decided

An alert whose subject already has an OPEN issue with this alert's name in the title and a
`fix-verdict:` line — or one a person closed within `RESPONDER_HUMAN_CLOSE_DAYS` — is decided: a
re-fire spawns no session ([INTAKE-RESP-DECIDED-ONCE](responder-gates.md#intake-resp-decided-once)).
