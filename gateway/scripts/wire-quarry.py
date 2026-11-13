#!/usr/bin/env python3
"""wire-quarry — the loop's hand on the gateway's wire door (specs/endpoints/wire.md §GW-WIRE-QUARRY).

    wire-quarry.py list
    wire-quarry.py show <source>
    wire-quarry.py find --key <name>
    wire-quarry.py cut <source> [--path a.b.c] --out <fixture.json>

Reads `GET /wire` and `GET /wire/<source>` and nothing else: no credential is held or sent, nothing is
written to the door. `cut` writes the chosen fragment of a recorded answer (values and key order as
recorded) plus `<fixture stem>.provenance.json` beside it. Standard library only.

Exit codes: 0 ok · 2 usage · 3 the door is silent · 4 the source is not recorded · 5 the path (or a
JSON body) is not there · 6 the record is truncated (`complete: false`).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

ENV = "WIRE_DOOR_URL"
DEFAULT_DOOR = "http://agent-gateway.agent-egress.svc.cluster.local:8080"
TIMEOUT_S = 15


class Exit(Exception):
    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code, self.message = code, message


def door() -> str:
    return os.environ.get(ENV, DEFAULT_DOOR).rstrip("/")


def get(path: str) -> tuple[int, dict[str, str], bytes]:
    """One GET, no credential. A non-200 other than 404 and any transport fault is `door unreachable`."""
    url = door() + path
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_S) as r:  # noqa: S310 — http(s) door by construction
            return r.status, {k.lower(): v for k, v in r.headers.items()}, r.read()
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return 404, {k.lower(): v for k, v in e.headers.items()}, e.read()
        raise Exit(3, f"door unreachable: {door()} (answered {e.code} for {path})") from e
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise Exit(3, f"door unreachable: {door()}") from e


def index() -> list[dict]:
    status, _, body = get("/wire")
    try:
        return json.loads(body)["sources"] if status == 200 else []
    except (ValueError, KeyError, TypeError) as e:
        raise Exit(3, f"door unreachable: {door()} (no index answered)") from e


def member(source: str) -> tuple[dict[str, str], bytes]:
    status, headers, body = get("/wire/" + source)
    if status == 404:
        raise Exit(4, f"{source} not recorded")
    return headers, body


def provenance_line(headers: dict[str, str]) -> str:
    return (f"wire: source={headers.get('x-wire-source')} class={headers.get('x-wire-class')} "
            f"sha256={headers.get('x-wire-sha256')} fetched_at={headers.get('x-wire-fetched-at')}")


def cmd_list(_: argparse.Namespace) -> int:
    for s in index():
        age = "-" if s.get("age_s") is None else f"{s['age_s']}s"
        status = "no good answer" if s.get("status") is None else str(s["status"])
        print(f"{s['source']}\t{s['class']}\t{status}\t{age}")
    return 0


def cmd_show(a: argparse.Namespace) -> int:
    headers, body = member(a.source)
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()
    print(provenance_line(headers), file=sys.stderr)
    return 0


def walk(node, prefix: str = ""):
    """Every (dotted path, key, value) under a JSON document, in document order."""
    if isinstance(node, dict):
        for k, v in node.items():
            p = f"{prefix}.{k}" if prefix else k
            yield p, k, v
            yield from walk(v, p)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from walk(v, f"{prefix}.{i}" if prefix else str(i))


def cmd_find(a: argparse.Namespace) -> int:
    for s in index():
        if s.get("status") is None:
            continue
        try:
            _, body = member(s["source"])
            doc = json.loads(body)
        except Exit as e:
            if e.code == 4:
                continue
            raise
        except ValueError:
            continue  # a non-JSON member (the Go page) has no key to find; `show` covers it
        for path, key, _v in walk(doc):
            if key == a.key:
                print(f"{s['source']}\t{path}")
    return 0


def resolve(doc, path: str):
    """The value at a dotted path; a key may itself contain dots (`deepseek-v4.1-flash`), so each
    level takes the longest key the rest of the path still resolves through."""
    if path == "":
        return doc
    if isinstance(doc, dict):
        parts = path.split(".")
        for n in range(len(parts), 0, -1):
            key = ".".join(parts[:n])
            if key in doc:
                try:
                    return resolve(doc[key], ".".join(parts[n:]))
                except KeyError:
                    continue
    elif isinstance(doc, list):
        head, _, rest = path.partition(".")
        if head.isdigit() and int(head) < len(doc):
            return resolve(doc[int(head)], rest)
    raise KeyError(path)


def cmd_cut(a: argparse.Namespace) -> int:
    headers, body = member(a.source)
    if headers.get("x-wire-complete") == "false":
        raise Exit(6, f"{a.source} record is truncated (complete: false); nothing cut")
    try:
        doc = json.loads(body)
    except ValueError as e:
        raise Exit(5, f"{a.source} is not JSON; cut --path reads JSON only (use show)") from e
    try:
        fragment = resolve(doc, a.path)
    except KeyError as e:
        raise Exit(5, f"{a.source} has no path {a.path!r}") from e
    meta = next((s for s in index() if s["source"] == a.source), {})
    out = Path(a.out)
    sidecar = out.with_name(out.stem + ".provenance.json")
    prov = {"source": a.source, "class": headers.get("x-wire-class"), "url": meta.get("url"),
            "sha256": headers.get("x-wire-sha256"), "fetched_at": headers.get("x-wire-fetched-at"), "path": a.path}
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(fragment, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    sidecar.write_text(json.dumps(prov, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {out} and {sidecar}", file=sys.stderr)
    return 0


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="wire-quarry.py", description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="verb", required=True)
    sub.add_parser("list").set_defaults(fn=cmd_list)
    s = sub.add_parser("show")
    s.add_argument("source")
    s.set_defaults(fn=cmd_show)
    f = sub.add_parser("find")
    f.add_argument("--key", required=True)
    f.set_defaults(fn=cmd_find)
    c = sub.add_parser("cut")
    c.add_argument("source")
    c.add_argument("--path", default="")
    c.add_argument("--out", required=True)
    c.set_defaults(fn=cmd_cut)
    args = p.parse_args(argv)
    try:
        return args.fn(args)
    except Exit as e:
        print(f"wire: {e.message}", file=sys.stderr)
        return e.code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
