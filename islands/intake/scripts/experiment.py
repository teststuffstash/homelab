#!/usr/bin/env python3
"""experiment — load the `## Experiment` section of an issue body and decide it from Prometheus (homelab#3586
pins 1–5 and 11; children #3602, the loader, and #3603, the verdict and the read).

An issue carries at most one experiment: the heading `## Experiment`, at least one non-blank prose line (the
claim in plain words), then exactly one fenced block whose info string is `experiment`, holding one JSON
object. The format is not this island's own: it is taken unchanged, with no added key, from the stack that
defines it (pin 1) — an unknown key at any level is refused, so two loaders cannot drift apart silently:

  id                 non-empty string
  requirement        non-empty string (carried, never run)
  cases              array (carried, never run — the platform read decides the kpi only)
  kpi                object, required by this loader:
    query              string containing $window (the token: `$windows` is another name and does not count)
    pass               one of < <= > >=, one space, a number
    baseline           number
    min_window         a whole number followed by m, h or d
    max_window         the same;  min_window <= max_window <= 7d
    min_samples_query  string containing $window
    min_samples        positive integer
    guards             optional array of {"id", "query" (with $window), "pass"}, ids unique

A body that states it has no experiment carries the one line `Experiment: none — <why>` instead.

  python3 -I islands/intake/scripts/experiment.py load [--check] <file|->
  python3 -I islands/intake/scripts/experiment.py read --prometheus <url> --since <RFC3339 t0> [--now <RFC3339>] <file|->
  python3 -I islands/intake/scripts/experiment.py at --prometheus <url> --query <promql with $window> --window <dur> --at <RFC3339>
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

The verdict (pins 3, 4, 5). `decide(experiment, t0, now, ask)` is pure: `experiment` is `load`'s object, `t0`
and `now` are whole epoch seconds, and `ask(promql, at)` is the only way it learns a number — a finite float,
`None` for an answer with no sample, `ReadFailed` raised for a read that failed. A failed read raises out of
`decide`; no verdict is returned for it.

  bound    = t0 + max_window;  horizon = min(now - 5 min, bound)
             (the five minutes are the settle time: a window is asked about only once it ended that long
             ago, so that its last scrapes and rule evaluations are in Prometheus — a window read while they
             are still arriving could answer differently a minute later)
  W        = the deciding window: the shortest whole number of minutes, min_window <= W <= horizon - t0, for
             which min_samples_query over W, asked at t0 + W, is >= min_samples (no sample counts as zero)
  no W     → `pending` while now - 5 min < bound, `no data` once the bound has settled
  with W   → query over W at t0 + W: no sample → `no data`; else every guard the same way — a guard with no
             sample, or failing its `pass`, → `fail` with the guard named; else the value against `pass`
  $window  → `<minutes>m`, wherever the token `$window` stands; nothing else in a query is rewritten

W is found by bisection over the whole minutes min_window … max_window (about 14 questions for seven days),
on the assumption that the count does not fall as the window grows. A window that lies past the horizon is
never asked about: it is taken as reaching the floor, and the search ends `pending` if it lands there. So
the questions asked on the way to a W depend on t0 and the block, not on `now`, and a decided verdict reads
the same at every later `now` (a row of the table reads one at its settle instant and again days later). The W returned was always asked about itself and holds the floor, and W − 1
(unless W is min_window) was asked about and does not. Where the count does fall as the window grows, that
is all that is promised: W is such a crossing, not necessarily the first one, and a count that falls again
in a window still in the future can move it.

`decide` returns (and `read` prints, with `id`, `t0` and `error` added) one object:
  verdict    `pass` | `fail` | `pending` | `no data`  (`no data` is final and never a pass)
  window_s   the deciding window in seconds, or null when there is none
  at         the deciding instant t0 + W, RFC3339, or null
  value      what `query` answered, or null
  samples    what min_samples_query answered at the deciding window; with no window, at the longest one
             asked about (null when none was asked)
  guards     [{id, value, ok}] in the block's order; empty when `query` answered nothing
  bound      t0 + max_window, RFC3339
  reason     one line

`read` asks `<url>/api/v1/query` with `query` and `time` (GET; one retry after a transport fault, an HTTP 5xx
or an answer that is not JSON; no proxy from the environment, a redirect is not followed). The time limit of
one attempt: 20 s of silence at most on the way to the response's headers (a socket timeout), and 20 s in
all, from the request, for the body's last byte — each read of the body is given only what is left. Everything in an answer is untrusted text: anything but HTTP 200 `status: success` with a `vector`
of no sample or one sample `[<the instant asked>, "<a finite decimal number>"]` is a failed read — two
samples ("one sample expected"), `NaN`, `+Inf`, a scalar, a matrix, a short or oversized body among them.
`NaN` is refused on purpose, although Prometheus answers it honestly for 0/0: a query whose claim can divide
by nothing says so with an `and on()` term (pin 2) and then answers no sample, which is `no data`; a bare
`NaN` read as "no sample" would let a query that never had that term look as if it did.

`read` exits (0, 1 and 2 are the verdict; a body that does not load never shares a code with one):
  0   pass
  1   fail
  2   no verdict — `pending`, `no data`, or the read failed: the object's `verdict` says which of the first
      two, and for a failed read `verdict` is null and `error` holds the reason
  3   the body states `Experiment: none — <why>`     (stderr as `load`, nothing on stdout)
  4   the body has no experiment section              (the same)
  5   the section is malformed                        (the same; `load` exits 2 for this)
  6   the file cannot be read                         (`load` exits 1 for this)
  70  a fault of this script itself (an exception nobody foresaw): the object is printed with `error`
      naming it and a null verdict — never exit 2, which a caller reads as "keep waiting"
  64  a usage error — an argument missing, `--since`/`--now` not RFC3339 (`2026-11-20T13:09:05Z`, or a
      numeric offset), `--prometheus` not an http(s) URL

`at` prints the one number `--query` answers over `--window` at `--at` (the replay intake reads a baseline
with), or `no sample`, and exits 0; 2 when the read failed (stderr says why, nothing on stdout); 64 on a usage
error; 70 on a fault of the script itself. `--window` is a whole number of m, h or d and is not held to the seven-day limit.
"""
import argparse
import calendar
import contextlib
import datetime
import http.client
import importlib.util
import io
import json
import math
import os
import re
import socket
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
FIXTURES = os.path.join(ROOT, "islands", "intake", "tests", "fixtures", "experiment")

