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
  register line.

Adding a fixture, recording a world, and the ADR-103 ratchet rule are all in the workflow doc.
