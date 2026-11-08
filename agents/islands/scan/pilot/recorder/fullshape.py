#!/usr/bin/env python3
"""fullshape — rebuild a trimmed replay family as a FULL-SHAPE family that keeps its personas.

    fullshape.py --family <trimmed family dir> --shapes <live-shape dir> --out <dir> [--mode principled|naive]
    fullshape.py --check <full family dir> --shapes <live-shape dir>

Two sources, two jobs:
  * SHAPE comes from the sanitised live recordings (recorder.py → live-shape/<world>/gh/): every key
    gh sends, in gh's order and nesting, with a realistic value per key.
  * PERSONA comes from the trimmed family (worlds/, patches/*.jq, rows/<id>/ overlays): every value
    a fixture author wrote wins, untouched — including spellings live gh never sends (reported).

A key the trimmed world LEFT OUT is filled by a named rule (FILL_RULES below; every fill is logged
to <out>/fill-log.json with file, path, rule). `--mode naive` fills every missing key with the live
exemplar's value verbatim instead — the control that shows which absences carried meaning.

Patches: an ADDING patch (`. + [...]`) is re-emitted with its PRs completed; a MODIFYING patch
(`map(if .number == N then … )`) is re-emitted as a top-level-key delta whose values are completed
(`. + {labels: [<full label>]}`). Patches are computed, never hand-edited; the original's comment
header is kept. Non-JSON world files (a garbage answer modelling a broken transport) are copied
verbatim: there is no full shape of a transport failure.

`--check` materialises every row exactly as run.sh's table mode does and asserts that every PR
carries the 12 `--json` keys and every object's key set equals its live counterpart's.
Stdlib + the jq binary (patch evaluation, exactly as the harness does).
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

PR_KEYS = ("author", "autoMergeRequest", "baseRefName", "createdAt", "headRefName", "headRefOid",
           "labels", "latestReviews", "mergeStateStatus", "number", "reviewDecision", "reviews")
UNIVERSE = "teststuffstash/testrepo"
AGENT_LOGIN = "app/homelab-agents-1234"  # the platform's ordinary PR author (live gh `pr list` bot form)
JQ = os.environ.get("JQ") or shutil.which("jq") or "jq"

FILL_RULES = {
    "P1-author": "PR `author` absent → the agent App in gh's bot form {is_bot, login} — jq read the absent "
                 "key as login null = not Renovate; so does `app/homelab-agents-1234`",
    "P1-author/shape": "(applies too) a persona's bare {login} → the live shape its login implies: bot "
                        "{is_bot, login} for `app/…`, user {id, is_bot, login, name} otherwise",
    "P2-reviews": "PR `reviews` absent → the reviews this row's `pr view` recording carries (the same "
                  "connection; all rows sharing the patch must agree) else the latestReviews, else []",
    "P3-latest": "PR `latestReviews` absent → last review per author from `reviews`, with live's "
                 "zero values (id \"\", commit.oid \"\"), else []",
    "P4-oid": "PR `headRefOid` absent → a fake SHA derived from the PR number",
    "P5-headref": "PR `headRefName` absent → `fix/pr-<n>` (`renovate/…` only ever comes from a persona)",
    "P6-review": "review element: id → fake PRR_ (latestReviews: \"\"), authorAssociation NONE, body \"\", "
                 "includesCreatedEdit false, reactionGroups [], commit.oid → fake SHA (latest: \"\"), "
                 "submittedAt → the same author's submittedAt in `reviews` (latestReviews only)",
    "P7-amr": "autoMergeRequest object: authorEmail null, commitBody null, commitHeadline sanitized, "
              "mergeMethod SQUASH, enabledBy = the PR author",
    "P8-label": "label element: id → fake LA_, description \"\", color ededed",
    "P9-commit": "commit element: authoredDate = committedDate, messageBody \"\", oid = headRefOid for the "
                 "LAST commit (else fake), authors absent → the PR author in commit form "
                 "(app/X → X[bot]); author element: email/id/name derived from login",
    "P10-pv-reviews": "`pr view` `reviews` absent → the board PR's (completed) reviews — `gh pr view "
                      "--json reviews` and `gh pr list --json reviews` read one connection",
    "P11-checkrun": "check-run: live exemplar with id/node_id/urls re-derived, head_sha = the key's SHA, "
                    "completed_at null unless status == completed; top total_count = len(check_runs)",
    "P12-status": "combined status: live exemplar with sha/urls from the key's SHA, total_count = "
                  "len(statuses); status element: live exemplar with id/urls re-derived",
    "P13-pull": "REST pull: live exemplar re-numbered; number/body persona; head.sha/ref, base.ref, user, "
                "auto_merge, mergeable_state derived from the board PR",
    "N-naive": "naive mode: the live exemplar's value, verbatim",
}


def h(s: str, n: int = 40) -> str:
    return hashlib.sha1(f"fullshape:{s}".encode()).hexdigest()[:n]


def fid(s: str) -> int:
    return int(h(s, 8), 16) % 10**9 + 10**9


# ── exemplars from the sanitised live recordings ─────────────────────────────────────────────────


class Shapes:
    def __init__(self, root: Path, exemplar_pr: int | None = None):
        lists = [json.loads(p.read_text()) for p in sorted(root.glob("*/gh/pr-list.json"))]
        prs = [pr for lst in lists for pr in lst]
        self.prs = prs
        self.pr = max(prs, key=lambda p: (len(p["reviews"]) > 0, len(p["labels"]) > 0,
                                          p["autoMergeRequest"] is not None))  # the richest live PR
        if exemplar_pr is not None:  # naive fills are exemplar-DEPENDENT: let the control pick another
            self.pr = next(p for p in prs if p["number"] == exemplar_pr)
        self.pr_order = list(self.pr.keys())
        self.amr = next(p["autoMergeRequest"] for p in prs if p["autoMergeRequest"])
        self.label = next(lb for p in prs for lb in p["labels"])
        self.review = next(r for p in prs for r in p["reviews"])
        self.latest = next(r for p in prs for r in p["latestReviews"])
        self.author_bot = next(p["author"] for p in prs if p["author"]["is_bot"])
        self.author_user = next((p["author"] for p in prs if not p["author"]["is_bot"]), None)
        pv = json.loads(next(root.glob("*/gh/pr-view-*.json")).read_text())
        self.pv_order = list(pv.keys())
        self.commit = pv["commits"][0]
        self.commit_author = self.commit["authors"][0]
        cr = json.loads(next(root.glob("*/gh/*-check-runs-*.json")).read_text())
        self.cr_top, self.check_run = cr, cr["check_runs"][0]
        st = json.loads(next(root.glob("*/gh/*-status.json")).read_text())
        self.st_top, self.status = st, st["statuses"][0]
        pull_f = next(root.glob("*/gh/api-repos-*-pulls-*.json"))
        self.pull = json.loads(pull_f.read_text())
        self.pull_n = self.pull["number"]


# ── completion ───────────────────────────────────────────────────────────────────────────────────


class Filler:
    def __init__(self, shapes: Shapes, mode: str, naive_rules: frozenset = frozenset()):
        self.s, self.mode, self.log, self.naive_rules = shapes, mode, [], naive_rules
        self.live_spelling = False

    def spell(self, login: str, form: str, where: str, path: str) -> str:
        """--live-spelling: rewrite a persona login to the spelling live gh sends on THIS read
        (observed 2026-11-08): `pr list` author = `app/X`; GraphQL review author = bare `X`;
        `pr view` commit author = `X[bot]`. Off by default — personas win."""
        if not self.live_spelling or not login:
            return login
        bare = login[4:] if login.startswith("app/") else login[:-5] if login.endswith("[bot]") else login
        bot = login != bare
        new = {"pr-author": f"app/{bare}" if bot else login, "review": bare,
               "commit": f"{bare}[bot]" if bot else login}[form]
        if form == "review" and login.endswith("[bot]"):
            new = bare
        if new != login:
            self.log.append({"file": where, "path": path, "rule": f"S-spelling {login} → {new}"})
        return new

    def nv(self, rule: str) -> bool:
        """This rule fills from the live exemplar verbatim (naive mode, or an ablation of ONE rule)."""
        return self.mode == "naive" or rule in self.naive_rules

    def note(self, where: str, path: str, rule: str) -> None:
        self.log.append({"file": where, "path": path, "rule": f"N-naive({rule})" if self.nv(rule) else rule})

    def ordered(self, obj: dict, order: list[str]) -> dict:
        out = {k: obj[k] for k in order if k in obj}
        out.update({k: v for k, v in obj.items() if k not in out})  # persona keys gh never sends: kept, last
        return out

    def complete_obj(self, obj, exemplar: dict, where: str, path: str, rule: str, derive=None) -> dict:
        """Missing keys of `obj` ← derive(key) (principled) or the exemplar (naive); exemplar order."""
        if obj is None:
            return None
        out = dict(obj)
        for k, ev in exemplar.items():
            if k in out:
                continue
            if derive and not self.nv(rule):
                v = derive(k)
                out[k] = v if (v is not None or k in DERIVE_NONE) else copy.deepcopy(ev)
            else:
                out[k] = copy.deepcopy(ev)
            self.note(where, f"{path}.{k}", rule)
        return self.ordered(out, list(exemplar.keys()))

    # PR ---------------------------------------------------------------------------------------
    def review(self, r: dict, where: str, path: str, latest: bool, reviews: list | None = None) -> dict:
        ex = self.s.latest if latest else self.s.review
        login = ((r.get("author") or {}).get("login") or "")
        if r.get("author"):
            login = self.spell(login, "review", where, path)
            r = {**r, "author": {**r["author"], "login": login}}

        def d(k):
            if k == "id":
                return "" if latest else f"PRR_{h(where + path + login, 16)}"
            if k == "commit":
                return {"oid": ""} if latest else {"oid": h(where + path + "commit")}
            if k == "submittedAt":
                same = [x.get("submittedAt") for x in (reviews or []) if ((x.get("author") or {}).get("login") or "") == login]
                return max([x for x in same if x], default=ex["submittedAt"])
            return {"authorAssociation": "NONE", "body": "", "includesCreatedEdit": False,
                    "reactionGroups": [], "state": "COMMENTED", "author": {"login": AGENT_LOGIN}}.get(k)
        return self.complete_obj(r, ex, where, path, "P6-review", d)

    def pr(self, pr: dict, where: str, pv_reviews: list | None = None) -> dict:
        n = pr.get("number")
        p = f"pr#{n}"
        out = dict(pr)
        if "author" not in out:
            out["author"] = copy.deepcopy(self.s.pr["author"]) if self.nv("P1-author") else {"is_bot": True, "login": AGENT_LOGIN}
            self.note(where, f"{p}.author", "P1-author")
        if "headRefOid" not in out:
            out["headRefOid"] = self.s.pr["headRefOid"] if self.nv("P4-oid") else h(f"pr-{n}-head")
            self.note(where, f"{p}.headRefOid", "P4-oid")
        if "headRefName" not in out:
            out["headRefName"] = self.s.pr["headRefName"] if self.nv("P5-headref") else f"fix/pr-{n}"
            self.note(where, f"{p}.headRefName", "P5-headref")
        if "reviews" not in out:
            if self.nv("P2-reviews"):
                out["reviews"] = copy.deepcopy(self.s.pr["reviews"])
            elif pv_reviews is not None:
                out["reviews"] = copy.deepcopy(pv_reviews)
            else:
                out["reviews"] = [dict(r) for r in out.get("latestReviews") or []]
            self.note(where, f"{p}.reviews", "P2-reviews")
        if "latestReviews" not in out:
            if self.nv("P3-latest"):
                out["latestReviews"] = copy.deepcopy(self.s.pr["latestReviews"])
            else:
                last: dict = {}
                for r in sorted(out["reviews"], key=lambda r: r.get("submittedAt") or ""):
                    last[((r.get("author") or {}).get("login") or "")] = r
                out["latestReviews"] = [dict(r) for r in last.values()]
            self.note(where, f"{p}.latestReviews", "P3-latest")
        if isinstance(out["author"], dict):
            out["author"] = self.actor(out["author"], where, f"{p}.author")
        for k in PR_KEYS:  # anything else gh always sends (base world: none today)
            if k not in out:
                out[k] = copy.deepcopy(self.s.pr[k])
                self.note(where, f"{p}.{k}", "N-naive")
        out["reviews"] = [self.review(r, where, f"{p}.reviews[{i}]", False) for i, r in enumerate(out["reviews"])]
        out["latestReviews"] = [self.review(r, where, f"{p}.latestReviews[{i}]", True, out["reviews"])
                                for i, r in enumerate(out["latestReviews"])]
        out["labels"] = [self.complete_obj(lb, self.s.label, where, f"{p}.labels[{i}]", "P8-label",
                                           lambda k, lb=lb: {"id": f"LA_{h(lb.get('name', ''), 16)}",
                                                             "description": "", "color": "ededed"}.get(k))
                         for i, lb in enumerate(out["labels"])]
        if out["autoMergeRequest"] is not None:
            author = out["author"]
            out["autoMergeRequest"] = self.complete_obj(
                out["autoMergeRequest"], self.s.amr, where, f"{p}.autoMergeRequest", "P7-amr",
                lambda k: {"commitHeadline": "sanitized commitHeadline", "mergeMethod": "SQUASH",
                           "enabledBy": copy.deepcopy(author) if author else None}.get(k))
        return self.ordered(out, self.s.pr_order)

    def actor(self, a: dict, where: str, path: str) -> dict:
        """gh's PR author has TWO live shapes: a bot {is_bot, login} (login `app/…`), a user
        {id, is_bot, login, name}. A persona's bare {login} is completed to the shape its login implies."""
        login = self.spell(a.get("login") or "", "pr-author", where, path)
        a = {**a, "login": login}
        bot = login.startswith("app/") or login.endswith("[bot]")
        ex = self.s.author_bot if bot or self.s.author_user is None else self.s.author_user
        if self.nv("P1-author"):
            ex = self.s.pr["author"]
        return self.complete_obj(a, ex, where, path, "P1-author",
                                 lambda k: {"is_bot": bot, "id": f"U_{h(login, 16)}", "name": f"Human {h(login, 6)}"}.get(k))

    # pr view ----------------------------------------------------------------------------------
    def commit_form(self, login: str) -> str:
        return (login[4:] + "[bot]") if login.startswith("app/") else login

    def commit_author(self, a: dict, where: str, path: str) -> dict:
        login = self.spell(a.get("login") or "", "commit", where, path)
        a = {**a, "login": login}
        return self.complete_obj(a, self.s.commit_author, where, path, "P9-commit",
                                 lambda k: {"email": f"{login}@users.noreply.invalid",
                                            "id": f"BOT_{h(login, 16)}" if "bot" in login else f"U_{h(login, 16)}",
                                            "name": login}.get(k))

    def pr_view(self, pv: dict, board_pr: dict, where: str) -> dict:
        out = dict(pv)
        commits = out.get("commits") or []
        oid = board_pr["headRefOid"]
        author_c = self.commit_form((board_pr.get("author") or {}).get("login") or "")
        done = []
        for i, c in enumerate(commits):
            c = dict(c)
            if "authors" not in c:
                c["authors"] = copy.deepcopy(self.s.commit["authors"]) if self.nv("P9-commit") else [{"login": author_c}]
                self.note(where, f"commits[{i}].authors", "P9-commit")
            last = i == len(commits) - 1
            c = self.complete_obj(c, self.s.commit, where, f"commits[{i}]", "P9-commit",
                                  lambda k, c=c, last=last, i=i: {"authoredDate": c.get("committedDate"),
                                                                  "messageBody": "",
                                                                  "oid": oid if last else h(f"{where}:c{i}")}.get(k))
            c["authors"] = [self.commit_author(a, where, f"commits[{i}].authors[{j}]") for j, a in enumerate(c["authors"])]
            done.append(c)
        out["commits"] = done
        if "reviews" not in out:
            out["reviews"] = copy.deepcopy(board_pr["reviews"]) if not self.nv("P10-pv-reviews") else copy.deepcopy(self.s.pr["reviews"])
            self.note(where, "reviews", "P10-pv-reviews")
        else:
            out["reviews"] = [self.review(r, where, f"reviews[{i}]", False) for i, r in enumerate(out["reviews"])]
        return self.ordered(out, self.s.pv_order)

    # REST -------------------------------------------------------------------------------------
    def check_runs(self, top: dict, sha: str, where: str) -> dict:
        out = dict(top)
        runs = []
        for i, r in enumerate(out.get("check_runs") or []):
            rid = fid(f"{where}:{i}:{r.get('name')}")
            der = {"id": rid, "node_id": f"CR_{h(str(rid), 16)}", "head_sha": sha,
                   "url": f"https://api.github.com/repos/{UNIVERSE}/check-runs/{rid}",
                   "html_url": f"https://github.com/{UNIVERSE}/runs/{rid}",
                   "details_url": f"https://github.com/{UNIVERSE}/actions/runs/{fid(where)}/job/{rid}",
                   "completed_at": self.s.check_run["completed_at"] if r.get("status") == "completed" else None,
                   "check_suite": {"id": fid(where + ':suite')}}
            runs.append(self.complete_obj(r, self.s.check_run, where, f"check_runs[{i}]", "P11-checkrun",
                                          lambda k: der.get(k)))
        out["check_runs"] = runs
        if "total_count" not in out:
            out["total_count"] = len(runs) if not self.nv("P11-checkrun") else self.s.cr_top["total_count"]
            self.note(where, "total_count", "P11-checkrun")
        return self.ordered(out, list(self.s.cr_top.keys()))

    def status(self, top: dict, sha: str, where: str) -> dict:
        out = dict(top)
        sts = []
        for i, st in enumerate(out.get("statuses") or []):
            sid = fid(f"{where}:{i}:{st.get('context')}")
            der = {"id": sid, "node_id": f"SC_{h(str(sid), 16)}",
                   "url": f"https://api.github.com/repos/{UNIVERSE}/statuses/{sha}", "description": ""}
            sts.append(self.complete_obj(st, self.s.status, where, f"statuses[{i}]", "P12-status", lambda k: der.get(k)))
        out["statuses"] = sts
        der = {"sha": sha, "total_count": len(sts),
               "commit_url": f"https://api.github.com/repos/{UNIVERSE}/commits/{sha}",
               "url": f"https://api.github.com/repos/{UNIVERSE}/commits/{sha}/status"}
        return self.complete_obj(out, self.s.st_top, where, "", "P12-status", lambda k: der.get(k))

    def pull(self, pull: dict, board_pr: dict | None, where: str) -> dict:
        n = pull.get("number")
        ex = json.loads(re.sub(rf"(?<=[/#]){self.s.pull_n}(?!\d)", str(n), json.dumps(self.s.pull)))
        if not self.nv("P13-pull") and board_pr is not None:
            ex["head"]["sha"] = board_pr["headRefOid"]
            ex["head"]["ref"] = board_pr["headRefName"]
            ex["head"]["label"] = f"teststuffstash:{board_pr['headRefName']}"
            ex["base"]["ref"] = board_pr["baseRefName"]
            ex["user"]["login"] = self.commit_form((board_pr.get("author") or {}).get("login") or "")
            ex["mergeable_state"] = board_pr["mergeStateStatus"].lower()
            if board_pr["autoMergeRequest"] is None:
                ex["auto_merge"] = None
        out = dict(pull)
        for k, v in ex.items():
            if k not in out:
                out[k] = v
                self.note(where, k, "P13-pull")
        return self.ordered(out, list(ex.keys()))


