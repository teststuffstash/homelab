# platform loop retro r11 — Kimi
## Coverage (window, bundle identity, completeness, late corrections)

- **Window:** 2026-11-02T00:00:00Z through 2026-11-09T00:00:00Z, exclusive. Bundle `38bbe4bf636c36b826cb015212b7b5d81952a1ebc870a18ab5ea434ff9cd43ed`, run `r11`, storage key `platform/runs/20261109T000000Z`, source revision `79eaf00c98f3ca5638e65ffc974ab7f6503ea27a`; prepared 05:00:09Z, collected through 04:30:08Z and covered at 04:30:08.838934Z on November 9.
- **Whole population:** 215 tasks, 2,784 events, 181 failure events, 70 superseded cancellations, 12 agent-pain events, 17 dispatches and 13 stats records. Worker duration was 26,183s; measured-cost records were **0**, so population worker cost is unknown, not zero. Standing open-time exposure was 18,698,310s and is not active work.
- **Completeness:** population counters cover all 215 tasks; 23 ranked task summaries and all 10 emitted ledger rows are serialized. Caps were 40 tasks, eight events/task, 20 late events and 60,000 bytes. I drilled ranks 1–8 across their fleet repositories and checked additional ledger/good-run contrasts. Rates use population denominators, not the worst-K sample.
- **Ledger:** 10 rows (eight done, two blocked), 16 round entries: 11 clean, four deliberate blocks and one no-op. First-touch cells were Sonnet 7 tasks/1 non-clean, Opus 1/0 and Haiku 2/2; both Haiku results were deliberate stop reports, so these small, externally confounded cells do not support a model-quality ranking.
- **Late corrections:** 409 late observations were counted, only 20 serialized. For example, August 30 sleep-iac#80 CI and September homelab#1643/#1906 activity observed in November correct their original periods; none is new r11 work. The other 389 could not be individually classified from this bundle.

## Summary (≤5 lines)