EXIT = {"ok": 0, "malformed": 2, "none": 3, "absent": 4}
EXIT_UNREADABLE = 1
EXIT_USAGE = 64
# `read`: 0, 1 and 2 are the verdict, so the body's own states move off them
READ_EXIT = {"pass": 0, "fail": 1, "pending": 2, "no data": 2}
READ_EXIT_FAILED = 2
READ_EXIT_BODY = {"none": 3, "absent": 4, "malformed": 5}
READ_EXIT_UNREADABLE = 6
EXIT_INTERNAL = 70  # a fault of this script, not of the read: never the code a caller takes for "keep waiting"

TIMEOUT_S = 20  # the socket timeout up to the headers, and the whole attempt's limit for the body
RETRY_PAUSE_S = 1
MAX_ANSWER_BYTES = 1 << 20  # an instant vector of one sample is a few hundred bytes
SETTLE_S = 300  # a window is asked about once it ended this long ago: its last scrapes and rule evaluations are in
MAX_INSTANT = 253402300799  # 9999-12-31T23:59:59Z

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
DURATION = re.compile(r"([0-9]{1,9})([mhd])", re.ASCII)  # bounded: int() of a digit run has a length limit
MAX_INT_DIGITS = 300  # an integer token longer than this is refused before int() or float() can raise on it
MAX_DEPTH = 32  # nesting of the block's JSON, refused before the parser's own recursion limit can be met
WINDOW = re.compile(r"\$window(?![A-Za-z0-9_])")  # the token: `$windows` is another name and is left alone
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
    if not isinstance(v, str) or not WINDOW.search(v):  # the token the read replaces, not the substring
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


def _int(token):
    # integer tokens never reach parse_float; int() raises past its digit limit and float(int) past 1e308
    if len(token.lstrip("-")) > MAX_INT_DIGITS:
        raise Malformed(f"the block holds an integer of {len(token.lstrip('-'))} digits, a number too large to read")
    return int(token)


def _depth(text):
    """The deepest nesting of [ and { in a JSON text, strings skipped."""
    depth = deepest = 0
    in_string = escaped = False
    for ch in text:
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
        elif ch == '"':
            in_string = True
        elif ch in "[{":
            depth += 1
            deepest = max(deepest, depth)
        elif ch in "]}":
            depth -= 1
    return deepest


def parse_block(text):
    """The fenced block's text → the parsed JSON object. Raises Malformed."""
    if _depth(text) > MAX_DEPTH:
        raise Malformed(f"the block nests deeper than {MAX_DEPTH} levels")
    try:
        block = json.loads(text, object_pairs_hook=_pairs, parse_constant=_constant, parse_float=_float,
                           parse_int=_int)
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


# ── the verdict ──────────────────────────────────────────────────────────────────────────────────────
class ReadFailed(Exception):
    """A number could not be read; str() says why. Never a verdict."""


RFC3339 = re.compile(r"([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(Z|[+-][0-9]{2}:[0-9]{2})",
                     re.ASCII)
OPS = {"<": lambda a, b: a < b, "<=": lambda a, b: a <= b, ">": lambda a, b: a > b, ">=": lambda a, b: a >= b}


def parse_rfc3339(text):
    """'2026-11-20T13:09:05Z' → epoch seconds. Whole seconds, `Z` or a numeric offset. Raises ValueError."""
    m = RFC3339.fullmatch(text) if isinstance(text, str) else None
    if not m:
        raise ValueError(f"{text!r} is not an RFC3339 instant (want 2026-11-20T13:09:05Z)")
    y, mo, d, h, mi, s = (int(g) for g in m.groups()[:6])
    try:
        epoch = calendar.timegm(datetime.datetime(y, mo, d, h, mi, s).timetuple())
    except ValueError:
        raise ValueError(f"{text!r} is not a date and time that exists") from None
    zone = m.group(7)
    if zone != "Z":
        zh, zm = int(zone[1:3]), int(zone[4:6])
        if zh > 23 or zm > 59:
            raise ValueError(f"{text!r} carries an offset that does not exist")
        epoch -= (1 if zone[0] == "+" else -1) * (zh * 3600 + zm * 60)
    if not 0 <= epoch <= MAX_INSTANT:
        raise ValueError(f"{text!r} is outside 1970 … 9999")
    return epoch


