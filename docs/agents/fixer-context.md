# Fixer context — the worker's prompt is three layers, not one (FU-114)

_Design narrative, born 2026-07-28 from the #48 no-docker autopsy. Extends the **fixer** role in
[`roles.md`](roles.md) §Live roles — this is the brief/environment axis of that role, the way
[`iac-lane.md`](iac-lane.md) is the -iac lane's. NOT an -iac concern: #48 is an app-repo fixer
task (a system-test gate in sleep-tracking); the [iac-lane](iac-lane.md) doctrine does not apply._

## The incident that exposed it

sleep-tracking#48 asked the fixer to **build** a docker-based integration gate (kind/Garage/
Grafana). Three rounds of `deepseek-v4-flash` produced zero commits and a false-green
(`ci_passed:true` off 117 unit tests). The transcript autopsy (r3, `s3://agent-transcripts/
sleep-tracking/issue-48/`) found the model **never ran a single `docker`/`k3d` command** — it
asserted _"I can't run k3d in this environment"_ and pivoted to unit tests. The capability was
real (r1 genuinely ran `k3d cluster create`; the ride is kata+dind, `fixer.docker: true`). The
model didn't hallucinate from weakness alone — the **prompt actively primed it**:

1. **Capability-blind, mis-typed recipe.** `.agents/fix.yaml` is a *bug-fixer* ("Fix ONLY the bug…
   as a tight reviewable diff", decision-table TDD on `parser.py`). #48 is a *build* task. So the
   model did as told — hunted for a logic bug, found none, concluded "infrastructure, not a bug."
2. **The recipe frames the env as restricted** — _"ephemeral agent-sandbox pod… NO real-data",
   "no-real-data sandbox", "master is unreachable"_ — and **never mentions docker/kind/k3d**. A
   model reading that system prompt is primed toward "restricted sandbox → no docker."
3. **Docker was advertised only in the issue body's "Platform facts"** — hand-written per issue,
   structurally disconnected from the recipe, stale-prone. Nothing reconciled the two.

Root cause, one line: **the launcher reads every claim knob to _build_ the ride, but never tells
the model what it built** — and the one recipe conflates task approach with environment and is
blind to both the capability and the task class.

## The worker's context is three layers

Today `.agents/fix.yaml` is one flat blob that mixes all three and is accurate on only one:

| Layer | Answers | Owner | Today |
|---|---|---|---|
| **L1 — environment card** | "what CAN this ride do — docker? egress? budget?" | **platform** (from claim knobs) | ❌ absent; a stale "sandbox" framing in the recipe + hand-typed issue-body facts |
| **L2 — task-type brief** | "how do I approach THIS kind of task" | **stack repo** (`.agents/<class>.yaml`) | ⚠ one brief (`fix`), applied to every class incl. build |
| **L3 — selection** | "which brief for this issue" | **platform** (deterministic) | ❌ always `fix.yaml` |

This is the same shape [`roles.md`](roles.md) already names: _"N roles sharing machinery = one
machinery family × N briefs"_ and _"Mechanism > advice > nothing"_. The fixer is one machinery
family; it needs N briefs and a rendered environment, exactly as the reviewer got lenses (FU-101).

### L1 — the environment card (platform-generated, accurate-by-construction)

The **launcher** (`agents/agent-session.sh`) composes it from the same knobs it uses to build the
pod, so it can never drift from reality (unlike issue-body prose or recipe framing). Rendered as a
short system-prompt prefix, keyed on the knobs:

- `fixer.docker: true` → *"A real Docker daemon is at `$DOCKER_HOST` (kata microVM + dind).
  **Verify before assuming: `docker info`.** kind/k3d integration gates run here. Registry pulls
  MUST use `$REGISTRY_MIRROR_DOCKER_IO`/`_GHCR` — upstream hangs under the egress policy."*
- `fixer.docker: false` → *"No Docker in this ride. Cluster/integration gates run in GitHub CI,
  not in-pod — don't attempt them."*
- `egress.enforce: true` (+ `profile`/`extraFQDNs`) → *"Egress is ENFORCED. Allowlisted: … .
  A miss HANGS (not errors)."*  ·  `enforce: false` → *"Egress monitored, not blocked."*
- budget/round (*"round N of ROUNDS_MAX; ~$X budget"*), write-scope (*"you can only push a
  `fix/` branch + open a PR; master is unreachable"* — as fact, not fear).

**Provable, not describable** (the operator's phrasing): the card is generated from the knobs, so
it's true by construction, and it hands the worker the *verify* command instead of a prose claim
it can disbelieve. This REPLACES the recipe's "sandbox" framing AND the issue-body "Platform
facts" — those facts move here, out of every issue author's hands.

### L2 — task-type briefs (stack repo owns the machinery-family × N briefs)

Per repo, one brief per task class — carrying repo know-how, **never the environment** (L1 owns
that):
- `.agents/fix.yaml` — bug-fix: decision-table TDD, `parser.py`/`timezone.py`, the 85% gate.
- `.agents/build.yaml` — build a deliverable + prove it end-to-end (a gate, a chart, CI wiring).
  Crucially it does NOT say "find the bug" — the trap #48 fell into.

The **shared skeleton** (breaker convention FU-069, incremental-push discipline, the response
schema, `gh issue view` first) is common to all classes — a candidate for a platform-templated
base the repo extends, so a new class isn't a full re-write ("Mechanism > advice").

### L3 — selection (deterministic, launcher-owned — NOT the coordinator "figuring it out")

A claim-authoritative **`task/*` issue label** (default `task/fix`; #48 = `task/build`), read by
`coordinator-scan.sh`, emitted in the dispatch unit, passed as `--recipe .agents/<class>.yaml`.
The LLM never picks (ADR-094 launcher-owned recipe, the #55 lesson). The class is known at issue
authoring time — the same "known exactly at authoring time" property FU-087 relies on for
Depends-on. **Shared with FU-095**: one `task/*` classifier can drive both this recipe selection
AND FU-095's task-class model routing — one label, two deterministic consumers.

## Division of labor (platform vs stack)

| Piece | Owner | Source of truth | Rendered/selected by |
|---|---|---|---|
| Environment card (L1) | **platform** | AgentStack claim knobs (`fixer.docker`, `egress.*`, budget) | **launcher** — prepended to the recipe it already owns (ADR-094) |
| Task-type brief (L2) | **stack repo** | `.agents/<class>.yaml` | repo authors; shared skeleton = platform-templated base |
| Selection (L3) | **platform (deterministic)** | issue `task/*` label (IssueLabels-authoritative) | `coordinator-scan.sh` → dispatch unit → `--recipe` |
| Advisory lenses | platform | `agents/lenses/*.md` | already live for the reviewer (FU-101); the env card is the fixer's always-on "lens" |

**Injection mechanism** (grounded in what exists): the launcher already base64s the recipe into
`claude --append-system-prompt-file` and into `--run "goose run --recipe …"`. It **prepends the
rendered env card to the recipe content** in both paths — one launcher change, both harnesses,
stays ADR-094 launcher-owned, mirrors the reviewer's lens-append exactly.

## Why not "just advertise docker better"

Because a model that skims prose won't read a better ad. The two platform-wide rules in
[`roles.md`](roles.md) apply: **"Mechanism > advice"** (render the environment from the knobs, don't
describe it) and **"Elicit, don't inject"** (the task brief stays lean; the env card is FACT the
worker verifies, not an opinion checklist).

## Maps onto every #48 failure

| Failure | Fixed by |
|---|---|
| "sandbox" framing primes no-docker | L1 card: generated docker truth + `docker info` verify |
| bug-fix recipe on a build task | L2 `build.yaml` + L3 deterministic `task/build` selection |
| docker advertised only in issue body (stale-prone) | facts move to L1, generated from knobs |
| never probed | card hands the exact probe; `build.yaml` can make a one-line env check its step 0 (cheap — NOT the full `devbox run ci`, which GitHub owns) |

The `ci.sh` silent-skip-without-docker (`else echo "integration test SKIPPED"`) is a separate
hygiene fix (fail-closed when docker is *expected*) — lower priority: GitHub CI is the real gate,
and L1+L2 make the worker actually use docker. In-pod `ci_passed` stays a best-effort self-report
by design (the operator's call: in-pod CI is a typo-saver, not the gate).

## Build order (design-first, then passes)

1. **L1 — launcher env card** (`agent-session.sh render_env_card()` from `$DOCKER`/`$EGRESS_*`/
   budget, prepend to recipe). Highest leverage — it alone would have stopped deepseek's
   assumption. Verify against a real dispatch.
2. **L2 + L3 — BUILT** (FU-114, archived 2026-08-02). L2: `.agents/build.yaml` on sleep-tracking
   (#48 was the first `task/build`) AND oracle-fleet (#166, the role-unification port). L3: the
   scan reads the issue's `task/*` label (default `task/fix`) and emits `class=<c>` in the
   dispatch unit — queued-dispatch AND c4c5-redispatch both — and the session uses
   `.agents/<c>.yaml` verbatim (brief step 5; recipe choice is never session judgment).
3. **ci.sh fail-closed** when docker is expected-but-absent (hygiene) — **explicitly the
   operator's call, unscheduled** (GitHub CI is the real gate; in-pod `ci_passed` stays a
   best-effort self-report by design). Not tracked by an FU — re-raise here if wanted.

Relates FU-101 (reviewer lenses — the pattern extended to the fixer), FU-095 (model axis; shared
`task/*` classifier), FU-087 (authoring-time knowledge), ADR-094 (launcher-owned recipe),
ADR-085 (mechanism=platform / policy=stack). Home role: [`roles.md`](roles.md) §fixer.
