# platform loop retro r10 — Kimi

## Coverage (window, bundle identity, completeness, late corrections)

- **Window:** 2026-10-19T00:00:00Z through 2026-11-02T00:00:00Z, exclusive. Bundle `b50aa06125a889070f789ef99e3fe7a9582e5a928a05e09d9633be17a901deaf`, run `r10`, storage key `platform/runs/20261102T000000Z`, source revision `54e9343897d71dff97302c32954b3965bbdd2be0`; collected through 04:30:07Z and covered at 04:30:08Z.
- **Whole population:** 759 tasks, 10,814 events, 555 failure events, 257 superseded cancellations, 43 agent-pain events, 74 dispatches and 37 stats records. Worker duration was 50,196s; only one population stats record carried measured cost, totaling **$0.0144**. Standing open-time exposure was 12,523,132s; it is waiting exposure, not a failure verdict.
- **Completeness:** population counters cover all 759 tasks and all 38 ledger rows, but only 24 ranked task summaries and 25 ledger rows are serialized. Caps were 40 tasks, eight events/task, 20 late events and 60,000 serialized bytes. Rates below therefore use population denominators, not the worst-K sample. Authenticated reads succeeded across the relevant fleet repositories.
- **Late corrections:** 1,471 late observations were counted, with 20 serialized. They correct their original periods—for example, August activity on homelab#538/#818 observed in October—and are not new r10 work or worker rounds.

## Summary (≤5 lines)

- Bucket-A is **6**, down from 8: **13 → 13 → 14 → 8 → 6**; this is an issue-only lower bound because the responder ledger was unavailable.
- The 38-row ledger contains 65 round entries: 27 clean and 38 non-clean; small, harness-confounded model cells do not support a model-quality ranking.
- Python 3.15 still caused fleet-wide repeated integration work, while circles#124 supplied two more in-window no-launch dispatches.
- ShellCheck caused seven OOMKilled rides across four tasks; its root fix shipped, but unattended terminal-pod strike recording remains open.
- Several good controls shipped or recurred: content-hash debounce, foreign-commit rebase protection, first-approval scoped spec work, and closeout reconciliation.

## Findings (ranked, ≤6)

### F1 — Python minors still lack a fleet hold, so each repository repeats the same version-set ruling

**Evidence:** four of eight deep-dives were Python 3.15 PRs: homelab#2610, oracle-fleet#883, allure-behavior-snippets#36 and circles#124, with **76 bundle failure events combined**. Homelab#2610 required six further in-window rebase repairs before a seat moved the complete set on October 28; oracle-fleet#883 independently repeated the flake-ref/full-set integration and ran 2,124 tests. Allure#36 remained blocked on the cp315/musl/`gcc` adaptation, and circles#124 was closed only when #129 carried the complete set. These are instance resolutions, not deployment of the fleet hold.

**Mechanism:** per-repository Renovate proposals can become actionable before the shared devbox/image/lock version set can move. Existing set assertions detect disagreement after proposal; they do not hold the proposal class behind the fleet’s stable-nixpkgs decision.

**Change:** extend r9 F1: add the proposed `python`/`uv:python*` minor docker-tag `dependencyDashboardApproval` rule to **`renovate-global.json packageRules`**, recording the un-park condition. Do not refile the already completed per-repository integrations.

**Expected saving:** the three observed r10 operator touch items—homelab un-park, oracle/circles integration batch, and allure disarm—would collapse toward one dashboard decision. That is **€9–24 if handled in-sitting**, or up to **€60–90 only if each was a separate out-of-sitting summons**; six homelab repair rides are rail-3 spending, normally cents and currently untracked.

**Confidence:** high on recurrence and absence of the rule at the bundle revision; medium on operator-time sizing.

### F2 — PR-keyed no-launch rounds still evade the phantom reaper

**Evidence:** circles#124’s October 19 round 4 followed three older attempts that left no worker pod or push; October 20’s round 5 then identified the concrete launcher mismatch: `--task pr-124` was refused because the launcher requires `issue-<N>`. Thus there were **two more in-window dispatches** after r9’s three, rather than merely importing old rounds. The eventual human replacement was #129.

