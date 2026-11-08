#!/usr/bin/env python3
"""recorder — record a REAL `gh` answer into a replay world, sanitised, with machine provenance.

    recorder.py record   --world <dir> [--source o/r] [--universe o/r] [--raw-cache <dir>] -- gh <argv…>
    recorder.py sanitize --world <dir> [--source o/r] [--universe o/r]  --raw-cache <dir>

`record` runs the gh invocation EXACTLY as the script under test spells it (against the live
`--source` repo), minus `--jq`/`-q` (the replay stub evaluates the script's `--jq` at serve time,
so the world must hold the raw answer). The world file name is the STUB'S key — computed by
sourcing agents/replay/stubs/_common.sh (`_rp_words` + `_rp_slug`), never a port of it — over the
SANITISED argv: a SHA or a repo name inside a path is part of the key, so the argv and the payload
go through the same rewrite and `commits/<sha>/check-runs` keys on the same fake SHA the board's
`headRefOid` carries.

The raw (unsanitised) answer goes to --raw-cache only (default: $RECORDER_TMP, never the tree), so
`sanitize` can re-derive the world after a rewrite-list change without another network call.

Provenance: one `provenance.yaml` per world (the registry's existing file — run.sh table mode
strips it when it materialises a world, and `run.sh --rerecord` reads its `recorded:` entries),
appended per file as `{path, cmd, at, source}`.

The sanitiser's rewrite list is SANITISE_DOC below; it is mechanical (no hand edits) and keeps the
markers the updater reads (login prefixes/suffixes, `Merge branch ` headlines, the rebase-check
box, label names, check names, branch first segments). Stdlib only.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]  # agents/islands/scan/pilot/recorder → repo root
COMMON = ROOT / "agents/replay/stubs/_common.sh"
SOURCE = "teststuffstash/homelab"
UNIVERSE = "teststuffstash/testrepo"  # agents/replay/fixtures/updater/bridge.sh pins it
SALT = "replay-recorder-v1"

SANITISE_DOC = """
1. repo:      `<source>` → `<universe>` in every string (path-anchored; `homelab-reviewer` untouched)
2. SHAs:      every 40-hex string (anywhere in a string) → sha1(salt:sha) — stable across calls
3. ids:       `id`/`databaseId`/`fullDatabaseId`/`node_id`/`external_id` → hashed, same type and
              node-id prefix (`PR_`, `PRR_`, `CR_`, `MDQ6…` → `X_`); an EMPTY id stays empty
4. logins:    KEPT when they carry a meaning the scripts read: `app/…`, `…[bot]`, `homelab-*`,
              `renovate*`, `github`, `github-actions`, `dependabot*`, `ghost`, and the org itself (the
              universe's owner — `teststuffstash`, pinned by bridge.sh); every other login →
              `human-<h6>`, replaced in EVERY string (URLs included) once collected
5. people:    `name` inside an actor/user/author object → `Human <h6>` (bots: kept); `email` →
              `<login>@users.noreply.invalid`; any other e-mail-shaped string likewise (except the
              `git@github.com` of an ssh_url)
6. prose:     `title`, `body`, `messageBody`, `commitHeadline`/`commitBody`, `commit_title`/`commit_message`, `message`, `description` (review/label/status/repo), check
              `output.{title,summary,text}`, `annotations` text → `sanitized <key>`; a body keeps
              every line carrying an HTML-comment marker (`<!-- rebase-check -->`, …), with
              base64 runs ≥40 chars inside it → `sanitized` (renovate-debug payloads) and
              7–39-hex runs (short SHAs, session ids) → hashed, same length
7. headlines: `messageHeadline` keeps `Merge branch '<b>' into <b>` (branches per 8) or the
              conventional-commit prefix up to `:`; the rest → `sanitized headline`
8. branches:  `headRefName`/`ref`/`head_branch`/`label` (owner:branch) keep the first `/` segment
              (`renovate/`, `fix/`, `goal/`), the rest → h6; `master`/`main` kept
9. repos:     a repository object's `name` (dict has `full_name`, or the value is a source repo
              name) → the universe's; a numeric id ≥4 digits inside a URL path → the same fake id
              its `id` field got (check-run/job/status ids)
