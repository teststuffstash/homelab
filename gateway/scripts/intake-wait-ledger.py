#!/usr/bin/env python3
"""intake-wait-ledger — the tally behind the wait read's accumulation bar (gateway/intake-wait.md).

Reads wait records (one per parking comment, written by step W of gateway/intake.md and carried in each
APPLY receipt's `waits`) and prints, deterministically:
  - per rule-line KEY: the records and the distinct ITEMS behind it, by class;
  - per class: how many records (intake-written waits only — a wait a ride or a reviewer wrote is listed
    apart and never counts toward the island's tally);
  - which keys have reached the bar: R or O records on >= --bar (default 2) distinct items.
A proposal (step W's `INTAKE-WAIT-PROPOSAL`) is kept only for a key at the bar; the items behind it come
from this ledger, never from the proposer.

The KEY of a `rule:` line is `<file>|<mark>|<the line's first eight words>`, the words lower-cased with
markdown and punctuation stripped (`caused`: the line that produced the wait; `missing`: the line the
missing one would FOLLOW) — so two records naming the same line are one key whatever its line number.

  python3 gateway/scripts/intake-wait-ledger.py [--dir <bucket-shaped dir>] [--island gateway]
        [--records <file.json|.jsonl>]... [--proposals <file>] [--bar 2] [--json]
  python3 gateway/scripts/intake-wait-ledger.py --self-test

--dir reads <dir>/homelab/intake-<island>-*/*/receipt.json (APPLY receipts only, schema
island-intake-receipt/v1), `waits[]`; --records adds records (a JSON array, or one JSON object per line).
A record appearing twice (same `wait` id) counts once, the later one winning. Exit 0; 2 on unreadable input.
"""
import argparse
import contextlib
import glob
import io
import json
import os
import re
import sys
import tempfile

CLASSES = ("H", "R", "O", "U")
MARKS = ("caused", "missing")


def norm_words(text, n=8):
    t = re.sub(r"[`*_>\[\]()\"'“”‘’«»]", " ", str(text or "")).lower()
    t = re.sub(r"[^a-z0-9§/.:=+-]+", " ", t)
    words = [w.strip(".:,;") for w in t.split()]
    return " ".join([w for w in words if w][:n])


def rule_key(rule):
    f = str(rule.get("file", "")).strip()
    m = str(rule.get("mark", "")).strip()
    return "{}|{}|{}".format(f, m, norm_words(rule.get("words", "")))


SAMPLE = 120  # characters of an unparseable line kept as its sample


def load_records_file(path, bad=None):
    """→ the JSON objects of <path> (an array, or one object per line). A line — or a whole array — that is not
    a JSON object is model output gone wrong, never fatal: it is skipped and, when <bad> is a list, its truncated
    text appended there; every valid object is kept. Only an unreadable FILE raises (OSError)."""
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    text = text.strip()
    bad = [] if bad is None else bad
    if not text:
        return []
    if text.startswith("["):
        try:
            data = json.loads(text)
        except ValueError:
            bad.append(text[:SAMPLE])
            return []
        out = [r for r in data if isinstance(r, dict)]
        bad += [json.dumps(r)[:SAMPLE] for r in data if not isinstance(r, dict)]
        return out
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except ValueError:
            r = None
        if isinstance(r, dict):
            out.append(r)
        else:
            bad.append(line[:SAMPLE])
    return out


def load_dir(d, island):
    out = []
    pat = os.path.join(d, "homelab", f"intake-{island}-*", "*", "receipt.json")
    for p in sorted(glob.glob(pat)):
        try:
            with open(p, encoding="utf-8") as fh:
                rc = json.load(fh)
        except (OSError, ValueError):
            print(f"intake-wait-ledger: unreadable {p} — skipped", file=sys.stderr)
            continue
        if rc.get("schema") != "island-intake-receipt/v1" or rc.get("mode") != "apply":
            continue
        for r in rc.get("waits") or []:
            if isinstance(r, dict):
                out.append(r)
    return out


def valid(r):
    return (isinstance(r.get("wait"), str) and r.get("class") in CLASSES
            and isinstance(r.get("rules", []), list)
            and all(isinstance(x, dict) and x.get("mark") in MARKS and x.get("file") for x in r.get("rules", [])))


