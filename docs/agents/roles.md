# Roles — the role axis, inventoried

**Status: created 2026-07-27 (operator sessions of 2026-07-27; the FU-100 build + the meta-11
prod-outage role-gap analysis).** This is the home of the **role** axis from
[`platform-and-stacks.md`](platform-and-stacks.md) §Composition axes. One page per question the
axes model raises: *what does a role consist of, which exist, what does a new one cost?*

## What a role is

```
role = brief (recipe/rubric/skill)
     + boundary (ns, credentials, egress, write scope)
     + activation machinery:
         1. dispatch predicate   — WHEN does it fire (scan clause, reviewable check, schedule, alert)
         2. edge trigger         — emitter arm → Sensor dep → submit Workflow (near-instant path)
         3. backstop             — level-triggered cron that re-derives the edge's work
         4. idempotency keys     — atomic dispatch key + in-session self-guard
         5. capacity gates       — subscription latch/semaphore, budget-capped keys
         6. breaker hooks        — agent/error exclusion, rounds-max, rate caps
```

The machinery outweighs the brief ~10:1 (count the reviewer below). Consequences, both proven:
standing up a new role is machinery design, not prompt-writing; and N "roles" that share
machinery are really **one machinery family × N briefs** — see §Lenses. Rendering a role
per-stack means the AgentStack Composition renders the *whole* machinery set (FU-080's
coordinate leg, FU-100's review leg — both changed zero prompts, zero images).

Two platform-wide design rules bound every brief (operator, 2026-07-27):

- **Elicit, don't inject.** Judgment roles get question-shaped briefs ("what breaks when this
  ships?"), not opinion checklists — keeps worker context lean and the model comparison
  (FU-095) uncontaminated. Opinions that must exist live in versioned lens sources (§Lenses),
  never inline in briefs.
- **Mechanism > advice > nothing.** A practice the platform can render (topology spread, probe
  scaffolds, chart defaults) becomes a Composition/chart-template default; the lens reviews
  only what can't be defaulted.

## Machinery families

| family | fires on | members (live) | members (planned) |
|---|---|---|---|
| dispatch-on-work | scan-emitted work unit (issue/PR state) | fixer | infra-fixer (FU-106) |
| dispatch-on-event | reviewable transition (exporter edge) | reviewer | + lenses (FU-101) |
| dispatch-on-schedule | cron (level-triggered) | scout; retro (suspended) | prober (FU-102), audit-pass (FU-101 e-ITS) |
| dispatch-on-alert | Alertmanager firing | — | responder (FU-103) |
| dispatch-on-goal | human-queued `goal` issue | — (meta-coordinator does this by hand) | researcher (FU-105); meta-coordinator machinery (FU-086/FU-090) |

## Live roles

### fixer (worker)

- **brief**: per-repo `.agents/fix.yaml` recipe (launcher-owned `--recipe`, never LLM-assembled — ADR-094)
- **boundary**: fixer ns == repo; branch-scoped ~1h git token, budget-capped OpenRouterKey; per-stack egress CNP
- **machinery**: predicate = `coordinator-scan.sh` clauses (queued-dispatch, c4c5, changes-requested,
  merge-conflict, unarmed-major; deps-closed FU-087, lane-free, repo-dispatchable, capacity);
  edge = `/coordinate` doorbell (item units = FU-085/FU-086 remaining); backstop = `coordinate-<stack>`
  cron; key = pod name `agent-<project>-<task>-r<round>` (atomic create, 2026-07-21); capacity =
  subscription-latch pre-spawn + per-key budget; breakers = agent/error excluded everywhere, ROUNDS_MAX

### coordinator

- **brief**: `agents/coordinator/README.md` (loaded by absolute path; cwd = stack `mainRepo`)
- **boundary**: `<stack>-agents` ns as `agentstack-loop`, broker `role=coordinator` token;
  writes = labels/comments/merge via `gh` (+ W1 ⚑ gap-flags, ADR-086; W2+ = FU-059)
- **machinery**: predicate = `coordinator-scan.sh` (deterministic gate — no LLM on empty wakes);
  edge = `/coordinate` doorbell → `coordinate-perstack` routing (coordinate-argo.yaml); backstop =
  `coordinate-<stack>` */10 cron; key = `coordinator-scan` mutex + item-scoped dispatch (ADR-094);
  capacity = subscription semaphore (global) / latch (per-stack); breakers = per TICK-LOG §Loop-safety

### reviewer

- **brief**: per-repo `.agents/review.md` rubric (+ lens attachments — §Lenses)
- **boundary**: distinct `homelab-reviewer` App (self-approval blocked), broker `role=reviewer`
  token per-run; full-repo read
- **machinery**: inventoried guard-by-guard in [`merge-path-fsm.md`](merge-path-fsm.md)
  (MP-T03/T04/T08). predicate = reviewable (`review-reflex.sh`: armed ∧ green ∧ (review_required
  ∧ ¬bot_approved_head ∨ reviewable_again)); edge = exporter POST → `review` Sensor → global +
  `review-perstack` triggers (FU-100, 2026-07-27); backstop = global */15 + `review-<stack>` crons;
  key = pod-label check + STEP-0 self-guard (deterministic-name key = FU-092, open gap MP-G02);
  capacity = semaphore + latch; breakers = verdict-count trip, agent/error, merge-commit staleness guard

### retro

- **brief**: retro brief (observability-and-retro.md Part B; cross-review cell contract)
- **boundary**: budget-capped ephemeral key; must not hold the fixer WIP slot (FU-058 P3)
- **machinery**: backstop = `retro-session` CronWorkflow (retro-argo.yaml) — **born suspended,
  hand-fired** (FU-058); predicate = `minNewTasks` ledger level-trigger; no edge; keys/breakers
  inherit launcher defaults. Planned duty: harvests the local rules delta (§Lenses maintenance).

### scout (model-scout)

- **brief**: scout probe (model-routing.md §M7)
- **boundary**: ephemeral only-free capped keys (canary)
- **machinery**: backstop = weekly `model-scout` cron (reflexes-argo.yaml); no edge; FU-095(b)
  extends its candidate source to a maintained rotation. Documented under the model axis today;
  it is a *role* — machinery listed here, content stays in model-routing.md.

### meta-coordinator

- **brief/state**: `agents/coordinator/TICK-LOG.md` (practice) + `meta-state.md` (in-flight chains)
- **boundary**: the operator's jail sessions — full context, human-gated
- **machinery**: **zero** — every meta-11 incident action (detect/diagnose/remediate/harden) was
  manual. First machinery pieces, tracked: `arbitrate` scan clause (FU-086), follow-ups harvest +
  goal decomposition (FU-090), close-the-loop C6 (MP-G03).

## Lenses (FU-101)

A **lens** = the reviewer/advisor machinery + a different brief sourced from an **externally
maintained standard**, selected by a deterministic artifact-class predicate, advisory-first.
Staleness is outsourced (OWASP/RIA maintain content; we pin versions and treat a standard's new
release like a dep bump); the local delta (platform-specific lessons, e.g. paired rolls) stays
incident-evidenced in merge-path-fsm.yaml style — the retro role maintains it.

| lens | source (pinned) | selection predicate | first mode | status |
|---|---|---|---|---|
| k8s-prod | k8s production checklist class | `chart*/templates/` or manifest dirs touched, or diff adds a workload `kind:` | advisory | **LIVE 2026-07-27** (`agents/lenses/k8s-prod.md`) |
| helm | helm-best-practices | `chart*/` touched | advisory | **LIVE 2026-07-27** (`agents/lenses/helm.md`) |
| ASVS | OWASP ASVS (pinned major) | auth/input/session code; new public endpoint | advisory | pending (predicate needs a code-class detector, not paths) |
| e-ITS | RIA e-ITS baseline | stack-level, scheduled audit-pass | audit report | pending (seeded by FU-105's IdP research output) |

Mechanism (built with FU-101's first two lenses): `reviewer-session.sh` computes the diff class
in-pod (deterministic — changed paths + `gh pr diff` grep), fetches matching
`agents/lenses/<lens>.md` from the public homelab repo raw (platform-owned, no image rebuild),
and appends them to the system prompt after the project rubric. The advisory contract lives
INSIDE each lens file (`LENS(<name>):` findings are Follow-ups, never the verdict); fetch
failure skips the lens loudly. The per-stack advisory→blocking knob is not yet rendered (needs
the AgentStack claim + a launcher read — do it when the first lens earns teeth).

Per-stack claim knob graduates a lens advisory → blocking. Audit-lane model rules (reasoning
tier allowed, dual-model worth it) are FU-095's.

## Planned roles (machinery checklists)

- **prober** (FU-102) — the agentic canary. Product-contract probes (oracle UC-1 probe-e2e is
  the proven brief); prod-read + report-only, $1 ephemeral keys. predicate = post-deploy +
  schedule; edge = deploy doorbell; backstop = cron; key = (endpoint, artifact digest);
  breaker = inert 🌱 issues + rate cap. Detection belts stack: FU-099 blackbox (seconds, dumb)
  → prober (minutes, contract-deep) → responder.
- **responder** (FU-103) — alert-triggered triage. **v1 machinery LIVE 2026-07-27
  (deterministic, report-only):** predicate = Alertmanager firing (fan-out route `continue:
  true` in `tofu/monitoring.tf` → the `/alert` webhook); edge = Sensor `/alert` (third webhook
  on the agent-loop EventSource) → `respond` WorkflowTemplate
  (`agents/coordinator/responder-argo.yaml`) — a SCRIPT (no LLM) that fingerprint-dedupes and
  files ONE evidence issue per new alert (bot-authored → inert, breaker #1; scan 🌱 surfaces
  it); backstop = none (alerts are level-triggered); key = `alert-fp:<fingerprint>` in the open
  issue body; capacity = Sensor rateLimit 6/min (no subscription draw in v1). Graduation knobs
  (NOT built): the LLM triage session behind the same edge, then the remediation whitelist
  (the FU-090 `selfQueue` pattern).
- **researcher/planner** (FU-105) — spec/requirements research. dispatch-on-goal (human-queued
  `goal` issue, FU-090(c) shape); reasoning tier + dual-model review (FU-095 rules); output =
  spec PRs through the codeowner gate. **Boundary is the new piece: open-web egress** — a
  `research` egress profile (proxy-logged) or claude-harness server-side WebSearch; safe because
  the pod holds no cluster creds and a spec-branch-only git token. Consumers in order: sleep
  spec retrofit (FU-095 prerequisite), IdP greenfield (whose EITS output seeds the e-ITS lens).
  **First mode BUILT 2026-07-27:** sleep-tracking `.agents/research.yaml` (recipe: specs/-only
  boundary, un-armed PR = the human gate until a CODEOWNERS ruleset exists, FU-069 breaker),
  `goal` label + goal issue sleep-tracking#36, claim `claudeTier: true` (sleep-iac#21), egress =
  claude server-side WebSearch (no dial change — WebFetch stays blocked and the brief says so).
  Dispatch is operator-manual until FU-090(c) graduates; git token is the standing per-repo
  broker token (branch-scope narrowing = open gap, noted in FU-105).
- **infra-fixer** (FU-106) — the -iac devops role. Works the **-iac wrapper layer** (charts stay
  target-agnostic — §contract/fulfillment in FU-106); input = `values.schema.json` diff (the
  typed infra delta), fulfillment = enriched **bump PR** (chart pin + claim change in ONE -iac
  commit — atomic at the deploy boundary, the meta-11 paired-rolls rule generalized); mechanical
  (schema-valid, within FU-093 quota) rides the ADR-084 CI-only lane, judgment stays
  codeowner-gated. Hard boundary: wires secret *references*, never values. Detector built
  2026-07-27 (`agents/infra-schema-diff.sh` — the typed delta + `enrichment_needed` bit);
  scan clause + dispatch = the remaining machinery.
- **audit-pass** — not a role: reviewer machinery × e-ITS lens × schedule predicate (dissolved
  the planned "auditor").

## SLO machinery (not a role — stack policy)

The stack declares `slo: {endpoint, probe, availability, errorBudget}` on its AgentStack claim;
the platform renders the FU-099 blackbox probe, burn-rate alerts, the responder's alert edge,
and the teeth: **a stack that burnt its error budget gets its auto-merge lane demoted to
codeowner-gated** (FU-104). Zero opinions in any brief; "harder to ship something that breaks"
enforced by contract.
