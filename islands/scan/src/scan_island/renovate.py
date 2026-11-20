"""Whose currency is a Renovate PR — the island's one Renovate predicate module (ADR-153, homelab#2007).

Authorship is read through ONE login normalization: `app/homelab-renovate-1234` (the `gh pr list` shape),
`homelab-renovate-1234[bot]` (REST / `pr view` commit authors) and the bare login all read as Renovate.
Checks are probed over REST (`commits/<sha>/check-runs` + `/status`), each answer read raw and strictly
against updater.schema.json (`check_runs_read`, `status_read`); an unreadable leg holds.
"""

import json

from . import gh
from .strict import Nullable, lacking

MERGE_PREFIX = "Merge branch "
OK = {"SUCCESS", "NEUTRAL", "SKIPPED"}
IN_FLIGHT = {"QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED", "PENDING", ""}
BOX_OFF = "- [ ] <!-- rebase-check -->"
BOX_ON = "- [x] <!-- rebase-check -->"

# The fields updater.schema.json requires of each read (SCAN-UPDATER-PICK, -UNSTRAND, -RENOVATE): `/properties/<name>`.
COMMIT_PROBE = {"commits": [{"messageHeadline": str, "committedDate": str, "authors": [{"login": str}]}]}
COMMIT_REVIEW_PROBE = {
    **COMMIT_PROBE,
    "reviews": [{"author": Nullable({"login": str}), "state": str, "submittedAt": str}],
}
CHECK_RUNS_READ = {"check_runs": [{"name": str, "status": str, "conclusion": Nullable(str)}]}
STATUS_READ = {"statuses": [{"context": str, "state": str}]}


def is_renovate_login(login: str | None) -> bool:
    login = login or ""
    login = login.removeprefix("app/").removesuffix("[bot]")
    return login.startswith("homelab-renovate")


def author(pr: dict) -> bool:
    """The PR's author is Renovate; a null author (a deleted account) is not."""
    return pr["author"] is not None and is_renovate_login(pr["author"]["login"])


def _is_merge(commit: dict) -> bool:
    return commit["messageHeadline"].startswith(MERGE_PREFIX)


def read(*args: str, shape: object) -> dict | None:
    """One `gh` read, raw: the parsed answer, or None when the call failed, the body is not JSON, or the answer
    lacks a field `shape` requires (pin 5 — never a default)."""
    result = gh.run(*args)
    if result.returncode:
        return None
    try:
        data = json.loads(result.stdout)
    except ValueError:
        return None
    return None if lacking(data, shape) else data


def probe(slug: str, n: int, oid: str) -> dict | None:
    """`{commits, rollup}`; None when ANY leg is unreadable (the caller holds — a half-read is never "not green").
    `rollup` is one (check name, conclusion) per check run (its conclusion, or its status while it has none)
    and per commit status (its state), upper-cased."""
    commits = read("pr", "view", str(n), "--repo", slug, "--json", "commits", shape=COMMIT_PROBE)
    if commits is None:
        return None
    runs = read("api", f"repos/{slug}/commits/{oid}/check-runs?per_page=100", shape=CHECK_RUNS_READ)
    if runs is None:
        return None
    statuses = read("api", f"repos/{slug}/commits/{oid}/status", shape=STATUS_READ)
    if statuses is None:
        return None
    rollup = [(r["name"], (r["conclusion"] if r["conclusion"] is not None else r["status"]).upper()) for r in runs["check_runs"]]
    rollup += [(s["context"], s["state"].upper()) for s in statuses["statuses"]]
    return {"commits": commits["commits"], "rollup": rollup}


def green(p: dict) -> bool:
    """Every check concluded clean; none reported is not green; a CANCELLED a same-named sibling outlives is dropped (#2754)."""
    groups: dict[str, list[str]] = {}
    for k, c in p["rollup"]:
        groups.setdefault(k, []).append(c)
    conclusions = []
    for cs in groups.values():
        conclusions += [c for c in cs if c != "CANCELLED"] if any(c != "CANCELLED" for c in cs) else cs
    return len(conclusions) > 0 and all(c in OK for c in conclusions)


def red(p: dict) -> bool:
    """A CONCLUDED red: something reported, nothing in flight, not green."""
    cs = [c for _, c in p["rollup"]]
    return len(cs) > 0 and not any(c in IN_FLIGHT for c in cs) and not green(p)


def untouched(p: dict) -> bool:
    """No non-merge commit authored by anyone but Renovate."""
    return all(is_renovate_login(a["login"]) for c in p["commits"] if not _is_merge(c) for a in c["authors"])


def merged_into(p: dict) -> bool:
    """A non-Renovate MERGE commit is on the branch (only an update-branch call writes those)."""
    return any(not is_renovate_login(a["login"]) for c in p["commits"] if _is_merge(c) for a in c["authors"])


def handback(slug: str, n: int, prefix: str) -> None:
    """Tick Renovate's rebase/retry box from a FRESH REST body read; a hold or refusal is a line, never fatal."""
    head = f"{prefix} #{n} Renovate-authored, merged into, not merge-ready"
    result = gh.run("api", f"repos/{slug}/pulls/{n}", "--jq", '.body // ""')
    if result.returncode:
        print(f"{head} — body unreadable, HOLDING the hand-back (rule #6; the next pass retries)")
        return
    body = result.stdout.rstrip("\n")
    if BOX_ON in body:
        print(f"{head} — rebase already requested (box ticked); Renovate's next run takes it back")
        return
    if BOX_OFF not in body:
        print(f"{head} — no rebase checkbox in the body; human check (close + delete the branch, docs/renovate.md)")
        return
    new = "\n".join(line.replace(BOX_OFF, BOX_ON, 1) for line in body.split("\n"))
    if gh.run("api", "-X", "PATCH", f"repos/{slug}/pulls/{n}", "-f", f"body={new}").returncode:
        print(f"{head} — could not tick the rebase box; the next pass retries")
    else:
        print(f"{head} — handed back to Renovate (rebase box ticked; its next run rebuilds the branch)")
