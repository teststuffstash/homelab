"""The island's fake `gh`: serves ONE recorded world to a component run as a process (goal #3490 pins 5, 6).

Put first on PATH by `tests/world.py` (never run by hand). It reads the serving plan the helper
wrote (`$FAKE_GH_PLAN`: the world dir, its reads, its writes, the case's faults) and appends one
JSON line per call to `$FAKE_GH_LOG`.

- A read the world holds is answered with its file's bytes (`--jq` applied over them, as gh does).
- A read the world does not hold exits 2 and names the read; the helper fails the case.
- A write is never performed: it is answered by the world's hand-written answer for its operation
  (`writes/<op>.<status>.json`, printed as gh prints a response body), or by an exit status for a
  gh command that prints no JSON. A write the world declares no operation for exits 2, as a read.
- A fault the case injected on one call replaces that call's answer: a failing call, a non-JSON
  body, the answer with one named field absent, or a write answering a hand-written error.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

UNRECORDED = 2


def strip_jq(argv: list[str]) -> tuple[list[str], str | None]:
    out, jq, it = [], None, iter(argv)
    for a in it:
        if a in ("--jq", "-q"):
            jq = next(it, "")
        elif a.startswith("--jq="):
            jq = a.removeprefix("--jq=")
        else:
            out.append(a)
    return out, jq


def api_method(argv: list[str]) -> str:
    method, prev = "", ""
    for a in argv:
        if prev in ("-X", "--method"):
            method = a.upper()
        elif a.startswith("--method="):
            method = a.removeprefix("--method=").upper()
        elif a.startswith("-X") and len(a) > 2:
            method = a[2:].upper()
        prev = a
    if method:
        return method
    return "POST" if any(a in ("-f", "-F", "--field", "--raw-field", "--input") for a in argv) else "GET"


def api_path(argv: list[str]) -> str:
    """The first positional after `api` that is not an option or an option's value."""
    takes_value = {"-X", "--method", "-f", "-F", "--field", "--raw-field", "--input", "-H", "--header", "-q", "--jq", "-t", "--template"}
    it = iter(argv[1:])
    for a in it:
        if a in takes_value:
            next(it, None)
        elif not a.startswith("-"):
            return a
    return ""


def template_re(template: str) -> re.Pattern[str]:
    return re.compile("^" + "/".join("[^/]+" if re.fullmatch(r"\{[a-z_]+\}", p) else re.escape(p) for p in template.split("/")) + "$")


def write_op(plan: dict, argv: list[str]) -> dict | None:
    """The world's declared write this call is, or None. `gh pr merge … --auto` and REST writes."""
    for w in plan["writes"]:
        if w["method"] == "gh":
            if re.fullmatch(template_re(w["path"].replace(" ", "/")).pattern, "/".join(argv)):
                return w
        elif argv[:1] == ["api"] and w["method"] == api_method(argv) and not w.get("after"):
            if template_re(w["path"]).match(api_path(argv).partition("?")[0]):
                return w
    return None


def is_write(argv: list[str]) -> bool:
    if argv[:1] == ["api"]:
        return api_method(argv) != "GET"
    return argv[:2] not in (["pr", "view"], ["pr", "list"], ["issue", "view"], ["issue", "list"], ["pr", "checks"])


def drop(data: object, path: list) -> object:
    node = data
    for k in path[:-1]:
        node = node[k]
    del node[path[-1]]
    return data


def emit(body: bytes, jq: str | None) -> int:
    if jq is None:
        sys.stdout.buffer.write(body)
        return 0
    p = subprocess.run(["jq", "-r", jq], input=body, capture_output=True, check=False)
    sys.stdout.buffer.write(p.stdout)
    sys.stderr.buffer.write(p.stderr)
    return 1 if p.returncode else 0


def main(argv: list[str]) -> int:
    plan = json.loads(Path(os.environ["FAKE_GH_PLAN"]).read_text())
    world = Path(plan["world"])
    log_path = Path(os.environ["FAKE_GH_LOG"])
    prior = [json.loads(line) for line in log_path.read_text().splitlines()] if log_path.exists() else []
    key, jq = strip_jq(argv)
    entry: dict = {"argv": argv}

    def finish(rc: int) -> int:
        entry["rc"] = rc
        with log_path.open("a") as f:
            f.write(json.dumps(entry) + "\n")
        return rc

    if is_write(key):
        w = write_op(plan, key)
        if w is None:
            entry.update(kind="write", unrecorded=True)
            print(f"fake gh: unrecorded write — the world declares no operation for: gh {' '.join(argv)}", file=sys.stderr)
            return finish(UNRECORDED)
        entry.update(kind="write", op=w["op"])
        target = w["op"]
    else:
        entry["kind"] = "read"
        served = None
        if key[:1] == ["api"] and api_method(key) == "GET":
            done = {e.get("op") for e in prior if e.get("kind") == "write" and e.get("rc") == 0}
            for w in plan["writes"]:
                if w.get("after") in done and template_re(w["path"]).match(api_path(key).partition("?")[0]):
                    served = f"writes/{w['op']}.{w['statuses'][0]}.json"
        if served is None:
            served = next((r["file"] for r in plan["reads"] if r["argv"] == key), None)
        if served is None:
            entry["unrecorded"] = True
            print(f"fake gh: unrecorded read — the world holds no answer for: gh {' '.join(key)}", file=sys.stderr)
            return finish(UNRECORDED)
        entry["file"] = served
        target = served

    occurrence = 1 + sum(1 for e in prior if e.get("op", e.get("file")) == target)
    fault = next((f for f in plan["faults"] if f["target"] == target and f["occurrence"] == occurrence), None)
    if fault:
        entry["fault"] = fault["kind"]

    if entry["kind"] == "write":
        if fault and fault["kind"] == "status":
            body = (world / "writes" / f"{w['op']}.{fault['status']}.json").read_bytes()
            sys.stdout.buffer.write(body)
            print(f"gh: {json.loads(body).get('message', '')} (HTTP {fault['status']})", file=sys.stderr)
            return finish(1)
        if fault and fault["kind"] == "fail":
            print("gh: Bad Gateway (HTTP 502)", file=sys.stderr)
            return finish(1)
        if w["method"] == "gh":
            return finish(int(w["exit"]))
        return finish(emit((world / "writes" / f"{w['op']}.{w['statuses'][0]}.json").read_bytes(), jq))

    body = (world / served).read_bytes()
    if fault:
        if fault["kind"] == "fail":
            print("gh: Bad Gateway (HTTP 502)", file=sys.stderr)
            return finish(1)
        if fault["kind"] == "non-json":
            sys.stdout.write("upstream connect error or disconnect/reset before headers\n")
            return finish(0)
        if fault["kind"] == "absent":
            body = json.dumps(drop(json.loads(body), fault["field"]), ensure_ascii=False, separators=(",", ":")).encode() + b"\n"
    return finish(emit(body, jq))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
