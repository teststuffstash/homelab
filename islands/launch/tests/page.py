"""Rows of the spec page's tables, read at collection (rule 1: the page is the test source)."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

ADMISSION = Path(__file__).resolve().parent.parent / "specs" / "admission.md"


@dataclass(frozen=True)
class Row:
    id: str  # the description cell, a trailing ` ⚖` dropped
    cells: dict[str, str]  # header → cell text, inline-code backticks removed

    def __getitem__(self, key: str) -> str:
        return self.cells[key]


def table_under(heading: str, page: Path = ADMISSION) -> list[Row]:
    """The rows of the first table after the `#### heading` line."""
    lines = page.read_text(encoding="utf-8").splitlines()
    start = next(i for i, ln in enumerate(lines) if ln.strip() == f"#### {heading}")
    rows: list[list[str]] = []
    for ln in lines[start + 1:]:
        if ln.startswith("|"):
            rows.append(_cells(ln))
        elif rows:
            break
    header, _sep, *body = rows
    out = []
    for cells in body:
        d = dict(zip(header, cells, strict=True))
        out.append(Row(d["description"].removesuffix(" ⚖").strip(), d))
    return out


def _cells(line: str) -> list[str]:
    parts = re.split(r"(?<!\\)\|", line.strip())[1:-1]
    return [p.strip().replace("`", "") for p in parts]
