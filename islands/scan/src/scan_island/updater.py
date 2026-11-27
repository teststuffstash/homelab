"""Keep one merge-ready PR per lane current (legs 1 and 2 of the updater; ADR-111, ADR-125).

Leg 1 (the main pick) updates the oldest merge-ready, armed, BEHIND PR of each (repo, base) lane,
hopping to the lane's next member when an update fails (homelab#2203); it also admits an armed, BEHIND PR that is
not merge-ready when its red is its base's (the inherited red, homelab#2588). Leg 2 (unstrand) updates an
armed, BEHIND, CHANGES_REQUESTED PR only when content landed after the reviewer's verdict.
Leg 1b (the Renovate hand-back sweep) runs over the PRs outside legs 1 and 2; leg 3 labels armed ∧ DIRTY PRs
`merge-conflict` over REST. Renovate authorship and currency live in `renovate.py`.

Every read is strict (goal #3490 pin 5, updater.schema.json): a snapshot entry lacking a field `pr` requires
holds the WHOLE pass (exit 4, nothing written); a probe answer lacking one holds that PR.
"""

import datetime as dt
import json
import os
import sys

from . import gh, renovate
from .renovate import COMMIT_PROBE, COMMIT_REVIEW_PROBE
from .strict import Nullable, lacking

LIST_FIELDS = "number,createdAt,mergeStateStatus,autoMergeRequest,reviewDecision,labels,headRefOid,latestReviews,baseRefName,reviews,author,headRefName"
UNREADABLE = 4  # the snapshot answered without a field the schema requires: nothing written

# The fields of one snapshot entry updater.schema.json requires (`/properties/pr`): every field the pass reads.
PR = {
    "number": int,
    "createdAt": str,
    "mergeStateStatus": str,
    "autoMergeRequest": Nullable(dict),
    "reviewDecision": str,
    "baseRefName": str,
    "labels": [{"name": str}],
    "headRefOid": str,
    "latestReviews": [{"author": Nullable({"login": str}), "state": str}],
    "reviews": [{"author": Nullable({"login": str}), "state": str, "submittedAt": str}],
    "author": Nullable({"login": str}),
}


# The fields updater.schema.json requires of the ci read and the base ci read: `/properties/ci_check_read`.
CI_CHECK_READ = {"check_runs": [{"name": str, "status": str, "conclusion": Nullable(str), "started_at": Nullable(str)}]}


def _login(review: dict) -> str | None:
    """The review's author login; None for a deleted account (`author` null) — no one's verdict."""
    return None if review["author"] is None else review["author"]["login"]


def _is_bot(review: dict, bot: str) -> bool:
    login = _login(review)
    return login is not None and login.removesuffix("[bot]") == bot


def _reviewer(review: dict) -> bool:
    login = _login(review)
    return login is not None and login.startswith("homelab-reviewer")


def _names(pr: dict) -> list[str]:
    return [label["name"] for label in pr["labels"]]


def _behind(pr: dict) -> bool:
    return pr["autoMergeRequest"] is not None and pr["mergeStateStatus"] == "BEHIND"


def leg1_cand(pr: dict) -> bool:
    if not _behind(pr) or pr["reviewDecision"] == "CHANGES_REQUESTED":
        return False
    if pr["reviewDecision"] != "REVIEW_REQUIRED":
        return True
    return not any(_reviewer(r) and r["state"] == "APPROVED" for r in pr["latestReviews"])


def leg2_domain(pr: dict) -> bool:
    return _behind(pr) and pr["reviewDecision"] == "CHANGES_REQUESTED"


def breakered(pr: dict) -> bool:
    names = _names(pr)
    return "agent/error" in names or "agent/arbitrate" in names


def _probe(slug: str, n: int, fields: str) -> dict | None:
    """The per-candidate commit probe: the `gh pr view` call, then the pull-commits read; None when either call failed,
    its body is not JSON, or the answer lacks a field the schema requires of it (`commit_probe` / `commit_review_probe` /
    `pull_commits_read`)."""
    shape = COMMIT_REVIEW_PROBE if fields == "commits,reviews" else COMMIT_PROBE
    return renovate.commit_probe(slug, n, fields, shape)


