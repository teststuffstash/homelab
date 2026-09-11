# Codeowner queue — parked PRs across the repo universe (2026-09-11)

Method: one `gh pr list` per repo (12 repos from `agents/stacks.json` `.stacks[].repos`: sleep-iac,
sleep-tracking, snore-recorder, agent-runtime, agent-coordinator, homelab, openrouter-operator,
oracle-iac, allure-behavior-snippets, oracle-fleet, circles-iac, circles), classified with the exact
`§ REVIEW` predicate from `agents/board.sh` (non-draft AND (`reviewDecision==REVIEW_REQUIRED` AND an
APPROVED latestReview by `homelab-reviewer*`) OR label `major/awaiting-human`). Follow-ups: the
PR's reviews/comments + `gh issue list --search "#<num>"` + a recent-issues scan (created ≥ 2026-08-31)
grepped for each PR number. Conflicts: `git merge-tree --write-tree` pairwise on the fetched heads.

## TOTALS

| | |
|---|---|
| Parked PRs | **8** — homelab 6, oracle-fleet 1, sleep-tracking 1 (0 in the other 9 repos) |
| Open PRs scanned | 18 (the other 10: seat-authored, drafts, CHANGES_REQUESTED, merge-conflict, or no bot verdict yet) |
| Follow-ups FILED as issues | 2 — homelab#1544 (from #1541), homelab#1566 (from #1542) — both **(b)** |
| Follow-ups LATENT in review text (not yet harvested) | 8 — **7 (a)** in-diff nits/defects, **1 (b)** |
| (a) vs (b) overall | **(a) 7 · (b) 3** |
| Topic clusters | 5 (6 if the coordinator-scan cluster is split by clause) |
| Largest cluster | `coordinator-scan-clauses` — 3 PRs (#1540, #1541, #1545), all edit `agents/coordinator-scan.sh` |
| Pairwise conflicts | 2 — #1541×#1540 (`agents/coordinator-scan.sh`), #1543×#1542 (`agents/replay/fixtures/goal/rows.psv`) |

Key structural fact: the harvest (issue-authoring.md §Leg (a)) runs at **`merged-closeout`** — the
reviewer's `Follow-ups:` bullets become issues only AFTER the seat merges. None of the 8 has merged,
so 8 of the 10 follow-ups below are still latent review text; the two filed ones (#1544, #1566) came
from ARBITRATE rulings / a ci-red ruling, not from the harvest.

## Per-PR records

### homelab#1545 — Fix #1539: fleet-fault un-latch for agent/error labels
- author `app/homelab-agents-1234` · 2d · labels `agent/arbitrate` · head `fix/issue-1539-fleet-fault-unlatch`
- files: `agents/coordinator-scan.sh`, `agents/coordinator/README.md`, `agents/replay/README.md`, 4 new fixture dirs `agents/replay/fixtures/fleet-fault-unlatch-{cause-closed-green,cause-open,no-marker,probe-fail}/`
- Touches (issue #1539): `agents/coordinator-scan.sh, agents/coordinator/README.md, agents/replay/fixtures/` · PR: `Touches-escapes: none`
- history: 5 rounds; the bot's CHANGES_REQUESTED (emitter play-text never wrote the marker the reader parses — "feature that cannot activate") was fixed IN the PR at round 5 → APPROVED.
- follow-ups: latent (a) — removal path: `--remove-label` ok but `gh pr comment` fails → log misreports "FAILED" (reviewer: "not worth a dedicated round"). No issue filed.
- topic: `coordinator-scan-clauses` / fleet-fault

### homelab#1543 — Fix #1534: sort goal terminal-leg descendants by repo+number
- author bot · 2d · labels `agent/blocked, agent/arbitrate` (blocked-on residue from the #1565 master-red fleet fault, now CLOSED) · head `fix/issue-1534-terminal-leg-sort`
- files: `agents/coordinator-scan.sh` (1 line), `agents/replay/fixtures/goal/rows.psv`, `agents/replay/fixtures/goal/expected/cross-repo-terminal.txt`
- Touches (#1534): `agents/coordinator-scan.sh, agents/replay/fixtures/goal` · escapes none
- follow-ups: none (reviewer: "complete and correctly scoped")
- topic: `goal-replay-fixtures` · **CONFLICTS with #1542 on `rows.psv`** (both append a row)

### homelab#1542 — Fix #1533: add replay fixture for parent.url extraction
- author bot · 2d · no labels · head `fix/issue-1533-parent-url-extraction`
- files: `agents/replay/fixtures/goal/expected/parent-url-extraction-live.txt`, `agents/replay/fixtures/goal/rows.psv`, `agents/replay/fixtures/goal/worlds/open-pre/gh/issue-list.json`
- Touches (#1533): `agents/replay/, agents/coordinator-scan.sh` · escapes none
- follow-ups: latent (a) — new expected file is byte-identical to `checkpoint-due.txt` (thin marginal coverage; "not worth a fixture rework"). FILED (b): **#1566** `blocked-on` marker read line-anchored vs comment-anchored — a scan defect the ci-red ruling *hit on this PR* (Origin: #1542), unrelated to the diff.
- topic: `goal-replay-fixtures` · fixture-only, no clause change

### homelab#1541 — Fix #1529: stale-sha red and human-ruling hold in ci-red escalation
- author bot · 2d · labels `agent/arbitrate` · head `fix/issue-1529-ci-red-stale-sha`
- files: `agents/coordinator-scan.sh`, `agents/replay/README.md`, fixtures `ci-red-stale-sha-{escalates,hold}/`, `docs/agents/merge-path-fsm.md`, `docs/agents/merge-path-fsm.yaml`
- Touches (#1529): `agents/coordinator-scan.sh, agents/replay/fixtures/, agents/replay/README.md, docs/agents/merge-path-fsm.yaml` · escapes none
- history: 6+ rounds; bot CHANGES_REQUESTED twice (vacuous pin — mock keyed on short sha; broken human-hold jq predicate) → the hold was **excised** by arbitration, the pin fixed in-PR → APPROVED.
- follow-ups: latent (a) — new per-sha `check-runs` query lacks `--paginate` (file convention; >30 check-runs would hide a red — the exact silent-park mode this PR closes); latent (a) — title still says "and human-ruling hold" (metadata, `gh pr edit --title`). FILED (b): **#1544** honour a human's `agent/arbitrate` removal with a self-releasing key — the excised sub-defect 2, re-scoped as a design question (hold duration), Touches identical to #1529's.
- topic: `coordinator-scan-clauses` / ci-red · **CONFLICTS with #1540 on `coordinator-scan.sh`** (both edit the ci-red/arbitrate region; also both touch `merge-path-fsm.{md,yaml}` + `replay/README.md`, auto-mergeable)

### homelab#1540 — launcher: move scan/reflex ARBITRATE notices to agent-summary
- author bot · 2d · no labels · head `fix/issue-1527-arbitrate-notices`
- files: `agents/coordinator-scan.sh`, `agents/review-reflex.sh`, `agents/replay/README.md`, fixtures `arbitrate/fu147-refire-blocked-agent-summary/`, `context-prefetch/fix-round-with-arbitration/` (expected+world), `docs/agents/merge-path-fsm.md`, `docs/agents/merge-path-fsm.yaml`
- Touches (#1527): `agents/agent-session.sh, agents/coordinator-scan.sh, agents/review-reflex.sh, agents/machine-comment.sh, agents/coordinator/README.md, agents/replay/fixtures` · escapes none
- history: 6 fix rounds (pin-vacuity ratchet + generated-index churn), final red was master-origin (#1565).
- follow-ups: none filed, none latent (acceptance leg (a) of #1527 — the coordinator-ruling-plus-newer-notice fixture — deferred by arbitration as optional; stays on the OPEN issue #1527, not a new item).
- topic: `coordinator-scan-clauses` / arbitrate

### homelab#1538 — Fix #1525: flatten PF_REVIEWS_RAW jq filters across paginated pages
- author bot · 2d · no labels · head `fix/issue-1525-flatten-reviews`
- files: `agents/agent-session.sh`, `agents/replay/stubs/_common.sh`, `agents/replay/stubs/gh`, `agents/replay/README.md`, fixture `agent-session-paginated-reviews/` (bridge, brief, expected, world pages 1-2)
- Touches (#1525): `agents/agent-session.sh, agents/replay/stubs/gh, agents/replay/fixtures` · escapes none
- history: round 1 broke 14 fixtures (`$2` under `set -u` in the shared stub) — fixed in round 2 via ci-red ARBITRATE; latest red = environmental (proxy self-test SIGINT), rerun.
- follow-ups: latent (a) — `_rp_serve` signature comment (`optional`/`paginate` share one positional); reviewer explicitly declined to file ("comment polish").
- topic: `launcher-review-pagination` (touches the shared replay stub — every fixture rides it)

### oracle-fleet#554 — feat: add class-1 contract prober brief (.agents/probe.md)
- author bot · <1d · no labels · head `fix/issue-344-probe-md`
- files: `.agents/probe.md` (new) · Touches (#344): `.agents/probe.md` · escapes none · `.agents/**` is CODEOWNERS-gated
- source issue #344 stays OPEN for deliverable 2 (the `spec.prober` claim flip in oracle-iac — operator seat's PR, by design).
- follow-ups: latent (a) ×2 — **both are correctness defects in the diff** the bot APPROVED past ("pre-prod merge-forward policy"): checks 3/4 read `result.content[0].structuredContent.*` but `structuredContent` is a sibling of `content` (both highest-value checks would PROBE-FAIL from tick one); check 4's canonical query is English (`"audit log"`) against an Estonian-only lemmatized index (false FINDING). A changes-requested review would have had the worker fix both in one round.
- topic: `prober-brief`

### sleep-tracking#142 — chore: devbox update — MAJOR bump, human review
- author `app/homelab-renovate-1234` · 10d · labels `dependencies, major, major/awaiting-human` · head `devbox-update`
- files: `devbox.lock` only · no Touches (renovate-style, FU-022 weekly lock sync)
- bot review DISMISSED (auto-merge deliberately NOT armed; migration investigation posted: chromium 151→152, only consumer is the Playwright render gate, `system-test` green on this head, no adaptation needed).
- follow-ups: latent (b) — stale docstring `tests/integration/test_dashboard_render.py:7` ("nix devbox chromium is NOT used") — outside the diff.
- related open: sleep-tracking#147 (shared unkeyed devbox venv on the 2-slot runner) — same toolchain surface, not spawned by this PR.
- topic: `devbox-major-bump`

## Follow-up ledger — (a) fixable in-PR vs (b) genuinely new

| from PR | follow-up | where it lives | class |
|---|---|---|---|
| #1541 | `check-runs` query lacks `--paginate` | review text (latent) | **a** |
| #1541 | stale PR title | review text (latent) | **a** (metadata) |
| #1541 | honour human `agent/arbitrate` removal, self-releasing key | **issue #1544** | b (design: hold duration) — though its seed was an in-diff broken predicate that WAS handled by changes-requested → excise |
| #1542 | expected file byte-identical to `checkpoint-due.txt` | review text | **a** |
| #1542 | `blocked-on` marker anchor mismatch | **issue #1566** | b (scan defect observed on the PR, not in it) |
| #1545 | un-latch log misreport on comment failure | review text | **a** |
| #554 | wrong `structuredContent` path (2 checks dead) | review text | **a** — real defect, approved past |
| #554 | English query vs Estonian corpus | review text | **a** — real defect, approved past |
| #1538 | `_rp_serve` signature comment | review text (declined) | **a** |
| #142 | stale docstring in render test | review text | b (outside diff) |

Count: **(a) 7 · (b) 3**. Zero 🌱 sprouts exist in any of the three repos since 2026-08-31; the
`merged-closeout` harvest hasn't fired for any of these because none has merged. Operator hypothesis
check: of the 7 (a) items, 6 are on PRs the bot APPROVED with the finding in the same review — the
oracle-fleet#554 pair is the clearest case where an APPROVE+Follow-ups verdict ships known-broken
content that a CHANGES_REQUESTED would have fixed in one more worker round.

## GROUPING — topic → PRs

| topic | PRs | shared files | conflict |
|---|---|---|---|
| `coordinator-scan-clauses` | #1540 (arbitrate notices), #1541 (ci-red stale-sha), #1545 (fleet-fault un-latch) | `agents/coordinator-scan.sh` (all 3), `agents/replay/README.md` (all 3), `docs/agents/merge-path-fsm.{md,yaml}` (#1540, #1541), `agents/coordinator/README.md` (#1545) | **#1541 × #1540 content-conflict in `coordinator-scan.sh`** — whichever merges second needs a merge-conflict fix round. #1545 merges clean against both. |
| `goal-replay-fixtures` | #1542 (parent.url fixture), #1543 (terminal-leg sort) | `agents/replay/fixtures/goal/rows.psv` (both) | **#1543 × #1542 content-conflict in `rows.psv`** (both append a row at the same spot) — trivial, but the updater cannot auto-resolve it. |
| `launcher-review-pagination` | #1538 | `agents/agent-session.sh`, `agents/replay/stubs/{_common.sh,gh}` | none (merges clean vs all five siblings) |
| `prober-brief` | oracle-fleet#554 | `.agents/probe.md` | n/a (different repo) |
| `devbox-major-bump` | sleep-tracking#142 | `devbox.lock` | n/a; sleep-tracking#145/#146 (seat PRs, `devbox.json`/`devbox.lock`) are on the same surface |

Suggested read order inside the homelab cluster: #1538 first (stub shared by every fixture; independent), then
#1545, then #1540 → #1541 (or the reverse — one will need a rebase), then #1542 → #1543 (same).
All six are currently `ok` against `origin/master`.

## CORPUS-SUBSET map — owning docs per topic (mechanical: mention counts over docs/agents/*.md, docs/*.md, docs/adr.md, agents/*/README.md)

| topic | top docs by mentions (≤3) | narrower section reads |
|---|---|---|
| `coordinator-scan-clauses` (arbitrate/ci-red) | `agents/replay/README.md` (113), `agents/coordinator/README.md` (53), `docs/agents/issue-lifecycle-fsm.md` (22); touched: `docs/agents/merge-path-fsm.md` (14) | coordinator README §The `arbitrate` clause (L976) + §The `ci-red` clause (L1148) + §Blocked-on marker / §ci-cause (L1529-1617) ≈ 25 KB; replay README minus the generated index ≈ 33 KB; `merge-path-fsm.md` whole (24 KB); ADR-086/094/097/119 blocks |
| `coordinator-scan-clauses` (fleet-fault, #1545) | `agents/coordinator/README.md` (9), `docs/agents/merge-path-fsm.md` (8), `docs/agents/issue-lifecycle-fsm.md` (6) | coordinator README §State machine (L36) + §One fleet fault, not N parks (L1196); no ADR mentions "fleet fault" |
| `goal-replay-fixtures` | `agents/coordinator/README.md` (13 — goal walk/close-sweep), `docs/agents/issue-lifecycle-fsm.md` (9), `agents/replay/README.md` (goal family index row) | coordinator README §goal-checkpoint (L723-975, ≈20 KB); ADR-102 |
| `launcher-review-pagination` | `agents/replay/README.md` (66), `agents/coordinator/README.md` (9), `docs/agents/workflow.md` (4) | replay README §The cleanup contract + §seam patterns (stub behavior); `workflow.md` §worker gates |
| `prober-brief` | `docs/agents/roles.md` (9 — §prober L173-190), `docs/agents/iac-lane.md` (2), `docs/agents/chainless-redesign.md` (2); ADR-107 (1) | `roles.md` §prober only (~2 KB) + oracle-fleet's own `specs/server/mcp-conformance.md`, `specs/tools/search.md` (the reviewer's grounding — outside the homelab corpus) |
| `devbox-major-bump` | `agents/coordinator/README.md` (8 — §Dependency major bumps L1368), `docs/agents/merge-path.md` (5) | §Dependency major bumps (3.5 KB) + FU-022 in `docs/follow-ups.md` |

### Size

| corpus | bytes | files |
|---|---|---|
| Full design-agents corpus (`docs/agents/*.md` + `agents/*/README.md`) | **791,296** | 20 |
| Union of whole owning docs across all 8 PRs (`agents/replay/README.md`, `agents/coordinator/README.md`, `docs/agents/merge-path-fsm.md`, `docs/agents/issue-lifecycle-fsm.md`, `docs/agents/workflow.md`, `docs/agents/roles.md`, `docs/agents/merge-path.md`) | **362,802** (46 %) | 7 |
| Section-scoped union (coordinator README §State machine + §goal-checkpoint + §arbitrate..§ci-red + §major bumps + §blocked-on ≈ 58 KB; replay README minus index ≈ 33 KB; `merge-path-fsm.md` 24 KB; `roles.md` §prober ≈ 2 KB; ADR blocks ≈ 5 KB) | **≈ 122,000** (≈ 15 %) | sections |

Per-cluster the subset is smaller still: the three coordinator-scan PRs need ≈ 85 KB (sections above
minus goal/prober/major), the two goal-fixture PRs ≈ 25 KB, #554 ≈ 2 KB of homelab corpus plus the
stack's specs, #142 ≈ 4 KB.
