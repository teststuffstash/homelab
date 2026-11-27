#!/usr/bin/env python3
"""intake-wait-cases — list and validate the recorded wait cases the replay gate reads (islands/intake/rules/intake-wait.md).

A case is one PARKING comment, recorded as the sitting could have read it, so a candidate rules file can be
replayed against it later. One directory per case under islands/intake/tests/fixtures/wait-cases/:

  case.json            schema intake-wait-case/v1: item, parked_at, parking_comment_id, parked_by, writer
                       (intake|lane|human), as_of (the instant the replay rules at: the parking comment for an
                       intake wait, the first re-read for another writer's), rules {path, commit} (the brief that
                       stood at as_of), island, recorded_at[, note]
  input.json           the input row as the selector presents it (kind member|reread|text; id == item)
  issue.json           GET /repos/<repo>/issues/<n>, full wire (today's; the body as of as_of is edits.json's)
  edits.json           the GraphQL userContentEdits answer, full — every body revision with its editedAt
  comments.json        GET …/comments, the objects created at or before as_of (parking comment included)
  comments-after.json  …the objects after as_of (the release evidence — never shown to a replayed sitting)
  events.json          GET …/events at or before as_of;  events-after.json  after it
  snapshots/*.json     optional: {fetched_at, path, answer} — a live read the outcome depended on
  expected.json        {outcome, blocked_on, class, split, basis}: the outcome the rules SHOULD have produced
                       (outcome + `blocked-on` target, never wording), its wait class (H|R|O|U — U is not scored),
                       train|heldout, one line of basis

  python3 islands/intake/scripts/intake-wait-cases.py [--dir <cases dir>] [--git] [list | validate]
  python3 islands/intake/scripts/intake-wait-cases.py --self-test

`validate` (the default) is strict: a missing or unknown file or key, a comment on the wrong side of as_of,
a malformed target, or a held-out set without one H and two R/O cases fails (exit 1). --git also checks that
each rules commit exists in this checkout.
"""
import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
DEFAULT_DIR = os.path.join(ROOT, "islands", "intake", "tests", "fixtures", "wait-cases")

FILES = {"case.json", "input.json", "issue.json", "edits.json", "comments.json", "comments-after.json",
         "events.json", "events-after.json", "expected.json"}
OUTCOMES = {"queue", "goal", "seat", "fold", "close", "requeue", "standing", "split", "file", "forward"}
CASE_KEYS = {"schema", "item", "parked_at", "parking_comment_id", "parked_by", "writer", "as_of", "rules",
             "island", "recorded_at"}
CASE_OPT = {"note"}
EXPECTED_KEYS = {"outcome", "blocked_on", "class", "split", "basis"}
TARGET = re.compile(r"^(human|issue=([0-9]+|new)|pr=[0-9]+)$")
ITEM = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#([0-9]+)$")
ISO = "%Y-%m-%dT%H:%M:%SZ"


def ts(s):
    return dt.datetime.strptime(s, ISO)


def load(p):
    with open(p, encoding="utf-8") as fh:
        return json.load(fh)


