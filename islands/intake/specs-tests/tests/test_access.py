"""specs/access.md — one rule()-labelled case per proven row.

Every case reads the DECLARED records through `decl.py` (the rulesets, the workflow manifest, the
token's mint site, the App declaration, the gateway policy); none carries a copy of them. Each
expected value is derived in a comment from the page and the source it cites.
"""

from __future__ import annotations

import json

import allure
import pytest

import decl
from conftest import SPECS, rule

GOAL_REF = "refs/heads/goal/0-access-probe"  # any goal/<n>-<slug>: the page's create-ref row
MASTER_REF = "refs/heads/master"
WORLDS = SPECS / "worlds"


def _identity() -> decl.Identity:
    (secret,) = decl.token_secret_refs(decl.sitting_workflow())  # exactly one Secret, or unpack fails
    return decl.identity_of(secret)


def _has_rule(rs: decl.Ruleset, kind: str) -> list[decl.Block]:
    return [b for r in rs.block.children("rules") for b in r.children(kind)]


# ── INTAKE-ACCESS-IDENTITY ─────────────────────────────────────────────────────────────────────


@pytest.mark.parametrize("row", [pytest.param("sitting-runs-as-island-intake", marks=rule("INTAKE-ACCESS-IDENTITY"),
                                              id="sitting-runs-as-island-intake")])
def test_sitting_service_account(row: str) -> None:
    # islands/intake/README.md §Consumer contracts: the pods run "as ServiceAccount `island-intake`".
    allure.dynamic.title(row)
    wf = decl.sitting_workflow()
    assert wf["spec"]["workflowSpec"]["serviceAccountName"] == "island-intake"


@pytest.mark.parametrize("row", [pytest.param("token-is-homelab-intake", marks=rule("INTAKE-ACCESS-IDENTITY"),
                                              id="token-is-homelab-intake")])
def test_token_identity(row: str) -> None:
    # docs/github-apps.yaml `homelab-intake` purpose: "homelab-intake[bot] is the sitting". Every GH_TOKEN
    # of the workflow reads one Secret, and the chain Secret → ExternalSecret → GithubAccessToken →
    # appID lands on that App (mint site agents/coordinator/intake-git.yaml).
    allure.dynamic.title(row)
    refs = decl.token_secret_refs(decl.sitting_workflow())
    assert refs == {"intake-git"}, f"the sitting's GH_TOKEN reads {sorted(refs)}, not the intake App's Secret intake-git"
    ident = decl.identity_of("intake-git")
    allure.dynamic.parameter("generator", ident.generator)
    allure.dynamic.parameter("app", f"{ident.slug} ({ident.app_id})")
    assert ident.slug == "homelab-intake"


# ── INTAKE-ACCESS-GOAL-BRANCH ──────────────────────────────────────────────────────────────────


@pytest.mark.parametrize("row", [pytest.param("create-goal-ref", marks=rule("INTAKE-ACCESS-GOAL-BRANCH"),
                                              id="create-goal-ref")])
def test_create_goal_ref(row: str) -> None:
    # The page: creating refs/heads/goal/<n>-<slug> at the default branch's head → created.
    # (1) A creation carries no check run, so a ruleset that covers the ref and enforces
    #     required_status_checks on creation refuses it for an identity off its bypass list
    #     (the 2026-11-22 world): every such ruleset must set do_not_enforce_on_create = true.
    # (2) Creating a ref is a contents write (POST /repos/{o}/{r}/git/refs) on the repo.
    allure.dynamic.title(row)
    covering = [rs for rs in decl.rulesets() if rs.target == "branch" and decl.covers(rs.include, GOAL_REF)]
    assert covering, "no ruleset covers goal/** — the page's premise moved"
    enforcing = [(rs, b) for rs in covering for b in _has_rule(rs, "required_status_checks")]
    assert enforcing, "no covering ruleset carries required_status_checks — the row's premise moved"
    for rs, b in enforcing:
        allure.dynamic.parameter(rs.name, b.attrs.get("do_not_enforce_on_create", "<unset>"))
        assert b.attrs.get("do_not_enforce_on_create") == "true", (
            f"{rs.resource} ({rs.name!r}) covers {GOAL_REF} and enforces its required checks on CREATE "
            "— a sitting's goal-branch cut is refused (HTTP 422)")
    ident = _identity()
    assert ident.level("contents") == decl.LEVELS["write"], ident.minted
    assert "homelab" in ident.repositories


