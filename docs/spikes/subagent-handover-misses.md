# Subagent handover misses — the decomposition-rules ledger

**Status: OPEN experiment (operator directive, 2026-08-13).** The jail's build mode during the
bootstrap is **subagent chunks, double-reviewed** — the seat reads the worktree diff pre-push,
then the review reflex reads the PR — and this file is the miss ledger both reads feed: every
defect logged by WHO CAUGHT IT, every catch distilled into a **decomposition rule** for the next
handover. The operator's framing: *"the main thread should keep a log of misses — only way we can
improve the process of handing over work. This is a decomposition rules gathering exercise."*

Companions: the worktree A/B protocol (meta-state §NEXT SESSION, 2026-08-12 — the corpus
question: do corpus-less subagents leak context-poverty defects that surface post-merge?) and the
build-mode section of [`../agents/chainless-redesign.md`](../agents/chainless-redesign.md)
(ADR-107). What settles the experiment: enough rows that the catch-point distribution and the
rule list stabilize — then the seat gate narrows to first-of-family chunks (or drops), the rules
become the dispatch-prompt template, and this spike is harvested into the charter's build-mode
section.

## Why both reviews, for now

The bot proved itself on seat-authored work (4 real round-1 catches across 2 days, two of them in
fable-authored code — PR#407, #412 — both by tool-grounded verification). But the bot has never
been the guard against the A/B's dangerous class: context-poverty defects that pass BOTH reviews
and surface later. Until the post-merge column has data, the seat read stays on every chunk.

## The ledger — v1 rows (2026-08-12..13; schema frozen 2026-08-19, new rows go to v2 below)

One row per PR. `author` = seat (baseline arm) | subagent (trial arm). Catch-points: **seat**
(pre-push diff read) · **bot** (review reflex) · **post-merge** (anything found after — the
lagged column; back-fill it when a defect traces to a merged PR). `rule` = the decomposition/
handover lesson, or `—` if clean.

| date | PR | chunk | author | seat caught | bot caught | post-merge | rule derived |
|---|---|---|---|---|---|---|---|
| 2026-08-12 | #392 | goal-ancestor table-mode (4 fixtures) | subagent | 0 | 0 | (watching) | run-1 of the A/B; 148.5k tokens, 9m11s authoring |
| 2026-08-13 | #407 | claude-ride `--model` fix | seat | — | 1 (fallback pattern tested the PRE-parse shape — could never match) | — | verify a guard's predicate against the value AT THE GUARD, not at the source; the reviewer RAN the parser — decompositions should name the executable check, not just the intent |
| 2026-08-13 | #408 | /route urgency+labels leg | seat | — | 0 | (soaking) | — |
| 2026-08-13 | #409 | model-splitting shim + claude-go | seat | — | 0 | compat gaps found by LIVE probing same day (not review-catchable — no key existed at review time) | probes > reviews for external-API contracts; a chunk against an unprobed API should budget a probe round, not assume the docs |
| 2026-08-13 | #410 | claude-go env file + Go-leg hardening | seat | — | 0 | — | — |
| 2026-08-13 | #411 | ADR-107 charter docs | seat | — | 0 | — | — |
| 2026-08-13 | #412 | pr-wait primitive | seat | — | 1 (reviewDecision survives pushes — the primary caller loop echoed stale feedback; reviewer cited `reviewable_again` as prior art) | — | when a chunk's contract IS a loop, hand over the loop's re-entry case explicitly ("what does the second invocation see?"); state-freshness guards are a named repo pattern — point the author at `reviewable_again` |
| 2026-08-13 | #418 | fix.yaml `agents/**` tier caveat (#354 opt 1) | **subagent** (kimi-k3, sonnet slot, Go rail; 64.6k tok, ~4 min) | content: 0 · **process: 1, post-hoc** — checked out its branch in the SHARED tree (card violation; surfaced only when the seat's next commits landed on the subagent's branch; reflog-confirmed) | 0 | — | (a) the seat gate gains a deterministic POST-RUN process check: `git -C /workspace/homelab branch --show-current` + `status` — a diff read cannot see boundary escapes; (b) the card must teach the MECHANISM, not just the rule: branch refs are repo-GLOBAL across worktrees, so any `git -C <shared-tree>` escapes the boundary even when the commit lands in the worktree |
| 2026-08-13 | #429 (r1–r3) | proxy Go leg (chunk A of #420) | **subagent** (kimi sonnet slot) | r1 REPORT-layer catch: wrong integration point (/chat/completions built, /anthropic contracted — its green self-test tested what it built, not the contract) · **process: r1 committed proxy-port copies onto EVERY branch the shared tree visited** (stowaways on PR#427 + PR#419; reviewer WITHHELD verdict + agent/error; responder filed #428) | 2 High on the stray copy's early review (case-variant credential smuggling; Go statuses contaminating the OR capacity latch) — fixed in r3 | (lag) | (a) name the DECISIVE test case in the contract — implementer self-tests verify the implementation; (b) isolation moved worktree → LOCAL CLONE (#428 ruling): structure over documentation once a class recurs; (c) a failed `&&` chain's trailing checkout never runs — never park branch state behind one |
| 2026-08-13 | #433 | Go key via ESO (chunk C) | **subagent** (kimi sonnet slot, 71s, 34k tok) | 0 — first fully CLEAN clone run | 0 (merged r1) | — | clean-run traits worth repeating: single-file scope, pattern file named WITH a "don't look further" clause, exact field values in the prompt. (Seat-side miss recorded on the issue: a "file does not exist" claim from a tree-scoped grep — negative existence claims need repo-wide grep) |
| 2026-08-13 | #434 (r1–r4) | Go usage meter (chunk B) | **subagent** (kimi sonnet slot) | r1: 4 — branch-contract miss (committed on clone master, reported a branch that didn't exist; clone isolation contained it), spec'd stub-e2e test silently downgraded to a store tautology, NameError on the untested unknown-model branch, Prometheus TYPE per-window duplication (idiom pointer ignored) · r2: 2 — DELETED the four beta-strip assertions in a block rewrite, tautology REPEATED | 1 — cache-write tokens extracted but never priced (`_cw_p` discarded; 6 models undercounted) — survived author + dispatch spec + seat review: the decorrelation catch | (soaking) | (a) the tautology class needs a NAMED clause in every dispatch (see card rule below); (b) block rewrites: existing checks move, never vanish — diff your own test block for deleted `check(` lines; (c) the formula in a dispatch must enumerate EVERY priced dimension — the author implemented the example, not the dict |
| 2026-08-13 | #435 (r1–r2) | reviewer Go failover + snapshots (chunk D) | **subagent** (kimi sonnet slot) | r1: 2 — fixtures COPIED the gate logic into bridge.sh instead of `block:` composition (green fixture that can't see drift; sentinels added but unused), HEADSHA fallback unreachable (pipeline `|| ` after `cut`) · report: "9 pre-existing replay failures, unrelated" asserted WITHOUT a baseline (master 81/0 green; its clone's reds were its own mid-work state) — and round 2 DOUBLED DOWN on the claim | 1 — `${MODEL}` baked into PREP at build time while the failover reassigns it later: Go-served reviews would stamp the wrong model into the never-scrubbed TICK-LOG (one-char escape fix) | — | (a) "pre-existing" is a claim that requires a master-baseline run IN the report; (b) heredoc quoting discipline: anything a later gate can mutate must be escaped into runtime expansion — "what does this line see at POD time?" joins the loop-re-entry question as a named handover check |
| 2026-08-13 | #436 | Go-leg surface-path map | seat | — | 0 (merged r1) | root cause was chunk A's (#429): `GO_UPSTREAM + self.path` VERBATIM → opencode.ai SPA 404 as 200 HTML — and chunk A's self-test ASSERTED the buggy join (expected value derived from the code, not the upstream contract). Second live-DOA in the same leg (first: no User-Agent → Cloudflare 1010, fixed in #434 r2). Both invisible to stubs, both predicted by the matrix, both found ONLY by the seat's post-merge live probe | stubs prove OUR half only: an upstream-facing chunk is closed by a SEAT live probe, never by a green stub suite — and a self-test expectation must cite the contract source it encodes (the matrix row), or it will happily pin the bug |


## The ledger — v2 (2026-08-19 →): comparison keys + transcript links

The schema change the corpus/model-comparison question forced (operator, 2026-08-19): rows gain
the bucketing keys a "did the deepseek→haiku swap move the distribution" grep needs, and shed
everything derivable once the transcript link exists. The rules that keep it cheap and honest:

- **The row is written in the same act as the verdict** — the seat's pre-push read (subagent
  arms) or the bot verdict/merge (seat arms). Deferring rows is the archaeology tax: the wave
  rows below were reconstructed from PR metadata after the drafting session died, and their
  seat/model cells are permanently `unrecorded`.
