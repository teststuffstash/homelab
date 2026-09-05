# Roles — the role axis, inventoried

**This doc owns the role axis** from [`platform-and-stacks.md`](platform-and-stacks.md)
§Composition axes — one page for the three questions that axis raises: *what does a role consist
of, which exist, and what does a new one cost?* Written out of the FU-100 build and the meta-11
prod-outage role-gap analysis. The platform map (which role runs where) is
[`README.md`](README.md); per-role status is coarse here on purpose — the tracker and the cluster
are the authorities.

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

Three platform-wide design rules bound every brief (operator, 2026-07-27; the third
2026-09-01):

- **Elicit, don't inject.** Judgment roles get question-shaped briefs ("what breaks when this
  ships?"), not opinion checklists — keeps worker context lean and the model comparison
  (FU-095) uncontaminated. Opinions that must exist live in versioned lens sources (§Lenses),
  never inline in briefs.
- **Mechanism > advice > nothing.** A practice the platform can render (topology spread, probe
  scaffolds, chart defaults) becomes a Composition/chart-template default; the lens reviews
  only what can't be defaulted.
- **Prefetch, don't fetch — "grep > tool call."** Every deterministic read a ride would make as
  an LLM tool call (the issue + its comments, the review thread, the failing CI log, the branch
  log) is gathered by the LAUNCHER with cheap machinery before the pod exists and materialized
  into the ride (`/work/context/`, homelab#1175, #1205); a tool call costs prompt tokens, wall-clock,
  and — when it fails — an error-recovery turn, and a REQUIRED read that fails is a deferral
  before dispatch, never a ride that starts on half its directive (the #969 no-op, homelab#1069).
  A recipe's "first read X" line names a file, not a command.

## Machinery families

| family | fires on | members (live) | members (planned) |
|---|---|---|---|
| dispatch-on-work | scan-emitted work unit (issue/PR state) | fixer; infra-fixer (FU-106 — detector + infra-enrich 2026-07-27, oracle-iac twin 2026-08-02; both -iac repos have merged rides) | |
| dispatch-on-event | reviewable transition (exporter edge) | reviewer | + lenses (FU-101) |
| dispatch-on-schedule | cron (level-triggered) | scout; retro | prober (FU-102), audit-pass (FU-101 e-ITS) |
| dispatch-on-alert | Alertmanager firing | responder v2 (triage-first, GitOps-verbs) | remediation whitelist; selfQueue |
| dispatch-on-goal | a human-queued mission (research) / Goal issue | researcher (first mode proven E2E 2026-07-27 — sleep spec PR #38) | FU-090(c) auto-dispatch; meta-coordinator machinery (FU-086/FU-090) |

## Live roles

### fixer (worker)

- **brief**: per-repo `.agents/<class>.yaml` recipe (launcher-owned `--recipe`, never LLM-assembled — ADR-094).
  The brief is THREE layers — a platform-generated **environment card** (from the claim knobs) + a stack-owned
  **task-type brief** (`fix`/`build`/…) + **deterministic selection** (a `task/*` label). Design + division of
  labor: [`fixer-context.md`](fixer-context.md) (FU-114, born from the #48 no-docker autopsy — today only `fix`
  exists and the environment is unadvertised, which primed a `fixer.docker:true` ride to assume "no docker")
- **boundary**: fixer ns == repo; branch-scoped ~1h git token, budget-capped OpenRouterKey; per-stack egress CNP
- **machinery**: predicate = `coordinator-scan.sh` clauses (queued-dispatch, c4c5, changes-requested,
  merge-conflict, unarmed-major; deps-closed FU-087, footprint-free (ADR-097 Touches: intersection)
  + REPO_MAX_WIP/REPO_PR_CAP ceilings, repo-dispatchable, capacity);
  edge = `/coordinate` doorbell (item units shipped — ADR-094/FU-086, archived; reviewer verdicts
  ride a Sensor fast-path); backstop = `coordinate-<stack>`
  cron; key = pod name `agent-<project>-<task>-r<round>` (atomic create, 2026-07-21); capacity =
  subscription-latch pre-spawn + per-key budget; breakers = agent/error excluded everywhere, ROUNDS_MAX

### coordinator

- **brief**: `agents/coordinator/README.md` (loaded by absolute path; cwd = stack `mainRepo`)
- **boundary**: `<stack>-agents` ns as `agentstack-loop`, broker `role=coordinator` token;
  writes = labels/comments/merge via `gh` (+ W1 ⚑ gap-flags, ADR-086; W2+ = FU-059)
- **machinery**: predicate = `coordinator-scan.sh` (deterministic gate — no LLM on empty wakes);
  edge = `/coordinate` doorbell → `coordinate-perstack` routing (coordinate-argo.yaml); backstop =
  `coordinate-<stack>` */30 cron; key = `coordinator-scan` mutex + item-scoped dispatch (ADR-094);
  capacity = subscription semaphore (global) / latch (per-stack); breakers = per TICK-LOG §Loop-safety

### reviewer

- **brief**: per-repo `.agents/review.md` rubric (+ lens attachments — §Lenses)
- **boundary**: distinct `homelab-reviewer` App (self-approval blocked), broker `role=reviewer`
  token per-run; full-repo read
- **machinery**: inventoried guard-by-guard in [`merge-path-fsm.md`](merge-path-fsm.md)
  (MP-T03/T04/T08). predicate = reviewable (`review-reflex.sh`: armed ∧ green ∧ (review_required
  ∧ ¬bot_approved_head ∨ reviewable_again)); edge = exporter POST → `review` Sensor → global +
  `review-perstack` triggers (FU-100, 2026-07-27); backstop = global */15 + `review-<stack>` crons;
  key = pod-label check + STEP-0 self-guard (deterministic-name key (repo, pr, head-sha8) —
  shipped 2026-07-27, MP-G02 closed);
  capacity = semaphore + latch; breakers = verdict-count trip, agent/error, merge-commit staleness guard

### retro

- **brief**: retro brief (observability-and-retro.md Part B; cross-review cell contract)
- **boundary**: budget-capped ephemeral key; must not hold the fixer WIP slot (FU-058 P3)
- **machinery**: backstop = `retro-session` CronWorkflow (retro-argo.yaml) — self-fires Mondays
  05:00 UTC (unsuspended 2026-08-03; ⚠ the lane's FIRST end-to-end pass was 2026-08-11, hand-fired
  after five latent bugs — FU-058; the PLATFORM series since 2026-08-19, the #587 [stint](chainless-redesign.md): stack
  param `platform`, ride ns from `agents/retro-project.sh`, fleet read token, report content
  floor); predicate = `minNewTasks` ledger level-trigger; no edge;
  keys/breakers inherit launcher defaults. Planned duty: harvests the local rules delta (§Lenses maintenance).

### scout (model-scout)

- **brief**: scout probe (model-routing.md §M7 — v3 redesign 2026-08-10: variant filter,
  benchmark cross-check, typed cell-keyed canary verdicts, and the §M13 pool-curation duty;
  FU-161/FU-162)
- **boundary**: ephemeral only-free capped keys (canary)
- **machinery**: backstop = weekly `model-scout` cron (reflexes-argo.yaml); no edge; FU-095(b)
  extends its candidate source to a maintained rotation. Documented under the model axis today;
  it is a *role* — machinery listed here, content stays in model-routing.md.

### meta-coordinator

- **brief/state**: `agents/coordinator/TICK-LOG.md` (practice) + `meta-state.md` (in-flight chains)
- **boundary**: the operator's jail sessions — full context, human-gated
- **watch machinery**: the `agents/meta-*.sh` Monitor probes — jail tooling, not platform
  mechanism (operator ruling 2026-08-10); inventory + duties in
  [`../runbook.md`](../runbook.md) §Meta-session watch scripts, arming in
  [`meta-state.md`](meta-state.md) §Re-arm
- **machinery**: two of the three tracked pieces SHIPPED 2026-07-27 — the `arbitrate` scan
  clause (FU-086) and close-the-loop C6 + Follow-ups harvest (`merged-closeout`, MP-T10 /
  FU-090a) are loop-owned now; the incident lane grew machine belts the same day (blackbox →
  responder triage → FU-044 deterministic revert). Remaining meta-manual: FU-090 (b)
  spec-driven authoring + (c) goal decomposition, and everything the belts escalate.

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
| ASVS | OWASP ASVS v5.0 (May 2025, [asvs.dev](https://asvs.dev/)) | `gh pr diff` grep for auth/input/session/signature code and new route registrations (Go/Python/TS) | advisory | **LIVE 2026-08-24** (`agents/lenses/asvs.md`) — code-class predicate via diff grep, not paths; prefers quiet miss over false alarm |
| e-ITS | RIA e-ITS baseline | stack-level, scheduled audit-pass | audit report | pending (seeded by FU-105's IdP research output) |

Mechanism (built with FU-101's first two lenses): `reviewer-session.sh` computes the diff class
in-pod (deterministic — changed paths + `gh pr diff` grep), fetches matching
`agents/lenses/<lens>.md` from the public homelab repo raw (platform-owned, no image rebuild),
and appends them to the system prompt after the project rubric. The advisory contract lives
INSIDE each lens file (`LENS(<name>):` findings are Follow-ups, never the verdict); fetch
failure skips the lens loudly. The per-stack advisory→blocking knob is rendered on the
AgentStack claim as `spec.lenses.<name>: advisory|blocking` (FU-101), sourced through
the same fail-closed claim read as the reviewer optout — zero extra cluster calls.
A lens marked blocking appends a `POSTURE: blocking` line to its fetched text so the
reviewer knows its findings MAY determine the verdict. Absent = every lens stays advisory.

Per-stack claim knob graduates a lens advisory → blocking. Audit-lane model rules (reasoning
tier allowed, dual-model worth it) are FU-095's.

**Posture ruling (operator, 2026-09-02 — the #818 verdict sitting): advisory is the designed
steady state for practice lenses.** Critical findings block regardless of lens posture — through
the rubric's blocking classes (lens-independent) and the deterministic belts (Gate-A
scan-secrets, the enforcing IAC-G04 sentinel) that own the security-critical classes outright.
`blocking` is reserved for lens classes the belts cannot reach (ASVS-shaped app-code findings),
graduated only after advisory signal exists. Growth direction: MORE lenses that trigger often,
never harder posture on quiet ones.

## Role machinery checklists (built + planned)

- **prober** (FU-102) — the **contract probe** role (glossary ruling: *canary* unqualified is
  the scout's rail probe; the early "agentic canary" name is retired). Product-contract probes (oracle UC-1 probe-e2e is
  the proven brief); prod-read + report-only. **Scheduled leg BUILT 2026-08-07; FIRST FLIP 2026-08-24
  (platform stack, homelab#835)**: claim knob `spec.prober {enabled, schedule, model}` renders `probe-<stack>`
  (CronWorkflow, loop ns) running `<mainRepo>/.agents/probe.md` on the SUBSCRIPTION
  (claude/haiku — operator direction 2026-08-07, platform roles ride the subscription;
  latch-gated). no git/cluster writes by construction (operator ruling 2026-08-30). A feedback row filed through a stack's own MCP is a report into that stack's product sink — not a write to git or the cluster. Still
  missing: the post-deploy sync-succeeded edge, 🌱 issue filing, (endpoint, digest) keying —
  and every stack brief but the platform's (`homelab/.agents/probe.md`, #835 — belt-gap
  framing: report what is broken AND unalerted; content shape still awaits the ≥2-projects
  rule). Detection belts stack: FU-099 blackbox (seconds, dumb) → prober (minutes,
  contract-deep) → responder; until a claim flips `enabled` (platform: 2026-08-24), a stack remains
  blackbox → *nothing* → responder and the alert lane carries the prober's load.

  **⚖ SUGGESTED IDEAS — operator thinking in progress (2026-08-08), NOT decisions. Do not build
  from this block; it exists so the flip-time design starts from the whole option space. The
  operator's framing question comes first: what is a PROBE vs an E2E TEST — what should run ONCE
  as a smoke gate on a change, and what deserves a cron? "The simplistic probe is not the
  solution to all problems" — don't reach for the probe hammer on every nail-shaped problem.**
  - **Sanctioned class: two MCP-attachment modes for an agentic probe** (Goal #1039). The
    probe session has two wiring modes, sequenced deliberately:
    **Class 1 — raw-HTTP** (zero machinery, tests the wire contract first). The brief carries
    everything; the session probes with raw streamable-HTTP JSON-RPC via curl — the meta-11
    shape. No MCP config, no client-library smoothing; arguably the stronger canary.
    **Class 2 — harness-attached** (behind the AgentStack MCP knob, tests what a real consumer
    experiences including client-side schema conformance). Rendered from the claim's MCP
    endpoint; the knob is referenced by issue (Goal #1039), not by field path — the field
    path's home is the XRD + `docs/agents/agentstack.md`.
    **Cell doctrine:** KPI cells are the census-derived consumer-assistant set, with pinned
    experiment arms per ADR-104 (deterministic slot draws on curated pools): explicit
    overrides, never routed.
  - *Probe vs e2e-test split (undecided):* oracle's `probe-e2e.sh` in kind mode is closer to an
    E2E TEST (deterministic serve leg, fixture corpus, asserts on transcripts) — a per-change,
    run-once artifact; the prober's cron probe is a CANARY against the LIVE contract (drift,
    corpus rot, cert/route breakage — things a merge gate cannot catch because they happen
    later). The boundary question: which assertions belong to the change (smoke, once, gate-ish
    but never merge-blocking per the 2026-07-24 ruling) vs to time (cron, report-only).
  - *Progressive delivery (operator sketch):* deploy a goal branch's serving artifact as
    `mcp-goal<N>.oracle.teststuff.net` — or main URL + a feature-flag header — and run the
    probe/e2e AGAINST THAT before the assembly merge, so acceptance bullet-4-style "live half"
    checks stop being post-merge operator chores. The specs-preview machinery
    (`specs-<pr>.oracle.teststuff.net`, torn down on PR close) is the existing precedent/donor
    shape. Open: per-goal endpoint vs header-based flag routing, teardown, and whether the
    probe that runs there is the smoke (once) or the canary (cron) flavor.
- **responder** (FU-103) — alert-triggered triage. **v2 LIVE + full-E2E-proven 2026-07-27 (triage-first —
  operator ruled issues must be triage-gated and stack-routed, never one-per-alert):**
  predicate = Alertmanager firing (fan-out route `continue: true` in
  `argocd/platform/values/kube-prometheus-stack.yaml` — was `tofu/monitoring.tf` before FU-136);
  edge = Sensor `/alert` → `respond` WorkflowTemplate (`agents/coordinator/responder-argo.yaml`)
  — per NEW fingerprint one INLINE sonnet triage session whose cheapest-sufficient outcome is
  report-only → GitOps quick fix on the stack's -iac (revert/pin PR, CI-only lane auto-merges)
  → ONE inert issue on the stack's -iac/app repo → homelab only for platform namespaces or
  needs-platform (routing = alert namespace → stacks.json); backstop = none (alerts refire
  ≤3h); key = 24h fp ledger (`responder-seen` cm, namespaced RBAC) + fp-issue search belt;
  capacity = Sensor rateLimit 6/min + subscription semaphore + FU-088 latch + a 12-triages/day
  cap (unique-fp storms); breakers = one-issue-max, no kubectl mutations, no agent labels
  (inert, breaker #1), loop-smell → report-only stop.
  **Dispatch SPLIT from triage 2026-08-07 (FU-133 dispatch half):** the session's issue carries
  `fix-verdict: fix|report-only` (a diagnosis); the shell applies `agent-fix` (inert — the scan's
  dispatch precondition is `agent/queued` alone, ADR-122 (2), S8 #1432) and rings `/fix-verdict`;
  the `fix-debounce` machinery
  (`fix-debounce-argo.yaml`) judges the whole pending SET before any `agent/queued` lands —
  mechanism in [`iac-lane.md`](iac-lane.md) §"one root cause, N alert issues". This replaced
  the per-issue `selfQueue` knob (cb4ae5a, which dispatched same-cause issues in parallel).
  **Graduation dial BUILT 2026-08-24 (goal#818):** a claim-gated `responder:` block on the
  AgentStack XRD renders a scoped Role + RoleBinding per stack namespace (the loop ns + every
  fixer-enabled repo ns), granting exactly the declared verb/resource pairs to the responder
  identity (agentstack-loop SA). Default OFF — absent block = nothing rendered, the responder
  keeps its report-only breakers ("no kubectl mutations", one-issue-max, inert labels).
  Enabling the dial does not by itself make the responder mutate anything; a consumer must be
  wired to read the grant and act on it (goal #818 §assembly — this PR ships NO consumer;
  report-only remains the default posture). The escalation-check mirror lives in
  `argocd/resources/agentstack/rbac.yaml` under `crossplane-agentstack-composed`.
  **Three lane gaps, all evidenced by the 27-issue corpus (2026-08-04 audit, FU-133):** the lane
  files one issue per *fingerprint* and correlates nothing (~19 of 27 issues were 5 root causes;
  one PVC produced 8 across 8 days); it has no state after "issue filed" (`send_resolved = false`
  on the responder receiver — the resolve event is never delivered, so a cleared alert leaves an
  open issue); and **ownership vs the -iac observation window is undefined** (IAC-G10 —
  [`iac-lane.md`](iac-lane.md) §Who owns a symptom).
  **Self-referential gate BUILT 2026-08-04** (`responder-argo.yaml`, deterministic — the alert
  label `platform_machinery: "true"` ∨ namespace ∈ {kube-system, argocd, longhorn-system,
  registry-cache, arc-runners, agent-coordinator, agent-egress, *-agents} ∨ alertname `Agent*`):
  those alerts cap the outcome at report-only and stamp `self-referential: true` on the issue,
  because the alerts most likely to want a fixer are the ones that disable it — the pod, the pull,
  the PVC attach, the git token or the CI runners it needs are the broken thing. The future
  `selfQueue` knob reads the marker instead of re-deriving it. Verified against 11 alert shapes
  from the corpus (7 self, 4 dispatchable).
  **The label key added 2026-08-11 (homelab#239), and it is the primary one:** the other two
  *infer* machinery from something else, so an alert derived from a **pushgateway** metric matches
  neither — `RetroReportOverdue` (no meaningful namespace, name not `Agent*`) passed the gate, took
  a `fix` verdict, was debounce-queued, and put a worker on the retro belt, which only the
  jail/operator lane can act on; it latched `agent/error` (homelab#237). A rule AUTHOR knows the
  machinery fact and declares it at the rule site, exactly as with `triage: none` — the two are
  different caps and compose: `triage: none` means *do not investigate*, `platform_machinery` means
  *investigate, but a human merges the fix*. Stamped only where it is load-bearing (an alert the
  namespace/`Agent*` belt already catches would gain nothing and would change its own Alertmanager
  fingerprint); the live pairing is asserted in `agents/coordinator/responder-behaviour-test.sh`
  §#239 against the real `PrometheusRule`s, which is the only place a dropped stamp can fail —
  `manifest-lint` SKIPs both kinds involved.

  **POLICY_DENIED runbook — BUILT 2026-08-08 (homelab#125).** Before this, the lane faulted sessions
  for not following a runbook that was written down nowhere and whose only named tool
  (`devbox run hubble`) is a *jail* recipe: the `agent-coordinator` image carries no `hubble` and no
  `cilium` binary, and `agent-read-infra` grants no `pods/portforward`. So a triage reported "cannot
  name the FQDN" three hours after a sibling session had named it. The reads that actually work from
  the responder pod, cheapest first — both verified from an agent pod under the enforced egress
  profile:
  1. **Prometheus, and it is usually the whole answer.** The drop metric already resolves names —
     `tofu/cilium.tf` sets `drop:sourceContext=namespace;destinationContext=dns|ip`, so `destination`
     *is* the FQDN whenever the DNS proxy knew it. `hubble` was never needed to answer "which
     destination was denied".
     `curl -sG http://kube-prometheus-stack-prometheus.monitoring.svc:9090/api/v1/query --data-urlencode 'query=topk(10, sum by (source,destination,protocol) (increase(hubble_drop_total{reason="POLICY_DENIED",source="<ns>"}[6h])) > 0)'`
     — in-cluster service DNS, **not** the `192.168.40.13` LAN VIP: an LB IP is a `world` destination
     and only reaches Prometheus because pod→VIP is DNAT'd before policy evaluation
     ([`agentstack.md`](agentstack.md) §egress). Widen `[6h]`→`[24h]`/`[7d]` before concluding
     nothing is there; a bare-IP `destination` means the DNS proxy saw no name for it, which is a
     finding, not a dead end.
  2. **Hubble, for per-flow detail only** (port, timing, the exact pod). No binary in the image and
     no port-forward verb, so exec it in a cilium agent, which does carry it:
     `kubectl exec -n kube-system ds/cilium -- hubble observe --namespace <ns> --verdict DROPPED`
     (`pods/exec` is already granted by the `agent-coordinator` ClusterRole). ⚠ That is **one node's
     ring buffer** — an absence is not evidence of no drops. Add
     `--server <hubble-relay clusterIP>:80` for the fleet, or name the node you sampled.
     Same blind spot `scripts/hubble-observe.sh` port-forwards around for jail sessions.
  RBAC moved once, narrowly: `cilium.io` `ciliumnetworkpolicies` +
  `ciliumclusterwidenetworkpolicies` get/list on `agent-read-infra` — the lane was asked to diagnose
  a deny without reading the policy that produced it. `pods/portforward` and `services/proxy` were
  asked for and **declined** (rationale in `agent-read-rbac.yaml`): the first is useless without
  shipping the CLI, the second buys a route that already exists.
  Two brief rules landed with it, both from the same night: **on a subject/fingerprint dedup hit,
  read the prior thread before re-deriving** — a predecessor's triage is evidence, and the session
  must cite its verdict or say why it is wrong; and **compose issue bodies with `--body-file`, never
  an interpolated `"$(…)"`** — that authoring bug spliced 360 lines of flow logs into #125's own
  body and ate every inline code span, deleting exactly the identifiers a fixer needs.
  Gate for all of it: `bash agents/coordinator/responder-behaviour-test.sh` (kubeconform SKIPS both
  resources in `responder-argo.yaml` — `argoproj.io` has no schema, so `manifest-lint` validates
  none of this shell).
- **researcher/planner** (FU-105) — **LIVE** (first mode) — spec/requirements research. dispatch-on-goal (a human-queued
  MISSION issue, FU-090(c) shape); reasoning tier + dual-model review (FU-095 rules); output =
  spec PRs through the codeowner gate. **Boundary is the new piece: open-web egress** — a
  `research` egress profile (proxy-logged) or claude-harness server-side WebSearch; safe because
  the pod holds no cluster creds and a spec-branch-only git token. Consumers in order: sleep
  spec retrofit (FU-095 prerequisite), IdP greenfield (whose EITS output seeds the e-ITS lens).
  **First mode BUILT 2026-07-27:** sleep-tracking `.agents/research.yaml` (recipe: specs/-only
  boundary, un-armed PR = the human gate until a CODEOWNERS ruleset exists, FU-069 breaker),
  the then-`goal` label (retired, FU-163) + mission issue sleep-tracking#36, claim `claudeTier: true` (sleep-iac#21), egress =
  claude server-side WebSearch (no dial change — WebFetch stays blocked and the brief says so).
  Dispatch is operator-manual until FU-090(c) graduates; git token is the standing per-repo
  broker token (branch-scope narrowing = an open hardening dial). **Proven E2E 2026-07-27**
  (sleep spec PR #38: 17 ⚖ + 9 suspected bugs, dual-model reviewed, human-gated). The un-armed
  gate is now launcher-owned: `--no-arm` auto-derives from a `research*` recipe →
  `AGENT_ARM_PR=0` (agent-runtime), and the C9 re-arm belt skips `research/*` branches — **into
  the default branch only** (2026-09-04): a research ride whose `Base:` is `goal/**` ARMS, because
  its human read is the goal's assembly, not the fix→goal hop
  ([issue-authoring.md](issue-authoring.md) Goal card rule 10).
  Vocabulary (FU-163, rename executed 2026-08-23): a research MISSION is not an ADR-102 Goal —
  research PRECEDES the Goal (it prepares the contract the Goal then implements). The historical
  bare `goal` dispatch label no longer exists and never had a machine reader; `mission` is the
  reserved future label. Process home: [`research-and-specs.md`](research-and-specs.md).
- **infra-fixer** (FU-106) — **LIVE** — the -iac devops role. Works the **-iac wrapper layer** (charts stay
  target-agnostic); input = `values.schema.json` diff (the typed infra delta), fulfillment =
  enriched **bump PR** (chart pin + claim change in ONE -iac commit — atomic at the deploy
  boundary, the meta-11 paired-rolls rule generalized); mechanical (schema-valid, within the
  FU-093 quota) rides the ADR-084 CI-only lane, judgment stays codeowner-gated. Hard boundary:
  wires secret *references*, never values. Detector + `infra-enrich` dispatch class built
  2026-07-27, first live dispatch merged the same day; oracle-iac twin live 2026-08-02 — both
  -iac repos have merged rides. **Full rollout matrix (a)–(f), the lane
  doctrine and the IAC-G01..G06 gap register:** [`iac-lane.md`](iac-lane.md).
- **audit-pass** — not a role: reviewer machinery × e-ITS lens × schedule predicate (dissolved
  the planned "auditor").

## Context delivery — role × context × source (FU-117)

Operator 2026-07-28: *"context management is starting to spread — which role requires what
context."* The section grew as a deliberate pile-up (grow organically, then analyse and refactor
— not BDUF); **the refactor began with stint S4 (#762, 2026-08-23)** — the operator's own
work-map scheduling is what lifted the let-it-pile-up gate. The map, as now built:

| Context class | One source | Delivered by | Reaches |
|---|---|---|---|
| **1 — environment** (dynamic per-ride facts: docker, egress, proxies, round, write scope, base, goal card) | AgentStack claim knobs + launch state | `render_env_card()` (launcher, ADR-094) | every ride, both harnesses |
| **2 — task + service facts** | the ISSUE (author-injected — the worker clones only `/work/repo`) | issue body — DELIVERY via the launcher's prefetch bundle (`/work/context/` with index, homelab#1175, #1205; the "prefetch, don't fetch" rule above) | every ride |
| **3 — universal ground rules** (devbox-only installs, prior-art, machine markers) | [`agents/ground-rules.md`](../../agents/ground-rules.md) — **built #763**: the env card's static sibling, injected verbatim by the launcher; a missing file degrades LOUDLY (replay `env-card-ground-rules/missing`) | `render_env_card()` prepends the file | every ride, both harnesses |
| task rules (how to approach this class) | stack repo `.agents/<class>.yaml` | launcher `--recipe` (L2/L3, [fixer-context.md](fixer-context.md)) | the ride |
| jail seat procedure | [`agents/jail-seat-card.md`](../../agents/jail-seat-card.md) — **built #764/PR#773**: composed by the mono jail's entrypoint (container card + seat card → `/workspace/homelab/CLAUDE.local.md`, container-start snapshot; claude-jail#1) | Claude-Code auto-load of the composed `CLAUDE.local.md` | the homelab seat ONLY — stack jails get the facts-only `CLAUDE.md` via their clone, deliberately no seat card |
| jail container ground rules | claude-jail `tools/jail-card.md` (that repo's own; stack jails add a `STACK_*`-rendered env card) | the jail entrypoint/init composition | every jail session, both jail classes |

The `render_env_card()` interim duplication (accepted 2026-07-28) is REMOVED — the card keeps
only dynamic facts and `cat`s the ground-rules file. Every FU-117 leg is BUILT (2026-08-23:
#763 ground rules, #764 the jail third context — both jail compositions live, #765 the
meta-state eviction); the residual is the fleet CLAUDE.md slim-down, inventoried + tiered on
the claude-jail#1 thread.

**Root finding (2026-07-28, kept as the section's evidence): two delivery channels carry
different context.**

| Channel | Reaches | Carries |
|---|---|---|
| **Claude-Code auto-load** (CLAUDE.md + skills + memory) | the meta-coordinator, and claude-harness rides (coordinator / reviewer / researcher — they run `claude -p`, clone homelab, get its CLAUDE.md) | the universal ground rules |
| **Recipe + launcher-spliced env card** | the **goose** worker/fixer rides | per-ride facts + task rules |

**Goose is not Claude Code, so it never loads CLAUDE.md.** The universal ground rules that live
there — grep SERVICES.md, devbox-for-everything, prior-art-before-creating — therefore never reach
the goose worker. Concrete cost already paid: #71-r1 downloaded a kind binary into a read-only nix
profile; the #48 rounds never configured the registry mirror. Both are CLAUDE.md-rule gaps. The env
card became the smuggling route, which *is* the spread.

**Sighting 2026-08-07 — the JAIL is a third context, and it has no env-card mechanism at all.**
Operator direction: [`teststuffstash/claude-jail`](https://github.com/teststuffstash/claude-jail)
needs one so its `CLAUDE.md` can be *clean of instructions*. Today the jail's ground rules live
inline in `/workspace/CLAUDE.md` (container permissions, devbox-not-apt, the scratchpad) and
homelab's own `CLAUDE.md` mixes jail-session procedure ("work directly on `master`") with
repo-universal facts. Two costs already visible:

- **Wrong-context instructions are READ AS APPLICABLE.** homelab has a live fixer lane, so agents
  ride this repo — and `## How changes land (jail sessions)` used to tell the reader to push to
  master, the opposite of a worker's contract (softened 2026-08-12: the jail default is now
  PR-lane too; only the bookkeeping class stays direct). Structurally the ruleset rejects such a push, so
  the cost is confusion rather than damage — but the doc is the wrong place to be relying on
  branch protection to correct.
- **The duplication now runs three ways, not two** *(superseded by #763 — the card no longer
  restates anything; kept as the sighting that sized the map)*: `render_env_card()` restated
  CLAUDE.md rules for goose; the jail restated a third set for the meta-session. The map
  therefore has THREE contexts (jail meta-session / claude-harness ride / goose ride), and the
  jail was the only one with no delivery mechanism to refactor *into*.

⚑ Interim guard only (2026-08-07): a banner at that section scoping it to the jail. It reaches
Claude-Code readers and NOT goose rides — belt, not fix, and precisely the spread this item exists
to remove.

**A boundary the model must respect (sighting 2026-07-28).** The ride clones ONLY `/work/repo` —
the project repo, never homelab — so a worker **cannot** grep SERVICES.md. And it shouldn't:
**service context** (endpoints, buckets, existing-secret refs) is the **issue author's /
coordinator's** job to inject into the issue; the worker executes with it. Meta-15 briefly added a
"grep SERVICES.md" env-card bullet and then removed it — exactly the flip-flop-to-worker the
operator flagged.

So the map has at least **three context classes**:

1. **Environment** — how your box works. Owner: the env card
   ([`fixer-context.md`](fixer-context.md) L1).
2. **Task + service facts** — what THIS task needs. Owner: the **issue**, injected by the
   author/coordinator.
3. **Universal ground rules** — CLAUDE.md today, and unreachable by goose.

**Interim (2026-07-28, meta-15 — RETIRED by #763):** the key CLAUDE.md rules were duplicated
into `render_env_card()`; the dedup into `agents/ground-rules.md` removed the duplication
(map above).

**Sighting 2026-08-03 (circles FU-126 A/B):** recipe text carried egress FOLKLORE ("WebFetch will
mostly be blocked") while the truth is per-HARNESS capability — claude rides have server-side
WebSearch (unaffected by pod egress), goose rides have no web tool at all (kimi's spec arm could
only disclaim "reasoned from training knowledge"). Capability truth moved into the env card (a
harness-conditional "Web research:" line); recipes should stop asserting it. Class-1 context that
recipes were squatting on.

**⚖ Ruling 2026-08-04 — advertising the difference is not enough; remove it.** A harness-conditional
env-card line makes the platform HONEST about capability, and honest is where we stopped. But it
leaves "can this ride check whether the bug is already known upstream?" answered by which harness
happened to be picked — and opencode, hermes and whatever comes next are unknowns we would discover
the same way, one wrong ride at a time. If one harness has web research, every harness should: it
belongs to the platform (an egress-allowlisted docs/search endpoint, or an MCP tool the launcher
wires) rather than to the harness. Nothing that decides whether a fixer can SEE something should be
a property of the binary we happened to spawn. Tracked as FU-134.

**DELIVERED 2026-08-05 — `POST /search` on the egress proxy.** An ordinary completion carrying
OpenRouter's `openrouter:web_search` server tool (the `plugins:[{id:"web"}]` form is deprecated),
returning `{answer, citations:[{url,title}]}` to any harness that can curl. What made this the
shape rather than a self-hosted SearXNG or a per-stack egress allowlist: it rides **the caller's own
key ref**, so budget, guardrail, cost ledger and per-session attribution all keep working, there is
no new credential to leak and no new egress hole — the ride already reaches that VIP for its
completions. Cost is the ride's (~$0.005/search + prompt tokens), which the env card states so the
model can act on it ("ask few, real questions"). Two boundaries worth remembering: an
anthropic-tier ref is refused (those rides have WebSearch in-harness, one hop less and no spend),
and under `guardrail: only-free` the search model must be a `:free` id or it 403s like any other
completion — that is the guardrail working, not a defect in the endpoint. The env card now states a
GUARANTEE per harness and passes the address as `AGENT_SEARCH_URL`, never a literal: a kata guest
cannot reach a ClusterIP (FU-072), so the card must print the address *this* pod can use.
Acceptance: from a ride-shaped pod in ns `circles`, a question no model can answer from training
data came back with 10 citations.

**The refactor (executed as designed, S4 #763):** the role × context × source map at the top of
this section — dynamic per-ride facts (env card) / universal ground rules (authored once in
`agents/ground-rules.md`, launcher-injected as the env card's static sibling) / task rules (the
recipe). One source per concern, delivered to the roles that need it.

## SLO machinery (not a role — stack policy)

The stack declares `slo: {endpoint, probe, availability, errorBudget}` on its AgentStack claim;
the platform renders the FU-099 blackbox probe, burn-rate alerts, the responder's alert edge,
and the teeth: **on a burnt stack, reviewer dispatch is parked at every dispatch site — no new bot
approval is minted, so every unapproved PR is codeowner-gated in effect** (FU-104). A PR already
approved-at-head with auto-merge armed still merges: the teeth withdraw no approval and disarm no
PR. Zero opinions in any brief; "harder to ship something that breaks" enforced by contract.
