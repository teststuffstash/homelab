# LENS: migration — the dependency-major review (S9 homelab#1989, ADR-141)

**BLOCKING BY CONSTRUCTION.** This lens is not advisory: on a dependency bump the migration
judgment IS the verdict. It is the one stated exception to the advisory steady state of the
other lenses, and it is selected deterministically by `reviewer-session.sh` (label `major` or
`deps-review`, or a lockfile-only diff that crosses a major).

**Semver decides that this lens runs; blast class decides the lane.** An ARMED major (GitHub Actions;
tofu Deployment images and terraform providers — ADR-141 as amended; the `argo-workflows` chart —
ADR-149) merges on your `--approve`: your review is the gate, and
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
   - **Providers / charts:** notes + known issues + the sentinel plan or the rendered diff — and for a
     chart, the **appVersion delta** (the section below), stated before anything else.
   - **Substrate (Talos, Kubernetes, Cilium, Longhorn, Garage):** notes + known issues + the
     management box's canary; these never self-merge.
4. **`## Evidence`** — what you ran and what it showed: the CI run at head, the grep results, the
   upstream URLs, the issue numbers. A claim without a line here is an inference, and you say so.

## Charts: chart semver is not app semver — state the appVersion delta first

A Helm chart's version and the application it ships move independently, and Renovate labels on the
CHART's semver. Read the chart index for BOTH pins before the four headings — `helm show chart
<chart> --repo <url> --version <v>` for the current and the target (or the repo's `index.yaml`,
`appVersion`) — and open `## Upstream` with one line: `chart X → Y, app A → B`. Then review the
delta that is actually crossing:

- **An app major inside a chart minor or patch** is the real migration: `--request-changes` naming
  the app's release notes read it needs. The `deps-review` lane does not run this lens, so say in
  the body that the bump is an app major so the coordinator routes it as one.
- **A chart major with the app on a patch** is a packaging change (CRD delivery, value renames,
  hook jobs): review exactly those against this repo's values and nothing more.
- **For an ARMED chart major (ADR-149) your APPROVED merges.** Approve only when the app delta stays
  inside a minor: `crds.keep: true` means the mechanical revert (`chart-revert`, on
  `ArgoControllerSilent`) does not downgrade CRDs, which is what makes it safe. An app major stays
  `--request-changes` however clean the packaging read is — the lens is the one human-shaped gate
  that lane has.

Origin: ADR-149 (2026-10-05) — the app major rode a chart minor unlensed, and both lens rounds on
the chart major misstated the app's starting version.

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

## Language / tool RUNTIME majors: the read produces follow-ups (what to adopt), not a "needed" list

A runtime (Python, Node, Go, the JDK) is backwards compatible by policy: across three feature
releases the "must change" list is usually EMPTY (openrouter-operator#80, python 3.11→3.14: nothing
removed that the code used). Writing "no adaptation needed" and stopping is the failure — the value
of reading three What's New pages is what the code CAN now do (operator, 2026-09-27: "usually there is
no needed change, just something new and shiny, new best practices"). So for a runtime major, list
under `## Upstream` what the release lets THIS code adopt — each new syntax / stdlib API / idiom with
its call sites (PEP 695 generics for a `ParamSpec`/`TypeVar` decorator, `fromisoformat` parsing `Z`,
`StrEnum`, `tomllib`, `TaskGroup`, the `type` statement, …) and the linter rules that start firing once
`target-version` moves — as ORDINARY review follow-ups: the standard `Follow-ups:` shape, one
issue-ready bullet each (no term of its own). Nothing in it blocks the bump. ⚠ A dependency PR
usually has NO container (ADR-127), so nothing harvests those bullets today — the seat files the one
backlog issue from the review body until FU-292 closes that gap; write them anyway, they are the
record. An empty list is a finding too: say the pages were read and name why nothing applies.

## Version SETS — a runtime bump moves its whole set, or names what it leaves behind

A language / tool runtime is usually pinned in SEVERAL places that must agree
(`docs/dependency-upgrades.md` §Version SETS, owner homelab#2014): for a Python service the
`Dockerfile` `FROM`, `devbox.json` `python@X.Y`, `pyproject.toml` `requires-python`, ruff
`target-version`, mypy `python_version`. A Renovate bump moves ONE member (the image tag). Read
the others as part of the SAME change, not as "lint/dev targets that need not move":

- **CI runs under the devbox interpreter, not the image.** With `devbox.json` still at the old
  major, a green `ci` proves the code on the OLD runtime and nothing about the new one — say so
  under Platform compatibility, and count it as an adaptation this repo needs.
- **devbox pins never move on their own.** The weekly `devbox-update` job re-resolves `@latest`
  packages only; a `python@3.11` pin stays on 3.11 until a human edits it (openrouter-operator#80,
  2026-09-27: python 3.11→3.14 in the image, 3.11 everywhere else, approved as "no adaptation").
- The set moving together IS the legitimate `--request-changes` on a Renovate PR: name every
  member and its new value; the coordinator dispatches a worker onto the branch (or the operator
  lands the members CODEOWNERS owns in THAT repo — read it, never assume — and says so). Bumping `target-version`
  also turns on the new release's lints, so the review lists what they flag.

## Verdict

`--approve` only once every breaking change is N/A or handled in the diff, the known-issues read
found nothing that touches us, and the platform read confirms compatibility — with the four
headings filled. `--request-changes` names the adaptation this repo needs. Neither verdict ever
asks for a re-run of green checks.