- **`arm`** = author (seat | subagent) · **SERVED model, never the slot alias** (the PR#407
  lesson — "haiku" through the shim was not haiku) · subagent tokens.
- **`corpus`** = `git log -1 --format=%h -- docs/agents agents/jail-subagent-card.md` at the
  session's corpus read — the bucketing key for corpus-change comparisons.
- **`transcript`** = `s3://jail-transcripts/projects/<slug>/<session-id>.jsonl` (the PR#580
  sync). Timings, bounces, tokens-per-round and the play-by-play live THERE, not in the row.
- **Clean rows are sacred** — they are the denominators; a findings-only ledger cannot tell
  "the model improved" from "the seat stopped looking". The seat's own baseline (2/6 leak to
  bot, v1 observations) is the yardstick either way.
- Optional GitHub-side mirror: one `Seat pre-push read: clean | N findings (<classes>)` line in
  the PR body at push — greppable parity with bot verdicts; the file stays the analysis store.

| date | PR | chunk | arm | corpus | seat | bot | post-merge | rule derived | transcript |
|---|---|---|---|---|---|---|---|---|---|
| 2026-08-18 | #569 | FU-167 step 1: family dirs + bidirectional pins: lint (moves 4+5) | unrecorded (backfilled — drafting session died with its scratchpad) | 5c13317 | unrecorded | 0 (merged r1) | (lag) | main-checkout push worked first try — the #429 clone-origin lesson HELD (a rule that stuck) | — (pre-sync) |
| 2026-08-18 | #572 | FU-167 step 2 batch 1: c4c5-infeasible + harvest + goal families → table mode (14 dirs → 3 tables, −1233 lines) | subagent wave · slot-default deepseek-v4-flash UNVERIFIED (backfilled) · 278k tok / 185 calls / 76 min; seat ≈20k (brief+review+integration) | 5c13317 | unrecorded | 0 (merged r1) | (lag) | — | — (pre-sync) |
| 2026-08-19 | #578 | session types & the watch contract (chainless + card) | seat | c01967f | — | 0 (merged r1) | (lag) | — | s3://jail-transcripts/projects/-workspace-homelab/ff7482dd-1b15-4410-a03f-6103330708c3 |
| 2026-08-19 | #579 | board § FIX row (seat CR PRs) + suite | seat | c01967f | — | 0 (merged r1) | (lag) | — | s3://jail-transcripts/projects/-workspace-homelab/ff7482dd-1b15-4410-a03f-6103330708c3 |
| 2026-08-19 | #580 | jail-transcripts bucket + sync script | seat | c01967f | — | 0 (merged r1) | 1 — the new Workspace manifest was never registered in `kustomization.yaml` `resources:`, so ArgoCD applied NOTHING (found by the seat's post-merge Secret-wait timing out; the kustomization header warns about exactly this). Survived author + bot | a new manifest in a kustomize-rendered dir is TWO edits — the file AND its `resources:` line; the end-state check (does the object exist?) is what caught it, not any review | s3://jail-transcripts/projects/-workspace-homelab/ff7482dd-1b15-4410-a03f-6103330708c3 |
| 2026-08-19 | #582 | board ⚠ half-labeled TRIAGE line (oracle#260 class) | seat | c01967f | — | 0 (merged r1) | (lag) | — | s3://jail-transcripts/projects/-workspace-homelab/ff7482dd-1b15-4410-a03f-6103330708c3 |
| 2026-08-19 | #583 | jail stint container (shape + STINT source + board excl) | seat | c01967f | — | 0 (merged r1) | 1 — the COIN collided: "wave" already carried three senses (ArgoCD sync waves, Z-Wave, the informal subagent-batch usage); operator caught it same-day → rename #585 | a new coin greps the WHOLE corpus for informal senses — the FU-163 glossary check is necessary, not sufficient | s3://jail-transcripts/projects/-workspace-homelab/ff7482dd-1b15-4410-a03f-6103330708c3 |
| 2026-08-19 | #584 (r1–r2) | session-ctx measured telemetry | seat | c01967f | — | 1 — bare `--big` busy-hung: bash shift-past-end is an args-UNCHANGED no-op (nonzero, uncaught without -e), so the parse loop spun; the bot RAN it (tool-grounded, timeout 3 → 124) | (lag) | optional trailing values: never `shift 2` for a maybe-absent arg — consume the optional in its own case | s3://jail-transcripts/projects/-workspace-homelab/ff7482dd-1b15-4410-a03f-6103330708c3 |
| 2026-08-19 | #585 | stint rename sweep (wave → stint) | seat | c01967f | — | (riding) | — | — | s3://jail-transcripts/projects/-workspace-homelab/ff7482dd-1b15-4410-a03f-6103330708c3 |
| 2026-08-19 | #586 | #420 closeout docs currency (§Rollout) | seat | c01967f | — | (riding) | — | — | s3://jail-transcripts/projects/-workspace-homelab/ff7482dd-1b15-4410-a03f-6103330708c3 |