@pytest.mark.parametrize("row", [pytest.param("refused-2026-11-22", marks=rule("INTAKE-ACCESS-GOAL-BRANCH"),
                                              id="refused-2026-11-22")])
def test_recorded_refusal(row: str) -> None:
    # World create-ref-refused-2026-11-22 (specs/worlds/README.md): the sitting's own create-ref
    # call before the fix. Read strictly: every field present, nothing extra. Joined to the
    # rulesets: the refused ref is a goal/** ref a check-enforcing ruleset covers — the condition
    # create-goal-ref's first clause removes.
    allure.dynamic.title(row)
    world = json.loads((WORLDS / "create-ref-refused-2026-11-22.json").read_text(encoding="utf-8"))
    assert set(world) == {"provenance", "request", "response"}
    assert set(world["request"]) == {"method", "path", "fields"}
    assert set(world["request"]["fields"]) == {"ref", "sha"}
    assert set(world["response"]) == {"status", "body"}
    assert set(world["response"]["body"]) == {"message", "documentation_url", "status"}
    req, resp = world["request"], world["response"]
    allure.attach(json.dumps(world, indent=2), name="world", attachment_type=allure.attachment_type.JSON)
    assert req["method"] == "POST" and req["path"].endswith("/git/refs")
    assert resp["status"] == 422 and resp["body"]["status"] == "422"
    assert resp["body"]["message"] == "Reference update failed"
    ref = req["fields"]["ref"]
    assert any(decl.covers(rs.include, ref) and _has_rule(rs, "required_status_checks")
               for rs in decl.rulesets() if rs.target == "branch"), ref


@pytest.mark.parametrize("row", [pytest.param("accepted-after-the-fix", marks=rule("INTAKE-ACCESS-GOAL-BRANCH"),
                                              id="accepted-after-the-fix")])
def test_recorded_acceptance(row: str) -> None:
    # World create-ref-accepted-2026-11-22: the same call as the sitting's identity after the
    # apply. Read strictly. Joined to the rulesets: the created ref is a goal/** ref, and every
    # check-enforcing ruleset covering it exempts creation — the state create-goal-ref asserts.
    allure.dynamic.title(row)
    world = json.loads((WORLDS / "create-ref-accepted-2026-11-22.json").read_text(encoding="utf-8"))
    assert set(world) == {"provenance", "request", "response"}
    assert set(world["request"]) == {"method", "path", "fields"}
    assert set(world["request"]["fields"]) == {"ref", "sha"}
    assert set(world["response"]) == {"status", "headers", "body"}
    assert set(world["response"]["body"]) == {"ref", "node_id", "url", "object"}
    assert set(world["response"]["body"]["object"]) == {"sha", "type", "url"}
    req, resp = world["request"], world["response"]
    allure.attach(json.dumps(world, indent=2), name="world", attachment_type=allure.attachment_type.JSON)
    assert req["method"] == "POST" and req["path"].endswith("/git/refs")
    assert resp["status"] == 201
    assert resp["body"]["ref"] == req["fields"]["ref"]
    assert resp["body"]["object"]["sha"] == req["fields"]["sha"]
    assert resp["headers"]["x-github-request-id"]
    ref = req["fields"]["ref"]
    covering = [rs for rs in decl.rulesets()
                if rs.target == "branch" and decl.covers(rs.include, ref) and _has_rule(rs, "required_status_checks")]
    assert covering, ref


# ── INTAKE-ACCESS-ISSUES · -READ-PR · -CLONE ───────────────────────────────────────────────────


@pytest.mark.parametrize("row", [pytest.param("issue-acts", marks=rule("INTAKE-ACCESS-ISSUES"), id="issue-acts")])
def test_issue_acts(row: str) -> None:
    # Label, comment, close, file, edit a body, bind a sub-issue: all Issues API writes on the repo.
    allure.dynamic.title(row)
    ident = _identity()
    assert ident.level("issues") == decl.LEVELS["write"], ident.minted
    assert "homelab" in ident.repositories