- Bucket-A has an **observed lower bound of 6** distinct platform-control failures; the new-platform-issue-only cell is 0 and the unavailable responder ledger prevents a complete count or a clean trend claim.
- The dominant avoidable costs were dependency-state handling: one stale no-op, 11 origin-PR no-dispatch passes, repeated identical policy reviews, and eight red runs on one shared lock-graph problem.
- Spec work also repeated two small checks: ⚖ row/test-id joins and deployment-aware closing-keyword review; one miss auto-closed #1021 before its production acceptance evidence.
- One-round/first-approval deliveries (#1022 and the independent #924 control) show that narrow observable changes remain a reliable unit; long walls here were predominantly dependency/review idle, not active execution.

## Findings (ranked, ≤6)

### F1 — Origin-PR dependencies have no automatic hold/release, producing both premature work and idle operator waits

**Evidence:** [#1022](https://github.com/teststuffstash/oracle-fleet/issues/1022) tried to make open PR #1018 its native blocker at 09:14 on November 8; GitHub returned 422 because the blocker was a PR. It then incurred **11 no-dispatch coordinator passes**, was parked at 10:50, and still waited for an [operator re-queue at 18:58](https://github.com/teststuffstash/oracle-fleet/issues/1022#issuecomment-6725681188), **5h30m after #1018 merged at 13:28**. Conversely, [#1021](https://github.com/teststuffstash/oracle-fleet/issues/1021) started while origin #1017 was open; round 3 resumed the old branch, spent **21 turns/1,173s**, opened #1031 as a no-op, and had to abandon it for a current-master rebuild in #1032.

**Mechanism:** native `blockedBy` handles issue blockers, but a spec-gap child whose text exists only on an open PR has no trusted machine-readable dependency state. The coordinator therefore either dispatches against a stale base or repeatedly rediscovers the same wait and eventually requires a human release.

**Change:** add one origin-PR precondition to the **coordinator README W1 ⚑ spec-gap/scan dispatch clause**: W1 writes trusted `blocked-on: pr=<owner/repo>#<n>` on the still-queued child; the scan suppresses dispatch while that PR is open and ordinary level-triggered eligibility resumes when it merges. Do not use the human-only `agent/blocked` terminal for this machine wait.

**Expected saving:** the observed **one stale worker no-op + 11 coordinator passes + 5h30m post-dependency idle + one operator re-queue** per comparable pair. The operator touch is **€3–8 in-sitting or €20–30 if it is a lone summons**. Rail 3 avoids 12 subscription rides: cash-amortized steady-state normally cents (marginal ≈$0 under headroom), while API-equivalent list×tokens is unmeasured. No paid-API saving is claimed.

**Confidence:** high on both failure modes; medium on the exact marker implementation, which must respect the trusted-input gate below.

### F2 — Identical dependency-policy holds are re-reviewed on every rebase because currency follows HEAD, not policy inputs

**Evidence:** [sleep-tracking#218](https://github.com/teststuffstash/sleep-tracking/pull/218) received **five in-window CHANGES_REQUESTED reviews** (November [2](https://github.com/teststuffstash/sleep-tracking/pull/218#pullrequestreview-5738227468), [3](https://github.com/teststuffstash/sleep-tracking/pull/218#pullrequestreview-5760654576), [5](https://github.com/teststuffstash/sleep-tracking/pull/218#pullrequestreview-5793534320), and 6 ×[2](https://github.com/teststuffstash/sleep-tracking/pull/218#pullrequestreview-5800905447)); every head had green CI/system-test and the same ADR-158 result: prod Garage v2.3.0 cannot move directly to test v2.5.0. Cross-repo [oracle-fleet#965](https://github.com/teststuffstash/oracle-fleet/pull/965) repeated the same one-line hold until its November 3 [AGENT_ERROR](https://github.com/teststuffstash/oracle-fleet/pull/965#issuecomment-6592200906) explicitly reported a review loop on a human-blocked PR.

**Mechanism:** reviewer currency is head-based. A Renovate rebase changes HEAD without changing the changed-file content, production pin, target pin, ADR revision or human hold, so the reviewer pays to re-derive an already-live verdict. This is distinct from #1977's rebase-writer selector and #2182's push-during-review race.

**Change:** add a **reviewer scan migration-lens rebase-debounce clause**: fingerprint changed-file content **plus** production/target pins, lens/ADR revision and latest human hold; stand aside while that tuple and the live verdict are unchanged, rather than keying only on HEAD.

**Expected saving:** at least **four duplicate r11 reviews** on #218 after its first in-window verdict (five relative to the October 31 baseline), plus avoidance of one #965-style error latch. That latch is **€3–8 in-sitting or €20–30 as an out-of-sitting summons**. Avoided reviewer rides are rail 3: cash-amortized normally cents/marginal ≈$0 under headroom; API-equivalent is unmeasured because tokens are absent. No paid-API amount is inferred.

**Confidence:** high on event counts and unchanged policy; medium on implementation because external policy inputs must be read safely.

### F3 — A WAN-bound pre-PR gate still strands pushed work instead of opening a flagged PR

**Evidence:** [#1021 rounds 1–2](https://github.com/teststuffstash/oracle-fleet/issues/1021#issuecomment-6719615409) both committed and pushed the implementation, with targeted tests/diff-CI green, but `pr-open` refused to open a PR when GitHub snippets-wheel downloads returned 504 ([round 1](https://github.com/teststuffstash/oracle-fleet/issues/1021#issuecomment-6719918245), [round 2](https://github.com/teststuffstash/oracle-fleet/issues/1021#issuecomment-6720238280)). At 10:18 the coordinator correctly [withheld a third identical ride](https://github.com/teststuffstash/oracle-fleet/issues/1021#issuecomment-6720265172) and filed homelab#3214. This extends r10's #1563/#1571 mechanism rather than treating the later code correction as erasing it.

**Mechanism:** the worker recipe has no explicit route for a gate that is WAN-bound and unavailable from the pod but runnable by CI. Useful work remains PR-less and consumes another resume/triage cycle.

**Change:** retain the r10 candidate in the **worker recipe pre-PR gate step**: a positively identified WAN-bound gate may be skipped and named as unrun in the PR, which CI must run; other red gates still block. This complements, not replaces, the targeted wheel cache/API fallback in #3228.

**Expected saving:** conservatively **one repeat worker ride** on #1021 and one dependency triage item; if that item causes a lone summons, **€20–30**, otherwise **€3–8 in-sitting**. Subscription cash-amortized saving is normally cents (marginal ≈$0 under headroom), API-equivalent is unmeasured, and no billed OpenRouter dollars are available. Savings are valid only if CI actually executes the flagged gate.

**Confidence:** high on the recurrence; medium on generic skip-and-flag safety. #3225/#3227/#3228 are targeted remediations and one successful ride is not effectiveness evidence for the generic route.

### F4 — A leading `Fixes` still defeats deployment-aware acceptance review

**Evidence:** on [#1013](https://github.com/teststuffstash/oracle-fleet/pull/1013), review at 17:17 on November 7 caught a leading `Fixes #1012` beside an unchecked production-Prometheus row; changing it to `Refs` kept #1012 open until real production evidence was pasted at 17:41. One day later [#1032](https://github.com/teststuffstash/oracle-fleet/pull/1032) again began `Fixes #1021` despite a later `Refs` line and unchecked production-call row. The code review mistook the later line for the whole body; merge closed [#1021](https://github.com/teststuffstash/oracle-fleet/issues/1021) within one second at 19:12:38Z and the [closeout belt marked done](https://github.com/teststuffstash/oracle-fleet/issues/1021#issuecomment-6725900204), with no production answer in the subsequent trail.

**Mechanism:** the reviewer checks for the presence of `Refs` rather than parsing all closing keywords together with acceptance state. The label reconciler can correct labels but cannot restore the missing deployment opportunity.

**Change:** make **reviewer rubric item 9 (acceptance/closeout)** a hard, whole-body check: any recognized closing keyword anywhere in the body is blocking while a required deployment/verification acceptance row remains unchecked; a later `Refs` does not cancel an earlier `Fixes`.

**Expected saving:** one body-only review cycle like #1013 and up to one manual reopen/reconciliation per #1021-like recurrence: **€3–8 in-sitting or €20–30 if separately summoned**. Any avoided reviewer ride is rail 3, cash-amortized normally cents and API-equivalent unmeasured. The larger benefit is preserving the required production-evidence gate, not an asserted worker saving.

**Confidence:** high on the body, timestamps and missing subsequent evidence; the actual eventual operator cost is not yet observed.

### F5 — Deterministic shared-lock guard reds still rely on coordinator override for consistent terminal handling

**Evidence:** openrouter-operator [#110](https://github.com/teststuffstash/openrouter-operator/pull/110) and [#111](https://github.com/teststuffstash/openrouter-operator/pull/111) each had **four failed r11 CI runs**. Both were the same STRICT `deps-pin-guard` class: virtualenv gained `packaging`, `python-discovery` dropped `platformdirs`, and #111 also resolved a different virtualenv version. The [correct #110 ruling](https://github.com/teststuffstash/openrouter-operator/pull/110#issuecomment-6672207076) parked it and filed [#113](https://github.com/teststuffstash/openrouter-operator/issues/113); the [correct #111 ruling](https://github.com/teststuffstash/openrouter-operator/pull/111#issuecomment-6672141723) dispatched no worker but left neither blocked label nor tracking issue. By contrast, #105's codeload 429 was environmental: one rerun passed and it merged in about six minutes.

**Mechanism:** G12b's broad armed-red worker-first route does not distinguish an environmental red from a deterministic ownership guard. Human judgment prevented waste this time, but the two shared-graph items received inconsistent terminal states and duplicate review surfaces.

**Change:** split the **coordinator README G12b armed-red play** before worker dispatch: environmental → existing one-rerun rule; deterministic dependency-ownership guard → no worker, consistent `agent/blocked`/hold, and one deduplicated owned-route issue linking all PRs for that shared lock graph.

**Expected saving:** no historical worker saving is claimed—the coordinators already avoided it. On a comparable pair this caps the downside at **two avoided worker dispatches** and batches two human remediation reads; one avoided separate sitting saves its **€17–25 fixed entry**, otherwise **€3–8 per in-sitting item**. Subscription cash-amortized draw would normally be cents/marginal ≈$0 under headroom; API-equivalent and paid-API savings are unmeasured.

**Confidence:** high on the shared mechanism and inconsistent terminals; medium on future savings and on keeping one issue per graph rather than per package.

### F6 — Judgement markers repeatedly reach review without the exact row/test-id join

**Evidence:** [#1013](https://github.com/teststuffstash/oracle-fleet/pull/1013) and [#1032](https://github.com/teststuffstash/oracle-fleet/pull/1032) each recorded ⚖ in prose/`Spec changes` but omitted it from the row description and matching test id. #1032's 18:04 specs CR required exactly that one-line correction; [round 5](https://github.com/teststuffstash/oracle-fleet/issues/1021#issuecomment-6719615409) implemented it before two approvals at 18:48/18:50. #1013's first correction loop also contained other findings, so it is corroboration, not a wholly attributable round.

**Mechanism:** workers validate semantics and prose but lack a pre-PR mechanical join check for the judgement marker's three representations. Review remains the first place the exact string equality is exercised.

**Change:** add to the **fix-round recipe pre-PR spec/test join check**: for every ⚖ judgement in prose or `Spec changes`, require the same ⚖-bearing description cell and character-identical test case id before opening/updating the PR.

**Expected saving:** **one certainly attributable worker round and two re-reviews** on #1021, with up to one similar shared correction loop on #1012. This is rail 3 only: cash-amortized steady-state normally cents (marginal ≈$0 under headroom); API-equivalent list×tokens is unmeasured; **no rail-1 or paid-API saving is claimed**.

**Confidence:** high on #1021 and on the repeated miss; medium on extrapolating beyond these two tasks.

## Proposed process changes (table: change | artifact | expected saving | confidence)

| change | artifact | expected saving | confidence |
|---|---|---|---|
| Hold/re-release spec-gap children on trusted origin-PR state | `agents/coordinator/README.md` W1 ⚑ spec-gap + scan dispatch precondition | 1 stale no-op + 11 passes + 5h30m idle + one €3–8/€20–30 operator touch; rail-3 cash normally cents, API-equivalent unmeasured | High evidence; medium implementation |
| Debounce migration-lens reviews on content + external policy inputs | Reviewer scan rebase-debounce clause | ≥4 duplicate reviews; possible €3–8/€20–30 latch touch; rail-3 cash cents, API-equivalent unmeasured | High evidence; medium implementation |
| Skip-and-flag only positively identified WAN-bound pre-PR gates | Worker recipe pre-PR gate step | 1 repeat ride + one €3–8/€20–30 triage item, conditional on CI running the gate; both rail-3 prices unmeasured/cash normally cents | High recurrence; medium safety |
| Reject any closing keyword with unchecked required deployment evidence | Reviewer rubric item 9 | One body-only review cycle and up to one €3–8/€20–30 reconciliation; rail-3 cash cents, API-equivalent unmeasured | High |
| Route deterministic lock-ownership reds to one shared blocked/owned-route track | `agents/coordinator/README.md` G12b armed-red play | Future cap: 2 worker rides; €17–25 if one sitting is avoided, else €3–8/item; rail-3 cash cents/API-equivalent unmeasured | High mechanism; medium saving |
| Check ⚖ equality across prose, row description and test id before PR | Fix-round recipe pre-PR spec/test join | 1 worker round + 2 re-reviews certain on #1021; rail 3 only, cash cents/API-equivalent unmeasured | High on #1021; medium recurrence |

## Task granularity (per deep-dive task: chunked-right / should-have-been-one / fan-out — evidence)

| Rank / task | Judgment | Evidence |
|---|---|---|
| 1 — oracle-fleet#1021 | **chunked-right** at issue scope | The runtime error payload/schema/row correctly stayed out of shape-only #1017. Five dispatches were not five useful chunks: two infra stops, one stale-base no-op, one rebuild and one marker fix. #1031→#1032 was execution rework, not evidence for a larger model or more fan-out. |
| 2 — oracle-fleet PR#1017 | **fan-out**, correctly bounded | A statute/wire-ledger restyle chunk with two first-pass approvals. Integration (master merges, restoring #1015 test hunks, success-envelope test) preceded formal review; children #1021/#1024 owned gaps before review, avoiding #1018's unfiled-gap loop. |
| 3 — oracle-fleet#1022 | **chunked-right** | One harness assertion + expected cell + emitter was one real worker round with two first-pass approvals. The 11 no-dispatch passes and 5h30m wait were dependency friction, not in-chunk rework. |
| 4 — oracle-fleet PR#1018 | **fan-out**, with real integration rework | Eight review submissions represented three substantive CR loops. In-chunk work fixed row cells/emitter parameters/`supported_protocols`; integration-only work replaced shared `CURRENT_KEYS` round bookkeeping with metrics-specific begin/end handling. Children #1022/#1023 were appropriate separations. |
| 5 — sleep-tracking#218 | **chunked-right** | A one-line Garage test pin is the right Renovate unit; production re-vendoring is a separate platform task. Five green-head policy CRs were review/hold churn, not cross-chunk integration. |
| 6 — openrouter-operator#110 | **should-have-been-one** for owned remediation with #111 | The original Renovate unit was reasonable, but four red runs and the shared virtualenv/packaging/python-discovery graph require one coherent lock-graph repair, not separate transitive edits. |
| 7 — openrouter-operator#105 | **chunked-right** | One hook patch, one environmental setup retry, then merge in ~6 minutes. No worker or integration chunk justified fan-out; cancelled approve jobs were concurrency, not extra failures. |
| 8 — openrouter-operator#111 | **should-have-been-one** for owned remediation with #110 | Four red runs expressed the same graph problem and its virtualenv resolution drifted from #110. Batch the owned remediation; do not fan out packaging/python-discovery hunks. |

## Wins to codify (or "none observed")

- **Good deep-dive control — #1022→#1035:** one real Sonnet dispatch and first-pass code/specs approvals. Reusable procedure: name one observable metric outcome, read `/metrics` directly to avoid Prometheus scrape raciness, update harness + expected spec cell + emitter in one diff, and use kind e2e as image-level proof.
- **Independent GOOD spot-check — #924→#1003:** one dispatch on November 2, first-pass code/specs approvals at 20:58/21:01, merged at 21:16; #974→#1004 and #999→#1000 showed the same pattern. Narrow, row-shaped acceptance remains a good sizing signal, not a basis for model ranking.
- **File gap owners before review:** #1017 created #1021/#1024 before its first review and passed; #1018 initially carried `work: unfiled` and burned an avoidable scope loop. Preserve this in W1 while adding F1's origin-PR dependency hold.
- **Environmental/content distinction:** #105 followed the existing environmental-one-rerun rule and avoided a worker; #110/#111 correctly recognized deterministic guard reds. Codify the split rather than weakening `deps-pin-guard`.

## Platform KPIs (bucket-A count · trend · proposed next gate)

**Bucket-A: ≥6 observed platform-logic failure events, a lower bound; new homelab defect-issue-only count: 0.** The six distinct control-path failures, counted once rather than per comment/review, were: [#3197](https://github.com/teststuffstash/homelab/pull/3197) (body edit held a specs CR), [#3198](https://github.com/teststuffstash/homelab/pull/3198) (`Refs` PR lost issue/acceptance context), [#3200](https://github.com/teststuffstash/homelab/pull/3200) (one failed retro run; two contributing defects counted once), [#3203](https://github.com/teststuffstash/homelab/pull/3203) (outsider input reached privileged worker context), [#3208](https://github.com/teststuffstash/homelab/pull/3208) (retro credential write-scope mismatch), and [#3213](https://github.com/teststuffstash/homelab/pull/3213) (outsider `ARBITRATE` crossed scan control). All already have fixes/regression work and are not refiled above.

**Trend:** prior reported cells are **13 → 13 → 14 → 8 → 6**, with r11's observed floor **≥6** mechanically flat at six. The issue-only cell is **6 → 0**, but that is not an improvement claim: r10 was issue-only, r11's six are PR-documented, prior cells used mixed methods, and the responder ledger is missing. A like-for-like trend and the ADR-103 sustained-non-fall trigger therefore remain unresolved rather than being inferred from the zero.

**Proposed next gate:** one **trusted-control-input replay gate** across `agents/agent-session.sh` and `agents/coordinator-scan.sh`. For every marker consumer, inject an outsider/`NONE` comment and prove it cannot dispatch, suppress, debounce, fingerprint or release a hold; trusted Apps and OWNER/MEMBER/COLLABORATOR inputs must still work, and author-type probe failure must safe-hold. This is the highest-recurrence unguarded class: #3203/#3213 fixed two paths, while [#3147's November 8 handoff](https://github.com/teststuffstash/homelab/pull/3147#issuecomment-6720285470) records release of `blocked-on: human` by any non-loop comment plus roughly 20 still-untrusted marker reads. Extend #3147; do not duplicate #3203/#3213.

## Predecessor score (deployment evidence and opportunities, or "insufficient evidence")

- **Closeout reconciliation #3101 — deployed November 1; positive directional evidence, not a rate claim.** After #1032 merged, #1021 moved from closed/stale review to `agent/done` at 19:15:59Z. This is a third observed success after r10's two, although F4 shows that label reconciliation cannot prove deployment acceptance.
- **PR-less fleet-fault un-latch #3096 — deployed; insufficient effectiveness evidence.** Known opportunities #1563/#1571 remain latched because cause #3091 remains open, so the un-latch correctly cannot fire. **OOM root/attended-strike #3102 — partial deployment; insufficient evidence:** no suitable r11 OOM recurrence was found and unattended residual #3094 remains open.
- **Python-minor fleet hold, PR-keyed `launch-failed`, general capacity deferral and parked-Renovate repair suppression — not deployed at the source revision; insufficient effectiveness evidence.** #2601/#3095/#3094 remain relevant existing work. The parked/review mechanism did recur on #965, so absence of deployment is not scored as success.
- **WAN-bound skip-and-flag — not deployed generically; the process failure recurred on #1021.** #3225/#3227/#3228 are targeted remediations; #3228's successful cached-wheel/API-fallback ride is one positive opportunity for that targeted fix only. **Insufficient evidence** for the generic candidate or a fleet effectiveness rate.
- **Harness-follows-cell #2883 and named-series retro fixes #3200/#3208:** merged deployment is established, but suitable post-deployment opportunities are absent or too new (#3208's first write-capable opportunity is scheduled for November 11). **Insufficient evidence**, not proof from merge alone.

## Evidence confidence (what you could NOT verify and why)

Authenticated `gh` reads succeeded across homelab, oracle-fleet, sleep-tracking and openrouter-operator; no relevant repository was unreachable. Review rounds were counted from issue/PR trails. PR open→merge timestamps and dependency waits were used to qualify wall time rather than treating open time as active work.

The known ledger blind spots apply once: `reviewer_rounds` is unreliable; `wall_time_s` has no active/idle decomposition; `retry_storms` omits in-session retries; and zero subscription/Haiku cost means **untracked**, not free. The bundle contains no worker sessions, deployment harvest or token-cost coverage. Consequently paid OpenRouter savings are not invented, and rail-3 API-equivalent prices cannot be numerically computed; cash-amortized prices are described by the required monthly-fee/window-share model rather than presented as measured bills.

TOOL_GAP: responder ledger — needed to count non-GitHub bucket-A events, so ≥6 is a lower bound and no complete trend is claimed.

TOOL_GAP: collector state artifact via s5cmd — needed to inspect the 389 late observations omitted from the serialized bundle; the read timed out.

TOOL_GAP: gh run log archive — needed to independently retrieve the full deps-pin-guard/codeload logs; archive reads timed out, so those mechanisms rely on dated coordinator rulings, attempt records and #113's quoted output.

All findings are candidates, not accepted work. Human acceptance and a fresh pre-queue check are required; any accepted process-change children belong under the label-inert `retro-batch` lineage, never an automatically launched Goal. Publication does not authorize execution.

BEGIN-RETRO-FINDINGS
```retro-findings-json
{"schema_version":1,"findings":[{"mechanism":"spec-gap-child-origin-pr-dependency-is-not-reconciled","surface":"agents/coordinator/README.md W1 spec gap-flags / origin-PR scan hold","summary":"Oracle#1021 burned a stale-base no-op while #1022 made 11 no-dispatch passes and waited 5h30m for operator re-queue; hold queued gap children on trusted origin-PR state and release automatically on merge.","evidence":["https://github.com/teststuffstash/oracle-fleet/issues/1021","https://github.com/teststuffstash/oracle-fleet/issues/1022"],"related_work":[]},{"mechanism":"dependency-policy-review-currency-follows-head-not-policy-inputs","surface":"reviewer scan migration-lens rebase debounce","summary":"Sleep#218 emitted five identical in-window ADR-158 change requests and Oracle#965 latched agent/error on the same cross-repo policy hold; fingerprint content plus production/target pins, ADR revision and human hold instead of HEAD alone.","evidence":["https://github.com/teststuffstash/sleep-tracking/pull/218","https://github.com/teststuffstash/oracle-fleet/pull/965"],"related_work":["https://github.com/teststuffstash/homelab/issues/1977","https://github.com/teststuffstash/homelab/issues/2182"]},{"mechanism":"wan-bound-pre-pr-gate-strands-finished-work","surface":"worker recipe pre-PR gate step","summary":"Oracle#1021 rounds 1-2 pushed useful changes but could not open a PR when WAN snippets-wheel fetches failed; allow only positively identified WAN-bound gates to be skipped, flagged and run by CI.","evidence":["https://github.com/teststuffstash/oracle-fleet/issues/1021","https://github.com/teststuffstash/homelab/issues/3214"],"related_work":["https://github.com/teststuffstash/homelab/issues/3088","https://github.com/teststuffstash/homelab/issues/3091","https://github.com/teststuffstash/homelab/pull/3228"]},{"mechanism":"unchecked-deployment-acceptance-auto-closes-via-leading-fixes","surface":"reviewer rubric item 9 acceptance/closeout","summary":"PR#1013 caught a leading Fixes beside unchecked production evidence but PR#1032 repeated it and auto-closed #1021; reject any closing keyword anywhere in the body while required deployment evidence remains unchecked.","evidence":["https://github.com/teststuffstash/oracle-fleet/pull/1013","https://github.com/teststuffstash/oracle-fleet/pull/1032","https://github.com/teststuffstash/oracle-fleet/issues/1021"],"related_work":["https://github.com/teststuffstash/homelab/pull/3101"]},{"mechanism":"deterministic-lock-guard-red-is-routed-as-adaptable-pr","surface":"agents/coordinator/README.md G12b armed-red play","summary":"Openrouter#110/#111 each had four red runs from one shared dependency-graph guard but received inconsistent terminal handling; split deterministic ownership reds from environmental retries and use one deduplicated blocked owned-route issue per graph.","evidence":["https://github.com/teststuffstash/openrouter-operator/pull/110","https://github.com/teststuffstash/openrouter-operator/pull/111"],"related_work":["https://github.com/teststuffstash/openrouter-operator/issues/113","https://github.com/teststuffstash/homelab/pull/2995"]},{"mechanism":"spec-judgement-marker-omitted-from-row-and-test-id","surface":"fix-round recipe pre-PR spec/test join check","summary":"Oracle#1012/#1021 both omitted the judgement marker from the exact row/test-id join; add a pre-PR equality check across prose, description cell and test case id.","evidence":["https://github.com/teststuffstash/oracle-fleet/pull/1013","https://github.com/teststuffstash/oracle-fleet/pull/1032"],"related_work":[]}]}
```
END-RETRO-FINDINGS
