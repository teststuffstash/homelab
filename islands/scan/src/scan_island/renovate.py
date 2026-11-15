"""Whose currency is a Renovate PR — the island's one Renovate predicate module (ADR-153, homelab#2007).

Authorship is read through ONE login normalization: `app/homelab-renovate-1234` (the `gh pr list` shape),
`homelab-renovate-1234[bot]` (REST / `pr view` commit authors) and the bare login all read as Renovate.
Checks are probed over REST (`commits/<sha>/check-runs` + `/status`); an unreadable leg holds.
"""

import json

from . import gh

MERGE_PREFIX = "Merge branch "
CHECK_RUNS_JQ = '[.check_runs[]? | {name, conclusion: ((.conclusion // .status // "") | ascii_upcase)}]'
STATUS_JQ = '[.statuses[]? | {context, state: ((.state // "") | ascii_upcase)}]'
OK = {"SUCCESS", "NEUTRAL", "SKIPPED"}
IN_FLIGHT = {"QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED", "PENDING", ""}
BOX_OFF = "- [ ] <!-- rebase-check -->"
BOX_ON = "- [x] <!-- rebase-check -->"


def is_renovate_login(login: str | None) -> bool:
    login = login or ""
    login = login.removeprefix("app/").removesuffix("[bot]")
    return login.startswith("homelab-renovate")


def author(pr: dict) -> bool:
    return is_renovate_login((pr.get("author") or {}).get("login"))


def _is_merge(commit: dict) -> bool:
    return (commit.get("messageHeadline") or "").startswith(MERGE_PREFIX)


def _array(slug: str, *args: str) -> list | None:
    result = gh.run(*args)
    if result.returncode:
        return None
    try:
        data = json.loads(result.stdout)
    except ValueError:
        return None
    return data if isinstance(data, list) else None


def probe(slug: str, n: int, oid: str) -> dict | None:
    """`{commits, statusCheckRollup}`; None when ANY leg is unreadable (the caller holds — a half-read is never "not green")."""
    result = gh.run("pr", "view", str(n), "--repo", slug, "--json", "commits")
    if result.returncode:
        return None
    try:
        commits = json.loads(result.stdout)
    except ValueError:
        return None
    if not isinstance(commits, dict) or not isinstance(commits.get("commits"), list):
        return None
    if not oid:
        return None
    runs = _array(slug, "api", f"repos/{slug}/commits/{oid}/check-runs?per_page=100", "--jq", CHECK_RUNS_JQ)
    if runs is None:
        return None
    statuses = _array(slug, "api", f"repos/{slug}/commits/{oid}/status", "--jq", STATUS_JQ)
    if statuses is None:
        return None
    return {"commits": commits["commits"], "statusCheckRollup": runs + statuses}


def _entries(p: dict) -> list[tuple[str, str]]:
    out = []
    for e in p.get("statusCheckRollup") or []:
        conclusion = e.get("conclusion")
        if conclusion is None or conclusion is False:
            conclusion = e.get("state")
        out.append((e.get("name") or e.get("context") or "", "" if conclusion in (None, False) else conclusion))
    return out


def green(p: dict) -> bool:
    """Every check concluded clean; none reported is not green; a CANCELLED a same-named sibling outlives is dropped (#2754)."""
    groups: dict[str, list[str]] = {}
    for k, c in _entries(p):
        groups.setdefault(k, []).append(c)
    conclusions = []
    for cs in groups.values():
        conclusions += [c for c in cs if c != "CANCELLED"] if any(c != "CANCELLED" for c in cs) else cs
    return len(conclusions) > 0 and all(c in OK for c in conclusions)


def red(p: dict) -> bool:
    """A CONCLUDED red: something reported, nothing in flight, not green."""
    cs = [c for _, c in _entries(p)]
    return len(cs) > 0 and not any(c in IN_FLIGHT for c in cs) and not green(p)


def untouched(p: dict) -> bool:
    """No non-merge commit authored by anyone but Renovate."""
    return all(is_renovate_login(a.get("login")) for c in p.get("commits") or [] if not _is_merge(c) for a in c.get("authors") or [])


def merged_into(p: dict) -> bool:
    """A non-Renovate MERGE commit is on the branch (only an update-branch call writes those)."""
    return any(not is_renovate_login(a.get("login")) for c in p.get("commits") or [] if _is_merge(c) for a in c.get("authors") or [])


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
