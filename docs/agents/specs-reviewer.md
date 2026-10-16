# The specs reviewer — the second review identity over `specs/` and its evidence

> Design note for [`agents/lenses/specs.md`](../../agents/lenses/specs.md) (the brief, rules only).
> Decided by [ADR-155](../adr.md#adr-155--the-specs-reviewer-is-a-second-app-identity-and-the-island-repo-requires-two-approvals-2026-10-16);
> built 2026-10-16 (dispatch `agents/specs-reviewer-session.sh`, workflow
> `agents/coordinator/specs-review-argo.yaml`, identity `agents/coordinator/scaffold/specs-reviewer-git.yaml`, parked until the App exists).
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
specs verdict can never collapse. The ESO chain is `agents/coordinator/scaffold/specs-reviewer-git.yaml`
(the [`iac-lane.md`](iac-lane.md) sentinel's shape: Infisical key
`SPECS_REVIEWER_GH_APP_PRIVATE_KEY` → `GithubAccessToken` generator → Secret `specs-reviewer-git`,
key `GH_TOKEN`). The login is a literal in the script (`homelab-specs-reviewer`, no `[bot]`
suffix — `gh api user` 403s for an installation token; REST spells reviewers `x[bot]`, GraphQL
`x`, so every match strips the suffix).

**Dispatch.** A level-triggered CronWorkflow `specs-review` in `agent-coordinator`
(`agents/coordinator/specs-review-argo.yaml`: `*/5`, `Forbid` + mutex, 15-min deadline, the
agent-coordinator image) clones master and runs `agents/specs-reviewer-session.sh` — ONE layer,
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
| no `(^\|/)specs/` path among the PR's files (REST, paginated) | **mechanical** `--approve` with a fixed body, no LLM — the price of GitHub's repo-wide count; many per tick |
| a specs path | an **LLM pass** — at most ONE per tick, the oldest candidate; the rest wait a tick |

**The gateway seam (FU-270 dogfood).** The LLM pass is the first real consumer of
[`POST /sessions`](../../gateway/specs/endpoints/sessions.md): body `{stack: platform, role:
reviewer, task: "specs-review <repo>#<n>", round: 0, harness: claude}` (no new role — `reviewer`
is right: the subscription first, Go as failover). `decision: defer` → log reason +
`retry_after_s`, stop; the next tick retries (never an in-process poll). `decision: dispatch` →
the returned `env` map is exported VERBATIM as the LLM env ([GW-SESSIONS-ENV](../../gateway/specs/endpoints/sessions.md#gw-sessions-env):
`ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_MODEL`, nothing LLM-shaped added —
the workflow renders no `ANTHROPIC_*` of its own), and the session is released on exit
(`DELETE /sessions/{id}`, a trap). The `review` WorkflowTemplate's subscription-capacity
semaphore is deliberately NOT carried: that is the old proxy's capacity model; the rail cap is now
the gateway's. Its row in the access inventory: [`access.md`](../../gateway/specs/access.md).

**Inputs, exactly the lens's scope — built before admission, each checked.** An authenticated
clone (`http.extraHeader` preemptive auth) of the base branch + `pull/<n>/head`; `git diff
origin/<base>...pr -- ':(glob)**/specs/**'`; the PR title/body; the `specs/` trees at head
extracted with `git archive`; the head's evidence (below). Any input that fails to fetch — or a
`specs.diff` that comes back empty although the PR's files name a specs path — is no review
(fail CLOSED: a blocking lens must never read an empty input as clean). The model is CONFINED:
it runs under `env -i` with exactly the gateway's dispatch env + OTEL + a throwaway `HOME`
(never `GH_TOKEN` / `GH_TOKEN_FILE` — pinned by the self-test), its cwd is the inputs dir, and
its tool scope is an allow-list — `Read(//<inputs>/**)` + `Glob`, `--permission-mode default`, so
in `-p` mode any read outside the inputs (the token file under `/var/run`, `/proc`, `$HOME`) is
denied rather than prompted; Grep/Bash/Write are not granted. The lens is its WHOLE system prompt
(fetched from `LENS_BASE`, default the public master raw URL) — a fetch failure is no review and
a non-zero exit. The verdict is parsed from the model's `Verdict:` line and submitted
by the SCRIPT, **pinned to the reviewed head**: the head is re-read immediately before the
submit (moved = the verdict is dropped and the next tick reads the new head — a push during the
minutes the model runs must never land a verdict on an unreviewed head), and the review is
posted through the REST reviews endpoint with `commit_id` = the reviewed head (`APPROVE` →
`APPROVE`, `CHANGES_REQUESTED` → `REQUEST_CHANGES`); an unparsable result is no terminal. The
mechanical approval takes the same path.

**Evidence at head.** `gh run list --commit <head> --workflow ci.yaml` → the completed, successful
run → `gh run view --log` → the `evidence-render: BEGIN … END` block
(`gateway/scripts/evidence_render.py` prints its render to stdout since 2026-10-16 — the step
summary has no API and `specs/evidence/` is gitignored) → counted only when its stamp is
`git <head sha12>`; anything else reads "evidence: none at head" with the reason, and the lens's
check 6 does the rest.

**Exit contract.** Every PR the tick posted on is re-read; a live own verdict at the content commit
must exist, else exit 10 (a silent green would mask a dead review plane — the
`reviewer-session.sh` idea, without its aside/label terminals).

**Belts.** Pushgateway `job/specs-review`: `specs_review_last_tick_timestamp_seconds` (every
tick, shadow and zero-PR ticks included — the `SpecsReviewTickStale` alert in
`argocd/resources/pushgateway/prometheusrule.yaml` reads it, 30 m), `specs_review_shadow`,
`specs_review_tick_verdicts{kind=mechanical|approve|request_changes|defer|error}` (per-tick
counts — a push replaces the group). OTEL with `role=specs-reviewer` so the subscription spend
attributes. Self-test: `devbox run specs-review-self-test` (`bash -n` + the jq predicates on
fixtures; `diff-ci` row ready, its `ci.yaml` step is operator-direct).

**Cutover order (the operator; owning item FU-270).** The workflow lands first and runs in SHADOW
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
