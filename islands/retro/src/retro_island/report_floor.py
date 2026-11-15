"""RETRO-REPORT-FLOOR (specs/cell.md): what a retro report is.

Same definitions as the old member `agents/retro-report-floor.sh`. Pure: executes nothing, writes no file.
"""

from __future__ import annotations

import re

BEGIN = "BEGIN-RETRO-REPORT"
END = "END-RETRO-REPORT"
FLOOR = 20

_NON_CONTENT = re.compile(r"^[ \t\r\n\f\v]*$|^#")


def _last_block(log: str) -> str:
    """The LAST complete BEGIN/END block, markers and inter-block text dropped (the old awk pass)."""
    buf: list[str] = []
    last: list[str] = []
    inside = False
    for line in log.splitlines(keepends=True):
        if BEGIN in line:
            buf, inside = [], True
        elif END in line:
            inside, last, buf = False, buf, []
        elif inside:
            buf.append(line if line.endswith("\n") else line + "\n")
    return "".join(last)


def content_lines(text: str) -> int:
    """Lines that are neither whitespace-only nor start with `#` in column 0."""
    return sum(1 for line in text.splitlines() if not _NON_CONTENT.match(line))


def report_floor(text: str, kind: str) -> str:
    """Return the report, or exactly one reason line: `no-markers`, `empty`, `under-floor: N content lines < 20`.

    `kind` is the caller's declaration: `log` (a ride log, both marker strings required) or `report` (used as-is).
    """
    if kind == "log":
        if BEGIN not in text or END not in text:
            return "no-markers"
        report = _last_block(text)
    elif kind == "report":
        report = text
    else:
        raise ValueError(f"kind must be 'log' or 'report', not {kind!r}")
    if not report:
        return "empty"
    n = content_lines(report)
    if n < FLOOR:
        return f"under-floor: {n} content lines < {FLOOR}"
    return report


def is_reason(result: str) -> bool:
    """True when `result` is a reason line rather than a report."""
    return result in ("no-markers", "empty") or result.startswith("under-floor: ")