**Mechanism:** C4/C5 requires “no live pod, no open PR, no merged PR.” For a PR-keyed unit, its own open PR falsifies that predicate even when no pod, ride, stats or strike ever existed. Launch failure therefore produces neither reconciliation nor the strike needed for model/cell switching.

**Change:** retain r9 F2’s exact proposal in **`agents/coordinator-scan.sh` C4/C5**: a persisted PR-keyed dispatch with no newer `agent-ride`, stats or strike becomes `error_class=launch-failed`; the existing identical-pair invariant handles repetition. No `launch-failed` leg was present at the source revision; #3106’s no-op rerun handles a different, completed-round case.

**Expected saving:** two r10 coordinator dispatches and recurrence of a silent multi-day stall; chiefly **rail 1**, avoiding one out-of-sitting discovery worth approximately **€20–30**, with any resulting triage normally a **€3–8 in-sitting item**. Subscription savings are unmeasured.

**Confidence:** high on the missing state transition and launcher refusal.

### F3 — Rail capacity is still being converted into human-first model strikes

**Evidence:** homelab#3095 latched `error_class=unknown` across **three issues: #1941, #2589 and #3087**. The preserved #3087 tail contains the literal `Error: Go usage limit exceeded` after useful work and a pushed branch. The same model/rail/window supports the capacity hypothesis for #1941, but its transcript was not read, so only #3087 is confirmed literal evidence.

**Mechanism:** this is r9 F3’s capacity-as-model-fault mechanism with a new quota spelling. An `unknown` model strike cannot represent “pause this rail until quota resets”; it instead creates a fleet fault and blocks otherwise salvageable tasks.

**Change:** extend the existing #2601 substance in the **coordinator README Invariants identical-pair strike rule / `agent-finalize` rate-limit class**: classify the observed Go-quota literal as rail-capacity/defer, not `unknown`, and do not consume a logic round or reselect another model on the exhausted rail.

**Expected saving:** one three-issue fleet-latch triage per comparable quota window: **€20–30 if it causes a lone summons, or €3–8 in-sitting**; avoided retry/subscription draw is not quantifiable from the bundle.

**Confidence:** high for #3087’s classification; medium for the other carriers.

### F4 — An unattended OOMKilled worker still has no surviving strike writer

**Evidence:** #3094/PR#3102 records **seven OOMKilled rides across #1973, #1941, #2588×2 and #3048×3**. ShellCheck’s dataflow pass peaked at 4,356MiB inside 4Gi pods. #2588 lost locally committed work and repeated a roughly 48-minute ride; #3048 demonstrated that the spike also occurred on the Anthropic rail, refuting a model/context-only explanation.

**Mechanism:** finalization dies with the worker container. PR **#3102 merged November 1** and fixed the ShellCheck spike plus launcher-attended `oom` classification, but explicitly leaves the unattended case open: the coordinator launcher usually dies with its pod, while the scan’s terminal-pod reader survives.

**Change:** only the residual remains: have **`agents/coordinator-scan.sh` C4/C5’s existing `TPODS` terminal-pod belt** emit the `oom` strike for an otherwise unrecorded OOMKilled ride. Do not refile the shipped ShellCheck fix or claim that external salvage can recover the dead container.

**Expected saving:** no saving is claimed for the seven historical rides or for #3102’s already shipped root fix. The residual converts future unattended kubectl discovery into routed triage, avoiding up to one **€20–30 out-of-sitting summons** per incident; repeat-ride and subscription savings are contingent and unpriced.

**Confidence:** high on the residual; post-#3102 recurrence is unmeasured.

### F5 — The parked-Renovate repair selector still ignores the human gate

**Evidence:** after homelab#2610’s October 18 park, its agent summary records **six r10 DIRTY-Renovate rebase requests**: October 20 ×2, October 21, October 22 ×2 and October 27. This extends r9 F4’s cross-PR mechanism rather than rediscovering it. The current `renovate-rebase-tick` selector excludes `agent/error` and `agent/arbitrate`, but not `agent/blocked`.

