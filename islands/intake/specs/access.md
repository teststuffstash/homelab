---
id: IF-ACCESS
use-cases: []
---
# Access — what the sitting's identity can do

**Every act the rules write, the sitting's identity can perform — and nothing beyond.** A rule in
[`rules/`](../rules/intake.md) that tells a sitting to do something its identity is refused is a
defect of the pair, not of the sitting; so is a grant no rule needs. This page holds the two halves
side by side: the acts the rules write (positive rows) and the acts the identity must be refused
(negative rows). Rows point at the declared records — the rulesets
([`tofu/github/repo_rulesets.tf`](../../../tofu/github/repo_rulesets.tf),
[`org_ruleset.tf`](../../../tofu/github/org_ruleset.tf)), the workflow manifest
([`agents/coordinator/island-intake-argo.yaml`](../../../agents/coordinator/island-intake-argo.yaml)),
the token's mint site ([`agents/coordinator/git-token.yaml`](../../../agents/coordinator/git-token.yaml)),
the App declaration ([`docs/github-apps.yaml`](../../../docs/github-apps.yaml)) and the gateway
policy ([`argocd/resources/agent-gateway/policy.json`](../../../argocd/resources/agent-gateway/policy.json))
— and never restate them. How a sitting judges is the rules' business, not this page's.

