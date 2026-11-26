"""The release-on-churn mutant of scan_island.checkpoint_b (goal #3656 child 4, pin 4 ⚖): the head commit id folded into the hash.

Run as a script, never imported by the component; no flag in `src/` selects it. The hold's marker names the
pull request AND the commit its head was at, so a push, an updater master-merge or any new head commit
releases the hold and (b) fires again on the same pull request: the mistake the operator's ruling of PR #3319
(a hold that releases only when the assembly PR closes or is replaced) rules out.
"""

import hashlib
import sys

from scan_island import checkpoint_b

_head: dict[int, str] = {}
_assembly_pr = checkpoint_b.assembly_pr


def marker_for(pr: int, head: str) -> str:
    """The first characters of the mutant's marker for pull request `pr` whose head commit is `head`."""
    return f"🤖 `state-fp:goal-checkpoint-b:{hashlib.sha256(f'pr={pr} head={head}'.encode()).hexdigest()[:12]}`"


def assembly_pr(listed: list[dict], goal: str) -> int | None:
    pr = _assembly_pr(listed, goal)
    for p in listed:
        if p["number"] == pr:
            _head[pr] = p["headRefOid"]
    return pr


def marker(pr: int) -> str:
    return marker_for(pr, _head[pr])


if __name__ == "__main__":
    checkpoint_b.assembly_pr = assembly_pr
    checkpoint_b.marker = marker
    sys.exit(checkpoint_b.main(sys.argv[1:]))
