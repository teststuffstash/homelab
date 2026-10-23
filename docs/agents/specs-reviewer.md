# The specs reviewer — the second review identity over `specs/` and its evidence

> Design note for [`agents/lenses/specs.md`](../../agents/lenses/specs.md) (the brief, rules only).
> Decided by [ADR-155](../adr.md#adr-155--the-specs-reviewer-is-a-second-app-identity-and-the-island-repo-requires-two-approvals-2026-10-16);
> built 2026-10-16 (dispatch `agents/specs-reviewer-session.sh`, workflow
> `agents/coordinator/specs-review-argo.yaml`, identity `agents/coordinator/specs-reviewer-git.yaml`).
> Born with the P2 gateway island ([`context-and-autonomy.md`](../spikes/context-and-autonomy.md)
> §Direction, FU-270 / ADR-139).

## Why a second reviewer

Oracle's spec process ([`docs/process/README.md`](https://github.com/teststuffstash/oracle-fleet/blob/master/docs/process/README.md)
rule 1) makes `specs/` the HUMAN gate against golden-mastering. §Direction 2 moves that read off
the operator: **specs are reviewer-gated, not codeowner-gated** — a full-context reviewer (the
island's specs + the consumer contracts it touches) gates spec changes; ⚖ rows reach the operator
as a digest. The code reviewer cannot be it: reading rows beside the code, a row that matches the
code looks RIGHT — the one failure the gate exists to catch. The specs reviewer never sees code.

## What it gates, on what input

- **Gates spec ROWS**: intent source (vs golden-mastered), ⚖ flagging + `Spec changes:` listing,
  removed-row reasons, row ⇄ schema contradictions, evidence stamped at head, glossary terms —
  BLOCKING. Table SHAPE is advisory always: propose the split, never a size.
- **Does not gate**: code, tests, manifests, the mechanical coupling (`spec_gate.py` in `ci`
  owns it), prose polish. A clean read is `--approve` — the island repo's SECOND required
  approval; a failing blocking check is `--request-changes`; a comment is never the terminal
  (ADR-155 — the identity is distinct, so neither verdict touches the code reviewer's state).
- **Input**: the `**/specs/**` diff, the specs trees at head (unchanged neighbours), the PR body
  (`Spec changes:`, the closing issue), and the CI evidence the head rendered — counted only when
  its stamp names THIS head. No rubric, no implementation files.

## Grounding

- Oracle process rules 2–10 and `.agents/review.md` items 1–2 and 8 (rows not functions; rows
  derive from intent; provenance for "real shape" claims).
- The operator's reviewer-shape trial (claude.ai artifact "Reviewer shape trial", 2026-09-29;
  three rule sets × three oracle requirements). **R-HARD** (≤3 cols × ≤5 rows) split by count,
  not meaning — 10–14 IDs from one, cross-key rows dropped, constants pushed into prose, cells
  re-packed to fit the cap: **rejected**. **R-ATOMIC** (one value per cell, size a smell) and
  **R-JUDGE** (one question per table, same axes, plain values, no split for size): **adopted**,
  with the trial's own caveats in the lens checklist — a set is one value (strict atomicity
  exploded `{A, B}` into boolean columns and wide sparse tables), a cross-key row is a proof,
  a mostly-constant column may carry the rule being proven, and every split mints NEW rows
  (new scope → ⚖ + `🚧 WIP`) and moves IDs (alias anchors).

## Wiring (ADR-155)

**Identity.** `homelab-specs-reviewer[bot]` — its own GitHub App
([`docs/github-apps.yaml`](../github-apps.yaml): contents write, pull_requests write, issues
read, checks read, actions read; installed on the island repos). GitHub counts approvals per
identity, and the island repo's master ruleset requires 2 (`required_approvals` in `tofu/github`),
so this approval is structurally the second one — the code verdict (`homelab-reviewer`) and the
specs verdict can never collapse. The ESO chain is `agents/coordinator/specs-reviewer-git.yaml`
(the [`iac-lane.md`](iac-lane.md) sentinel's shape: Infisical key
`SPECS_REVIEWER_GH_APP_PRIVATE_KEY` → `GithubAccessToken` generator → Secret `specs-reviewer-git`,
key `GH_TOKEN`). The login is a literal in the script (`homelab-specs-reviewer`, no `[bot]`
suffix — `gh api user` 403s for an installation token; REST spells reviewers `x[bot]`, GraphQL
`x`, so every match strips the suffix).

