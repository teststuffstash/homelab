#!/usr/bin/env python3
"""island_rules — the island rules digest's deterministic half (FU-320; docs/glossary.md "island
rules digest"). Two verbs, both read-only:

  python3 agents/island_rules.py set [--json]
      The "island rules" set: every repo .md file a launcher hands a session as its brief or rules,
      attributed to an island. DERIVED, never enumerated (the four rules below); an island is the
      one gateway/scripts/intake-select.sh's own island table names (that table is called, never
      copied: its function block is evaluated from the selector file itself).

  python3 agents/island_rules.py changes --since YYYY-MM-DD --until YYYY-MM-DD [--ref master]
      The week's change record (`island-rules-changes/v1`, JSON on stdout): per file of the set (as
      the set stands at the window's END), every first-parent commit on <ref> inside the half-open
      window [since 00:00Z, until 00:00Z) — sha, committer date, author identity class, subject, PR
      number when the subject carries one, numstat lines added/removed — and the file's size at the
      window's start and end.

  python3 agents/island_rules.py self-test
      A fixture git repo built in a temp dir; asserts the derivation and the change record.

THE DERIVATION — a file is in the set when one of these holds (each is mechanical; none is a list):
  R1 launcher feed. A repo .md path on a NON-comment line of agents/coordinator/*-argo.yaml or
     agents/*-session.sh, in one of three FEED shapes:
       assign  — a shell assignment whose value starts with the path (BRIEF=…, RUBRIC=…, a
                 ${VAR:-default} default): the launcher holds the file as the session's brief/rules;
       read    — the path is the operand of a verb that hands file content over (it stands AFTER the
                 verb on the line): cat, curl, _lens_run, --append-system-prompt-file,
                 `python3 -` (a brief renderer), a `for f in` read loop;
       direct  — brief text tells the session to take the file as its rules: "Read <path>",
                 "Follow <path>", or "<path>, your system prompt".
     A path that is merely CITED (a parenthetical "(docs/agents/roles.md §deep dig)", a read-set list
     of data files, a log line) matches no shape — that is what keeps design docs, the tracker and
     report paths out without an exclude list. `$HERE/` resolves to agents/, a same-file `NAME=`
     directory assignment resolves one level (the retro's $RETROS, the reviewer's $LENS_BASE raw URL),
     and any remaining `$var` in the file name is a glob over files that exist (docs/intake/$ISLAND.md).
  R2 rules closure. A rules file's own "Read/Follow [x](x)" directive pulls x in (gateway/intake.md
     → intake-escape.md), transitively, with the same direct shape as R1.
  R3 facts. docs/intake/*.md — the per-island facts files intake-select.sh names.
  R4 README declaration. A `Rules files:` line in islands/*/README.md or gateway/README.md listing
     links (no README declares one today — the leg is wired so a declaration needs no code change).

ATTRIBUTION: docs/intake/<island>.md → <island>; every other path → island_of_path (the selector's
longest-prefix rule); nothing → "commons".
"""
from __future__ import annotations

import glob
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.dirname(HERE)
SELECTOR = "gateway/scripts/intake-select.sh"
TABLE_BEGIN = "# ── the island table"
TABLE_END = "# ── --source dig"
RAW_PREFIX = "https://raw.githubusercontent.com/teststuffstash/homelab/master/"
PR_RE = re.compile(r"\(#(\d+)\)\s*$")

TOKEN = r"(?P<tok>(?:\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/|[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.${}-]*[A-Za-z0-9_}]\.md)\b"
ASSIGN_RE = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*=[\"']?(?:\$\{[A-Za-z_][A-Za-z0-9_]*:-)?" + TOKEN)
READ_VERB_RE = re.compile(r"(^|[\s;(|&{])(cat|curl|_lens_run)\s|--append-system-prompt-file|--system-prompt-file|python3 - |\bfor [A-Za-z_]+ in ")
DIRECT_RE = re.compile(r"(?i)\b(?:read|follow)\s+(?:the\s+)?[`\[]*" + TOKEN)
SYSPROMPT_RE = re.compile(TOKEN + r"[`\]]*,\s*your system prompt")
ANY_TOKEN_RE = re.compile(TOKEN)
DIR_ASSIGN_RE = re.compile(r"\b(?:local\s+)?([A-Za-z_][A-Za-z0-9_]*)=[\"']?(?:\$\{[A-Za-z_][A-Za-z0-9_]*:-)?([^\"'\s}]+)")
MD_DIRECT_RE = re.compile(r"(?i)\b(?:read|follow)\s+(?:the\s+)?(?:\[[^\]]*\]\((?P<link>[^)#\s]+\.md)[^)]*\)|`(?P<bare>[^`\s]+\.md)`)")
README_RULES_RE = re.compile(r"^Rules files?:(.*)$", re.M)
LINK_RE = re.compile(r"\]\(([^)#\s]+\.md)")


