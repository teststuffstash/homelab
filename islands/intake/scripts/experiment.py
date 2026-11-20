#!/usr/bin/env python3
"""experiment — load the `## Experiment` section of an issue body (homelab#3586 pins 1, 2 and 5; child #3602).

An issue carries at most one experiment: the heading `## Experiment`, at least one non-blank prose line (the
claim in plain words), then exactly one fenced block whose info string is `experiment`, holding one JSON
object. The format is not this island's own: it is taken unchanged, with no added key, from the stack that
defines it (pin 1) — an unknown key at any level is refused, so two loaders cannot drift apart silently:

  id                 non-empty string
  requirement        non-empty string (carried, never run)
  cases              array (carried, never run — the platform read decides the kpi only)
  kpi                object, required by this loader:
    query              string containing $window
    pass               one of < <= > >=, one space, a number
    baseline           number
    min_window         a whole number followed by m, h or d
    max_window         the same;  min_window <= max_window <= 7d
    min_samples_query  string containing $window
    min_samples        positive integer
    guards             optional array of {"id", "query" (with $window), "pass"}, ids unique

A body that states it has no experiment carries the one line `Experiment: none — <why>` instead.

  python3 -I islands/intake/scripts/experiment.py load [--check] <file|->
  python3 -I islands/intake/scripts/experiment.py --self-test

`load` exits:
  0  a valid section — stdout is one JSON object: the block, with `kpi.min_window_s` / `kpi.max_window_s`
     (the durations in seconds) and `kpi.pass_op` / `kpi.pass_value` (`pass` split; the same two keys on
     every guard) added
  2  a malformed section — stderr `experiment: malformed — <the first fault>`
  3  no block and the line `Experiment: none — <why>` — stderr `experiment: none — <why>`
  4  neither — stderr `experiment: absent — …`
  1  the file cannot be read;  64  a usage error
`--check` prints nothing on either stream and only exits.

As a module (the read that decides a verdict imports it): `load_body(text)` → `(status, value)` with status
`ok` (value: the output object), `none` (value: the reason), `absent` or `malformed` (value: the message);
`EXIT[status]` is the exit code. `validate(block)` → the output object, raising `Malformed`.
"""
import argparse
import contextlib
import io
import json
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
FIXTURES = os.path.join(ROOT, "islands", "intake", "tests", "fixtures", "experiment")

EXIT = {"ok": 0, "malformed": 2, "none": 3, "absent": 4}
EXIT_UNREADABLE = 1
EXIT_USAGE = 64

HEADING = "## Experiment"
INFO = "experiment"
MAX_WINDOW_S = 7 * 86400
UNIT_S = {"m": 60, "h": 3600, "d": 86400}

TOP_KEYS = ("id", "requirement", "cases", "kpi")
KPI_KEYS = ("query", "pass", "baseline", "min_window", "max_window", "min_samples_query", "min_samples")
KPI_OPT = ("guards",)
GUARD_KEYS = ("id", "query", "pass")

FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
SECTION_END = re.compile(r"^#{1,2}(\s|$)")
NONE_LINE = re.compile(r"^Experiment:\s*none\b(.*)$")
NONE_REASON = re.compile(r"^ — (\S.*)$")
# matched with fullmatch, ASCII digits only: "7d\n" and a non-ASCII digit int() would convert are both refused
PASS = re.compile(r"(<=|>=|<|>) (-?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)", re.ASCII)
DURATION = re.compile(r"([0-9]+)([mhd])", re.ASCII)
ABSENT = 'no "## Experiment" section and no "Experiment: none — <why>" line'


class Malformed(Exception):
    """The body's experiment is malformed; str() is the first fault."""


# ── the block ────────────────────────────────────────────────────────────────────────────────────────
def duration_s(value, where):
    """'7d' → 604800. A whole number of minutes, hours or days, greater than zero."""
    m = DURATION.fullmatch(value) if isinstance(value, str) else None
    if not m or int(m.group(1)) == 0:
        raise Malformed(f"{where} {json.dumps(value)} is not a whole number followed by m, h or d")
    return int(m.group(1)) * UNIT_S[m.group(2)]