10. urls:     avatars → `https://avatars.invalid/u/<id>`; gravatar ids dropped; everything else
              rewritten by rules 1, 2, 4 only
Not rewritten: dates, states/enums, label names, check/status names, PR numbers, counts.
"""

KEEP_LOGIN = re.compile(r"^(app/.*|.*\[bot\]|homelab-.*|renovate.*|github|github-actions|dependabot.*|ghost|Copilot)$")
SHA40 = re.compile(r"(?<![0-9a-f])[0-9a-f]{40}(?![0-9a-f])")
HEX = re.compile(r"(?<![0-9A-Za-z])[0-9a-f]{7,39}(?![0-9A-Za-z])")  # short SHAs / session ids in marker lines
B64 = re.compile(r"[A-Za-z0-9+/]{40,}={0,2}")
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
PROSE_KEYS = {"title", "body", "messageBody", "description", "summary", "text", "body_text", "body_html",
              "commitHeadline", "commitBody", "message", "commit_title", "commit_message"}
ID_KEYS = {"id", "databaseId", "fullDatabaseId", "node_id", "external_id"}
BRANCH_KEYS = {"headRefName", "ref", "head_branch"}


def h(s: str, n: int = 6) -> str:
    return hashlib.sha1(f"{SALT}:{s}".encode()).hexdigest()[:n]


def fake_sha(s: str) -> str:
    return hashlib.sha1(f"{SALT}:sha:{s}".encode()).hexdigest()


# ── the stub's key grammar — sourced, not ported ─────────────────────────────────────────────────


def stub_key(argv: list[str]) -> str:
    """`gh <argv>` → the world file stem the replay stub serves (`_rp_slug "$(_rp_words …)"`)."""
    p = subprocess.run(["sh", "-c", '_RP_TOOL=gh; . "$0"; _rp_slug "$(_rp_words "$@")"', str(COMMON), *argv],
                       capture_output=True, text=True, check=True)
    return p.stdout.strip()


# ── sanitiser ────────────────────────────────────────────────────────────────────────────────────


class Sanitiser:
    def __init__(self, sources: list[str], universe: str):
        self.sources, self.universe = sources, universe
        self.logins: dict[str, str] = {}
        self.repo_names = {r.split("/")[1] for r in sources}
        self.ids: dict[str, str] = {}
        self.owners = {r.split("/")[0] for r in [*sources, universe]}  # the org is the universe, keep it
        self.repo_re = re.compile("(?:" + "|".join(re.escape(x) for x in sources) + r")(?![\w-])")

    # pass 1: every human login, so pass 2 can rewrite it inside URLs and prose alike
    def collect(self, v, parent_key: str = "") -> None:
        if isinstance(v, dict):
            for k, x in v.items():
                if k in ID_KEYS and isinstance(x, int) and not isinstance(x, bool) and x > 999:
                    self.ids[str(x)] = str(self.ident(k, x))
                if k == "login" and isinstance(x, str) and not KEEP_LOGIN.match(x) and x not in self.owners:
                    self.logins.setdefault(x, f"human-{h(x)}")
                self.collect(x, k)
        elif isinstance(v, list):
            for x in v:
                self.collect(x, parent_key)

    def string(self, s: str) -> str:
        s = self.repo_re.sub(self.universe, s)
        s = SHA40.sub(lambda m: fake_sha(m.group(0)), s)
        for real, fake in sorted(self.logins.items(), key=lambda kv: -len(kv[0])):
            s = re.sub(r"(?<![\w-])" + re.escape(real) + r"(?![\w-])", fake, s)
        if self.ids:  # a numeric id inside a URL path → the same fake id the `id` field carries
            s = re.sub(r"(?<=/)(\d{4,})(?![\d])", lambda m: self.ids.get(m.group(1), m.group(1)), s)
        s = EMAIL.sub(lambda m: m.group(0) if m.group(0) == "git@github.com" else f"{h(m.group(0))}@users.noreply.invalid", s)
        return s

    def branch(self, b: str) -> str:
        if b in ("master", "main") or not b:
            return b
        head, sep, rest = b.partition("/")
        return f"{head}/{h(b)}" if sep else h(b)

    def headline(self, s: str) -> str:
        m = re.match(r"^Merge branch '([^']*)'(?: of \S+)? into (\S+)$", s)
        if m:
            return f"Merge branch '{self.branch(m.group(1))}' into {self.branch(m.group(2))}"
        m = re.match(r"^([a-z]+(?:\([^)]*\))?!?):", s)
        return f"{m.group(1)}: sanitized headline" if m else "sanitized headline"

    def prose(self, key: str, s: str) -> str:
        if not s:
            return s
        keep = [HEX.sub(lambda m: h(m.group(0), len(m.group(0))), B64.sub("sanitized", ln))
                for ln in s.split("\n") if "<!--" in ln and "-->" in ln]
        return "\n".join([f"sanitized {key}"] + [self.string(ln) for ln in keep])

    def ident(self, key: str, v):
        if isinstance(v, bool) or v is None:
            return v
        if isinstance(v, int):
            return int(h(str(v), 8), 16) % 10**9 + 10**9
        if isinstance(v, str):
            if not v:
                return v  # live gh sends "" (latestReviews[].id) — keep the empty, it IS the shape
            pre = re.match(r"^([A-Z]{1,4}_)", v)
            return (pre.group(1) if pre else "X_") + h(v, 16)
        return v

    def walk(self, v, key: str = "", parent: dict | None = None):
        if isinstance(v, dict):
            actorish = "login" in v
            out = {}
            for k, x in v.items():
                if k in ID_KEYS:
                    out[k] = self.ident(k, x)
                elif k == "login" and isinstance(x, str):
                    out[k] = self.logins.get(x, x)
                elif k == "name" and actorish and isinstance(x, str) and x and not KEEP_LOGIN.match(v.get("login") or ""):
                    out[k] = f"Human {h(x)}"
                elif k == "email" and isinstance(x, str):
                    out[k] = f"{self.logins.get(v.get('login') or '', v.get('login') or h(x))}@users.noreply.invalid" if x else x
                elif k in ("avatar_url", "avatarUrl") and isinstance(x, str):
                    out[k] = f"https://avatars.invalid/u/{self.ident('id', v.get('id', 0))}"
                elif k == "gravatar_id":
                    out[k] = ""
                elif k == "messageHeadline" and isinstance(x, str):
                    out[k] = self.headline(x)
                elif k in BRANCH_KEYS and isinstance(x, str):
                    out[k] = self.branch(x)
                elif k == "label" and isinstance(x, str) and ":" in x:  # REST head/base label "owner:branch"
                    o, _, b = x.partition(":")
                    out[k] = f"{o}:{self.branch(b)}"
                elif k == "name" and isinstance(x, str) and ("full_name" in v or x in self.repo_names):  # a repository object
                    out[k] = self.universe.split("/")[1]
                elif k in PROSE_KEYS and isinstance(x, str):
                    out[k] = self.prose(k, x)
                else:
                    out[k] = self.walk(x, k, v)
            return out
        if isinstance(v, list):
            return [self.walk(x, key, parent) for x in v]
        if isinstance(v, str):
            return self.string(v)
        return v

    def argv(self, argv: list[str]) -> list[str]:
        return [self.string(a) for a in argv]


# ── record ───────────────────────────────────────────────────────────────────────────────────────


def strip_jq(argv: list[str]) -> list[str]:
    out, skip = [], False
    for a in argv:
        if skip:
            skip = False
            continue
        if a in ("--jq", "-q"):
            skip = True
            continue
        if a.startswith("--jq="):
            continue
        out.append(a)
    return out


def stamp(world: Path, entries: list[dict], keys: dict[str, str]) -> None:
    """(Re)write the world's provenance.yaml from the raw cache — one `recorded:` entry per file, in
    run.sh's `--rerecord`-readable shape (`  - path:` / `    cmd:`) plus `at`, `source`, `via`.
    Regenerated, never appended: a re-sanitise after a rewrite-list change keeps it exact."""
    lines = ["# provenance — GENERATED by agents/islands/scan/pilot/recorder/recorder.py from its raw cache",
             f"world: {world.name}", "class: recorded",
             "sanitised: true   # recorder.py SANITISE_DOC — `cmd` is the LIVE argv; the stored file is the",
             "                  # sanitised answer, so run.sh --rerecord's byte diff always reads DRIFTED here",
             "recorded:"]
    for e in sorted(entries, key=lambda e: e["at"]):
        lines += [f"  - path: gh/{keys[cache_name(e['live'])]}.json", f"    cmd: {shlex.join(['gh', *e['argv']])}",
                  f"    at: {e['at']}", f"    source: {e['source']} (live, read-only)"]
        if e.get("via"):
            lines.append(f"    via: {e['via']}")
    (world / "provenance.yaml").write_text("\n".join(lines) + "\n", encoding="utf-8")


def cache_name(argv: list[str]) -> str:
    return h(" ".join(argv), 12) + ".json"


def write_world_file(world: Path, key: str, payload) -> str:
    rel = f"gh/{key}.json"
    (world / "gh").mkdir(parents=True, exist_ok=True)
    (world / rel).write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return rel


def cmd_record(a) -> int:
    argv = a.argv[1:] if a.argv and a.argv[0] == "gh" else a.argv
    live = strip_jq(argv)
    cache = Path(a.raw_cache)
    cache.mkdir(parents=True, exist_ok=True)
    if a.raw_file:  # an answer fetched by hand with the SAME argv (counted in the call budget)
        raw = json.loads(Path(a.raw_file).read_text(encoding="utf-8"))
    else:
        p = subprocess.run(["gh", *live], capture_output=True, text=True)
        if p.returncode != 0:
            sys.stderr.write(f"record: gh failed rc={p.returncode}: {p.stderr}")
            return 1
        raw = json.loads(p.stdout)
    full = stub_key(Sanitiser([a.source], a.universe).argv(argv))
    key = a.key or full
    if not (full == key or full.startswith(key + "-")):
        sys.stderr.write(f"record: --key {key} is not a prefix the stub would fall back to from {full}\n")
        return 2
    entry = {"argv": argv, "live": live, "source": a.source, "key": key, "via": a.via or "",
             "at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "raw": raw}
    (cache / cache_name(live)).write_text(json.dumps(entry, indent=1), encoding="utf-8")
    return sanitize_into(Path(a.world), cache, a.universe, only=[cache_name(live)])


def sanitize_into(world: Path, cache: Path, universe: str, only=None) -> int:
    every = [json.loads(f.read_text()) for f in sorted(cache.glob("*.json"))]
    entries = [json.loads((cache / n).read_text()) for n in only] if only else every
    # ONE sanitiser over every cached answer: a login seen in one file is rewritten in all of them
    s = Sanitiser(sorted({e["source"] for e in every}), universe)
    for e in every:
        s.collect(e["raw"])
    keys = {}
    for e in every:
        keys[cache_name(e["live"])] = e.get("key") or stub_key(s.argv(e["argv"]))
    for e in entries:
        # the key was computed over the SANITISED argv at record time: a SHA in a path is the same
        # stateless fake SHA the payload carries (fake_sha), so no second pass is needed
        key = e.get("key") or stub_key(s.argv(e["argv"]))
        rel = write_world_file(world, key, s.walk(e["raw"]))
        print(f"→ {world.name}/{rel}")
    stamp(world, every, keys)
    return 0



def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("record", "sanitize"):
        sp = sub.add_parser(name)
        sp.add_argument("--world", required=True)
        sp.add_argument("--source", default=SOURCE)
        sp.add_argument("--universe", default=UNIVERSE)
        sp.add_argument("--raw-cache", default=os.environ.get("RECORDER_TMP", ""))
        if name == "record":
            sp.add_argument("--raw-file", help="a hand-fetched answer to the same argv (no network call)")
            sp.add_argument("--via", help="how a --raw-file answer was fetched (stamped into provenance)")
            sp.add_argument("--key", help="a SHORTER stub key the stub falls back to (e.g. pr-list for pr-list-open)")
            sp.add_argument("argv", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    if not a.raw_cache:
        ap.error("--raw-cache (or $RECORDER_TMP) is required: the raw answer never lands in the tree")
    if a.cmd == "record":
        if a.argv and a.argv[0] == "--":
            a.argv = a.argv[1:]
        return cmd_record(a)
    return sanitize_into(Path(a.world), Path(a.raw_cache), a.universe)


if __name__ == "__main__":
    sys.exit(main())