def rfc3339(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def window_query(query, minutes):
    """The query with every `$window` token replaced by `<minutes>m`; nothing else is touched."""
    out, n = WINDOW.subn(lambda _: f"{minutes}m", query)
    if not n:
        raise ReadFailed("the query holds no $window token")
    return out


def _fmt(number):
    """5.0 → '5', 0.25 → '0.25'."""
    return str(int(number)) if number == int(number) and abs(number) < 1e15 else repr(number)


def _instant(value, name):
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= MAX_INSTANT:
        raise ValueError(f"{name} is not a whole number of epoch seconds")
    return value


def _blank_report(bound):
    """The report's keys, nothing decided: one shape for a verdict and for a failed read."""
    return {"verdict": None, "window_s": None, "at": None, "value": None, "samples": None, "guards": [],
            "bound": rfc3339(bound), "reason": None}


def decide(experiment, t0, now, ask):
    """The verdict of one loaded experiment — a function of t0 and what `ask` answers (the module docstring).

    Raises ReadFailed when a number could not be read: then there is no verdict.
    """
    kpi = experiment["kpi"]
    t0, now = _instant(t0, "t0"), _instant(now, "now")
    bound = t0 + kpi["max_window_s"]
    low, top = kpi["min_window_s"] // 60, kpi["max_window_s"] // 60
    settled = now - SETTLE_S  # what ended by then is asked about; what ended later is still arriving
    reach = (min(settled, bound) - t0) // 60  # the longest whole-minute window that has ended and settled
    floor = kpi["min_samples"]

    def number(query, minutes, what):
        got = ask(window_query(query, minutes), t0 + minutes * 60)
        if got is None:
            return None
        if isinstance(got, bool) or not isinstance(got, (int, float)) or not math.isfinite(got):
            raise ReadFailed(f"{what} over {minutes}m answered {got!r}, which is not a finite number")
        return float(got)

    counts = {}

    def samples(minutes):
        if minutes not in counts:
            got = number(kpi["min_samples_query"], minutes, "min_samples_query")
            counts[minutes] = 0.0 if got is None else got
        return counts[minutes]

    out = _blank_report(bound)

    def done(verdict, reason):
        out["verdict"], out["reason"] = verdict, reason
        return out

    lo, hi = low, top
    while lo < hi:
        mid = (lo + hi) // 2
        if mid > reach or samples(mid) >= floor:  # a window not yet ended is never asked about
            hi = mid
        else:
            lo = mid + 1
    window = lo
    if window > reach or samples(window) < floor:  # the confirmation: the window found is asked about itself
        if counts:
            out["samples"] = counts[max(counts)]
        if settled >= bound:
            return done("no data", f"min_samples_query did not reach {floor} within max_window ({kpi['max_window']})")
        if reach < low:
            return done("pending", f"no window of min_window ({kpi['min_window']}) has ended and settled yet")
        return done("pending", f"min_samples_query has not reached {floor} yet")

    out["window_s"], out["at"], out["samples"] = window * 60, rfc3339(t0 + window * 60), counts[window]
    value = number(kpi["query"], window, "query")
    if value is None:
        return done("no data", "query answered no sample over the deciding window")
    out["value"] = value
    faults = []
    for guard in kpi.get("guards", []):
        got = number(guard["query"], window, f"guard {guard['id']}")
        ok = got is not None and OPS[guard["pass_op"]](got, guard["pass_value"])
        out["guards"].append({"id": guard["id"], "value": got, "ok": ok})
        if got is None:
            faults.append(f"guard {guard['id']}: no sample")
        elif not ok:
            faults.append(f"guard {guard['id']}: {_fmt(got)} {guard['pass_op']} {_fmt(guard['pass_value'])} does not hold")
    if faults:
        return done("fail", "; ".join(faults))
    claim = f"{_fmt(value)} {kpi['pass_op']} {_fmt(kpi['pass_value'])}"
    if OPS[kpi["pass_op"]](value, kpi["pass_value"]):
        return done("pass", f"{claim} holds")
    return done("fail", f"{claim} does not hold")


# ── the read ─────────────────────────────────────────────────────────────────────────────────────────
class _Transient(Exception):
    """A fault worth the one retry."""


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # the 3xx then surfaces as an HTTPError: an answer from somewhere else is not Prometheus's


SAMPLE = re.compile(r"[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?", re.ASCII)
BASE_URL = re.compile(r"https?://[!-~]+", re.ASCII)  # printable ASCII, no blank


def base_url(text):
    """A `--prometheus` value → the URL without its trailing slash. Raises ValueError."""
    if not isinstance(text, str) or not BASE_URL.fullmatch(text):
        raise ValueError(f"{text!r} is not an http(s) URL")
    try:
        parts = urllib.parse.urlsplit(text)
        host, _ = parts.hostname, parts.port  # .port raises on a port that is not a number
    except ValueError:
        raise ValueError(f"{text!r} is not an http(s) URL") from None
    if not host or parts.query or parts.fragment:
        raise ValueError(f"{text!r} is not an http(s) URL without a query or a fragment")
    return text.rstrip("/")


def _refuse_constant(name):
    raise ValueError(name)


def _socket_timeout(resp, seconds):
    """Give the next read of the body only `seconds`. The socket sits behind the response's buffered reader,
    which has no public name for it; where it cannot be reached the read keeps the timeout it was opened with
    and the deadline is checked between reads."""
    sock = getattr(getattr(getattr(resp, "fp", None), "raw", None), "_sock", None)
    if sock is not None:
        try:
            sock.settimeout(max(seconds, 0.001))
        except (OSError, ValueError):
            pass


def _get(opener, url, timeout):
    """One GET → the body's bytes. Raises _Transient or ReadFailed."""
    deadline = time.monotonic() + timeout
    try:
        with opener.open(urllib.request.Request(url, headers={"Accept": "application/json"}), timeout=timeout) as resp:
            if resp.status != 200:
                raise ReadFailed(f"HTTP {resp.status}")
            chunks, size = [], 0
            while True:
                if time.monotonic() >= deadline:
                    raise _Transient(f"no whole answer within {_fmt(timeout)} s")
                _socket_timeout(resp, deadline - time.monotonic())
                chunk = resp.read1(65536)
                if not chunk:
                    break
                size += len(chunk)
                if size > MAX_ANSWER_BYTES:
                    raise ReadFailed(f"the answer is longer than {MAX_ANSWER_BYTES} bytes")
                chunks.append(chunk)
            declared = resp.headers.get("Content-Length")
            if declared is not None and declared.strip() != str(size):
                raise _Transient(f"the answer was cut short ({size} bytes of a declared {declared.strip()[:20]})")
            return b"".join(chunks)
    except urllib.error.HTTPError as e:
        why = ""
        try:
            said = json.loads(e.read(4096).decode("utf-8", "replace"))
            if isinstance(said, dict) and isinstance(said.get("error"), str):
                why = f": {said['error'][:300]}"
        except (ValueError, OSError, http.client.HTTPException, RecursionError):
            pass
        finally:
            e.close()
        if 300 <= e.code < 400:
            raise ReadFailed(f"HTTP {e.code}: a redirect is not followed") from None
        if e.code >= 500:
            raise _Transient(f"HTTP {e.code}{why}") from None
        raise ReadFailed(f"HTTP {e.code}{why}") from None
    except (OSError, http.client.HTTPException) as e:  # URLError, a timeout, a reset, a malformed response
        raise _Transient(f"{type(e).__name__}: {str(e)[:300]}") from None
    except ValueError as e:  # a URL the client refuses to send
        raise ReadFailed(f"the request could not be made: {str(e)[:300]}") from None


def sample_of(body, at):
    """An answer's bytes → the one sample's float, or None for no sample. Raises _Transient or ReadFailed."""
    try:
        answer = json.loads(body.decode("utf-8"), parse_constant=_refuse_constant)
    except (ValueError, RecursionError):  # UnicodeDecodeError and JSONDecodeError are ValueErrors
        raise _Transient("the answer is not JSON") from None
    if not isinstance(answer, dict):
        raise ReadFailed("the answer is not a JSON object")
    if answer.get("status") != "success":
        said = answer.get("error")
        raise ReadFailed("Prometheus answered an error" + (f": {said[:300]}" if isinstance(said, str) else ""))
    data = answer.get("data")
    if not isinstance(data, dict) or data.get("resultType") != "vector" or not isinstance(data.get("result"), list):
        kind = data.get("resultType") if isinstance(data, dict) else None
        raise ReadFailed(f"the answer is not a vector (resultType {json.dumps(kind)[:40]})")
    result = data["result"]
    if not result:
        return None
    if len(result) > 1:
        raise ReadFailed(f"one sample expected, the answer holds {len(result)}")
    pair = result[0].get("value") if isinstance(result[0], dict) else None
    if not isinstance(pair, list) or len(pair) != 2:
        raise ReadFailed("the sample holds no [time, value] pair")
    stamp, text = pair
    if isinstance(stamp, bool) or not isinstance(stamp, (int, float)) or not math.isfinite(stamp) or abs(stamp - at) >= 1:
        raise ReadFailed(f"the sample is not stamped with the instant asked ({at})")
    if not isinstance(text, str):
        raise ReadFailed("the sample's value is not a string")
    if len(text) > 64 or not SAMPLE.fullmatch(text):
        raise ReadFailed(f"the sample's value {json.dumps(text[:20])} is not a finite decimal number")
    number = float(text)
    if not math.isfinite(number):
        raise ReadFailed(f"the sample's value {json.dumps(text[:20])} is too large to read")
    return number


def http_ask(base, timeout=None, pause=None):
    """→ `ask(promql, at)` over `<base>/api/v1/query`: one retry after a transient fault, then ReadFailed."""
    timeout = TIMEOUT_S if timeout is None else timeout
    pause = RETRY_PAUSE_S if pause is None else pause
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect)

    def ask(promql, at):
        url = base + "/api/v1/query?" + urllib.parse.urlencode({"query": promql, "time": str(at)})
        for attempt in (1, 2):
            try:
                return sample_of(_get(opener, url, timeout), at)
            except _Transient as e:
                if attempt == 2:
                    raise ReadFailed(f"{e} (asked twice)") from None
                threading.Event().wait(pause)  # the pause before the one retry

    return ask


