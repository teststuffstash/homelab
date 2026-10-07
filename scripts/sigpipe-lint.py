#!/usr/bin/env python3
"""sigpipe-lint — no `printf|echo … | grep -q` / `| grep -m1` / `| head` in tracked shell.

    devbox run sigpipe-lint                  (scan every tracked shell script; exit 1 + file:line on a hit)
    devbox run sigpipe-lint -- --self-test   (the detector against its own fixture table)
    devbox run sigpipe-lint -- FILE…         (scan just these files)

THE CLASS. An early-exit reader — `grep -q`/`-qx`/`-qF`/`-qE`/`-vq`, `grep -m1`/`--max-count`,
`head` (any form) — stops reading at its first match/line and exits while the writer may still be
writing. The writer then takes EPIPE. With SIGPIPE at its default the writer dies 141, and under
`set -o pipefail` the WHOLE pipeline reads as failed — `if printf … | grep -q needle` goes false
with the needle present (FU-219, exit 141 in coordinator-scan). With SIGPIPE ignored (the GitHub
runner does this; so does agents/replay/run.sh since PR #2367) the builtin prints
"printf: Broken pipe" and returns non-zero — same pipefail verdict, plus stderr noise. Whether it
fires is a race on pipe-buffer timing, so it surfaces as CI FLAKES (agents/board-test.sh's
2026-09-05 PR#1436 flake; master run 37668796169, 2026-10-07).

THE RULE (agents/board-test.sh documented it once; this makes it mechanical): read the haystack
from a HERE-STRING — `grep -q -- "$needle" <<< "$hay"` — or, for the first line, a parameter
expansion (`${x%%$'\\n'*}`, `${x:0:N}`). Bash writes a here-string in full before the reader
starts, so no writer can be left holding a closed pipe. POSIX sh has no `<<<`: use `case` or a
heredoc redirect (`grep -q x <<EOF` / `$hay` / `EOF`).

SCOPE: every tracked file ending .sh/.bash or whose shebang names sh/bash/dash. The writer is the
pipeline stage directly before the `|` and must START with printf/echo (after `!`, `if`, `then`,
…); a stage like `grep -o … | head -1` is a different writer and out of scope. Shell embedded in
YAML (Argo workflows, .github/workflows) is not scanned — it has no file boundary to lint by.
"""
import os
import re
import subprocess
import sys

# Files whose sites convert in their own PR, with the reason. Hits there are listed, never fatal;
# an entry whose file is clean prints a STALE notice — delete it then. Shrink-only: a NEW file
# never goes here (convert it instead).
PENDING = {
    "agents/agent-session.sh": "ADR-103 ratchet clause file — converts in its own PR (behaviour-neutral, README-recorded)",
    "agents/reviewer-session.sh": "ADR-103 ratchet clause file — converts in its own PR (behaviour-neutral, README-recorded)",
    "agents/machine-comment.sh": "ADR-103 ratchet clause file — converts in its own PR (behaviour-neutral, README-recorded)",
}

WRITER_RE = re.compile(r"^(printf|echo)(\s|$)")
LEAD_WORDS = ("!", "if", "then", "elif", "else", "while", "until", "do", "{", "time")


def logical_lines(text):
    """[(first_lineno, joined_text)]: backslash continuations, trailing-`|` and leading-`|` lines joined."""
    out, buf, start, cont = [], "", None, False
    for n, raw in enumerate(text.split("\n"), 1):
        line = raw.rstrip("\r")
        stripped = line.rstrip()
        lead = line.lstrip()
        if not cont and out and buf == "" and lead.startswith("|") and not lead.startswith("||"):
            ln, prev = out.pop()          # a leading-pipe line continues the previous one
            buf, start = prev + " ", ln
        if start is None:
            start = n
        if stripped.endswith("\\") and not stripped.endswith("\\\\"):
            buf += stripped[:-1] + " "
            cont = True
            continue
        if stripped.endswith("|") and not stripped.endswith("||"):
            buf += stripped + " "
            cont = True
            continue
        buf += line
        out.append((start, buf))
        buf, start, cont = "", None, False
    if buf:
        out.append((start, buf))
    return out