def check_case(d, git=False):
    """→ (summary dict | None, [errors])"""
    errs = []
    name = os.path.basename(d.rstrip("/"))
    have = set(os.listdir(d))
    for f in sorted(FILES - have):
        errs.append(f"{name}: missing {f}")
    for f in sorted(have - FILES - {"snapshots"}):
        errs.append(f"{name}: unknown file {f}")
    if errs:
        return None, errs
    try:
        j = {f: load(os.path.join(d, f)) for f in FILES}
    except (OSError, ValueError) as e:
        return None, [f"{name}: unparseable JSON: {e}"]
    c, inp, exp = j["case.json"], j["input.json"], j["expected.json"]
    if not isinstance(c, dict) or set(c) - CASE_KEYS - CASE_OPT or CASE_KEYS - set(c):
        return None, [f"{name}: case.json keys {sorted(c) if isinstance(c, dict) else c} (want {sorted(CASE_KEYS)} [+ {sorted(CASE_OPT)}])"]
    if c["schema"] != "intake-wait-case/v1":
        errs.append("{}: case.json schema {!r}".format(name, c["schema"]))
    m = ITEM.match(str(c["item"]))
    if not m:
        return None, errs + ["{}: case.json item {!r} is not <owner/repo>#<n>".format(name, c["item"])]
    n = int(m.group(1))
    try:
        parked, as_of = ts(c["parked_at"]), ts(c["as_of"])
        ts(c["recorded_at"])
    except (TypeError, ValueError):
        return None, errs + [f"{name}: a case.json timestamp is not {ISO}"]
    if as_of < parked:
        errs.append(f"{name}: as_of is before parked_at")
    if c["writer"] not in ("intake", "lane", "human"):
        errs.append("{}: writer {!r}".format(name, c["writer"]))
    if c["writer"] == "intake" and as_of != parked:
        errs.append(f"{name}: an intake wait is replayed at its parking comment (as_of == parked_at)")
    r = c["rules"]
    if not (isinstance(r, dict) and set(r) == {"path", "commit"} and re.fullmatch(r"[0-9a-f]{40}", str(r.get("commit", "")))):
        errs.append(f"{name}: rules must be {{path, commit: <40-hex>}}")
    elif git and subprocess.run(["git", "-C", ROOT, "cat-file", "-e", r["commit"] + "^{commit}"],
                                capture_output=True).returncode != 0:
        errs.append("{}: rules commit {} not in this checkout".format(name, r["commit"]))
    if not isinstance(inp, dict) or inp.get("id") != c["item"] or inp.get("number") != n \
            or inp.get("kind") not in ("member", "reread", "text") or not isinstance(inp.get("title"), str):
        errs.append("{}: input.json must be the selector row of {} (id, number, kind member|reread|text, title)".format(name, c["item"]))
    if not isinstance(j["issue.json"], dict) or j["issue.json"].get("number") != n:
        errs.append(f"{name}: issue.json is not issue #{n}")
    try:
        j["edits.json"]["data"]["repository"]["issue"]["userContentEdits"]["nodes"]
    except (KeyError, TypeError):
        errs.append(f"{name}: edits.json is not a userContentEdits answer")
    for f, side in (("comments.json", "before"), ("comments-after.json", "after"),
                    ("events.json", "before"), ("events-after.json", "after")):
        rows = j[f]
        if not isinstance(rows, list):
            errs.append(f"{name}: {f} is not an array")
            continue
        for x in rows:
            t = ts(x["created_at"])
            if (side == "before" and t > as_of) or (side == "after" and t <= as_of):
                errs.append("{}: {} holds an object from the wrong side of as_of ({})".format(name, f, x["created_at"]))
                break
    park = [x for x in j["comments.json"] if isinstance(x, dict) and x.get("id") == c["parking_comment_id"]]
    if not park or park[0].get("created_at") != c["parked_at"]:
        errs.append("{}: comments.json lacks the parking comment {} at {}".format(name, c["parking_comment_id"], c["parked_at"]))
    if os.path.isdir(os.path.join(d, "snapshots")):
        for f in sorted(os.listdir(os.path.join(d, "snapshots"))):
            try:
                s = load(os.path.join(d, "snapshots", f))
                assert f.endswith(".json") and set(s) == {"fetched_at", "path", "answer"}
            except (OSError, ValueError, AssertionError):
                errs.append(f"{name}: snapshots/{f} must be {{fetched_at, path, answer}}")
    if not isinstance(exp, dict) or set(exp) != EXPECTED_KEYS:
        errs.append(f"{name}: expected.json keys {sorted(exp) if isinstance(exp, dict) else exp} (want {sorted(EXPECTED_KEYS)})")
        return None, errs
    if exp["outcome"] not in OUTCOMES:
        errs.append("{}: expected outcome {!r}".format(name, exp["outcome"]))
    bo = exp["blocked_on"]
    if exp["outcome"] == "seat":
        if not (isinstance(bo, str) and TARGET.match(bo)):
            errs.append(f"{name}: a seat names its target: blocked_on human | issue=<n|new> | pr=<n> (got {bo!r})")
    elif bo is not None:
        errs.append(f"{name}: blocked_on is null unless the outcome is seat (got {bo!r})")
    if exp["class"] not in ("H", "R", "O", "U"):
        errs.append("{}: class {!r}".format(name, exp["class"]))
    if exp["split"] not in ("train", "heldout"):
        errs.append("{}: split {!r}".format(name, exp["split"]))
    if not (isinstance(exp["basis"], str) and exp["basis"].strip()):
        errs.append(f"{name}: basis is one non-empty line")
    if exp["class"] == "H" and (exp["outcome"], bo) != ("seat", "human"):
        errs.append(f"{name}: an H case expects seat / human")
    summary = {"case": name, "item": c["item"], "writer": c["writer"], "as_of": c["as_of"],
               "rules": r.get("commit", "")[:8] if isinstance(r, dict) else "", "class": exp["class"],
               "split": exp["split"], "outcome": exp["outcome"], "blocked_on": bo}
    return (summary if not errs else None), errs


