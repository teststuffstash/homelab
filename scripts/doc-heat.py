#!/usr/bin/env python3
"""doc-heat — transcript-derived read heat over this repo's markdown (docs/spikes/doc-heat.md).

Parses Claude Code session transcripts for two channels of doc consumption:
  - Read tool calls (file_path + offset/limit -> file- and line-range heat)
  - grep-shaped hits (any `path.md:NNN` reference inside tool results -> line heat)
and renders a static coverage-style report. v0 source: the jail archive; the data
schema carries a `source` dimension so the cluster leg (v1) adds a second source
with separate + combined views instead of a rewrite.

Heat doctrine (the spike): deletion signal = heat x class x age, never heat alone.
The living/historical class is docs-graph-lint's split, consumed not re-invented.
Line heat is APPROXIMATE: counts anchor to line numbers at read time; files drift.

Usage: python3 scripts/doc-heat.py            # -> ~/.claude/doc-heat/{data.json,report.html}
  env: DOC_HEAT_SRC (transcript dir), DOC_HEAT_OUT (output dir)
"""
from __future__ import annotations

import collections
import glob
import html
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.environ.get("DOC_HEAT_SRC", os.path.expanduser("~/.claude/projects/-workspace-homelab"))
OUT = os.environ.get("DOC_HEAT_OUT", os.path.expanduser("~/.claude/doc-heat"))

# the docs-graph-lint living/historical split — consume, don't re-invent
def is_historical(p: str) -> bool:
    return p.startswith(("docs/agents/retros/", "docs/incidents/")) or p == "docs/follow-ups-archive.md"

MD_REF = re.compile(r"([A-Za-z0-9_][A-Za-z0-9_./-]*\.md):(\d+)")
SKILL_TAG = re.compile(r"<command-name>/([a-z-]+)</command-name>")


def norm(path: str, repo_files: set[str]) -> str | None:
    p = path.replace("/workspace/homelab/", "").lstrip("/").removeprefix("./")
    return p if p in repo_files else None


def main() -> None:
    repo_files = set(
        subprocess.run(["git", "ls-files", "*.md"], cwd=REPO, capture_output=True, text=True)
        .stdout.split()
    )
    # per file: {"whole": n, "ranged": n, "grep": n, "lines": {ln: [read, grep]}, "sessions": set}
    heat: dict[str, dict] = collections.defaultdict(
        lambda: {"whole": 0, "ranged": 0, "grep": 0, "lines": collections.defaultdict(lambda: [0, 0]), "sessions": set()}
    )
    n_sessions = 0
    for tf in sorted(glob.glob(os.path.join(SRC, "*.jsonl"))):
        sid = os.path.basename(tf)[:8]
        n_sessions += 1
        for line in open(tf, errors="ignore"):
            if '"tool_use"' not in line and ".md" not in line:
                continue
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue
            content = (o.get("message") or {}).get("content")
            if not isinstance(content, list):
                continue
            for c in content:
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "tool_use" and c.get("name") == "Read":
                    inp = c.get("input") or {}
                    f = norm(str(inp.get("file_path", "")), repo_files)
                    if not f:
                        continue
                    h = heat[f]
                    h["sessions"].add(sid)
                    off, lim = inp.get("offset"), inp.get("limit")
                    if off or lim:
                        h["ranged"] += 1
                        start = int(off or 1)
                        for ln in range(start, start + int(lim or 2000)):
                            h["lines"][ln][0] += 1
                    else:
                        h["whole"] += 1
                elif c.get("type") == "tool_result":
                    r = c.get("content")
                    text = r if isinstance(r, str) else " ".join(
                        x.get("text", "") for x in r if isinstance(x, dict)
                    ) if isinstance(r, list) else ""
                    for m in MD_REF.finditer(text):
                        f = norm(m.group(1), repo_files)
                        if f:
                            heat[f]["grep"] += 1
                            heat[f]["lines"][int(m.group(2))][1] += 1
                            heat[f]["sessions"].add(sid)

    ages = {}
    for f in repo_files:
        r = subprocess.run(["git", "log", "-1", "--format=%as", "--", f], cwd=REPO, capture_output=True, text=True)
        ages[f] = r.stdout.strip() or "?"

    rows = []
    for f in sorted(repo_files):
        h = heat.get(f)
        rows.append({
            "file": f, "class": "historical" if is_historical(f) else "living",
            "whole": h["whole"] if h else 0, "ranged": h["ranged"] if h else 0,
            "grep": h["grep"] if h else 0, "sessions": len(h["sessions"]) if h else 0,
            "age": ages[f],
            "lines": {str(k): v for k, v in sorted(h["lines"].items())} if h else {},
        })
    rows.sort(key=lambda r: -(r["whole"] * 3 + r["ranged"] * 2 + r["grep"]))

    os.makedirs(OUT, exist_ok=True)
    data = {"sources": {"jail": {"sessions": n_sessions, "files": rows}}}
    with open(os.path.join(OUT, "data.json"), "w") as fh:
        json.dump(data, fh, indent=1)
    render(rows, n_sessions)
    print(f"doc-heat: {n_sessions} sessions -> {sum(1 for r in rows if r['sessions'])}/{len(rows)} files touched")
    print(f"report: {os.path.join(OUT, 'report.html')}")


