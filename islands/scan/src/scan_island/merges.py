"""Which commit of a pull request is a merge commit (glossary.md § merge commit): one with two or more parents.

A commit's message decides nothing. The parents come from the pull-commits read
(`gh api repos/<slug>/pulls/<n>/commits?per_page=100`, schema `pull_commits_read`), joined to the commits of
the PR view by `sha` = `oid`. A view commit with no element in that answer leaves the commits unreadable.
"""

# The fields updater.schema.json / major-handoff.schema.json require of the read (`/properties/pull_commits_read`),
# as a `strict.lacking` shape.
PULL_COMMITS_READ = [{"sha": str, "parents": [{"sha": str}]}]


def pull_commits_path(slug: str, n: int | str) -> str:
    return f"repos/{slug}/pulls/{n}/commits?per_page=100"


def is_merge(parents: list) -> bool:
    """The one predicate: two or more parents."""
    return len(parents) >= 2


def flag(commits: list[dict], listed: list[dict]) -> list[dict] | None:
    """The view's commits, each with `merge` set from its parents in `listed`; None when a commit has no element there."""
    parents = {e["sha"]: e["parents"] for e in listed}
    if any(c["oid"] not in parents for c in commits):
        return None
    return [{**c, "merge": is_merge(parents[c["oid"]])} for c in commits]