_ASK = http_ask  # the commands' way to Prometheus; the self-test swaps it to plant a fault of the script


# ── the command ──────────────────────────────────────────────────────────────────────────────────────
class _Parser(argparse.ArgumentParser):
    def error(self, message):  # 2 means "malformed section" here; a usage error must not look like one
        self.print_usage(sys.stderr)
        self.exit(EXIT_USAGE, f"{self.prog}: error: {message}\n")


def _typed(convert):
    """An argparse `type` from a converter that raises ValueError or Malformed: the fault becomes a usage error."""
    def typed(text):
        try:
            return convert(text)
        except (ValueError, Malformed) as e:
            raise argparse.ArgumentTypeError(str(e)) from None
    return typed


def _window_arg(text):
    return duration_s(text, "--window") // 60


def _window_query_arg(text):
    if not WINDOW.search(text):
        raise ValueError("--query holds no $window token")
    return text


def _body_text(path):
    """→ (text, None), or (None, the fault)."""
    try:
        if path == "-":
            return sys.stdin.read(), None
        with open(path, encoding="utf-8") as fh:
            return fh.read(), None
    except (OSError, UnicodeDecodeError) as e:
        return None, e


def _read(a):
    text, e = _body_text(a.body)
    if text is None:
        print(f"experiment: cannot read {a.body}: {e}", file=sys.stderr)
        return READ_EXIT_UNREADABLE
    status, value = load_body(text)
    if status != "ok":
        print(f"experiment: {status} — {value}", file=sys.stderr)
        return READ_EXIT_BODY[status]
    now = int(time.time()) if a.now is None else a.now
    failed = dict(_blank_report(a.since + value["kpi"]["max_window_s"]))
    try:
        report = decide(value, a.since, now, _ASK(a.prometheus))
        report["error"] = None
        code = READ_EXIT[report["verdict"]]
    except ReadFailed as e:
        report, code = dict(failed, error=str(e)[:600]), READ_EXIT_FAILED
    except Exception as e:  # unforeseen: said in the report under its own exit, never a traceback
        report, code = dict(failed, error=f"internal: {type(e).__name__}: {e}"[:600]), EXIT_INTERNAL
    report["id"], report["t0"] = value["id"], rfc3339(a.since)
    print(json.dumps(report, sort_keys=True, allow_nan=False))
    return code


def _at(a):
    try:
        got = _ASK(a.prometheus)(window_query(a.query, a.window), a.at)
    except ReadFailed as e:
        print(f"experiment: read failed — {str(e)[:600]}", file=sys.stderr)
        return READ_EXIT_FAILED
    except Exception as e:  # as in _read
        print(f"experiment: internal — {type(e).__name__}: {e}"[:600], file=sys.stderr)
        return EXIT_INTERNAL
    print("no sample" if got is None else _fmt(got))
    return 0