def early_exit_reader(rest):
    """True when the pipeline stage `rest` (text after the `|`) is an early-exit reader."""
    toks = rest.split()
    if toks and toks[0] == "command":
        toks = toks[1:]
    if not toks:
        return False
    if toks[0] == "head":
        return True
    if toks[0] not in ("grep", "egrep", "fgrep"):
        return False
    skip = False
    for t in toks[1:]:
        if skip:
            skip = False
            continue
        if t == "--":
            break
        if t in ("--quiet", "--silent") or t.startswith("--max-count"):
            return True
        if t.startswith("--"):
            continue
        if re.match(r"^-[A-Za-z]", t):
            # a short-option cluster: q anywhere, or m (with or without its count) in it
            letters = re.match(r"^-([A-Za-z]*)", t).group(1)
            if "q" in letters or "m" in letters:
                return True
            skip = t == "-" + letters and letters[-1:] in tuple("efABCdD")  # option takes the next word
            continue
        break   # first non-option word: the pattern
    return False


def writer_stage(stage):
    s = stage.strip()
    changed = True
    while changed:
        changed = False
        for w in LEAD_WORDS:
            if s == w or s.startswith(w + " ") or s.startswith(w + "\t"):
                s = s[len(w):].lstrip()
                changed = True
    return WRITER_RE.match(s) is not None


def scan_line(line):
    """Return the list of offending pipe offsets in one logical line."""
    hits = []
    frames = [{"dq": False, "start": 0}]
    i, n = 0, len(line)
    sq = False
    while i < n:
        c = line[i]
        f = frames[-1]
        if sq:
            if c == "'":
                sq = False
            i += 1
            continue
        if c == "\\":
            i += 2
            continue
        if f["dq"]:
            if c == '"':
                f["dq"] = False
            elif line.startswith("$(", i):
                frames.append({"dq": False, "start": i + 2, "in_dq": True})
                i += 2
                continue
            i += 1
            continue
        # unquoted
        if c == "#" and (i == 0 or line[i - 1] in " \t;"):
            break   # comment
        if c == "'":
            sq = True
        elif c == '"':
            f["dq"] = True
        elif line.startswith("$(", i):
            frames.append({"dq": False, "start": i + 2})
            i += 2
            continue
        elif c == "(":
            frames.append({"dq": False, "start": i + 1})
        elif c == ")":
            if len(frames) > 1:
                frames.pop()
            frames[-1]["start"] = i + 1 if not frames[-1].get("dq") else frames[-1]["start"]
        elif c == "`":
            f["start"] = i + 1
        elif line.startswith("||", i) or line.startswith("&&", i):
            f["start"] = i + 2
            i += 2
            continue
        elif c == ";" or c == "&":
            f["start"] = i + 1
        elif c == "|":
            if line.startswith("|&", i):
                i += 2
                f["start"] = i
                continue
            if writer_stage(line[f["start"]:i]) and early_exit_reader(line[i + 1:]):
                hits.append(i)
            f["start"] = i + 1
        i += 1
    return hits


def scan_text(text):
    out = []
    for lineno, line in logical_lines(text):
        if line.lstrip().startswith("#"):
            continue
        hits = scan_line(line)
        if hits:
            out.append((lineno, len(hits), line.strip()))
    return out


def shell_files(root):
    files = subprocess.check_output(["git", "-C", root, "ls-files", "-z"]).decode().split("\0")
    out = []
    for f in files:
        p = os.path.join(root, f)
        if not f or not os.path.isfile(p) or os.path.islink(p):
            continue
        if re.search(r"\.(sh|bash)$", f):
            out.append(f)
            continue
        try:
            with open(p, "rb") as h:
                first = h.readline(200)
        except OSError:
            continue
        if re.match(rb"#!\S*(/env\s+)?\S*\b(ba|da)?sh\b", first):
            out.append(f)
    return sorted(out)