@pytest.mark.parametrize("row", [pytest.param("pr-and-checks-read", marks=rule("INTAKE-ACCESS-READ-PR"),
                                              id="pr-and-checks-read")])
def test_pr_reads(row: str) -> None:
    # A PR's body, reviews and comments (pull_requests); its check runs (checks) and commit statuses
    # (statuses); gh's statusCheckRollup fragment also reaches checkSuite.workflowRun (actions) —
    # agents/coordinator/git-token.yaml's own comment on the actions grant.
    allure.dynamic.title(row)
    ident = _identity()
    for perm in ("pull_requests", "checks", "statuses", "actions"):
        allure.dynamic.parameter(perm, ident.minted.get(perm, "<none>"))
        assert ident.level(perm) >= decl.LEVELS["read"], perm


@pytest.mark.parametrize("row", [pytest.param("clone-homelab", marks=rule("INTAKE-ACCESS-CLONE"), id="clone-homelab")])
def test_clone_homelab(row: str) -> None:
    allure.dynamic.title(row)
    ident = _identity()
    assert ident.level("contents") >= decl.LEVELS["read"]
    assert "homelab" in ident.repositories


# ── INTAKE-ACCESS-GATEWAY ──────────────────────────────────────────────────────────────────────


@pytest.mark.parametrize("row", [pytest.param("admit-coordinator-platform", marks=rule("INTAKE-ACCESS-GATEWAY"),
                                              id="admit-coordinator-platform")])
def test_gateway_caller(row: str) -> None:
    # islands/intake/README.md §Stack islands: every sitting "is admitted as the platform's
    # (`--stack platform`, role `coordinator`)", as the workflow's ServiceAccount.
    allure.dynamic.title(row)
    wf = decl.sitting_workflow()
    md = wf["metadata"]
    caller = f"system:serviceaccount:{md['namespace']}:{wf['spec']['workflowSpec']['serviceAccountName']}"
    entry = decl.gateway_callers().get(caller)
    assert entry is not None, f"{caller} is not a gateway caller"
    assert "coordinator" in entry["roles"] and "platform" in entry["stacks"], entry


# ── INTAKE-ACCESS-DENIED ───────────────────────────────────────────────────────────────────────


@pytest.mark.parametrize("row", [pytest.param("on-no-bypass-list", marks=rule("INTAKE-ACCESS-DENIED"),
                                              id="on-no-bypass-list")])
def test_no_bypass(row: str) -> None:
    # No declared ruleset lists the sitting's App: every Integration actor resolves (literal or the
    # variable's default) to another id. OrganizationAdmin is a role an App token never holds.
    allure.dynamic.title(row)
    ident = _identity()
    for rs in decl.rulesets():
        for actor in rs.block.children("bypass_actors"):
            kind = actor.attrs["actor_type"].strip('"')
            value, how = decl.resolve_actor_id(actor.attrs["actor_id"])
            allure.dynamic.parameter(f"{rs.name}:{kind}:{value or '-'}", how)
            assert kind in ("OrganizationAdmin", "Integration"), f"{rs.name}: unknown actor type {kind}"
            if kind == "Integration":
                assert value != ident.app_id, f"{rs.name}: the sitting's App {ident.slug} bypasses ({how})"
                assert ident.slug not in how, f"{rs.name}: {how} names the sitting's App"


@pytest.mark.parametrize("row", [pytest.param("update-without-checks", marks=rule("INTAKE-ACCESS-DENIED"),
                                              id="update-without-checks")])
def test_updates_need_checks(row: str) -> None:
    # Updating master or a goal/** ref (a push, a merge) needs the required checks: a ruleset with
    # required_status_checks covers both refs, enforcement defaults to active, and (on-no-bypass-list)
    # the sitting is not waived. do_not_enforce_on_create exempts only the creation.
    allure.dynamic.title(row)
    enforcement, _ = decl.tf_variable_default("enforcement")
    assert enforcement == "active"
    for ref in (MASTER_REF, GOAL_REF):
        assert any(decl.covers(rs.include, ref) and _has_rule(rs, "required_status_checks")
                   for rs in decl.rulesets() if rs.target == "branch"), ref


@pytest.mark.parametrize("row", [pytest.param("merge-without-review", marks=rule("INTAKE-ACCESS-DENIED"),
                                              id="merge-without-review")])