def _newest_content(commits: list) -> str:
    return max((c["committedDate"] for c in commits if not c["merge"]), default="")


def _merge_ready(slug: str, pr: dict, bot: str, ready_only: bool) -> bool | None:
    """True when merge-ready, False when the admission gives the PR up, None when its commit probe holds it."""
    n = pr["number"]
    decision = pr["reviewDecision"]
    cj = None
    if renovate.author(pr):
        cj = renovate.probe(slug, n, pr["headRefOid"])
        if cj is None:
            print(f"updater[{slug}]: #{n} commit probe unreadable — HOLDING, not updating (rule #6; the */15 cron retries)")
            return None
        # the merge-ready exception (ADR-153): untouched + green falls through to the admission below
        if renovate.untouched(cj) and not renovate.green(cj):
            if renovate.merged_into(cj):
                renovate.handback(slug, n, f"updater[{slug}]:")
            else:
                print(f"updater[{slug}]: #{n} Renovate-authored, untouched and not green — Renovate's to rebase (rebaseWhen behind-base-branch, ADR-153); skipping")
            return False
    if not ready_only or decision == "APPROVED":
        return True
    if decision == "REVIEW_REQUIRED":  # the codeowner park (#1649): decided by reviewDecision, probe-free
        return False
    if decision == "" and "automerge" in _names(pr):
        return True
    approved = [r["submittedAt"] for r in pr["reviews"] if _is_bot(r, bot) and r["state"] == "APPROVED"]
    if not approved:
        return False
    approved_at = max(approved)
    probe = cj if cj is not None else _probe(slug, n, "commits")
    if probe is None:
        print(f"updater[{slug}]: #{n} commit probe unreadable — HOLDING, not updating (rule #6; the */15 cron retries)")
        return None
    return approved_at > _newest_content(probe["commits"])


def _update(slug: str, n: int, oid: str | None) -> bool:
    args = ["api", "-X", "PUT", f"repos/{slug}/pulls/{n}/update-branch"]
    if oid:
        args += ["-f", f"expected_head_sha={oid}"]
    result = gh.run(*args)
    if result.returncode:
        sys.stderr.write(result.stderr)  # gh's own error, as the shell leaves it on stderr
        return False
    return True


def _ci_run(read: dict) -> dict | None:
    """The newest `ci` check run of a ci read, by `started_at`; a run with no `started_at` has not started: it is the newest."""
    runs = [r for r in read["check_runs"] if r["name"] == "ci"]
    return max(runs, key=lambda r: (r["started_at"] is None, r["started_at"] or ""), default=None)


def _started(run: dict) -> dt.datetime | None:
    return None if run["started_at"] is None else dt.datetime.fromisoformat(run["started_at"])


def _ci_read(slug: str, ref: str) -> dict | None:
    return renovate.read("api", f"repos/{slug}/commits/{ref}/check-runs?per_page=100", shape=CI_CHECK_READ)


def inherited_red(slug: str, pr: dict, bases: dict[str, dict | None]) -> bool:
    """The PR's red is its base's: its newest `ci` run is a completed failure that started before the newest `ci` run at
    its base's head, a completed success. The base's read is made once per base per pass (`bases`); an unreadable
    read of either holds the PR with a line."""
    n = pr["number"]
    mine = _ci_read(slug, pr["headRefOid"])
    if mine is None:
        print(f"updater[{slug}]: #{n} ci check read unreadable — HOLDING, not updating (rule #6; the */15 cron retries)")
        return False
    head = _ci_run(mine)
    if head is None or head["status"] != "completed" or head["conclusion"] != "failure":
        return False
    base_name = pr["baseRefName"]
    if base_name not in bases:
        bases[base_name] = _ci_read(slug, f"heads/{base_name}")
    theirs = bases[base_name]
    if theirs is None:
        print(f"updater[{slug}]: #{n} base check read unreadable — HOLDING, not updating (rule #6; the */15 cron retries)")
        return False
    base = _ci_run(theirs)
    if base is None or base["status"] != "completed" or base["conclusion"] != "success":
        return False
    before, after = _started(head), _started(base)
    if before is None or after is None or not before < after:
        return False
    print(f"updater[{slug}]: #{n} ci failed before {base_name}'s head went green — inherited red, admitted without merge-ready")
    return True


