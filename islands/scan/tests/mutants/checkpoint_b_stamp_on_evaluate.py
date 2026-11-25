"""The stamp-on-evaluation mutant of scan_island.checkpoint_b (goal #3656 pin 4): the same decision, the marker written in `evaluate`.

Run as a script, never imported by the component; no flag in `src/` selects it. It is the mistake the
trigger (b) hold exists to avoid: a Goal that lost its lane has been stamped without being dispatched.
"""

import sys

from scan_island import checkpoint_b


def main(argv: list[str]) -> int:
    if argv[:1] == ["evaluate"] and len(argv) == 3:
        decision = checkpoint_b.decide(argv[1], argv[2].lstrip("#"))
        if decision is None:
            return 4
        print(decision.line())
        if decision.eligible and decision.pr is not None:
            checkpoint_b.write_marker(argv[1], argv[2].lstrip("#"), decision.pr)
        return 0
    return checkpoint_b.main(argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