DERIVE_NONE: set[str] = {"authorEmail", "commitBody", "completed_at", "auto_merge"}  # derive() may return None ON PURPOSE


# ── the family ───────────────────────────────────────────────────────────────────────────────────


def jq_file(patch: Path, data) -> object:
    p = subprocess.run([JQ, "-f", str(patch)], input=json.dumps(data), capture_output=True, text=True, check=True)
    return json.loads(p.stdout)


def read_rows(fam: Path) -> list[dict]:
    rows = []
    for line in (fam / "rows.psv").read_text().split("\n")[:-1]:
        if not line or line.startswith("#"):
            continue
        c = [x.strip() for x in line.split("|")] + [""] * 6
        if c[0]:
            rows.append({"id": c[0], "world": c[1] or "board", "patch": c[2], "env": c[3], "expect": c[4], "params": c[5]})
    return rows


def header(text: str) -> str:
    return "".join(ln + "\n" for ln in text.split("\n") if ln.startswith("#"))


def build(fam: Path, shapes: Shapes, out: Path, mode: str, naive_rules: frozenset = frozenset(),
          live_spelling: bool = False) -> dict:
    f = Filler(shapes, mode, naive_rules)
    f.live_spelling = live_spelling
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    for name in ("bridge.sh", "rows.psv"):
        shutil.copy2(fam / name, out / name)
    shutil.copytree(fam / "expected", out / "expected")
    (out / "fixture.yaml").write_text(
        "# CONSTRUCTED full-shape copy of agents/replay/fixtures/updater — generated by\n"
        "# agents/islands/scan/pilot/recorder/fullshape.py (never hand-edit; rebuild). The family contract\n"
        "# prose lives in the original fixture.yaml; rows.psv, bridge.sh and expected/ are byte copies.\n"
        "pins:\n  - MP-T02\nname: updater-fullshape\nmode: table\nparts:\n  - file:bridge.sh\nrows: rows.psv\n")
    rows = read_rows(fam)
    base = json.loads((fam / "worlds/board/gh/pr-list.json").read_text())
    base_nums = [p["number"] for p in base]

    # row → (patched trimmed board, its pr-view reviews per PR)
    pv_reviews: dict[tuple[str, int], list] = {}
    for r in rows:
        for pvf in (fam / "rows" / r["id"] / "gh").glob("pr-view-*.json") if (fam / "rows" / r["id"]).is_dir() else []:
            try:
                pv = json.loads(pvf.read_text())
            except ValueError:
                continue
            if "reviews" in pv and r["patch"]:
                n = int(pvf.stem.split("-")[-1])
                key = (r["patch"], n)
                if key in pv_reviews and pv_reviews[key] != pv["reviews"]:
                    pv_reviews[key] = None  # rows sharing the patch disagree → no derivation
                    f.log.append({"file": r["patch"], "path": f"pr#{n}.reviews", "rule": "P2-reviews: rows DISAGREE, left to latestReviews/[]"})
                elif key not in pv_reviews:
                    pv_reviews[key] = pv["reviews"]

    # base world
    full_base = [f.pr(pr, "worlds/board/gh/pr-list.json") for pr in base]
    (out / "worlds/board/gh").mkdir(parents=True)
    (out / "worlds/board/gh/pr-list.json").write_text(json.dumps(full_base, indent=2) + "\n")
    (out / "worlds/board/provenance.yaml").write_text(
        "# provenance — CONSTRUCTED by recorder/fullshape.py: shape from the sanitised live recordings,\n"
        "# persona from the trimmed family. Every filled key is in ../../fill-log.json.\n"
        "world: board\nclass: constructed\n"
        "shape_from: agents/islands/scan/pilot/recorder/live-shape/   # class: recorded (provenance.yaml there)\n"
        "persona_from: agents/replay/fixtures/updater/worlds/board/gh/pr-list.json\n"
        f"fill_mode: {mode}{' naive=' + ','.join(sorted(naive_rules)) if naive_rules else ''}\n")

    # patches
    (out / "patches").mkdir()
    boards: dict[str, list] = {}
    for pf in sorted((fam / "patches").glob("*.jq")):
        rel = f"patches/{pf.name}"
        trimmed = jq_file(pf, base)
        tnums = [p["number"] for p in trimmed]
        where = rel
        rel_patch = next((r["patch"] for r in rows if r["patch"].endswith(rel)), "")
        if tnums[:len(base)] == base_nums and trimmed[:len(base)] == base:
            added = [f.pr(p, where, (pv_reviews.get((rel_patch, p["number"])) or None)) for p in trimmed[len(base):]]
            body = ". + " + json.dumps(added, indent=2)
            board = full_base + added
        else:
            assert len(trimmed) == len(base), f"{pf.name}: neither an add nor an in-place modify"
            deltas = []
            board = []
            for old, new, fb in zip(base, trimmed, full_base):
                changed = {k: v for k, v in new.items() if old.get(k) != v}
                if not changed:
                    board.append(fb)
                    continue
                fullnew = f.pr({**fb, **changed}, where)
                delta = {k: fullnew[k] for k in changed}
                deltas.append((old["number"], delta))
                board.append(fullnew)
            body = "map(" + " | ".join(
                f"if .number == {n} then . + {json.dumps(d, indent=2)} else . end" for n, d in deltas) + ")"
        boards[rel] = board
        (out / rel).write_text(header(pf.read_text()) +
                               f"# GENERATED by agents/islands/scan/pilot/recorder/fullshape.py from the trimmed "
                               f"agents/replay/fixtures/updater/{rel} — never hand-edit.\n" + body + "\n")

    # row overlays
    for r in rows:
        src = fam / "rows" / r["id"]
        if not src.is_dir():
            continue
        prel = r["patch"].split("@")[1].strip() if "@" in r["patch"] else ""
        board = boards.get(prel, full_base)
        by_n = {p["number"]: p for p in board}
        for fp in sorted(src.rglob("*")):
            if not fp.is_file():
                continue
            rel = fp.relative_to(src)
            dst = out / "rows" / r["id"] / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            where = f"rows/{r['id']}/{rel}"
            try:
                data = json.loads(fp.read_text())
            except ValueError:
                shutil.copy2(fp, dst)
                f.log.append({"file": where, "path": "", "rule": "verbatim: not JSON (a transport-failure persona)"})
                continue
            stem = fp.stem
            m_pv = re.fullmatch(r"pr-view-(\d+)", stem)
            m_sha = re.search(r"-commits-([0-9a-z]+)-(check-runs-per-page-100|status)$", stem)
            m_pull = re.fullmatch(r"api-repos-.*-pulls-(\d+)", stem)
            if m_pv:
                data = f.pr_view(data, by_n[int(m_pv.group(1))], where)
            elif m_sha and m_sha.group(2).startswith("check-runs"):
                data = f.check_runs(data, m_sha.group(1), where)
            elif m_sha:
                data = f.status(data, m_sha.group(1), where)
            elif m_pull:
                data = f.pull(data, by_n.get(int(m_pull.group(1))), where)
            else:
                raise SystemExit(f"unclassified world file: {where}")
            dst.write_text(json.dumps(data, indent=2) + "\n")
    (out / "fill-log.json").write_text(json.dumps(f.log, indent=1) + "\n")
    return {"fills": len(f.log)}


