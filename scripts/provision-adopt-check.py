#!/usr/bin/env python3
"""provision-adopt-check — does a repos[].provision entry describe EXACTLY what a legacy Workspace declares?

ADR-169 migration (docs/stack-workspace-migration.md): an entry with `adopt` runs the Composition's
fixed Terraform in the legacy Workspace's state. If the two modules differ in any resource, data
source, attribute or output, the first `manage` reconcile changes live infrastructure (a replaced
password, a renamed key, a dropped grant). This compares the two modules as Terraform sees them:
same blocks by (type, name), same attribute values, same outputs and sensitivity. It ignores comments,
layout, attribute order, `import` blocks (already applied to the state) and `variable` blocks (a
`var.x` reference is replaced by the Workspace's `vars` value, as provider-terraform passes it).

The live `observe` mode is the second, authoritative check (the plan itself); this one runs first
because it needs no reconcile and names the differing attribute.

  provision-adopt-check.py --legacy A.tf --composed B.tf [--var k=v ...]   two module files
  provision-adopt-check.py --live LEGACY_WS COMPOSED_WS                    read both from the cluster
                                                                           (kubectl, spec only — no Secret)
Exit 0 equivalent · 1 they differ (the differences are printed) · 2 usage / parse error.
"""
import json
import re
import subprocess
import sys

TOKEN = re.compile(r'"(?:[^"\\]|\\.)*"|[{}\[\]=,]|[A-Za-z0-9_.\-\[\]"]+')
IGNORED_BLOCKS = {"import", "variable", "terraform", "moved"}
LABELS = {"resource": 2, "data": 2, "output": 1, "variable": 1, "module": 1, "provider": 1}


class ParseError(Exception):
    pass


def tokenize(src):
    out = []
    for line in src.splitlines():
        # strip a comment: '#' or '//' outside a string
        buf, in_str, i = [], False, 0
        while i < len(line):
            c = line[i]
            if c == '"' and (i == 0 or line[i - 1] != "\\"):
                in_str = not in_str
            if not in_str and (c == "#" or line.startswith("//", i)):
                break
            buf.append(c)
            i += 1
        out += TOKEN.findall("".join(buf))
    return out


def parse_value(toks, i):
    t = toks[i]
    if t == "{":
        body, i = parse_body(toks, i + 1)
        return ("obj", body), i
    if t.startswith('"'):
        return ("str", json.loads(t)), i + 1
    if re.fullmatch(r"-?[0-9]+", t):
        return ("num", int(t)), i + 1
    if t in ("true", "false"):
        return ("bool", t == "true"), i + 1
    if t == "null":
        return ("null", None), i + 1
    return ("ref", t), i + 1


def parse_body(toks, i):
    """Parse statements until the matching '}' (or EOF at top level). Returns (dict, next_index)."""
    body = {}
    while i < len(toks):
        t = toks[i]
        if t == "}":
            return body, i + 1
        if t == ",":
            i += 1
            continue
        if i + 1 < len(toks) and toks[i + 1] == "=":
            val, i = parse_value(toks, i + 2)
            body[("attr", t)] = val
            continue
        # a block: IDENT LABEL* {
        kind, j, labels = t, i + 1, []
        while j < len(toks) and toks[j] != "{":
            if not toks[j].startswith('"'):
                raise ParseError(f"unexpected token {toks[j]!r} after {kind!r}")
            labels.append(json.loads(toks[j]))
            j += 1
        if j >= len(toks):
            raise ParseError(f"unterminated block {kind} {labels}")
        inner, i = parse_body(toks, j + 1)
        key = ("block", kind, tuple(labels))
        if kind in IGNORED_BLOCKS:
            key += (len(body),)  # import blocks repeat; they are dropped below anyway
        elif key in body:
            raise ParseError(f"duplicate block {kind} {labels}")
        body[key] = inner
    return body, i