class Fail(Exception):
    pass


def sh(args, cwd, check=True):
    p = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    if check and p.returncode != 0:
        raise Fail(f"{' '.join(args)}: rc {p.returncode}: {p.stderr.strip()}")
    return p.stdout


# ── the island table (the selector's, evaluated from its own file) ───────────────────────────────
def island_table(root, paths):
    """→ (islands list, {path: island or ''}) via intake-select.sh's own island_of_path."""
    sel = os.path.join(root, SELECTOR)
    with open(sel, encoding="utf-8") as fh:
        text = fh.read()
    if TABLE_BEGIN not in text or TABLE_END not in text:
        raise Fail(f"{SELECTOR}: the island-table markers moved ({TABLE_BEGIN!r} … {TABLE_END!r})")
    script = (
        'eval "$(sed -n "/^$1/,/^$2/p" "$3")" || exit 2\n'
        'shift 3; echo "$ISLANDS"\n'
        'for p in "$@"; do printf "%s\\t%s\\n" "$p" "$(island_of_path "$p")"; done\n'
    )
    out = sh(["bash", "-c", script, "table", TABLE_BEGIN, TABLE_END, sel, *paths], cwd=root)
    lines = out.split("\n")
    islands = lines[0].split()
    if not islands:
        raise Fail(f"{SELECTOR}: the island table evaluated to no islands")
    owner = {}
    for ln in lines[1:]:
        if "\t" in ln:
            p, isl = ln.split("\t", 1)
            owner[p] = isl
    return islands, owner


# ── R1: launcher feeds ───────────────────────────────────────────────────────────────────────────
def launchers(root):
    return sorted(glob.glob(os.path.join(root, "agents/coordinator/*-argo.yaml"))
                  + glob.glob(os.path.join(root, "agents/*-session.sh")))


def norm(path):
    p = os.path.normpath(path)
    return "" if p.startswith("..") or os.path.isabs(p) else p


def dir_vars(lines, here_rel):
    """NAME=<repo dir> assignments in one launcher (one level; $HERE pre-resolved)."""
    out = {}
    for ln in lines:
        for m in DIR_ASSIGN_RE.finditer(ln):
            name, val = m.group(1), m.group(2)
            val = val.replace("${HERE}", here_rel).replace("$HERE", here_rel)
            if val.startswith(RAW_PREFIX):
                val = val[len(RAW_PREFIX):]
            if "$" in val or val.endswith(".md"):
                continue
            out[name] = val
    return out


def resolve(root, tok, here_rel, dvars):
    """A token → the existing repo .md files it names (a list; empty = not a repo path)."""
    t = tok.replace("\\", "").replace("${HERE}", here_rel).replace("$HERE", here_rel)
    m = re.match(r"^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/(.*)$", t)
    if m:
        if m.group(1) not in dvars:
            return []
        t = dvars[m.group(1)].rstrip("/") + "/" + m.group(2)
    t = norm(t)
    if not t or t.startswith("/"):
        return []
    if "$" in t:
        d, base = os.path.split(t)
        if "$" in d:
            return []
        pat = re.sub(r"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?", "*", base)
        return sorted(os.path.relpath(p, root) for p in glob.glob(os.path.join(root, d, pat)) if os.path.isfile(p))
    return [t] if os.path.isfile(os.path.join(root, t)) else []