def main(argv=None):
    ap = _Parser(description=__doc__.split("\n")[0])
    ap.add_argument("--self-test", action="store_true")
    sub = ap.add_subparsers(dest="cmd", parser_class=_Parser)
    ld = sub.add_parser("load", help="print the body's experiment as validated JSON")
    ld.add_argument("--check", action="store_true", help="print nothing, only exit")
    ld.add_argument("body", help="a file holding an issue body, or - for stdin")
    rd = sub.add_parser("read", help="decide the body's experiment from Prometheus")
    rd.add_argument("--prometheus", required=True, type=_typed(base_url), help="the base URL; /api/v1/query is appended")
    rd.add_argument("--since", required=True, type=_typed(parse_rfc3339), help="t0, RFC3339")
    rd.add_argument("--now", type=_typed(parse_rfc3339), help="RFC3339 (default: the clock)")
    rd.add_argument("body", help="a file holding an issue body, or - for stdin")
    at = sub.add_parser("at", help="print the one number a query answers over a window at an instant")
    at.add_argument("--prometheus", required=True, type=_typed(base_url))
    at.add_argument("--query", required=True, type=_typed(_window_query_arg), help="PromQL holding $window")
    at.add_argument("--window", required=True, type=_typed(_window_arg), help="a whole number of m, h or d")
    at.add_argument("--at", required=True, type=_typed(parse_rfc3339), help="the instant the window ends, RFC3339")
    a = ap.parse_args(argv)
    if a.self_test:
        return self_test()
    if a.cmd == "read":
        return _read(a)
    if a.cmd == "at":
        return _at(a)
    if a.cmd != "load":
        ap.error("want: load [--check] <file|->, read …, at …, or --self-test")
    text, e = _body_text(a.body)
    if text is None:
        if not a.check:
            print(f"experiment: cannot read {a.body}: {e}", file=sys.stderr)
        return EXIT_UNREADABLE
    status, value = load_body(text)
    if a.check:
        return EXIT[status]
    if status == "ok":
        print(json.dumps(value, sort_keys=True, allow_nan=False))  # ASCII out: a lone surrogate cannot break the write
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
    _self_test_decide(check)
    _self_test_read(check, run)
    print("experiment self-test: " + ("PASS" if not fails else f"FAIL ({len(fails)})"))
    return 1 if fails else 0


READ_FIXTURES = os.path.join(ROOT, "islands", "intake", "tests", "fixtures", "experiment-read")
T0 = 1793491205  # 2026-11-01T00:00:05Z: the harness's own clock comment gives 2026-10-27T05:00:00Z = 1793077200; + 4 d 19 h 5 s
T_ASK = T0 + 2000 * 60  # 1793611205, 2026-11-02T09:20:05Z


def _fixture_body(name):
    with open(os.path.join(READ_FIXTURES, name), encoding="utf-8") as fh:
        status, value = load_body(fh.read())
    if status != "ok":
        raise AssertionError(f"{name} does not load: {value}")
    return value


def _table_ask(series, t0, asked):
    """The fake `ask` of the decision table: answers from step functions of the window, and refuses a question
    whose windows disagree, whose $window was not replaced, or whose instant is not t0 + the window."""
    def ask(promql, at):
        asked.append((promql, at))
        windows = set(re.findall(r"\[([0-9]+)m[\]:]", promql))
        names = re.findall(r"fx_(samples|value|errors)\b", promql)
        if "$" in promql or len(windows) != 1 or len(names) != 1:
            raise AssertionError(f"not a question the table knows: {promql}")
        minutes = int(windows.pop())
        if at != t0 + minutes * 60:
            raise AssertionError(f"{promql} asked at {at}, not at t0 + {minutes}m")
        answer = None
        for start, value in series.get(names[0], []):
            if start <= minutes:
                answer = value
        if answer == "raise":
            raise ReadFailed("the table says this read fails")
        return None if answer is None else float(answer)
    return ask


def _self_test_decide(check):
    # the instants: against an anchor this file did not compute
    check("parse_rfc3339: 2026-10-27T05:00:00Z is 1793077200", parse_rfc3339("2026-10-27T05:00:00Z") == 1793077200)
    check("parse_rfc3339: an offset is applied (07:00:00+02:00 is the same instant)",
          parse_rfc3339("2026-10-27T07:00:00+02:00") == 1793077200 and parse_rfc3339("2026-10-27T03:30:00-01:30") == 1793077200)
    check("rfc3339 writes it back", rfc3339(1793077200) == "2026-10-27T05:00:00Z" and rfc3339(T0) == "2026-11-01T00:00:05Z")
    for bad in ("2026-10-27", "2026-10-27T05:00:00", "2026-10-27t05:00:00Z", "2026-10-27T05:00:00z", "2026-13-01T00:00:00Z",
                "2026-02-30T00:00:00Z", "2026-10-27T24:00:00Z", "2026-10-27T05:00:00.5Z", "2026-10-27T05:00:00Z\n",
                "2026-10-27T05:00:00+24:00", "1969-12-31T23:59:59Z", "1970-01-01T00:00:00+01:00",
                "٢٠٢٦-10-27T05:00:00Z", " 2026-10-27T05:00:00Z", "1793077200", ""):
        try:
            got = parse_rfc3339(bad)
        except ValueError:
            got = "refused"
        check(f"parse_rfc3339 refuses {bad!r}", got == "refused", got)
    # $window: the token, every occurrence, nothing else
    check("$window → <minutes>m at every occurrence",
          window_query("a[$window] / b[$window:1m] offset 5m", 90) == "a[90m] / b[90m:1m] offset 5m")
    check("…and a longer name that starts with it is left alone",
          window_query("a[$window] + $windows + $window_s", 7) == "a[7m] + $windows + $window_s")
    try:
        got = window_query("a[$windows]", 7)
    except ReadFailed:
        got = "refused"
    check("a query with no $window token is a failed read, not a query sent as it is", got == "refused", got)
    check("the four operators", [OPS[o](1.0, 1.0) for o in ("<", "<=", ">", ">=")] == [False, True, False, True]
          and [OPS[o](0.0, 1.0) for o in ("<", "<=", ">", ">=")] == [True, True, False, False]
          and [OPS[o](2.0, 1.0) for o in ("<", "<=", ">", ">=")] == [False, False, True, True])

    with open(os.path.join(READ_FIXTURES, "decide.json"), encoding="utf-8") as fh:
        table = json.load(fh)
    t0 = parse_rfc3339(table["t0"])
    check("the table's t0 is the epoch the stub fixture is written against", t0 == T0, t0)
    outputs = {}
    for row in table["rows"]:
        name, asked = row["name"], []
        experiment = _fixture_body(row["body"])
        try:
            got = decide(experiment, t0, parse_rfc3339(row["now"]), _table_ask(row["series"], t0, asked))
        except ReadFailed as e:
            got = ("raised", str(e))
        except AssertionError as e:
            got = ("the fake ask refused", str(e))
        if row.get("raises"):
            check(f"decide: {name}", got == ("raised", "the table says this read fails"), got)
        else:
            check(f"decide: {name}", got == row["expect"], got)
            outputs[name] = got
        check(f"decide: {name} — at most {row['max_asks']} question(s)", len(asked) <= row["max_asks"], len(asked))
        if "same_as" in row:
            check(f"decide: {name} — identical to the output of “{row['same_as']}”",
                  row["same_as"] in outputs and json.dumps(got, sort_keys=True) == json.dumps(outputs[row["same_as"]], sort_keys=True), got)
    verdicts = {o["verdict"] for o in outputs.values() if isinstance(o, dict)}
    check("the table reaches every verdict", verdicts == {"pass", "fail", "pending", "no data"}, sorted(verdicts))
    check("the table has rows that raise and rows read twice", sum(1 for r in table["rows"] if r.get("raises")) >= 3
          and sum(1 for r in table["rows"] if "same_as" in r) >= 3)
    # the count that falls: the window returned holds the floor and the minute before it does not
    row = next(r for r in table["rows"] if r["name"].startswith("a count that falls"))
    asked = []
    got = decide(_fixture_body(row["body"]), t0, parse_rfc3339(row["now"]), _table_ask(row["series"], t0, asked))
    minutes = got["window_s"] // 60
    answers = {int(re.search(r"\[([0-9]+)m", q).group(1)) for q, _ in asked if "fx_samples" in q}
    check("decide: the window of a falling count was asked about itself, and so was the minute before it",
          minutes in answers and minutes - 1 in answers, sorted(answers))
    # what `ask` hands back is not trusted either
    body = _fixture_body("body.md")
    for label, answer in (("NaN", float("nan")), ("inf", float("inf")), ("-inf", float("-inf")), ("a string", "20"),
                          ("True", True), ("a list", [20.0])):
        try:
            got = decide(body, t0, t0 + 3000 * 60, lambda q, at, answer=answer: answer)
        except ReadFailed:
            got = "raised"
        check(f"decide: an ask that answers {label} is a failed read", got == "raised", got)
    for label, a_t0, a_now in (("a float t0", float(t0), t0), ("a bool now", t0, True), ("a negative t0", -1, t0),
                               ("a string now", t0, "2026-11-03T02:00:05Z")):
        try:
            got = decide(body, a_t0, a_now, lambda q, at: 20.0)
        except ValueError:
            got = "refused"
        check(f"decide: {label} is refused", got == "refused", got)