**Dispatch.** A level-triggered CronWorkflow `specs-review` in `agent-coordinator`
(`agents/coordinator/specs-review-argo.yaml`: `*/5`, `Forbid` + mutex, 15-min deadline, the
agent-coordinator image, its own `specs-review` ServiceAccount — the gateway's `callers` key, #2685)
clones master and runs `agents/specs-reviewer-session.sh` — ONE layer,
not `reviewer-session.sh`'s launcher→pod shape, because this identity never executes or reads
hostile code: its inputs are a diff, a body and a CI log, and its LLM admission is the gateway's.
The tick holds no state; for every open non-draft PR of `SPECS_REVIEW_REPOS` (homelab today) at
its content commit (the newest NON-MERGE commit — `review-reflex.sh`'s grammar):

| state at the content commit | the tick does |
|---|---|
| a live own verdict (APPROVED / CHANGES_REQUESTED, never DISMISSED) | nothing — done |
| more than one live own verdict | ONE `AGENT_ERROR:` comment with a `head=` marker (idempotent), no label — this identity has no `issues:write` |
| no live `homelab-reviewer` APPROVED | nothing — the code gate goes first ("one old reviewer and THEN the new"; a Renovate PR's approval comes from the renovate-approve reflex, so this holds for it too) |
| CI not green, or label `agent/error` | nothing |
| no specs path and no rule-test path among the PR's files (REST, paginated; `review_path_re`: `(^\|/)specs/` or the repo's tests root, `gateway/tests/` here) | **mechanical** `--approve` with a fixed body, no LLM — the price of GitHub's repo-wide count; many per tick |
| a specs or rule-test path | an **LLM pass** — at most ONE per tick, the oldest candidate; the rest wait a tick. Inside it, the pinned `touched-rules` decides: no rule touched = the mechanical approval after all |

**Inputs: the context pack (ADR-156), built before admission.** An authenticated clone
(`http.extraHeader` preemptive auth) of the base branch + `pull/<n>/head`; the pinned
`allure-behavior-snippets` wheel (`SNIPPETS_VERSION`, verified against `SNIPPETS_SHA256`, extracted
and run with the image's stdlib `python3`); the round context the pack cannot fetch itself (PR body,
`issue-intent.md` = each closing issue's `## Acceptance` section, `prior-review.md` = the newest own
LLM review in any state, since a push dismisses it); the head's evidence pack (raw Allure results
+ `evidence.json` + `digest.md`) and the newest first-parent base commit's pack as baseline (its
`evidence.json` + commit) — both read anonymously from the `gateway-specs` bucket's web endpoint,
`evidence/<pr-N|base>/<sha>.tar.gz`, written by ci (`gateway/scripts/evidence-publish.sh`; until
2026-10-21 a `gateway-evidence` Actions artifact, which held ~2.1 GB of the org's 2 GB included
storage — that artifact stays the read fallback until the old runs expire). `evidence-pack` turns these into the model's inputs dir: touched rules,
their sections + the spec diff, the specs tree, `digest.md` (`Stamp:` / `Baseline:` + mechanical
findings), per-rule tables, `evidence/<RULE>.json`, attachments, and `process/` (RULES, CONVENTIONS,
briefs). A failed clone, wheel or pack is no review (fail CLOSED); ABSENT evidence is not a refusal:
the pack states it, and the evidence brief turns it into `E-STALE` / `NO_EVIDENCE` findings. The
model is CONFINED: it runs under `env -i` with exactly the gateway's dispatch env + OTEL + a
throwaway `HOME` (never `GH_TOKEN` / `GH_TOKEN_FILE`, and no `settings.json` — the images' permissive `permissions.allow` would union with the allow-list; both pinned by the self-test), its cwd is the
pack, and its tool scope is an allow-list — `Read(//<inputs>/**)` + `Glob`, `--permission-mode
default`, so in `-p` mode any read outside the inputs (the token file under `/var/run`, `/proc`,
`$HOME`) is denied rather than prompted; Grep/Bash/Write are not granted. The system prompt is
homelab's wiring lens (`agents/lenses/specs.md`, fetched from `LENS_BASE`, default the public
master raw URL; a fetch failure is no review) followed by the pinned finding contract, rows brief
and evidence brief from the pack's `process/briefs/`. The verdict is parsed from the model's `Verdict:` line and submitted
by the SCRIPT, **pinned to the reviewed head**: the head is re-read immediately before the
submit (moved = the verdict is dropped and the next tick reads the new head — a push during the
minutes the model runs must never land a verdict on an unreviewed head), and the review is
posted through the REST reviews endpoint with `commit_id` = the reviewed head (`APPROVE` →
`APPROVE`, `CHANGES_REQUESTED` → `REQUEST_CHANGES`); an unparsable result is no terminal. The
mechanical approval takes the same path.

