Fixes #1205.

Rows 2–4 of the launcher context-prefetch stage — the half PR #1179 deliberately left unshipped.

## What lands

- **Fix round** (`--work-branch`): `pr.md` (PR body + `compare` commit log) and `reviews.md`
  (verdicts newest-first + inline comments with `file:line`), plus the coordinator's
  ruling/arbitration comment when one is on the thread. The **newest verdict is REQUIRED** —
  unreadable defers (exit 0, no pod, no round consumed).
- **ci-red round**: `ci-failure.md` — failing check-runs (name/conclusion/URL) plus a bounded
  `--log-failed` tail. An unreadable log defers: the round exists to read it.
- **`/work/context/` as a directory with `index.txt`**, replacing r1's single `/work/issue.md`.
  Optional items that fail degrade LOUDLY — `MISSING: <item> — <error>` in the index, never
  silently absent. The env-card line names the bundle index.
- **Delivery moved OFF argv** (the codeowner acceptance item from #1175): the bundle is written to
  a per-pod ConfigMap and mounted at `/work/context/`, so bundle size no longer bounds
  dispatchability. Previously a thread large enough to exceed `argv_guard` deferred *forever* —
  the next pass re-read the same oversized thread. A ConfigMap-create failure falls back to the
  old argv prelude rather than dropping the ride.
- **`docs/agents/roles.md`** unified on `/work/context/` — closing the doc-follows-code gap the
  #1175 codeowner read (ADR-110) recorded.
- **Replay-pinned** (ADR-103): `context-prefetch/{fix-round,fix-round-unreadable,ci-red,ci-red-unreadable}`
  arms — readable and required-unreadable for each round class, the deferral line and no pod create.

## Footprint exception — `agents/coordinator/rbac.yaml` (+5/−0)

Outside this issue's declared `Touches:`, and flagged as such at dispatch. It is kept because the
off-argv acceptance item requires it: the launcher SA needs `configmaps {create,delete}` in the
pod's namespace or ConfigMap delivery cannot exist. The hunk is exactly those two verbs on that
one resource; no other rule is touched.

## Provenance

The build ran as `agent-homelab-issue-1205-r1` (round 1, `claude/haiku` after a
`goose-32602-truncation` strike swap off `deepseek/deepseek-v4-flash` — a strike, so no round
consumed). The worker built and **pushed** this branch, then `gh pr create` failed with
`API rate limit already exceeded for installation ID 142724430`, which also took out its
auto-merge arming, issue-link and label-flip bookkeeping. The coordinator is opening and arming
the PR to complete that terminal bookkeeping; the commits and the acceptance evidence are the
worker's. Its claim — `devbox run clause-replay`, 376 fixtures green — is unverified by the
coordinator and is CI's and the reviewer's to gate.
## Footprint exception 2 — `argocd/resources/agentstack/{composition,rbac}.yaml` (codeowner read, 2026-09-05)

The `agents/coordinator/rbac.yaml` grant above widens only the GLOBAL `agent-coordinator`
ClusterRole. All four stacks are graduated (per-stack loops): the launcher actually runs as
ServiceAccount `agentstack-loop` in `<stack>-agents`, dispatching into each fixer namespace under
the Composition-rendered **namespaced** Role `agentstack-loop`
(`argocd/resources/agentstack/composition.yaml`) — pods/pods-log/exec, PVC read,
OpenRouterKey lifecycle, but no `configmaps` verbs at all. Every graduated stack would therefore
have silently taken the argv fallback on every dispatch, never the ConfigMap path this PR ships.
Added `configmaps: [create, patch, delete]` to that Role. Crossplane cannot compose a Role
granting a verb its own aggregated ClusterRole doesn't hold (the escalation check documented at
the top of `argocd/resources/agentstack/rbac.yaml`) — added `create` to that ClusterRole's existing
`configmaps, endpoints, events, …` rule to match (kept the existing verb order, appended one).
One transient Composition reconcile is expected if the ClusterRole syncs after the render — the
documented self-heal, not a bug.

## Fallback shape (codeowner read)

The argv fallback (taken when the ConfigMap create IS refused) wrote a single concatenated
`/work/context/bundle.txt`, but `render_env_card()` tells the ride to read
`/work/context/index.txt` for the bundle index, then `/work/context/issue.md` FIRST — neither
name existed on that path. Fixed the fallback to write those exact two files (two base64
payloads in the prelude). The optional items the fallback omits for argv-size reasons (`pr.md`,
`reviews.md`, `arbitration.md`, `ci-failure.md`) are downgraded from `OK` to
`MISSING  argv fallback (ConfigMap create refused)` in the index when they DID fetch, so the
index never silently claims an item that isn't there — items already `MISSING` for their own
reason (e.g. no failing check runs) are left untouched.

Ratchet: `agents/replay/stubs/kubectl` writes always succeeded unconditionally, so no existing
fixture could exercise a refused ConfigMap create. Generalized the stubs' per-call
failure-injection override (homelab#740) from the gh-only `STUB_GH_<slug>` to a
`$_RP_TOOL`-prefixed `STUB_<TOOL>_<slug>` (backward compatible for `gh`) and wired it into
`kubectl`'s mutation branch. Added `context-prefetch/fix-round-cm-refused`
(`STUB_KUBECTL_create=fail`, reusing the `fix-round` world) to pin the two-file fallback and the
MISSING-downgrade positively — `devbox run -- bash agents/replay/run.sh -v
agents/replay/fixtures/context-prefetch` and the full `devbox run clause-replay` (384 fixtures)
both green; index regenerated.

<!-- agent-touches: begin -->
Touches-escapes: agents/coordinator/rbac.yaml|governance
<!-- agent-touches: end -->


