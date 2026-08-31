#!/usr/bin/env python3
"""prompt-transport-lint — the mechanical guard for the prose-inside-executing-code class (#197).

WHY THIS EXISTS. Four times now, prose (a prompt, a comment, a dollar amount) has been embedded in
a context that a shell later EXPANDS, and each time the fix was local while the class stayed live:

  1. 2026-08-05 — an apostrophe inside a jq program inside `$( )` killed the review reflex fleetwide.
  2. 2026-08-08 — `$103.74` in a comment inside reviewer-session.sh's EXPANDING pod-manifest heredoc
     parsed as positional `${1}03.74`; under `set -u` it killed every reviewer dispatch for ~5.5h.
  3. the responder's `gh issue create --body-file` lesson (never an interpolated body argument).
  4. 2026-08-09 — `jq -Rs` used as SHELL quoting in coordinator-session.sh's headless path: JSON
     escaping leaves backticks and `$` live, so the pod's `bash -lc` re-expanded the #162 RAIL RULE
     and its backticked fragments EXECUTED and were stripped from every delivered prompt for ~6h.

The durable warnings for #1 and #3 were written down and did not prevent #2 or #4. Compliance is
the gap, so the class needs a GUARD, not another warning. Two mechanical signatures are checkable:

  JQ-QUOTING           `jq -R/-Rs` output interpolated into a string that a shell later re-expands
                       (`bash -c`/`bash -lc`, or a pod ARGS array). jq escapes for JSON; backticks
                       and `$` are not JSON-special and survive into the pod. The correct transport
                       is base64 → file → `"$(cat FILE)"` (agents/coordinator-session.sh, #197).
  HEREDOC-DOLLAR-DIGIT `$` followed by a digit inside an EXPANDING (`<<EOF`, not `<<'EOF'`) heredoc
                       that builds a k8s manifest — the `$103.74` shape.
  SQ-PROSE            a literal `'` inside a single-quoted shell string that is itself carried
                       through an EXPANDING heredoc or `bash -lc` payload — the apostrophe
                       terminates the string and everything after executes as shell (instance #5,
                       commit 1698b42: "sandbox's" in the pod-side single-quoted PROMPT wedged the
                       whole review plane). The transport that makes it live: the single-quoted
                       string sits INSIDE an EXPANDING heredoc body that the launcher ships to a
                       pod to run, so the pod's shell is the one that parses the broken quote.
  HEREDOC-BACKTICK    a backtick inside an UNQUOTED (`<<EOF`, not `<<'EOF'`) heredoc that builds a
                       prompt or pod manifest — command-substituted by the LAUNCHER at construction
                       time and silently vanish from the delivered text (instance #6, PR#559 lines
                       225/226/228: PR#547's `` `at efc90c5a` `` fragments executed at build time).
  HEREDOC-FN-DOLLAR    a shell FUNCTION DEFINITION embedded inside an UNQUOTED heredoc payload,
                       with an unescaped `$` in its body (instance #7, PR#727, 2026-08-20):
                       agents/reviewer-session.sh defined `depth-rule-append() { … "$1" …
                       "$PROMPT" … }` between `PREP=$(cat <<PREP` and its terminator — every
                       unescaped `$` expanded at GENERATION time, in the outer script's scope, so
                       the pod received a corrupted function (the call site's `|| true` swallowed
                       it). Fixed shape: define the function at top level and inject it with
                       `$(declare -f name)`, which is exempt (command-substitution output is not
                       re-expanded).
  DELIM-FIELD          a variable-headed `grep` pattern probing a `|`-delimited table without an
                       anchor (retro r1 F2, homelab#930: PR#631 r1, PR#863 r1/r3, PR#858 r3 — 4
                       CI-green blocking rounds in one window). `grep -m1 "$key|" table` matches
                       any row whose key merely CONTAINS the value ("deepseek" hits
                       "deepseek-v4|…"); under `-F` an anchor is impossible (`^` is literal).
                       Fixed shapes: anchored BRE `grep "^$key|"` (default grep is BRE — `|` stays
                       literal) or awk field equality (`awk -F'|' -v k="$key" '$1==k'`).
                       ⚠ The family's OTHER shape — `IFS=$'\t' read` over a table with an
                       optional-EMPTY field (tab is IFS-whitespace, so runs collapse and fields
                       shift) — is documented here but NOT mechanized: five live, correct
                       tab-read sites exist in agents/ (their producers guarantee non-empty
                       fields), so a static signature would be pure noise. Revisit on the next
                       incident of that shape.

Both are HEURISTICS on purpose (#197): a false positive costs a review prompt, a false negative is
instance #5. The discriminator that keeps the current tree green: the OUTER
`ARGS="[\\"bash\\",\\"-lc\\",$(printf %s "$WRAPPED" | jq -Rs .)]"` is the sanctioned transport and
must stay clean — it is an INNER `jq -Rs` feeding a string that is ITSELF handed to a shell that is
the bug. So exec-array assignments are exempt from the single-occurrence rule (but not from the
two-occurrences-in-one-line rule, which is the same bug written without a temp variable).

Usage:
  prompt-transport-lint.py                 # self-test on the fixtures, then lint tracked agents/**.sh
  prompt-transport-lint.py FILE [FILE...]  # lint exactly these files
  prompt-transport-lint.py --self-test     # fixtures only

Wired into CI (`devbox run prompt-transport-lint`, .github/workflows/ci.yaml) — the header's old
"not wired yet" note is history; run it locally the same way.
"""
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FIXTURES = REPO / "scripts" / "fixtures" / "prompt-transport"
# The launchers are the whole exposed surface of this class: they are the only code that builds a
# string for a shell to run INSIDE a pod. Widening to scripts/ is a one-line change here.
DEFAULT_GLOBS = ("agents/*.sh", "agents/**/*.sh")

