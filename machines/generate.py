#!/usr/bin/env python3
"""Render every generated machine table in this repo from machines/machines.yaml.

`machines.yaml` is the single source of truth for what boxes exist (tofu/locals.tf reads the
same file for the metal-node flags via `yamldecode`). This script writes:

    machines/README.md        power/benchmark table (physical boxes only) + machines.html
    machines/machines.html    the same table as a static page
    README.md, CLAUDE.md      the marker-delimited host table + the Talos/k8s/Cilium version line

The version triple is NOT copied into the YAML: it is read straight from `tofu/variables.tf`'s
defaults, which is where the cluster actually gets its versions from.

Everything between a `<!-- BEGIN GENERATED <key> ... -->` / `<!-- END GENERATED <key> -->` pair is
replaced wholesale, so re-running must leave `git diff` empty (CONTEXT.md principle 2 — a
regeneration is a stable diff). Edit the YAML, never the generated blocks, then run:

    devbox run -- python3 machines/generate.py
"""
import os, re, sys, json, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
YAML = os.path.join(HERE, "machines.yaml")
TOFU_VARS = os.path.join(ROOT, "tofu", "variables.tf")

KINDS = {"metal", "vm", "lxc", "device"}
# Only physical boxes carry a wall-power figure / a stress-ng score; a VM or an LXC draws its
# power through its host, so listing it in the power table would invent a measurement.
POWER_TABLE_KINDS = {"metal"}


def die(msg):
    sys.exit(f"machines/generate.py: FAIL — {msg}")


def load():
    try:
        import yaml  # noqa
        with open(YAML) as f:
            return yaml.safe_load(f)
    except ImportError:
        # fall back to the devbox `yq` (Go) -> JSON
        return json.loads(subprocess.check_output(["yq", "-o=json", YAML]))


def check(machines):
    """The YAML is a config contract for tofu as well as for these tables — fail loudly."""
    seen = set()
    for m in machines:
        name = m.get("name") or die(f"a machine has no name: {m!r}")
        if name in seen:
            die(f"duplicate machine name {name!r}")
        seen.add(name)
        if m.get("kind") not in KINDS:
            die(f"{name}: kind must be one of {sorted(KINDS)}, got {m.get('kind')!r}")
        for field in ("label", "role", "ip"):
            if not m.get(field):
                die(f"{name}: missing required field {field!r}")
        if m.get("talos_metal_node"):
            if m["kind"] != "metal":
                die(f"{name}: talos_metal_node needs kind: metal")
            if not m.get("install_disk"):
                die(f"{name}: talos_metal_node needs install_disk (tofu/metal.tf would fail)")


def tofu_default(var_name):
    """Read a `variable "<name>" { ... default = "<v>" }` default out of tofu/variables.tf."""
    with open(TOFU_VARS) as f:
        src = f.read()
    block = re.search(r'variable\s+"%s"\s*\{(.*?)\n\}' % re.escape(var_name), src, re.S)
    if not block:
        die(f"no `variable \"{var_name}\"` block in tofu/variables.tf (renamed?)")
    default = re.search(r'\n\s*default\s*=\s*"([^"]+)"', block.group(1))
    if not default:
        die(f"`variable \"{var_name}\"` in tofu/variables.tf has no string default")
    return default.group(1)


def num(v):
    if v is None:
        return None
    return int(v) if isinstance(v, float) and v == int(v) else v


def cell(v, unit=""):
    v = num(v)
    return "—" if v is None else f"{v}{unit}"


def md(v):
    """Markdown table cell — a stray pipe would break the row."""
    return str(v).replace("|", "\\|")


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
    "Physical boxes only (`kind: metal`) — a VM/LXC draws its power through its host. The same "
    "YAML also drives the host tables in [`../README.md`](../README.md) / "
    "[`../CLAUDE.md`](../CLAUDE.md) and the metal-node flags in `tofu/locals.tf`.\n\n"
    "Benchmark = stress-ng `matrixprod` bogo-ops/s (synthetic, comparable across these runs only; "
    "see [`../docs/power-measurements.md`](../docs/power-measurements.md)). **Perf/W** = multi-core "
    "bogo-ops/s ÷ load W."
)


def power_rows(machines):
    return [m for m in machines if m.get("kind") in POWER_TABLE_KINDS]


def render_md(machines):
    rows = power_rows(machines)
    head = "| " + " | ".join(c[0] for c in COLUMNS) + " |"
    sep = "|" + "|".join(" --- " for _ in COLUMNS) + "|"
    body = "\n".join("| " + " | ".join(md(c[1](m)) for c in COLUMNS) + " |" for m in rows)
    return f"# Machine inventory\n\n{HEADER_NOTE}\n\n{head}\n{sep}\n{body}\n"


def render_html(machines):
    rows = power_rows(machines)
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


def render_hosts(machines):
    """The Host | IP | Role table shared by README.md and CLAUDE.md."""
    lines = ["| Host | IP | Role |", "|---|---|---|"]
    for m in machines:
        ip = m.get("ip_display") or m["ip"]
        lines.append(f"| {md(m['label'])} | {md(ip)} | {md(m['role'])} |")
    return "\n".join(lines)


def render_versions():
    talos = tofu_default("talos_version")
    kube = tofu_default("kubernetes_version")
    cilium = tofu_default("cilium_version")
    return (f"Cluster: **Talos {talos} / Kubernetes {kube}**, **Cilium {cilium}** CNI "
            "(kube-proxy-free).")


BEGIN = ("<!-- BEGIN GENERATED {key} — do not edit; edit machines/machines.yaml and run "
         "`devbox run -- python3 machines/generate.py` -->")
END = "<!-- END GENERATED {key} -->"


def inject(path, key, block):
    """Replace everything between the BEGIN/END markers for `key`, markers included."""
    with open(path) as f:
        src = f.read()
    pattern = re.compile(r"<!-- BEGIN GENERATED %s\b.*?<!-- END GENERATED %s -->"
                         % (re.escape(key), re.escape(key)), re.S)
    if not pattern.search(src):
        die(f"{os.path.relpath(path, ROOT)}: no `<!-- BEGIN GENERATED {key} ... -->` / "
            f"`<!-- END GENERATED {key} -->` marker pair")
    new = pattern.sub(lambda _: BEGIN.format(key=key) + "\n" + block + "\n" + END.format(key=key),
                      src, count=1)
    with open(path, "w") as f:
        f.write(new)
    return new != src


def main():
    data = load()
    machines = data["machines"]
    check(machines)

    with open(os.path.join(HERE, "README.md"), "w") as f:
        f.write(render_md(machines))
    with open(os.path.join(HERE, "machines.html"), "w") as f:
        f.write(render_html(machines))

    hosts, versions = render_hosts(machines), render_versions()
    for doc in ("README.md", "CLAUDE.md"):
        inject(os.path.join(ROOT, doc), "hosts", hosts)
        inject(os.path.join(ROOT, doc), "versions", versions)

    print(f"wrote machines/README.md + machines/machines.html "
          f"({len(power_rows(machines))} physical of {len(machines)} machines) "
          f"and the hosts/versions blocks in README.md + CLAUDE.md")


if __name__ == "__main__":
    main()