**Mechanism:** the repair writer treats a human-parked dependency PR as an ordinary dirty Renovate branch, repeatedly ticking a rebase whose result cannot satisfy the park condition. Allure#36’s content-hash debounce and sleep-tracking#199’s foreign-commit `Edited/Blocked` state are useful contrasts: those controls avoided this particular repeat-ride shape.

**Change:** make **`agents/coordinator-scan.sh`’s `renovate-rebase-tick` selector skip `agent/blocked`**, leaving a report-only hold. Un-parking already changes the label/state and restores normal eligibility.

**Expected saving:** **rails 2–3 only:** six observed repair rides plus associated CI on this PR, normally cents in amortized subscription terms; exact paid tokens are unavailable. **No rail-1 saving is claimed.**

**Confidence:** high on evidence and low on monetary value.

## Proposed process changes (table: change | artifact | expected saving | confidence)

| change | artifact | expected saving | confidence |
|---|---|---|---|
| Dashboard-hold Python minor image/`uv:python*` proposals until the fleet version set can move | `renovate-global.json packageRules (python docker-tag minor)` | Rail 1: €9–24 in-sitting across three observed touches; up to €60–90 if all were lone summons. Rail 3: six repair rides, cents/untracked | High mechanism; medium saving |
| Turn a persisted PR-keyed dispatch without ride/stats/strike into `launch-failed` | `agents/coordinator-scan.sh C4/C5 phantom agent/in-progress rule` | Two r10 dispatches; avoid one €20–30 discovery summons; subsequent triage €3–8 in-sitting | High |
| Treat the confirmed Go quota literal as capacity/defer, extending #2601 | `coordinator README Invariants identical-pair strike rule / agent-finalize rate-limit class` | One three-issue latch triage: €20–30 lone or €3–8 in-sitting; retries unpriced | High on #3087; medium fleet-wide |
| Emit an external `oom` strike from terminal-pod state when no launcher survived | `agents/coordinator-scan.sh C4/C5 TPODS belt` | Residual detection only: up to €20–30 per unattended incident; no claim for shipped root-fix savings | High residual; recurrence unknown |
| Suppress DIRTY-Renovate repair while `agent/blocked` | `agents/coordinator-scan.sh renovate-rebase-tick` | Rails 2–3 only: six repair rides plus CI, normally cents | High evidence; low value |

## Task granularity (per deep-dive task: chunked-right / should-have-been-one / fan-out — evidence)

| Rank / task | Judgment | Evidence |
|---|---|---|
| 1 — homelab#2610 | **should-have-been-one** | Docker-only proposal required devbox JSON/lock, pyproject/ruff and uv-lock integration. Zero worker rounds; the seat ultimately delivered the set as one coherent change with 943 tests. |
| 2 — oracle-fleet#883 | **should-have-been-one** | The image proposal again required build/runtime bases, devbox, pyproject and locks together. The final single integrated change passed 2,124 tests and received both approvals; no evidence favors fan-out. |
| 3 — allure-behavior-snippets#36 | **should-have-been-one** | Image selection and its build adaptation are one deliverable: cp315 musl lacks the wheel and the fallback needs `gcc`. No fixer lane or worker rounds existed, so there was no cross-chunk agent rework to price. |
| 4 — homelab#2819 | **should-have-been-one** | Chart and engine digest were born split: digest 2.4.3 with `targetRevision` 2.4.2 made `xr-render` red by construction. Moving both together produced green CI and first approvals. |
| 5 — homelab#2798 | **chunked-right** | One deliberately non-merging experiment carried one hypothesis through grant/gate iterations to a green kind run with **61 PASS/0 FAIL**. No agent rounds or integration chunks justify splitting it further; its 962,724s standing stall is not active work. |
| 6 — sleep-tracking#199 | **should-have-been-one** | Playwright lock and image pin are one version set. One clean DeepSeek round restored the lock members while preserving unrelated maintenance; the worker appropriately noted that this did **not** explain the Grafana connection refusal. |
| 7 — homelab#2821 | **chunked-right** | Separating the #2819 instance repair from the Renovate cooldown policy fix was useful isolation, not artificial chunking. #2886 made the targeted chart-index exception; zero worker rounds were burned on cross-chunk integration. |
| 8 — circles#124 | **should-have-been-one** | Five dispatch attempts, including two r10 no-launches, never produced the required full-set change. Replacement #129 carried Dockerfile, devbox, pyproject and lock together; a larger coherent task, not more fan-out, was the appropriate unit. |