def _self_test_read(check, run):
    spec = importlib.util.spec_from_file_location(
        "prom_stub", os.path.join(ROOT, "islands", "intake", "tests", "prom_stub.py"))
    stub = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(stub)
    srv = stub.serve(os.path.join(READ_FIXTURES, "prom.json"))
    base = f"http://127.0.0.1:{srv.server_port}"
    query = "fx_x[5m]"
    global RETRY_PAUSE_S
    pause, RETRY_PAUSE_S = RETRY_PAUSE_S, 0  # the commands below retry without the wait

    def one(scenario, timeout=5):
        before = len(srv.requests)
        try:
            got = http_ask(f"{base}/{scenario}", timeout=timeout, pause=0)(query, T_ASK)
        except ReadFailed as e:
            got = f"failed: {e}"
        except Exception as e:  # the row then fails, with the exception named
            got = f"TRACEBACK {type(e).__name__}: {e}"
        sent = srv.requests[before:]
        return got, len(sent), sent

    try:
        got, n, sent = one("one")
        check("ask: one sample is its number, one request", (got, n) == (5.0, 1) and isinstance(got, float), (got, n))
        check("ask: the request carries the query and the instant, under the URL's own path",
              sent == [{"scenario": "one", "query": query, "time": str(T_ASK)}], sent)
        for scenario, want in (("exponent", 1500.0), ("negative", -0.5), ("empty", None)):
            got, n, _ = one(scenario)
            check(f"ask: {scenario} → {want!r}", got == want and n == 1 and type(got) is type(want), (got, n))
        # (scenario, what the failure says, requests sent: 2 where the fault is worth the one retry)
        for scenario, says, requests in (
                ("two", "one sample expected, the answer holds 2", 1),
                ("nan", 'the sample\'s value "NaN" is not a finite decimal number', 1),
                ("inf", 'the sample\'s value "+Inf" is not a finite decimal number', 1),
                ("minus-inf", 'the sample\'s value "-Inf" is not a finite decimal number', 1),
                ("word", 'the sample\'s value "abc" is not a finite decimal number', 1),
                ("blank", 'the sample\'s value "" is not a finite decimal number', 1),
                ("spaced", 'the sample\'s value " 5" is not a finite decimal number', 1),
                ("newline", 'the sample\'s value "5\\n" is not a finite decimal number', 1),
                ("hex", 'the sample\'s value "0x10" is not a finite decimal number', 1),
                ("other-digits", "is not a finite decimal number", 1),
                ("long", "is not a finite decimal number", 1),
                ("overflow", 'the sample\'s value "1e999" is too large to read', 1),
                ("number-not-string", "the sample's value is not a string", 1),
                ("nan-constant", "the answer is not JSON (asked twice)", 2),
                ("scalar", 'the answer is not a vector (resultType "scalar")', 1),
                ("matrix", 'the answer is not a vector (resultType "matrix")', 1),
                ("string", 'the answer is not a vector (resultType "string")', 1),
                ("histogram", "the sample holds no [time, value] pair", 1),
                ("pair-of-three", "the sample holds no [time, value] pair", 1),
                ("sample-not-object", "the sample holds no [time, value] pair", 1),
                ("result-not-list", "the answer is not a vector", 1),
                ("no-data-key", "the answer is not a vector (resultType null)", 1),
                ("status-error", "Prometheus answered an error: query timed out in expression evaluation", 1),
                ("status-missing", "Prometheus answered an error", 1),
                ("list", "the answer is not a JSON object", 1),
                ("html", "the answer is not JSON (asked twice)", 2),
                ("unclosed", "the answer is not JSON (asked twice)", 2),
                ("stale-stamp", f"the sample is not stamped with the instant asked ({T_ASK})", 1),
                ("bad-request", "HTTP 400: invalid parameter \"query\": 1:9: parse error", 1),
                ("http-204", "HTTP 204", 1),
                ("http-500", "HTTP 500 (asked twice)", 2),
                ("flaky-twice", "HTTP 500 (asked twice)", 2),
                ("truncated", "the answer was cut short", 2),
                ("redirect", "HTTP 302: a redirect is not followed", 1),
                ("oversized", f"the answer is longer than {MAX_ANSWER_BYTES} bytes", 1),
                ("no-such-scenario", "HTTP 404", 1)):
            got, n, _ = one(scenario)
            check(f"ask: {scenario} is a failed read — {says}", isinstance(got, str) and got.startswith("failed: ")
                  and says in got and n == requests, (got, n))
        got, n, _ = one("flaky")
        check("ask: an HTTP 500 followed by an answer is that answer, after the one retry", (got, n) == (5.0, 2), (got, n))
        got, n, sent = one("redirect")
        check("ask: the redirect's target (a scenario that would answer 5) was never asked",
              [r["scenario"] for r in sent] == ["redirect"], sent)
        started = time.monotonic()
        got, n, _ = one("slow", timeout=0.3)
        check("ask: an answer that does not come within the timeout is a failed read, asked twice",
              isinstance(got, str) and got.startswith("failed: ") and "(asked twice)" in got and n == 2
              and time.monotonic() - started < 1.4, (got, n))
        started = time.monotonic()
        got, n, _ = one("drip", timeout=0.5)  # a byte every 0.2 s, 3 s in all: no single read times out, the attempt does
        check("ask: a body that keeps trickling past the attempt's time limit is a failed read, asked twice",
              isinstance(got, str) and got.startswith("failed: ") and "(asked twice)" in got and n == 2
              and time.monotonic() - started < 2.0, (got, n, time.monotonic() - started))
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            dead = s.getsockname()[1]
        try:
            got = http_ask(f"http://127.0.0.1:{dead}", timeout=2, pause=0)(query, T_ASK)
        except ReadFailed as e:
            got = f"failed: {e}"
        check("ask: nothing listening is a failed read", isinstance(got, str) and "(asked twice)" in got, got)

        # ── the commands ──
        body = os.path.join(READ_FIXTURES, "body.md")
        loader = os.path.join(FIXTURES, "")

        def read(scenario, now, path=body, since="2026-11-01T00:00:05Z"):
            before = len(srv.requests)
            rc, out, err = run(["read", "--prometheus", f"{base}/{scenario}/", "--since", since, "--now", now, path])
            try:
                obj = json.loads(out) if out else None
            except ValueError:
                obj = out
            return rc, obj, err, out, srv.requests[before:]

        keys = ["at", "bound", "error", "guards", "id", "reason", "samples", "t0", "value", "verdict", "window_s"]
        rc, obj, err, out, sent = read("pass", "2026-11-03T02:00:05Z")
        check("read: pass exits 0 and prints one object of the eleven keys", rc == 0 and err == "" and out.count("\n") == 1
              and isinstance(obj, dict) and sorted(obj) == keys, (rc, out, err))
        check("read: …the verdict's object, with id, t0 and a null error", obj == {
            "id": "press-waits-down", "t0": "2026-11-01T00:00:05Z", "error": None, "verdict": "pass", "window_s": 120000,
            "at": "2026-11-02T09:20:05Z", "value": 2, "samples": 20, "guards": [{"id": "errors", "value": 0, "ok": True}],
            "bound": "2026-11-08T00:00:05Z", "reason": "2 <= 3 holds"}, obj)
        check("read: …the deciding question is query over 2000m at t0 + 2000m; a trailing slash on the URL is dropped",
              {"scenario": "pass", "time": str(T_ASK),
               "query": "max_over_time(fx_value[2000m]) and on() (avg_over_time(fx_up[2000m]) > 0.95)"} in sent
              and len(sent) <= 16, sent[-3:])
        again = read("pass", "2026-11-09T00:00:05Z")
        check("read: the same body read a week later prints the same line", again[0] == 0 and again[3] == out, again[3])
        rc, obj, err, out, _ = read("fail", "2026-11-03T02:00:05Z")
        check("read: fail exits 1", rc == 1 and obj["verdict"] == "fail" and obj["value"] == 7 and obj["error"] is None
              and obj["reason"] == "7 <= 3 does not hold", (rc, out, err))
        rc, obj, err, out, _ = read("pending", "2026-11-03T02:00:05Z")
        check("read: pending exits 2 with the verdict said", rc == 2 and obj["verdict"] == "pending" and obj["error"] is None
              and obj["samples"] == 3 and obj["window_s"] is None, (rc, out, err))
        rc, obj, err, out, _ = read("pending", "2026-11-08T00:00:05Z")
        check("read: at the bound itself, not yet settled, it is still pending", rc == 2 and obj["verdict"] == "pending", (rc, out))
        rc, obj, err, out, _ = read("pending", "2026-11-08T00:05:05Z")
        check("read: no data exits 2 with the verdict said", rc == 2 and obj["verdict"] == "no data" and obj["error"] is None, (rc, out))
        rc, obj, err, out, _ = read("two-samples", "2026-11-03T02:00:05Z")
        check("read: two samples exit 2 — no verdict, the error says one sample expected", rc == 2 and sorted(obj) == keys
              and obj["verdict"] is None and obj["error"] == "one sample expected, the answer holds 2"
              and obj["bound"] == "2026-11-08T00:00:05Z" and obj["id"] == "press-waits-down" and err == "", (rc, out, err))
        rc, obj, err, out, sent = read("down", "2026-11-03T02:00:05Z")
        check("read: HTTP 500 exits 2 — no verdict, asked twice", rc == 2 and obj["verdict"] is None
              and obj["error"] == "HTTP 500 (asked twice)" and len(sent) == 2, (rc, out, len(sent)))
        rc, obj, err, out, _ = read("value-down", "2026-11-03T02:00:05Z")
        check("read: a read that fails after the window was found is still no verdict", rc == 2 and obj["verdict"] is None
              and obj["window_s"] is None and obj["error"] == "HTTP 503 (asked twice)", (rc, out))
        global _ASK

        def broken(base):
            raise KeyError("planted")
        kept, _ASK = _ASK, broken
        try:
            rc, obj, err, out, _ = read("pass", "2026-11-03T02:00:05Z")
            rc2, out2, err2 = run(["at", "--prometheus", base, "--query", "up[$window]", "--window", "1h", "--at", "2026-11-02T09:20:05Z"])
        finally:
            _ASK = kept
        check("read: a fault of the script itself exits 70, not 2 — the object says so, no traceback", rc == EXIT_INTERNAL
              and sorted(obj) == keys and obj["verdict"] is None and obj["error"] == "internal: KeyError: 'planted'" and err == "", (rc, out, err))
        check("at: the same — exit 70, nothing on stdout", (rc2, out2, err2) == (EXIT_INTERNAL, "", "experiment: internal — KeyError: 'planted'\n"), (rc2, out2, err2))
        for name, code in (("none.md", 3), ("neither.md", 4), ("malformed-no-block.md", 5), ("no-such-body.md", 6)):
            rc, obj, err, out, sent = read("pass", "2026-11-03T02:00:05Z", path=os.path.join(loader, name))
            check(f"read: {name} exits {code} — nothing on stdout, one stderr line, nothing asked",
                  rc == code and out == "" and len(err.splitlines()) == 1 and sent == [], (rc, out, err, sent))
        with open(body, encoding="utf-8") as fh:
            rc, out, _ = run(["read", "--prometheus", f"{base}/pass", "--since", "2026-11-01T00:00:05Z",
                              "--now", "2026-11-03T02:00:05Z", "-"], stdin=fh.read())
        check("read: the body from stdin", rc == 0 and json.loads(out)["verdict"] == "pass", (rc, out))
        rc, out, err = run(["read", "--prometheus", f"{base}/pending", "--since", rfc3339(int(time.time()) - 7200), body])
        check("read: without --now the clock is read (t0 two hours ago, three samples: pending)",
              rc == 2 and json.loads(out)["verdict"] == "pending" and json.loads(out)["samples"] == 3, (rc, out, err))
        for label, args in (
                ("--since not RFC3339", ["read", "--prometheus", base, "--since", "1793491205", body]),
                ("--now not RFC3339", ["read", "--prometheus", base, "--since", "2026-11-01T00:00:05Z", "--now", "now", body]),
                ("--since missing", ["read", "--prometheus", base, body]),
                ("--prometheus missing", ["read", "--since", "2026-11-01T00:00:05Z", body]),
                ("a file: URL", ["read", "--prometheus", "file:///etc/hostname", "--since", "2026-11-01T00:00:05Z", body]),
                ("a URL with no host", ["read", "--prometheus", "http://", "--since", "2026-11-01T00:00:05Z", body]),
                ("a URL with a blank in it", ["read", "--prometheus", base + "/a b", "--since", "2026-11-01T00:00:05Z", body]),
                ("a URL with a query", ["read", "--prometheus", base + "/?x=1", "--since", "2026-11-01T00:00:05Z", body]),
                ("a URL whose port is not a number", ["read", "--prometheus", "http://127.0.0.1:port", "--since", "2026-11-01T00:00:05Z", body]),
                ("at: --query without $window", ["at", "--prometheus", base, "--query", "up", "--window", "10d", "--at", "2026-11-02T09:20:05Z"]),
                ("at: --window not a duration", ["at", "--prometheus", base, "--query", "up[$window]", "--window", "10", "--at", "2026-11-02T09:20:05Z"]),
                ("at: --at not RFC3339", ["at", "--prometheus", base, "--query", "up[$window]", "--window", "10d", "--at", "yesterday"])):
            before = len(srv.requests)
            rc, out, err = run(args)
            check(f"usage: {label} exits 64, prints nothing on stdout, asks nothing",
                  rc == EXIT_USAGE and out == "" and len(srv.requests) == before, (rc, out, err))

        def at(scenario, query, window, when="2026-11-02T09:20:05Z"):
            before = len(srv.requests)
            rc, out, err = run(["at", "--prometheus", f"{base}/{scenario}", "--query", query, "--window", window, "--at", when])
            return rc, out, err, srv.requests[before:]

        rc, out, err, sent = at("baseline", "max_over_time(fx_value[$window]) and on() (avg_over_time(fx_up[$window]) > 0.95)", "10d")
        check("at: the one number — 10d is asked as 14400m, at the instant given", (rc, out, err) == (0, "5\n", "")
              and [r["time"] for r in sent] == [str(T_ASK)], (rc, out, err, sent))
        rc, out, err, _ = at("baseline", "fx_fraction[$window]", "30m")
        check("at: a fraction is printed as it is", (rc, out) == (0, "0.25\n"), (rc, out, err))
        rc, out, err, _ = at("baseline", "fx_gone[$window]", "1h")
        check("at: an answer with no sample prints `no sample` and exits 0", (rc, out, err) == (0, "no sample\n", ""), (rc, out, err))
        rc, out, err, sent = at("down", "fx_value[$window]", "1h")
        check("at: a failed read exits 2 — nothing on stdout, the reason on stderr", rc == 2 and out == ""
              and err == "experiment: read failed — HTTP 500 (asked twice)\n" and len(sent) == 2, (rc, out, err))
        rc, out, err, _ = at("two", "fx_value[$window]", "1h")
        check("at: two samples are a failed read", rc == 2 and out == "" and "one sample expected" in err, (rc, out, err))
        rc, out, err, _ = at("nan", "fx_value[$window]", "1h")
        check("at: NaN is a failed read, never printed as a number", rc == 2 and out == "", (rc, out, err))
    finally:
        RETRY_PAUSE_S = pause
        srv.shutdown()
        srv.server_close()


if __name__ == "__main__":
    sys.exit(main())
