# The -iac lane — no humans in the deploy path (FU-106)

_Design narrative, born 2026-07-27 from the first live -iac fixer dispatch (sleep-iac#28) and the
operator rulings the same day. The machine itself is modeled in
[`iac-lane-fsm.yaml`](iac-lane-fsm.yaml) → generated view [`iac-lane-fsm.md`](iac-lane-fsm.md),
same lint as the app machine. The app-repo merge path ([`merge-path.md`](merge-path.md) /
[`merge-path-fsm.yaml`](merge-path-fsm.yaml)) does NOT apply here — that was the founding
observation: -iac repos are not application repos._

## Why -iac is a different machine

In an app repo, CI carries the evidence (tests, the full-stack gate) — green means *behavior
verified*, `Merged` is the terminal state, and tested-tree==landed-tree is the whole guarantee.
In an -iac wrapper repo that inverts: **CI can only prove FORM** (does it render, does it match
schemas, does it satisfy policy); the behavioral truth arrives *after* merge, as ArgoCD sync →
resource health → SLO/KPI. **Merge is the midpoint of the -iac lifecycle, not the end** — so the
machine has a post-merge half, and that half is the primary gate, not a belt.

## The doctrine (operator rulings, 2026-07-27)

1. **No human in the deploy path.** Nothing a human must click sits between a queued issue and a
   reconciled deployment. The platform enforces budgets (FU-093 quota, `budgetUSD`, resource caps
   like a bucket's `max_size`); user happiness is measured (SLO probes, gateway KPIs); degradation
   rolls back automatically (FU-044 chain). Humans appear **monthly** — the retro (FU-058) + 🌱
   sprout triage, where "is this successful experiment worth its complexity" gets decided — and on
   **product-contract specs** (the codeowner gate, already delegated day-to-day).
2. **Cheap CI validation is still worthwhile.** An assertion in CI costs seconds and *explains
   itself* (a reason/message at the point of failure); the same defect caught post-merge costs a
   revert, an investigation session, and tokens. Deterministic-first is an economic ruling, not
   just a safety one: catch cheap, explain loud, and reserve the post-merge machinery for what
   CI structurally cannot see.
3. **No blocking LLM review either.** The reviewer demotes to an *advisory lens* (IAC-G06): async,
   post-merge, on the cheap grounding tier (the FU-095/retro evidence class — grounding-strong
   models, not coding-strong), filing findings as inert issues. Review becomes evidence
   generation; it never adds latency or subscription draw to the deploy path.

## Lane taxonomy — each PR class gets its own gate

| lane | author | gate | notes |
|---|---|---|---|
| `deploy_bump` | deploy App | CI-only, instant (ADR-084) | `require_approval=false` is deliberate: App bypass can't waive an approval, so it was dropped, not bypassed |
| `infra_enrich` | coordinator unit | rides the bump PR (atomic pin+claim) | mechanical (schema-valid, FU-093 quota) = CI lane; judgment parks (roles.md §infra-fixer) |
| `fixer_issue` | worker | **the gap** (IAC-G01) — closes via the policy sentinel, not review | sleep-iac#28: 38s self-merge incl. `.github/workflows/` |
| `pin_follow` | deploy workflow (**IAC-G07 SHIPPED 2026-08-02**, oracle-fleet#167) | CI-only (pure mechanical) | cross-repo image-ref propagation: workflow tags ride the bump commit, pin-hold opt-out. Was the single most frequent human commit in oracle-iac history (7 of the last 120). |
| `data_roll` | operator (oracle corpus rolls) | paired-roll contract (fleet#159 schema gate) | 4 of the last 120 oracle-iac commits; semi-mechanical since the schema gate — WHICH corpus stays judgment, the paired pin+digest commit is workflow-shaped |
| `operator` | operator/meta session | CI-only | the directing human IS the review |
| `revert` | FU-044 chain | CI-only, must NEVER gain a gate | the emergency path stays instant |
| `renovate` | Renovate | existing classification (renovate.md) | |

## The platform lane — homelab is one repo, so the gate is per PATH
### Governance changes batch into a CHECKPOINT — the A5 process (operator, 2026-08-12)

Ownership/gate changes (CODEOWNERS lines, ruleset knobs like `required reviews = 2`, a second
review identity for parts of `docs/`, carve-out lints) follow the goal lane's checkpoint shape,
not per-event edits: **any single one-line edit makes local sense; ten of them are a different
process.** Candidates PILE UP in the list below instead of landing one at a time, and the pile is
reviewed in ONE `/design-agents`-context sitting (full corpus — these changes interact with the
whole gate architecture) when the operator calls it or the pile grows past a handful. Today the
operator hand-drives this batching through jail sessions; this section is the process home so it
stops being a memory.

**The pile (dated candidates, NOT decided):**
- required reviews = 2 on some tier (2026-08-12).
- a second review identity for parts of `docs/` (2026-08-12).
- drop the tier-1 `/argocd/resources/` scaffold line — its own condition: IAC-G04 enforcing on
  homelab (shadow coverage shipped 2026-08-12, A5 leg 1) or the operator's trust call.
- docs/ split: release per-service docs, keep the memory core (`follow-ups*.md`, `adr.md`,
  `incidents/`, `docs/agents/`) owned; optionally machine-enforce the tracker's single-writer
  contract via the governance-lint set (2026-08-12 mapping).
- the full agent-runtime-style narrowing stays BLOCKED on a replacement single-tax point for
  assembly merges (ADR-106 — homelab has no `/specs/`-invariant in assembly diffs).

⚠ Known structural debt, deliberately parked (operator, 2026-08-12): `scripts/` has no internal
structure that would make path-based rules easy — CI-invoked checks (governance-class: the
governance-lint treats ALL of `scripts/` as such) sit beside operational one-shots in one flat
directory. Restructuring it is its own future candidate, not part of any current leg.


Every stack splits an app repo (behavior; CI carries the evidence) from `-iac` (form + post-merge
truth). **homelab has no such split.** It *is* the platform's own `-iac` — ArgoCD watches
`argocd/`, `agents/coordinator`, `agents/fixer/*` and syncs on merge, so merge is the midpoint here
too — and it is simultaneously where the loop's own machinery lives. So the lane taxonomy above
cannot key on the repo. It keys on the **path**.

| paths | applied by | agent may author | gate |
|---|---|---|---|
| `docs/**` | nothing | ✅ | **codeowner** (CODEOWNERS `/docs/` since 2026-08-04 — the docs are the platform's memory) |
| `argocd/resources/**` | ArgoCD — merge *is* deploy | ✅ | CI (see the check-coverage caveat below) |
| `argocd/platform/**` | ArgoCD app-of-apps, `prune: true` | ✅ | **codeowner** — an edit here *deletes* services |
| `tofu/*.tf` (root) | `tofu apply` | ✅ | **codeowner**; apply stays out-of-band (cone rule) |
| `ansible/**` | `opnsense-playbook.sh` → the router | ✅ | **codeowner** + windowed apply |
| `agents/**`, `policy/**`, `tofu/github/**`, `tofu/cloudflare/**` | the loop's own machinery | ✅ | **codeowner** — see the pre-merge rule below |
| `.github/**`, `devbox.json`, CI-invoked `scripts/**`, `.agents/**` | executes BEFORE review | ❌ **never** | operator only |

### ⚠ The trap: one root cause, N alert issues, N concurrent fixers

**Alert issues arrive one-per-fingerprint, so a single underlying fault becomes several issues that
look independent.** Queue them the way ordinary work is queued — one at a time, up to
`REPO_MAX_WIP` — and you get **three fixers attacking three symptoms of one cause**, each authoring
a PR against a different file, none aware of the others.

**ADR-097's footprint hold does NOT catch this.** It holds a queued issue whose declared `Touches:`
overlaps an in-progress one — it keys on PATHS. Same-cause issues routinely declare *different*
paths. Live on 2026-08-07, all three open and mutually non-overlapping:

| issue | `Touches:` |
|---|---|
| #103 `NodeSystemSaturation` on wk-01 | `agents/coordinator/*-argo.yaml` |
| #110 `PodSigkilled` bucket-sync OOM | `agents/coordinator/transcripts-viewer.yaml` |
| #111 `GithubWorkflowRunFailed` | `argocd/platform/arc-runners.yaml` |

#103 and #110 are both memory-pressure stories; nothing in the footprint gate relates them, so both
are dispatchable at once. The three fixes would then be authored against a symptom each, and the
one that is actually the cause gets no more attention than the two that are downstream of it.

**So alert issues need a different queueing rule from ordinary work: look at ALL of them together
BEFORE labelling any** (operator direction 2026-08-07). The unit of triage is the open SET, not the
next issue. What that pass has to decide, per group: which single issue is the cause (queue that
one), which are downstream (leave inert, link them to it), and which are genuinely independent.
⚠ Fail-safe direction is *not to label*: an un-queued issue waits, while three concurrent fixers on
one cause spend budget AND produce conflicting PRs that a human then has to reconcile.
⚠ This is FU-133's correlation half, one step further downstream — that item is about the alert lane
filing uncorrelated ISSUES; this is about DISPATCHING them uncorrelated. Same root, different cost.

**BUILT 2026-08-07 (`fix-debounce`, operator design)** — bell-driven, deliberately not cron-first:
a cron's latency is random within its window, a bell's is exactly the debounce. The verdict/queue
split is the load-bearing move: `agent-fix` became a *diagnosis* (the triage session ends its issue
with `fix-verdict: fix|report-only`; the responder shell applies the label — inert, because the
scan's dispatch precondition is `agent/queued` alone (ADR-122 (2), S8 #1432)) and `agent/queued`
is granted ONLY by the set-judged debouncer:

- **Edge**: the responder rings `POST /fix-verdict` after labelling → Sensor submits a
  `fix-debounce` workflow (`agents/coordinator/fix-debounce-argo.yaml`).
- **Debounce**: suspend `wait` (default 10m) — suspends run in PARALLEL, so every bell guarantees
  a decision ≥ wait after *it*; only `decide` serializes (mutex). A burst wakes together; the
  first decide sweeps the whole set, the rest exit empty.
- **State is GitHub, nowhere else**: the pending set IS the live label query
  `agent-fix ∧ no agent/* label` over the claims' repos (REST only — the search index lags and the
  GraphQL pool is the one the reflex drained, FU-084). A killed workflow loses nothing. ⚠ The
  exclusion is the whole **lifecycle namespace**, not a list, and that is load-bearing
  (homelab#238 → #244): `agent/*` is lifecycle state, `agent-fix` is the *diagnosis* and carries a
  dash precisely so the prefix test eats only the former. Every lifecycle label is applied by
  **removing `agent/queued`**, so each one is the same hole — the label that says somebody has
  this issue is exactly what re-admits it to the pending set:
  - human-waiting (`agent/blocked`, `agent/error`) — live on homelab#237, 2026-08-11: block
    01:53Z → silent re-queue 02:17Z, dispatch re-discovering the same blocker once per debounce
    period with the human gate erased each turn. Fixed by #238 — for that pair only.
  - **in-flight** (`agent/in-progress`, `agent/review`) — dispatch does `--add-label
    agent/in-progress --remove-label agent/queued`, so a RIDING issue re-entered the set and was
    re-queued mid-ride: live on homelab#238's own timeline (dispatch 08:08:14Z → `agent/queued`
    back on 08:17:21Z). Only the launcher's pre-flight (open-PR / running-pod refusal) and the
    pod-name idempotency key held that to label churn — belts doing a guard's job. #244 is why
    this became a namespace test rather than a longer list.
  - terminal (`agent/done`, `agent/linked`) — finished work never re-queues.

  The re-queue was never a belt for the [IL-T16 phantom-label
  reconcile](issue-lifecycle-fsm.md) or C4/C5 re-dispatch: both are the *scan's*, both re-add
  `agent/queued` themselves (IL-T16 queued-first, in-progress-second), and an issue wearing
  `agent/queued` was outside the pending set under the old predicate too — so nothing downstream
  loses a trigger. Same rule the scan holds on its side (`coordinator-scan.sh:17`).
- **Decide**: 0 pending → exit. 1 → deterministic gates, queue. ≥2 → ONE sonnet set-pass
  (latch-gated, subscription-semaphore held only across decide) emits cause/downstream/
  independent as fenced JSON; the SHELL applies it (ADR-094 — the LLM judges, launcher-owned
  code acts). Downstream issues get `agent/linked` + a comment naming the cause; `unsure` waits.
- **Queue-time deny = the ❌ table only** (`.github/`, `.agents/`, `devbox.json|lock`,
  `scripts/`): the paths where authoring takes effect before a human approves. Everything else
  queues freely — CODEOWNERS gates the MERGE (the §above correction). `self-referential: true`
  bodies are skipped at wake: dispatch onto broken substrate stays a human call.
- **Backstop** (machinery slot 3): a 2h cron re-derives the pending set a lost bell left behind,
  with `wait=10s` — normal latency stays bell-shaped; the cron only rescues drops.
- **Bounds**: no ledger of its own — set-passes ≤ verdict rings/day (≤ `RESPONDER_DAILY_MAX`),
  plus the FU-088 latch and the shared claude semaphore.
- **Re-entry**: if a linked issue's alert refires after the cause-fix merged, the responder's
  fp/subject belts reopen the SAME issue; removing `agent/linked` re-enters it in the pending set.
  A reopen **restores a record, not a queue** (#228, 2026-08-09): GitHub brings a reopened issue
  back wearing the labels it was closed with, so the responder strips the whole lifecycle set
  (`agent/queued`, `agent/in-progress`, `agent/done`, `agent-fix`) on every reopen in
  launcher-owned shell, and only a fresh `fix-verdict: fix` re-earns `agent-fix`. Unstripped, the
  live case arrived pre-queued on already-merged work and the FU-069 breaker caught the
  contradiction — which is a belt doing a guard's job at the wrong end of the lane.
- **First live ≥2-pending set-pass (2026-08-07): independence RIGHT, queueing WRONG — and the
  coordinator caught it.** The set was homelab#68 + #118; the verdict "independent root causes"
  was correct. But #68 was queued off its BODY — a 07-28 diagnosis whose scope ceiling
  (`longhornManager.resources`) had ALREADY shipped (FU-112(b)/FU-139; zero BestEffort pods
  live) — and `agent/queued` landed 11 minutes AFTER the responder's resolve leg recorded the
  alert clearing (#68 was human-engaged, so the resolve leg could not close it, and it sat
  ripe in the pending set). The 21:00Z platform coordinator refused the unit and parked it
  `agent/blocked` with the full refutation. **Lesson: the set-pass reads bodies, not current
  state — the queue gate needs a CURRENCY check (FU-133 leg c — QUEUED as homelab#253,
  blocked-by #244): skip when the alert has
  resolved, and treat a body older than its subject's last state change as suspect.** The
  reopening kill was `Error`-137 shared-fate (the PSI-stall class, FU-139 archive), not a
  values problem — #63/#65 are the same collateral, not riders on any longhorn-values fix.

**The line is "does it take effect before a human approves?" — not "is it governance"** (operator
correction, 2026-08-07). The old rule put all six prefixes in ❌ on the reasoning that *"an agent
that can edit them is not gated at all, whatever the ruleset says."* That is false for most of
them: **the loop runs from `master`** — every coordinator/reviewer/worker pod does
`git clone --depth 1 -b master` — so a PR-branch edit to `coordinator-scan.sh`, `review-reflex.sh`
or `agent-session.sh` changes nothing that is running. It is a proposal, and the codeowner gate is
a human. Authoring is not effect.

Three things genuinely do take effect first, and they are the whole ❌ list:

| path | why it beats the gate |
|---|---|
| `.github/**` | `on: pull_request` runs the PR's OWN workflow — arbitrary code on the runner with its token, and a green `ci` by fiat, before anyone looks |
| `devbox.json` + CI-invoked `scripts/**` | CI executes them from the branch; here the scripts ARE the checks (adding a tool is normal in a STACK repo, not in this one) |
| `.agents/**` | a fix round resumes with `--work-branch` on the PR's branch, so the NEXT round reads its recipe from there — it can loosen its own ceiling mid-PR |

⚠ Consequence worth stating: a faked green does NOT merge anything here, because every remaining
path is codeowner-gated. The reason `.github/**` stays ❌ is **code execution on the runner**, not
the check — conflating those two is what made the old rule too broad.

Two files are carved back OUT of that table because the arc-runner auto-bump commits both
(`argocd/platform/arc-runners.yaml`, `agents/coordinator/reflexes-argo.yaml`) and a mechanical tag
bump should not wait for a human. Ownership is **replaced, not dropped**: `pin-only-lint` (in the
required `ci`) allows only arc-runner image-pin lines into them via a PR — stricter than the review
it stands in for, since a regex cannot approve a smuggled fourth line. Real edits take the operator
path (direct to master), which is not a PR and not gated. That is the general shape for anything
else that needs un-gating: **replace the owner with a rule, never just remove the owner.**

The deny row is the load-bearing one. `agents/**` holds the launcher that builds its own dispatch
command (ADR-094), the scan that decides what gets dispatched, and the reflex that approves its own
PRs; `tofu/github/**` holds the ruleset governing all of it. **A fixer permitted to edit its own
governor is not gated at all**, whatever the ruleset says.

**Both preconditions landed 2026-08-04** (FU-068): the repo-root `CODEOWNERS` encodes the tiers
above, and `tofu/github` flipped homelab to `require_approval = true, require_code_owner_review =
true` — applied, ruleset `required_approval["homelab"]` created. Ordering mattered and was not
cosmetic: `require_approval` is repo-WIDE while only code-owner review is path-scoped, and
`review-reflex.sh` derives its scan set from the AgentStack claims, so flipping before homelab
joined a claim would have stalled every armed PR on an approval nothing could give (an
App/Integration bypass cannot waive required-approval — only an OrganizationAdmin can, ADR-084).

**The lane became dispatchable 2026-08-05** (`c5db520`, FU-142 archived): `.agents/fix.yaml` +
`.agents/review.md` ship the recipe `--recipe` needs (launcher-owned, ADR-094 — without it the
launcher refuses before a pod exists, which is what held homelab#97 at `agent/blocked`). The recipe
is the fixer's own governor, so it sits in the deny row's spirit — operator-authored, never
agent-authored. Three homelab-specific departures from the sleep-iac donor it was adapted from:
scope is a **PATH tier ceiling over the issue's `Touches:`** (a `Touches:` line may narrow the
tiers, never widen them); with no `devbox run ci` here the recipe names the lints **per path** and
makes the PR state which ran; and the PR must reference its issue or the scan re-dispatches
(agent-runtime#32). The GATE question settled by adding `raw.githubusercontent.com` to the fixer's
`extraFQDNs` — `manifest-lint` shells to kubeconform, which fetches schemas there, and under
`enforce: true` the gate would otherwise fail on a network drop rather than on the manifest.

**Automerge safety is a function of check coverage, not of the path.** `ci` was
`argocd-validate-pins` alone — it proves a pinned OCI chart renders and looks at nothing else, so a
hand-written Deployment with a typo passed. `kubeconform -strict` over `argocd/resources/*` and
`tofu fmt` landed with the tiers; the honest residue is that **most resources are SKIPPED** for
want of a local CRD schema (Applications, AgentStacks, CiliumNetworkPolicies — PrometheusRules
left this class 2026-08-11: `prometheus-rules-lint`/promtool parses every expr in `ci`, FU-158;
behaviour tests still open) —
`manifest-lint` prints that every run and fails if it ever validates nothing.

**Operator ruling 2026-08-06: that skipped majority is the SENTINEL's problem, not a schema-vendoring
errand** — it gets no id of its own and belongs to IAC-G04/FU-106. The reasoning is the same one that
made the sentinel exist: the kinds kubeconform cannot see are exactly the kinds that carry the
platform contract (an `Application` pointing anywhere, an `AgentStack` claiming any budget or egress,
a `CiliumNetworkPolicy` widening the deny row, a `PrometheusRule` silencing a belt). A vendored
OpenAPI schema would only prove those documents are well-*formed*; the sentinel's Kyverno policies
are what judge whether they are *permitted*, and they run cluster-side off master where the PR
cannot rewrite them. So extending the G04 sentinel to homelab (already FU-106's next-action, for the
tier-1 CODEOWNERS residue) is also what closes this gap — vendor a schema only where a kind turns
out to need form-checking the policies don't give. `tofu validate` stays separately out (a provider
download per PR, the FU-130 WAN class). A third residue joined 2026-08-11 (PR#250's finding):
`manifest-lint` globs only `argocd/{resources,platform}`, so **`agents/coordinator/*.yaml`** — the
loop's own Sensors/CronWorkflows/WorkflowTemplates — is schema-checked by nobody; same owner, same
step (the sentinel covering homelab), not a separate errand. _2026-09-03 (#1315):_ the Workflow
kinds now get `argo lint --offline` in `ci` (`devbox run argo-lint` — template references, not
just schema); the Sensors/EventSources remain the sentinel's. The same PR closed a fourth residue
of this class: the PublicRoute Composition's **templated Terraform** (a string no schema gate
reads) is rendered + `tofu validate`d by `devbox run publicroute-tf-validate`.

**The fixer block landed the same day** (`agents/fixer/openrouter-operator/agentstack.yaml`:
budget $5/week, `guardrail: none` — the stack chain is a paid model, `claudeTier: false` per the
FU-134 ruling, egress `none`+enforced), which is what creates the per-repo namespace its worker
RoleBinding needs (`agent-read-infra`, since homelab is the platform's own `-iac`). **The one thing
still outstanding** is the IAC-G04 sentinel covering homelab so tier 1 can go back to being
unowned — a FU-106 next-action. Until then tier 1 is owned as a scaffold and says so.

### ⚖ Auto-revert does NOT generalize to the platform (operator ruling, 2026-08-04)

The obvious next step from FU-044 — point the Degraded→revert chain at homelab's own ArgoCD apps —
is **rejected as a blanket rule**, for two reasons that are properties of the platform rather than
of the mechanism:

- **The platform barely has the trigger.** The chain reverts *"the newest `deploy/*` bump merged
  ≤120m"*. In homelab only the first-party image pins move that way (agent-base,
  agent-coordinator, arc-runner). garage, kube-prometheus-stack, loki and forgejo move by
  chart-version bumps and hand edits — there is usually no `deploy/*` commit to revert to.
- **Revert is not free for stateful services, and this is the last net.** Reverting a garage or
  CNPG chart can be worse than the failure it answers: CRD/schema downgrades, PVC expectations,
  data-layer skew. And if the revert *also* fails, nothing catches it — on a stack that costs the
  stack, here it costs the machinery that would have fixed it.

**Ruling: auto-revert extends to homelab only for the reversible class** — a first-party image
**pin** bump, no CRD/schema migration, no data-layer coupling. Everything else that goes Degraded
reaches the responder as an alert plus a report-only issue, and a human decides. Stated as a
precondition rather than an app list so it survives new apps: *revert automatically only where the
change is a pin and the rollback is provably as safe as the roll-forward.*

**IMPLEMENTED 2026-08-04** in `agents/coordinator/deploy-revert-argo.yaml`. The argocd-notifications
subscription was already global, so homelab apps had been POSTing Degraded all along and the
workflow was dropping them at the `*-iac` source guard; the change is that guard plus a predicate:
for `teststuffstash/homelab`, **every content line of the candidate merge's diff must be a
first-party image pin** (`ghcr.io/teststuffstash/…:<tag>`), or it exits report-only. Deliberately
the same shape as `scripts/pin-only-lint.sh` — a regex cannot be talked past, and an unreadable
diff is fail-closed rather than "no offending lines found". Exercised against five diffs before
shipping: pin bumps pass, a `targetRevision` bump, a third-party image and a pin bump with one
smuggled non-pin line all drop to report-only. The revert PR gets **no merge special-casing** —
CODEOWNERS still applies, so it auto-merges on the un-owned pin paths and waits for a human
anywhere else. Both outcomes are correct; bypassing the gate to make a rollback faster is not.

### Who owns a symptom — the alert lane vs the observation window

Two entry points reach the same post-merge machinery: **change-triggered** (a merge opens a window,
IAC-T04/T05) and **symptom-triggered** (the responder, IAC-T07). They already overlap in
production — the responder's cheapest-sufficient outcome list includes a GitOps quick fix on the
stack's `-iac`, which *is* this lane's revert path. Undefined ownership means a revert racing a fix.

**Rule: inside an open observation window for a recent deploy, the -iac lane owns the symptom** —
the alert lane attaches evidence to that unit and dispatches nothing. Outside a window, the alert
lane owns it. Modelled as IAC-G10; the correlation half — filing-side `group_by = ["alertname"]`, one delivery per storm —
is FU-133 leg (a), QUEUED as homelab#252.

## The infra-delta rollout matrix — what an upstream chart change costs the wrapper

The whole role exists because of the **target-agnostic-chart constraint**
([platform-and-stacks.md §Composition axes](platform-and-stacks.md), 4th bullet): app charts carry
only the consumption **contract** (`values.schema.json`, `existingSecret`, endpoint values,
default-off flags for ecosystem-standard CRDs) and deploy anywhere; **platform fulfillment**
(Crossplane claims, ExternalSecrets) lives in the per-target wrapper chart in `-iac`. So every
upstream change has to be classified by what it demands of the wrapper:

| # | Chart change | What `-iac` must do |
|---|---|---|
| a | New **provisionable** (bucket, key, DB) | Wrapper claim, **atomic with the pin bump** |
| b | New value **with a default** | Nothing — chart default carries it |
| c | New **required** value | The `values.schema.json` **diff between chart versions IS the typed infra delta** → the scan emits one infra unit per `-iac` target dir → the role **enriches** the ADR-084 bump PR (pin + fulfillment in ONE commit = deploy-atomic, the meta-11 paired-rolls rule generalized) |
| d | **Expand/contract** for code-level compat | Both halves, with a scan **aging predicate** on undropped expands (a debt timer; the contract task is born via the FU-090 harvest) |
| e | **Runtime wedge** (`optional: false` → new RS wedges, old keeps serving) | The occasional visible-stall variant of (c) |
| f | **Quota / judgment** | Codeowner-gated, provider-first hold — the only surviving hold |

Mechanical (schema-valid **and** within the FU-093 quota) rides the CI-only auto-merge lane; the
**FU-093 storage ledger is what DEFINES "mechanical"** ([storage-ledger.md](../storage-ledger.md)).
Hard boundary: the role wires secret **references**, never values — Infisical writes stay
operator/ESO-push.

**Greenfield is OUTSIDE this matrix (named 2026-08-02).** The matrix diffs an EXISTING wrapper
against a chart delta; a project's FIRST chart has no wrapper to diff — `values.schema.json`
appearing at all is the delta. That case is a **bootstrap seam, not a lane class**: the first
wrapper is semi-derivable (donor copy from the freshest graduated stack — the FU-070 copy-paste
experiment — plus the schema's required-without-default list as the fill-in worklist, plus the
chart's `example-homelab-values.yaml` as the worked example), but its judgment slots are
irreducibly operator: secret VALUES (the reference/value boundary above), platform precreations
(ns, repos), and the FU-039 subdomain claim. After the first deploy the stack enters the matrix
and evolves via `infra_enrich`.

⚠ This deliberately **re-opens two standing exclusions** — `fixerRepos` context-only (the FU-086
predicate) and "sleep-iac excluded, CI-only deploy repo" — via a *distinct dispatch class*, not by
silently flipping them.

**Built 2026-07-27:** `agents/infra-schema-diff.sh` (the typed delta + `enrichment_needed` bit,
verified); the scan's `ci-red-stale` probe routes a RED `deploy/*` bump PR in a `*-iac` repo to the
distinct `infra-enrich` class — the item session helm-pulls both chart versions, runs the diff, and
enriches **the same PR** (brief §infra-enrich). The sleep-iac exclusion was re-opened deliberately
via a reviewed claim diff (sleep-iac#24: fixer block, stack-declared fixer ns, `-iac` fix.yaml +
PROD-SERVING rubric). First live dispatch 2026-07-27 (#22 → PR#28, merged, deliverables verified by
the C6 closeout) — **and that dispatch is what exposed IAC-G01**, below. The **oracle-iac twin
went LIVE 2026-08-02** (fixer block #262 + ns render; first ride #97→#265 merged clean).

## Assurance layers (what catches what)

- **L0 — CI, deterministic (form):** helm template / kustomize build renders, kubeconform against
  pinned CRD schemas, and **policy-as-code for the platform contract that is already prose**:
  ip-plan ranges (ADR-088), hostname conventions, ADR-076 bucket ownership, tenancy boundaries,
  secret *references-never-values*, `deletionPolicy` guards, workflow-path rules. Every rule kills
  an incident class forever, with a message. This is the decision-table doctrine applied to infra.
- **L0b — the tamper-proof sentinel (IAC-G04): v1 BUILT 2026-08-03; G01 ENFORCEMENT FLIP BUILT
  2026-08-18** (soak verdict: -iac repos 15d clean; homelab needed a baseline, below). In-repo CI
  runs the PR's own workflow code, so a required check the PR can rewrite is not a gate against
  the worker itself. The sentinel runs cluster-side (`iac-sentinel` CronWorkflow */15,
  agent-coordinator ns, arc-runner image) with rules and engines from THIS repo's master —
  the PR tree arrives as a tarball (data, never executed; no helm/hooks in v1 — raw-YAML pass,
  the render pass is v2). **Engines (operator ruling: no engine sprawl — Kyverno is THE rule
  engine for THIS, the CLI seat; NB no prior roadmap record of kyverno was found — this ruling is
  the record. ⚠ NARROWED 2026-08-27: the earlier "the admission-controller seat is its future"
  read as Kyverno having already won that seat. It has not — the ADMISSION seat is a separate,
  OPEN choice between Kyverno and OPA Gatekeeper, deliberately gated on a SECOND use case before
  deciding, per the ≥2-pattern rule. The two seats are different jobs: the sentinel evaluates a
  PR tree offline, while admission puts a webhook in the pod-creation path where `failurePolicy`
  and availability dominate. Tracked with its first use case as FU-191):** `policy/iac/*.yaml` (5 Kyverno policies:
  raw-Secret, public-bucket, explicit-Delete deletionPolicy, VIP∈192.168.32.0/19,
  cluster-scoped power kinds — all synthetically verified firing), gitleaks (secret values,
  fleet-standard), and a bash path-rule (worker-authored PRs must not touch
  `.github/workflows/**` — the sleep-iac#28 hole; a GitHub **push ruleset** with restricted
  file paths is the enforcement-grade native version, to verify+tofu at the flip).
  **Shadow → enforce is the router-rollout pattern**: v1 posted nothing to GitHub (logs +
  pushgateway `iac_sentinel_violations`/`_engine_seconds`); **the flip (built 2026-08-18)**
  adds `statuses: write` to the homelab-REVIEWER App (never the worker's own identity — it
  could pass itself), and the sentinel posts an `iac-sentinel` commit status per evaluated PR
  head (success/failure; `error` on probe failure — fail-closed, healed next tick) when
  `SENTINEL_STATUS_TOKEN` is present (the reviewer-git Secret; empty = shadow). The context is
  REQUIRED on the four sentinel repos (tofu `protected_repos`), and the tick tightened
  */15 → */5 so a PR waits ≤ one tick. The workflow push ruleset (`workflow_push_guard`,
  `restrict_workflow_pushes`) rejects `.github/workflows/**` pushes by non-bypass actors —
  but GitHub allows push rules on PRIVATE repos only (422 at the flip apply), so it exists
  solely on oracle-iac; on the public repos (homelab, sleep-iac, circles-iac) the fence is the
  required check itself: workflow edits only LAND via a PR (org ruleset), and the sentinel's
  path-rule reds any worker-authored PR touching `.github/workflows/**`.
  **The homelab baseline that made the platform repo enforceable:** the tenancy policy
  (no-cluster-scoped) reads differently on the platform repo — there the fence is "only the
  grants the platform already owns", encoded as `policy/iac/exceptions/homelab.yaml` (a Kyverno
  PolicyException enumerating every legit cluster-scoped resource BY NAME; a new
  ClusterRole/Namespace in a PR still goes red until the codeowner-gated `/policy/` list grows).
  Same central-ownership model for secrets scanning: `policy/iac/gitleaks.toml` (documented-FP
  allowlist) is passed with `--config` from the sentinel's own master clone — exceptions and
  scanner config are never read from the scanned PR tree, which a hostile PR controls.
  ⚠ **The ordering rule that falls out, which costs one red cycle to learn:** a PR adding a NEW
  cluster-scoped resource is red until its name is on **master**, because the run judging it reads
  master's baseline and not the PR's copy. So the exception lands FIRST, as its own change — which
  also puts `policy/iac/exceptions/*` in the CODEOWNERS / `.github/workflows/**` class: self-gating
  is impossible, so it is operator-direct by necessity, not convenience. Seen live on homelab#1008
  (ADR-118's read door, three names), fixed by `105f6db3` landing the baseline separately.
  **Measured overhead (2026-08-03, both -iac repos at master):** fetch ~0.7–1.0s · collect
  ~0.2s · kyverno ~0.7–0.8s (5 policies × 17–25 docs) · gitleaks ~0.14s · **total ~1.8–2.1s
  serial per PR head**. Parallelizing engines saves <1s while ARC job overhead is ~10–30s and
  the poll tick is 15min — **parallel steps start paying only when serial engine time reaches
  the job-overhead scale (~10s+)**, i.e. after the v2 render pass (helm templating per chart is
  the expensive step) or ~10× policy growth; revisit against `iac_sentinel_engine_seconds` then.
  **Sentinel freshness keys on `iac_sentinel_last_run_timestamp_seconds`** (per-tick heartbeat,
  pushed on every tick incl. zero-PR ones — FU-176: the pushgateway replaces the whole group per
  push, so engine rows legitimately vanish on quiet ticks and are NOT a health signal;
  `IacSentinelSilent` alerts on >30m of heartbeat silence).
  This — not review — is what closes IAC-G01, because rollback is structurally blind to
  silent security holes (a public bucket never degrades a KPI).
- **L1 — pre-merge rendered diff:** master-vs-branch manifest diff as a PR comment — grounds any
  reader (human or lens) in the actual delta, catches plausible-YAML-wrong-effect.
- **L2 — post-merge machine:** sync → health → observation window (below) → promote | revert.
  Widened revert trigger (IAC-G02), cluster-verifying closeout (IAC-G03).
- **L3 — runtime:** SLO probes + error-budget teeth (FU-104 — budget burnt already parks the
  stack's auto-merge lane: the platform pausing shipping when users hurt, no human), responder
  routing to the -iac ops surface, scheduled drift/audit lenses (FU-101 shape) for the silent
  classes between policy rules.

What structurally cannot be caught pre-merge: references to platform-precreated resources,
provider-side effects, cross-stack interactions. That is exactly the post-merge half's job, and
why revert-first (never fix-forward-in-place) is the standing play.

### ⚠ ArgoCD health is NOT the post-deploy gate (sharpened by meta-11, 2026-07-26)

A chart that renders and passes kubeconform can still break at runtime — a bad migration, a
crashlooping CronJob, a probe that passes while the thing behind it is dead. The meta-11 schema-skew
outage **stayed GREEN in Argo throughout**, because the pods were Ready on a `tcpSocket` probe.

So L2's health check is a *shallow* gate, and two things carry the real weight:

- **The deep contract probe** — the FU-102 prober at tools/call level, "verify through the deepest
  component" ([roles.md](roles.md) §prober). That is the acceptance signal, not app health.
- **The deterministic half of prevention** — the paired-roll / schema-gate contract
  (oracle-fleet#159 shape) plus readiness that actually exercises the backend (#157).

**Deterministic rollback shipped 2026-07-27 (FU-044, no LLM):** argocd-notifications (`oncePer`
revision) POSTs a post-sync **Degraded** app → the `/deploy-degraded` edge → the `deploy-revert`
Sensor/Workflow ([`agents/coordinator/deploy-revert-argo.yaml`](../../agents/coordinator/deploy-revert-argo.yaml)):
it reverts the newest `deploy/*` bump merged ≤120m that touches the app's path, as an auto-merging
PR (branch + cm-ledger idempotency). Non-`-iac`, no-recent-bump and revert-conflict all fail closed
to report-only.

**Roll-FORWARD — dispatch a worker against the app repo to fix the breakage — is the remaining LLM
half.** Direction is settled: do it **in-cluster off ArgoCD app-health events, NOT in the GitHub
Actions deploy run**, since the deploy job now ends at "auto-merge armed" (`deploy-pin.sh`) and
post-deploy health is decoupled from CI. Standing operator prereq: **harden app CI so prod
breakages are rare** — the rollback is the safety net, not the primary control.

## Progressive delivery — the observation window (IAC-G05)

The current platform (ArgoCD + Cilium Gateway API + Argo Workflows/Events + Prometheus — no mesh,
by design) supports three rungs; **eventually Cloudflare fronts all services** (operator,
2026-07-27), which is where the top rung lives.

- **Rung 0 — smoke-verified sync (any stack, buildable now):** an ArgoCD **PostSync hook Job**
  curls the new deployment — `/healthz` plus one real read — so "Synced" only reports after the
  service *answered*, and a failure fails the sync loudly into the existing Degraded→revert path.
  Sleep is the shape-proving pilot: a single user, so the curl IS the user. Zero new components.

  **Cron-shaped apps (⚖ answered 2026-08-03, built as sleep-tracking#113):** a CronJob has no
  endpoint to curl — its `/healthz` is **a run's exit code**. The hook Job runs the app for real
  (init step, same podTemplate) then does **freshness-free read assertions** on the output (opens,
  non-empty, newest record plausibly recent). Two operator rulings baked in: (a) *no
  run-freshness assert* — upload-on-unchanged-input is incidental behavior today, and such
  behaviors become contracts only after the pattern emerges across multiple projects, not
  per-app; (b) *real-run-as-hook presumes runs are idempotent and cheap* (true for sleep's
  small dataset). For a future cron where reruns are costly or side-effecting, the candidate
  shapes are: a **dry-run/smoke flag** in the app (parse config + touch dependencies, write
  nothing), a **data-subset canary** (new logic gated to a slice of ids/tenants via flag —
  rollback = flag flip), a **parallel shadow CronJob** (new image against a clone/validation
  pool, compare outputs), or **phased schedule frequency** (canary runs 1×/day before the image
  lands on the real cadence). Pick per app; none needed for sleep.
- **Rung 1 — in-cluster traffic split** (a *deployment/traffic* canary — the glossary's third
  sense, distinct from the scout's rail probe): Gateway API weighted `backendRefs` (Cilium
  implements them; the ADR-092 sleep Gateway is already this stack): stable + canary Deployments, promotion =
  a weight flip driven by a Workflow step reading Prometheus. If/when analysis-driven promotion
  should be declarative, **Argo Rollouts + its Gateway API plugin** is the fit — the
  [README](README.md) §Open "revisit Rollouts only if reality proves testing insufficient" clause
  fires for oracle *differently than written*: not because testing failed, but because runtime
  evidence IS the product's decision signal (the free tier is the canary — the business design).
- **Rung 2 — the edge (Cloudflare, the destination):** key-tier routing at the gateway/Worker
  (free→latest, paid→stable pin), weighted CF Load Balancing across origins, and **shadow
  mirroring** — the teststuff ladder (① shadow ② serve-with-hedge ③ stable). Wrong-answer-with-200
  detection lives HERE (diff candidate vs stable on mirrored real traffic), not in k8s health.
  The cluster rungs stay the reference deployment underneath, per the architecture doc's own rule.
- **Probe placement corollary:** once Cloudflare fronts a service, the SLO probe needs an
  outside-in leg through the same path users take — an all-green LAN probe over a broken edge is
  the FU-108 lesson (a probe that returns cleanly is not a probe that looked) at network scale.

Oracle is where this is the business idea; sleep gets rung 0 now purely to prove the shape.

## Model class — devops is not coding

The -iac task shape is grounding-heavy (schema adherence, cross-referencing platform contracts),
not algorithm-heavy — and the retro program's evidence (FU-058 runs 1+2) says exactly that axis
separates models: deepseek-v4-pro/hy3 graded opus-adjacent on grounded work at $0.02–0.08 while
fabricator-prone models invented APIs precisely where grounding was needed. So: **the -iac lane
gets its own chain**, not the app-coding chain. Mechanism: interim = per-repo override in the
claim (`repos[].fixer.workerModel/[Fallbacks]`, the `dockerRepos` pattern); proper home =
FU-095(a), where **repo-type (app vs -iac) is the first task-class axis** (cheaper and sharper
than budget×track, and the FU-057 ledger already keys per-repo). Rotation entrants earn devops
evidence via a devops-shaped scout canary (render + patch a manifest against a schema) — coding
canaries prove nothing here.

## Build order

Tracked on FU-106; the gap register (IAC-G01..G06, `iac-lane-fsm.yaml` — G07 shipped without
ever entering it) IS the list. The order as EXECUTED: G07 + G02 + G03 (2026-08-02) → G05
rung-0 (sleep-tracking#113) + G04 sentinel v1 shadow (2026-08-03).
**The G01 ENFORCEMENT flip: LIVE since 2026-08-18 (§L0b — status posting, homelab baseline,
required check + push ruleset in tofu; the grant + apply landed the same day, and the sentinel
has red-cycled a real PR since — homelab#1008's baseline-ordering catch). Remaining: the G06
advisory lens; window rungs 1/2 when oracle's gateway metering (T3c) exists.**
**Historical reprioritization note (2026-08-02, commit-history audit):** G07 pin-follow was the
biggest *mechanical* win (no LLM, deterministic, the most frequent human commit in oracle-iac)
and can ship independently of the order above; and once oracle-iac gains a fixer block (the
FU-106 twin, operator-wanted), G04 rises with it — fixer volume without the sentinel widens the
G01 hole.