## Standing observations (promote to rules as they recur)

- **The tautology class hit 4 sightings in one day** (pre-halved constant read back; fallback
  store-seed, twice; fixture bridging a COPY of the gate; chunk A's path assertion derived from
  the code): promoted to a card rule in the same PR — "if your test contains a copy of the logic
  under test, or an expected value your test itself inserted, it tests nothing."
- **Round-trip economics, day 2**: subagent authoring ~free (Go rail), rounds ~2–7 min each; the
  binding costs are bot rounds (sonnet subscription) and seat attention. Tight, computed,
  single-concern round messages converged every branch ≤2 rounds; the wide round-1 dispatches
  are where all multi-round churn originated.
- **The seat's baseline bot-catch rate is 2/6 on one day** — the seat's own authoring leaks
  round-1 findings at a measurable rate, which is the honest yardstick for judging subagent rows
  (a subagent arm with 1-in-3 bot catches is not automatically worse than the seat).
- Both seat-arm catches were **contract/state-freshness classes, found by executing the code
  against the live surface** — the tool-grounded-verification mechanism from the banked
  tier-thesis (TICK-LOG 2026-08-13). Decomposition corollary: a handover should always name the
  executable verification ("run X, expect Y"), because that is what reviews demonstrably use.
- Dispatch-prompt mechanics proven so far: warm devbox = `cp -a /workspace/homelab/.devbox .`
  (40s → 3.6s, measured); the PR cycle = `devbox run pr-wait -- <n>` (typed exits; fix-in-context
  on 2, escalate on 3/4/5); worktree per subagent; width ≤2–3 (subscription burn).