# (snippet, flagged?) — the detector's contract. Positives are the shapes found in-tree on
# 2026-10-07; negatives are the conversions and the near-misses the detector must not flag.
FIXTURES = [
    ("printf '%s' \"$OUT\" | grep -qF -- \"$2\" && ok", True),
    ("if ! printf '%s\\n' \"$x\" | grep -qx \"$y\"; then", True),
    ("line=\"$(printf '%s\\n' \"$1\" | grep -m1 '^G=' || true)\"", True),
    ("printf '%s' \"$a\" | grep -Em1 x", True),
    ("printf '%s' \"$a\" | grep --max-count=1 x", True),
    ("printf '%s\\n' \"$mine\" | grep -vqE \"$RE\"", True),
    ("echo \"$x\" | grep -Eq '^[0-9]+$' || die", True),
    ("id=\"$(printf '%s' \"$ids\" | head -1)\"", True),
    ("printf '%s' \"$r\" | head -c 600 | sed 's/^/ /'", True),
    ("x=$(foo) && printf '%s' \"$x\" | grep -q y", True),
    ("printf 'LOG %s\\n' \"$(printf '%s' \"$T\" | head -1)\"", True),
    ("if printf '%s\\n' \"$c\" \\\n   | grep -qE '^a'; then", True),
    ("x=1\nprintf '%s\\n' \"$c\"\n  | head -2", True),
    ("grep -qF -- \"$2\" <<< \"$OUT\" && ok", False),
    ("printf '%s\\n' \"$x\" | grep -c .", False),
    ("printf '%s\\n' \"$x\" | grep -E '^a' | sort", False),
    ("echo \"ok $(grep -o 'P [^\"]*' f | head -1)\"", False),
    ("kubectl get po | head -1", False),
    ("# printf '%s' \"$x\" | grep -q y", False),
    ("echo 'printf x | grep -q y'", False),
    ("printf '%s' \"$x\" || grep -q y f", False),
    ("printf '%s\\n' \"$x\" | grep -e -q", False),
]


def self_test():
    bad = 0
    for snippet, want in FIXTURES:
        got = bool(scan_text(snippet))
        if got != want:
            bad += 1
            print(f"FAIL want={want} got={got}: {snippet}")
    print(f"sigpipe-lint self-test: {len(FIXTURES) - bad}/{len(FIXTURES)} pass")
    return 1 if bad else 0


def main(argv):
    if argv[:1] == ["--self-test"]:
        return self_test()
    root = subprocess.check_output(["git", "rev-parse", "--show-toplevel"]).decode().strip()
    files = argv or shell_files(root)
    if not files:
        print("sigpipe-lint: PROBE-FAIL — zero shell files found (git ls-files broken?)", file=sys.stderr)
        return 2
    total = pending = 0
    for f in files:
        with open(os.path.join(root, f) if not os.path.isabs(f) else f, errors="replace") as h:
            found = scan_text(h.read())
        for lineno, nsites, line in found:
            if f in PENDING:
                pending += nsites
                print(f"{f}:{lineno}: [{nsites}] PENDING ({PENDING[f]}): {line[:160]}")
            else:
                total += nsites
                print(f"{f}:{lineno}: [{nsites}] {line[:200]}")
        if f in PENDING and not found and not argv:
            print(f"sigpipe-lint: STALE exemption — {f} is clean now; delete its PENDING entry")
    if total:
        print(f"sigpipe-lint: FAIL — {total} printf/echo pipe(s) into an early-exit reader "
              "(grep -q/-m, head). Read the haystack from a here-string: "
              "`grep -q -- \"$needle\" <<< \"$hay\"` (POSIX sh: case / heredoc). Why: scripts/sigpipe-lint.py docstring.",
              file=sys.stderr)
        return 1
    print(f"sigpipe-lint: ok ({len(files)} shell files, 0 early-exit pipes"
          + (f"; {pending} pending in {len(PENDING)} exempted file(s)" if pending else "") + ")")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
