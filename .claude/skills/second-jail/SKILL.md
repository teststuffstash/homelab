---
name: second-jail
description: >
  OPERATOR-TYPED ONLY: "/second-jail" at the start of a session marks THIS session as a SECONDARY
  homelab mono jail running beside the primary one on the same shared /workspace/homelab — for
  background experiments that may be abandoned. Work only in a clone, write no shared records
  (FUs, meta-state, TICK-LOG, GAPS, memory), PR lane only, remove the clone when done. Never
  self-invoke; a primary seat never loads this.
---

# second-jail — you are NOT the primary seat

> **Glance first**: [`../GAPS.md`](../GAPS.md) §second-jail — unpromoted sightings apply until
> closed (contract: [`../README.md`](../README.md)).

The operator opened a second mono jail beside the primary session. Both see the same
`/workspace/homelab` — the operator's own `~/Projects/homelab` working tree. This session exists
for experiments that may never be committed. **These rules narrow the seat card
(`CLAUDE.local.md`)**: its single-writer and direct-to-master authority belongs to the primary,
not to you. Everything else in it (safety, prior-art, design routing) still applies.

1. **Work only in a clone.** Before your first write:
   ```bash
   C=<your scratchpad>/<slug>
   git clone -q /workspace/homelab "$C"
   git -C "$C" remote set-url origin "$(git -C /workspace/homelab remote get-url origin)"
   git -C "$C" fetch -q origin && git -C "$C" checkout -q -B <branch> origin/master
   cp -a /workspace/homelab/.devbox "$C"/   # warm toolchain
   ```
   A clone, never `git worktree add` (worktrees share the main repo's refs — homelab#428). Reading
   `/workspace/homelab` is fine; never write, `checkout`, `commit`, `stash` or `reset` there.
2. **Write no shared record.** Not yours: `docs/follow-ups.md` + archive (never mint an FU id —
   the counter is the primary's), `docs/agents/meta-state.md`, `agents/coordinator/TICK-LOG.md`,
   `.claude/skills/GAPS.md`, the auto-memory directory (read it, don't write it). No direct push
   to master; no merging other PRs, no codeowner reads, no `major/awaiting-human` merges. A loose
   end you find goes into your final message (and the PR body), for the primary to file.
3. **Keeping work = the PR lane.** Branch from `origin/master` in the clone, open a PR, let the
   bot review. Reference only FU ids that already exist. Abandoning is fine — no commit needed.
4. **Live infrastructure**: a mutation runs inside a
   [maintenance window](../maintenance-window/SKILL.md), and `devbox run maint -- list` comes
   first — if the primary has a window open, wait for it. A shared resource visibly in use (the
   FU-297 test VM running, a subagent's drill VM) is not yours to touch: wait or ask.
5. **Taking over.** If a shared record genuinely needs writing, do not do it while the primary
   runs. Ask the operator; once they confirm the primary jail has exited, finish or remove your
   clone work, then work in `/workspace/homelab` under the normal seat card (`git status` first —
   leave what isn't yours). From then on you are the primary; this skill no longer applies.
6. **Close out.** Before the session ends: push anything you keep, then `rm -rf` the clone. The
   final message lists branches/PRs, what was abandoned, and any proposed tracker entries.