def split_pass(value, where):
    """'<= 0' → ('<=', 0.0)."""
    m = PASS.fullmatch(value) if isinstance(value, str) else None
    if not m:
        raise Malformed(f"{where} {json.dumps(value)} is not one of < <= > >=, a space, a number")
    number = float(m.group(2))
    if not math.isfinite(number):
        raise Malformed(f"{where} {json.dumps(value)} holds a number too large to read")
    return m.group(1), number


def _is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def _keys(obj, where, required, optional=()):
    if not isinstance(obj, dict):
        raise Malformed(f"{where} is not an object")
    for k in obj:
        if k not in required and k not in optional:
            raise Malformed(f"unknown key {where}.{k}" if where != "the block" else f"unknown key {k}")
    for k in required:
        if k not in obj:
            raise Malformed(f"missing key {where}.{k}" if where != "the block" else f"missing key {k}")


def _nonempty(v, where):
    if not isinstance(v, str) or not v.strip():
        raise Malformed(f"{where} is not a non-empty string")


def _query(v, where):
    if not isinstance(v, str) or "$window" not in v:
        raise Malformed(f"{where} is not a string containing $window")


def validate(block):
    """The parsed block → the output object (a copy with the derived keys). Raises Malformed on the first fault."""
    _keys(block, "the block", TOP_KEYS)
    _nonempty(block["id"], "id")
    _nonempty(block["requirement"], "requirement")
    if not isinstance(block["cases"], list):
        raise Malformed("cases is not an array")
    kpi = block["kpi"]
    _keys(kpi, "kpi", KPI_KEYS, KPI_OPT)
    _query(kpi["query"], "kpi.query")
    op, val = split_pass(kpi["pass"], "kpi.pass")
    if not _is_number(kpi["baseline"]):
        raise Malformed("kpi.baseline is not a number")
    lo = duration_s(kpi["min_window"], "kpi.min_window")
    hi = duration_s(kpi["max_window"], "kpi.max_window")
    if lo > hi:
        raise Malformed(f"kpi.min_window {kpi['min_window']} is longer than kpi.max_window {kpi['max_window']}")
    if hi > MAX_WINDOW_S:
        raise Malformed(f"kpi.max_window {kpi['max_window']} is longer than 7d")
    _query(kpi["min_samples_query"], "kpi.min_samples_query")
    if not isinstance(kpi["min_samples"], int) or isinstance(kpi["min_samples"], bool) or kpi["min_samples"] < 1:
        raise Malformed("kpi.min_samples is not a positive integer")
    out_kpi = dict(kpi, min_window_s=lo, max_window_s=hi, pass_op=op, pass_value=val)
    if "guards" in kpi:
        if not isinstance(kpi["guards"], list):
            raise Malformed("kpi.guards is not an array")
        seen, guards = set(), []
        for i, g in enumerate(kpi["guards"]):
            where = f"kpi.guards[{i}]"
            _keys(g, where, GUARD_KEYS)
            _nonempty(g["id"], f"{where}.id")
            if g["id"] in seen:
                raise Malformed(f"{where}.id {json.dumps(g['id'])} is not unique")
            seen.add(g["id"])
            _query(g["query"], f"{where}.query")
            g_op, g_val = split_pass(g["pass"], f"{where}.pass")
            guards.append(dict(g, pass_op=g_op, pass_value=g_val))
        out_kpi["guards"] = guards
    return dict(block, kpi=out_kpi)


def _pairs(pairs):
    d = {}
    for k, v in pairs:
        if k in d:
            raise Malformed(f"the block repeats the key {json.dumps(k)}")
        d[k] = v
    return d


def _constant(name):
    raise Malformed(f"the block holds {name}, which is not a JSON number")


def _float(token):
    # json.loads turns an overflowing token (1e999) into inf without calling parse_constant
    number = float(token)
    if not math.isfinite(number):
        raise Malformed(f"the block holds {token}, a number too large to read")
    return number


def parse_block(text):
    """The fenced block's text → the parsed JSON object. Raises Malformed."""
    try:
        block = json.loads(text, object_pairs_hook=_pairs, parse_constant=_constant, parse_float=_float)
    except json.JSONDecodeError as e:
        raise Malformed(f"the block is not one JSON value (line {e.lineno} column {e.colno} of the block)") from None
    if not isinstance(block, dict):
        raise Malformed("the block is not one JSON object")
    return block