## Wins to codify

- **Good-run contrast — oracle-fleet#984 → PR#995:** one Sonnet round, clean CI, both reviews approved on their first verdicts, then merge. The reusable procedure is a narrowly scoped issue enumerating five observable deliverables, an explicit allowed `⚑ gap` alternative, spec/test updates in the same diff, and acceptance greps. Subscription tokens were recorded but cash/API-equivalent savings cannot be inferred.
- **Causal honesty with mechanical repair — sleep-tracking#199:** restore the version set, run the suite, and separately state when the observed connection failure remains unexplained. Codify that distinction in the fix-round recipe rather than forcing a false root-cause narrative.
- **Debounce and ownership controls:** allure#36’s `state-fp` prevented repeated unarmed-major rides despite subsequent CI churn; sleep#199’s foreign-commit notification stopped Renovate from rebasing away an adaptation. Preserve both when changing the parked-PR selector.
- **Measured infrastructure diagnosis — #3102:** base reproduction, Prometheus memory shape, a 10Gi control, and equal 145-finding lint output isolated ShellCheck without blaming a model. Its reported whole-tree peak fell to 347MiB, although post-deployment effectiveness still needs opportunities.

## Platform KPIs (bucket-A count · trend · proposed next gate)

**Bucket-A: 6, a defensible platform-issue count and lower bound** against the full responder-ledger-plus-issues definition. Counted once per newly filed in-window defect issue, not per comment or repeated ride:

| Class | Issues |
|---|---|
| Scan lifecycle/holds | #2808 closed review-only closeout; #3048 PR-less fleet-fault un-latch; #3139 invisible `blocked-on: human` hold |
| Launch/admission/worker containment | #2870 explicit-harness admission; #3002 struck-cell reselection; #3094 OOM containment |

Excluded were product/build work, alerts/model scouts, dependency policy #2821, CI/replay-only defects #2757/#3088/#3092, and deduplicated fleet-strike carriers #3091/#3095. Older active defects were context, not new r10 events.

**Trend:** **13 → 13 → 14 → 8 → 6**, down 2/25% and a second consecutive fall; the sustained-non-fall ADR-103 trigger is not active. Comparability caveat: r9 included one unfiled live defect, whereas this count is issue-only.

**Proposed next gate:** recurrence is tied 3/3. Choose a **scan lifecycle/hold state-space replay** covering closed `agent/review`-only issues, PR-less fleet-fault latches and `blocked-on: human` label/un-latch states, asserting exactly one owner or explicit hold. It extends r9’s state-axis work, regression-pins #2808/#3048’s shipped fixes, and leaves #3139’s still-open state visible.

TOOL_GAP: responder ledger — needed to count any non-GitHub bucket-A defect events, so 6 is a lower bound.

## Predecessor score (deployment evidence and opportunities, or "insufficient evidence")

- **r9 F1 — not deployed:** the proposed Python dashboard hold remained absent at the source revision. Four r10 instances recurred and were resolved individually; therefore **insufficient evidence of effectiveness**, not a successful deployment.
- **r9 F2 — not deployed:** no PR-keyed `launch-failed` C4/C5 leg was present. Circles#124 rounds 4–5 were direct post-r9 opportunities and the mechanism recurred. Effectiveness remains **unverified**.
- **r9 F3 — not deployed as a general capacity deferral:** #2601 remains the related work; #3095 supplied a new quota-literal opportunity and fleet latch. **Insufficient evidence of improvement.**
- **r9 F4 — not deployed in the repair writer:** the DIRTY selector still omitted `agent/blocked`; six homelab#2610 repairs were post-r9 opportunities. The review-side blocked exclusion does not fix this repair leg.
- **Shipped r10 closeout fix #3101:** deployed and had two observable opportunities—openrouter-operator#91 and homelab#2071 moved stale `agent/review` to `agent/done`, with zero follow-ups harvested. That is positive directional evidence, but too few opportunities for a rate claim.
- **#3102 OOM root/attended-strike fix and #3096 PR-less un-latch/replay-environment fix:** merged November 1; **insufficient evidence** because no suitable post-deployment recurrence window was available. #2886’s Crossplane cooldown fix likewise has no demonstrated post-fix born-half-set opportunity in this bundle.