def tally(records, bar=2):
    by_wait = {}
    bad = 0
    for r in records:
        if not valid(r):
            bad += 1
            continue
        by_wait[r["wait"]] = r
    recs = list(by_wait.values())
    mine = [r for r in recs if r.get("writer", "intake") == "intake"]
    other = [r for r in recs if r.get("writer", "intake") != "intake"]
    classes = {c: sum(1 for r in mine if r["class"] == c) for c in CLASSES}
    other_classes = {c: sum(1 for r in other if r["class"] == c) for c in CLASSES}
    false_recs = [r for r in mine if r["class"] in ("R", "O")]
    keys = {}
    for r in mine:
        for rule in r.get("rules", []):
            k = rule_key(rule)
            e = keys.setdefault(k, {"key": k, "file": rule["file"], "mark": rule["mark"],
                                    "words": norm_words(rule.get("words", "")), "records": [],
                                    "items": set(), "false_items": set(),
                                    "classes": {c: 0 for c in CLASSES}, "widens": False})
            e["records"].append(r["wait"])
            e["items"].add(r.get("item") or r["wait"].split("@")[0])
            e["classes"][r["class"]] += 1
            if r["class"] in ("R", "O"):
                e["false_items"].add(r.get("item") or r["wait"].split("@")[0])
                e["widens"] = e["widens"] or bool(r.get("widens"))
    rows = []
    for k in sorted(keys):
        e = keys[k]
        rows.append({"key": k, "file": e["file"], "mark": e["mark"], "words": e["words"],
                     "records": sorted(e["records"]), "items": sorted(e["items"]),
                     "false_items": sorted(e["false_items"]), "classes": e["classes"],
                     "widens": e["widens"], "at_bar": len(e["false_items"]) >= bar})
    return {
        "schema": "intake-wait-ledger/v1", "bar": bar,
        "records": len(mine), "invalid": bad,
        "classes": classes,
        "false_waits": {"records": len(false_recs),
                        "items": len({r.get("item") or r["wait"].split("@")[0] for r in false_recs})},
        "other_writers": {"records": len(other), "classes": other_classes},
        "keys": rows,
        "at_bar": [x["key"] for x in rows if x["at_bar"]],
    }


def check_proposals(ledger, proposals):
    at = {x["key"]: x for x in ledger["keys"] if x["at_bar"]}
    kept, dropped = [], []
    for p in proposals:
        if not isinstance(p, dict):
            continue
        k = p.get("key") or rule_key(p)
        if k in at and isinstance(p.get("diff"), str) and p.get("diff").strip():
            kept.append({"key": k, "file": at[k]["file"], "diff": p["diff"],
                         "items": at[k]["false_items"], "records": at[k]["records"],
                         "widens_authority": bool(p.get("widens_authority", at[k]["widens"])) or at[k]["widens"]})
        else:
            dropped.append({"key": k, "reason": "not at the bar" if k not in at else "no diff"})
    return kept, dropped


def text_report(ledger):
    cls = " ".join(f"{c}={ledger['classes'][c]}" for c in CLASSES)
    fw = ledger["false_waits"]
    lines = [f"records (intake-written): {ledger['records']} · classes {cls} · "
             f"false waits: {fw['records']} record(s) on {fw['items']} item(s)"]
    if ledger["other_writers"]["records"]:
        lines.append(f"other writers (not tallied): {ledger['other_writers']['records']} record(s)")
    for x in ledger["keys"]:
        kc = " ".join(f"{c}={x['classes'][c]}" for c in CLASSES if x["classes"][c])
        lines.append(f"{'AT-BAR' if x['at_bar'] else '      '} {x['key']}  items={len(x['items'])} "
                     f"(R/O on {len(x['false_items'])}) {kc}{' widens' if x['widens'] else ''}")
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dir")
    ap.add_argument("--island", default="gateway")
    ap.add_argument("--records", action="append", default=[])
    ap.add_argument("--proposals")
    ap.add_argument("--bar", type=int, default=int(os.environ.get("INTAKE_WAIT_BAR", "2")))
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args(argv)
    if a.self_test:
        return self_test()
    recs, bad_recs, bad_props = [], [], []
    try:
        if a.dir:
            if not os.path.isdir(os.path.join(a.dir, "homelab")):
                print(f"intake-wait-ledger: {a.dir} has no homelab/ — not a bucket-shaped dir", file=sys.stderr)
                return 2
            recs += load_dir(a.dir, a.island)
        for f in a.records:
            recs += load_records_file(f, bad_recs)
    except OSError as e:
        print(f"intake-wait-ledger: unreadable input: {e}", file=sys.stderr)
        return 2
    led = tally(recs, a.bar)
    if a.proposals:
        try:
            props = load_records_file(a.proposals, bad_props)
        except OSError as e:
            print(f"intake-wait-ledger: unreadable proposals: {e}", file=sys.stderr)
            return 2
        led["proposals"], led["dropped"] = check_proposals(led, props)
        led["dropped"] += [{"key": None, "reason": "unparseable", "sample": b} for b in bad_props]
    led["unparseable"] = {"records": {"count": len(bad_recs), "samples": bad_recs[:5]},
                          "proposals": {"count": len(bad_props), "samples": bad_props[:5]}}
    print(json.dumps(led, indent=1, sort_keys=True) if a.json else text_report(led))
    return 0