def feeds_of(root, rel):
    """R1 over one launcher → {path: [shape:launcher]}."""
    here_rel = os.path.dirname(rel) if rel.endswith(".sh") else ""
    with open(os.path.join(root, rel), encoding="utf-8") as fh:
        lines = [ln.replace("\\`", "`").replace("\\$", "$") for ln in fh.read().split("\n")
                 if not ln.lstrip().startswith("#")]
    dvars = dir_vars(lines, here_rel or ".")
    found = {}

    def add(tok, shape):
        for p in resolve(root, tok, here_rel or ".", dvars):
            found.setdefault(p, set()).add(f"{shape}:{rel}")

    for ln in lines:
        for m in ASSIGN_RE.finditer(ln):
            add(m.group("tok"), "assign")
        v = READ_VERB_RE.search(ln)
        if v:  # the path must be the verb's operand: AFTER it on the line, never a citation before it
            for m in ANY_TOKEN_RE.finditer(ln, v.end() - 1):
                add(m.group("tok"), "read")
        for m in DIRECT_RE.finditer(ln):
            add(m.group("tok"), "direct")
        for m in SYSPROMPT_RE.finditer(ln):
            add(m.group("tok"), "direct")
    return found


# ── R2: rules closure ────────────────────────────────────────────────────────────────────────────
def directives_of(root, rel):
    with open(os.path.join(root, rel), encoding="utf-8") as fh:
        text = fh.read()
    out = []
    for m in MD_DIRECT_RE.finditer(text):
        tgt = m.group("link") or m.group("bare")
        if tgt.startswith(("http://", "https://")):
            continue
        for cand in (os.path.join(os.path.dirname(rel), tgt), tgt):
            p = norm(cand)
            if p and os.path.isfile(os.path.join(root, p)):
                out.append(p)
                break
    return out


def derive(root):
    """→ {path: sorted list of 'rule:shape:source'} — the set before attribution."""
    found = {}

    def add(p, why):
        found.setdefault(p, set()).add(why)

    for lp in launchers(root):
        rel = os.path.relpath(lp, root)
        for p, whys in feeds_of(root, rel).items():
            for w in whys:
                add(p, "R1:" + w)
    queue = sorted(found)
    seen = set(queue)
    while queue:
        src = queue.pop(0)
        for p in directives_of(root, src):
            add(p, f"R2:direct:{src}")
            if p not in seen:
                seen.add(p)
                queue.append(p)
    for p in sorted(glob.glob(os.path.join(root, "docs/intake/*.md"))):
        add(os.path.relpath(p, root), "R3:facts")
    for readme in sorted(glob.glob(os.path.join(root, "islands/*/README.md")) + [os.path.join(root, "gateway/README.md")]):
        if not os.path.isfile(readme):
            continue
        rel = os.path.relpath(readme, root)
        with open(readme, encoding="utf-8") as fh:
            text = fh.read()
        for m in README_RULES_RE.finditer(text):
            for tgt in LINK_RE.findall(m.group(1)):
                p = norm(os.path.join(os.path.dirname(rel), tgt))
                if p and os.path.isfile(os.path.join(root, p)):
                    add(p, f"R4:readme:{rel}")
    return {p: sorted(w) for p, w in found.items()}


def rules_set(root):
    raw = derive(root)
    islands, owner = island_table(root, sorted(raw))
    files = []
    for p in sorted(raw):
        isl = ""
        m = re.match(r"^docs/intake/([^/]+)\.md$", p)
        if m and m.group(1) in islands:
            isl = m.group(1)
        else:
            isl = owner.get(p, "")
        files.append({"path": p, "island": isl or "commons", "via": raw[p]})
    return {"schema": "island-rules-set/v1", "islands": islands, "files": files}


# ── the change record ────────────────────────────────────────────────────────────────────────────
def identity_class(name, email):
    """operator | bot:<name>. A `[bot]` App identity or a launcher's own noreply@ identity is a named
    machine identity; everything else is the operator's account (the seat's sessions commit and open
    PRs as the operator, so git cannot tell a seat-authored change from a hand-typed one)."""
    if name.endswith("[bot]") or email == "noreply@teststuff.net":
        return f"bot:{name}"
    return "operator"


def blob_size(root, rev, path):
    if not rev:
        return None
    p = subprocess.run(["git", "cat-file", "-s", f"{rev}:{path}"], cwd=root, capture_output=True, text=True)
    return int(p.stdout.strip()) if p.returncode == 0 else None