# sequential blue ramp (dataviz reference palette; near-zero recedes toward the surface)
LIGHT_RAMP = ["#cde2fb", "#9ec5f4", "#6da7ec", "#2a78d6", "#184f95"]
DARK_RAMP = ["#184f95", "#256abf", "#3987e5", "#6da7ec", "#9ec5f4"]


def bucket(n: int) -> int:
    return 0 if n <= 0 else min(4, (1 if n == 1 else 2 if n <= 3 else 3 if n <= 9 else 4))


def render(rows: list[dict], n_sessions: int) -> None:
    hot = [r for r in rows if r["sessions"]]
    cold_living = [r for r in rows if not r["sessions"] and r["class"] == "living"]
    css_ramp = "".join(
        f".b{i}{{background:{LIGHT_RAMP[i]}}}" for i in range(5)
    ) + "@media (prefers-color-scheme: dark){:root:where(:not([data-theme=light])) " + \
        " ".join(f".b{i}{{background:{DARK_RAMP[i]}}}" for i in range(5)) + "}" + \
        ":root[data-theme=dark] " + " ".join(f".b{i}{{background:{DARK_RAMP[i]}}}" for i in range(5))

    def table_rows() -> str:
        out = []
        for r in hot:
            cls = "hist" if r["class"] == "historical" else ""
            out.append(
                f"<tr class='{cls}'><td><a href='#f-{html.escape(r['file'])}'>{html.escape(r['file'])}</a></td>"
                f"<td>{r['class']}</td><td>{r['whole']}</td><td>{r['ranged']}</td>"
                f"<td>{r['grep']}</td><td>{r['sessions']}</td><td>{r['age']}</td></tr>"
            )
        return "\n".join(out)

    def gutters() -> str:
        out = []
        for r in hot:
            if not r["lines"]:
                continue
            path = os.path.join(REPO, r["file"])
            if not os.path.isfile(path):
                continue
            body = []
            for i, text in enumerate(open(path, errors="ignore").read().splitlines(), 1):
                rd, gp = r["lines"].get(str(i), [0, 0])
                b = bucket(rd + gp)
                tip = f" title='reads {rd} · grep {gp}'" if b else ""
                body.append(
                    f"<div class='ln'><span class='no b{b}'{tip}>{i}</span>"
                    f"<span class='tx'>{html.escape(text) or ' '}</span></div>"
                )
            out.append(
                f"<details id='f-{html.escape(r['file'])}'><summary>{html.escape(r['file'])} "
                f"<span class='m'>(whole {r['whole']} · ranged {r['ranged']} · grep {r['grep']})</span>"
                f"</summary><div class='code'>{''.join(body)}</div></details>"
            )
        return "\n".join(out)

    cold = "\n".join(
        f"<tr><td>{html.escape(r['file'])}</td><td>{r['age']}</td></tr>" for r in cold_living
    )
    page = f"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>doc-heat</title>
