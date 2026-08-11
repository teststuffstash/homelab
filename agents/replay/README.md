# `agents/replay/` — the clause-replay harness

Recorded world in, expected actions out. The mechanism doc is
[`docs/agents/workflow.md` §Replay harness](../../docs/agents/workflow.md#replay-harness); this
file is the map of the directory.

```
run.sh                  the runner — `bash agents/replay/run.sh [-v] [fixture-dir ...]`
stubs/gh                PATH-shim gh:      serves world/gh/,      records mutations
stubs/kubectl           PATH-shim kubectl: serves world/kubectl/, records mutations (incl. stdin)
stubs/_common.sh        world lookup, action recording, the read/write split
fixtures/<name>/
  fixture.yaml          what to run and how to judge it
  world/<tool>/*.json   RECORDED API responses, keyed by the invocation they answer
  expected/actions.txt  the action stream this clause must emit
  *.sh                  bridge / observation-point parts named by `parts:`
```

Run everything (what CI runs):

```sh
devbox run -- bash agents/replay/run.sh
```

## When a clause depends on a sourced helper

`fixtures/harvest-*` (ADR-102, homelab#207) are the worked example: the clause under replay calls
`goal_budget_read` out of `agents/goal-budget.sh`. The bridge **sources that file from the
checkout** (`. "$REPLAY_ROOT/agents/goal-budget.sh"`) and redefines only its two I/O seams —
`gb_ledger` (the pushgateway scrape) and `gb_cap` (the estimator, which prices against a live
registry). Everything between them is real arithmetic over the recorded world.

`fixtures/summary-comment-*` (ADR-103, homelab#210) are the second pair, and the simplest shape the
harness supports: the bridge is the ONLY part. It sources `agents/machine-comment.sh` and redefines
one seam — `mc_now`, the wall clock, which would otherwise make the fixture red once per second.
The `gh` calls stay real and go through the PATH-shim, which is exactly what puts the find-or-create
decision (POST a new comment vs PATCH the existing one) into the asserted action stream.

Do it this way round, not the other. Stubbing the whole helper would pin the clause's *branching*
and nothing else, and the reason that sum lives in a shared file at all is that a second copy of it
would drift from the launcher's — so the fixture must be able to see that drift. Copying the helper
into the fixture directory is worse still, for the reason `run.sh` already gives about transcribed
clauses (#166): a copy goes green while the original moves.

The seams are ordinary shell functions, declared as seams in the helper's header. If a clause you
are pinning reaches for I/O with no seam, add one there rather than a `REPLAY_*` branch in
production code — a test-only backdoor in a clause is a clause with an untested path.

`fixtures/argv-payload-*` (homelab#242) are the third family, and the first whose seam is not I/O
at all: `ag_limit` in `agents/argv-guard.sh` returns the kernel's 128KiB `MAX_ARG_STRLEN`, and the
fixtures shrink it to 512 bytes. Same rule, different reason — a fixture that asserted the real
ceiling would have to commit a 128KiB payload to assert arithmetic that does not change with
scale. Bound the *magnitude* through a seam, never the branching. The boundary itself is not left
to the fixture's word: the guard refuses at exactly the size `execve()` does (verified against
`env true` at 131071 → OK / 131072 → E2BIG on the PR that added it), and the pair pins the two
verdicts that flank it — a refusal that names the limit, and a warn band that does *not* stop the
ride. Over-eagerness is the usual failure of a size check, so "89% still dispatches" is pinned as
behaviour rather than trusted to prose.

`fixtures/fix-debounce-currency-*` (homelab#253) are the fourth family, and the first whose seam
serves a world of its own: the queue-time currency gate reads live alert state, so the bridge
shadows `fc_am_alerts` (the Alertmanager `/api/v2/alerts` GET) and `fc_now` (the clock the
`endsAt > now` split turns on), and the recording lands in `world/alertmanager/alerts.json` —
beside `world/gh/`, but served by the seam rather than by a PATH-shim stub, and keyed by nothing
because a fixture pins one moment of the alert store. Two rules make it worth copying:

- **Record the seam's read as a `CALL` line.** A probe that silently stopped happening is a gate
  that silently stopped gating, and an unrecorded read leaves the stream identical either way. It
  is the same reason the responder's bridge writes `CALL curl …`.
- **Pin the clock through `env:`, loudly.** `fc_now` reads `${FC_NOW:?…}` and dies with a message
  naming the fixture's obligation, because a *defaulted* clock is a fixture asserting against an
  accident: every recorded `endsAt` would silently drift into the past and the whole family would
  converge on "resolved" while looking green. (`fixture.yaml`'s subset has no inline comments —
  a trailing `# …` on the list item rides into the value and reaches `jq --argjson` as garbage.)

`fixtures/retro-key-*` (homelab#270) shadow **`python3` itself** in the bridge — the seam pattern
the responder pair uses for `curl`, applied to a helper the clause SHELLS OUT to rather than
sources. `retro-session.sh` mints its cell's budget key by running `estimate_budget.py --emit-cr`,
which prices against the live OpenRouter registry; the shadow appends `--price-per-mtok` and calls
`command python3`, so the real estimator, the real tier choice and the real `emit_cr` rendering all
stay under assertion and only the network leaves. Prefer this to stubbing the mint: the CR travels
`kubectl apply -f -`, so its `budgetUSD` lands in the action stream as STDIN, and the thing most
worth pinning about that clause is the number in it. The one field with no fixed value —
`expiresAt`, now+4h — is `scrub:`bed to a shape rather than asserted, the same treatment
`summary-comment-*` gives its clock.

`fixtures/scout-*` (FU-161 legs 1–2, homelab#282) are the sixth family and the first whose subject
is a top-level SCRIPT that runs its work at load time. `model-scout.sh` cannot be sourced the way
`goal-budget.sh` is — sourcing it *is* the weekly tick — so the seams reach the fixture the other
way the harness already supports: a `# >>>REPLAY:scout-seams>>>` block holding nothing but the
function definitions, composed FIRST, with the bridge composed after it and redefining exactly the
I/O it must. Part order is the whole mechanism, and it is the reverse of the sourced-helper
families: seams, then bridge, then the clause blocks. Three things worth copying:

- **Compose the seam you are asserting; shadow only the transport underneath it.** The keyless leg
  (`scout-bench-unkeyed-unbenched`) runs the REAL `scout_get_model` and lets its env gate decide,
  because "no key ⇒ every candidate `unbenched` ⇒ the tick still posts a digest" is the production
  path on merge day, not an edge case. Its bridge shadows `curl` as a **tripwire** — record, then
  `exit 9` — so a gate that leaked reds instead of reaching mcp.openrouter.ai from a cron pod. The
  benched leg shadows the same `curl` as a recording, and the JSON-RPC frames land in the action
  stream, which is the only place "one `get-model` per surviving candidate" is checkable at all.
- **Split the world's provenance and say which half is which.** `scout-variant-batch-rollout` is
  the acceptance case, and its 22 ids are digest #234's real ones; the price and
  `supported_parameters` fields around them are reconstructed, because the digest recorded ids
  rather than catalog rows. `scout-bench-mcp-error` goes further — it pins the degrade for an
  upstream envelope this platform has never probed. A fabricated world is legitimate for pinning
  OUR side of a contract; it must not be presented as a recording of THEIRS.
- **A synthetic sibling earns its place when the real world conflates two rules.** In #234's world
  every suppressed id was `:batch` AND had a known base, so one rule could have been doing all the
  work with the fixture none the wiser. `scout-variant-known-base` separates them on a six-id
  catalog — including a `:batch` id whose base is NEW (still dropped: exclusion is outright) and
  two within-tick variants of one new base (collapsed to the cheaper listing).

⚠ `model-scout.sh` is **not** in the ADR-103 ratchet's clause-file regex, so nothing forced these
fixtures and nothing will force the next author's. Adding it means editing `.github/workflows/`,
which the fixer lane may not touch (`.agents/fix.yaml`, the CI-runs-your-branch rule) — so it is
noted here and on #282's PR for a seat that can.

`fixtures/scan-phase-marker` + `fixtures/scan-wedge-alert` (FU-145, homelab#283) are the seventh
family and the first **pair split across the two modes**, because the thing under test spans a
shell emitter and a PromQL expr. `scan-phase-marker` is ordinary `actions`: the shipped
`>>>REPLAY:scan-phase>>>` block, with `sp_now` and `curl` shadowed in the bridge, so the push URL
(namespace-keyed group, pod as a metric label) and the `in_deterministic` value land in the action
stream. `scan-wedge-alert` is `suite`: its entrypoint lifts the alert's expr OUT of
`argocd/resources/pushgateway/prometheusrule.yaml` (annotations stripped — this pins firing, not
prose) and replays series through `promtool test rules`. Two rules worth copying:

- **Pin an emitter and its reader together or you have pinned neither.** An expr replayed against
  series nobody emits asserts a fiction, and an emitter with no expr behind it is a metric nobody
  reads — the FU-145 defect was exactly a rule whose subject was not what its emitter measured. The
  suite also cross-checks the two metric names against `coordinator-scan.sh`, so a rename on one
  side goes red instead of going silent.
- **A behaviour test earns its place by red-casing the bug it fixes.** The four replays were run
  against the pre-#283 pod-lifetime expr before landing: three go red, including the healthy-18m
  ride the old rule fired on twice. `promtool` and `yq` come from devbox, so the suite exits 2
  naming the missing tool rather than skipping when run outside it.

`fixtures/run-phase-metric` (FU-160, homelab#287) is the eighth family and the launcher-side twin
of `scan-phase-marker` — the same emitter shape (a `>>>REPLAY:run-phase-metric>>>` block, clock and
transport shadowed in the bridge), pinning `agent_run_phase_seconds{phase=…}`. Two differences are
the reason it is worth reading rather than copied from its twin:

- **The clock is pinned PER CALL, not advanced by the seam.** `run_phase` reads `rp_now` inside a
  command substitution, and a subshell cannot write back — a self-advancing clock would hand out
  its first tick forever and every phase would measure 0 with the fixture green. So the bridge sets
  `RP_NOW` before each call and `rp_now` only reads it, `:?`-guarded. Any seam a clause consumes
  through `$( )` has this property; reach for the fix-debounce family's loud-clock rule, not for
  state inside the seam.
- **The assertion is the ACCUMULATION, not one push.** The pushgateway replaces per metric NAME
  within a group, so an emitter that pushed only the phase that just closed would delete every
  earlier one and each ride would end holding a single number. The growing STDIN block in
  `expected/actions.txt` is that rule under assertion — a fixture pinning only the URL would go
  green on exactly that bug, and it would surface as a dashboard that had quietly only ever shown
  `bookkeeping`.

## When the clause lives inside a manifest

`fixtures/responder-reopen-*` (homelab#228) are the first pair whose `source:` is not a `.sh` file
at all — it is `agents/coordinator/responder-argo.yaml`, whose `container.args[0]` carries ~300
lines of shell. Nothing special was needed: `extract` trims leading whitespace before matching, so
a `# >>>REPLAY:<name>>>>` sentinel sits happily inside the YAML block scalar at whatever column the
manifest indents to, and the extracted block composes as ordinary shell.

Two things that pair does need, and both live in the harness rather than the fixture:

- **`gh --jq` is evaluated by the stub, not ignored.** `coordinator-scan.sh`'s standing rule is to
  pipe to a real `jq`, so no fixture had exercised it; the responder's embedded script uses
  `gh api … --jq` directly, and a stub that served the raw payload would have handed the verdict
  clause an entire JSON array where it expected an issue number. An unrecorded read still dies
  loudly through it — the body is served into a variable first, because `exit 9` from the left half
  of a pipeline is not an exit at all.
- **The seam for non-`gh` I/O is a shell function in the bridge.** The verdict half rings a doorbell
  with `curl`; the bridge shadows `curl` and writes a `CALL curl …` line into `$REPLAY_ACTIONS`, so
  "did this dispatch" is asserted in the same vocabulary as every label write. Adding a third
  PATH-shim would have worked too and buys nothing — the function is the seam pattern the section
  above already describes.

`fixtures/retro-harvest-cell-errored` (homelab#268) is the first fixture whose subject is partly a
**declaration** rather than a clause. Argo — not any shell — decides that an OOMKilled cell is
`Error` and not `Failed`, and `continueOn` is the DAG field that says whether the sibling and the
harvest survive it; no clause reads that field, and kubeconform SKIPs the CronWorkflow kind, so
nothing was checking it. The bridge therefore `awk`s the two cell tasks' `continueOn` lines out of
the shipped manifest and prints them as OUT lines, and the block replays what the harvest does with
the world an errored cell leaves behind (no ride log at all — `tee` never ran, so the output
artifact is unresolvable and `optional: true` stages nothing). Both halves are needed and neither is
sufficient: the consequence replay passes on a manifest whose widening was reverted, and the
declaration alone would pin a string nobody has watched work. The rule this generalizes: read the
declaration OUT of the file (never transcribe it), and only reach for this when the field genuinely
has no clause behind it — a value the shell branches on belongs in the action stream instead.

## Reads must be recorded; writes need not be

A READ with no world file DIES (loudly, exit 9) — an empty payload usually parses and the clause
then asserts on nothing. A WRITE with no world file SUCCEEDS silently: mutations are the output
under test, and most clauses never read the reply back.

That second half was documented from the start and did not work until homelab#208. `_rp_serve`'s
`exit 9` kills the whole stub process from inside a function, so the write path's `|| true` was
unreachable and every unrecorded mutation came back FAILED — clauses took their `gh write refused?`
branch and the fixture pinned the error path while looking like it pinned the happy one. Nothing
caught it because no fixture had yet written without reading back; the `goal-*` terminal fixtures
(`gh issue edit --add-label`, `gh issue close`) were the first. `_rp_serve <key> optional` now
returns 1 instead of dying, and the write path passes it.

Record a write anyway when the clause CONSUMES its output — `gh issue create` prints the new
issue's URL and `harvest-disposition` parses the number out of it.

`fixtures/_selftest-*` are PROBE-FAIL fixtures — deliberately broken, `expect: fail`, one per
detector the runner owns. They run first (the glob sorts them there) so the harness proves itself
before it judges anything else. If one of them ever goes green, the run fails loudly: a check
nobody has watched fail is not a check.

## When a clause file changes and no fixture can apply

The ratchet fails any PR touching a clause file without touching `agents/replay/` (EXEMPT since
2026-08-11: a pin-only diff to a pin-guarded clause file — the canonical no-fixture-applies case,
regexes sourced from `pin-only-lint.sh`), and names a note here as the alternative. Keep that hatch narrow by answering one question: **can the harness observe
this diff at all?** It asserts an action stream — the `gh`/`kubectl` calls a clause emits — so the
answer is no only when the diff emits none. "The branching is unchanged but the payload moved" is
observable, and there the ratchet is doing its job: extend the fixture.

Log each instance here, so the next author sees a register rather than a precedent:

- **homelab#103** — a soft `topologySpreadConstraints` (via `podSpecPatch`) and Sensor CPU
  `requests` added to `coordinate-argo.yaml` / `review-argo.yaml`. Pod *placement*, declared to the
  kube-scheduler: no clause reads it and no branch turns on it. Evidence rather than assertion —
  the full suite stayed green on the change with every `expected/actions.txt` untouched, which is
  the harness itself reporting that the streams did not move.
- **FU-058 belt (2026-08-10)** — one appended `printf | curl` in `retro-argo.yaml`'s harvest step
  (the RetroReportOverdue success-timestamp push). The diff IS observable (a curl in the action
  stream) but `retro-argo.yaml` has no fixture family yet — its FSM-side declaration is
  `unreplayed` and the first retro-lane fixture should record this step's world when it is built
  (jail-lane commit; the ratchet gained the file the same day, so the next PR touch pays properly).
- **retro-lane 2026-08-11 (three more jail-lane clause diffs, same fixture debt)** —
  `f791937` (AWS_REGION in tsenv), `6b1ece6` (harvest runs as root), `4db553e` (bounded worst-K
  slice + pipefail) each touched `retro-argo.yaml` direct-to-master; all observable; the standing
  entry below covers the debt — the first retro-lane fixture family pins ALL of it.
- **guard stderr-fold fix (2026-08-11, homelab#237)** — the guard's busy-probe read kubectl's
  stderr "No resources found" as pod output (`2>&1`), refusing every fire since unsuspend; fixed
  to a split-stream read, both legs verified live from the jail (empty ns → idle, failing probe →
  busy). Observable (a kubectl call + refusal line) — the debt above stands: the first retro-lane
  fixture should pin BOTH the refusal legs and this empty-is-idle case (jail-lane commit).
- **retro-lane debt, PARTLY PAID (homelab#248)** — `fixtures/retro-cell-report-*` and
  `fixtures/retro-harvest-*` are the first retro-lane family: the cell's report-marker self-check
  (both verdicts) and the harvest's cell→filename slug plus its partial-run notice. They do NOT
  discharge the standing entry above — the **guard** (busy-probe legs, ledger delta) and the
  harvest's git/gh half are still unpinned, and `retro-argo.yaml`'s FSM-side declaration stays
  `unreplayed`. The next touch of either extends this family rather than opening a fourth
  register line. **Extended 2026-08-11 (homelab#268)** — `fixtures/retro-harvest-cell-errored`
  joins the family for the DAG's Error phase (see the declaration note above). **Extended
  2026-08-11 (homelab#269)** — `fixtures/retro-harvest-slug-collision` pins the other filename
  branch: two cells on ONE model under different harnesses (`claude:opus` / `goose:opus`) derive
  one slug, so the harvest disambiguates with the harness ON COLLISION ONLY; its sibling
  `retro-harvest-slug` is the regression proof that the ordinary path's names did not move. Still
  unpaid, and still this entry's debt: the **guard** (busy-probe legs, ledger delta) and the
  harvest's git/gh half.

Adding a fixture, recording a world, and the ADR-103 ratchet rule are all in the workflow doc.