**The sitting's identity.** Rows name "the sitting's identity", never an App. It is whatever the
workflow's `GH_TOKEN` resolves to: the Secret `intake-git`, minted from the `homelab-intake` App
([INTAKE-ACCESS-IDENTITY](#intake-access-identity)), an App used by nothing else
([INTAKE-ACCESS-OWN-APP](#intake-access-own-app)). The cluster identity (the gateway caller, the
kube API) is the workflow's ServiceAccount.

## Interface — the machine half

| requirement | declared record | proven by |
|---|---|---|
| [INTAKE-ACCESS-IDENTITY](#intake-access-identity) | the manifest's `serviceAccountName` and `GH_TOKEN` Secret refs → `ExternalSecret` → `GithubAccessToken` → `docs/github-apps.yaml` | the chain, followed |
| [INTAKE-ACCESS-GOAL-BRANCH](#intake-access-goal-branch) | rulesets covering `refs/heads/goal/**`; the mint's `contents` | a static join + a recorded world |
| [INTAKE-ACCESS-ISSUES](#intake-access-issues) | the mint's `issues`, `repositories` | a static join |
| [INTAKE-ACCESS-READ-PR](#intake-access-read-pr) | the mint's `pull_requests`, `checks`, `statuses`, `actions` | a static join |
| [INTAKE-ACCESS-CLONE](#intake-access-clone) | the mint's `contents`, `repositories` | a static join (homelab only) |
| [INTAKE-ACCESS-GATEWAY](#intake-access-gateway) | `policy.json` `callers` | a static join |
| [INTAKE-ACCESS-TRANSCRIPTS](#intake-access-transcripts) | the manifest's `agent-transcripts-s3` keys | — |
| [INTAKE-ACCESS-METRICS](#intake-access-metrics) | the manifest's `PROMETHEUS`, `PUSHGATEWAY` | — |
| [INTAKE-ACCESS-DENIED](#intake-access-denied) | every ruleset's `bypass_actors` and rules; the mint | a static join |
| [INTAKE-ACCESS-OWN-APP](#intake-access-own-app) | the App's mint sites and its Secret's consumers; its declared permissions | a static join |

## Requirement index

| Requirement | section | Status |
|---|---|---|
| [INTAKE-ACCESS-IDENTITY](#intake-access-identity) | who acts | 🚧 WIP — no evidence publisher for this root (rule-labelled tests in `specs-tests/tests/test_access.py` pass locally against the declared records) |
| [INTAKE-ACCESS-GOAL-BRANCH](#intake-access-goal-branch) | what the rules write | 🚧 WIP — no evidence publisher for this root (`create-goal-ref`, `refused-2026-11-22` and `accepted-after-the-fix` pass locally against `tofu/github/repo_rulesets.tf` and the two recorded worlds; the accepted answer was recorded after the 2026-11-22 apply, under the previous identity `coordinator-git` — for `homelab-intake` the creation rests on the static join: its `contents: write` against the same rulesets). ⚑ gap — the same identity may also delete a `goal/**` ref (the probe's `204`); no row says whether it should |
| [INTAKE-ACCESS-ISSUES](#intake-access-issues) | what the rules write | 🚧 WIP — no evidence publisher for this root (`issue-acts` passes locally against the mint site and `docs/github-apps.yaml`); unverified — a stack repo's write: the stack islands' repos come from the live claims, which no test reads |
| [INTAKE-ACCESS-READ-PR](#intake-access-read-pr) | what the rules write | 🚧 WIP — no evidence publisher for this root (`pr-and-checks-read` passes locally against the mint site and `docs/github-apps.yaml`) |
| [INTAKE-ACCESS-CLONE](#intake-access-clone) | what the rules write | 🚧 WIP — no evidence publisher for this root (`clone-homelab` passes locally); unverified — `clone-stack-repo`: no test joins the live claims' `repos[].intake.facts` repos to the mint's `repositories` |
| [INTAKE-ACCESS-GATEWAY](#intake-access-gateway) | what the rules write | 🚧 WIP — no evidence publisher for this root (`admit-coordinator-platform` passes locally against `policy.json`) |
| [INTAKE-ACCESS-TRANSCRIPTS](#intake-access-transcripts) | what the rules write | 🚧 WIP — no evidence pipeline yet: missing proof — the reader and writer keys' bucket grants are not read from a declared record by any test |
| [INTAKE-ACCESS-METRICS](#intake-access-metrics) | what the rules write | 🚧 WIP — no evidence pipeline yet: missing proof — no test reads the egress the sitting's pod has to Prometheus, Alertmanager and the Pushgateway |
| [INTAKE-ACCESS-DENIED](#intake-access-denied) | what the identity must not do | 🚧 WIP — no evidence publisher for this root (`on-no-bypass-list`, `update-without-checks`, `merge-without-review`, `administer-repo`, `push-workflow-file`, `review-or-merge-pr`, `rerun-a-workflow` pass locally against `tofu/github/`, the mint site and `docs/github-apps.yaml`); unverified — rulesets made outside `tofu/github/` (none is expected) |
| [INTAKE-ACCESS-OWN-APP](#intake-access-own-app) | its own App | 🚧 WIP — no evidence publisher for this root (`used-by-nothing-else`, `least-set` pass locally against the mint sites, the manifests and `docs/github-apps.yaml`); the live token was not read by this root's tests — its world is the declared records |

## Who acts

### INTAKE-ACCESS-IDENTITY

The sitting runs as the CronWorkflow `island-intake`'s ServiceAccount, and every GitHub call it
makes carries the `GH_TOKEN` its pods read. Every `GH_TOKEN` entry of the workflow names the same
Secret; that Secret is written by exactly one `ExternalSecret` from exactly one
`GithubAccessToken` generator, whose `appID` is an App declared in `docs/github-apps.yaml`. The
token's effective grant on a permission is the lower of what the generator requests and what the
App declares (the FU-098 ⊆-invariant, held by `scripts/github-apps-lint.py`). The other rows of
this page read that effective grant and the generator's `repositories`.

**World:** the declared records at the commit under test.

#### Which identity the sitting acts as

Legend: `record` = the declared record read; `expected?` = what it resolves to.

| description | record | expected? |
|---|---|---|
| sitting-runs-as-island-intake | the workflow's `serviceAccountName` | `island-intake` |
| token-is-homelab-intake | the `GH_TOKEN` Secret refs → `ExternalSecret` → `GithubAccessToken` → `appID` | Secret `intake-git`, App `homelab-intake` |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "INTAKE-ACCESS-IDENTITY.md"

</details>

## What the rules write

### INTAKE-ACCESS-GOAL-BRANCH

A sitting that files a Goal cuts the Goal's branch `refs/heads/goal/<n>-<slug>` at the default
branch's head itself ([`rules/intake.md`](../rules/intake.md) §A bot-authored Goal). A creation
carries no check run, so a ruleset that covers `goal/**` and enforces `required_status_checks` on
creation refuses it for every identity off its bypass list: such a ruleset sets
`do_not_enforce_on_create`. Creating a ref is a contents write on the repo. A sitting is on no
bypass list ([INTAKE-ACCESS-DENIED](#intake-access-denied)), so this creation is the one way the
rules have to make the branch.

> **External:** GitHub REST `POST /repos/{owner}/{repo}/git/refs` (create a reference) needs
> `contents: write`; a ruleset's `required_status_checks` rule applies to ref creation unless
> `do_not_enforce_on_create` is set — the provider attribute exists in the installed
> `integrations/github` provider; the refusal's body names no rule (world below), so the cause is
> read from the rulesets, not from the answer. The creation was verified against the live API
> after the apply (the accepted world).

**World:** [create-ref-refused-2026-11-22](worlds/README.md#create-ref-refused-2026-11-22) for the
refusal, [create-ref-accepted-2026-11-22](worlds/README.md#create-ref-accepted-2026-11-22) for the
accepted answer; the declared records for the static join.

#### Cutting a Goal's branch

Legend: `rulesets` = the state of every ruleset covering the ref; `expected?` = the API's answer.

| description | world | ref | rulesets | expected? |
|---|---|---|---|---|
| create-goal-ref | declared records | `refs/heads/goal/<n>-<slug>` at the default branch's head | every check-enforcing ruleset sets `do_not_enforce_on_create` | created |
| refused-2026-11-22 | create-ref-refused-2026-11-22 | `refs/heads/goal/3656-scan-checkpoint-b` | `required-checks` enforces its checks on creation | refused, `422` `Reference update failed` |
| accepted-after-the-fix | create-ref-accepted-2026-11-22 | `refs/heads/goal/0-access-probe` | as `create-goal-ref`, applied | `201` with the new ref |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "INTAKE-ACCESS-GOAL-BRANCH.md"

</details>

### INTAKE-ACCESS-ISSUES

A sitting labels, comments on, closes, files and edits issues, and binds sub-issues and
`blockedBy` edges ([`rules/intake.md`](../rules/intake.md) §A bot-authored Goal and its outcomes):
every one an Issues API write on the island's repo. The identity holds `issues: write` there.

**World:** the declared records.

#### Issue writes

| description | act | repo | expected? |
|---|---|---|---|
| issue-acts | label · comment · close · file · edit · sub-issue | `teststuffstash/homelab` | allowed (`issues: write`) |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "INTAKE-ACCESS-ISSUES.md"

</details>

### INTAKE-ACCESS-READ-PR

A sitting reads a PR's body, reviews and comments, and a covering PR's checks
([`rules/intake.md`](../rules/intake.md) §What you read). Check runs, commit statuses, and the
workflow run behind a check suite (which `gh`'s status rollup reaches) are separate permissions.

**World:** the declared records.

#### PR reads

| description | act | expected? |
|---|---|---|
| pr-and-checks-read | read body, reviews, check runs, statuses, the check suite's run | allowed (`pull_requests`, `checks`, `statuses`, `actions` ≥ read) |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "INTAKE-ACCESS-READ-PR.md"

</details>

### INTAKE-ACCESS-CLONE

Every sitting clones homelab; a stack island's sitting also clones the stack's repo
([../README.md](../README.md) §Stack islands) with the same token. A clone needs `contents: read`
on a repo the mint's `repositories` lists.

**World:** the declared records.

#### Clones

| description | repo | expected? |
|---|---|---|
| clone-homelab | `teststuffstash/homelab` | allowed |
| clone-stack-repo | a repo a live claim declares under `repos[].intake.facts` | allowed |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "INTAKE-ACCESS-CLONE.md"

</details>

### INTAKE-ACCESS-GATEWAY

Every session of a sitting is admitted by the gateway as the platform's, role `coordinator`
([../README.md](../README.md) §Stack islands), the caller being the workflow's ServiceAccount
([GW-SESSIONS-AUTH](../../../gateway/specs/endpoints/sessions.md#gw-sessions-auth) — what the
gateway answers is the supplier's).

**World:** the declared records.

#### Admission

| description | caller | stack | role | expected? |
|---|---|---|---|---|
| admit-coordinator-platform | the workflow's ServiceAccount | `platform` | `coordinator` | a `callers` entry grants it |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "INTAKE-ACCESS-GATEWAY.md"

</details>

### INTAKE-ACCESS-TRANSCRIPTS

A sitting reads ride records (`s3://agent-transcripts/homelab/issue-<n>/…`) and writes its own
receipt under `s3://agent-transcripts/homelab/intake-<island>-<day>/`, with the reader and writer
keys of the Secret the manifest names.

**World:** none yet.

#### Transcripts

| description | act | expected? |
|---|---|---|
| read-ride-record | read `homelab/issue-<n>/<run>/run.log` | allowed (reader key) |
| write-receipt | write `homelab/intake-<island>-<day>/…` | allowed (writer key) |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "INTAKE-ACCESS-TRANSCRIPTS.md"

</details>

### INTAKE-ACCESS-METRICS

A sitting reads the live state of an alert and its gauge (Alertmanager, Prometheus) and the
experiment metrics, and pushes its own `island_intake_*` gauges to the Pushgateway, at the
addresses the manifest sets.

**World:** none yet.

#### Metrics

| description | act | expected? |
|---|---|---|
| read-alerts-and-gauges | `GET /api/v2/alerts`, `GET /api/v1/query` | allowed |
| push-sitting-gauges | `POST /metrics/job/island_intake/…` | allowed |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "INTAKE-ACCESS-METRICS.md"

</details>

## What the identity must not do

### INTAKE-ACCESS-DENIED

The sitting's identity is on no ruleset's bypass list: every `Integration` bypass actor resolves to
another App, and an App token never holds the `OrganizationAdmin` role. So every update of the
default branch or a `goal/**` ref waits on the required checks (only a creation is exempt), and
every change to them comes by an approved pull request. It holds no `administration` and no
`workflows` permission — both decided non-grants of its App — so no ruleset, repository setting or
workflow file is its to change; and it reads pull requests and workflow runs without writing them,
so it reviews, merges and re-runs nothing.

> **External:** the `OrganizationAdmin` bypass actor matches org owners' user identities, never an
> App installation token; a ruleset's `pull_request` rule refuses a direct push or merge that did
> not come through an approved pull request. Verify during the live probe after the apply.

**World:** the declared records.

#### Refused acts

| description | act | expected? |
|---|---|---|
| on-no-bypass-list | any act a ruleset gates | refused — no bypass actor is the sitting's App |
| update-without-checks | push to or merge into the default branch or `goal/**` without the required checks | refused |
| merge-without-review | change the default branch or `goal/**` without an approved pull request | refused |
| administer-repo | edit or delete a ruleset or a repository setting | refused (no `administration`) |
| push-workflow-file | push a change under `.github/workflows/` | refused (no `workflows`) |
| review-or-merge-pr | review, merge, edit or comment on a pull request (Pulls API) | refused (`pull_requests` read only) |
| rerun-a-workflow | re-run or cancel a workflow run | refused (`actions` read only) |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "INTAKE-ACCESS-DENIED.md"

</details>

## Its own App

### INTAKE-ACCESS-OWN-APP

The sitting runs as its own GitHub App, used by nothing else: the App mints at exactly one site,
and that site's Secret is read by the sitting's workflow alone. Its permissions are exactly the
least the positive rows above need — a grant no row needs, or a need the App lacks, breaks the row:

| permission | level | needed by | broader than the act? |
|---|---|---|---|
| `metadata` | read | every App | — |
| `contents` | write | [INTAKE-ACCESS-GOAL-BRANCH](#intake-access-goal-branch) `create-goal-ref` | yes — `write` also pushes commits and creates any unprotected branch; the clones alone need `read` |
| `issues` | write | [INTAKE-ACCESS-ISSUES](#intake-access-issues) | yes — also edits and closes issues no rule names; the Issues API has no narrower grant |
| `pull_requests` | read | [INTAKE-ACCESS-READ-PR](#intake-access-read-pr) | — |
| `checks` | read | [INTAKE-ACCESS-READ-PR](#intake-access-read-pr) | — |
| `statuses` | read | [INTAKE-ACCESS-READ-PR](#intake-access-read-pr) | — |
| `actions` | read | [INTAKE-ACCESS-READ-PR](#intake-access-read-pr) (the status rollup's run) | yes — also reads run logs |

**World:** the declared records. The live token (its repositories, a read, a refused pull-request
write) was read once by the seat when the App went live; no world records it.

#### One App, one consumer

| description | record | expected? |
|---|---|---|
| used-by-nothing-else | every mint site of the App's id; every manifest reading its Secret | one site (`intake-git.yaml`); one consumer (the island-intake workflow) |
| least-set | the App's declared permissions and the mint's requested ones | equal to the table above |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "INTAKE-ACCESS-OWN-APP.md"

</details>
