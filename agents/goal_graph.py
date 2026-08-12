#!/usr/bin/env python3
"""goal_graph.py — dump a Goal issue's sub-issue tree (the FU-090 sprout index) as canonical
JSON, then render it as a DAG (mermaid / dot).

Two-step by design (operator, 2026-08-12): FETCH walks the live GitHub tree ONCE and saves a
deterministic snapshot; RENDER is a pure function over that file, so renderings can be iterated
without re-walking the API. Same world -> byte-identical JSON (nodes/edges/labels all sorted,
no timestamps) — the CONTEXT.md "deterministic, reviewable diffs" rule applied to a snapshot.

Edges carried, both kinds the platform actually writes:
  sub         parent -> child   (native sub-issue lineage — issue-authoring.md rung 1)
  blocked_by  blocker -> blocked (native dependency edges — FU-111; the only gating reader)

Relation to prior art (stated per the prior-art rule): FU-090 rung 4 (exporter sprout-RATE
gauge -> Grafana node-graph) is a METRIC over this same tree and remains unbuilt; homelab#209's
agent-goals panel is the convergence REGISTRY (numbers, no edges). This is the on-demand seat
renderer — jail tooling, not platform mechanism (roles.md §meta-coordinator).

Usage (jail: prefix with `devbox run --`; needs gh + a token that reads the repos):
  python3 agents/goal_graph.py fetch teststuffstash/homelab 278 -o goal-278.json
  python3 agents/goal_graph.py render goal-278.json --format mermaid > goal-278.mmd
  python3 agents/goal_graph.py render goal-278.json --format dot | dot -Tsvg > goal-278.svg
"""

import argparse
import json
import re
import subprocess
import sys

MAX_DEPTH = 10  # bound the walk (goal-budget.sh binds its ancestor walk at 6; trees are ~3 deep)


def gh_json_lines(path):
    """`gh api --paginate --jq '.[]'` -> list of dicts. Loud on failure (rule #6 shape:
    an unreadable probe is an error, never an empty tree)."""
    res = subprocess.run(
        ["gh", "api", path, "--paginate", "--jq", ".[]"],
        capture_output=True, text=True,
    )
    if res.returncode != 0:
        # 404 on dependencies/* means "none" on some gh versions; empty stdout + rc 0 is the
        # normal empty answer. Anything else is fatal.
        if "HTTP 404" in res.stderr:
            return []
        sys.exit(f"PROBE-FAIL: gh api {path}: {res.stderr.strip()}")
    return [json.loads(line) for line in res.stdout.splitlines() if line.strip()]


def gh_issue(repo, number):
    res = subprocess.run(
        ["gh", "api", f"repos/{repo}/issues/{number}"],
        capture_output=True, text=True,
    )
    if res.returncode != 0:
        sys.exit(f"PROBE-FAIL: gh api repos/{repo}/issues/{number}: {res.stderr.strip()}")
    return json.loads(res.stdout)


def repo_of(issue):
    # "https://api.github.com/repos/OWNER/REPO" -> "OWNER/REPO"
    return issue["repository_url"].split("/repos/", 1)[1]


def node_id(repo, number):
    return f"{repo}#{number}"


def classify(issue, is_root):
    """One status string per node — the render key. Precedence mirrors how the scan reads
    labels (terminal > human-gate > in-flight > queued > inert)."""
    labels = {l["name"] for l in issue.get("labels", [])}
    title = issue.get("title", "")
    if is_root or "task/goal" in labels:
        return "goal"
    if title.startswith("post-launch:"):
        return "bucket"
    if issue["state"] == "closed":
        return "closed-skip" if issue.get("state_reason") == "not_planned" else "closed"
    if "agent/error" in labels:
        return "error"
    if "agent/blocked" in labels:
        return "blocked"
    if "agent/in-progress" in labels or "agent/review" in labels:
        return "riding"
    if "agent/queued" in labels:
        return "queued"
    return "inert"