# ── the body ─────────────────────────────────────────────────────────────────────────────────────────
def scan(text):
    """One pass over the body, fences respected → (headings, blocks, nones).

    headings  line indexes of `## Experiment`
    blocks    [(open line index, text, closed)] for every fence whose info string is `experiment`
    nones     [(line index, rest of the line after `Experiment: none`)]
    sections  {heading index: [(line index, kind)]} with kind `prose`, `block` (the experiment fence) or `fence`
              (any other fenced block — it is not prose: a code fence alone before the block does not make
              the claim), to the next `#`/`##` heading
    """
    headings, blocks, nones, sections = [], [], [], {}
    fence = None  # (marker char, length, is_experiment, open index, lines)
    current = None
    for i, line in enumerate(text.splitlines()):
        if fence:
            m = FENCE.match(line)
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= fence[1] and not m.group(2).strip():
                if fence[2]:
                    blocks.append((fence[3], "\n".join(fence[4]), True))
                fence = None
            else:
                fence[4].append(line)
            continue
        m = FENCE.match(line)
        if m:
            is_exp = m.group(2).strip() == INFO
            fence = (m.group(1)[0], len(m.group(1)), is_exp, i, [])
            if current is not None:
                sections[current].append((i, "block" if is_exp else "fence"))
            continue
        if SECTION_END.match(line):
            current = None
            if line.rstrip() == HEADING:
                headings.append(i)
                current = i
                sections[i] = []
            continue
        m = NONE_LINE.match(line)
        if m:
            nones.append((i, m.group(1).rstrip()))
        elif current is not None and line.strip():
            sections[current].append((i, "prose"))
    if fence and fence[2]:
        blocks.append((fence[3], "\n".join(fence[4]), False))
    return headings, blocks, nones, sections


def load_body(text):
    """An issue body → (status, value): ok → the output object; none → the reason; absent / malformed → the message."""
    try:
        headings, blocks, nones, sections = scan(text)
        if len(nones) > 1:
            raise Malformed('more than one "Experiment: none" line')
        reason = None
        if nones:
            m = NONE_REASON.match(nones[0][1])
            if not m:
                raise Malformed('the "Experiment: none" line gives no reason (want "Experiment: none — <why>")')
            reason = m.group(1)
        if len(headings) > 1:
            raise Malformed('more than one "## Experiment" section')
        if blocks and reason is not None:
            raise Malformed('both an experiment block and an "Experiment: none" line')
        if len(blocks) > 1:
            raise Malformed(f"{len(blocks)} experiment blocks (want exactly one)")
        if reason is not None:
            return "none", reason
        if not headings:
            if blocks:
                raise Malformed('an experiment block outside a "## Experiment" section')
            return "absent", ABSENT
        parts = sections[headings[0]]
        if not blocks:
            raise Malformed('the "## Experiment" section holds no experiment block')
        at = blocks[0][0]
        if (at, "block") not in parts:
            raise Malformed('the experiment block is outside the "## Experiment" section')
        if not any(kind == "prose" and i < at for i, kind in parts):
            raise Malformed("the experiment block comes before any prose line")
        if not blocks[0][2]:
            raise Malformed("the experiment block's fence is never closed")
        return "ok", validate(parse_block(blocks[0][1]))
    except Malformed as e:
        return "malformed", str(e)


# ── the command ──────────────────────────────────────────────────────────────────────────────────────
class _Parser(argparse.ArgumentParser):
    def error(self, message):  # 2 means "malformed section" here; a usage error must not look like one
        self.print_usage(sys.stderr)
        self.exit(EXIT_USAGE, f"{self.prog}: error: {message}\n")