def test_merges_need_review(row: str) -> None:
    # Changes to master and goal/** must come by pull request: a pull_request rule covers both refs.
    allure.dynamic.title(row)
    for ref in (MASTER_REF, GOAL_REF):
        assert any(decl.covers(rs.include, ref) and _has_rule(rs, "pull_request")
                   for rs in decl.rulesets() if rs.target == "branch"), ref


@pytest.mark.parametrize("row", [pytest.param("administer-repo", marks=rule("INTAKE-ACCESS-DENIED"),
                                              id="administer-repo")])
def test_no_administration(row: str) -> None:
    # Editing or deleting a ruleset (or a repo setting) needs `administration`; the token has none,
    # and the App declares it a decided non-grant (`absent:` — over-grant is drift too).
    allure.dynamic.title(row)
    ident = _identity()
    assert ident.level("administration") == 0, ident.minted
    assert "administration" in ident.absent, ident.absent


@pytest.mark.parametrize("row", [pytest.param("push-workflow-file", marks=rule("INTAKE-ACCESS-DENIED"),
                                              id="push-workflow-file")])
def test_no_workflows(row: str) -> None:
    # A push that adds or changes .github/workflows/** needs `workflows: write`; none, decided absent.
    allure.dynamic.title(row)
    ident = _identity()
    assert ident.level("workflows") == 0, ident.minted
    assert "workflows" in ident.absent, ident.absent


@pytest.mark.parametrize("row", [pytest.param("review-or-merge-pr", marks=rule("INTAKE-ACCESS-DENIED"),
                                              id="review-or-merge-pr")])
def test_no_pr_write(row: str) -> None:
    # Reviewing, merging, editing or commenting on a pull request through the Pulls API needs
    # `pull_requests: write`; the token reads only.
    allure.dynamic.title(row)
    ident = _identity()
    assert ident.level("pull_requests") == decl.LEVELS["read"], ident.minted


@pytest.mark.parametrize("row", [pytest.param("rerun-a-workflow", marks=rule("INTAKE-ACCESS-DENIED"),
                                              id="rerun-a-workflow")])
def test_no_actions_write(row: str) -> None:
    # Re-running or cancelling a workflow run needs `actions: write`; the token reads only.
    allure.dynamic.title(row)
    ident = _identity()
    assert ident.level("actions") == decl.LEVELS["read"], ident.minted


# ── INTAKE-ACCESS-OWN-APP ──────────────────────────────────────────────────────────────────────

# The least set the page's positive rows need, act by act (specs/access.md INTAKE-ACCESS-OWN-APP):
# contents write — create-goal-ref; issues write — issue-acts; pull_requests, checks, statuses, actions
# read — pr-and-checks-read; metadata read — every App.
NEEDS = {"metadata": "read", "contents": "write", "issues": "write",
         "pull_requests": "read", "checks": "read", "statuses": "read", "actions": "read"}


@pytest.mark.parametrize("row", [pytest.param("used-by-nothing-else", marks=rule("INTAKE-ACCESS-OWN-APP"),
                                              id="used-by-nothing-else")])
def test_own_app(row: str) -> None:
    # The App mints at exactly one site, and that site's Secret is read by the sitting's workflow alone.
    allure.dynamic.title(row)
    ident = _identity()
    sites = decl.mint_sites_of(ident.app_id)
    consumers = decl.secret_consumers(ident.secret)
    allure.dynamic.parameter("mint sites", ", ".join(sites))
    allure.dynamic.parameter("consumers", ", ".join(consumers))
    assert sites == ["agents/coordinator/intake-git.yaml"], sites
    assert consumers == ["agents/coordinator/island-intake-argo.yaml"], consumers


@pytest.mark.parametrize("row", [pytest.param("least-set", marks=rule("INTAKE-ACCESS-OWN-APP"), id="least-set")])
def test_least_set(row: str) -> None:
    # Declared == needed: a grant no row needs fails, and so does a need the App lacks. The mint
    # requests the same set (metadata is implicit in every token).
    allure.dynamic.title(row)
    ident = _identity()
    assert ident.declared == NEEDS, ident.declared
    assert {k: v for k, v in NEEDS.items() if k != "metadata"} == ident.minted, ident.minted