<style>
:root{{color-scheme:light;--s1:#fcfcfb;--pp:#f9f9f7;--ink:#0b0b0b;--ink2:#52514e;--mut:#898781;--grid:#e1e0d9;--bord:rgba(11,11,11,.10)}}
@media (prefers-color-scheme:dark){{:root:where(:not([data-theme=light])){{color-scheme:dark;--s1:#1a1a19;--pp:#0d0d0d;--ink:#fff;--ink2:#c3c2b7;--grid:#2c2c2a;--bord:rgba(255,255,255,.10)}}}}
:root[data-theme=dark]{{color-scheme:dark;--s1:#1a1a19;--pp:#0d0d0d;--ink:#fff;--ink2:#c3c2b7;--grid:#2c2c2a;--bord:rgba(255,255,255,.10)}}
body{{margin:0;padding:24px;background:var(--pp);color:var(--ink);font:14px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}}
h1{{font-size:20px}} h2{{font-size:16px;margin-top:28px}}
.banner{{background:var(--s1);border:1px solid var(--bord);border-radius:6px;padding:10px 14px;color:var(--ink2);max-width:72em}}
table{{border-collapse:collapse;background:var(--s1);font-variant-numeric:tabular-nums}}
th,td{{padding:4px 10px;border-bottom:1px solid var(--grid);text-align:left}}
th{{color:var(--mut);font-weight:600}} tr.hist td{{color:var(--mut)}}
.legend span{{display:inline-block;width:34px;height:12px;margin-right:2px;border:1px solid var(--bord)}}
.code{{background:var(--s1);border:1px solid var(--bord);border-radius:6px;padding:6px 0;overflow-x:auto;font:12px/1.45 ui-monospace,monospace}}
.ln{{display:flex;white-space:pre}} .no{{min-width:46px;text-align:right;padding:0 8px;color:var(--mut);user-select:none}}
.tx{{padding-left:10px}} details{{margin:8px 0}} summary{{cursor:pointer}} .m{{color:var(--mut)}}
a{{color:inherit}}
{css_ramp}
</style></head><body>
<h1>doc-heat — markdown read heat</h1>
<p class="banner"><b>Source: jail ({n_sessions} sessions)</b> — the cluster source (separate + combined
views) arrives with v1. <b>Blind spots:</b> auto-injected context (CLAUDE.md, memory, skill bodies)
never appears as a Read; the operator's own reading (GitHub/editor) is invisible; /design sessions
read owning docs in full, flattening their line signal. <b>Line heat is approximate</b> — counts
anchor to line numbers at read time and files drift. Deletion signal = heat × class × age — never
heat alone; <i>historical</i> rows (muted) are expected cold by doctrine (docs/spikes/doc-heat.md).</p>
<p class="legend">line heat: <span class="b0"></span><span class="b1"></span><span class="b2"></span><span class="b3"></span><span class="b4"></span> 0 · 1 · 2–3 · 4–9 · 10+</p>
<h2>Files by heat ({len(hot)} touched / {len(rows)} total)</h2>
<div style="overflow-x:auto"><table><tr><th>file</th><th>class</th><th>whole reads</th><th>ranged reads</th><th>grep hits</th><th>sessions</th><th>last commit</th></tr>
{table_rows()}</table></div>
<h2>Cold living docs ({len(cold_living)}) — candidates to judge, not a delete list</h2>
<div style="overflow-x:auto"><table><tr><th>file</th><th>last commit</th></tr>{cold}</table></div>
<h2>Line detail (files with line-level heat)</h2>
{gutters()}
</body></html>"""
    with open(os.path.join(OUT, "report.html"), "w") as fh:
        fh.write(page)


if __name__ == "__main__":
    sys.exit(main())