**Evidence at head.** Only a run stamped `git.commit=<head>` in `environment.properties` counts
(CONVENTIONS § The head/artifact stamp); the pack's `Stamp:` line says whether it does. The gateway
suite runs against the PR head's source in-process, so its stamp carries no `image.digest`: it is
PR-head evidence, never built-image evidence (open question 2).

**Exit contract.** Every PR the tick posted on is re-read; a live own verdict at the content commit
must exist, else exit 10 (a silent green would mask a dead review plane — the
`reviewer-session.sh` idea, without its aside/label terminals).

**Belts.** Pushgateway `job/specs-review`: `specs_review_last_tick_timestamp_seconds` (every
tick, shadow and zero-PR ticks included — the `SpecsReviewTickStale` alert in
`argocd/resources/pushgateway/prometheusrule.yaml` reads it, 30 m), `specs_review_shadow`,
`specs_review_tick_verdicts{kind=mechanical|approve|request_changes|defer|error}` (per-tick
counts — a push replaces the group; `SpecsReviewNoProgress` fires when every tick for an hour
reported an `error` or a `defer`, the stuck-but-ticking case the heartbeat cannot see). The model
run is bounded by `timeout ${LLM_TIMEOUT_S}` (600 s) inside the pod's 900 s deadline, because a
deadline kill skips the EXIT trap and leaves the gateway session holding its slot until the 4 h
TTL. OTEL with `role=specs-reviewer` so the subscription spend
attributes. Self-test: `devbox run specs-review-self-test` (`bash -n` + the jq predicates on
fixtures; `diff-ci` row ready, its `ci.yaml` step is operator-direct).