def check_all(root, git=False):
    if not os.path.isdir(root):
        return [], [f"no cases directory {root}"]
    rows, errs = [], []
    for name in sorted(os.listdir(root)):
        d = os.path.join(root, name)
        if not os.path.isdir(d):
            errs.append(f"unknown file {name} in the cases directory")
            continue
        s, e = check_case(d, git)
        errs += e
        if s:
            rows.append(s)
    if not rows and not errs:
        errs.append(f"no cases under {root}")
    held = [x for x in rows if x["split"] == "heldout"]
    if rows and (sum(1 for x in held if x["class"] == "H") < 1 or sum(1 for x in held if x["class"] in ("R", "O")) < 2):
        errs.append("the held-out set needs at least one H and two R/O cases (has %s)" % [(x["case"], x["class"]) for x in held])
    return rows, errs


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("cmd", nargs="?", default="validate", choices=["list", "validate"])
    ap.add_argument("--dir", default=DEFAULT_DIR)
    ap.add_argument("--git", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args(argv)
    if a.self_test:
        return self_test()
    if a.git and subprocess.run(["git", "-C", ROOT, "rev-parse", "--is-shallow-repository"],
                                capture_output=True, text=True).stdout.strip() == "true":
        # a depth-1 CI checkout holds no old commit: say so, never fail the case shape on it
        print("intake-wait-cases: shallow checkout — rules commits not checked", file=sys.stderr)
        a.git = False
    rows, errs = check_all(a.dir, a.git)
    if a.cmd == "list":
        for x in rows:
            print(f"{x['case']:<18} {x['item']:<28} {x['writer']:<6} {x['class']:<7} {x['split']:<7} "
                  f"{x['outcome']:<9} {x['blocked_on'] or '-':<11} rules@{x['rules']}")
    for e in errs:
        print("intake-wait-cases: " + e, file=sys.stderr)
    n_train = sum(1 for x in rows if x["split"] == "train")
    n_held = sum(1 for x in rows if x["split"] == "heldout")
    print(f"intake-wait-cases: {len(rows)} case(s) valid (train {n_train}, heldout {n_held}), {len(errs)} error(s)",
        file=sys.stderr)
    return 1 if errs else 0


# ── self-test: the real validator over built cases, each defect planted once ───────────────────────────
def self_test():
    fails = []

    def check(nm, cond, got=""):
        print(("  ok   " if cond else "  FAIL ") + nm + ("" if cond else f"  got: {got}"))
        if not cond:
            fails.append(nm)

    def build(root, name, n, cls, split, outcome="seat", bo="human", writer="intake"):
        d = os.path.join(root, name)
        os.makedirs(d)
        P, A = "2026-11-12T05:00:00Z", ("2026-11-12T05:00:00Z" if writer == "intake" else "2026-11-15T05:00:00Z")
        item = f"o/r#{n}"
        files = {
            "case.json": {"schema": "intake-wait-case/v1", "item": item, "parked_at": P, "parking_comment_id": 7,
                          "parked_by": "bot", "writer": writer, "as_of": A, "rules": {"path": "islands/intake/rules/intake.md", "commit": "a" * 40},
                          "island": "gateway", "recorded_at": "2026-11-19T00:00:00Z"},
            "input.json": {"id": item, "kind": "member", "number": n, "title": "t"},
            "issue.json": {"number": n},
            "edits.json": {"data": {"repository": {"issue": {"userContentEdits": {"nodes": []}}}}},
            "comments.json": [{"id": 6, "created_at": "2026-11-11T00:00:00Z"}, {"id": 7, "created_at": P}],
            "comments-after.json": [{"id": 8, "created_at": "2026-11-16T00:00:00Z"}],
            "events.json": [], "events-after.json": [],
            "expected.json": {"outcome": outcome, "blocked_on": bo, "class": cls, "split": split, "basis": "b"},
        }
        for f, v in files.items():
            with open(os.path.join(d, f), "w") as fh:
                json.dump(v, fh)
        return d

    def edit(d, f, fn):
        p = os.path.join(d, f)
        v = load(p)
        v = fn(v) or v
        with open(p, "w") as fh:
            json.dump(v, fh)

    with tempfile.TemporaryDirectory() as root:
        build(root, "a", 1, "H", "heldout")
        build(root, "b", 2, "R", "heldout", "seat", "issue=new")
        build(root, "c", 3, "O", "heldout", "queue", None)
        build(root, "d", 4, "R", "train", "requeue", None, writer="lane")
        rows, errs = check_all(root)
        check("four well-formed cases validate (an intake wait at its parking, a lane wait at its re-read)", len(rows) == 4 and not errs, errs)

        def planted(nm, f, fn, want, case="b"):
            with tempfile.TemporaryDirectory() as r2:
                for c, n, cl, sp, o, bo, w in (("a", 1, "H", "heldout", "seat", "human", "intake"), ("b", 2, "R", "heldout", "seat", "issue=new", "intake"),
                                               ("c", 3, "O", "heldout", "queue", None, "intake")):
                    build(r2, c, n, cl, sp, o, bo, w)
                if f:
                    edit(os.path.join(r2, case), f, fn)
                else:
                    fn(os.path.join(r2, case))
                _, e = check_all(r2)
                check(nm, any(want in x for x in e), e)

        planted("a comment after as_of in comments.json fails", "comments.json", lambda v: v.append({"id": 9, "created_at": "2026-11-13T00:00:00Z"}), "wrong side")
        planted("a missing parking comment fails", "case.json", lambda v: v.update(parking_comment_id=99), "lacks the parking comment")
        planted("an unknown case.json key fails", "case.json", lambda v: v.update(extra=1), "case.json keys")
        planted("a seat without a target fails", "expected.json", lambda v: v.update(blocked_on=None), "a seat names its target")
        planted("a malformed target fails", "expected.json", lambda v: v.update(blocked_on="issue=abc"), "a seat names its target")
        planted("a target on a non-seat fails", "expected.json", lambda v: v.update(outcome="queue"), "blocked_on is null")
        planted("expected.json carrying wording (an extra key) fails", "expected.json", lambda v: v.update(comment="intake: seat — x"), "expected.json keys")
        planted("an H case that does not expect seat/human fails", "expected.json", lambda v: v.update(blocked_on="pr=1"), "an H case", case="a")
        planted("a short rules commit fails", "case.json", lambda v: v["rules"].update(commit="abc"), "rules must be")
        planted("an intake wait replayed after its parking fails", "case.json", lambda v: v.update(as_of="2026-11-13T00:00:00Z"), "as_of == parked_at")
        planted("input.json naming another item fails", "input.json", lambda v: v.update(number=99), "input.json must be")
        planted("an unknown file fails", None, lambda d: open(os.path.join(d, "notes.md"), "w").close(), "unknown file")
        planted("a missing file fails", None, lambda d: os.remove(os.path.join(d, "edits.json")), "missing edits.json")
        planted("a held-out set without two R/O cases fails", "expected.json", lambda v: v.update(split="train"), "held-out set needs")
        check("an absent cases dir fails", check_all(os.path.join(root, "nope"))[1] != [])
    print("intake-wait-cases self-test: " + ("PASS" if not fails else f"FAIL ({len(fails)})"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
