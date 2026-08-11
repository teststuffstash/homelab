---
name: fu-sweep
description: >
  Triage every OPEN follow-up and act on it — not a closing spree. FIRST reconciles the tracker
  with what the machine lane (responder flow + fixer PRs) has shipped since the last sweep —
  synced by substance, never by a PR's own FU-label — then sorts each item into DO-NOW
  (it fails the 5-minute rule), SOAK-DUE (a "let it soak" whose window has long passed, so the
  question is answerable today), UNBLOCKED (it waits on an FU since archived, or an issue the
  machine lane closed), OPERATOR (needs a decision only the operator can make), or STILL VALID —
  then DOES the do-now ones, VERIFIES the soaks against live evidence, and re-reads the
  unblocked ones as if filed today. Use on "sweep the
  follow-ups", "FU cleanup", "triage the tracker", "what follow-ups are still relevant", or when
  the open count / a section has grown out of control. Run BEFORE docs-cleanup, which propagates
  what this pass changes.
---

# fu-sweep — decide, then act

> **Glance first**: [`../GAPS.md`](../GAPS.md) §fu-sweep — unpromoted sightings apply until
> closed (contract: [`../README.md`](../README.md)).

`docs-cleanup` runs tracker→outward: it takes ids already archived or rewritten and repairs every
doc that still describes the old status. It assumes the deciding already happened. **This skill is
that deciding**, and it is the missing half — measured 2026-08-07: creation ran **2.4 ids/day over
FU-050→100 and 4.4/day over FU-100→153**, the Agents block reached **34 of 57 open items**, and
**7 open items carried a soak/verify-later clause that nothing re-checks.**

## Hard rules

- **Agents-dominated tracker ⇒ corpus preload.** When the open items are mostly agent-platform
  (the standing state: 92% for ids ≥100), run the [`design-agents`](../design-agents/SKILL.md)
  read plan first (skip if already read this session) — classifying agents items without the
  corpus under-reads, per the ruling that created that skill. If a
  [`board-sweep`](../board-sweep/SKILL.md) ran this session, its HANDLED bucket IS step 2's
  machine-lane delta — verify by substance and move on.
- **This is not a closing spree.** "Close the stale ones" produces a small tracker and a large
  amount of silently-dropped work. Every item leaves the pass with a REASON, and the default for
  anything you cannot evidence is **leave it open, unchanged**.
- **Evidence, not memory, decides a soak.** A soak's question is answerable only against the live
  thing: the metric, the run, the label, the pod. `git grep` for the fix is not proof it works —
  that is the "written is not applied" class this repo keeps rediscovering.
