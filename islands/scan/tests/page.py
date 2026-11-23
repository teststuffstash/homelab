"""A spec page's tables, read as test parameters (CONVENTIONS § The intent column: the header is the parameter list).

The description cell is the case id verbatim; every other header cell is a parameter named by `argname`:
lower-cased, a `#` before digits read as `pr` (`#90 before the pass` → `pr90_before_the_pass`), each run of
other characters an `_`, and a trailing `?` (an expected column) read as an `expected_` prefix.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

Table = tuple[str, list[str], list[list[str]]]


def cells(line: str) -> list[str]:
    return [c.strip() for c in line.strip().strip("|").split("|")]


def tables(page: Path) -> list[Table]:
    """Every table of the page as (the `####` heading above it, header cells, body rows)."""
    out, heading, lines = [], "", page.read_text("utf-8").splitlines()
    i = 0
    while i < len(lines):
        if lines[i].startswith("#### "):
            heading = lines[i].removeprefix("#### ").strip()
        if lines[i].startswith("|") and i + 1 < len(lines) and re.fullmatch(r"\|(\s*:?-+:?\s*\|)+", lines[i + 1].strip()):
            header, rows, i = cells(lines[i]), [], i + 2
            while i < len(lines) and lines[i].startswith("|"):
                row = cells(lines[i])
                if len(row) != len(header):
                    raise ValueError(f"{page.name}: a row of {len(row)} cells under a {len(header)}-cell header: {lines[i]}")
                rows.append(row)
                i += 1
            out.append((heading, header, rows))
            continue
        i += 1
    return out


def table(all_tables: list[Table], question: str) -> tuple[list[str], list[list[str]]]:
    [(header, rows)] = [(h, r) for q, h, r in all_tables if q == question and h[0] == "description"]
    return header, rows


def argname(header_cell: str) -> str:
    expected = header_cell.endswith("?")
    name = re.sub(r"#(?=\d)", "pr", header_cell.removesuffix("?").lower())
    name = re.sub(r"[^a-z0-9]+", "_", name).strip("_")
    if not name.isidentifier():
        raise ValueError(f"header cell {header_cell!r} reads as {name!r}, not a parameter name")
    return f"expected_{name}" if expected else name


def params(all_tables: list[Table], question: str) -> tuple[list[str], list]:
    header, rows = table(all_tables, question)
    return [argname(h) for h in header[1:]], [pytest.param(*row[1:], id=row[0]) for row in rows]


def ticks(cell: str) -> list[str]:
    return re.findall(r"`([^`]+)`", cell)
