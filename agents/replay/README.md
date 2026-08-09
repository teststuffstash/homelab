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

Do it this way round, not the other. Stubbing the whole helper would pin the clause's *branching*
and nothing else, and the reason that sum lives in a shared file at all is that a second copy of it
would drift from the launcher's — so the fixture must be able to see that drift. Copying the helper
into the fixture directory is worse still, for the reason `run.sh` already gives about transcribed
clauses (#166): a copy goes green while the original moves.

The seams are ordinary shell functions, declared as seams in the helper's header. If a clause you
are pinning reaches for I/O with no seam, add one there rather than a `REPLAY_*` branch in
production code — a test-only backdoor in a clause is a clause with an untested path.

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

Adding a fixture, recording a world, and the ADR-103 ratchet rule are all in the workflow doc.