# A heredoc opener: `<<WORD`, `<<-WORD`, `<<'WORD'`, `<<"WORD"`, `<<\WORD`. Deliberately NOT `<<<`
# (a here-string — coordinator-scan.sh has ~40 of them); the caller also rejects a match preceded
# by `<`, which is what stops `# <<<REPLAY:rail-degrade<<<` from opening a phantom heredoc.
HEREDOC_RE = re.compile(r"<<(?!<)-?\s*(\\?)(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
ASSIGN_RE = re.compile(r"^\s*(?:export\s+|local\s+|declare\s+(?:-\w+\s+)?)?([A-Za-z_][A-Za-z0-9_]*)=")
VAR_REF_RE = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)")
# `jq -Rs`, `jq -R`, `jq -sR`, `jq --arg x y -R` — raw-input mode in any spelling.
JQ_RAW_RE = re.compile(r"\bjq\b(?:\s+--?[\w-]+(?:\s+\S+)??)*?\s+-[a-zA-Z]*R[a-zA-Z]*\b")
# The pod ARGS array as it is written in the launchers, JSON-escaped inside a shell double quote:
# `[\"bash\",\"-lc\", …]`. Also matches the unescaped JSON form.
EXEC_ARRAY_RE = re.compile(r"\\?\"(?:bash|sh)\\?\"\s*,\s*\\?\"-[a-z]*c\\?\"")
EXEC_INLINE_RE = re.compile(r"\b(?:bash|sh)\s+-[a-z]*c\b")
SUBST_RE = re.compile(r"\$\(|`")
# `$1`, `${1}`, `$103.74` — unescaped only. `\$103.74` inside a warning comment is the FIXED shape
# and must not flag (agents/reviewer-session.sh carries exactly that as its maintainer note).
DOLLAR_DIGIT_RE = re.compile(r"(?<!\\)\$\{?\d")
KIND_RE = re.compile(r"^\s*kind:\s*[A-Za-z]")
STDIN_APPLY_RE = re.compile(r"\b(?:apply|create|replace|delete)\b[^|]*-f\s+-")
# A heredoc captured into a variable: `PREP=$(cat <<PREP`, `FOO="$(cat <<'EOF'"` — the captured
# value is shipped somewhere (a pod ARGS array, a file the pod reads), so its shell quoting is
# parsed again by the destination shell.
CAPTURED_HEREDOC_RE = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*\s*=\s*(?:\$)?\(?\s*cat\s+<<")
# A heredoc piped into kubectl/oc — the pod-manifest family. `"$KUBECTL"`, `${KUBECTL}`, or bare kubectl.
PIPE_TO_KUBECTL_RE = re.compile(r"\|\s*\"?\\?\$?\{?[A-Za-z_]*KUBECTL|\|\s*kubectl\b")
# A heredoc writing a prompt file (re-review.sh) — same "prose the pod reads" class.
PROMPT_FILE_HEREDOC_RE = re.compile(r"cat\s+>\s+\"?\$?\{?[A-Za-z_]*PROMPT")
SQ_ASSIGN_RE = re.compile(r"^\s*(?:export\s+|local\s+|declare\s+(?:-\w+\s+)?)?([A-Za-z_][A-Za-z0-9_]*)=\s*'")
# A shell function definition line: `name() {` or `function name {`, optionally indented. Hyphens
# are legal in bash function names (agents/reviewer-session.sh's depth-rule-append, PR#727).
FN_DEF_RE = re.compile(r"^\s*(?:([A-Za-z_][A-Za-z0-9_-]*)\s*\(\)|function\s+([A-Za-z_][A-Za-z0-9_-]*))\s*\{")
# Any unescaped `$` — deliberately broader than DOLLAR_DIGIT_RE. Used ONLY inside a heredoc-embedded
# function body (check_heredoc_fn_dollar): `$1`, `$a`, `$PROMPT` are all generation-time landmines
# there, not just `$<digit>`.
DOLLAR_ANY_RE = re.compile(r"(?<!\\)\$")
# A block that never closes its quote would swallow the rest of the file and turn one typo into a
# whole-file false positive. Cap it: past this many lines the scanner gives up on that assignment.
MAX_BLOCK_LINES = 80
# DELIM-FIELD: everything after a grep call on the line (a quoted pattern may itself contain `|`,
# so the span deliberately does NOT stop at shell pipe chars — the quoted-string extraction below
# is what scopes it), and a double-quoted string inside that span. VAR-headed = the pattern begins
# with an interpolation.
GREP_CALL_RE = re.compile(r"\bgrep\b(.*)$")
DQ_STRING_RE = re.compile(r'"((?:[^"\\]|\\.)*)"')
VAR_HEAD_RE = re.compile(r"^\$\{?[A-Za-z_]")


def scan_quotes(text, in_single, in_double):
    """Advance the shell quoting state across one line. Returns (in_single, in_double).

    Backslash escapes only outside single quotes (`\\` is literal in `'…'`), and an unquoted `#`
    at a word boundary starts a comment — without that rule an apostrophe in a trailing comment
    opens a quote that never closes, which is the very class this lint is about.
    """
    i = 0
    while i < len(text):
        c = text[i]
        if in_single:
            if c == "'":
                in_single = False
        elif in_double:
            if c == "\\":
                i += 1
            elif c == '"':
                in_double = False
        else:
            if c == "\\":
                i += 1
            elif c == "'":
                in_single = True
            elif c == '"':
                in_double = True
            elif c == "#" and (i == 0 or text[i - 1] in " \t;&|("):
                break
        i += 1
    return in_single, in_double


def parse(lines):
    """Split a shell file into heredocs and assignment blocks.

    Returns (heredocs, blocks, plain_lines). A heredoc is {delim, expanding, opener, body}; a block
    is {var, lines} covering a possibly multi-line `VAR=…` assignment; plain_lines are the code
    lines that belong to neither.
    """
    heredocs, blocks, plain = [], [], []
    cur = None                      # open assignment block
    in_single = in_double = False
    heredoc = None                  # heredoc body being consumed
    pending = []                    # openers seen on the current line, not yet consumed

    for no, raw in enumerate(lines, 1):
        if heredoc is not None:
            if cur is not None:
                cur["lines"].append((no, raw))       # the body is part of the assignment's value…
            if raw.strip() == heredoc["delim"]:
                heredocs.append(heredoc)
                heredoc = pending.pop(0) if pending else None
            else:
                heredoc["body"].append((no, raw))
            continue                                  # …but its quotes never affect the parity scan

        if cur is None:
            m = ASSIGN_RE.match(raw)
            if m and not raw.lstrip().startswith("#"):
                cur = {"var": m.group(1), "start": no, "lines": [(no, raw)]}
                in_single, in_double = scan_quotes(raw, False, False)
                if not (in_single or in_double):
                    blocks.append(cur)
                    cur = None
            else:
                plain.append((no, raw))
        else:
            cur["lines"].append((no, raw))
            in_single, in_double = scan_quotes(raw, in_single, in_double)
            if not (in_single or in_double) or len(cur["lines"]) > MAX_BLOCK_LINES:
                blocks.append(cur)
                cur = None

        if not raw.lstrip().startswith("#"):
            for m in HEREDOC_RE.finditer(raw):
                if m.start() > 0 and raw[m.start() - 1] == "<":
                    continue
                hd = {
                    "delim": m.group(3),
                    "expanding": not m.group(1) and not m.group(2),
                    "opener": raw,
                    "opener_no": no,
                    "body": [],
                }
                if heredoc is None:
                    heredoc = hd
                else:
                    pending.append(hd)

    if cur is not None:
        blocks.append(cur)
    if heredoc is not None:
        heredocs.append(heredoc)
    return heredocs, blocks, plain


def check_heredocs(heredocs):
    """HEREDOC-DOLLAR-DIGIT: `$<digit>` inside an EXPANDING heredoc that builds a k8s manifest."""
    out = []
    for hd in heredocs:
        if not hd["expanding"]:
            continue
        body = hd["body"]
        is_manifest = (
            any(KIND_RE.match(t) for _, t in body) and any("apiVersion:" in t for _, t in body)
        ) or bool(STDIN_APPLY_RE.search(hd["opener"]))
        if not is_manifest:
            continue
        for no, text in body:
            if DOLLAR_DIGIT_RE.search(text):
                out.append((no, "HEREDOC-DOLLAR-DIGIT", (
                    "`$<digit>` inside the EXPANDING heredoc opened at line %d (`<<%s`) — the shell "
                    "expands it as a positional parameter ($103.74 → ${1}03.74) and silently "
                    "corrupts the manifest, or dies under `set -u`. Write `USD 103.74`, escape it "
                    "`\\$1`, or quote the delimiter `<<'%s'`." % (hd["opener_no"], hd["delim"], hd["delim"])
                ), text.strip()))
    return out


def _payload_heredoc(hd):
    """True when an EXPANDING heredoc's body is carried to a re-executing context.

    The three shapes that make backtick command-substitution LIVE:
      * piped into kubectl/oc (`cat <<EOF | kubectl create -f -`) — the pod-manifest family;
      * captured into a variable (`PREP=$(cat <<PREP`) that is shipped to a pod to run;
      * written to a prompt file the pod reads (re-review.sh).
    The `done <<FEED` loop-feeds (coordinator-scan.sh, footprint.sh, …) are data feeds, not
    payloads — a backtick there is ordinary text and must not flag.
    """
    if hd["opener"].lstrip().startswith("done "):
        return False
    body = hd["body"]
    is_manifest_body = (
        any(KIND_RE.match(t) for _, t in body) and any("apiVersion:" in t for _, t in body)
    )
    return bool(
        CAPTURED_HEREDOC_RE.search(hd["opener"])
        or PIPE_TO_KUBECTL_RE.search(hd["opener"])
        or PROMPT_FILE_HEREDOC_RE.search(hd["opener"])
        or STDIN_APPLY_RE.search(hd["opener"])
        or is_manifest_body
    )


def check_heredoc_backtick(heredocs):
    """HEREDOC-BACKTICK: a backtick inside an UNQUOTED heredoc that builds a prompt or pod manifest.

    An unquoted heredoc body is command-substituted at construction time. A backtick in it — even
    inside a `# comment` line, which the shell does NOT recognise inside a heredoc body — runs a
    command whose stdout replaces the fragment, so prose silently vanishes from the delivered text
    (instance #6, PR#559 lines 225/226/228). The launcher's own convention is two-space padding
    (`  head  `) precisely to avoid this.
    """
    out = []
    for hd in heredocs:
        if not hd["expanding"] or not _payload_heredoc(hd):
            continue
        for no, text in hd["body"]:
            ticks = [m.start() for m in re.finditer(r"`", text)]
            skip = set()
            for i, pos in enumerate(ticks):
                if pos in skip:
                    continue
                if pos > 0 and text[pos - 1] == "\\":
                    continue  # escaped backtick survives expansion literally
                end = text.find("`", pos + 1)
                frag = text[pos:end + 1] if end != -1 else "`"
                inner = text[pos + 1:end].strip() if end != -1 else "…"
                # A backtick pair is ONE command substitution — emit one finding, not one per tick.
                if end != -1 and end in ticks:
                    skip.add(end)
                out.append((no, "HEREDOC-BACKTICK", (
                    "backtick inside the UNQUOTED heredoc opened at line %d (<<%s) — the launcher "
                    "command-substitutes it when building the %s, so %s silently vanishes from the "
                    "delivered prompt. Quote the delimiter <<'%s', escape the backtick, or use "
                    "two-space padding (  %s  )." % (
                        hd["opener_no"], hd["delim"], hd["delim"],
                        frag, hd["delim"], inner,
                    )
                ), text.strip()))
    return out


def check_heredoc_fn_dollar(heredocs):
    """HEREDOC-FN-DOLLAR: a shell function DEFINITION embedded inside an UNQUOTED heredoc payload,
    with an unescaped `$` somewhere in its body (instance #7, PR#727, 2026-08-20).

    agents/reviewer-session.sh's first cut defined `depth-rule-append() { … "$1" … "$PROMPT" … }`
    between `PREP=$(cat <<PREP` and its terminator — an unquoted (expanding) delimiter, so every
    unescaped `$` in the function body expanded at GENERATION time, in the outer launcher's scope,
    not at pod-run time. The pod received a corrupted function; the call site's `|| true` swallowed
    the failure silently, and the extraction-based replay stayed green (it reads source, not
    generated output). The fixed shape — define the function at TOP LEVEL, inject it into the
    heredoc via `$(declare -f name)` — must NOT flag: a `$(declare -f …)` line never matches
    FN_DEF_RE (it is a call, not a `name() {` definition), and a top-level definition sits in
    `plain`, never in a heredoc body, so this check never sees it.

    One finding per function (at its definition line), not per `$` — the class is "this function
    got embedded here at all", and a per-occurrence report would just be noise on the same defect.
    Brace matching is a simple per-line `{`/`}` count, same heuristic weight as the rest of this
    file (#197): good enough for the shapes these launchers actually write.
    """
    out = []
    for hd in heredocs:
        if not hd["expanding"] or not _payload_heredoc(hd):
            continue
        body = hd["body"]
        i, n = 0, len(body)
        while i < n:
            no, text = body[i]
            m = FN_DEF_RE.match(text)
            if not m:
                i += 1
                continue
            fn_name = m.group(1) or m.group(2)
            depth = text.count("{") - text.count("}")
            has_dollar = bool(DOLLAR_ANY_RE.search(text[m.end():]))
            j = i
            while depth > 0 and j + 1 < n:
                j += 1
                _, jtext = body[j]
                depth += jtext.count("{") - jtext.count("}")
                if DOLLAR_ANY_RE.search(jtext):
                    has_dollar = True
            if has_dollar:
                out.append((no, "HEREDOC-FN-DOLLAR", (
                    "shell function `%s() { … }` defined inside the UNQUOTED heredoc opened at "
                    "line %d (<<%s) has an unescaped $ in its body — the LAUNCHER expands it at "
                    "GENERATION time, in the outer script's scope, not the pod, corrupting the "
                    "emitted function (instance #7, PR#727, 2026-08-20). Define the function at "
                    "top level and inject with $(declare -f %s), or escape every $ — "
                    "generation-time expansion corrupts the emitted copy (the PR#727 class)."
                    % (fn_name, hd["opener_no"], hd["delim"], fn_name)
                ), text.strip()))
            i = j + 1
    return out


def check_sq_prose(heredocs):
    """SQ-PROSE: an apostrophe inside a single-quoted string carried through an expanding transport.

    The instance (#5, commit 1698b42) was a `PROMPT='…'` assignment INSIDE the body of an EXPANDING
    heredoc (`PREP=$(cat <<PREP`). The body is shipped to a pod and executed, so the apostrophe in
    the prose ("sandbox's") terminated the single-quoted string and everything after parsed as
    shell — every reviewer pod died on a syntax error. Detection: parse each captured EXPANDING
    heredoc's body as shell, extract each `VAR='…'` block, and `bash -n` it. A broken apostrophe
    makes the assignment unparseable; a clean single-quoted prompt parses with exactly two
    apostrophes (opening + closing).
    """
    out = []
    for hd in heredocs:
        if not hd["expanding"] or not CAPTURED_HEREDOC_RE.search(hd["opener"]):
            continue
        body_lines = [t for _, t in hd["body"]]
        _, inner_blocks, _ = parse(body_lines)
        for b in inner_blocks:
            first = b["lines"][0][1]
            if not SQ_ASSIGN_RE.search(first):
                continue
            text = "".join(t for _, t in b["lines"])
            r = subprocess.run(["bash", "-n"], input=text, capture_output=True, text=True)
            if r.returncode != 0:
                out.append((hd["opener_no"] + b["start"], "SQ-PROSE", (
                    "apostrophe inside the single-quoted %s='…' string carried through the EXPANDING "
                    "heredoc opened at line %d (`<<%s`) — the pod's shell parses this later, and the "
                    "' terminates the string so the rest executes as shell (instance #5, 1698b42). "
                    "bash -n on the extracted assignment fails: %s. Reword apostrophe-free." % (
                        b["var"], hd["opener_no"], hd["delim"], r.stderr.strip().splitlines()[-1]
                        if r.stderr.strip() else "syntax error",
                    )
                ), text.strip().splitlines()[0]))
    return out


def check_delim_field(lines):
    """DELIM-FIELD: a variable-headed grep pattern probing a `|`-delimited table, unanchored.

    Line-local by design (the call shape is one line wherever it appears — plain code, an
    assignment block, or a heredoc-shipped script body), so this scans raw lines and skips only
    comment lines. Two firing shapes, one message each:

      * regex grep, pattern starts with `$var` and contains `|`, no `^` anchor — a value that is
        a PREFIX of another value matches the wrong row (PR#631's class);
      * `-F` grep whose pattern interpolates a variable and contains `|` — `-F` makes `^` literal,
        so the call CANNOT be anchored; the fix is anchored BRE or awk field equality.

    The tab-`read` half of the retro F2 family is documented in the header and deliberately not
    mechanized (five live correct sites; see the signature table).
    """
    out = []
    for no, text in enumerate(lines, 1):
        if text.lstrip().startswith("#") or "grep" not in text:
            continue
        m = GREP_CALL_RE.search(text)
        if not m:
            continue
        span = m.group(1)
        for sm in DQ_STRING_RE.finditer(span):
            pat = sm.group(1)
            if "|" not in pat or "$" not in pat:
                continue
            fixed = bool(re.search(r"(?:^|\s)-[a-zA-Z]*F[a-zA-Z]*\b", span[: sm.start()]))
            if fixed and (VAR_HEAD_RE.match(pat) or pat.startswith("^$")):
                out.append((no, "DELIM-FIELD", (
                    "`grep -F` with an interpolated `|`-delimited table pattern — under -F a `^` "
                    "is LITERAL, so this probe cannot be anchored and a value that is a prefix of "
                    "another value matches the wrong row (retro r1 F2, homelab#930). Use anchored "
                    "BRE (`grep \"^$key|\"` — default grep is BRE, `|` stays literal) or awk field "
                    "equality (`awk -F'|' -v k=\"$key\" '$1==k'`)."
                ), text.strip()))
            elif not fixed and VAR_HEAD_RE.match(pat):
                out.append((no, "DELIM-FIELD", (
                    "variable-headed pattern against a `|`-delimited table without a `^` anchor — "
                    "a key that is a PREFIX of another key matches the wrong row (retro r1 F2, "
                    "homelab#930: PR#631/#863/#858 all shipped this CI-green). Anchor it "
                    "(`grep \"^$key|\"`) or use awk field equality (`awk -F'|' -v k=\"$key\" "
                    "'$1==k'`)."
                ), text.strip()))
    return out


def check_jq_quoting(blocks, plain):
    """JQ-QUOTING: `jq -R` output interpolated into a string a shell later re-expands."""
    def jq_hits(lines):
        hits = []
        for no, text in lines:
            for m in JQ_RAW_RE.finditer(text):
                if SUBST_RE.search(text[: m.start()]):   # inside `$( … )` / backticks
                    hits.append((no, text))
        return hits

    by_var = {}
    for b in blocks:
        b["body"] = "".join(t for _, t in b["lines"])
        b["refs"] = set(VAR_REF_RE.findall(b["body"]))
        b["is_exec"] = bool(EXEC_ARRAY_RE.search(b["body"]) or EXEC_INLINE_RE.search(b["body"]))
        b["jq"] = jq_hits(b["lines"])
        by_var.setdefault(b["var"], []).append(b)

    # Seed: every variable whose CONTENT is handed to a shell to execute. Then walk the
    # interpolation graph — a var spliced into a var spliced into `bash -lc` is just as expanded.
    danger, queue = set(), []
    for b in blocks:
        if b["is_exec"]:
            queue.extend(b["refs"] - {b["var"]})
    for no, text in plain:
        if EXEC_ARRAY_RE.search(text) or EXEC_INLINE_RE.search(text):
            queue.extend(VAR_REF_RE.findall(text))
    while queue:
        v = queue.pop()
        if v in danger:
            continue
        danger.add(v)
        for b in by_var.get(v, []):
            queue.extend(b["refs"])

    out = []
    for b in blocks:
        if b["is_exec"]:
            # The sanctioned transport is ONE jq -Rs, at the outermost layer. Two on the same line
            # is the same bug as below, written without the temp variable.
            for no, text in b["jq"][1:]:
                out.append((no, "JQ-QUOTING", (
                    "two `jq -R` command substitutions building one `bash -c` argument — the inner "
                    "one JSON-escapes prose that the pod's shell then re-expands (backticks and `$` "
                    "are not JSON-special). Send it base64 → file → `\"$(cat FILE)\"` instead."
                ), text.strip()))
            continue
        if b["var"] in danger and b["jq"]:
            no, text = b["jq"][0]
            out.append((no, "JQ-QUOTING", (
                "`jq -R` output is interpolated into $%s, which reaches a `bash -c`/`bash -lc` that "
                "RE-EXPANDS it — jq escapes for JSON, not for the shell, so backticks and `$` in the "
                "prompt execute in the pod (#197 instance 4). Send it base64 → file → "
                "`\"$(cat FILE)\"`, the transport SEED already uses." % b["var"]
            ), text.strip()))
    return out


def lint(path):
    """Returns a sorted list of (line, code, message, source) findings for one file."""
    lines = Path(path).read_text().splitlines(keepends=True)
    heredocs, blocks, plain = parse(lines)
    return sorted(
        check_heredocs(heredocs)
        + check_heredoc_backtick(heredocs)
        + check_heredoc_fn_dollar(heredocs)
        + check_sq_prose(heredocs)
        + check_jq_quoting(blocks, plain)
        + check_delim_field(lines)
    )


def report(path, findings):
    for no, code, msg, src in findings:
        print("prompt-transport-lint: FAIL %s:%d [%s]\n    %s\n    %s" % (path, no, code, src, msg),
              file=sys.stderr)


def self_test():
    """The positive controls are the two real pre-fix defects, committed as FIXTURE STRINGS (never
    live code, #197). Each fixture declares what it must produce as `# EXPECT: CODE@line` / clean —
    a lint whose own controls are not executed is a lint nobody knows is still wired up."""
    fixtures = sorted(FIXTURES.glob("*.fixture"))
    if len(fixtures) < 4:
        print("prompt-transport-lint: PROBE-FAIL — expected the fixture set in %s, found %d"
              % (FIXTURES, len(fixtures)), file=sys.stderr)
        return 1
    rc = 0
    for f in fixtures:
        want = set()
        for line in f.read_text().splitlines():
            m = re.search(r"#\s*EXPECT:\s*(\S+)", line)
            if m and m.group(1) != "clean":
                code, _, no = m.group(1).partition("@")
                want.add((code, int(no)))
        got = {(code, no) for no, code, _, _ in lint(f)}
        if got == want:
            print("prompt-transport-lint: self-test ok — %s (%s)"
                  % (f.name, ", ".join(sorted("%s@%d" % (c, n) for c, n in want)) or "clean"))
            continue
        rc = 1
        print("prompt-transport-lint: SELF-TEST FAIL %s\n    expected %s\n    got      %s"
              % (f, sorted(want) or "clean", sorted(got) or "clean"), file=sys.stderr)
        report(str(f), lint(f))
    return rc


def tracked_files():
    out = []
    for glob in DEFAULT_GLOBS:
        r = subprocess.run(["git", "-C", str(REPO), "ls-files", glob],
                           capture_output=True, text=True, check=True)
        out.extend(REPO / p for p in r.stdout.split())
    return sorted(set(out))


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    only_self_test = "--self-test" in argv
    rc = 0
    if not args:
        rc = self_test()
        if only_self_test:
            return rc
        files = tracked_files()
        if not files:
            print("prompt-transport-lint: PROBE-FAIL — zero files matched %s (git ls-files broken?)"
                  % (DEFAULT_GLOBS,), file=sys.stderr)
            return 1
    else:
        files = [Path(a) for a in args]

    hits = 0
    for f in files:
        findings = lint(f)
        hits += len(findings)
        report(str(f), findings)
    if hits:
        print("prompt-transport-lint: FAIL — %d finding(s) across %d file(s). The signatures are "
              "heuristics (#197): if this one is wrong, say so in the PR and refine the rule — do "
              "not silence it by rewriting the prompt around it." % (hits, len(files)), file=sys.stderr)
        return 1
    print("prompt-transport-lint: ok (%d files, 0 findings)" % len(files))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