- **Do NOT re-file what you resolve.** If the sweep does the work, the item is archived with the
  fix in the same commit (the tracker's own resolve rule), not rewritten as "done, verify later".
- **Never invent an id.** Prior-art grep before proposing anything new (a NEW name for
  platform functionality additionally clears `docs/glossary.md`); the sweep may only add an
  item if it is genuinely new deferred work, and the §THE BAR tests in `docs/follow-ups.md` apply
  to the sweep exactly as to anyone else.
- **The operator's list is short or it will not be read.** Cap it; if everything needs a decision,
  the sweep has not done its job.

## The pass

1. **Inventory.** `devbox run follow-ups-lint`, then per section count items and lines. Anything
   the lint flags (OVERSIZE / DANGLING / STALE / NO-BACKLINK / DONE-MARKER) is a target on sight.

2. **Reconcile the MACHINE LANE first — before classifying anything.** The responder flow and the
   fixer lanes advance FU-tracked territory but never write the tracker (by design: triage
   sessions cannot push master, and fixer PRs don't edit `follow-ups.md`) — so between sweeps,
   merged machine work silently invalidates items' "Remaining" lists, and a sweep that classifies
   before reconciling triages against STALE truth. Found the hard way 2026-08-08: PR#129 (from
   responder-filed homelab#124) shipped the verdict-keyed resolve leg *calling itself* "FU-133
   leg c" while the tracker's leg (c) was a different mechanism entirely — unsynced, the next
   closure sweep would have archived unfinished work on the label alone.
   - **Gather the delta** since the last sweep (the tracker header's "Previous pass" date):
     org-wide CLOSED issues carrying the responder's markers and the fixer's labels, plus MERGED
     PRs that cite an FU id —
     ```sh
     SINCE=2026-08-07   # ← the last sweep's date, from the tracker header
     gh search issues --owner teststuffstash --match body "alert-fp:" --state closed \
       --closed ">$SINCE" --json repository,number,title -q '.[]|"\(.repository.name)#\(.number) \(.title[0:60])"'
     gh search prs --owner teststuffstash --merged --match body "FU-" \
       --updated ">$SINCE" --json repository,number,title -q '.[]|"\(.repository.name)#\(.number) \(.title[0:60])"'
     ```
     plus the reverse direction: grep open FU items for `#NNN` / `repo#NNN` issue references and
     check whether those issues have since closed (an FU gated on an issue the machine resolved
     is UNBLOCKED and nothing announced it).
   - **Sync by SUBSTANCE, never by label.** A PR or issue claiming "FU-NNN (leg X)" is a CLAIM
     about the tracker, not a fact of it — read the diff/closure against the item's actual
     remaining-work text before recording anything (the leg-c collision above is the canonical
     example; the verdict-line rule applies to machine self-attribution exactly as to verdicts).
     Record real advances in the item; archive only what is fully evidenced end-to-end.
   - Every classification in step 3 then runs on CURRENT truth.

3. **Classify EVERY open item into exactly one bucket.** Read the item's *next action*, not its
   headline — the headline is why it was filed, the next action is whether it is still work.

   | Bucket | Test | What the sweep does |
   |---|---|---|
   | **DO-NOW** | context is in hand, ≲5 min, safe now | **do it**, verify it, archive the item in the same commit |
   | **SOAK-DUE** | says soak/verify/"awaiting live proof" and the window has passed | answer it against live evidence → archive if proven, re-scope if not |
   | **OPERATOR** | needs a decision, a privilege, or a preference | one line on the operator list, with the options and your recommendation |
   | **UNBLOCKED** | it waits on another FU since archived (or nearly done), or on an issue the machine lane has since closed (step 2's reverse grep) | re-read it as if filed today: often the next action is now doable, sometimes the whole item evaporated with its blocker |
   | **STILL VALID** | real deferred work, next action clear, not yet actionable | leave untouched — say so, do not reword for the sake of it |

   ⚠ **UNBLOCKED is the bucket nobody checks, and it cannot be grepped for.** The dependency is
   written in prose and the phrasing varies — `Relates`, `Prereq:`, `Absorbs FU-057's residue`,
   `Inherited from FU-107`, `behind`, `gated on`. A blocker-word regex found **0** of them on
   2026-08-07; widening to "any open item citing an archived id" found **23 of 57**, mostly
   ordinary cross-references. So: use the query as a PRE-FILTER that narrows what you read, never
   as the answer. Reading the cited sentence is what distinguishes "relates to" from "waits on".

   ```sh
   # open items citing an id that is already archived → the read-list for this bucket
   python3 - <<'EOF'
   import re
   arch=set(re.findall(r'\*\*FU-(\d+)\*\*', open('docs/follow-ups-archive.md').read()))
   cur=None; buf=[]; items=[]
   for l in open('docs/follow-ups.md'):
       m=re.match(r'- \[ \] \*\*(FU-\d+)\*\*', l)
       if m:
           if cur: items.append((cur,'\n'.join(buf)))
           cur=m.group(1); buf=[l.rstrip()]
       elif cur is not None: buf.append(l.rstrip())
   if cur: items.append((cur,'\n'.join(buf)))
   for i,t in items:
       done=sorted({r for r in re.findall(r'FU-(\d+)', t) if r!=i.split('-')[1]} & arch)
       if done: print(i, '→ cites archived', ['FU-'+d for d in done])
   EOF
   ```

4. **Execute the DO-NOW bucket.** This is where the sweep earns its cost. ⚠ Each fix still needs
   its own end-state check against the live thing (`CLAUDE.md` §Safety) — a sweep is not licence to
   batch-commit unverified changes, and a broken fix is worse than an open item.

5. **Answer the SOAK-DUE bucket.** For each: what would prove it? Then go get that. Typical shapes
   here — a metric that should have moved (`router_strikes_total`), a clause that should have fired
   (grep the scan's own tick logs), a label that should have flipped (the issue timeline). If the
   evidence says the soak FAILED, that is the most valuable output of the whole pass: re-scope the
   item with what was measured, do not quietly extend it.

6. **LOOP — every resolution can unblock the next.** After finishing DO-NOW and SOAK-DUE, re-run
   the UNBLOCKED pre-filter against the ids you just archived and re-classify what cites them. A
   closure often turns a STILL-VALID item into a DO-NOW: its blocker is gone and the fix is now
   five minutes. Repeat until a pass produces no new DO-NOW — this is the compounding part of a
   sweep and the reason it beats closing items one at a time as they come up.
   ⚠ Bound it: stop after 3 passes or when the remaining work stops being ≲5-minute shaped, and
   say where you stopped. A chain that keeps growing is a sign you are doing a PROJECT inside a
   sweep — file it properly (ROADMAP or a scoped item) instead of following it to the bottom.

7. **Write the operator list.** ≤10 lines total, each: id, the decision needed, the options, your
   recommendation. If an item has sat in OPERATOR across two sweeps, say so — that is a signal the
   framing is wrong, not that the operator is slow.

8. **Verify + hand off.** `devbox run follow-ups-lint` green, the archived items' fixes each
   verified, then run **docs-cleanup** to propagate every status this pass changed into the docs
   that reference those ids.

## Scale note

A sweep that touches everything touches nothing carefully. If the open count is large, sweep ONE
section per pass and say which. Prefer the section that has grown fastest since the last sweep —
growth rate is the better signal than absolute size, because it points at where filing has become
the reflex.