# --- provenance -----------------------------------------------------------
# The native tree files every post-launch sprout under the BUCKET (IL-T17), which erases the
# derivation chain. The true origin survives only as body prose — the harvest play's
# "Harvested from PR #N (issue #M)" grammar and the goal-review rides' "Found while verifying #K".
# Best-effort parse, ordered patterns, first hit wins; unparsed stays None (the render falls
# back to the native parent — honest, never guessed).

_PR_REF = r"PR (?:([\w.-]+/[\w.-]+)#|#?)(\d+)"
_ISSUE_REF = r"\(issue (?:([\w.-]+/[\w.-]+)#|#?)(\d+)\)"


def _resolve_pr_issue(repo, pr):
    """PR-only provenance: read the PR body's closing keyword for its issue."""
    res = subprocess.run(["gh", "api", f"repos/{repo}/pulls/{pr}"],
                         capture_output=True, text=True)
    if res.returncode != 0:
        return None
    body = json.loads(res.stdout).get("body") or ""
    m = re.search(r"(?:[Ff]ixes|[Cc]loses|[Ii]mplements|[Rr]esolves) #(\d+)", body)
    return int(m.group(1)) if m else None


def parse_provenance(body, repo, self_num, root_num=None):
    if not body:
        return None
    # 1. arbitration deferral: "Deferred out of PR #325 (issue #309)"
    m = re.search(r"[Dd]eferred out of " + _PR_REF + r" " + _ISSUE_REF, body)
    if m:
        return {"origins": [node_id(m.group(3) or repo, int(m.group(4)))],
                "via_pr": int(m.group(2)), "kind": "arbitration-deferral"}
    # 2. closeout: "Harvested from the merged-closeout of #299 (PR #306"
    m = re.search(r"[Hh]arvested from the merged-closeout of #(\d+) \(PR #(\d+)", body)
    if m:
        return {"origins": [node_id(repo, int(m.group(1)))],
                "via_pr": int(m.group(2)), "kind": "closeout-finding"}
    # 3. the canonical shape: "Harvested from PR #310 review (issue #288)" — incl. cross-repo
    m = re.search(r"[Hh]arvested from " + _PR_REF + r"[^\n]{0,200}?" + _ISSUE_REF, body)
    if m:
        return {"origins": [node_id(m.group(3) or repo, int(m.group(4)))],
                "via_pr": int(m.group(2)), "kind": "harvest"}
    # 4. goal-review / verification findings: collect the issue refs in the lead sentence,
    #    minus PR numbers and the goal itself ("Found ... verifying children #334 / #333 / #335")
    m = re.search(r"(?:[Hh]arvested from goal-review|[Ff]ound (?:while|by|at|on|during)|"
                  r"[Ff]iled (?:by|at|during))[^\n]{0,260}", body)
    if m:
        span = re.sub(r"PR #\d+", "", m.group(0))
        goal_hint = re.search(r"(?:goal|goal-review\S*(?: of| on| for)?) #(\d+)", span)
        nums = [int(x) for x in re.findall(r"#(\d+)", span)]
        drop = {self_num} | ({int(goal_hint.group(1))} if goal_hint else set())
        if root_num is not None:
            drop.add(root_num)  # the goal names itself in every ride sentence — never an origin
        origins = sorted({n for n in nums if n not in drop})
        if origins:
            return {"origins": [node_id(repo, n) for n in origins],
                    "via_pr": None, "kind": "goal-review-finding"}
    # 5. last resort — a bare "from PR #328's sweep": resolve the PR's own issue
    m = re.search(r"from " + _PR_REF + r"'s", body)
    if m:
        pr = int(m.group(2))
        origin = _resolve_pr_issue(m.group(1) or repo, pr)
        if origin:
            return {"origins": [node_id(m.group(1) or repo, origin)],
                    "via_pr": pr, "kind": "pr-body-finding"}
    return None


