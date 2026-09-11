# Spike — codeowner-catches census, 2026-08-04 → 2026-09-11

**Question (operator, verbatim):** "find how many times have we found problems in codeowner
review and what types of problems they were. I'm thinking of ways to reduce their amount anyway,
let some things go more free and hope the loop itself heals some problems even if they come up."

**Scope.** Machine-authored PRs (`homelab-agents-1234[bot]`, `homelab-renovate-1234[bot]`;
`renovate[bot]` authored none in the window) on `teststuffstash/{homelab,agent-runtime,
agent-coordinator,openrouter-operator}`, created 2026-08-04 → 2026-09-11. The codeowner gate is
[ADR-110](../adr.md) (per-session corpus read, `agents/jail-seat-card.md` §How changes land); the
path tiering is `CODEOWNERS` since 2026-08-04. Seat-authored PRs are excluded.
`homelab-deploy-1234[bot]` authored 57 homelab PRs in the window (all auto-merged, 0 human
touches) — not in the census, noted here only.

**Definitions used.** *Bot-approved* = at least one `homelab-reviewer` review in state APPROVED,
**or** a review now in state DISMISSED whose body is not a changes-request (GitHub's GraphQL
loses the original state of a dismissed review; `dismiss_stale_reviews_on_push=true` on the
master ruleset dismisses every approval a later content push lands on — 43 bot reviews are in
that state on homelab). *Catch* = a bot-approved machine PR the human then did not merge as-is:
a `RasmusSoot` CHANGES_REQUESTED/COMMENTED review or an APPROVED review whose body records a
finding, a non-merge `RasmusSoot` commit after the first bot approval, a human dismissal of the
bot review, a human close-unmerged, or a human PR comment recording a gate-read finding. *Clean
read* = bot-approved, touched by the human (a review or the merge), no catch. *No human touch* =
bot-approved and auto-merged without any human review or merge (Tier-1 paths).

## Method (deterministic reads; every command as run)

```
# 1. PR list — the documented `gh pr list --json …commits,reviews,files --limit 500` call FAILS on homelab
#    (GraphQL node-limit: "requesting up to 1,000,000 possible nodes"); REST list used instead:
gh api "repos/teststuffstash/<slug>/pulls?state=all&per_page=100&sort=created&direction=desc" --paginate \
  --jq '.[] | select(.created_at >= "2026-08-04") | {n:.number,t:.title,a:.user.login,s:.state,m:.merged_at,c:.closed_at,cr:.created_at,l:[.labels[].name]}'
# 2. Per-PR detail, batched 20 PRs per GraphQL query (aliases p<N>: pullRequest(number:N)), fields:
#    number title state createdAt mergedAt closedAt author{login} mergedBy{login}
#    reviews(first:30){author state body submittedAt}
#    commits(first:60){commit{oid committedDate messageHeadline author{name user{login}} committer{name user{login}}}}
#    comments(first:40){author body createdAt}  files(first:60){path}
#    timelineItems(first:60, itemTypes:[REVIEW_DISMISSED_EVENT,CLOSED_EVENT,MERGED_EVENT,REOPENED_EVENT]){… actor createdAt dismissalMessage review{author state}}
gh api graphql -f query='query { repository(owner:"teststuffstash", name:"<repo>") { p<N>: pullRequest(number:<N>) { … } … } }'
# 3. One commit body: gh api repos/teststuffstash/homelab/commits/<sha> --jq '.commit.message'
# 4. Budget check: gh api rate_limit   (5000/5000 REST + GraphQL at start; ~30 GraphQL calls used)
# 5. TICK-LOG grep (clone, from the 2026-08-03 heading, line 1864, onward):
awk 'NR>=1864' agents/coordinator/TICK-LOG.md | grep -niE 'gate read|gate-read|codeowner read|seat caught|seat-caught|the gate caught|caught by the seat|caught at the read'   # 79 hits
```

Classification was done by reading every `RasmusSoot` review body / commit headline / dismissal /
close comment on the flagged set (the 199 human APPROVED bodies were split by keyword into 130
read in full + 69 plain "read → merging" bodies). Per-PR timelines paged at 60 commits / 30
reviews / 40 comments; no PR in the flagged set hit a page cap. Human-commit detection ignores
`Merge …` headlines (updater and conflict-resolution merges).

