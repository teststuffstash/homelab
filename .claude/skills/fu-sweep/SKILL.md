---
name: fu-sweep
description: >
  Triage every OPEN follow-up and act on it — not a closing spree. Sorts each item into DO-NOW
  (it fails the 5-minute rule), SOAK-DUE (a "let it soak" whose window has long passed, so the
  question is answerable today), UNBLOCKED (it waits on an FU that has since been archived),
  OPERATOR (needs a decision only the operator can make), or STILL VALID — then DOES the do-now
  ones, VERIFIES the soaks against live evidence, and re-reads the unblocked ones as if filed
  today. Use on "sweep the
  follow-ups", "FU cleanup", "triage the tracker", "what follow-ups are still relevant", or when
  the open count / a section has grown out of control. Run BEFORE docs-cleanup, which propagates
  what this pass changes.
---

# fu-sweep — decide, then act

`docs-cleanup` runs tracker→outward: it takes ids already archived or rewritten and repairs every
doc that still describes the old status. It assumes the deciding already happened. **This skill is
that deciding**, and it is the missing half — measured 2026-08-07: creation ran **2.4 ids/day over
FU-050→100 and 4.4/day over FU-100→153**, the Agents block reached **34 of 57 open items**, and
**7 open items carried a soak/verify-later clause that nothing re-checks.**

## Hard rules

- **This is not a closing spree.** "Close the stale ones" produces a small tracker and a large
  amount of silently-dropped work. Every item leaves the pass with a REASON, and the default for
  anything you cannot evidence is **leave it open, unchanged**.
- **Evidence, not memory, decides a soak.** A soak's question is answerable only against the live
  thing: the metric, the run, the label, the pod. `git grep` for the fix is not proof it works —
  that is the "written is not applied" class this repo keeps rediscovering.
- **Do NOT re-file what you resolve.** If the sweep does the work, the item is archived with the
  fix in the same commit (the tracker's own resolve rule), not rewritten as "done, verify later".
- **Never invent an id.** Prior-art grep before proposing anything new; the sweep may only add an
  item if it is genuinely new deferred work, and the §THE BAR tests in `docs/follow-ups.md` apply
  to the sweep exactly as to anyone else.
- **The operator's list is short or it will not be read.** Cap it; if everything needs a decision,
  the sweep has not done its job.

## The pass

1. **Inventory.** `devbox run follow-ups-lint`, then per section count items and lines. Anything
   the lint flags (OVERSIZE / DANGLING / STALE / NO-BACKLINK / DONE-MARKER) is a target on sight.

2. **Classify EVERY open item into exactly one bucket.** Read the item's *next action*, not its
   headline — the headline is why it was filed, the next action is whether it is still work.

   | Bucket | Test | What the sweep does |
   |---|---|---|
   | **DO-NOW** | context is in hand, ≲5 min, safe now | **do it**, verify it, archive the item in the same commit |
   | **SOAK-DUE** | says soak/verify/"awaiting live proof" and the window has passed | answer it against live evidence → archive if proven, re-scope if not |
   | **OPERATOR** | needs a decision, a privilege, or a preference | one line on the operator list, with the options and your recommendation |
   | **UNBLOCKED** | it waits on another FU that has since been archived (or nearly done) | re-read it as if filed today: often the next action is now doable, sometimes the whole item evaporated with its blocker |
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

3. **Execute the DO-NOW bucket.** This is where the sweep earns its cost. ⚠ Each fix still needs
   its own end-state check against the live thing (`CLAUDE.md` §Safety) — a sweep is not licence to
   batch-commit unverified changes, and a broken fix is worse than an open item.

4. **Answer the SOAK-DUE bucket.** For each: what would prove it? Then go get that. Typical shapes
   here — a metric that should have moved (`router_strikes_total`), a clause that should have fired
   (grep the scan's own tick logs), a label that should have flipped (the issue timeline). If the
   evidence says the soak FAILED, that is the most valuable output of the whole pass: re-scope the
   item with what was measured, do not quietly extend it.

5. **Write the operator list.** ≤10 lines total, each: id, the decision needed, the options, your
   recommendation. If an item has sat in OPERATOR across two sweeps, say so — that is a signal the
   framing is wrong, not that the operator is slow.

6. **Verify + hand off.** `devbox run follow-ups-lint` green, the archived items' fixes each
   verified, then run **docs-cleanup** to propagate every status this pass changed into the docs
   that reference those ids.

## Scale note

A sweep that touches everything touches nothing carefully. If the open count is large, sweep ONE
section per pass and say which. Prefer the section that has grown fastest since the last sweep —
growth rate is the better signal than absolute size, because it points at where filing has become
the reflex.