def fetch(repo, number, with_deps=True):
    nodes, edges = {}, []
    root_id = node_id(repo, number)
    queue = [(repo, number, None, 0)]
    seen = set()
    while queue:
        r, n, parent, depth = queue.pop(0)
        nid = node_id(r, n)
        if nid in seen:
            continue  # cycle/diamond safety: first (shallowest) parent wins the tree edge
        seen.add(nid)
        issue = gh_issue(r, n)
        prov = parse_provenance(issue.get("body"), r, n, number) if nid != root_id else None
        if prov:
            for o in prov["origins"]:
                edges.append({"from": o, "to": nid, "type": "harvest",
                              "via_pr": prov["via_pr"], "kind": prov["kind"]})
        nodes[nid] = {
            "id": nid,
            "repo": r,
            "number": n,
            "title": issue.get("title", ""),
            "state": issue["state"],
            "state_reason": issue.get("state_reason"),
            "labels": sorted(l["name"] for l in issue.get("labels", [])),
            "depth": depth,
            "status": classify(issue, nid == root_id),
            "provenance": prov,
            "url": issue.get("html_url", ""),
        }
        if parent:
            edges.append({"from": parent, "to": nid, "type": "sub"})
        if with_deps:
            for blocker in gh_json_lines(f"repos/{r}/issues/{n}/dependencies/blocked_by"):
                b_id = node_id(repo_of(blocker), blocker["number"])
                edges.append({"from": b_id, "to": nid, "type": "blocked_by"})
                if b_id not in seen and b_id not in nodes:
                    # external blocker: record as a node, do not walk its subtree
                    nodes.setdefault(b_id, {
                        "id": b_id,
                        "repo": repo_of(blocker),
                        "number": blocker["number"],
                        "title": blocker.get("title", ""),
                        "state": blocker["state"],
                        "state_reason": blocker.get("state_reason"),
                        "labels": sorted(l["name"] for l in blocker.get("labels", [])),
                        "depth": None,
                        "status": "external",
                        "url": blocker.get("html_url", ""),
                    })
        if depth < MAX_DEPTH:
            for child in gh_json_lines(f"repos/{r}/issues/{n}/sub_issues"):
                queue.append((repo_of(child), child["number"], nid, depth + 1))
        else:
            print(f"WARN: depth bound {MAX_DEPTH} hit at {nid} — subtree truncated",
                  file=sys.stderr)
    return {
        "root": root_id,
        "nodes": sorted(nodes.values(), key=lambda x: (x["repo"], x["number"])),
        "edges": sorted(edges, key=lambda e: (e["type"], e["from"], e["to"])),
    }


# --- render ---------------------------------------------------------------

MERMAID_CLASSES = {
    "goal":        "fill:#4c1d95,stroke:#a78bfa,color:#ffffff",
    "bucket":      "fill:#1e3a5f,stroke:#7dd3fc,color:#e0f2fe",
    "closed":      "fill:#14532d,stroke:#4ade80,color:#dcfce7",
    "closed-skip": "fill:#3f3f46,stroke:#a1a1aa,color:#d4d4d8,stroke-dasharray:4 3",
    "queued":      "fill:#713f12,stroke:#facc15,color:#fef9c3",
    "riding":      "fill:#7c2d12,stroke:#fb923c,color:#ffedd5",
    "blocked":     "fill:#7f1d1d,stroke:#f87171,color:#fee2e2",
    "error":       "fill:#7f1d1d,stroke:#f87171,color:#fee2e2,stroke-width:3px",
    "inert":       "fill:#27272a,stroke:#71717a,color:#e4e4e7",
    "external":    "fill:#18181b,stroke:#52525b,color:#a1a1aa,stroke-dasharray:2 2",
}


def mermaid_id(nid):
    return re.sub(r"[^A-Za-z0-9]", "_", nid)


def esc(text, limit=48):
    if len(text) > limit:
        text = text[: limit - 1] + "…"
    return text.replace('"', "#quot;")  # mermaid's own entity escape — truncate FIRST


