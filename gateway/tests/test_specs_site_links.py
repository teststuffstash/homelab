"""Static gate for the spec pages' flowchart node links (the oracle-fleet
tests/test_specs_site_links.py shape, oracle-fleet#955).

Every `click <node> href "#fragment" …` inside a ```mermaid fence of any page under specs/ must land
on an anchor that exists on that page — a heading id as mkdocs' `toc` extension slugifies it, or an
explicit `<a id="…">` — and stay same-tab (`_self`) with a relative fragment only. Every
`flowchart` on an endpoint page carries at least one such link: a flowchart node IS a link into the
requirement that owns it (specs/README.md §Rules — the page's navigation), so a chart with no link
is a picture, not a map. Sequence diagrams (the use case's wire walk) carry none; Mermaid has no
click directive for them. The rendered-browser half is scripts/e2e/test_specs_site.py.

Offline: pure text over the committed pages; not a rule-labelled suite (it proves the site, not a
requirement), so its records carry no story label and the spec gate counts them as unlabelled.
"""

from __future__ import annotations

import re
import unicodedata
from pathlib import Path

import pytest

SPECS = Path(__file__).resolve().parent.parent / "specs"
PAGES = sorted(p for p in SPECS.rglob("*.md") if (SPECS / "evidence") not in p.parents)
CLICK = re.compile(r"^\s*click\s+(\S+)\s+(.*)$")
HREF = re.compile(r'^href\s+"([^"]*)"(?:\s+"[^"]*")?\s+_self\s*$')


def _slug(text: str) -> str:
    """python-markdown `toc` slugify (the mkdocs default)."""
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode("ascii")
    text = re.sub(r"[^\w\s-]", "", text).strip().lower()
    return re.sub(r"[-\s]+", "-", text)


def _scan(page: Path) -> tuple[set[str], list[tuple[int, str, str]], list[tuple[int, str, int]]]:
    """(anchors on the page, [(line, node, rest-of-click-line)] for every mermaid click,
    [(line, diagram kind, clicks in it)] for every mermaid fence)."""
    anchors: set[str] = set()
    clicks: list[tuple[int, str, str]] = []
    diagrams: list[tuple[int, str, int]] = []
    fence: str | None = None
    for no, line in enumerate(page.read_text(encoding="utf-8").splitlines(), 1):
        m = re.match(r"^```(\w*)", line)
        if m:
            fence = None if fence is not None else (m.group(1) or "plain")
            if fence == "mermaid":
                diagrams.append((no, "", 0))
            continue
        if fence == "mermaid":
            no0, kind, n = diagrams[-1]
            if not kind and line.strip():
                kind = line.strip().split()[0]  # the first non-blank line names the diagram type
            if CLICK.match(line):
                clicks.append((no, CLICK.match(line).group(1), CLICK.match(line).group(2)))
                n += 1
            diagrams[-1] = (no0, kind, n)
        elif fence is None:
            h = re.match(r"^#{1,6}\s+(.*?)\s*#*\s*$", line)
            if h:
                base = slug = _slug(h.group(1))
                n = 0
                while slug in anchors:  # toc's unique(): ing, ing_1, ing_2 …
                    n += 1
                    slug = f"{base}_{n}"
                anchors.add(slug)
            anchors.update(re.findall(r'<a id="([^"]+)"', line))
    return anchors, clicks, diagrams


SCANS = {page: _scan(page) for page in PAGES}
ALL_CLICKS = [(page, *c) for page, (_, clicks, _) in SCANS.items() for c in clicks]
ENDPOINT_FLOWCHARTS = [
    (page, no, n)
    for page, (_, _, diagrams) in SCANS.items()
    if page.parent.name == "endpoints"
    for no, kind, n in diagrams
    if kind.startswith("flowchart") or kind == "graph"
]


def _rel(p: Path) -> str:
    return str(p.relative_to(SPECS))


@pytest.mark.parametrize(
    ("page", "no", "node", "rest"), ALL_CLICKS, ids=[f"{_rel(c[0])} L{c[1]} {c[2]}" for c in ALL_CLICKS]
)
def test_a_click_is_a_same_tab_relative_fragment_on_an_existing_anchor(
    page: Path, no: int, node: str, rest: str
) -> None:
    m = HREF.match(rest)
    assert m, f"{_rel(page)}:{no}: click {node} must be `href \"#fragment\" [\"tooltip\"] _self`, got: {rest}"
    href = m.group(1)
    assert href.startswith("#") and len(href) > 1, f"{_rel(page)}:{no}: relative fragments only, got {href!r}"
    assert href[1:] in SCANS[page][0], f"{_rel(page)}:{no}: {href} is not a heading or explicit anchor on the page"


@pytest.mark.parametrize(
    ("page", "no", "clicks"), ENDPOINT_FLOWCHARTS, ids=[f"{_rel(d[0])} L{d[1]}" for d in ENDPOINT_FLOWCHARTS]
)
def test_an_endpoint_flowchart_links_into_its_requirements(page: Path, no: int, clicks: int) -> None:
    assert clicks >= 1, f"{_rel(page)}:{no}: a flowchart on an endpoint page carries no `click … href` — every node is a link into the requirement that owns it"