## Evidence confidence

The bundle records GitHub activity, not worker sessions, full token cost, deployments or legacy commit statuses. Mirrored issue/PR stats can describe the same ride and are not unique-run cost records. The 24-task/25-row serialization limits trail discovery beyond the ranked sample, although population counters remain authoritative.

The known ledger blind spots apply once across this report: `reviewer_rounds` is unreliable, so verdicts came from trails; `wall_time_s` is not active/idle decomposition; `retry_storms` omits in-session model retries; and zero subscription/haiku cost means **untracked**, not free. Consequently, model first-touch rates are descriptive only, and most rail-3 savings cannot be converted into exact cash or API-equivalent dollars.

All findings are candidates. Existing work is linked above, deployed fixes are not refiled, and human acceptance plus a fresh pre-queue check remains necessary. Any accepted children belong under the label-inert `retro-batch` lineage contract, not an automatically launched Goal; publication does not authorize execution.

BEGIN-RETRO-FINDINGS
```retro-findings-json
{"schema_version":1,"findings":[{"mechanism":"python-version-set-no-fleet-hold-until-nixpkgs-stable","surface":"renovate-global.json packageRules (python docker-tag minor)","summary":"Four Python 3.15 PRs repeated per-repository integration and operator rulings; add the proposed dashboard approval hold for Python minor image and uv:python* members until the fleet version set can move.","evidence":["https://github.com/teststuffstash/homelab/pull/2610","https://github.com/teststuffstash/oracle-fleet/pull/883","https://github.com/teststuffstash/allure-behavior-snippets/pull/36","https://github.com/teststuffstash/circles/pull/124"],"related_work":[]},{"mechanism":"pr-keyed-dispatch-no-launch-invisible-to-phantom-reaper","surface":"agents/coordinator-scan.sh C4/C5 phantom agent/in-progress rule","summary":"Circles#124 added two in-window dispatches without a launched worker; classify a persisted PR-keyed dispatch with no ride, stats or strike as launch-failed so the existing strike path can act.","evidence":["https://github.com/teststuffstash/circles/pull/124"],"related_work":[]},{"mechanism":"rate-limit-strike-latches-agent-error","surface":"coordinator README Invariants identical-pair strike rule / agent-finalize rate-limit class","summary":"The confirmed OpenCode Go quota literal was classified as unknown and contributed to a three-issue fleet latch; extend the existing capacity/defer classification instead of consuming model strikes.","evidence":["https://github.com/teststuffstash/homelab/issues/3095","https://github.com/teststuffstash/homelab/issues/3087"],"related_work":["https://github.com/teststuffstash/homelab/issues/2601"]},{"mechanism":"oomkilled-worker-bypasses-finalize-strike-and-salvage","surface":"agents/coordinator-scan.sh C4/C5 TPODS terminal-pod belt","summary":"Seven OOMKilled rides exposed the absence of a surviving strike writer; after the shipped ShellCheck and launcher-attended fixes, record otherwise-unattended terminal OOMs from the scan's existing TPODS reader.","evidence":["https://github.com/teststuffstash/homelab/issues/3094","https://github.com/teststuffstash/homelab/issues/3048","https://github.com/teststuffstash/homelab/issues/1973"],"related_work":["https://github.com/teststuffstash/homelab/pull/3102"]},{"mechanism":"parked-renovate-pr-keeps-rebase-and-review-churn","surface":"agents/coordinator-scan.sh DIRTY-Renovate rebase repair (homelab#1977 class) / review reflex","summary":"Homelab#2610 received six rebase repairs after its human park; exclude agent/blocked PRs from the renovate-rebase-tick writer while retaining report-only visibility.","evidence":["https://github.com/teststuffstash/homelab/pull/2610"],"related_work":["https://github.com/teststuffstash/homelab/issues/1977"]}]}
```
END-RETRO-FINDINGS