def changes(root, since, until, ref):
    t0, t1 = f"{since}T00:00:00Z", f"{until}T00:00:00Z"
    rev0 = sh(["git", "rev-list", "-1", "--first-parent", f"--before={t0}", ref], root).strip() or None
    rev1 = sh(["git", "rev-list", "-1", "--first-parent", f"--before={t1}", ref], root).strip() or None
    # The set as it stands at the window's END: derived from a checkout of rev1 when it is not HEAD.
    head = sh(["git", "rev-parse", "HEAD"], root).strip()
    if rev1 and rev1 != head:
        # an exported tree, not a worktree: the derivation reads files only, and the repo's own
        # worktree registry is left alone
        tmp = tempfile.mkdtemp(prefix="island-rules-")
        try:
            arch = subprocess.run(["git", "archive", rev1], cwd=root, capture_output=True, check=False)
            if arch.returncode != 0:
                raise Fail(f"git archive {rev1}: {arch.stderr.decode(errors='replace').strip()}")
            subprocess.run(["tar", "-x", "-C", tmp], input=arch.stdout, check=True)
            rset = rules_set(tmp)
        finally:
            subprocess.run(["rm", "-rf", tmp])
    else:
        rset = rules_set(root)
    sep = "\x1f"
    out_files = []
    for f in rset["files"]:
        log = sh(["git", "log", "--first-parent", f"--since={t0}", f"--until={t1}", "--numstat",
                  f"--format=@@{sep}%H{sep}%cI{sep}%an{sep}%ae{sep}%s", ref, "--", f["path"]], root)
        commits = []
        for block in log.split("@@" + sep)[1:]:
            head_line, _, rest = block.partition("\n")
            sha, date, an, ae, subj = head_line.split(sep, 4)
            added = removed = 0
            for ln in rest.strip().split("\n"):
                parts = ln.split("\t")
                if len(parts) == 3 and parts[0].isdigit():
                    added += int(parts[0]); removed += int(parts[1])
            # a commit inside the window can still be dated before it on a first-parent walk (an old
            # author date merged late is fine: %cI is the committer date git log filters on).
            pr = PR_RE.search(subj)
            commits.append({"sha": sha, "date": date, "identity": identity_class(an, ae), "subject": subj,
                            "pr": int(pr.group(1)) if pr else None, "added": added, "removed": removed})
        commits.reverse()  # oldest first
        out_files.append({"path": f["path"], "island": f["island"],
                          "size_start": blob_size(root, rev0, f["path"]), "size_end": blob_size(root, rev1, f["path"]),
                          "commits": commits})
    changed = [f for f in out_files if f["commits"]]
    return {
        "schema": "island-rules-changes/v1",
        "window": {"since": t0, "until": t1, "ref": ref, "rev_start": rev0, "rev_end": rev1},
        "counts": {
            "files_in_set": len(out_files),
            "files_changed": len(changed),
            "islands_changed": len({f["island"] for f in changed}),
            "commits": len({c["sha"] for f in changed for c in f["commits"]}),
            "net_bytes": sum((f["size_end"] or 0) - (f["size_start"] or 0) for f in changed),
        },
        "files": out_files,
    }


