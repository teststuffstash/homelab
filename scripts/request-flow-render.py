#!/usr/bin/env python3
"""Render an app's merged public request map (docs/patterns/public-request-flow.md, ADR-124).

Two inputs, one picture: the PLATFORM map (docs/patterns/request-flow/platform.yaml — the edge,
the tunnel, the LAN path, the contract rows the platform assumes of an app) and the APP map (the
app repo's own stages, one row per guard, each pointing at its spec id). Rows merge by `seq`
(platform 10–89, app ≥ 100); contract rows apply per profile (`applies_to`) and are matched by the
app's `fulfils: <id>`; unfulfilled ones render as GAPS (exit 2 under --strict). An app row's
`depends_on: ["<host>/<path>"]` names a call to ANOTHER PublicRoute — a dashed edge in the diagram
and a cross-map table, because a claim has one backend per hostname and this is how two compose. Output is deterministic: same inputs → same bytes,
with a content hash of each input in the header as provenance (never a git sha — the committed
example must not change when an unrelated commit touches the file).

    python3 scripts/request-flow-render.py --platform docs/patterns/request-flow/platform.yaml \
        --profile api --app <your-map.yaml> [--lan] [--strict] [--out docs/request-flow.md]
    python3 scripts/request-flow-render.py --self-test   # renders the committed example, byte-compares

YAML is read with PyYAML when present, else through `yq -o=json` (devbox ships yq) — the same
fallback machines/generate.py uses.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
EXAMPLE_DIR = os.path.join(ROOT, "docs", "patterns", "request-flow")
COLS = ["seq", "stage", "owner", "guard", "value", "rejection", "verify", "id"]


def load_yaml(path: str) -> dict:
    try:
        import yaml  # noqa: F401  (PyYAML, when the interpreter has it)
        with open(path, encoding="utf-8") as f:
            return yaml.safe_load(f)
    except ModuleNotFoundError:
        out = subprocess.run(["yq", "-o=json", ".", path], check=True, capture_output=True, text=True)
        return json.loads(out.stdout)


def content_hash(path: str) -> str:
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()[:12]


def esc(v) -> str:
    return str(v if v is not None else "—").replace("|", "\\|").replace("\n", " ")


def validate(platform: dict, app: dict, profile: str) -> list[str]:
    errs: list[str] = []
    schema = platform.get("schema", {})
    owners = set(schema.get("owners", []))
    app_min = int(schema.get("app_seq_min", 100))
    if profile not in platform.get("profiles", {}):
        errs.append(f"profile {profile!r} not in the platform map ({sorted(platform.get('profiles', {}))})")
        return errs
    for row in platform["profiles"][profile]["stages"] + platform.get("lan", {}).get("stages", []):
        if row.get("owner") not in owners:
            errs.append(f"platform row {row.get('id')}: owner {row.get('owner')!r} not in {sorted(owners)}")
        if int(row["seq"]) >= app_min:
            errs.append(f"platform row {row.get('id')}: seq {row['seq']} collides with the app range (≥{app_min})")
    seen: set[int] = set()
    for row in app.get("stages", []):
        for k in ("seq", "id", "stage"):
            if k not in row:
                errs.append(f"app row missing {k!r}: {row}")
        s = int(row.get("seq", -1))
        if s < app_min:
            errs.append(f"app row {row.get('id')}: seq {s} below app_seq_min {app_min}")
        if s in seen:
            errs.append(f"app row {row.get('id')}: duplicate seq {s}")
        seen.add(s)
    contract = platform.get("contract", [])
    contract_ids = {c["id"] for c in contract}
    for c in contract:
        for pr in c.get("applies_to", ["api", "consumer"]):
            if pr not in platform.get("profiles", {}):
                errs.append(f"contract row {c['id']}: applies_to unknown profile {pr!r}")
    applicable = {c["id"] for c in contract if profile in c.get("applies_to", ["api", "consumer"])}
    for row in app.get("stages", []):
        f = row.get("fulfils")
        if f and f not in contract_ids:
            errs.append(f"app row {row.get('id')}: fulfils unknown contract row {f!r}")
        elif f and f not in applicable:
            errs.append(f"app row {row.get('id')}: fulfils {f!r}, which does not apply to the {profile!r} profile")
        deps = row.get("depends_on", [])
        if not isinstance(deps, list) or any(not isinstance(d, str) or "/" not in d for d in deps):
            errs.append(f"app row {row.get('id')}: depends_on must be a list of '<host>/<path>' strings, got {deps!r}")
    return errs


def render(platform: dict, app: dict, profile: str, lan: bool, paths: tuple[str, str]) -> tuple[str, list[dict]]:
    p_rows = [dict(r, owner_kind="platform") for r in platform["profiles"][profile]["stages"]]
    a_rows = [dict(r, owner="app", owner_kind="app") for r in app.get("stages", [])]
    lan_rows = [dict(r, owner_kind="lan") for r in platform.get("lan", {}).get("stages", [])] if lan else []
    merged = sorted(p_rows + a_rows, key=lambda r: (int(r["seq"]), str(r["id"])))
    fulfilled = {r["fulfils"]: r["id"] for r in a_rows if r.get("fulfils")}
    contract = [c for c in platform.get("contract", []) if profile in c.get("applies_to", ["api", "consumer"])]
    gaps = [c for c in contract if c["id"] not in fulfilled]
    deps = [(r, d) for r in a_rows for d in (r.get("depends_on") or [])]

    out: list[str] = []
    out.append(f"# Request map — {esc(app.get('app', 'app'))} · `{profile}` profile")
    out.append("")
    out.append("> GENERATED by `scripts/request-flow-render.py` — do not edit; regenerate. Pattern + schema:")
    out.append("> [`docs/patterns/public-request-flow.md`](../public-request-flow.md). Platform half:")
    out.append(f"> `{os.path.relpath(paths[0], ROOT)}` (sha256 `{content_hash(paths[0])}`); app half: `{os.path.relpath(paths[1], ROOT)}`")
    out.append(f"> (sha256 `{content_hash(paths[1])}`). Values are POINTERS to where each knob lives — the number's home is authoritative.")
    if app.get("spec_base"):
        out.append(f"> App spec rows: {app['spec_base']}")
    out.append("")
    # mermaid: platform chain → app chain; LAN branch joins at the first shared id (PRF-SERVICE)
    out.append("```mermaid")
    out.append("flowchart LR")
    out.append("    C([client])")
    prev = "C"
    for r in p_rows:
        node = f"P{r['seq']}"
        label = esc(r["stage"]).split(" — ")[0].replace('"', "'")
        out.append(f'    {node}["{r["seq"]} {label}"]')
        out.append(f"    {prev} --> {node}")
        prev = node
    for r in a_rows:
        node = f"A{r['seq']}"
        label = esc(r["stage"]).split(" — ")[0].split(",")[0].replace('"', "'")
        out.append(f'    {node}["{r["seq"]} {label}"]')
        out.append(f"    {prev} --> {node}")
        prev = node
    for i, (r, d) in enumerate(deps):
        out.append(f'    D{i}(["{d}"])')
        out.append(f"    A{r['seq']} -.->|calls| D{i}")
    if lan_rows:
        out.append("    L([LAN client])")
        lprev = "L"
        join_ids = {r["id"] for r in p_rows}
        for r in lan_rows:
            if r["id"] in join_ids:
                out.append(f"    {lprev} --> P{r['seq']}")
                break
            node = f"L{r['seq']}"
            label = esc(r["stage"]).split(" — ")[0].replace('"', "'")
            out.append(f'    {node}["{r["seq"]} {label}"]')
            out.append(f"    {lprev} --> {node}")
            lprev = node
    out.append("```")
    out.append("")
    out.append("## Stages, in request order")
    out.append("")
    out.append("| seq | stage | owner | guard | value lives in | rejection looks like | verify | id |")
    out.append("|---|---|---|---|---|---|---|---|")
    for r in merged:
        out.append("| " + " | ".join(esc(r.get(c)) for c in COLS) + " |")
    if lan_rows:
        out.append("")
        out.append("## The LAN path (joins the table above at the shared stage)")
        out.append("")
        out.append("| seq | stage | owner | guard | value lives in | rejection looks like | verify | id |")
        out.append("|---|---|---|---|---|---|---|---|")
        for r in sorted(lan_rows, key=lambda r: int(r["seq"])):
            out.append("| " + " | ".join(esc(r.get(c)) for c in COLS) + " |")
    out.append("")
    if deps:
        out.append("## Cross-map dependencies (calls to ANOTHER PublicRoute)")
        out.append("")
        out.append("| from stage | calls | note |")
        out.append("|---|---|---|")
        for r, d in deps:
            out.append(f"| `{r['id']}` (seq {r['seq']}) | `{d}` | that host has its own request map — this picture is only as live as that one |")
        out.append("")
    out.append(f"## Contract — what the platform assumes of a `{profile}`-profile app")
    out.append("")
    out.append("| contract row | why the app owns it | fulfilled by |")
    out.append("|---|---|---|")
    for c in contract:
        who = f"`{fulfilled[c['id']]}`" if c["id"] in fulfilled else "**GAP**"
        out.append(f"| `{c['id']}` — {esc(c['stage'])} | {esc(c['why'])} | {who} |")
    out.append("")
    if gaps:
        out.append(f"**{len(gaps)} contract gap(s)**: " + ", ".join(f"`{g['id']}`" for g in gaps) + " — each is a seam where a bug will land; fill the row in the app map or decide it away in the spec.")
    else:
        out.append("**No contract gaps.**")
    out.append("")
    return "\n".join(out), gaps


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--platform", default=os.path.join(EXAMPLE_DIR, "platform.yaml"))
    ap.add_argument("--profile", choices=["api", "consumer"], default="api")
    ap.add_argument("--app")
    ap.add_argument("--lan", action="store_true", help="append the LAN path (ADR-092)")
    ap.add_argument("--strict", action="store_true", help="exit 2 when a contract row is unfulfilled")
    ap.add_argument("--out", help="write here instead of stdout")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args(argv)
    if a.self_test:
        return self_test()
    if not a.app:
        ap.error("--app is required (the app repo's map)")
    platform, app = load_yaml(a.platform), load_yaml(a.app)
    errs = validate(platform, app, a.profile)
    if errs:
        for e in errs:
            print("request-flow-render: INVALID —", e, file=sys.stderr)
        return 1
    text, gaps = render(platform, app, a.profile, a.lan, (a.platform, a.app))
    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            f.write(text)
    else:
        sys.stdout.write(text)
    if gaps and a.strict:
        print(f"request-flow-render: {len(gaps)} contract gap(s) under --strict: " + ", ".join(g["id"] for g in gaps), file=sys.stderr)
        return 2
    return 0


def self_test() -> int:
    """The committed example renders byte-identical, its two deliberate gaps are exactly the two
    seams it documents, and the validator catches the shapes it exists to catch."""
    plat_p = os.path.join(EXAMPLE_DIR, "platform.yaml")
    platform = load_yaml(plat_p)
    examples = (
        ("example-app.yaml", "api", "example-rendered.md", {"CTR-OPTIONS", "CTR-ERRORS"}, 0),
        ("example-static-site.yaml", "consumer", "example-static-rendered.md", {"CTR-CACHE"}, 1),
    )
    for app_file, profile, rendered, want_gaps, want_deps in examples:
        app_p = os.path.join(EXAMPLE_DIR, app_file)
        app = load_yaml(app_p)
        assert validate(platform, app, profile) == [], validate(platform, app, profile)
        text, gaps = render(platform, app, profile, True, (plat_p, app_p))
        assert {g["id"] for g in gaps} == want_gaps, (app_file, [g["id"] for g in gaps])
        assert text.count("-.->|calls|") == want_deps, (app_file, "depends_on edges")
        want = os.path.join(EXAMPLE_DIR, rendered)
        with open(want, encoding="utf-8") as f:
            committed = f.read()
        assert text == committed, (
            f"{os.path.relpath(want, ROOT)} is stale — regenerate:\n  devbox run request-flow-render -- "
            f"--profile {profile} --lan --app docs/patterns/request-flow/{app_file} --out {os.path.relpath(want, ROOT)}")
        # determinism: a second render is byte-identical
        assert render(platform, app, profile, True, (plat_p, app_p))[0] == text
    app = load_yaml(os.path.join(EXAMPLE_DIR, "example-app.yaml"))
    # the validator's teeth
    bad = {"stages": [{"seq": 50, "id": "X", "stage": "collides"}]}
    assert any("below app_seq_min" in e for e in validate(platform, bad, "api"))
    bad = {"stages": [{"seq": 100, "id": "X", "stage": "s", "fulfils": "CTR-NOPE"}]}
    assert any("unknown contract row" in e for e in validate(platform, bad, "api"))
    assert validate(platform, app, "nope")  # unknown profile → error, not a crash
    bad = {"stages": [{"seq": 100, "id": "X", "stage": "s", "fulfils": "CTR-CACHE"}]}
    assert any("does not apply to the 'api' profile" in e for e in validate(platform, bad, "api"))
    bad = {"stages": [{"seq": 100, "id": "X", "stage": "s", "depends_on": "mcp.minutark.ee/status"}]}
    assert any("depends_on must be a list" in e for e in validate(platform, bad, "api"))
    print("request-flow-render self-test: OK (both examples render byte-identical; gaps api = CTR-OPTIONS + CTR-ERRORS, consumer = CTR-CACHE; one depends_on edge; validator catches seq/contract/profile/applies_to/depends_on faults)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
