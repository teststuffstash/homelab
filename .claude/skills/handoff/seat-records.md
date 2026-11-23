# Seat records — a second jail's one-time wind-down handoff to the primary seat

A [second jail](../second-jail/SKILL.md) writes no shared record (rule 2). What it would have
written goes to the primary **once, at wind-down**, as one file of typed records. Then the
second jail exits. Nothing comes back to it: the file is one-way and has no `## Result`, and the
primary never asks the second jail a question. The type names the destination record and the
fields that record needs, so the primary files it without reconstructing the session.

**Where:** `/workspace/.handoff/seat/<YYYYmmdd-HHMM>-<session-slug>.md`. Mono jails see this
directory and no stack jail mounts it. The writer runs `mkdir -p` on it. A session writes one
file.

```markdown
# <session title>
from: homelab (second jail)
branches: fix/<slug> (PR #NNNN), …      # what was pushed; the clone is already removed
abandoned: <what was dropped, one line each>

## log
<condition → command, with PRs and commits>

## fu-new: <title>
- symptom: …
- why deferred: …
- next action: …
- prior art: grepped `<keywords>` — no FU/ADR matches

## act: merge #NNNN
- why the primary: …
```

## The types (a closed list; a record that fits none goes into the `log` prose)

| Section | Lands in | Fields | The primary's check before filing |
|---|---|---|---|
| `## log` (exactly one) | `agents/coordinator/TICK-LOG.md` | condition → command, with PRs and commits | None. History, pasted as written (trimmed if long) |
| `## fu-new: <title>` | `docs/follow-ups.md` (a new id) | symptom, why deferred, next action, prior art (the grep keywords and its negative) | Re-run the grep. Fold the record into a matching item, do the work itself if it takes 5 minutes or less, or mint an id |
| `## fu-update: FU-NNN` | that item, or the archive | change (new status, evidence, next action); `resolves: yes` archives it | Verify the evidence against the live thing |
| `## pickup: <title>` | `docs/agents/meta-state.md` | next step (one concrete step), owner | Drop it if the step is already done |
| `## gap: <skill>` | `.claude/skills/GAPS.md` | resight `<id>` or new; date; what the skill lacked, what was improvised | A resight extends the entry; two dates promote it (ADR-105) |
| `## memory: <slug>` | the auto-memory directory | kind (user/feedback/project/reference); fact; why + how to apply (feedback/project); the operator's words, quoted, for a ruling | Update an existing memory rather than add a twin |
| `## act: <verb> <ref>` | nothing: an act reserved for the primary (merge, codeowner read, `/seat-review`, direct-to-master push) | the ref; why the second jail may not do it | The gates that act needs, as for any other request |

Not types, because the second jail writes these itself: GitHub issues and PRs (the PR lane), a
doc or ADR change inside its PR, and a stack's `done/` notice (the outbound shape in
[`/workspace/tools/handoff.md`](../../../../tools/handoff.md)).

## Filing (the primary)

Oldest file first. Run each record's check, file it, and put every record from the file into
one bookkeeping commit whose message names the file. A record the check drops is named in the
`log` entry with the reason. Then delete the file: the records are the durable home. A
second jail that takes over as primary files its own handoff first.
