"""The trigger (b) hold of SCAN-CLAUSE-GOAL (specs/scan-decision.md): is `goal-checkpoint` (b) held by an open assembly PR?

    python -m scan_island.checkpoint_b evaluate <owner/repo> <goal>   read, print one decision line, never write
    python -m scan_island.checkpoint_b dispatch <owner/repo> <goal>   decide again; when (b) is eligible on an open
                                                                      assembly PR, write the marker on it

Exit 0 with a decision line; exit 4 (nothing on stdout, one warning on stderr) when the open-PR list is unreadable.
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
from dataclasses import dataclass

from . import gh
from .strict import lacking

# The open-list read. The field list is the island's recorded read of open pull requests (worlds/goal-checkpoint).
OPEN_FIELDS = "number,title,labels,reviewDecision,autoMergeRequest,mergeStateStatus,author,headRefName,body,baseRefName,headRefOid"
# The fields scan-decision.schema.json requires of the reads (`/properties/open_pr_list`, `/properties/issue_comments_read`).
OPEN_PR_LIST = [{"number": int, "headRefName": str, "body": str}]
ISSUE_COMMENTS_READ = [{"body": str}]


def marker(pr: int) -> str:
    """The first characters of the hold's marker comment on pull request `pr`."""
    return f"🤖 `state-fp:goal-checkpoint-b:{hashlib.sha256(f'pr={pr}'.encode()).hexdigest()[:12]}`"


@dataclass
class Decision:
    kind: str  # "no-pr" | "unmarked" | "unreadable" | "held"
    goal: str
    pr: int | None = None

    @property
    def eligible(self) -> bool:
        return self.kind != "held"

    def line(self) -> str:
        head = f"goal-checkpoint-b {self.goal}"
        return {
            "no-pr": f"{head} fires: no open assembly PR",
            "unmarked": f"{head} fires: pr={self.pr} carries no marker for pr={self.pr}",
            "unreadable": f"{head} fires: pr={self.pr} marker read failed",
            "held": f"{head} HELD: pr={self.pr}",
        }[self.kind]


def warn(message: str) -> None:
    print(f"warning: {message}", file=sys.stderr)


def _read_json(*args: str) -> object | None:
    result = gh.run(*args)
    if result.returncode:
        return None
    try:
        return json.loads(result.stdout)
    except ValueError:
        return None


def assembly_pr(listed: list[dict], goal: str) -> int | None:
    """The open pull request whose head is a `goal/**` branch and whose body has the line `Assembly-for: #<goal>`.
    Several: the highest number (the one that replaced the others)."""
    trailer = re.compile(rf"^Assembly-for: #{re.escape(goal)}[ \t]*$", re.M)
    found = [
        p["number"]
        for p in listed
        if p["headRefName"].startswith("goal/") and trailer.search(p["body"].replace("\r\n", "\n").replace("\r", "\n"))
    ]
    return max(found, default=None)


def _unreadable(answer: object | None, shape: object) -> str | None:
    return "failed or answered no parseable JSON" if answer is None else (f"answered {p}" if (p := lacking(answer, shape)) else None)


def decide(slug: str, goal: str) -> Decision | None:
    """None: the open list is unreadable (a warning is printed, nothing is decided)."""
    listed = _read_json("pr", "list", "--repo", slug, "--state", "open", "--limit", "100", "--json", OPEN_FIELDS)
    problem = _unreadable(listed, OPEN_PR_LIST)
    if problem:
        warn(f"the open pull request list of {slug} {problem} — no decision")
        return None
    pr = assembly_pr(listed, goal)  # type: ignore[arg-type]
    if pr is None:
        return Decision("no-pr", goal)
    comments = _read_json("api", f"repos/{slug}/issues/{pr}/comments?per_page=100")
    problem = _unreadable(comments, ISSUE_COMMENTS_READ)
    if problem:
        # a marker read that fails leaves (b) eligible (Goal pin 9): a read that keeps failing must not silence it
        warn(f"the comments read of {slug}#{pr} {problem} — (b) stays eligible")
        return Decision("unreadable", goal, pr)
    want = marker(pr)
    held = any(c["body"].startswith(want) for c in comments)  # type: ignore[union-attr]
    return Decision("held" if held else "unmarked", goal, pr)


def write_marker(slug: str, goal: str, pr: int) -> None:
    body = f"{marker(pr)} — deterministic scan dispatching a `goal-checkpoint` for Goal #{goal} (trigger b)"
    result = gh.run("api", "-X", "POST", f"repos/{slug}/issues/{pr}/comments", "-f", f"body={body}")
    if result.returncode:
        tail = result.stderr[-200:].replace("\n", " ").strip() or "no stderr"
        warn(f"the marker write on {slug}#{pr} was refused: {tail} — the dispatch goes on")


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[0] not in ("evaluate", "dispatch") or not re.fullmatch(r"#?[0-9]+", argv[2]):
        print("usage: python -m scan_island.checkpoint_b evaluate|dispatch <owner/repo> <goal>", file=sys.stderr)
        return 2
    mode, slug, goal = argv[0], argv[1], argv[2].lstrip("#")
    decision = decide(slug, goal)
    if decision is None:
        return 4
    print(decision.line())
    if mode == "dispatch" and decision.eligible and decision.pr is not None:
        write_marker(slug, goal, decision.pr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