def render_mermaid(g):
    by_id = {n["id"]: n for n in g["nodes"]}
    sub_children = {}
    for e in g["edges"]:
        if e["type"] == "sub":
            sub_children.setdefault(e["from"], []).append(e["to"])
    out = ["flowchart TD"]
    buckets = [n["id"] for n in g["nodes"] if n["status"] == "bucket"]
    in_bucket = {c for b in buckets for c in sub_children.get(b, [])}

    def node_line(n, indent="    "):
        # shape is the secondary encoding beside color: open work = stadium, settled = rect,
        # the goal itself = subroutine box — state must never be color-alone
        label = f'"#{n["number"]} {esc(n["title"])}"'
        if n["status"] == "goal":
            shape = f"[[{label}]]"
        elif n["status"] in ("closed", "closed-skip", "bucket"):
            shape = f"[{label}]"
        else:
            shape = f"([{label}])"
        return f'{indent}{mermaid_id(n["id"])}{shape}:::{n["status"].replace("-", "_")}'

    for n in g["nodes"]:
        if n["id"] in in_bucket or n["status"] == "bucket":
            continue
        out.append(node_line(n))
    for b in buckets:
        bn = by_id[b]
        out.append(f'    subgraph B_{mermaid_id(b)}["#{bn["number"]} {esc(bn["title"], 60)}"]')
        for c in sorted(sub_children.get(b, []), key=lambda i: by_id[i]["number"]):
            out.append(node_line(by_id[c], "        "))
        out.append("    end")
    for e in g["edges"]:
        f, t = mermaid_id(e["from"]), mermaid_id(e["to"])
        if e["type"] == "sub":
            if e["from"] in buckets:
                continue  # containment already drawn as the subgraph box
            t2 = f"B_{t}" if e["to"] in buckets else t
            out.append(f"    {f} --> {t2}")
        elif e["type"] == "blocked_by":
            out.append(f"    {f} -. blocks .-> {t}")
        # harvest (provenance) edges deliberately NOT drawn here: this view is what the
        # goal MACHINERY sees (containment + gating deps); --view derivation draws them
    # grid-wrap wide sibling generations with invisible links — 46 edge-less bucket children
    # would otherwise share one rank and render a ~15000px-wide row (the GitHub-UI mess)
    cols = 4
    for parent, children in sub_children.items():
        kids = sorted(children, key=lambda i: by_id[i]["number"])
        for i in range(cols, len(kids)):
            out.append(f"    {mermaid_id(kids[i - cols])} ~~~ {mermaid_id(kids[i])}")
    for name, style in MERMAID_CLASSES.items():
        out.append(f'    classDef {name.replace("-", "_")} {style}')
    return "\n".join(out) + "\n"


def render_derivation(g):
    """The TRUE lineage view: structural parent = the harvest-provenance origin where one
    parses, native parent otherwise (goal children; unparsed sprouts fall back to the goal
    with a dotted edge, never a guessed origin). The bucket container is dropped — it is
    filing, not derivation. LR: ranks are generations."""
    by_id = {n["id"]: n for n in g["nodes"]}
    harvest = {}
    for e in g["edges"]:
        if e["type"] == "harvest" and e["from"] in by_id:
            harvest.setdefault(e["to"], []).append(e)
    buckets = {n["id"] for n in g["nodes"] if n["status"] == "bucket"}
    native_parent = {e["to"]: e["from"] for e in g["edges"] if e["type"] == "sub"}
    out = ["flowchart LR"]
    for n in g["nodes"]:
        if n["id"] in buckets:
            continue
        label = f'"#{n["number"]} {esc(n["title"], 40)}"'
        if n["repo"] != g["root"].split("#")[0]:
            label = f'"{n["repo"].split("/")[-1]}#{n["number"]} {esc(n["title"], 34)}"'
        shape = f"[[{label}]]" if n["status"] == "goal" else (
            f"[{label}]" if n["status"].startswith("closed") else f"([{label}])")
        out.append(f'    {mermaid_id(n["id"])}{shape}:::{n["status"].replace("-", "_")}')
    root = g["root"]
    for n in g["nodes"]:
        nid = n["id"]
        if nid == root or nid in buckets:
            continue
        if nid in harvest:
            for e in harvest[nid]:
                via = f"|PR#{e['via_pr']}|" if e.get("via_pr") else ""
                arrow = "-->" if e["kind"] in ("harvest", "pr-body-finding") else "-.->"
                out.append(f"    {mermaid_id(e['from'])} {arrow}{via} {mermaid_id(nid)}")
        else:
            p = native_parent.get(nid)
            if p in buckets:  # filed into the bucket, origin unparsed — honest fallback
                out.append(f"    {mermaid_id(root)} -. origin unparsed .-> {mermaid_id(nid)}")
            elif p:
                out.append(f"    {mermaid_id(p)} --> {mermaid_id(nid)}")
    for e in g["edges"]:
        if e["type"] == "blocked_by":
            out.append(f"    {mermaid_id(e['from'])} -. blocks .-> {mermaid_id(e['to'])}")
    for name, style in MERMAID_CLASSES.items():
        out.append(f'    classDef {name.replace("-", "_")} {style}')
    return "\n".join(out) + "\n"


