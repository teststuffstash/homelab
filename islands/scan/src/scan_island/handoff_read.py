"""Read the pull-request facts consumed by the major handoff."""

import json
from dataclasses import dataclass

from . import gh


@dataclass(frozen=True)
class Review:
    login: str | None
    state: str
    submitted_at: str
    body: str


@dataclass(frozen=True)
class Commit:
    headline: str
    committed_at: str


@dataclass(frozen=True)
class HandoffPR:
    state: str
    labels: tuple[str, ...]
    reviews: tuple[Review, ...]
    commits: tuple[Commit, ...]


class UnreadablePR(ValueError):
    pass


def field(row: object, key: str) -> object:
    if not isinstance(row, dict) or key not in row:
        raise UnreadablePR(f"missing field {key}")
    return row[key]


def string(row: object, key: str) -> str:
    value = field(row, key)
    if not isinstance(value, str):
        raise UnreadablePR(f"expected a string for {key}")
    return value


def items(row: object, key: str) -> list[object]:
    value = field(row, key)
    if not isinstance(value, list):
        raise UnreadablePR(f"expected a list for {key}")
    return value


def review(row: object) -> Review:
    author = field(row, "author")
    login = None if author is None else string(author, "login")
    return Review(login, string(row, "state"), string(row, "submittedAt"), string(row, "body"))


def read_handoff_pr(slug: str, pr: str) -> HandoffPR:
    result = gh.run("pr", "view", pr, "--repo", slug, "--json", "state,labels,reviews,commits")
    if result.returncode:
        detail = result.stderr[-200:].replace("\n", " ").rstrip() or "no stderr"
        raise UnreadablePR(f"failed: {detail}")
    try:
        row: object = json.loads(result.stdout)
    except ValueError as exc:
        raise UnreadablePR("returned no parseable PR object") from exc
    return HandoffPR(
        string(row, "state"),
        tuple(string(label, "name") for label in items(row, "labels")),
        tuple(review(item) for item in items(row, "reviews")),
        tuple(Commit(string(item, "messageHeadline"), string(item, "committedDate")) for item in items(row, "commits")),
    )
