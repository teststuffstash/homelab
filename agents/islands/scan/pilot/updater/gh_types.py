"""Typed projections of the `gh` JSON the updater reads — our side of the boundary.

Exactly the fields `agents/update-pr-branch.sh` (+ `agents/renovate-currency.sh`) ask for:

  gh pr list --json number,createdAt,mergeStateStatus,autoMergeRequest,reviewDecision,labels,
                    headRefOid,latestReviews,baseRefName,reviews,author,headRefName
  gh pr view N --json commits            (leg 1 probe, renovate_probe)
  gh pr view N --json commits,reviews    (leg 2)
  gh api repos/R/commits/SHA/check-runs --jq '[… {name, conclusion}]'   (renovate_probe)
  gh api repos/R/commits/SHA/status     --jq '[… {context, state}]'     (renovate_probe)

Rules: unknown wire keys are ignored; a REQUIRED key that is missing raises `WireError`; a key of
the wrong JSON type raises `WireError`. "Optional" below means absent == null — jq's own reading of
a missing key, kept because the replay worlds record a sparser wire than gh emits (the base world's
PRs carry 7 of the 12 requested keys). Stdlib only.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any


class WireError(ValueError):
    """A gh payload that is not the shape we asked for (missing required key / wrong type)."""

    def __init__(self, where: str, key: str, reason: str):
        super().__init__(f"{where}: {key!r} {reason}")
        self.where, self.key, self.reason = where, key, reason


_MISSING = object()


def _get(d: Any, where: str, key: str, typ: type | tuple[type, ...], *, required: bool) -> Any:
    if not isinstance(d, dict):
        raise WireError(where, key, f"parent is {type(d).__name__}, not an object")
    v = d.get(key, _MISSING)
    if v is _MISSING:
        if required:
            raise WireError(where, key, "missing (required)")
        return None
    if v is None:
        if required:
            raise WireError(where, key, "is null (required)")
        return None
    # bool is an int subclass in Python; JSON true is never a PR number
    if isinstance(v, bool) and typ in (int, (int,)):
        raise WireError(where, key, "is a boolean, want int")
    if not isinstance(v, typ):
        raise WireError(where, key, f"is {type(v).__name__}, want {typ}")
    return v


def _str(d: Any, where: str, key: str, *, required: bool = False) -> str | None:
    return _get(d, where, key, str, required=required)


def _list(d: Any, where: str, key: str, *, required: bool = False) -> list | None:
    return _get(d, where, key, list, required=required)


@dataclass(frozen=True, slots=True)
class Actor:
    """`author` on a PR / a review: `{login}` (gh adds id/name/is_bot — ignored)."""

    login: str | None

    @classmethod
    def from_wire(cls, d: dict) -> Actor:
        return cls(login=_str(d, "author", "login"))


@dataclass(frozen=True, slots=True)
class Label:
    name: str | None

    @classmethod
    def from_wire(cls, d: dict) -> Label:
        return cls(name=_str(d, "label", "name"))


@dataclass(frozen=True, slots=True)
class Review:
    """An element of `latestReviews[]` / `reviews[]`."""

    author: Actor | None
    state: str | None
    submitted_at: str | None

    @classmethod
    def from_wire(cls, d: dict) -> Review:
        a = _get(d, "review", "author", dict, required=False)
        return cls(author=None if a is None else Actor.from_wire(a),
                   state=_str(d, "review", "state"),
                   submitted_at=_str(d, "review", "submittedAt"))

    @property
    def login(self) -> str | None:
        return None if self.author is None else self.author.login


@dataclass(frozen=True, slots=True)
class AutoMergeRequest:
    """Only its PRESENCE is read (armed); `enabledAt` kept for the reader."""

    enabled_at: str | None

    @classmethod
    def from_wire(cls, d: dict) -> AutoMergeRequest:
        return cls(enabled_at=_str(d, "autoMergeRequest", "enabledAt"))


def _reviews(d: dict, where: str, key: str) -> tuple[Review, ...]:
    raw = _list(d, where, key)
    return tuple(Review.from_wire(r) for r in (raw or []))


@dataclass(frozen=True, slots=True)
class PullRequest:
    """One element of the `gh pr list --json …` snapshot.

    REQUIRED: number, createdAt (the FIFO key), mergeStateStatus, labels (leg 3 reads every PR's).
    Optional (absent == null, jq's reading): the other eight. `reviewDecision` stays `str | None`
    because the bash distinguishes them: `jq -r` prints a null as the TEXT "null", which is
    neither "" (the no-approval arm) nor "CHANGES_REQUESTED".
    """

    number: int
    created_at: str
    merge_state_status: str
    labels: tuple[Label, ...]
    auto_merge_request: AutoMergeRequest | None
    review_decision: str | None
    head_ref_oid: str | None
    base_ref_name: str | None
    latest_reviews: tuple[Review, ...]  # null / absent / [] collapse: every reader does `// []` or `[]?`
    reviews: tuple[Review, ...]
    author: Actor | None
    head_ref_name: str | None

    @classmethod
    def from_wire(cls, d: dict) -> PullRequest:
        w = "pr"
        n = _get(d, w, "number", int, required=True)
        w = f"pr #{n}"
        amr = _get(d, w, "autoMergeRequest", dict, required=False)
        auth = _get(d, w, "author", dict, required=False)
        return cls(
            number=n,
            created_at=_str(d, w, "createdAt", required=True),
            merge_state_status=_str(d, w, "mergeStateStatus", required=True),
            labels=tuple(Label.from_wire(x) for x in _list(d, w, "labels", required=True)),
            auto_merge_request=None if amr is None else AutoMergeRequest.from_wire(amr),
            review_decision=_str(d, w, "reviewDecision"),
            head_ref_oid=_str(d, w, "headRefOid"),
            base_ref_name=_str(d, w, "baseRefName"),
            latest_reviews=_reviews(d, w, "latestReviews"),
            reviews=_reviews(d, w, "reviews"),
            author=None if auth is None else Actor.from_wire(auth),
            head_ref_name=_str(d, w, "headRefName"),
        )

    @property
    def armed(self) -> bool:
        return self.auto_merge_request is not None

    @property
    def label_names(self) -> tuple[str | None, ...]:
        return tuple(lb.name for lb in self.labels)


def parse_pr_list(payload: Any) -> tuple[PullRequest, ...]:
    if not isinstance(payload, list):
        raise WireError("pr list", "<root>", f"is {type(payload).__name__}, want array")
    return tuple(PullRequest.from_wire(d) for d in payload)


@dataclass(frozen=True, slots=True)
class CommitAuthor:
    login: str | None

    @classmethod
    def from_wire(cls, d: dict) -> CommitAuthor:
        return cls(login=_str(d, "commit author", "login"))


@dataclass(frozen=True, slots=True)
class Commit:
    message_headline: str | None
    committed_date: str | None
    authors: tuple[CommitAuthor, ...]

    @classmethod
    def from_wire(cls, d: dict) -> Commit:
        return cls(message_headline=_str(d, "commit", "messageHeadline"),
                   committed_date=_str(d, "commit", "committedDate"),
                   authors=tuple(CommitAuthor.from_wire(a) for a in (_list(d, "commit", "authors") or [])))

    @property
    def is_merge(self) -> bool:
        """`(.messageHeadline // "") | startswith("Merge branch ")` — the updater's own merges."""
        return (self.message_headline or "").startswith("Merge branch ")


@dataclass(frozen=True, slots=True)
class PrCommits:
    """`gh pr view N --json commits` — `commits` REQUIRED and an array (renovate_probe's
    `type == "array"`; leg 1's `jq -e '.commits'` is laxer, see REPORT)."""

    commits: tuple[Commit, ...]

    @classmethod
    def from_wire(cls, d: Any) -> PrCommits:
        return cls(commits=tuple(Commit.from_wire(c) for c in _list(d, "pr view", "commits", required=True)))


@dataclass(frozen=True, slots=True)
class PrCommitsReviews:
    """`gh pr view N --json commits,reviews` (leg 2). Both OPTIONAL here, None kept distinct from
    (): the bash reads this payload twice with different strictness — `renovate_untouched`
    (`.commits[]?`, null == empty) and the verdict jq (`.commits[]`, null == error == HOLD)."""

    commits: tuple[Commit, ...] | None
    reviews: tuple[Review, ...] | None

    @classmethod
    def from_wire(cls, d: Any) -> PrCommitsReviews:
        c = _list(d, "pr view", "commits")
        r = _list(d, "pr view", "reviews")
        return cls(commits=None if c is None else tuple(Commit.from_wire(x) for x in c),
                   reviews=None if r is None else tuple(Review.from_wire(x) for x in r))


@dataclass(frozen=True, slots=True)
class RollupEntry:
    """One check: a check-run `{name, conclusion}` or a commit status `{context, state}`, as the
    probe's --jq projections emit them (values already UPPERCASE; a running check-run reports its
    status as its conclusion)."""

    key: str  # .name // .context // ""
    value: str  # (.conclusion // .state) // ""

    @classmethod
    def check_run(cls, d: dict) -> RollupEntry:
        return cls(key=_str(d, "check-run", "name") or "", value=_str(d, "check-run", "conclusion") or "")

    @classmethod
    def status(cls, d: dict) -> RollupEntry:
        return cls(key=_str(d, "status", "context") or "", value=_str(d, "status", "state") or "")


@dataclass(frozen=True, slots=True)
class RenovateProbe:
    """renovate_probe's output: `{commits, statusCheckRollup: runs + statuses}`."""

    commits: tuple[Commit, ...]
    rollup: tuple[RollupEntry, ...]