def normalize(src, variables):
    toks = tokenize(src)
    body, i = parse_body(toks, 0)
    if i < len(toks):
        raise ParseError("unbalanced '}'")

    def subst(v):
        kind, val = v
        if kind == "ref" and val.startswith("var."):
            name = val[4:]
            if name not in variables:
                raise ParseError(f"{val} has no value (pass --var {name}=…)")
            return ("str", variables[name])
        if kind == "obj":
            return ("obj", {k: subst(x) if k[0] == "attr" else x for k, x in val.items()})
        return v

    out = {}
    for key, inner in body.items():
        if key[0] != "block" or key[1] in IGNORED_BLOCKS:
            continue
        flat = {}
        for k, v in inner.items():
            if k[0] == "attr":
                flat[k[1]] = subst(v)
            else:  # nested block (lifecycle)
                flat[f"{k[1]}{list(k[2]) or ''}"] = ("obj", {kk: subst(vv) for kk, vv in v.items() if kk[0] == "attr"})
        out[f'{key[1]} {".".join(key[2])}'] = flat
    return out


def show(v):
    kind, val = v
    if kind == "obj":
        return "{" + ", ".join(f"{k[1]}={show(x)}" for k, x in sorted(val.items())) + "}"
    return json.dumps(val) if kind in ("str", "num", "bool", "null") else val


def compare(legacy, composed):
    diffs = []
    for name in sorted(set(legacy) | set(composed)):
        if name not in composed:
            diffs.append(f"- {name}: in the legacy module only (the composed plan would DESTROY it)")
            continue
        if name not in legacy:
            diffs.append(f"+ {name}: in the composed module only (the composed plan would CREATE it)")
            continue
        a, b = legacy[name], composed[name]
        for attr in sorted(set(a) | set(b)):
            if attr == "sensitive" and name.startswith("output "):
                av, bv = a.get(attr, ("bool", False)), b.get(attr, ("bool", False))
            else:
                av, bv = a.get(attr), b.get(attr)
            if av != bv:
                diffs.append(f"~ {name}.{attr}: legacy {show(av) if av else '(unset)'} != composed {show(bv) if bv else '(unset)'}")
    return diffs


def live(ws):
    raw = subprocess.run(["kubectl", "get", "workspaces.tf.upbound.io", ws, "-o", "json"],
                         check=True, capture_output=True, text=True).stdout
    spec = json.loads(raw)["spec"]["forProvider"]
    return spec.get("module", ""), {v["key"]: v["value"] for v in spec.get("vars") or []}


def main(argv):
    variables, legacy_src, composed_src = {}, None, None
    args = list(argv)
    try:
        while args:
            a = args.pop(0)
            if a == "--legacy":
                legacy_src = open(args.pop(0)).read()
            elif a == "--composed":
                composed_src = open(args.pop(0)).read()
            elif a == "--var":
                k, _, v = args.pop(0).partition("=")
                variables[k] = v
            elif a == "--live":
                lw, cw = args.pop(0), args.pop(0)
                legacy_src, variables = live(lw)
                composed_src, cvars = live(cw)
                if cvars:
                    print(f"provision-adopt-check: {cw} carries vars {sorted(cvars)}; a composed module never should", file=sys.stderr)
                    return 2
            else:
                print(__doc__, file=sys.stderr)
                return 2
    except (IndexError, OSError, subprocess.CalledProcessError) as e:
        print(f"provision-adopt-check: {e}", file=sys.stderr)
        return 2
    if legacy_src is None or composed_src is None:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        diffs = compare(normalize(legacy_src, variables), normalize(composed_src, {}))
    except ParseError as e:
        print(f"provision-adopt-check: parse error: {e}", file=sys.stderr)
        return 2
    if diffs:
        print("provision-adopt-check: the modules DIFFER — adopting would change live infrastructure:")
        print("\n".join("  " + d for d in diffs))
        return 1
    print("provision-adopt-check: equivalent (same blocks, attributes and outputs)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
