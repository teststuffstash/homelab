# Spike — why the platform stalls: the defect census, the factory shape, the island cut

_Opened 2026-10-04 (operator ask, second-jail session, PR lane); re-framed 2026-10-05 after the
operator's correction. Status: **findings + an ordered plan proposal, no decision taken here** —
the direction recorded in §Direction is the operator's, the plan steps are proposals. Relates:
[`doc-heat.md`](doc-heat.md) (FU-164 — the measured corpus loads),
[`change-hotspots.md`](change-hotspots.md) (the proxy's separability),
[`codeowner-catches.md`](codeowner-catches.md) (the gate census),
[`no-human-in-the-loop.md`](no-human-in-the-loop.md), ADR-086 / ADR-103 / ADR-110 / ADR-122 /
ADR-126 / ADR-139, ROADMAP §"The platform lane sheds the meta crutch"._

## The question, and the correction

The first draft (2026-10-04) read "76 open issues, an FU counter over 300, nothing moves" as an
admission-and-context problem and proposed ways for the seat to **fix bugs faster** (machine
admission, a cheaper codeowner read, context lints, a smaller tracker). The operator's correction
(2026-10-05): *the 76 open issues are a symptom; the question is why the platform creates them.*
Shift every quality problem left — specs, tests, analysis — then deal with production quality
through guards and self-healing. And ground the answer in software-factory practice, not in
skill tuning. This revision does that; the first draft's measurements stay below because they
are still true, they are just not the lever.

## Measured

### A. The open issues, by what would have prevented them (77 open, read 2026-10-05)

| Class | n | Issues | Prevented by |
|---|---|---|---|
| Containers (Goals, post-launch buckets, stints, themes, retro batches) | 17 | #1985 #1918 #1907 #1906 #1771 #1769 #1680 #1640 #1418 #1311 #1302 #1243 #1170 #1101 #840 #818 #628 | — |
| Reports (weekly model scout) | 4 | #2242 #2053 #1821 #1647 | — |
| Work items with a parent (stint children, Goal reads, experiments, consequence work) | 12 | #2071 #2014 #1991 #1988 #1930 #1910 #1669 #1621 #1334 #1238 #1237 #1224 | — |
| **S1 — a guard missing a case, or a state no clause owns** | **16** | #2203 #2168 #2167 #2164 #2152 #1940 #1897 #1896 #1797 #1793 #1714 #1627 #1572 #1569 #1563 #1544 | a decision table per guard, with the state axes enumerated (label set × close reason × repo shape × event) |
| **S2 — two readers disagree on one grammar or channel** | **8** | #2181 #2163 #1923 #1776 #1775 #1720 #1567 #1566 | one parser per grammar + a producer→consumer round-trip row |
| **S3 — hardcoded scope / a missing enumeration arm** | **3** | #1939 #1855 #1682 | table-driven config + an exhaustiveness lint |
| S4 — environment semantics misread (git, GitHub API, RBAC, shell, ESO) | 9 | #2182 #1973 #1941 #1935 #1898 #1736 #1713 #1517 #1370 | a drill against the real environment; "fail loud, never silently fall back" |
| S5 — brief / rubric / directive design | 3 | #2169 #1794 #1280 | the rubric as a table (author × path → verdict) + reviewer drills |
| S6 — shipped, never observed firing | 2 | #1651 #2178 | a live acceptance probe per transition; a drill per chain |
| S7 — flake / external | 2 | #168 #1707 | — |
| S8 — a test, literally missing | 1 | #1571 | the test |

**44 defects; 28 (S1–S3, S8) are row-shaped** — a visible table with the missing row would have
caught them before merge. 9 are drill-shaped (S4). The open set is biased toward what stays open,
so the 120 issues closed since 2026-09-05 were sampled for the location only: 46 of 120 carry a
`Touches:` under `agents/`, 22 of those the scan — the same place.

### B. Where the defects live vs where the tests are

- The three FSMs (`merge-path-fsm.yaml` 14 transitions, `issue-lifecycle-fsm.yaml` ~30,
  `iac-lane-fsm.yaml` 7) model **transitions**. **Zero of the 44 defects is a wrong transition.**
  All 16 S1 defects sit inside a guard's **input space** — which label combination, which close
  reason, which repo shape — axes the FSM does not enumerate.
- The ADR-103 ratchet pins a changed transition with a replay fixture: **one world, one row.**
  `agents/replay/`: 201 fixtures, **31 tabular** (`rows:`), **1 shared world**; the harness's own
  2026-08-12 cleanup contract says the same ("a family IS a decision table, stored as N copied
  directories"). #1224 (a changed clause line must be *reached* by a fixture) is open.
- `agents/coordinator-scan.sh`: 6,107 lines, **69 distinct clause markers**, 15 jq predicates
  reading `labels[].name`, 15 machine-meaningful labels. The interfaces between pieces are 11
  line-anchored body grammars parsed in up to **18 files each** (`Touches:` 18, `Base:` 9,
  `Budget:` 8, `TOOL_GAP` 8, `AGENT_STRIKE` 8) — S2 is what that many parsers cost.
- The retro's weekly platform-logic count (ADR-103 bucket-A) ran **15 → 28 → 38** across August
  (r1, r4, r2 reports); the series has not been scored since.

### C. The island cut — doc→component co-change (1,899 commits since 2026-07-01)

Component self-containment (commits touching the component's code, share that also touched
another component's code, top partner):

| Component | commits | cross-component | top partner |
|---|---|---|---|
| gateway (`argocd/resources/openrouter-proxy/` + `model_id.py`) | 71 | **39 %** | scan 21 |
| scan (+ footprint, replay, goal graph) | 276 | 63 % | launcher 72 |
| launcher (`agent-session.sh`, recipes, ground rules) | 127 | 66 % | scan 72 |
| reviewer (`reviewer-session.sh`, lenses, `review.md`) | 46 | 78 % | scan 34 |
| reflexes (`coordinator/*-argo.yaml`) | 88 | 82 % | scan 47 |
| updater | 11 | 90 % | scan 10 |
| responder | 14 | 100 % | scan 11 |
| agentstack (XRD/Composition, `stacks.json`) | 157 | 57 % | infra 55 |
| exporters | 90 | 57 % | infra 35 |

**Two islands, not nine.** The gateway separates today (ADR-139's own 30-of-44 count agrees); its
consumer surface is six endpoints (`/route` 39 refs, `/router-status` 24, `/metrics` 14,
`/git-token` 10, `/opencode-limit` 9, `/loop-git-token` 7) across 83 files. Scan, launcher,
reviewer, updater, reflexes and responder co-change as **one thing with the scan at its centre**
— the coordinator — and that one thing holds 27 of the 44 defects. Agentstack and the exporters
co-change with infra: they are homelab's integration surface and stay.

The corpus follows the islands. Under a gateway + coordinator cut, of the 836 KB design-agents
read plan: the coordinator brief (139 KB) moves except its 11 KB label state machine and the 3 KB
ADR-119 filing contract; `issue-authoring.md` + the lifecycle FSM (119 KB) keep ~30 KB of grammar
and YAML; `observability-and-retro.md` (60) keeps the ~15 KB of emit channels; `model-routing.md`
(47) keeps the ~12 KB launcher/scan half; `chainless-redesign.md` (46) is rails design plus
build-order history (spikes); `merge-path.md` narrative (42) is incident history; `roles.md` +
`workflow.md` (82) become a ~25 KB index to island contracts; the generated `*-fsm.md` (83 KB)
leave the read plan since the YAML is the source. **≈520 KB leaves; ≈250–300 KB stays** —
about 70k tokens, a routine load instead of a 300k exception.

### D. Context the human pays (first draft, still true)

| What | Size |
|---|---|
| Static startup context, every seat session | ≈56–70 KB ≈ 14–17k tokens (`scripts/session-ctx.sh --startup`) |
| `/meta-coordinate` bootstrap adds | meta-state 32 KB ("tiny, transient") + TICK-LOG tail + 17 KB skill body |
| `/design-agents` read plan | 836 KB static → 299k/346k tokens measured; doc-heat run 2: 72 % of lines never read |
| Records | TICK-LOG 1.09 MB · adr.md 235 KB (54 of 111 ADRs over the 20-line rule) · follow-ups.md 133 KB (132 open, 74 in the Agents block the routing table assigns to issues) |
| Coordinator pod | the 139 KB brief as `--append-system-prompt-file`, every clause, every ride |

### E. Where the human is (first draft, still true)

The scan's one dispatch precondition is a human-applied `agent/queued`: 0 of 77 carry it, 44 are
bot-filed, 49 have no comment. Eleven human gates inventoried; the TICK-LOG's last four days read
"operator / by hand / codeowner click" ~40 times and "unattended" six. ADR-128 census: 273
codeowner reads → 38 findings (13.9 %).

## Reading it against the factory literature

| Practice | Source | Here |
|---|---|---|
| Research → design → plan → implement, as separate sessions; the human reviews the **design**, not the code — "leverage planning, skip code review" is the 2–3× option; "no review" failed within months | Horthy, *Context engineering* (Pragmatic Engineer, 2026) | The codeowner read is on diffs (273 reads, 13.9 % yield). Goals carry a design pin, but the reviewed artifact is still the PR. |
| Frequent intentional compaction: distil the trajectory into a document, start fresh from it; stay under ~40 % of the window | Horthy | meta-state.md is the compaction doc at 32 KB prose; the corpus read starts at the window's "dumb zone". |
| Own your context window; small, focused agents; stateless reducer; pre-fetch the context you might need | *12-factor agents* (factors 3, 10, 12, 13) | Workers: yes (≈42 KB, pre-fetched). Coordinator: one 139 KB brief for every clause. |
| Decision tables, not N near-duplicate tests; the reviewer reads the table and sees the missing row | NTD 2024 talk → `docs/agents/README.md` §Testing doctrine | Stated as doctrine; the replay harness is 31 tables in 201 fixtures. |
| Rows are the contract: requirement IDs as headings, test ids, error codes; ⚖ marks judgment rows; evidence stamped per row; schema ⇄ requirement coupling checked by a gate; use-case first; incompleteness rendered (`🚧 WIP`, `⚑ gap`) | oracle-fleet `docs/process/README.md`, ADR-086 | Exists for one stack. The platform has FSM YAML + fixtures, no `specs/`. |
| Humans review the result, not the diff; specs are the human gate (CODEOWNERS) | oracle-fleet rule 1 | **Rejected for the platform by the operator (2026-10-05)** — the operator reads specs but is not a blocker: a full-context reviewer gates spec changes; guards revert, responders heal. |

## Diagnosis

The stall is upstream of admission. The platform writes guards by hand, one reading of the
labels per clause, and pins each with a single replayed world; the bugs are the rows nobody
wrote. The admission backlog and the record growth of the first draft are what that looks like
from the seat: every row-shaped defect becomes an issue the seat must admit, a ride, a review, a
TICK-LOG line and often an FU. The human gates (E) are the belt that compensates for the missing
tables, and the corpus (D) is what a human needs in order to be that belt.

## Direction (operator, 2026-10-05 — recorded, not decided here)

1. **Monorepo stays; pieces move to islands** — a directory with its own build, specs, tests and
   context; the seams become shared libraries/files. Homelab keeps the consumer contracts, the
   integration and the big picture.
2. **Specs are reviewer-gated, not codeowner-gated.** The operator reads specs and does not block
   on them. A full-context reviewer (the island's specs + the consumer contracts it touches, small
   enough per island) reviews spec changes; ⚖ rows reach the operator as a digest to read.
3. **Guards revert; the loop self-heals.** Production quality is detectors + a revert path +
   responders, proven by drills — not a human read.

### Interfaces are redrawn at the cut (operator, 2026-10-05)

An island exposes what its consumer needs to act, not what the island holds; the move to
islands is the moment to shrink every seam. Measured on master (the component page
[Islands and Seams](https://claude.ai/artifact/XpxnjfA4WTg1As18eTQHUK) carries the per-seam
table):

- **Gateway.** The caller computes half the routing before it asks: it reads the stack row,
  filters the chain by harness, fetches the issue's labels, copies the claim's deny list, sends
  9 fields (`stack, task, role, session, key_ref, chain, deny, labels, urgency`), consumes 7,
  then runs its own ladder — **84 self-routing sites** across six scripts (launcher 33,
  subscription latch 12, session 10, scan 9, resolve-model 7, reviewer 6), two capacity
  booleans polled, 12 harness env vars hand-assembled, 7 model literals. The consumer's real
  question is "may this unit run now, with which harness, and what goes in the pod's env".
  Proposed: `POST /sessions {stack, repo, role, task, round, tier, surface}` →
  `{decision, retry_after_s, session, harness, env{…}, context_tokens}`; the proxy resolves the
  model **per request** from the session identity (every LLM call already passes through it
  with an opaque auth ref), so no caller names a model and the two limit endpoints fold into
  the defer. Six endpoints become two plus the evidence surface.
- **Claim.** 14 fields; the 5 model knobs (`coordinatorModel, workerModel,
  workerModelFallbacks, routerMode, modelDeny`) are read by the Composition **0 times** — only
  scripts read them. With a routing gateway they leave the claim; `modelDeny` stays as the one
  legitimate routing policy, projected by the Composition into the gateway's mount so it has
  one reader. 14 → 9 fields.
- **Coordinator ↔ GitHub.** 15 labels (8 `agent/*` states + 7 class/verdict) and 11 body keys
  carry five facts: admission, class, budget, one state, a Goal verdict. ADR-122 (3) already
  rules one machine block + one parser; the island work is executing it.
- **Observability.** `ci-cause:` / `TOOL_GAP:` markers in comments and review bodies become one
  typed event per ride outcome (ADR-103 (2) already rules machine residue out of timelines).

## The plan (ordered; each step one session + one PR + a settle number)

**P0 — Un-wedge the theme lane.** #1935: the `goal/**` ruleset has no bypass actor and strict
checks make BEHIND terminal, so every theme assembly parks until an OrgAdmin pushes. Fix in
`tofu/github` (operator lane). *Settles:* an assembly PR brought current by the updater.

**P1 — One themed Goal over the row-shaped defects, fix rule "table first, then the row".**
The 24 S1–S3 defects in two themes by fix surface (ADR-126 membership = `Touches:` ⊆ theme
surface): *guard tables* (the 16 S1 — scan + fixtures) and *one parser* (the 8 S2 — footprint,
ledger, reviewer, handoff). Each child converts the guard it fixes into a decision table (fixture
`rows:` over a named world) and adds its row. S4 becomes drills, not rides; S5 becomes rubric
rows. The 33 non-defects stay out (containers in a container break the lineage rules). One human
click admits the tree; one human read per theme assembly. *Settles:* the Goal's two assemblies
merged; the 24 issues closed; bucket-A scored for the two weeks after.

**P2 — The gateway island** (ADR-139 step 3 done *inside* the monorepo). A directory holding the
proxy code, `specs/` in the oracle shape (six endpoint pages with schema coupling; `/route` first
— #2163 is a router row nobody read), its tests and image CI; `argocd/resources/openrouter-proxy/`
keeps the deploy manifests and the mounted `model-classes.json`; the consumer contract is the
redrawn one (§Interfaces: `/sessions` + per-request model resolution), and it is the only
gateway text left in `docs/agents/`. A later `git subtree split` keeps history. Does not wait
on FU-269/FU-127 — nothing leaves the repo. *Settles:* `model-routing.md` ≤ 12 KB; zero model
literals in `agents/*.sh`; the gateway's spec pages carry evidence for every row; the claim's
five model knobs gone from the XRD.

**P3 — Shared parsers.** One library for the 11 body grammars and one file for the 15-label
vocabulary (ADR-122 (3) already rules "one machine block, one parser"); every reader imports it.
*Settles:* `grep -l 'Touches:'` over `agents/ scripts/ .agents/` returns the library and the
authoring writer only.

**P4 — The spec gate as a reviewer lens + a revert guard, per island.** (a) a lens that loads
the island's `specs/` and the consumer contracts the diff touches, grades spec rows (a row
changed without its ⚖ flag, a row removed with evidence green, a schema change without its page),
and posts the verdict; (b) a weekly ⚖ digest — rows changed, by island — for the operator to
read, never to approve; (c) each island ships a detector from its own evidence, a revert path
(pinned image for the gateway; a revert PR for the coordinator, whose pods clone master), and a
drill that drives the chain end to end (#2178's revert chain was unproven; the responder's
fix-verdict path is the self-heal half). *Settles:* a deceptive spec PR (row says X, code does Y)
blocked by the lens on a throwaway base; one drill per island green.

**P5 — Guard tables as the ratchet.** #1224 lands: a changed clause line must be reached by a
registered fixture row, or be FSM-declared unreplayed. Tables backfill in fix-density order
(ADR-103: never big-bang) — P1 is the first batch. *Settles:* tabular fixtures ≥ 69 (one per
clause marker); bucket-A falling across four scored weeks.

**P6 — Machine admission for `agent-fix` filings** (the first draft's P1), now safe: the lens is
the gate, the guard is the net. Goals and governance-core paths stay human (ROADMAP: autonomy
grows on the intake and fix sides, never the approval side). *Settles:* days from bot filing to
`agent/queued` ≈ 0 without a seat touch.

**P7 — Context follows the islands.** The corpus split of §C; the coordinator brief becomes the
coordinator island's own context, loaded per clause; the first draft's hygiene items ride along
as one-liners — `session-ctx --startup` thresholds as lints, the Agents block of the tracker back
to issues, containers and `agent/done` issues closing on date predicates, meta-state as a
machine-readable pickup list. *Settles:* `--startup` ≤ 40 KB; the design-agents read plan
≤ 300 KB.

**Order.** P0 is a ruleset edit; P1 and P3 are the backlog itself; P2 is the first island and the
template for the coordinator's; P4 and P5 are what make P6 safe; P7 falls out of P2.

## Quickfixes that rode the opening PR

- `scripts/session-ctx.sh --startup` — the static startup-context meter + the design-agents
  read-plan size, so trims are measured, not felt.
- `CLAUDE.md` — three history passages reduced to their rules (18.0 → 16.8 KB).
- `agents/jail-seat-card.md` — the mechanism-history blockquote and two measured-history
  paragraphs reduced to their rules; every rule kept.
- `board-sweep` + `fu-sweep` — the "run the design-agents read plan first" rule (forbidden since
  2026-09-27) replaced by the slice rule; fu-sweep's and design-agents' descriptions reduced to
  when-to-use; a stale "34 of 57" figure replaced by "read the lint output".

## Loose ends found, not filed (second jail — the primary mints)

- "Island" is the operator's word for the unit of §Direction (1); the glossary has no row, and a
  name for platform functionality clears the glossary in its coining commit (FU-163).
- The coordinator has no pinned ref: pods clone master, so its revert class is a revert PR, not an
  image pin — P4(c) must say so per island.
- The retro's bucket-A series stopped at 38 (2026-08-31); P1/P5 settle on it, so it needs scoring
  again first.
- GAPS.md has no §second-jail, §board-sweep, §fu-sweep, §docs-cleanup, §opnsense-as-code,
  §skill-retro although 12 of 13 skills demand the glance; 9 open GAPS entries carry ≥ 2 dates and
  none is promoted.
- MEMORY.md (auto-memory index) is 25 KB with 300–489-char lines: an index holding content.
- `fu-sweep` and `board-sweep` had not been edited since 2026-08-19 while the rules they encode
  changed twice.

## What would settle it

The weekly platform-logic count (ADR-103 bucket-A), scored again and falling; days from bot
filing to `agent/queued`; tabular fixtures over clause markers; seat-minutes per merged machine
PR. Each measured on the two weeks before and after a step lands.
