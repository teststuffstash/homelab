#!/usr/bin/env python3
"""Generate machines/README.md and machines/machines.html from machines.yaml.

The YAML is the single source of truth; this renders tables from it (computing the derived
Perf/W and load-delta columns). Edit machines.yaml, never the generated files, then run:

    devbox run -- python3 machines/generate.py
"""
import os, sys, json, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
YAML = os.path.join(HERE, "machines.yaml")


def load():
    try:
        import yaml  # noqa
        with open(YAML) as f:
            return yaml.safe_load(f)
    except ImportError:
        # fall back to the devbox `yq` (Go) -> JSON
        return json.loads(subprocess.check_output(["yq", "-o=json", YAML]))


def num(v):
    if v is None:
        return None
    return int(v) if isinstance(v, float) and v == int(v) else v


def cell(v, unit=""):
    v = num(v)
    return "—" if v is None else f"{v}{unit}"


def perf_per_watt(m):
    mc, lw = m.get("multicore_bogo_s"), m.get("load_w")
    return f"{mc / lw:.1f}" if mc and lw else "—"


COLUMNS = [
    ("Machine",        lambda m: m["name"]),
    ("Role",           lambda m: m.get("role", "")),
    ("Hardware",       lambda m: m.get("hardware", "")),
    ("Cores",          lambda m: cell(m.get("cpu_cores"))),
    ("RAM (GB)",       lambda m: cell(m.get("memory_gb"))),
    ("Plug",           lambda m: (m.get("plug") or "—").replace("sensor.plug_", "").replace("_power", "")),
    ("Idle (W)",       lambda m: cell(m.get("idle_w"))),
    ("Load (W)",       lambda m: cell(m.get("load_w"))),
    ("1-core (bogo/s)", lambda m: cell(m.get("singlecore_bogo_s"))),
    ("Multi (bogo/s)", lambda m: cell(m.get("multicore_bogo_s"))),
    ("Perf/W",         lambda m: perf_per_watt(m)),
    ("Remote power",   lambda m: m.get("remote_power") or "—"),
]

HEADER_NOTE = (
    "Generated from `machines.yaml` by `generate.py` — **do not edit by hand**; edit the YAML "
    "and re-run `devbox run -- python3 machines/generate.py`.\n\n"
    "Benchmark = stress-ng `matrixprod` bogo-ops/s (synthetic, comparable across these runs only; "
    "see [`../docs/power-measurements.md`](../docs/power-measurements.md)). **Perf/W** = multi-core "
    "bogo-ops/s ÷ load W."
)


def render_md(data):
    rows = data["machines"]
    head = "| " + " | ".join(c[0] for c in COLUMNS) + " |"
    sep = "|" + "|".join(" --- " for _ in COLUMNS) + "|"
    body = "\n".join("| " + " | ".join(str(c[1](m)) for c in COLUMNS) + " |" for m in rows)
    return f"# Machine inventory\n\n{HEADER_NOTE}\n\n{head}\n{sep}\n{body}\n"


def render_html(data):
    rows = data["machines"]
    th = "".join(f"<th>{c[0]}</th>" for c in COLUMNS)
    trs = "\n".join(
        "<tr>" + "".join(f"<td>{c[1](m)}</td>" for c in COLUMNS) + "</tr>" for m in rows
    )
    return (
        "<!doctype html><meta charset=utf-8><title>Homelab machines</title>"
        "<style>body{font-family:system-ui,sans-serif;margin:2rem}"
        "table{border-collapse:collapse}th,td{border:1px solid #ccc;padding:4px 8px;text-align:left}"
        "th{background:#f2f2f2}</style>"
        "<h1>Homelab machine inventory</h1>"
        f"<table><thead><tr>{th}</tr></thead><tbody>\n{trs}\n</tbody></table>"
    )


def main():
    data = load()
    with open(os.path.join(HERE, "README.md"), "w") as f:
        f.write(render_md(data))
    with open(os.path.join(HERE, "machines.html"), "w") as f:
        f.write(render_html(data))
    print(f"wrote machines/README.md and machines/machines.html ({len(data['machines'])} machines)")


if __name__ == "__main__":
    main()