# ── self-test: the real functions over a bucket-shaped temp dir ─────────────────────────────────────
def self_test():
    fails = []

    def check(name, cond, got=""):
        print(("  ok   " if cond else "  FAIL ") + name + ("" if cond else f"  got: {got}"))
        if not cond:
            fails.append(name)

    H = "teststuffstash/homelab"
    step3 = {"file": "gateway/intake.md", "mark": "caused",
             "words": "3. **Does it need a human fact?** The body (or meta-state) says"}
    step3_moved = {"file": "gateway/intake.md", "mark": "caused",
                   "words": "3. Does it need a human fact? The body or meta-state says"}
    facts_missing = {"file": "gateway/intake.md", "mark": "missing",
                     "words": "- Sibling sets (step 3's parity check): the rails — `opencode`,"}

    def rec(wait, cls, rules, writer="intake", widens=False):
        return {"wait": wait, "item": wait.split("@")[0], "class": cls, "rules": rules, "writer": writer, "widens": widens}

    with tempfile.TemporaryDirectory() as d:
        def receipt(day, run, mode, waits):
            p = os.path.join(d, "homelab", f"intake-gateway-{day}", run)
            os.makedirs(p)
            with open(os.path.join(p, "receipt.json"), "w") as fh:
                json.dump({"schema": "island-intake-receipt/v1", "mode": mode, "waits": waits}, fh)
        # item #1: two parking comments, both R on step 3 → ONE item behind the key
        receipt("2026-11-10", "a", "apply", [rec(H + "#1@2026-11-01T00:00:00Z/released", "R", [step3]),
                                             rec(H + "#1@2026-11-02T00:00:00Z/released", "R", [step3])])
        # a dry-run receipt's records never count
        receipt("2026-11-11", "b", "dry-run", [rec(H + "#9@2026-11-01T00:00:00Z/released", "R", [step3])])
        # an H record confirms the same line; a ride-written R is listed apart
        receipt("2026-11-12", "c", "apply", [rec(H + "#2@2026-11-03T00:00:00Z/released", "H", [step3]),
                                             rec(H + "#3@2026-11-03T00:00:00Z/released", "R", [step3], writer="lane")])
        # an unreadable receipt is skipped, never fatal
        os.makedirs(os.path.join(d, "homelab", "intake-gateway-2026-11-13", "z"))
        with open(os.path.join(d, "homelab", "intake-gateway-2026-11-13", "z", "receipt.json"), "w") as fh:
            fh.write("{not json")
        led = tally(load_dir(d, "gateway"))
        k3 = rule_key(step3)
        row = [x for x in led["keys"] if x["key"] == k3]
        # expected from the contract: #1 (two R records, one item) + #2 (H) → items {#1,#2}, false_items {#1}
        check("two parking comments of ONE item are one item behind the key (not at the bar)",
              row and row[0]["false_items"] == [H + "#1"] and not row[0]["at_bar"], row)
        check("an H record is counted on the key but never toward the bar", row and row[0]["classes"]["H"] == 1, row)
        check("a dry-run receipt counts nothing; a ride-written wait is listed apart",
              led["records"] == 3 and led["other_writers"]["records"] == 1, (led["records"], led["other_writers"]))
        check("the key ignores markdown and punctuation (the same line, re-typed, is the same key)",
              rule_key(step3) == rule_key(step3_moved), (rule_key(step3), rule_key(step3_moved)))
        # this sitting's records: #4 R on step 3 (reaches the bar: #1 + #4), #5 O on a missing facts line (one item)
        fresh = os.path.join(d, "fresh.jsonl")
        with open(fresh, "w") as fh:
            fh.write(json.dumps(rec(H + "#4@2026-11-14T00:00:00Z/released", "R", [step3], widens=True)) + "\n")
            fh.write(json.dumps(rec(H + "#5@2026-11-14T00:00:00Z/standing", "O", [facts_missing])) + "\n")
            fh.write(json.dumps({"wait": "x", "class": "Z"}) + "\n")
        led = tally(load_dir(d, "gateway") + load_records_file(fresh))
        check("R/O records on two distinct items put the key at the bar", led["at_bar"] == [k3], led["at_bar"])
        check("a malformed record is counted invalid, never tallied", led["invalid"] == 1, led["invalid"])
        check("classes count intake-written records: R=3 (#1 twice, #4) H=1 O=1",
              led["classes"] == {"H": 1, "R": 3, "O": 1, "U": 0}, led["classes"])
        check("the false-wait KPI: 4 R/O records on 3 items", led["false_waits"] == {"records": 4, "items": 3}, led["false_waits"])
        km = rule_key(facts_missing)
        check("a missing line keys on the line it would follow, `missing` mark",
              km.startswith("gateway/intake.md|missing|- sibling sets"), km)
        kept, dropped = check_proposals(led, [dict(step3, diff="-old\n+new"), dict(facts_missing, diff="+x"), dict(step3, diff="")])
        check("a proposal is kept only at the bar, with the ledger's items and widens",
              len(kept) == 1 and kept[0]["items"] == [H + "#1", H + "#4"] and kept[0]["widens_authority"] is True, kept)
        check("…a proposal below the bar or without a diff is dropped with a reason",
              [x["reason"] for x in dropped] == ["not at the bar", "no diff"], dropped)
        check("--bar is a knob (3: nothing at the bar)", tally(load_dir(d, "gateway") + load_records_file(fresh), 3)["at_bar"] == [])
        # model output gone wrong: a malformed proposal line beside a valid one, a malformed record line beside
        # valid ones — each skipped and counted with a sample, everything valid kept (never exit 2)
        props = os.path.join(d, "props.jsonl")
        with open(props, "w") as fh:
            fh.write(json.dumps(dict(step3, diff="-old\n+new")) + "\n")
            fh.write('{"file": "gateway/intake.md", "diff": "+x" BROKEN\n')
        with open(fresh, "a") as fh:
            fh.write("{not json at all\n")
        out = os.path.join(d, "out.json")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = main(["--dir", d, "--records", fresh, "--proposals", props, "--json"])
        got = json.loads(buf.getvalue()) if rc == 0 else {}
        with open(out, "w") as fh:
            fh.write(buf.getvalue())
        check("a malformed proposal line is skipped and counted; the valid proposal beside it is kept",
              rc == 0 and len(got.get("proposals", [])) == 1 and got["unparseable"]["proposals"]["count"] == 1
              and any(x["reason"] == "unparseable" and x["sample"].startswith('{"file"') for x in got.get("dropped", [])), got)
        check("a malformed record line is skipped and counted; the bar still stands on the valid records",
              rc == 0 and got["unparseable"]["records"]["count"] == 1 and got["at_bar"] == [k3]
              and got["false_waits"] == {"records": 4, "items": 3}, got.get("unparseable"))
        bad = []
        arr = os.path.join(d, "arr.json")
        with open(arr, "w") as fh:
            fh.write('[{"wait": "a", "class": "R"}, 7')
        check("a whole array that is not JSON is one dropped sample, never a raise",
              load_records_file(arr, bad) == [] and len(bad) == 1, bad)
        rc = main(["--dir", os.path.join(d, "nowhere")])
        check("a dir that is not bucket-shaped is exit 2, never an empty tally", rc == 2, rc)
    print("intake-wait-ledger self-test: " + ("PASS" if not fails else f"FAIL ({len(fails)})"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