def main(argv=None):
    ap = _Parser(description=__doc__.split("\n")[0])
    ap.add_argument("--self-test", action="store_true")
    sub = ap.add_subparsers(dest="cmd", parser_class=_Parser)
    ld = sub.add_parser("load", help="print the body's experiment as validated JSON")
    ld.add_argument("--check", action="store_true", help="print nothing, only exit")
    ld.add_argument("body", help="a file holding an issue body, or - for stdin")
    a = ap.parse_args(argv)
    if a.self_test:
        return self_test()
    if a.cmd != "load":
        ap.error("want: load [--check] <file|->, or --self-test")
    try:
        if a.body == "-":
            text = sys.stdin.read()
        else:
            with open(a.body, encoding="utf-8") as fh:
                text = fh.read()
    except (OSError, UnicodeDecodeError) as e:
        if not a.check:
            print(f"experiment: cannot read {a.body}: {e}", file=sys.stderr)
        return EXIT_UNREADABLE
    status, value = load_body(text)
    if a.check:
        return EXIT[status]
    if status == "ok":
        print(json.dumps(value, ensure_ascii=False, sort_keys=True, allow_nan=False))
    else:
        print(f"experiment: {status} — {value}", file=sys.stderr)
    return EXIT[status]


# ── self-test: the real command over the fixture bodies; expected.json is written by hand ────────────
def self_test(fixtures=FIXTURES):
    fails = []

    def check(name, cond, got=""):
        print(("ok    " if cond else "FAIL  ") + name + ("" if cond else f"  → {got}"))
        if not cond:
            fails.append(name)

    def run(args, stdin=None):
        out, err, old = io.StringIO(), io.StringIO(), sys.stdin
        if stdin is not None:
            sys.stdin = io.StringIO(stdin)
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                try:
                    rc = main(args)
                except SystemExit as e:
                    rc = e.code
        finally:
            sys.stdin = old
        return rc, out.getvalue(), err.getvalue()

    with open(os.path.join(fixtures, "expected.json"), encoding="utf-8") as fh:
        expected = json.load(fh)
    have = {f for f in os.listdir(fixtures) if f.endswith(".md")}
    check("every fixture body has an expected row, every row a body", have == set(expected),
          sorted(have ^ set(expected)))
    exits = {e["exit"] for e in expected.values()}
    check("the fixtures cover every exit: 0, 2, 3, 4", exits == {0, 2, 3, 4}, sorted(exits))
    check("a fixture carries guards", any(e["exit"] == 0 and "guards" in e["out"]["kpi"] for e in expected.values()))
    for name in sorted(have & set(expected)):
        exp, path = expected[name], os.path.join(fixtures, name)
        rc, out, err = run(["load", path])
        check(f"{name}: exit {exp['exit']}", rc == exp["exit"], f"exit {rc}: {err.strip()}")
        if exp["exit"] == 0:
            try:
                got = json.loads(out)
            except ValueError:
                got = out
            check(f"{name}: stdout is the expected object", got == exp["out"] and out.count("\n") == 1, out.strip())
            check(f"{name}: nothing on stderr", err == "", err.strip())
        else:
            check(f"{name}: nothing on stdout", out == "", out.strip())
            lines = err.splitlines()
            check(f"{name}: one stderr line", len(lines) == 1, err.strip())
            if exp["exit"] == 2:
                want = "experiment: malformed — " + exp["fault"]
            elif exp["exit"] == 3:
                want = "experiment: none — " + exp["reason"]
            else:
                want = "experiment: absent — " + ABSENT
            check(f"{name}: stderr says {want!r}", lines[:1] == [want], err.strip())
        rc2, out2, err2 = run(["load", "--check", path])
        check(f"{name}: --check exits {exp['exit']} and prints nothing", (rc2, out2, err2) == (exp["exit"], "", ""),
              (rc2, out2, err2))
        with open(path, encoding="utf-8") as fh:
            rc3, out3, _ = run(["load", "-"], stdin=fh.read())
        check(f"{name}: the same from stdin", (rc3, out3) == (rc, out), (rc3, out3))
    rc, out, err = run(["load", os.path.join(fixtures, "no-such-body.md")])
    check("an unreadable file exits 1, not a verdict on the body", rc == EXIT_UNREADABLE and out == "", (rc, err))
    rc, out, err = run([])
    check("no subcommand is a usage error (64), never 2", rc == EXIT_USAGE and out == "", (rc, err))
    print("experiment self-test: " + ("PASS" if not fails else f"FAIL ({len(fails)})"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
