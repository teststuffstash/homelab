# LENS: migration — the dependency-major review (S9 homelab#1989, ADR-141)

**BLOCKING BY CONSTRUCTION.** This lens is not advisory: on a dependency bump the migration
judgment IS the verdict. It is the one stated exception to the advisory steady state of the
other lenses, and it is selected deterministically by `reviewer-session.sh` (label `major` or
`deps-review`, or a lockfile-only diff that crosses a major).

**Semver decides that this lens runs; blast class decides the lane.** An ARMED major (a GitHub
Actions bump — the CI-exercised class) merges on your `--approve`: your review is the gate, and
the FU-1990 revert chain rolls a post-merge failure back. An UN-ARMED major is human-gated: the
launcher-owned handoff (`agents/major-handoff.sh`) accepts your APPROVED only when it carries the
four headings below, and a human merges. The procedure is the same in both lanes.

## The three halves, in order — then the evidence

Write the review body under exactly these four headings (line-anchored, this spelling — the
handoff gate matches them literally):

1. **`## Upstream`** — for EVERY major crossed (v4 → v7 is three), the release / migration notes:
   fetch them (WebFetch, or `gh api repos/<owner>/<repo>/releases` — github.com is baseline
   egress); list each breaking change and map it onto THIS repo's usage (grep how the thing is
   invoked: `.github/`, `scripts/`, `chart/`, `Makefile`, `devbox.json`). N/A is a finding too —
   say why.
2. **`## Known issues`** — the upstream issue tracker, read, not assumed: open issues against the
   target version (`gh api "repos/<owner>/<repo>/issues?state=open&per_page=50"` plus a search on
   the target tag; for an Action, the runner/runtime it needs). Name the ones that touch our usage
   or our platform; "none found, N open issues scanned on <date>" when there are none.
3. **`## Platform compatibility`** — against what the fleet ACTUALLY runs, read from
   `/work/homelab` (a shallow master clone made in your prep; a missing clone is a TOOL_GAP you
   name, never a guess): the ARC runner image and its Actions Runner version
   (`docker/arc-runner/Dockerfile`, the `FROM ghcr.io/actions/actions-runner:<ver>` line;
   `argocd/platform/arc-runners.yaml`), the Talos / Kubernetes / Cilium versions
   (`machines/README.md`), the org Renovate policy (`.github/renovate-global.json` — there is NO
   per-repo `renovate.json` by design; never report its absence). Per class:
   - **Actions:** notes + known issues + runner compatibility (the Node runtime the action needs
     vs the Runner version above) + CI on the bumped head (a `pull_request` workflow runs the
     PR's own file, so a green `ci` at head IS the runner-compat proof for the workflows it ran;
     name the push-only workflows it did not run — the revert chain covers them).
   - **Providers / charts:** notes + known issues + the sentinel plan or the rendered diff.
   - **Substrate (Talos, Kubernetes, Cilium, Longhorn, Garage):** notes + known issues + the
     management box's canary; these never self-merge.
4. **`## Evidence`** — what you ran and what it showed: the CI run at head, the grep results, the
   upstream URLs, the issue numbers. A claim without a line here is an inference, and you say so.

## Renovate is the author — what that changes

- **Nobody pushes to a Renovate branch unless the coordinator dispatches a fixer.** A
  `--request-changes` is legitimate when THIS REPO needs adapting to the new major (a workflow
  input renamed, a config key gone, a call that must change): name the adaptation, and the
  coordinator's changes-requested clause dispatches a worker onto the branch — that is normal for
  a major. It is NOT legitimate for work Renovate does itself: a call site that exists on master
  but not in this diff (added after the PR opened) is bumped on Renovate's next rebase
  (`rebaseWhen: behind-base-branch`), never by a request; asking for it parks the PR and — once a
  fixer pushes — stops Renovate from maintaining it (agent-coordinator#14, 2026-09-26).
- **Renovate works in batches.** List the sibling open Renovate PRs of this repo (`gh api
  repos/<slug>/pulls?state=open`, keep the entries whose `user.login` starts with
  `homelab-renovate`) and read yours as one member: a runner or runtime fact you establish
  (Node 24 support, the Runner version) holds for every sibling — state it once, cite the sibling
  numbers, never re-derive it per PR. A grouped PR (`github-actions (major)`) is the whole batch
  in one diff: one `## Upstream` entry per action.
- **Never close a Renovate PR** and never ask a human to (a closed PR is a rejected version); the
  durable "not this version" is a config change (`.github/renovate-global.json`) — name it when
  that is the remedy.

## Verdict

`--approve` only once every breaking change is N/A or handled in the diff, the known-issues read
found nothing that touches us, and the platform read confirms compatibility — with the four
headings filled. `--request-changes` names the adaptation this repo needs. Neither verdict ever
asks for a re-run of green checks.