# ── self-test ────────────────────────────────────────────────────────────────────────────────────
def self_test():
    real = DEFAULT_ROOT
    fails = []

    def check(name, cond, detail=""):
        print(("  ok  " if cond else "  FAIL ") + name + ("" if cond else f" — {detail}"))
        if not cond:
            fails.append(name)

    # 1. the LIVE derivation pins what the operator named: the four gateway intake files + the facts.
    live = {f["path"]: f for f in rules_set(real)["files"]}
    for p in ("gateway/intake.md", "gateway/intake-escape.md", "gateway/intake-review-rows.md",
              "gateway/intake-review-unit.md"):
        check(f"live set holds {p} (island gateway)", live.get(p, {}).get("island") == "gateway", live.get(p))
    for p in sorted(glob.glob(os.path.join(real, "docs/intake/*.md"))):
        rel = os.path.relpath(p, real)
        stem = os.path.basename(rel)[:-3]
        check(f"live set holds {rel} (island {stem})", live.get(rel, {}).get("island") == stem, live.get(rel))
    # tightness: no design doc, tracker, meta-state or retro REPORT rides in (the rule, not a list:
    # these paths appear in launchers only as citations / data reads / write targets).
    for p in ("docs/agents/roles.md", "docs/follow-ups.md", "docs/agents/meta-state.md", "docs/runbook.md",
              "docs/agents/iac-lane.md"):
        check(f"live set leaves out the cited {p}", p not in live, live.get(p))
    check("live set holds no dated retro report", not any(re.match(r"docs/agents/retros/\d{4}-", p) for p in live))

    # 2. a fixture repo: the shapes, the closure, attribution, and the change record.
    tmp = tempfile.mkdtemp(prefix="island-rules-test-")
    try:
        def w(rel, text):
            os.makedirs(os.path.join(tmp, os.path.dirname(rel)), exist_ok=True)
            with open(os.path.join(tmp, rel), "w", encoding="utf-8") as fh:
                fh.write(text)

        def git(*a, date=None, author=("Op Erator", "op@example.org")):
            env = dict(os.environ, GIT_AUTHOR_NAME=author[0], GIT_AUTHOR_EMAIL=author[1],
                       GIT_COMMITTER_NAME=author[0], GIT_COMMITTER_EMAIL=author[1])
            if date:
                env.update(GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date)
            subprocess.run(["git", *a], cwd=tmp, env=env, check=True, capture_output=True)

        # the selector's table section, copied from the REAL file (the code under test reads it there)
        with open(os.path.join(real, SELECTOR), encoding="utf-8") as fh:
            w(SELECTOR, fh.read())
        w("gateway/intake.md", "# brief\nStep E: Follow [`intake-escape.md`](intake-escape.md).\nSee [roles](../docs/agents/roles.md).\n")
        w("gateway/intake-escape.md", "# escape\n")
        w("gateway/intake-review-unit.md", "# unit\n")
        w("docs/agents/roles.md", "# design doc\n")
        w("docs/intake/scan.md", "# scan facts\n")
        w("docs/intake/notanisland.md", "# orphan facts\n")
        w("agents/ground-rules.md", "# ground rules\n")
        w("agents/lenses/a.md", "# lens a\n")
        w("misc/rules.md", "# commons rules\n")
        w("docs/agents/retros/2026-01-01-platform-r1-x.md", "# a report\n")
        w("agents/coordinator/x-argo.yaml",
          "# comment: Read docs/agents/roles.md\n"
          "args:\n  - |\n"
          "    cat <<BRIEF\n    Read gateway/intake.md IN FULL. Context (docs/agents/roles.md §x).\n"
          "    Follow misc/rules.md.\n    (3) Loki (docs/agents/roles.md): curl -sG http://loki\n    BRIEF\n"
          "    _lens_run \"$case\" gateway/intake-review-unit.md \"Unit review\"\n"
          "    FACTS=\"docs/intake/$ISLAND.md (in place)\"\n"
          "    cp /tmp/r.md \"docs/agents/retros/${DATE}-x.md\"\n")
        w("agents/x-session.sh",
          "#!/bin/bash\nHERE=x\nLENS_BASE=\"${LENS_BASE:-https://raw.githubusercontent.com/teststuffstash/homelab/master/agents/lenses}\"\n"
          "local grf=\"${GROUND_RULES_FILE:-$HERE/ground-rules.md}\"\n"
          "curl -fsS \"\\$LENS_BASE/\\$l.md\"\n")
        git("init", "-q", "-b", "master")
        git("add", "-A")
        git("commit", "-q", "-m", "base", date="2026-01-01T12:00:00Z")
        fset = {f["path"]: f for f in rules_set(tmp)["files"]}
        expect = {
            "gateway/intake.md": "gateway",          # R1 direct
            "gateway/intake-escape.md": "gateway",   # R2 closure
            "gateway/intake-review-unit.md": "gateway",  # R1 read (_lens_run)
            "docs/intake/scan.md": "scan",           # R1 assign glob + R3, attributed by stem
            "docs/intake/notanisland.md": "commons",  # R3, stem is no island, no prefix owns it
            "agents/ground-rules.md": "agent-loop",  # R1 assign via $HERE default
            "agents/lenses/a.md": "agent-loop",      # R1 read via the raw-URL dir var + $l glob
            "misc/rules.md": "commons",              # R1 direct, no island prefix
        }
        for p, isl in expect.items():
            check(f"fixture: {p} → {isl}", fset.get(p, {}).get("island") == isl, fset.get(p))
        check("fixture: cited design doc stays out", "docs/agents/roles.md" not in fset, fset.get("docs/agents/roles.md"))
        check("fixture: a cp-target report stays out", not any("retros" in p for p in fset))

        # the change record: two commits in the window on intake.md (one operator, one bot, the bot's
        # carrying a PR number), one before it (excluded), one on a non-set file (excluded).
        w("gateway/intake.md", open(os.path.join(tmp, "gateway/intake.md")).read() + "line a\n")
        git("commit", "-qam", "before the window", date="2026-01-04T23:59:00Z")
        w("gateway/intake.md", open(os.path.join(tmp, "gateway/intake.md")).read() + "line b\nline c\n")
        git("commit", "-qam", "intake: add two lines", date="2026-01-06T10:00:00Z")
        w("README.md", "not in the set\n")
        git("add", "-A")
        git("commit", "-qm", "unrelated", date="2026-01-07T10:00:00Z")
        w("gateway/intake.md", open(os.path.join(tmp, "gateway/intake.md")).read().replace("line b\n", ""))
        git("commit", "-qam", "intake: drop a line (#42)", date="2026-01-08T10:00:00Z",
            author=("homelab-agents-1234[bot]", "1+homelab-agents-1234[bot]@users.noreply.github.com"))
        # a commit AFTER the window: the window's end is then not HEAD, so the set is derived from an
        # exported tree of the end revision (the cron's normal case)
        w("README.md", "after the window\n")
        git("commit", "-qam", "after the window", date="2026-01-20T10:00:00Z")
        rec = changes(tmp, "2026-01-05", "2026-01-12", "master")
        check("changes: the window's end revision is not HEAD",
              rec["window"]["rev_end"] != sh(["git", "rev-parse", "HEAD"], tmp).strip(), rec["window"])
        byp = {f["path"]: f for f in rec["files"]}
        ci = byp["gateway/intake.md"]["commits"]
        check("changes: schema", rec["schema"] == "island-rules-changes/v1")
        check("changes: two window commits on intake.md, oldest first",
              [c["subject"] for c in ci] == ["intake: add two lines", "intake: drop a line (#42)"], ci)
        # numstat derived from the edits above: +2/-0, then +0/-1
        check("changes: numstat", [(c["added"], c["removed"]) for c in ci] == [(2, 0), (0, 1)], ci)
        check("changes: identity classes", [c["identity"] for c in ci] == ["operator", "bot:homelab-agents-1234[bot]"], ci)
        check("changes: PR number from the subject", [c["pr"] for c in ci] == [None, 42], ci)
        # sizes: start = after "line a" was added; end = start + "line c\n" (7 bytes)
        s0, s1 = byp["gateway/intake.md"]["size_start"], byp["gateway/intake.md"]["size_end"]
        check("changes: size end - start = +7 bytes", s0 is not None and s1 - s0 == 7, (s0, s1))
        check("changes: counts", rec["counts"]["files_changed"] == 1 and rec["counts"]["commits"] == 2
              and rec["counts"]["net_bytes"] == 7, rec["counts"])
        empty = changes(tmp, "2026-02-01", "2026-02-08", "master")
        check("changes: an empty window has no commits", empty["counts"]["commits"] == 0, empty["counts"])
    finally:
        subprocess.run(["rm", "-rf", tmp])
    print(f"island_rules self-test: {'FAIL' if fails else 'ok'} ({len(fails)} failed)")
    return 1 if fails else 0


def main(argv):
    root = os.environ.get("ISLAND_RULES_ROOT", DEFAULT_ROOT)
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    verb, rest = argv[0], argv[1:]
    try:
        if verb == "set":
            rs = rules_set(root)
            if "--json" in rest:
                print(json.dumps(rs, indent=2))
            else:
                by = {}
                for f in rs["files"]:
                    by.setdefault(f["island"], []).append(f["path"])
                for isl in [*rs["islands"], "commons"]:
                    for p in by.get(isl, []):
                        print(f"{isl}\t{p}")
            return 0
        if verb == "changes":
            args = dict(zip(rest[::2], rest[1::2]))
            if "--since" not in args or "--until" not in args:
                raise Fail("changes needs --since YYYY-MM-DD --until YYYY-MM-DD")
            for k in ("--since", "--until"):
                if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", args[k]):
                    raise Fail(f"{k} {args[k]!r} is not YYYY-MM-DD")
            print(json.dumps(changes(root, args["--since"], args["--until"], args.get("--ref", "HEAD")), indent=2))
            return 0
        if verb == "self-test":
            return self_test()
        raise Fail(f"unknown verb {verb!r} (set | changes | self-test)")
    except Fail as e:
        print(f"island_rules: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