def leg1(slug: str, prs: list[dict], bot: str, ready_only: bool) -> None:
    verdicts = {pr["number"]: _merge_ready(slug, pr, bot, ready_only) for pr in prs if leg1_cand(pr)}
    ready = [pr for pr in prs if verdicts.get(pr["number"])]
    bases: dict[str, dict | None] = {}
    # the inherited-red leg is asked where the admission gives a PR up (never where its commit probe holds it)
    asked = [pr for pr in prs if verdicts.get(pr["number"], False) is False and _behind(pr) and pr["reviewDecision"] != "CHANGES_REQUESTED"
             and not breakered(pr) and not renovate.author(pr)]
    if ready_only:  # the pre-#1452 pick is armed ∧ BEHIND alone: nothing is left over to ask
        ready += [pr for pr in sorted(asked, key=lambda p: p["createdAt"]) if inherited_red(slug, pr, bases)]
    lanes: dict[str, list[dict]] = {}
    for pr in prs:
        if pr in ready:
            lanes.setdefault(pr["baseRefName"], []).append(pr)
    if not lanes:
        print(f"updater[{slug}]: no armed+BEHIND PR to update")
        return
    for _, members in sorted(lanes.items()):  # jq group_by orders lanes by base name
        first = True
        for pr in sorted(members, key=lambda p: p["createdAt"]):
            n = pr["number"]
            if first:
                print(f"updater[{slug}]: updating #{n} (oldest armed+BEHIND, FIFO)")
            else:
                print(f"updater[{slug}]: updating #{n} (lane hop — the lane's older member did not clear)")
            if _update(slug, n, pr["headRefOid"]):
                break  # one update LANDS per lane per pass
            print(f"updater[{slug}]: update of #{n} failed (422) — skipping; next pass retries")
            first = False


def sweep(slug: str, prs: list[dict]) -> None:
    """Leg 1b: hand back an armed, unbreakered Renovate PR outside legs 1 and 2 (a concluded red, or CHANGES_REQUESTED) the updater merged into."""
    for pr in prs:
        if pr["autoMergeRequest"] is None or leg1_cand(pr) or leg2_domain(pr) or breakered(pr) or not renovate.author(pr):
            continue
        n = pr["number"]
        sj = renovate.probe(slug, n, pr["headRefOid"])
        if sj is None:
            print(f"handback[{slug}]: #{n} commit probe unreadable — HOLDING (rule #6; the */15 cron retries)")
            continue
        if not (renovate.untouched(sj) and renovate.merged_into(sj)):
            continue
        if renovate.red(sj) or pr["reviewDecision"] == "CHANGES_REQUESTED":
            renovate.handback(slug, n, f"handback[{slug}]:")


def _verdict_ok(probe: dict | None) -> str:
    """"yes" when the newest non-merge commit post-dates the newest reviewer verdict, "no" when not, "" when unreadable."""
    if probe is None:
        return ""
    commits = [c["committedDate"] for c in probe["commits"] if not c["merge"]]
    verdicts = [r["submittedAt"] for r in probe["reviews"] if _reviewer(r) and r["state"] in ("APPROVED", "CHANGES_REQUESTED")]
    return "yes" if commits and verdicts and max(commits) > max(verdicts) else "no"