def render_dot(g):
    by_id = {n["id"]: n for n in g["nodes"]}
    colors = {
        "goal": "purple", "bucket": "steelblue", "closed": "darkgreen",
        "closed-skip": "gray50", "queued": "goldenrod", "riding": "darkorange",
        "blocked": "red3", "error": "red", "inert": "gray30", "external": "gray70",
    }
    out = ["digraph goal {", '  rankdir=TB; node [shape=box, style=filled, fontcolor=white];']
    for n in g["nodes"]:
        out.append(
            f'  "{n["id"]}" [label="#{n["number"]}\\n{esc(n["title"], 40)}", '
            f'fillcolor={colors.get(n["status"], "gray30")}];'
        )
    for e in g["edges"]:
        style = "" if e["type"] == "sub" else ' [style=dashed, label="blocks"]'
        out.append(f'  "{e["from"]}" -> "{e["to"]}"{style};')
    out.append("}")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fetch", help="walk the live tree, write canonical JSON")
    f.add_argument("repo", help="OWNER/REPO")
    f.add_argument("number", type=int, help="the goal issue number")
    f.add_argument("-o", "--out", default="-", help="output file (default stdout)")
    f.add_argument("--no-deps", action="store_true", help="skip blocked_by edges (fewer API calls)")
    r = sub.add_parser("render", help="render a fetched JSON file")
    r.add_argument("file")
    r.add_argument("--format", choices=["mermaid", "dot"], default="mermaid")
    r.add_argument("--view", choices=["containment", "derivation"], default="containment",
                   help="containment = the native tree (bucket as a box); "
                        "derivation = provenance origins as parents, bucket dropped")
    args = ap.parse_args()

    if args.cmd == "fetch":
        g = fetch(args.repo, args.number, with_deps=not args.no_deps)
        text = json.dumps(g, indent=2, sort_keys=True) + "\n"
        if args.out == "-":
            sys.stdout.write(text)
        else:
            with open(args.out, "w") as fh:
                fh.write(text)
            counts = {}
            for n in g["nodes"]:
                counts[n["status"]] = counts.get(n["status"], 0) + 1
            print(f"→ {args.out}: {len(g['nodes'])} nodes, {len(g['edges'])} edges "
                  f"({', '.join(f'{k}={v}' for k, v in sorted(counts.items()))})",
                  file=sys.stderr)
    else:
        with open(args.file) as fh:
            g = json.load(fh)
        if args.view == "derivation":
            if args.format == "dot":
                sys.exit("derivation view is mermaid-only for now")
            sys.stdout.write(render_derivation(g))
        else:
            sys.stdout.write(render_mermaid(g) if args.format == "mermaid" else render_dot(g))


if __name__ == "__main__":
    main()
