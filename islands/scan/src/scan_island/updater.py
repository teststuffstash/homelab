"""Keep one merge-ready PR per lane current (legs 1 and 2 of the updater; ADR-111, ADR-125).

Leg 1 (the main pick) updates the oldest merge-ready, armed, BEHIND PR of each (repo, base) lane,
hopping to the lane's next member when an update fails (homelab#2203). Leg 2 (unstrand) updates an
armed, BEHIND, CHANGES_REQUESTED PR only when content landed after the reviewer's verdict.
Legs 3 (merge-conflict) and the Renovate predicates are not built here.
"""

import json
import os
import sys

from . import gh

LIST_FIELDS = "number,createdAt,mergeStateStatus,autoMergeRequest,reviewDecision,labels,headRefOid,latestReviews,baseRefName,reviews,author,headRefName"
MERGE_PREFIX = "Merge branch "


def _login(review: dict) -> str:
    return ((review.get("author") or {}).get("login")) or ""


def _names(pr: dict) -> list[str]:
    return [label.get("name") for label in pr.get("labels") or []]


def _behind(pr: dict) -> bool:
    return pr.get("autoMergeRequest") is not None and pr.get("mergeStateStatus") == "BEHIND"


def leg1_cand(pr: dict) -> bool:
    if not _behind(pr) or pr.get("reviewDecision") == "CHANGES_REQUESTED":
        return False
    if pr.get("reviewDecision") != "REVIEW_REQUIRED":
        return True
    return not any(_login(r).startswith("homelab-reviewer") and r.get("state") == "APPROVED" for r in pr.get("latestReviews") or [])


def leg2_domain(pr: dict) -> bool:
    return _behind(pr) and pr.get("reviewDecision") == "CHANGES_REQUESTED"


def breakered(pr: dict) -> bool:
    names = _names(pr)
    return "agent/error" in names or "agent/arbitrate" in names


def _probe(slug: str, n: int, fields: str) -> dict | None:
    """The per-candidate `gh pr view` probe; None when the call failed or the body is not the JSON asked for."""
    result = gh.run("pr", "view", str(n), "--repo", slug, "--json", fields)
    if result.returncode:
        return None
    try:
        data = json.loads(result.stdout)
    except ValueError:
        return None
    if not isinstance(data, dict) or not isinstance(data.get("commits"), list):
        return None
    return data


def _newest_content(commits: list) -> str:
    return max((c.get("committedDate") or "" for c in commits if not (c.get("messageHeadline") or "").startswith(MERGE_PREFIX)), default="")


def _merge_ready(slug: str, pr: dict, bot: str, ready_only: bool) -> bool:
    n = pr["number"]
    decision = pr.get("reviewDecision")
    if not ready_only or decision == "APPROVED":
        return True
    if decision == "REVIEW_REQUIRED":  # the codeowner park (#1649): decided by reviewDecision, probe-free
        return False
    if decision == "" and "automerge" in _names(pr):
        return True
    approved = [r.get("submittedAt") or "" for r in pr.get("reviews") or [] if _login(r).removesuffix("[bot]") == bot and r.get("state") == "APPROVED"]
    if not approved:
        return False
    approved_at = max(approved)
    probe = _probe(slug, n, "commits")
    if probe is None:
        print(f"updater[{slug}]: #{n} commit probe unreadable — HOLDING, not updating (rule #6; the */15 cron retries)")
        return False
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


def leg1(slug: str, prs: list[dict], bot: str, ready_only: bool) -> None:
    ready = [pr for pr in prs if leg1_cand(pr) and _merge_ready(slug, pr, bot, ready_only)]
    lanes: dict[str, list[dict]] = {}
    for pr in prs:
        if pr in ready:
            lanes.setdefault(pr.get("baseRefName") or "", []).append(pr)
    if not lanes:
        print(f"updater[{slug}]: no armed+BEHIND PR to update")
        return
    for _, members in sorted(lanes.items()):  # jq group_by orders lanes by base name
        first = True
        for pr in sorted(members, key=lambda p: p.get("createdAt") or ""):
            n = pr["number"]
            if first:
                print(f"updater[{slug}]: updating #{n} (oldest armed+BEHIND, FIFO)")
            else:
                print(f"updater[{slug}]: updating #{n} (lane hop — the lane's older member did not clear)")
            if _update(slug, n, pr.get("headRefOid")):
                break  # one update LANDS per lane per pass
            print(f"updater[{slug}]: update of #{n} failed (422) — skipping; next pass retries")
            first = False


def _verdict_ok(probe: dict | None) -> str:
    """"yes" when the newest non-merge commit post-dates the newest reviewer verdict, "no" when not, "" when unreadable."""
    if probe is None or not isinstance(probe.get("reviews"), list):
        return ""
    commits = [c.get("committedDate") for c in probe["commits"] if not (c.get("messageHeadline") or "").startswith(MERGE_PREFIX)]
    verdicts = [r.get("submittedAt") for r in probe["reviews"] if _login(r).startswith("homelab-reviewer") and r.get("state") in ("APPROVED", "CHANGES_REQUESTED")]
    commits, verdicts = [c for c in commits if c], [v for v in verdicts if v]
    return "yes" if commits and verdicts and max(commits) > max(verdicts) else "no"


def leg2(slug: str, prs: list[dict]) -> None:
    for pr in prs:
        if not leg2_domain(pr) or breakered(pr):
            continue
        n = pr["number"]
        verdict = _verdict_ok(_probe(slug, n, "commits,reviews"))
        if verdict == "yes":
            print(f"unstrand: updating CR-and-behind PR #{n} (new content since verdict)")
            if not _update(slug, n, pr.get("headRefOid")):
                print(f"unstrand: update of #{n} failed (422) — skipping; next pass retries")
        elif verdict == "no":
            print(f"unstrand: #{n} CR-and-behind but NO new content since the verdict — nothing to re-review, not updating (2026-08-17 narrowing)")
        else:
            print(f"unstrand: #{n} commit/review probe unreadable — HOLDING, not updating (rule #6; the */15 cron retries)")


def main(slug: str) -> int:
    bot = os.environ.get("REVIEWER_LOGIN", "homelab-reviewer")
    ready_only = os.environ.get("UPDATER_MERGE_READY_ONLY", "1") != "0"
    listing = gh.run("pr", "list", "--repo", slug, "--state", "open", "--limit", "100", "--json", LIST_FIELDS)
    if listing.returncode:
        sys.stderr.write(listing.stderr)
        return listing.returncode
    prs = json.loads(listing.stdout)
    leg1(slug, prs, bot, ready_only)
    leg2(slug, prs)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: python -m scan_island.updater <owner/repo>")
    sys.exit(main(sys.argv[1]))