def leg2(slug: str, prs: list[dict]) -> None:
    for pr in prs:
        if not leg2_domain(pr) or breakered(pr):
            continue
        n = pr["number"]
        pj = _probe(slug, n, "commits,reviews")
        # a CHANGES_REQUESTED PR is never merge-ready: an untouched Renovate PR here is always Renovate's to rebase
        if pj is not None and renovate.author(pr) and renovate.untouched(pj):
            if renovate.merged_into(pj):
                renovate.handback(slug, n, "unstrand:")
            else:
                print(f"unstrand: #{n} Renovate-authored and untouched — Renovate rebases it itself (rebaseWhen behind-base-branch, ADR-153); skipping")
            continue
        verdict = _verdict_ok(pj)
        if verdict == "yes":
            print(f"unstrand: updating CR-and-behind PR #{n} (new content since verdict)")
            if not _update(slug, n, pr["headRefOid"]):
                print(f"unstrand: update of #{n} failed (422) — skipping; next pass retries")
        elif verdict == "no":
            print(f"unstrand: #{n} CR-and-behind but NO new content since the verdict — nothing to re-review, not updating (2026-08-17 narrowing)")
        else:
            print(f"unstrand: #{n} commit/review probe unreadable — HOLDING, not updating (rule #6; the */15 cron retries)")


def _label_token() -> str | None:
    return os.environ.get("UPDATER_LABEL_TOKEN") or os.environ.get("GH_TOKEN") or None


def _label_conflict(slug: str, n: int) -> None:
    """Create the label idempotently, then add it — REST both, never `gh pr edit` (GraphQL; homelab#2476)."""
    tok = _label_token()
    created = gh.run("api", "-X", "POST", f"repos/{slug}/labels", "-f", "name=merge-conflict", "-f", "color=e11d21",
                     "-f", "description=PR branch conflicts with master — updater can't auto-resolve", token=tok)
    create_err = created.stderr.rstrip("\n") if created.returncode else ""
    added = gh.run("api", "-X", "POST", f"repos/{slug}/issues/{n}/labels", "-f", "labels[]=merge-conflict", token=tok)
    if added.returncode:
        err = added.stderr.rstrip("\n") or "gh gave no output"
        print(f"updater[{slug}]: could not label #{n} merge-conflict — {err}" + (f" (label create: {create_err})" if create_err else "") + " — the */15 pass retries")


def leg3(slug: str, prs: list[dict]) -> None:
    """Armed ∧ DIRTY gains `merge-conflict`; anything else carrying it loses it (best-effort)."""
    for pr in prs:
        n = pr["number"]
        has = "merge-conflict" in _names(pr)
        if pr["autoMergeRequest"] is not None and pr["mergeStateStatus"] == "DIRTY":
            if not has:
                _label_conflict(slug, n)
        elif has:
            gh.run("api", "-X", "DELETE", f"repos/{slug}/issues/{n}/labels/merge-conflict", token=_label_token())


def _unreadable(slug: str, why: str) -> int:
    print(f"updater[{slug}]: snapshot unreadable — gh pr list answered {why} — HOLDING the whole pass, nothing written (rule #6)")
    return UNREADABLE


def main(slug: str) -> int:
    bot = os.environ.get("REVIEWER_LOGIN", "homelab-reviewer")
    ready_only = os.environ.get("UPDATER_MERGE_READY_ONLY", "1") != "0"
    listing = gh.run("pr", "list", "--repo", slug, "--state", "open", "--limit", "100", "--json", LIST_FIELDS)
    if listing.returncode:
        sys.stderr.write(listing.stderr)
        return listing.returncode
    try:
        prs = json.loads(listing.stdout)
    except ValueError:
        return _unreadable(slug, "no parseable JSON")
    missing = lacking(prs, [PR])
    if missing:
        return _unreadable(slug, missing)
    leg1(slug, prs, bot, ready_only)
    sweep(slug, prs)
    leg2(slug, prs)
    leg3(slug, prs)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: python -m scan_island.updater <owner/repo>")
    sys.exit(main(sys.argv[1]))
