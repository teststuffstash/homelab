# Jail seat card — session procedure for the homelab seat

> The SEAT's procedure card (FU-117 third context, S4 #764) — the sibling of
> [`jail-subagent-card.md`](jail-subagent-card.md) (subagents) and
> `ground-rules.md` (pod workers — lands with PR#768). Composed into the seat's session context
> by the MONO jail's bootstrap: claude-jail cats its shared container card + THIS file into
> **`/workspace/homelab/CLAUDE.local.md`** (gitignored here; auto-loaded by Claude Code) — the
> homelab-scoped target, so the seat card loads ONLY for sessions actually seated in this repo,
> never for a mono-jail session working another stack (claude-jail#1, design 2026-08-23).
> **STACK jails deliberately get NO seat card**: their homelab token is branch+PR-only by
> identity — this card's authority (direct-to-master bookkeeping, the ADR-110 gate read, the
> tracker's single writer) is structurally not theirs, and catting it in would recreate the
> wrong-context failure this split exists to fix. A stack jail's homelab context is the
> shallow-cloned `CLAUDE.md` — pure repo facts — which is the right amount.
> The mechanism is LIVE (claude-jail, 2026-08-23): the entrypoint composes at container start,
> so the card snapshot refreshes on container restart, not per session — after editing this
> file, running mono containers serve the previous composition until restarted. A worker
> riding this repo from the fixer lane never auto-loads this file, which makes the jail/worker
> split structural instead of banner-enforced. Paths below are written relative to the REPO
> ROOT (the seat's cwd), not this file.

## Design questions run full-context

**Assessing, critiquing, or designing a subsystem is not triage** — the ground truth for design
is documented *intent*, which no live probe can recover. The `/design` skill is the procedure
(founding docs + owning-doc link closure, sediment excluded, grounding named); **if a task is
design-shaped and the skill wasn't invoked, behave as if it was** — reads are pre-authorized,
rework is the expensive thing. A design answer names the docs that ground it; "no owning doc
covers X" is a finding to report, not a license to improvise. **Agent-platform topics route to
`/design-agents`** — the full-corpus variant (reads ALL of `docs/agents/` + the `agents/`
READMEs upfront, retros excluded; grounding names only what lies outside that corpus), because
the subsystem is coupled enough that any major change needs the whole context anyway
(operator, 2026-08-10).

## Follow-ups (FU-NNN)

Loose ends and deferred work are tracked **only** in `docs/follow-ups.md`, one stable id per item
(`FU-NNN`, never reused — conventions at the top of that file). The rules that keep it consistent:

- **Prior-art grep before filing or proposing ANYTHING** — a new FU, a "next step" in a summary,
  a new doc/script/ADR: grep `docs/follow-ups.md` + `docs/follow-ups-archive.md` + `docs/adr.md`
  **by topic keywords** (`PAT|credential`, not just the id header). Assume any loose end you
  "discover" is already tracked until a grep says otherwise, and state the negative ("no FU/ADR
  matches <keywords>") before creating. If a related item exists, extend it — never file a
  parallel one. A NEW name for platform functionality additionally clears
  [`docs/glossary.md`](../docs/glossary.md) first — if the concept exists use its term, if the
  term is taken pick another, and add the row in the coining commit (FU-163). A user question like "is this a follow-up?" usually means they half-remember an
  existing item — it's a retrieval cue, not a decision handed to you: grep first, answer with ids.
- **Next steps reported to the user must carry FU ids** — a proposed next step that hasn't been
  checked against the tracker is how duplicates start.
- **≲5 minutes with the context in hand? Just do it** — an entry costs more than the fix; file
  only genuine deferrals.
- **New deferred work / discovered loose end** → add an `FU-NNN` item there first. Never leave a
  free-floating `TODO` in code or docs — write the comment as `FU-NNN: <context>` instead.
- **An item is ≤10 lines: symptom, why deferred, next concrete action, link.** When it outgrows
  that, the detail moves to a doc (routing table above) and the FU becomes a **pointer** — the
  item keeps status + next action, the doc takes mechanism/evidence/history and backlinks the id.
  Do not grow a second copy in the tracker afterwards; edit the doc.
- **Resolved something?** Move the item to `docs/follow-ups-archive.md` (trimmed to a few lines,
  `(archived YYYY-MM-DD)`) in the same commit as the fix. Archive entries expire after ≈a month:
  delete the entry + scrub only TODO-shaped refs (`FU: FU-NNN` cells, `Tracked by` lines —
  ADR-116); bare id mentions are provenance names and stay, forever.
  A pointer item's **doc survives archival** — it's documentation, not tracker residue.
  `devbox run follow-ups-lint` catches dangling references, stale archive entries, oversized
  items, and broken/un-backlinked pointers.
- Roadmap-scale parked *features* go to `ROADMAP.md` → Backlog, not here.

## Safety

- `plan`/dry-run and review before any `apply`; this hits live machines.
- **Never `talosctl upgrade` a Proxmox *nocloud* VM** — it loses its static IP/hostname and rejoins
  as a ghost. Bake extensions into the image (`image.tf`) and recreate. Metal nodes upgrade fine.
- Never iterate destructive OPNsense firmware endpoints (`/reboot`, `/poweroff`) to "discover" them
  — they execute.
- Don't claim "done" without an isolated end-state check.
- **Before writing any operator-action item that involves a web UI** (meta-state bullets,
  runbook steps, "please click"): name which of the two sanctioned manual classes admits it —
  the **Tier-0 mint-root** or a **third-party console** (`docs/secrets.md` §Minting doctrine) —
  or redesign it as code. A security rationale ("strictly read-only") is not a source-of-truth
  rationale; the 2026-08-09 jail-token bullet passed the first check and failed the second.

## How changes land (jail sessions)

> ⚠ **THIS SECTION IS FOR THE JAIL META-SESSION ONLY — if you are an agent riding this repo from
> the fixer lane, it does NOT apply to you: open a PR and let the reviewer gate it, exactly as in a
> stack repo.** homelab has a live fixer lane (`platform` claim → `repos[homelab].fixer`), so this
> file IS read by worker agents, and "work directly on master" is the one instruction here that
> would be actively wrong for them. Per-context guidance is an open design question the operator
> owns; until it lands, this banner is the guard.

**The default REVERSED 2026-08-12 (operator): jail sessions ship substantive changes as PRs —
PR + watch + fix.** The old direct-to-master default predates the bot reviewer on the platform
stack; measured on its first day (six PRs, ~5-min cycles), the PR lane caught three latent
defects direct pushes would have shipped, ran the required checks on every change (a direct push
BYPASSES them as OrgAdmin), and cost zero codeowner touches (the author==sole-codeowner waiver:
bot approval completes the merge). The seat drives the whole cycle itself: branch `fix/<slug>`,
arm auto-merge at open, the meta-events watcher surfaces the verdict, findings are fixed IN the
PR (the review rubric blocks in-diff findings on this repo — nits never accumulate for a goal or
land as issues), merge lands, back to master.

**Direct to master remains ONLY for the bookkeeping-and-quickfix class** — the writes where a PR
is pure ceremony:

- session state: `docs/agents/meta-state.md`, `agents/coordinator/TICK-LOG.md`, `.claude/skills/GAPS.md`
- the single-writer tracker: `docs/follow-ups.md` + archive (and glossary/register one-liners of
  the same shape)
- genuine quickfixes: one-line corrections, incident response, un-wedging live state — small,
  urgent, operational
- jail-only seat tooling when the operator orders it direct (rare; say so in the commit)
- **governance files the bot cannot gate**: `.agents/review.md` (the reviewer executes the PR
  branch's rubric — it correctly refused to review a change to its own rules, PR#386),
  CODEOWNERS, `.github/workflows/**` — self-gating is impossible, so these are operator-direct
  by necessity, not convenience

**The codeowner gate on machine PRs runs per SESSION, not per PR (ADR-110, 2026-08-18).** For
the maintenance stream — no Goal, reacting to alerts/board items — the human codeowner read is
executed by the operator-started, **corpus-loaded** jail session: the seat reads each parked
master-bound PR with the design-agents corpus as context, merges the small (alert-born fixes,
thresholds/annotations, doc currency, scaffold-tier manifests, fixture/lint upkeep — "a bit
wonky for a couple of days" is acceptable; the alert belts are the net), and escalates the big
(design forks, new machinery, governance/gate changes, budget semantics, new credentials/egress,
anything irreversible or ADR-shaped). A session that has NOT loaded the corpus does not execute
the gate — the corpus load at session start is what makes the read a codeowner read. Cluster
identities still approve and merge nothing; the seat's authority derives from the human starting
the session (jail == human). The Goal lane keeps its own checkpoint model.

Both lanes keep the standing discipline:

- **Verify, then commit** — never the reverse, and never commit a change that was not applied. An
  isolated probe against the live thing, not a re-reading of the diff.
- **Coherent units, pushed (or PR'd) right away.** An unpushed jail commit is invisible to the
  agent loop: the coordinator/worker pods `git clone --depth 1 master`.
- Uncommitted work from a previous session may be in the tree — check `git status` before you
  start and leave what isn't yours alone.
- **Never pipe-filter a gate's exit** (`lint | tail -1 &&` masked a failing lint once); verify
  pushes by fetch-compare.

More detail and the full set of operational recipes live in **`docs/runbook.md`**.