# ── check: every materialised row is full-shape ──────────────────────────────────────────────────


def keyset_diff(obj, ex, path: str, errs: list) -> None:
    if isinstance(obj, dict) and isinstance(ex, dict):
        miss = [k for k in ex if k not in obj]
        if miss:
            errs.append(f"{path}: missing {miss}")
        for k in ex:
            if k in obj:
                keyset_diff(obj[k], ex[k], f"{path}.{k}", errs)
    elif isinstance(obj, list) and isinstance(ex, list) and ex and isinstance(ex[0], dict):
        for i, x in enumerate(obj):
            keyset_diff(x, ex[0], f"{path}[{i}]", errs)


def check(full: Path, shapes: Shapes) -> int:
    rows = read_rows(full)
    bad = 0
    for r in rows:
        board = json.loads((full / "worlds/board/gh/pr-list.json").read_text())
        if r["patch"]:
            board = jq_file(full / r["patch"].split("@")[1].strip(), board)
        errs: list[str] = []
        for pr in board:
            if tuple(sorted(pr)) != tuple(sorted(PR_KEYS)):
                errs.append(f"pr#{pr.get('number')}: keys {sorted(pr)}")
            ex = dict(shapes.pr)
            if pr["autoMergeRequest"] is None:
                ex.pop("autoMergeRequest")
            else:
                ex["autoMergeRequest"] = shapes.amr
            ex["latestReviews"], ex["reviews"], ex["labels"] = [shapes.latest], [shapes.review], [shapes.label]
            ex["author"] = shapes.author_bot if pr["author"].get("is_bot") else shapes.author_user
            keyset_diff(pr, ex, f"pr#{pr['number']}", errs)
        rd = full / "rows" / r["id"] / "gh"
        for fp in sorted(rd.glob("*.json")) if rd.is_dir() else []:
            try:
                data = json.loads(fp.read_text())
            except ValueError:
                continue
            ex = ({"commits": [shapes.commit], "reviews": [shapes.review]} if fp.stem.startswith("pr-view")
                  else {**shapes.cr_top, "check_runs": [shapes.check_run]} if "check-runs" in fp.stem
                  else {**shapes.st_top, "statuses": [shapes.status]} if fp.stem.endswith("-status")
                  else shapes.pull)
            keyset_diff(data, ex, fp.name, errs)
        if errs:
            bad += 1
            print(f"✗ {r['id']}: " + "; ".join(errs[:4]))
    print(f"full-shape check: {len(rows) - bad}/{len(rows)} rows full-shape")
    return 1 if bad else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--family")
    ap.add_argument("--shapes", required=True)
    ap.add_argument("--out")
    ap.add_argument("--mode", choices=("principled", "naive"), default="principled")
    ap.add_argument("--naive-rule", action="append", default=[],
                    help="ablation: fill THIS rule's keys from the live exemplar verbatim, every other rule principled")
    ap.add_argument("--exemplar-pr", type=int, help="naive fills: take values from THIS live PR (default: the richest)")
    ap.add_argument("--live-spelling", action="store_true", help="rewrite persona logins to the live per-read spelling")
    ap.add_argument("--check")
    a = ap.parse_args()
    shapes = Shapes(Path(a.shapes), a.exemplar_pr)
    if a.check:
        return check(Path(a.check), shapes)
    print(build(Path(a.family), shapes, Path(a.out), a.mode, frozenset(a.naive_rule), a.live_spelling))
    return 0


if __name__ == "__main__":
    sys.exit(main())