## Totals

| Repo | Machine PRs | Bot-approved | No human touch (auto-merged) | Human-read | Clean reads | Catches (all) | Catches with a finding | Catch rate (finding ÷ human-read) |
|---|---|---|---|---|---|---|---|---|
| homelab | 453 | 388 | 125 | 263 | 224 | 39 | 34 | 12.9 % |
| agent-runtime | 48 | 40 | 40 | 0 | 0 | 0 | 0 | — |
| openrouter-operator | 26 | 20 | 10 | 10 | 6 | 4 | 4 | 40 % |
| agent-coordinator | 0 | — | — | — | — | — | — | — |
| **overall** | **527** | **448** | **175** | **273** | **230** | **43** | **38** | **13.9 %** |

- "Catches (all)" includes 5 mechanical rows with no finding (`other` below: a stale-approval
  dismissal caused by the seat's own conflict-resolution push, or a Renovate pin closed as
  superseded/no-op). Finding ÷ all bot-approved = 38 / 448 = 8.5 %.
- Human-merged (mergedBy `RasmusSoot`) bot-approved PRs: homelab 65, openrouter-operator 5. The
  other human reads are a `RasmusSoot` APPROVED review followed by the armed auto-merge.
- Not in the denominator: 56 homelab + 8 agent-runtime + 6 openrouter-operator machine PRs merged
  with **no bot approval at all** — 37 + 8 + 6 of them created before 2026-08-11 (the seat was
  the sole reviewer until the bot-first flow's first pass, homelab#265), the rest seat-merged
  behind a latch/BEHIND skip or admin-merged (e.g. homelab#1120, #1336, #1453, #1468).

## Per-type counts

| Type | Catches | Share of 43 | Fixed by the seat (in-PR commit / direct-to-master) | Fixed by a fix round | Follow-up issue | Merged anyway (noted) | Closed |
|---|---|---|---|---|---|---|---|
| in-diff-defect | 18 | 42 % | 11 (9 / 2) | 4 (#841→#858, #894→#913→#915, #915, #1404) | 1 (#1514→#1527) | 2 (#995, #1154) | 0 |
| doc-currency | 8 | 19 % | 6 (2 / 4) | 1 (#1397→#1416) | 0 | 1 (#1389) | 0 |
| operator-lane | 3 | 7 % | 3 (1 / 2) | 0 | 0 | 0 | 0 |
| style-polish | 3 | 7 % | 0 | 0 | 0 | 3 | 0 |
| wrong-target | 2 | 5 % | 0 | 1 (#862 round 3) | 1 (#1292→#1297) | 0 | 0 |
| design-fork | 2 | 5 % | 1 (1 / 0) | 0 | 0 | 0 | 1 (#494) |
| vacuous-or-weak-pin | 1 | 2 % | 0 | 0 | 0 | 1 (#567) | 0 |
| scope-footprint | 1 | 2 % | 1 (1 / 0) | 0 | 0 | 0 | 0 |
| governance-gate | 0 | 0 % | — | — | — | — | — |
| other (no finding) | 5 | 12 % | — | — | — | 3 merged | 2 closed |
| **total** | **43** | | **22 (14 / 8)** | **6** | **2** | **10** | **3** |

## Per-catch ledger

Surfaced: HR = human review (state in parentheses), SC = seat commit on the PR branch after the
bot approval, DM = human dismissal of the bot review, CL = human close, CM = human PR comment,
TL = TICK-LOG. "Bot CR before" = the bot had itself requested changes on an earlier round.

| Repo#PR | Catch date | Type | Surfaced | Bot CR before | What (≤20 words) | After |
|---|---|---|---|---|---|---|
| homelab#236 | 08-10 | other | DM | no | Renovate pin auto-approval dismissed by the seat; bot re-approved a minute later; no finding | merged (Renovate) |
| homelab#276 | 08-11 | operator-lane | HR (APPROVED) | no | producer half of the recipe must be pasted into `.agents/fix.yaml` by the seat | seat direct-to-master post-merge |
| homelab#310 | 08-11 | operator-lane | HR (APPROVED) | no | deferred promtool lint hook (scripts/ + CI step) taken as the codeowner step | seat, jail lane |
| homelab#475 | 08-17 | design-fork | SC + DM | yes (1) | seat re-worded the ADR-109 amendment: the ⏸ class is backlog *inventory*, not backlog | seat commit in-PR; round-3 bot governance findings then dismissed with audit message |
| homelab#494 | 08-18 | design-fork | CL + CM | yes (1) | operator ruling: disable Renovate's Dependency Dashboard at source instead of carving it out of the sprout class | closed unmerged |
| homelab#567 | 08-18 | vacuous-or-weak-pin | HR (APPROVED note) | yes (1) | fixture sits at depth 2; the depth-1 runner never executed it — CI green without running it | merged; seat ran it by hand; activates with #569 |
| homelab#668 | 08-19 | other | DM | yes (1) | stale-approval dismissal from the seat's conflict-resolution merge + index regen; no finding | seat admin-merged |
| homelab#727 | 08-20 | in-diff-defect | SC + DM | yes (1) | depth-rule append defined inside the PREP heredoc (prose-in-executing-context); moved outside, injected via declare | seat commit in-PR; bot re-approved |
| homelab#800 | 08-23 | doc-currency | HR (APPROVED) | yes (1) | `agents/README.md` "--recipe (goose + claude; opencode uses --run)" line stale after the change | seat direct-to-master |
| homelab#841 | 08-24 | in-diff-defect | HR (APPROVED note) | no | `clause_files` is a hand copy of the ci.yaml ratchet regex — drift hazard | fix round #858 (its parity check found #841's list already stale by one file) |
| homelab#862 | 08-24 | wrong-target | HR (CHANGES_REQUESTED) | no | diagnosis refuted by Loki: real bug is `local a=… b=${a}` expansion under `set -u`, not the S3 write guard | fix round 3; seat approved 13:06Z |
| homelab#864 | 08-24 | doc-currency | CM (pre-read) | yes (1) | the fix reverses a recorded doctrine sentence (model-routing.md §M10 override rule) not updated in-diff | seat direct-to-master one-liner at merge time |
| homelab#879 | 08-24 | in-diff-defect | HR (APPROVED) + TL | no | `ledger.py:313 retry_storms` exact-membership drops the new `budget-403-*` subclasses — consumer the sweep missed | seat direct-to-master quickfix `2bda99b8` |
| homelab#890 | 08-24 | doc-currency | HR (APPROVED) | yes (1) | two one-token errors: wrong repo in an issue ref, wrong description of the fallback's source | seat direct-to-master |
| homelab#894 | 08-25 | in-diff-defect | HR (APPROVED) + TL | yes (3) | emitter: per-item pushgateway POST clobbers sibling series; since-timestamp re-stamped every push | follow-up #913 → fix round PR#915 |
| homelab#915 | 08-25 | in-diff-defect | HR (CHANGES_REQUESTED) + CM | yes (5) | `$qblockers` never assigned; under `set -u` the first queued issue aborts the whole tick (fleet-wide) | fix rounds 7–8; seat re-approved 08-26; taxonomy notes → #968 |
| homelab#947 | 08-26 | in-diff-defect | HR (APPROVED) + TL | no | retro-r1 F1 filing rule lands without its dedup clause | seat direct-to-master quickfix |
| homelab#955 | 08-26 | doc-currency | HR (APPROVED) | no | comment claims the next harvest READS marker files — no such reader exists; PR-body template duplicated | seat direct-to-master (comment softened) |
| homelab#965 | 08-26 | in-diff-defect | SC + DM + TL | no | admin-metrics belts had no coverage guard — a dead scrape would page nothing (`GarageAdminMetricsAbsent` added) | seat commit in-PR; bot + seat re-approved |
| homelab#995 | 08-26 | in-diff-defect | CM (watch item) | yes (1) | on the kata tier `Unschedulable` is also a queue state — the wedge discount can under-count WIP | merged; recorded as watch item |
| homelab#1112 | 08-31 | other | DM | no | stale-approval dismissal from the seat's conflict-resolution merge (conflicted with #1100); no finding | seat merged |
| homelab#1133 | 08-31 | other | CL | no | Renovate runner-image pin closed unmerged, no comment (superseded by the next pin — guessed) | closed |
| homelab#1146 | 08-31 | style-polish | HR (APPROVED nit) + TL | yes (1) | `reviewable_again` predicate now has a second copy — extract one home if it drifts again | merged; noted |
| homelab#1154 | 08-31 | in-diff-defect | HR (APPROVED nit) + TL | no | reword dropped the ⚠ prefix: a 403 token-scope failure now prints at the volume of an expected 422 race | merged; noted for next touch |
| homelab#1155 | 08-31 | doc-currency | SC + DM + CM + TL | no | five loop-door bullets granted the session "queue immediately / override the inert breaker" — contradicts breaker #1 | seat commit in-PR; bot re-reviewed |
| homelab#1278 | 09-02 | in-diff-defect | SC + DM | no | REMEDIATION-WOULD marker targeted the wrong class (the dial's class) | seat commit in-PR; re-approved at head |
| homelab#1289 | 09-03 | doc-currency | SC + DM + CM + TL | no | `ci-cause:` spec pasted into both plays (three copies) — collapsed to §ci-cause + pointers | seat commit in-PR; breaker cleared by the seat |
| homelab#1290 | 09-03 | in-diff-defect | SC + DM + TL | no | an unreadable `gh pr list` REFUSED dispatch; under the 07:25Z throttle that parks every dispatch — must DEFER | seat commit in-PR |
| homelab#1292 | 09-02 | wrong-target | HR (APPROVED) | yes (1) | mirror probes target `/v2/`; #1282's real incident signature (one poisoned commit) is not what they hit | follow-up #1297; merged |
| homelab#1347 | 09-04 | in-diff-defect | SC + DM + TL | no | `openrouter/*)` special case stripped the rail for cloaked codenames → opencode gets a bare codename | seat commit in-PR; bot re-approved |
| homelab#1352 | 09-04 | scope-footprint | SC + DM + TL | no | stray `worlds/arbitrate/…/--` file (a mis-invoked `--record`'s captured stderr) in the diff | seat commit in-PR |
| homelab#1366 | 09-04 | operator-lane | SC + DM | no | Renovate's runner-image pin lacks the pre-puller DaemonSet site (a pin-only path Renovate does not know) | seat commit in-PR |
| homelab#1386 | 09-05 | in-diff-defect | SC ×2 + DM ×2 + CM + TL | yes (2) | per-repo loop Role lacked `configmaps` verbs → every stack takes the argv fallback, which wrote `bundle.txt` while the card named `index.txt` | subagent + seat commits in-PR; bot re-approved |
| homelab#1389 | 09-05 | doc-currency | HR (APPROVED nit) | no | unit carries `harvest=` for changes-requested but the CR play still describes inert filing only | merged; noted for next README touch |
| homelab#1397 | 09-05 | doc-currency | HR (APPROVED nit) | no | README names `ci.yml`; the workflow is `ci.yaml` | fix round #1416 (docs-only PR) |
| homelab#1404 | 09-05 | in-diff-defect | HR (CHANGES_REQUESTED) + TL | yes (1) | `/packages/` cache can never be hit — PyPI index links artifacts by absolute `files.pythonhosted.org` URL | fix round (sub_filter); bot + seat re-approved |
| homelab#1514 | 09-08 | in-diff-defect | HR (APPROVED) + TL | yes (2) | scan/reflex ESCALATION notices are also line-anchored ARBITRATE comments → newest-wins pick can serve a notice as the directive | follow-up #1527 filed |
| homelab#1562 | 09-09 | in-diff-defect | SC + DM | yes (1) | `directory: {recurse: false}` beside a kustomization.yaml (ArgoCD applies the Kustomization doc itself); probe.py duplicated and diverged | seat commit in-PR; bot re-approved |
| openrouter-operator#55 | 09-01 | in-diff-defect | SC + DM + CM + TL | yes (2) | `read_key_secret` returned base64-raw `V1Secret.data` into `string_data` → NormalizeSecret would double-encode the live credential | seat commit in-PR; bot re-approved |
| openrouter-operator#59 | 09-04 | style-polish | HR (APPROVED nit) + TL | yes (2) | `lastTransitionTime` rewritten on every NoOp pass; Secret name used as condition `reason` | merged; noted |
| openrouter-operator#61 | 09-05 | style-polish | HR (APPROVED nit) | no | comment under `labels:` is a sentence fragment | merged; noted |
| openrouter-operator#65 | 09-05 | in-diff-defect | SC + DM | no | `has_openrouter_key` defaulted `True` — a fail-open default on the very bit the fix introduces | seat commit in-PR; bot re-approved |

### Gate-read catches outside the strict definition (not in the totals)

| Repo#PR | Date | Type | Why outside | What | After |
|---|---|---|---|---|---|
| homelab#1509 | 09-08 | in-diff-defect | seat CHANGES_REQUESTED landed before any bot review | belt keyed on the newest coordinator COMMENT (a `state-fp:` marker), not the newest ruling → re-trip loop; `FU-1507` is not an id | fix rounds 2–3; bot + seat approved |
| homelab#1515 | 09-08 | wrong-target | seat commit landed before the bot approval (round-4 directive executed by hand) | alert keyed on `argo_workflow_info{workflow=~…}` — a metric that does not exist here; rebuilt as `AgentLoopWorkflowsFailing` | seat commit on the branch; bot approved at head |
| homelab#1030 | 08-30 | governance-gate | never bot-approved | governance-lint keys the worker lane on PR author; the coordinator App authors every assembly PR → can never green | closed; re-opened from the same branch |
| homelab#1457 | 09-06 | style-polish | gate not executed (session not corpus-loaded) | env-card "fallback" is manual, not automatic | merged later, nit unactioned (TICK-LOG only) |

## TICK-LOG sightings (grep from the 2026-08-03 heading; 79 raw hits, these name a catch)

| TICK-LOG line | Date | PR(s) named | Sighting | Also on GitHub? |
|---|---|---|---|---|
| 4956 | 08-24 | #879, #873 | "caught + directly fixed the consumer gap the #879 review sweep missed" (quickfix `2bda99b8`); #873's TOOL_GAP answered from tofu source | yes (#879 approval body) |
| 5173 | 08-25 | #894 → #913 | "gate read found two emitter defects" | yes |
| 5563 | 08-26 | #965 | "the seat's own coverage-guard push" | yes |
| 5789 | 08-31 | #1146, #1154, #1155 | two nits + "CAUGHT a governance escape … corrected in-diff" | yes |
| 6147 | 09-01 | openrouter-operator#55 | "the ADR-110 read found a BLOCKING defect three bot rounds missed" | yes |
| 6540 | 09-03 | #1290, #1289 | two in-diff seat fixes | yes |
| 6824 | 09-04 | #1352, #1347 | stray file deleted; "carried a latent bug" | yes |
| 6871 | 09-04 | openrouter-operator#59 | "nit: transition time rewritten every pass" | yes |
| 6954 | 09-05 | #1386 | "held on two in-diff defects" | yes |
| 7024 | 09-05 | #1416, #1404 | #1397's nit landed as #1416; #1404's CR addressed | yes |
| 7353 | 09-06 | #1457 | wording nit, gate not executed | **TICK-LOG only** |
| 7394 | 09-06 | #1466, #1468 | bot block dismissed as a footprint formality; seat landed the escalation's three edits (no bot approval) | yes (override, not a catch) |
| 7882 | 09-08 | #1509, agent-runtime#131 | seat CR on #1509; agent-runtime#131 "one provenance line corrected, admin-merged" — a seat-authored PR (subagent paste), outside scope | #1509 yes; ar#131 **TICK-LOG only** |
| 7967 | 09-08 | #1514 → #1527 | residual filed | yes |
| 7986 | 09-08 | #1515 | "the gate read caught the alert as authored keying on … a metric that does not exist here" | commit + comment on the PR, pre-approval |

The remaining ~60 hits are gate reads recorded as executed with no finding ("all small class",
"merged"), or name seat-authored PRs (#963, #1183, #1436, #1437).

## Observations (facts only, no recommendation)

- **Path clustering.** 28 of the 38 catches-with-a-finding touch `agents/**` (the coordinator
  scan, launcher, briefs, replay fixtures) — the human-tier path with the most machine PRs; 4 are
  openrouter-operator `src/`; 6 are homelab belts/Applications under `argocd/**` (#310, #965,
  #1292, #1404, #1562 — alert/probe rules and Application shape; #965/#1404/#1562 also touch
  `argocd/platform/**`, so they were codeowner-required reads, while #310 and #1292 were Tier-1
  PRs the seat read anyway). 3 catches are prose-only diffs (#890 `docs/agents/model-routing.md`,
  #947 `agents/coordinator/README.md`, #1397 `agents/replay/README.md` — all doc-currency, all
  one-token/one-line). `argocd/resources/**`-only PRs (Tier 1, bot + CI) account for the 125 + 40
  + 10 "no human touch" merges.
- **What the seat fixed itself.** 22 of 38 findings were closed by the seat: 14 as a commit on the
  PR branch (the bot then re-approved at head in every case) and 8 direct-to-master post-merge
  (the bookkeeping/quickfix class). Only 6 went back through a worker fix round; 2 became
  follow-up issues (#1297, #1527 — both still open at the census date); 7 were merged with the
  finding recorded as a nit/watch item (2 in-diff-defect, 1 doc-currency, 1 weak pin, 3
  style-polish).
- **Fix rounds did later fix some seat-noted nits.** #841's duplicated regex → #858 (whose parity
  check then proved the copy stale); #1397's `ci.yml` → #1416 (a docs-only fix-round PR); #894's
  emitter defects → #913 → #915. #1146 (predicate second copy), #1154 (403 lost its ⚠), #1389,
  #995, or#59, or#61 show no later fix in the window.
- **Catches on PRs the bot had already blocked once.** 19 of 43 (17 homelab, 2 openrouter-operator)
  were on PRs with ≥1 prior bot CHANGES_REQUESTED round; the two heaviest (#915 after 5 bot rounds,
  or#55 after 2, #1386 after 2, #894 after 3) were in-diff defects the extra rounds did not reach.
  Conversely 24 catches were on PRs the bot approved in round 1.
- **Severity spread inside `in-diff-defect`.** 6 of the 18 would have been fleet-wide outages or
  data corruption on merge (#915 scan abort under `set -u`, #1290 dispatch refusal under throttle,
  #1386 every stack on the argv fallback, or#55 credential double-encode, or#65 fail-open default,
  #862 the fix would not have resurrected the scout); the rest are single-site logic, a stray
  file, a missing guard, or a lost log prefix.
- **Mechanical rows.** 5 of the 43 "catches" carry no finding: 2 stale-approval dismissals caused
  by the seat's own conflict-resolution push (#668, #1112 — `dismiss_stale_reviews_on_push`), 2
  Renovate pins closed as superseded/no-op (#1133, #1362), 1 re-triggered auto-approval (#236).
  Renovate PRs otherwise: 28 bot-approved, 1 real seat touch (#1366, the pre-puller pin site).
- **The reverse direction.** The seat dismissed a bot CHANGES_REQUESTED as a formality 4 times
  (#275, #547, #1466, #475 round 3) — all footprint/Touches escapes ruled compelled or fixed at the
  issue — and discharged bot/lens follow-up bullets by verification twice (#526, #537). The seat
  also took a bot non-blocking nit as its own post-merge one-liner on #320, #358, #368.
- **Volume.** 263 homelab human reads in 39 days (≈6.7/day) produced 34 findings; 199 of the reads
  are recorded as an APPROVED review body, 69 of which say only "read → merging". agent-runtime's
  40 bot-approved machine PRs were never human-read in the window (0 catches, 0 clean reads).
