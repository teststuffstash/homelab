# worlds/ — the states the launcher's rows run in

A **world** is a named fixture state: expected behaviour is a function of (launcher, world). The
launcher's worlds are the replay harness's ([`agents/replay/README.md` §The cleanup contract](../../../../replay/README.md)),
named here so a row can say which one it runs in. This directory holds no world files of its own:
each world lives where its fixture family keeps it, and this page is the index.

A launcher world has up to three halves, and a row names the halves its case varies:

- **a recorded GitHub state** — `world/gh/*.json` responses served by the `gh` stub, keyed by the
  invocation they answer (reads die when unrecorded, writes are recorded as actions);
- **a launcher-variable state** — the shell variables the clause reads, set per row in
  `rows/<id>/vars.sh` (the stack row, argv flags, `STATS`, `ERR_CLASS`, …);
- **the gateway seam** — `curl` shadowed in the family's bridge: the POST body is the asserted
  request, the row's `GW_REPLY_HTTP` / `GW_REPLY_BODY` is the gateway's answer, a DELETE is a
  release.

## Recorded GitHub worlds

| world | lives in | what it is |
|---|---|---|
| `homelab-278-tree` | `agents/replay/fixtures/goal-ancestor/worlds/` | the goal #278 tree: a bucket child (#367) two hops below a funded `task/goal`, and a direct child (#291) |
| `circles-constructed-parents` | `agents/replay/fixtures/goal-ancestor/worlds/` | constructed circles parents: no goal above #88; an unlabelled `Budget:` ancestor of #90; a child with both (#92) |
| `gate-homelab-278` | `agents/replay/fixtures/goal-budget-gate/worlds/` | goal #278 with its children, their spend ledger and the `Budget:` line — the gate's base |
| `gate-homelab-278-cross` | `agents/replay/fixtures/goal-budget-gate/worlds/` | the same goal with a cross-repo child whose number collides with a same-repo issue |
| `gate-homelab-278-no-ledger` | `agents/replay/fixtures/goal-budget-gate/worlds/` | `gate-homelab-278` with the ledger unreachable (the cap-sum fallback) |
| `issue-1175-fix-round` | `agents/replay/fixtures/context-prefetch/*/world/` | issue #1175 on `test-project` with comments, PR #42 (`fix/issue-1175-test`), its reviews, inline comments, check runs; each `context-prefetch/<case>` carries its own copy with its case's delta (the fixture dir name says which) |
| `ci-red-base` | `agents/replay/fixtures/ci-failure-run-select/ci-failure-run-select/worlds/base/` | a fix branch with one run concluded `failure` and a newer skipped run (constructed — its `provenance.yaml` says so) |

## Launcher-variable worlds

| world | what it fixes |
|---|---|
| `launcher-vars` | no recorded API state — the row's whole condition is in `rows/<id>/vars.sh` and the `env` column. The default world of every gateway-seam and outcome row. |
| `stack-platform` | `launcher-vars` with the `stacks.json` row `{"name": "platform"}` and `AGENT_GATEWAY=sessions` — the one stack the gateway admits |
| `stack-other` | `launcher-vars` with a non-platform stack row — the old path |

## The gateway seam

| world | what the shadowed gateway answers |
|---|---|
| `gw-dispatch-bound` | 200 `dispatch` with `session.id`, `rail`, `harness`, `model`, `env_keys`, `pull_url` and no credential — the shape of [`gateway/specs/use-cases/uc-1/bind-response.json`](../../../../../gateway/specs/use-cases/uc-1/bind-response.json) |
| `gw-dispatch-unbound` | 200 `dispatch` with `session.token` and an `env` map (the unbound lane's shape) |
| `gw-defer` | 200 `defer` with a `reason` and `retry_after_s` |
| `gw-error` | a non-200 (503 `tokenreview-transient`), or no answer (unreachable) |
| `gw-outcome-strike` | `POST /sessions/{id}/outcome` answers 200 with `strike: {class, scope}` |

The seam's answers are hand-written, not recorded from a live gateway: they are the launcher's
reading of the supplier's schema, not the supplier's proof (⚑ gap — one seam answer, the
`gateway-admit` row `bound-dispatch`, sends `tier: strong`, a value
[`sessions.schema.json`](../../../../../gateway/specs/endpoints/sessions.schema.json) `$defs.tier`
does not admit; nothing validates seam requests against the supplier schema).
