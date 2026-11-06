#!/usr/bin/env python3
"""Rendered-browser check of the specs site's Mermaid diagrams and flowchart node links (the
oracle-fleet scripts/e2e/test_specs_site.py shape, oracle-fleet#955).

Loads every locally built spec page that carries a mermaid fence (scripts/specs-build.sh output,
served statically), waits for exactly that many diagrams to render with none in error, then for
each diagram that carries linked nodes clicks its first link and asserts (a) the location fragment
equals the node's href and (b) the target heading is in view. A diagram with no linked node (a
sequence diagram) is checked for rendering only. When mkdocs.yml enables `navigation.instant`, the
same is repeated after one in-site navigation (away and back), because instant navigation swaps
the page body without a reload.

Usage (scripts/e2e-specs-site.sh runs it inside the playwright image):
  python3 scripts/e2e/test_specs_site.py --base-url http://127.0.0.1:8000 --evidence-out evid \
      --pages '{"/specs/endpoints/sessions.html": 3, …}'
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from playwright.sync_api import Page, sync_playwright

LINKS_JS = """
(svg) => [...svg.querySelectorAll('a')]
  .map(a => a.getAttribute('xlink:href') || a.getAttribute('href'))
  .filter(h => h && h.startsWith('#'))
"""


def wait_rendered(page: Page, expected: int) -> None:
    page.wait_for_function(
        f"document.querySelectorAll('div.mermaid-src.mermaid-done').length === {expected}",
        timeout=30000,
    )
    assert page.locator("div.mermaid-src.mermaid-error").count() == 0, "a diagram failed to render"


def check_every_diagram(page: Page, path: str, expected: int, phase: str, evid: Path | None, results: list[dict]) -> int:
    wait_rendered(page, expected)
    clicked = 0
    for i in range(expected):
        diagram = page.locator("div.mermaid-src.mermaid-done").nth(i)
        hrefs = diagram.locator("svg").evaluate(LINKS_JS)
        if not hrefs:
            results.append({"page": path, "phase": phase, "diagram": i, "rendered": True, "links": 0})
            print(f"  ok {path} {phase} diagram {i}: rendered (no linked node)")
            continue
        want = hrefs[0]
        diagram.scroll_into_view_if_needed()
        diagram.locator("svg a").first.click()
        page.wait_for_function(f"location.hash === {json.dumps(want)}", timeout=10000)
        assert page.evaluate("location.hash") == want
        box = page.evaluate(
            """(id) => { const e = document.getElementById(id);
              if (!e) return null; const r = e.getBoundingClientRect();
              return {top: r.top, bottom: r.bottom, vh: innerHeight}; }""",
            want[1:],
        )
        assert box, f"{phase}: {path} diagram {i}: target {want} is not an element on the page"
        assert box["bottom"] > 0 and box["top"] < box["vh"], (
            f"{phase}: {path} diagram {i}: target {want} not in view after the click: {box}"
        )
        results.append({"page": path, "phase": phase, "diagram": i, "fragment": want, "target_box": box})
        clicked += 1
        print(f"  ok {path} {phase} diagram {i}: click -> {want} in view")
        if evid and clicked == 1:
            page.screenshot(path=str(evid / f"{Path(path).stem}-{phase}-after-click.png"))
    return clicked


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--evidence-out", required=True)
    ap.add_argument("--instant", choices=["0", "1"], default="0")
    ap.add_argument("--pages", required=True, help="JSON: page path on the site → number of mermaid fences")
    args = ap.parse_args()
    pages: dict[str, int] = json.loads(args.pages)
    evid = Path(args.evidence_out)
    evid.mkdir(parents=True, exist_ok=True)
    instant = args.instant == "1"
    results: list[dict] = []
    clicks = 0

    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": 1280, "height": 800})
        errors: list[str] = []
        # The theme links Google Fonts; the leg has no egress and an unanswered request would hold
        # the load event forever. Everything off the local server is refused instantly.
        page.route(
            re.compile(r"^(?!https?://127\.0\.0\.1[:/]).*"),
            lambda route: route.abort() if route.request.url.startswith(("http:", "https:")) else route.continue_(),
        )
        page.on("pageerror", lambda e: errors.append(str(e)))
        for path, expected in pages.items():
            page.goto(args.base_url + path)
            clicks += check_every_diagram(page, path, expected, "fresh-load", evid, results)
            if instant:
                page.goto(args.base_url + path)  # reset the fragment, then navigate in-site
                wait_rendered(page, expected)
                page.locator("a.md-nav__link:not([aria-current])").first.click()
                page.wait_for_function(f"!location.pathname.endsWith({json.dumps(path)})", timeout=10000)
                page.go_back()
                clicks += check_every_diagram(page, path, expected, "after-instant-nav", evid, results)
        browser.close()
    assert not errors, f"page errors: {errors}"

    (evid / "specs-site-nav.json").write_text(json.dumps({"instant": instant, "pages": pages, "results": results}, indent=2))
    print(f"SPECS-SITE-NAV PASS: {len(results)} diagram(s) over {len(pages)} page(s), {clicks} node click(s), instant={instant}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