**Cutover order (the operator; owning item FU-270 — App registered 2026-10-16).** The workflow lands first and runs in SHADOW
(the `specs-reviewer-git` Secret is `optional:true`; the script logs "specs-reviewer-git absent —
shadow, no verdicts" and exits 0 — it never reviews under another identity). Then: (1) create +
install the App (`scripts/github-app-bootstrap.sh homelab-specs-reviewer manifest|catch`), its key
into Infisical as `SPECS_REVIEWER_GH_APP_PRIVATE_KEY` (`… secrets`); (2) `… register` fills `appID` /
`installID` in `specs-reviewer-git.yaml` AND `app_id` / `install_id` in `docs/github-apps.yaml`,
`git mv`s the file from `agents/coordinator/scaffold/` into `agents/coordinator/` and lists it in
`kustomization.yaml` — one PR. It is parked, not listed with placeholders, on purpose: a placeholder
generator would sit `SecretSyncedError` → `ArgoCDAppDegraded`, and manifest-lint requires every
`agents/coordinator/*.yaml` to be listed; (3) the Secret
appearing IS the cutover — the next tick posts verdicts. Until then every homelab PR parks on its
second required approval and the operator merges by admin override (ADR-155 landed first, by
design); the alert belt is live from the first shadow tick.

## Shadow runs — harness × rail cells (gateway/PLAN.md step 3)

A shadow run measures which harness × rail **cell** could ride this reviewer, on PRs whose verdicts
are already known, without touching any PR. `agents/specs-reviewer-session.sh --shadow --harness
claude|opencode|goose [--rail R] [--tier T] <repo>#<n>[@<sha>] …` takes the cell's explicit
`POST /sessions` inputs and builds the SAME context pack as the live pass (`build_pack`, one
builder), with the same lens, briefs and prompt. It writes one record per PR (verdict, findings,
the admission answer without its token, the gateway's session row with its four token classes,
wall clock, harness exit / timeout) to `--out`. It writes nothing to GitHub: every `gh` call goes
through a read-only allow-list (`gh_shadow_allows`), and a write is refused with rc 97 before it
reaches the CLI. The self-test pins the allow-list table, the refusal of the live verdict writer
and the anomaly comment, and that a run installs the wrapper. It pushes no metrics.

**Replay fidelity.** The judged head is fetched by sha. The base is `merge-base(origin/<base>,
head)`. The PR body is the edit that was current at the live review (`as_of` = the first own
review at that head). The prior review is the newest own LLM review before `as_of`. The baseline is
the newest base push run that is an ancestor of that base. #2635 needs this: its first review
judged a body without `Spec changes:`, and the same head was approved after the body edit. Issue
intent, the lens and the wheel are today's, and each record says so.

**Where.** The `specs-review-shadow` WorkflowTemplate (`agents/coordinator/specs-review-argo.yaml`)
runs one cell per submission. It has its own mutex and a 1 h deadline, and the records come back
as its `shadow` artifact. Its `image` is a runtime parameter from `agents/images.env`: agent-base
for the opencode/goose cells (the harness image), agent-coordinator for the claude cells (the live
reviewer's image).

**Confinement per cell.** Every cell runs under `env -i` with the dispatch env verbatim plus OTEL
and a throwaway `HOME`. The harness adds only its prompt, system prompt and tool scope, never a
base URL, key or model ([GW-SESSIONS-ENV](../../gateway/specs/endpoints/sessions.md#gw-sessions-env)).
Tool scope differs by cell. claude keeps the live allow-list. opencode denies
edit/bash/webfetch/external_directory (`OPENCODE_PERMISSION`). goose has no path-scoped read, so
its `developer` builtin keeps a shell, and its records say `confinement: env-only`.

**Measurements: 2026-10-17, the first cell sweep.** Four merged PRs whose live verdicts are known were replayed at the heads the live reviewer judged:
- #2635 at `02c7fb58`, round 1: CHANGES_REQUESTED `R2`, no `Spec changes:` section;
- #2640 at `9639e99e`, round 1: CHANGES_REQUESTED `R4`, the GET row's fields contradict the schema;
- #2628 at `7af95c8f`: APPROVE;
- #2631 at `22706567`: a mechanical APPROVE.

One run per cell, through the deployed gateway (`2026.10.17-gfdebcd39b7bf`). Tokens are the gateway's session row, `in / out / cache read / cache write`. Model seconds are the harness wall clock only. No run timed out (`LLM_TIMEOUT_S` 600). Raw records, with the review bodies: [`specs-reviewer-shadow-2026-10-17.jsonl`](specs-reviewer-shadow-2026-10-17.jsonl).

| cell (model) | PR | verdict | known finding | extra blocking | tokens | req | model s |
|---|---|---|---|---|---|---|---|
| claude@anthropic (claude/sonnet) — the control | #2635 | CHANGES_REQUESTED | ✅ R2 | 0 | 10 / 2.8k / 171k / 50k | 5 | 22 |
| | #2640 | CHANGES_REQUESTED | ✅ R4 | 0 | 12 / 5.7k / 456k / 88k | 6 | 45 |
| | #2628 | APPROVE | ✅ | 0 | 8 / 2.5k / 161k / 33k | 4 | 23 |
| claude@opencode, tier standard (opencode-go/deepseek-v4-flash) | #2635 | CHANGES_REQUESTED | ✅ R2 | 0 | 71k / 18k / 487k / 0 | 13 | 100 |
| | #2640 | CHANGES_REQUESTED | ✅ R4 | 0 | 106k / 30k / 1.21M / 0 | 17 | 198 |
| | #2628 | APPROVE | ✅ | 0 | 73k / 23k / 692k / 0 | 13 | 125 |
| claude@opencode, tier heavy, the reviewer's policy (opencode-go/claude-sonnet-4-6) | #2635, #2640, #2628 | no verdict | — | — | 0 / 0 / 0 / 0 | 1 each | ~2 |
| opencode@opencode, tier standard (opencode-go/deepseek-v4-flash) | #2635 | CHANGES_REQUESTED | ✅ R2 | 0 | 75k / 19k / 448k / 0 | 12 | 106 |
| | #2640 | CHANGES_REQUESTED | ✅ R4 | 1 (`R2` GW-METRICS: no ⚖ on two decision rows) | 104k / 30k / 1.23M / 0 | 19 | 319 |
| | #2628 | APPROVE | ✅ | 0 | 85k / 43k / 842k / 0 | 16 | 214 |
| goose@openrouter, role **worker** (deepseek/deepseek-v4-flash) | #2635 | APPROVE | ❌ missed R2 | 0 | 39k / 14k / 244k / 0 | 12 | 78 |
| | #2640 | no verdict | — | — | 65k / 18k / 685k / 0 | 18 | 139 |
| | #2628 | APPROVE | ✅ | 0 | 39k / 22k / 378k / 0 | 17 | 230 |

#2631 came out `mechanical` in every cell: touched-rules finds no rule, so no LLM ran, matching the live verdict.

**What the sweep found.** This is a comparison, not a ruling: which cell the live reviewer rides stays the operator's call.
- **The reviewer's Go fallback is dead upstream.** The `claude@opencode` cell at the reviewer's policy tier (heavy) got `400 api_error "Upstream request failed: Model is unavailable."` for `opencode-go/claude-sonnet-4-6`. It was reproduced directly against the gateway. The same session shape at tier standard (deepseek-v4-flash) works. The heavy id comes from `model-classes.json`'s `ids.opencode-go`, copied into the gateway policy. The matrix's Go "sonnet slot" is `kimi-k3` ([`opencode-model-matrix.md`](../spikes/opencode-model-matrix.md)). Until the policy changes, a reviewer that overflows the subscription onto Go gets no review.
- **goose@openrouter.** goose ran under `--role worker`, because the reviewer role has no openrouter rail and the policy stays unchanged. The cell missed the one known finding on #2635. On #2640 it ended without a `## Specs review` body. Its tool scope is env-only (`developer` shell). opencode on the same model family, deepseek-v4-flash, caught both known findings. So on this corpus the gap is the harness, not the model.
- **opencode@opencode** reproduced both known verdicts. It raised one extra blocking finding the live reviewer and the claude cells did not: missing `⚖` on two GW-METRICS decision rows the PR body called a choice. Whether that is valid is a rows-brief question, not a cell defect.
- **Cost shape.** The Go/deepseek cells read 3–5× the claude control's cache and run 4–7× longer, on a flat-rate rail. Claude reports list-price `total_cost_usd` even on Go; that number is not a charge.
- **Repeatability.** The two claude cells ran twice; the first runs logged records only, so the table uses the second runs. Both runs gave the same verdicts.
- **No GitHub writes.** No shadow run wrote a review, comment or label on the four PRs: their timelines show nothing after the sweep began (2026-10-17T07:12Z) beyond #2654's own cross-reference at 06:32Z.

## The portable process (ADR-156, 2026-10-16)

Every repo that keeps `specs/` runs the SAME requirements → tests → evidence → review process, or
the process does not work: a row judged one way in homelab and another in oracle-fleet is two
processes. Homelab took oracle-fleet's row-judgment rules and the reviewer-shape trial's lessons,
but none of the evidence side. `gateway/tests/conftest.py` is oracle's `tests/evidence.py` "minus
allure", and `evidence_render.py` emits one line per test (outcome, module, duration). That is a
producer limit, not a prompt omission: no steps, parameters, attachments or observed values exist
to review.

**One home.** [`allure-behavior-snippets`](https://github.com/teststuffstash/allure-behavior-snippets),
the wheel every repo already pins, carries the process, versioned together with its tools: the
numbered spec rules, conventions § Prime rule of reporting (given/when/then steps, a verdict step
per claim, attachments under the step they support), the two briefs, `touched-rules.py` and the
context-pack builder. A repo adopts by bumping its pin. oracle-fleet's `docs/process/` and this
repo's `gateway/specs/README.md` §Rules become pointers. The table-shape checklist ships there
marked as a candidate under the operator's iteration (the 2026-09-29 hold), advisory only.

**One reviewer, two briefs.** The briefs are maintained and evaluated apart, but one session runs
both and posts ONE review under ONE identity (`homelab-specs-reviewer`; the two-approval count is
unchanged):
- the **rows brief**: intent source, ⚖ flags + `Spec changes:`, schema ⇄ page, removed proofs,
  glossary, shape (advisory). Extracted from oracle's `.agents/review.md` WITHOUT its code-review
  duties.
- the **evidence brief**: oracle's `.agents/evidence-review.md` (a seat prototype there, never
  wired). Per-ROW proof (`NO_EVIDENCE`, `ROW_UNPROVEN`, `BARE_ROW`, `FAILED`, `VANISHED`,
  `UNIT_ONLY` ⚖, `WORLD_UNNAMED`), observed values traced through steps and attachments, baseline
  differences, and Allure hygiene: the three worst codes as notes, the same unresolved code on the
  same case across two reviews = blocking `HYGIENE_REPEAT`.
  `HYGIENE_REPEAT` blocks on ANY case in the pack, including cases the PR's diff never touched
  (operator, 2026-10-17, on #2645 round 3: "block anywhere").

Intent is read before evidence, and neither brief receives implementation code. A blocking finding
from either brief means `CHANGES_REQUESTED`. Two independent reviewer sessions were rejected
because the input saving is small and disagreement is the costly part. Measured on oracle's last
pack (11 touched rules, ~50k tokens: spec sections ~19.5k, `evidence.json` ~20k, `digest.md`
~7.7k), a split runs ~77k against ~57k for one session, and every disagreement costs another worker
round that the coordinator has no way to arbitrate.

**The finding contract (worker-facing).** Every blocking finding carries a stable ID, the rule or
case, the violated requirement, the observed evidence, and what would satisfy it. The reviewer
reconciles its findings before posting: no two requested fixes may contradict, and advisory shape
stays distinguishable from missing proof. Every round after the first receives the previous review
and marks each of its findings `resolved` / `still open` before reading new behaviour.

**The context pack** (oracle's `scripts/evidence-review.sh` contract plus homelab's additions):
- touched rules (`touched-rules.py`, which also reaches rules through changed test labels and event
  mappings, so dispatch becomes "touches a rule", not "touches a specs path");
- each touched rule's section + the spec diff, with the unchanged neighbouring specs as reference;
- the closing issue's acceptance text (fetched, not just referenced);
- `evidence.json` + `digest.md` + the raw Allure results and attachments, from the pack CI
  publishes to the `gateway-specs` bucket, which the tick downloads into its read-only inputs dir (the model has no fetch);
- the baseline: master's evidence, naming its commit and run scope, so a test that was not run is
  not read as a vanished proof;
- the previous review.

**PR-head evidence is not built-artifact evidence.** A stamp in `environment.properties` proves
nothing about an image: digest evidence requires the suite to run AGAINST the built image and the
report to record that digest (open question 2).

**Order** (status kept here):
1. This record — DONE 2026-10-16 (#2621).
2. The homelab launcher inputs that need no Allure (issue acceptance text, previous review,
   baseline, finding contract with round tracking) — DONE 2026-10-16 (#2622).
3. Snippets v0.5 carries the briefs, conventions, `touched-rules` and the pack builder — DONE
   (v0.5.0; v0.5.1 adds `evidence/<RULE>.json`; v0.5.2 reads `||`-divided decision tables and plain sub-sections, so the gateway rules join; v0.6.1 (2026-10-23, the GW-REDACT walkthrough) adds rule 11 — the requirement describes the system, never its tests — the header-is-the-parameter-list convention, rows-brief checks 8–9 and the `ROW_UNKEYED` / `HEADER_UNTHREADED` digest codes; homelab's `spec_gate.py` ratchets the same four join counts). oracle-fleet keeps its own process and v0.4.2
   until the gateway has proven this one (operator, 2026-10-16).
4. Gateway tests on Allure, the raw results uploaded as the `gateway-evidence` CI artifact — DONE
   2026-10-16 (#2623; ci.yaml c63dbe1); moved to the `gateway-specs` bucket 2026-10-21
   (`gateway/scripts/evidence-publish.sh` — Actions storage quota).
5. The evidence pass live — LIVE 2026-10-16 (#2624; first pass #2628: 3 rules, 9 turns, 34 s). Next:
   measure tokens, worker rounds, invalid findings and coordinator interventions per completed PR.

Cheaper helper subagents wait for that data, and they need a gateway change first: a session is
admitted with one model and the gateway rewrites every request to it
([GW-SESSIONS-ENV](../../gateway/specs/endpoints/sessions.md#gw-sessions-env)), so a cheaper
subagent bills at the lead's model today. oracle-fleet's human codeowner gate is a separate
decision; adopting the briefs does not remove it.

## Open questions

1. **Identity** — RESOLVED by ADR-155: a distinct App (`homelab-specs-reviewer`), its own
   CronWorkflow, two required approvals on the island repo; the same-App supersession variant was
   rejected there (one identity cannot make the count 2, and a later `CHANGES_REQUESTED` would
   silently overwrite the code verdict).
2. **Evidence stamp.** Found while building (2026-10-16): the stamp was `GITHUB_SHA`, which on a
   `pull_request` run is the test-MERGE commit — it could never name a PR head, so check 6 would
   have read "stale" on every PR. `gateway/tests/conftest.py` now prefers the event payload's
   `pull_request.head.sha` (push runs keep `GITHUB_SHA`), and the render also goes to stdout
   between markers. Still open: the stamp carries the git sha + policy sha256, not the image
   digest the specs README (rule 5) names — evidence is from the PR's test run, not from the built
   image; a digest stamp needs the image build to run the suite.
3. **`Spec changes:` as a deterministic pre-open check** (the 2026-07-25 oracle retros asked):
   the reviewer is the backstop, not the first line. Unchanged.
4. **Reach.** Oracle-fleet keeps its rule-1 codeowner gate; replacing it is per island, operator's
   call: install the App there, add the repo to the `specs-reviewer-git` chain's `repositories` + `SPECS_REVIEW_REPOS`,
   set `required_approvals = 2` in `tofu/github`.
5. **The half-join guard and parametrize-from-spec — tool flag or repo gate?** The oracle handoff
   (`.handoff/oracle/done/20261020-2107-specs-ruleset-and-golden-example-for-the-specs-reviewer.md`
   §4 items 4–5, 2026-10-20) names the hazard the joined render carries: a rule joins as soon as ONE
   description cell keys a case and every other row paints `∅ unproven` — rows that mostly do have
   tests under ids that differ from the cell — and nothing gates it. Two snippets-shaped remedies,
   both undecided (⚖): a ratchet on `∅` rows inside a joined table (per rule, baseline = today's
   count, never up; `allure-evidence` already computes `stats["unproven"]`), and a
   parametrize-from-spec helper that reads the GFM table under a rule heading into `pytest.param`s
   (ids = description cells, argnames = header) so the rows live once, in the .md. Whether each is a
   tool flag both repos get from the pin (`gateway/specs/README.md` §Rules) or a repo gate beside
   `spec_gate.py`'s join ratchet is the open fork; homelab#2860 (GW-REDACT rewritten to v0.6.1) is the
   rule where they would first apply. File them in the snippets repo when the pin moves.
