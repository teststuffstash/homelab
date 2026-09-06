#!/usr/bin/env python3
"""agents/issue_body.py — the ONE issue-body parser (ADR-122 (3), homelab#1430, S8 original 1a).

WHY THIS EXISTS. ADR-122 measured the authoring surface on 2026-09-03: **13 line-anchored body
grammars**, `Touches:` alone parsed in 9 files, each reader carrying its own regex with its own
quirks (one is case-sensitive, one demands a space after the colon, one strips currency symbols,
one is a bare substring test). The sum of individually-right readers is unauthorable — an author
who writes `**Touches:**` believes a footprint is declared while the scan reads none, and a
`Budget:` indented by two spaces funds nothing. So the grammars collapse into ONE machine block
read by ONE parser every consumer calls (ADR-113: Python from birth, stdlib only).

## The machine block

At the TOP of an issue body, between two `---` lines:

    ---
    Touches: agents/foo.sh, docs/bar.md
    Base: goal/12-slug
    Budget: 30
    Class: build
    ---

The grammar is the `agents/replay/` fixture.yaml subset (run.sh `parse_fixture`): flat
`key: value` lines, blank lines skipped, no nesting, no multi-line values,
lists comma-separated. Keys are the ADR-122 pin's 13 grammar names, case-SENSITIVE and exact
(`GRAMMAR` below). Anything else inside the fences — an unknown key, an indented/bulleted line,
a duplicate key, an unterminated fence — is a LOUD parse error (`IssueBodyError` in the API,
exit 2 + one stderr line in the CLI), never a silent skip: a silently-skipped line is exactly
the failure this module exists to end. A body with NO block is legal and parses to `{}`.

VALUE SHAPES are documented per key in `GRAMMAR_DOC` and are NOT enforced here. Deliberate:
the value policies live with the readers that already own them and phrase them better
(`goal-lint` says "Budget: '$12' is not a bare number (the launcher parses it as USD)"), and
forking that policy between the block path and the legacy path is how the two would drift. The
parser is a faithful READER; structure is its business, semantics are the caller's.

## The legacy read (transition window)

Until the writers switch (S8 original 1b, #1431) and the window closes (closeout 2), every key
with a live reader today is ALSO read in its existing line-anchored form, anywhere in the body,
with that reader's exact semantics — see `LEGACY`, each entry citing its source line. The block
wins; a legacy value used because the block lacked the key prints ONE line to stderr:

    LEGACY-GRAMMAR <key> <ref>

That is the migration meter (`<ref>` = whatever the caller passed as `--ref`, e.g.
`homelab#1302`; empty → `-`). Never suppress it.

⚠ THE READERS DO NOT AGREE WITH EACH OTHER, and this module does not paper over that. Example:
`scripts/goal-lint.sh`'s `line()` helper reads `Budget:` case-sensitively with leading
whitespace allowed; `agents/goal-budget.sh`'s `gb_budget_line` reads it at column 0 only and
strips a currency symbol. Widening either one silently would change a MONEY gate. So the
divergent forms are kept as named VARIANTS (`--legacy <variant>`) rather than unified by fiat:
each caller keeps byte-identical behaviour today, and the block — which has exactly one
spelling — is what actually collapses them.

## API

    parse(body, ref=…, variant=…)   -> dict of every key found (block ∪ legacy), values as str
    get(body, key, ref=…, variant=…)-> str | None
    touches(body, …)                -> list[str]   (the ONE list helper: split + strip + drop empties)
    render_block(fields)            -> str         ("---\\nk: v\\n---", no trailing newline)
    upsert_block(body, fields)      -> str         (replace or insert; the rest byte-identical)

## CLI (body on stdin, so bash callers pipe `gh issue view --json body -q .body`)

    python3 agents/issue_body.py get <key> [--ref R] [--legacy V] < body
    python3 agents/issue_body.py json [--ref R] [--legacy V] < body
    python3 agents/issue_body.py set <key>=<value> ... < body      # prints the new body
    python3 agents/issue_body.py --self-test

`get` prints nothing and exits 0 when the key is absent (the shell greps it replaces behave the
same way, and every caller runs under `set -e`); exit 2 is a grammar violation or a usage error.
"""
from __future__ import annotations

import json
import re
import sys

# The 13 grammars of ADR-122 pin 1, in the pin's own order — which is also render order.
GRAMMAR = (
    "Touches",
    "Base",
    "Budget",
    "Verdict-authority",
    "Production-leg",
    "Revert",
    "Origin",
    "Size",
    "Capability",
    "alert-fp",
    "self-referential",
    "fix-verdict",
    "Class",
)

# Value shapes, documented, enforced by the owning reader (see the module docstring).
GRAMMAR_DOC = {
    "Touches": "comma-separated repo-relative paths/globs (ADR-097)",
    "Base": "a branch name — `master` or `goal/<n>-<slug>`",
    "Budget": "a bare number, read as USD",
    "Verdict-authority": "human | kpi",
    "Production-leg": "free text — what production validates",
    "Revert": "free text — the pin rollback or revert commit",
    "Origin": "`<repo>#<n>` the filing came from (block-only; no reader today)",
    "Size": "free text estimate (block-only; no reader today)",
    "Capability": "free text capability fingerprint (ADR-119 platform-request)",
    "alert-fp": "the responder's alert fingerprint",
    "self-referential": "true | false",
    "fix-verdict": "fix | report-only",
    "Class": "fix | build | goal | research (ADR-122 (2) — replaces the task/* label)",
}

# `Class` has NO legacy body form: it maps from the `task/<class>` LABEL, which a body parser
# cannot see. `get(body, "Class")` therefore returns the block value or nothing, and callers pass
# labels separately (S8 original 1b, #1431, wires that).
BLOCK_ONLY = ("Class", "Origin", "Size")


class IssueBodyError(Exception):
    """A grammar violation. Loud by contract — never downgraded to a silent skip."""


# ── the legacy table ────────────────────────────────────────────────────────────────────────────
# One entry per key with a live reader. `pattern` is that reader's regex restated in Python with
# the SAME anchoring, case-sensitivity and emptiness rules; `normalize` is whatever the reader
# does to the captured value afterwards. The `source` field is the citation, and it is the point:
# when 1b deletes a reader, its entry here is what says which file to look at.


class _Legacy(object):
    __slots__ = ("pattern", "source", "normalize", "all_matches", "join", "probe")

    def __init__(self, pattern, source, normalize=None, all_matches=False, join=",", probe=None):
        self.pattern = re.compile(pattern) if pattern else None
        self.source = source
        self.normalize = normalize
        self.all_matches = all_matches
        self.join = join
        self.probe = probe  # a callable(body) -> str|None, for forms that are not regex-shaped


def _rstrip(v):
    return v.rstrip()


def _budget_norm(v):
    """`agents/goal-budget.sh` gb_budget_line's tail, verbatim:
        sed 's/^[^0-9]*//' | tr -d '[:space:]' | grep -E '^[0-9]+(\\.[0-9]+)?$'
    i.e. strip everything before the first digit (the `$`/`€` case — the number is read as USD by
    deliberate, stated approximation), delete all whitespace, and yield NOTHING unless what is
    left is a bare number. Applied to the FIRST matching line only (`head -1` sits before the
    grep in the pipeline, so a non-numeric first line does not fall through to a later one)."""
    v = re.sub(r"^[^0-9]*", "", v)
    v = re.sub(r"\s", "", v)
    return v if re.match(r"^[0-9]+(\.[0-9]+)?$", v) else ""


def _squash_ws(v):
    """`agents/agent-session.sh`'s `Base:` tail, verbatim: `tr -d '[:space:]'` — DELETE every
    whitespace character in the value (not a trim). A branch name carries none, so the two
    readings coincide on every real declaration; the difference is what a malformed one becomes,
    and preserving it is what makes the launcher's migration a no-op on its own inputs."""
    return re.sub(r"\s", "", v)


def _verdict_norm(v):
    """`agents/coordinator-scan.sh` ~2350: `gsub(/[ \\t\\r]/, "", v); print tolower(v)`."""
    return re.sub(r"[ \t\r]", "", v).lower()


def _revert_norm(v):
    """`agents/coordinator-scan.sh` ~2445: `sub(/[ \\t\\r]+$/, "", v)` — trailing trim only."""
    return re.sub(r"[ \t\r]+$", "", v)


def _selfref_probe(body):
    """`agents/coordinator/fix-debounce-argo.yaml` ~286 is a bare SUBSTRING test —
    `jq 'select(.body | contains("self-referential: true"))'` — not a line-anchored grammar. It
    is restated as what it is: present ⇒ `true`, absent ⇒ nothing. (A body carrying
    `self-referential: false` is simply not the marker, which is the debounce's own reading.)"""
    return "true" if "self-referential: true" in body else None


LEGACY = {
    # agents/coordinator-scan.sh:1393 (and 1838/1923/2264) — the ADR-097 footprint grammar:
    # case-insensitive, leading whitespace/tabs allowed, value must be non-empty, and EVERY
    # matching line is unioned with "," (reviewer-session.sh:593 does the same union, S6 #716).
    "Touches": _Legacy(r"(?im)^[ \t]*touches:[ \t]*(.+)$", "agents/coordinator-scan.sh:1393",
                       normalize=_rstrip, all_matches=True),
    # agents/coordinator-scan.sh:1084 — `grep -qiP '^[ \t]*base:[ \t]*.+'`: case-insensitive,
    # leading whitespace allowed, at least one character after the colon (homelab#828 r2 f2).
    "Base": _Legacy(r"(?im)^[ \t]*base:[ \t]*(.+)$", "agents/coordinator-scan.sh:1084",
                    normalize=_rstrip),
    # agents/goal-budget.sh:86 gb_budget_line — `sed -n 's/^[Bb]udget:[[:space:]]*//p'`:
    # column 0 only (NO leading whitespace), `Budget:`/`budget:` only, first match wins.
    "Budget": _Legacy(r"(?m)^[Bb]udget:[ \t]*(.*)$", "agents/goal-budget.sh:86",
                      normalize=_budget_norm),
    # agents/coordinator-scan.sh:2350 — awk `/^[ \t]*[Vv]erdict-authority:/`, first match.
    "Verdict-authority": _Legacy(r"(?m)^[ \t]*[Vv]erdict-authority:[ \t]*(.*)$",
                                 "agents/coordinator-scan.sh:2350", normalize=_verdict_norm),
    # scripts/goal-lint.sh:37 `line()` — the only reader; case-sensitive, leading ws allowed.
    "Production-leg": _Legacy(r"(?m)^[ \t]*Production-leg:[ \t]*(.*)$", "scripts/goal-lint.sh:37",
                              normalize=_rstrip),
    # agents/coordinator-scan.sh:2445 — awk `/^[ \t]*[Rr]evert:/`, first match.
    "Revert": _Legacy(r"(?m)^[ \t]*[Rr]evert:[ \t]*(.*)$", "agents/coordinator-scan.sh:2445",
                      normalize=_revert_norm),
    # agents/board.sh:230 — `capture("(?im)^Capability:[ \t]+(?<cap>[^\n]+)")`: column 0, and at
    # least ONE space/tab after the colon (the `+`), unlike every other grammar here.
    "Capability": _Legacy(r"(?im)^capability:[ \t]+(.+)$", "agents/board.sh:230", normalize=_rstrip),
    # agents/reviewer-session.sh:332 `grep -qE '^alert-fp:'` and
    # agents/meta-needs-attention.sh:170 `test("(^|\\n)alert-fp:")` — column 0, value may be
    # glued to the colon (`alert-fp:r1`, responder-behaviour-test.sh:376).
    "alert-fp": _Legacy(r"(?m)^alert-fp:[ \t]*(.*)$", "agents/reviewer-session.sh:332",
                        normalize=_rstrip),
    # the responder lane's verdict line (agents/coordinator/responder-argo.yaml:685 writes it;
    # agents/coordinator/responder-behaviour-test.sh:385 pins `grep -q '^fix-verdict:'`).
    "fix-verdict": _Legacy(r"(?m)^fix-verdict:[ \t]*(.*)$",
                           "agents/coordinator/responder-argo.yaml:685", normalize=_rstrip),
    # a substring test, not a grammar — see _selfref_probe.
    "self-referential": _Legacy(None, "agents/coordinator/fix-debounce-argo.yaml:286",
                                probe=_selfref_probe),
}

# ── legacy VARIANTS ─────────────────────────────────────────────────────────────────────────────
# `scripts/goal-lint.sh`'s `line()` is a single generic helper applied to four keys:
#   grep -m1 -E "^[[:space:]]*<Key>:[[:space:]]*" | sed -E "s/^[[:space:]]*<Key>:[[:space:]]*//; s/[[:space:]]+$//"
# — case-SENSITIVE on the key as spelled, leading whitespace allowed, an empty value allowed,
# first match, trailing whitespace trimmed, NO further normalization. That differs from the
# canonical readers above for `Budget` (which is column-0-only and currency-stripping) and for
# `Verdict-authority` (which lowercases). Preserved as a named variant so goal-lint keeps
# byte-identical behaviour rather than silently inheriting a money gate's widening.
# `agents/agent-session.sh`'s `Base:` read (the launcher pre-flight, ~line 791) is the OTHER
# divergent form: `sed -n 's/^[Bb]ase:[[:space:]]*//p' | head -1 | tr -d '[:space:]'` — COLUMN 0
# only (no leading whitespace), `Base:`/`base:` only (not the canonical reader's full
# case-insensitivity), first match, and all whitespace deleted from the value. It gates ARMING
# (a declared base un-arms auto-merge), so widening it by fiat would change what merges itself;
# named as a variant instead, exactly like goal-lint's money read. S8 original 1b, homelab#1431.
VARIANTS = {
    "agent-session": {
        "Base": _Legacy(r"(?m)^[Bb]ase:[ \t]*(.*)$", "agents/agent-session.sh:791",
                        normalize=_squash_ws),
    },
    "goal-lint": dict(
        (k, _Legacy(r"(?m)^[ \t]*" + re.escape(k) + r":[ \t]*(.*)$", "scripts/goal-lint.sh:37 line()",
                    normalize=_rstrip))
        for k in GRAMMAR if k not in BLOCK_ONLY
    ),
}


def _legacy_spec(key, variant):
    if variant:
        table = VARIANTS.get(variant)
        if table is None:
            raise IssueBodyError("unknown legacy variant %r (known: %s)"
                                 % (variant, ", ".join(sorted(VARIANTS))))
        if key in table:
            return table[key]
    return LEGACY.get(key)


def _legacy_read(body, key, variant=None):
    """The key's legacy line-anchored value, or None. Empty counts as absent — every shell reader
    this restates treats an empty value as no value (`.+` patterns) or tests `-n` afterwards."""
    if key in BLOCK_ONLY:
        return None
    spec = _legacy_spec(key, variant)
    if spec is None:
        return None
    if spec.probe is not None:
        return spec.probe(body) or None
    matches = spec.pattern.findall(body)
    if not matches:
        return None
    if spec.all_matches:
        vals = [spec.normalize(m) if spec.normalize else m for m in matches]
        vals = [v for v in vals if v != ""]
        value = spec.join.join(vals)
    else:
        value = matches[0]
        if spec.normalize:
            value = spec.normalize(value)
    return value or None


def _report_legacy(key, ref):
    sys.stderr.write("LEGACY-GRAMMAR %s %s\n" % (key, ref or "-"))


# ── the block ───────────────────────────────────────────────────────────────────────────────────

# ⚠ `[ \t\r]` on the fence, not `[ \t]`: a body authored through the GitHub WEB UI comes back
# with CRLF line endings, so the fence line is `---\r`. Without the `\r` the block would simply
# not be SEEN on those bodies — the whole block silently invisible, every unknown key inside it
# silently skipped, which is the exact failure mode this grammar's loudness exists to prevent.
# The scan's own awk normalizers strip `\r` for the same reason (coordinator-scan.sh:2350).
# Key lines need no such treatment: `_KEY_RE`'s value capture is `.rstrip()`ed, and every legacy
# normalizer below already deletes or trims `\r`.
_FENCE_RE = re.compile(r"^[ \t]*---[ \t\r]*$")
_KEY_RE = re.compile(r"^([A-Za-z][A-Za-z0-9._-]*):[ \t]*(.*)$")


def block_span(body):
    """`(first, last)` line indices of the fenced block's two `---` lines, or None when the body
    carries no block. Raises when the block opens and never closes — an unterminated fence is a
    malformed block, not "no block": treating it as absent is the silent skip the contract bans."""
    lines = (body or "").split("\n")
    i = 0
    while i < len(lines) and lines[i].strip() == "":
        i += 1
    if i >= len(lines) or not _FENCE_RE.match(lines[i]):
        return None
    for j in range(i + 1, len(lines)):
        if _FENCE_RE.match(lines[j]):
            return (i, j)
    raise IssueBodyError(
        "machine block opens with `---` at the top of the body and is never closed "
        "(add the closing `---`)")


def parse_block(body):
    """The machine block's fields as an ordered dict, `{}` when there is no block."""
    span = block_span(body)
    if span is None:
        return {}
    lines = (body or "").split("\n")
    first, last = span
    fields = {}
    for n in range(first + 1, last):
        raw = lines[n]
        if raw.strip() == "":
            continue
        if raw[:1] in (" ", "\t"):
            raise IssueBodyError(
                "machine block line %d is indented (%r) — the block is FLAT `key: value` lines; "
                "nesting is not in the grammar" % (n + 1, raw))
        m = _KEY_RE.match(raw)
        if m is None:
            raise IssueBodyError(
                "machine block line %d is not a `key: value` line (%r) — bullets, headings, "
                "prose and multi-line values are not in the grammar" % (n + 1, raw))
        key, value = m.group(1), m.group(2).rstrip()
        if key not in GRAMMAR:
            raise IssueBodyError(
                "machine block line %d: unknown key %r — the grammar is exactly: %s"
                % (n + 1, key, ", ".join(GRAMMAR)))
        if key in fields:
            raise IssueBodyError(
                "machine block line %d: duplicate key %r — one line per key is the machine truth"
                % (n + 1, key))
        fields[key] = value
    return fields


def render_block(fields):
    """The fenced block for `fields`, in GRAMMAR order, with no trailing newline. Values are
    single-line by grammar; keys outside the grammar and multi-line values are refused."""
    unknown = [k for k in fields if k not in GRAMMAR]
    if unknown:
        raise IssueBodyError("cannot render unknown key(s) %s — the grammar is exactly: %s"
                             % (", ".join(sorted(unknown)), ", ".join(GRAMMAR)))
    out = ["---"]
    for key in GRAMMAR:
        if key not in fields or fields[key] is None:
            continue
        value = str(fields[key]).strip()
        if "\n" in value or "\r" in value:
            raise IssueBodyError("value for %r spans lines — the grammar has no multi-line values"
                                 % key)
        if value == "":
            continue
        out.append("%s: %s" % (key, value))
    out.append("---")
    return "\n".join(out)


def upsert_block(body, fields):
    """`body` with `fields` merged into its machine block — the block replaced in place when one
    exists, otherwise a new one inserted at the top. Everything outside the block's own lines is
    byte-identical. A field whose value is None REMOVES that key."""
    body = body or ""
    span = block_span(body)
    merged = {}
    if span is not None:
        merged.update(parse_block(body))
    for key, value in fields.items():
        if key not in GRAMMAR:
            raise IssueBodyError("cannot set unknown key %r — the grammar is exactly: %s"
                                 % (key, ", ".join(GRAMMAR)))
        if value is None:
            merged.pop(key, None)
        else:
            merged[key] = str(value).strip()
    block = render_block(merged)
    if span is None:
        return block + "\n" + body
    lines = body.split("\n")
    first, last = span
    return "\n".join(lines[:first] + block.split("\n") + lines[last + 1:])


# ── the read API ────────────────────────────────────────────────────────────────────────────────

def get(body, key, ref="-", variant=None):
    """The value for `key`: the machine block's if it carries one, else the legacy line-anchored
    form (which prints one `LEGACY-GRAMMAR <key> <ref>` line to stderr — the migration meter).
    None when neither is present."""
    if key not in GRAMMAR:
        raise IssueBodyError("unknown key %r — the grammar is exactly: %s"
                             % (key, ", ".join(GRAMMAR)))
    block = parse_block(body)
    if key in block:
        return block[key]
    value = _legacy_read(body or "", key, variant)
    if value is not None:
        _report_legacy(key, ref)
    return value


def parse(body, ref="-", variant=None):
    """Every grammar key present in `body`, block ∪ legacy, values as strings. One
    `LEGACY-GRAMMAR` line per key that came from a legacy form."""
    block = parse_block(body)
    out = {}
    for key in GRAMMAR:
        if key in block:
            out[key] = block[key]
            continue
        value = _legacy_read(body or "", key, variant)
        if value is not None:
            _report_legacy(key, ref)
            out[key] = value
    return out


def touches(body, ref="-", variant=None):
    """The declared footprint as a list — the ONE place a comma-separated grammar value is split
    (ADR-097). Empty list when no `Touches:` is declared, which the scan reads as EXCLUSIVE."""
    raw = get(body, "Touches", ref=ref, variant=variant) or ""
    return [p.strip() for p in raw.split(",") if p.strip()]


# ── CLI ─────────────────────────────────────────────────────────────────────────────────────────

USAGE = """usage: issue_body.py get <key> [--ref R] [--legacy V] < body
       issue_body.py json [--ref R] [--legacy V] < body
       issue_body.py set <key>=<value> [...] < body
       issue_body.py --self-test"""


def _main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        sys.stderr.write(USAGE + "\n")
        return 2
    if argv[0] == "--self-test":
        return _self_test()

    cmd, rest = argv[0], list(argv[1:])
    ref, variant, positional = "-", None, []
    while rest:
        arg = rest.pop(0)
        if arg == "--ref":
            ref = rest.pop(0) if rest else "-"
        elif arg.startswith("--ref="):
            ref = arg.split("=", 1)[1]
        elif arg == "--legacy":
            variant = rest.pop(0) if rest else None
        elif arg.startswith("--legacy="):
            variant = arg.split("=", 1)[1]
        else:
            positional.append(arg)

    body = sys.stdin.read()
    try:
        if cmd == "get":
            if len(positional) != 1:
                sys.stderr.write(USAGE + "\n")
                return 2
            value = get(body, positional[0], ref=ref, variant=variant)
            if value is not None:
                sys.stdout.write(value + "\n")
            return 0
        if cmd == "json":
            sys.stdout.write(json.dumps(parse(body, ref=ref, variant=variant),
                                        sort_keys=True) + "\n")
            return 0
        if cmd == "set":
            if not positional:
                sys.stderr.write(USAGE + "\n")
                return 2
            fields = {}
            for item in positional:
                if "=" not in item:
                    sys.stderr.write("issue_body: `set` takes <key>=<value>, got %r\n" % item)
                    return 2
                key, value = item.split("=", 1)
                fields[key] = value
            sys.stdout.write(upsert_block(body, fields))
            return 0
    except IssueBodyError as exc:
        sys.stderr.write("issue_body: %s\n" % exc)
        return 2
    sys.stderr.write(USAGE + "\n")
    return 2


# ── self-test ───────────────────────────────────────────────────────────────────────────────────
# EVERY expectation below is derived in its comment FROM the contract source cited there — the
# grammar in this module's docstring, or the shell reader the legacy form restates. None is
# derived by running the code (an expectation read back off the implementation pins its bugs).

def _self_test():
    import io

    fails = []
    checked = [0]

    def check(label, got, want):
        checked[0] += 1
        if got == want:
            sys.stdout.write("  ✓ %s\n" % label)
        else:
            fails.append(label)
            sys.stdout.write("  ✗ %s\n      got:  %r\n      want: %r\n" % (label, got, want))

    def raises(label, fn, needle):
        checked[0] += 1
        try:
            fn()
        except IssueBodyError as exc:
            if needle in str(exc):
                sys.stdout.write("  ✓ %s\n" % label)
            else:
                fails.append(label)
                sys.stdout.write("  ✗ %s — raised, but not for the declared reason\n"
                                 "      got:  %s\n      want substring: %r\n" % (label, exc, needle))
        else:
            fails.append(label)
            sys.stdout.write("  ✗ %s — no IssueBodyError raised (a malformed block went silent)\n"
                             % label)

    def quiet(fn):
        """Run fn with stderr captured — returns (value, stderr-text). The LEGACY-GRAMMAR meter
        writes to stderr, so tests that are not ABOUT the meter must not spray it."""
        saved = sys.stderr
        sys.stderr = io.StringIO()
        try:
            return fn(), sys.stderr.getvalue()
        finally:
            sys.stderr = saved

    sys.stdout.write("issue_body self-test\n")

    # ── the block ────────────────────────────────────────────────────────────────────────────
    # Expectation source: the module docstring's grammar. Every key is spelled exactly as in
    # GRAMMAR; the value is the remainder of the line with trailing whitespace trimmed.
    full = "\n".join([
        "---",
        "Touches: agents/foo.sh, docs/bar.md",
        "Base: goal/12-slug",
        "Budget: 30",
        "Verdict-authority: human",
        "Production-leg: the dashboard shows the row",
        "Revert: revert the pin bump",
        "Origin: homelab#1302",
        "Size: 2 sessions",
        "Capability: object storage",
        "alert-fp: r1",
        "self-referential: false",
        "fix-verdict: report-only",
        "Class: build",
        "---",
        "",
        "## Why",
        "prose",
    ])
    got, err = quiet(lambda: parse_block(full))
    check("block: every grammar key parses", got, {
        "Touches": "agents/foo.sh, docs/bar.md",
        "Base": "goal/12-slug",
        "Budget": "30",
        "Verdict-authority": "human",
        "Production-leg": "the dashboard shows the row",
        "Revert": "revert the pin bump",
        "Origin": "homelab#1302",
        "Size": "2 sessions",
        "Capability": "object storage",
        "alert-fp": "r1",
        "self-referential": "false",
        "fix-verdict": "report-only",
        "Class": "build",
    })
    check("block: no LEGACY-GRAMMAR line when the block carries the key",
          quiet(lambda: get(full, "Base", ref="homelab#1"))[1], "")
    # Trailing whitespace is trimmed (the shell readers all end in an `s/[[:space:]]+$//`).
    check("block: trailing whitespace on a value is trimmed",
          parse_block("---\nBase: goal/9-x   \n---\n"), {"Base": "goal/9-x"})
    # Blank lines are the ONE skip (fixture.yaml's `/^[[:space:]]*$/ { next }`). Its `#`-comment
    # skip is deliberately NOT inherited: `### Touches:` is a real authoring mistake (the scan's
    # TOUCHES-MALFORMED probe, coordinator-scan.sh:1849, exists because authors write it), and a
    # grammar that skips `#` lines would swallow it silently — the exact failure this module ends.
    check("block: blank lines are skipped",
          parse_block("---\n\nBudget: 5\n---\n"), {"Budget": "5"})
    # No block at all is LEGAL and yields {} from the block (docstring: "A body with NO block is
    # legal"). This body has no leading `---`.
    check("block: a body with no block parses to {}", parse_block("## Why\nprose\n"), {})
    check("block: an empty body parses to {}", parse_block(""), {})
    # A fence that opens below prose is not a machine block: the block is at the TOP.
    check("block: `---` below prose is not the machine block (setext/hrule)",
          parse_block("Heading\n---\nBase: x\n---\n"), {})
    # Leading blank lines before the fence are tolerated — "at the TOP" means first CONTENT.
    check("block: leading blank lines still count as the top",
          parse_block("\n\n---\nBudget: 7\n---\n"), {"Budget": "7"})
    # CRLF: GitHub's web UI submits bodies with \r\n. The fence, the values and the blank-line
    # skip must all survive it — otherwise the block is invisible on exactly the bodies a human
    # typed, and its refusals never fire.
    check("block: a CRLF body parses (the web UI's line endings)",
          parse_block("---\r\nBudget: 30\r\nBase: goal/9-x\r\n\r\n---\r\n\r\n## Why\r\n"),
          {"Budget": "30", "Base": "goal/9-x"})
    raises("refusal: an unknown key in a CRLF block is still loud",
           lambda: parse_block("---\r\nNope: 1\r\n---\r\n"), "unknown key")

    # ── loud refusals ────────────────────────────────────────────────────────────────────────
    # Contract: "an unknown key, a nested/bulleted line, a duplicate key is a LOUD parse error,
    # never a silent skip".
    raises("refusal: unknown key", lambda: parse_block("---\nTouchez: x\n---\n"), "unknown key")
    raises("refusal: nested/indented line",
           lambda: parse_block("---\nTouches: a\n  Base: b\n---\n"), "indented")
    raises("refusal: bulleted line",
           lambda: parse_block("---\n- Touches: a\n---\n"), "not a `key: value` line")
    raises("refusal: heading line inside the fences",
           lambda: parse_block("---\n### Touches: a\n---\n"), "not a `key: value` line")
    raises("refusal: prose line inside the fences",
           lambda: parse_block("---\nBase: x\nthis is prose\n---\n"), "not a `key: value` line")
    raises("refusal: duplicate key",
           lambda: parse_block("---\nBudget: 5\nBudget: 6\n---\n"), "duplicate key")
    raises("refusal: unterminated fence",
           lambda: parse_block("---\nBudget: 5\nprose and no closing fence\n"), "never closed")
    # Case matters: the grammar names are exact (docstring: "case-SENSITIVE and exact").
    raises("refusal: wrong case is not the grammar key",
           lambda: parse_block("---\ntouches: a\n---\n"), "unknown key")

    # ── the legacy forms, one per live reader ────────────────────────────────────────────────
    # Each expectation is derived from the cited shell reader, NOT from this module.

    # agents/coordinator-scan.sh:1393 — `scan("(?mi)^[ \t]*touches:[ \t]*(.+)$")` unioned with
    # ",". Case-insensitive, leading whitespace allowed, EVERY line contributes.
    body = "prose\n  touches: a/**\nmore\nTouches: b.md, c.md\n"
    got, err = quiet(lambda: get(body, "Touches", ref="homelab#1302"))
    check("legacy Touches: case-insensitive union of every matching line", got, "a/**,b.md, c.md")
    check("legacy Touches: prints the meter once", err, "LEGACY-GRAMMAR Touches homelab#1302\n")
    # Same regex requires `(.+)` — an empty value is NOT a declaration.
    check("legacy Touches: an empty value is not a declaration",
          quiet(lambda: get("Touches:\n", "Touches"))[0], None)
    # The malformed forms the scan's TOUCHES-MALFORMED probe exists for (scan:1849) must stay
    # unparsed here too — guessing a footprint is worse than exclusive.
    check("legacy Touches: `**Touches:**` stays unparsed (scan:1849 strictness)",
          quiet(lambda: get("**Touches:** a/**\n", "Touches"))[0], None)
    check("legacy Touches: `- Touches:` stays unparsed",
          quiet(lambda: get("- Touches: a/**\n", "Touches"))[0], None)
    check("legacy Touches: `### Touches:` stays unparsed",
          quiet(lambda: get("### Touches: a/**\n", "Touches"))[0], None)
    # touches() is the ONE splitter: split on ",", strip, drop empties.
    check("touches(): splits, strips and drops empties",
          quiet(lambda: touches("Touches: a/** , b.md,,  c/\n"))[0], ["a/**", "b.md", "c/"])
    check("touches(): no line ⇒ [] (the scan reads that as EXCLUSIVE)",
          quiet(lambda: touches("## Why\n"))[0], [])

    # agents/coordinator-scan.sh:1084 — `grep -qiP '^[ \t]*base:[ \t]*.+'`.
    check("legacy Base: case-insensitive, leading whitespace allowed",
          quiet(lambda: get("\t base: goal/12-x\n", "Base"))[0], "goal/12-x")
    check("legacy Base: an empty value does not satisfy the `.+`",
          quiet(lambda: get("Base:\n", "Base"))[0], None)

    # agents/goal-budget.sh:86 gb_budget_line — column 0 only, `[Bb]udget:`, first line wins,
    # leading non-digits stripped, all whitespace deleted, must end up a bare number.
    check("legacy Budget: a bare number", quiet(lambda: get("Budget: 30\n", "Budget"))[0], "30")
    check("legacy Budget: lowercase `budget:` is read", quiet(lambda: get("budget: 12.5\n", "Budget"))[0], "12.5")
    check("legacy Budget: `$` is stripped and the number read as USD",
          quiet(lambda: get("Budget: $16\n", "Budget"))[0], "16")
    check("legacy Budget: INDENTED lines are NOT read (column 0 only — the money gate stays narrow)",
          quiet(lambda: get("  Budget: 30\n", "Budget"))[0], None)
    check("legacy Budget: `BUDGET:` is not one of the two spellings sed matches",
          quiet(lambda: get("BUDGET: 30\n", "Budget"))[0], None)
    check("legacy Budget: a non-numeric first line yields nothing (head -1 precedes the grep)",
          quiet(lambda: get("Budget: twelve\nBudget: 12\n", "Budget"))[0], None)

    # agents/coordinator-scan.sh:2350 — awk: first match, all spaces/tabs/CRs deleted, lowered.
    check("legacy Verdict-authority: lowercased and space-stripped",
          quiet(lambda: get("Verdict-authority:  Human \n", "Verdict-authority"))[0], "human")
    check("legacy Verdict-authority: the awk's /[Vv]/ class covers the lowercase spelling",
          quiet(lambda: get("verdict-authority: kpi\n", "Verdict-authority"))[0], "kpi")

    # agents/coordinator-scan.sh:2445 — awk, trailing trim only, value kept verbatim.
    check("legacy Revert: trailing whitespace trimmed, case of the value preserved",
          quiet(lambda: get("Revert: PR#1400 pin rollback   \n", "Revert"))[0], "PR#1400 pin rollback")

    # scripts/goal-lint.sh:37 line() — the only Production-leg reader.
    check("legacy Production-leg: read", quiet(lambda: get("Production-leg: the graph\n", "Production-leg"))[0],
          "the graph")

    # agents/board.sh:230 — `(?im)^Capability:[ \t]+(?<cap>[^\n]+)`: column 0, ≥1 space/tab.
    check("legacy Capability: read", quiet(lambda: get("Capability: object storage\n", "Capability"))[0],
          "object storage")
    check("legacy Capability: no space after the colon does not match the `[ \\t]+`",
          quiet(lambda: get("Capability:objectstorage\n", "Capability"))[0], None)
    check("legacy Capability: an indented line does not match (board's regex has no `[ \\t]*` prefix)",
          quiet(lambda: get("  Capability: object storage\n", "Capability"))[0], None)

    # agents/reviewer-session.sh:332 `grep -qE '^alert-fp:'` — the value may be glued to the colon
    # (responder-behaviour-test.sh:376 writes `alert-fp:r1`).
    check("legacy alert-fp: value glued to the colon",
          quiet(lambda: get("alert-fp:r1\n", "alert-fp"))[0], "r1")

    # responder lane: `grep -q '^fix-verdict:'` (responder-behaviour-test.sh:385).
    check("legacy fix-verdict: read", quiet(lambda: get("fix-verdict: report-only\n", "fix-verdict"))[0],
          "report-only")

    # fix-debounce-argo.yaml:286 — a bare `contains("self-referential: true")` SUBSTRING test.
    check("legacy self-referential: the substring marker",
          quiet(lambda: get("blah self-referential: true blah\n", "self-referential"))[0], "true")
    check("legacy self-referential: `false` is not the marker",
          quiet(lambda: get("self-referential: false\n", "self-referential"))[0], None)

    # Class/Origin/Size are block-only — no reader exists, so no legacy form may be invented.
    check("Class has no legacy body form (it maps from the task/* LABEL)",
          quiet(lambda: get("Class: build\n", "Class"))[0], None)
    check("Origin has no legacy body form", quiet(lambda: get("Origin: homelab#1\n", "Origin"))[0], None)
    check("Size has no legacy body form", quiet(lambda: get("Size: 3 sessions\n", "Size"))[0], None)

    # ── precedence + the meter ───────────────────────────────────────────────────────────────
    mixed = "---\nBase: goal/12-block\n---\n\nBase: goal/12-legacy\nBudget: 30\n"
    got, err = quiet(lambda: get(mixed, "Base", ref="homelab#1302"))
    check("precedence: the block wins over a legacy line", got, "goal/12-block")
    check("precedence: no meter line when the block answered", err, "")
    got, err = quiet(lambda: get(mixed, "Budget", ref="homelab#1302"))
    check("precedence: a key absent from the block falls through to legacy", got, "30")
    check("meter: LEGACY-GRAMMAR <key> <ref> on the fall-through",
          err, "LEGACY-GRAMMAR Budget homelab#1302\n")
    check("meter: an empty ref renders as `-`",
          quiet(lambda: get("Budget: 30\n", "Budget", ref=""))[1], "LEGACY-GRAMMAR Budget -\n")
    got, err = quiet(lambda: parse(mixed, ref="homelab#1302"))
    check("parse(): block ∪ legacy", got, {"Base": "goal/12-block", "Budget": "30"})
    check("parse(): one meter line per legacy key", err, "LEGACY-GRAMMAR Budget homelab#1302\n")

    # ── the goal-lint variant ────────────────────────────────────────────────────────────────
    # scripts/goal-lint.sh line(): `^[[:space:]]*<Key>:[[:space:]]*`, case-sensitive, first match,
    # trailing trim, NO normalization. Two documented divergences from the canonical readers:
    check("variant goal-lint: an INDENTED Budget is read (line() allows leading whitespace)",
          quiet(lambda: get("  Budget: 30\n", "Budget", variant="goal-lint"))[0], "30")
    check("variant goal-lint: `$16` is NOT stripped (line() does no currency normalization — "
          "goal-lint's own FAIL message owns that)",
          quiet(lambda: get("Budget: $16\n", "Budget", variant="goal-lint"))[0], "$16")
    check("variant goal-lint: Verdict-authority is NOT lowercased",
          quiet(lambda: get("Verdict-authority: Human\n", "Verdict-authority",
                            variant="goal-lint"))[0], "Human")
    check("variant goal-lint: lowercase `base:` is NOT matched (line() is case-sensitive)",
          quiet(lambda: get("base: goal/12-x\n", "Base", variant="goal-lint"))[0], None)
    check("variant goal-lint: a bare key with no value yields nothing (goal-lint tests `-n` on "
          "the result, so absent and empty are the same verdict there)",
          quiet(lambda: get("Production-leg:\n", "Production-leg", variant="goal-lint"))[0], None)
    check("variant goal-lint: the block still wins",
          quiet(lambda: get("---\nBudget: 9\n---\n  Budget: 30\n", "Budget",
                            variant="goal-lint"))[0], "9")

    # ── render_block / upsert_block ──────────────────────────────────────────────────────────
    # Render order is GRAMMAR order (docstring), regardless of the dict's insertion order.
    check("render_block: GRAMMAR order, fenced, no trailing newline",
          render_block({"Class": "build", "Touches": "a.sh", "Budget": "30"}),
          "---\nTouches: a.sh\nBudget: 30\nClass: build\n---")
    check("render_block: an empty value is omitted rather than written as a bare key",
          render_block({"Base": "", "Budget": "30"}), "---\nBudget: 30\n---")
    raises("render_block: refuses an unknown key", lambda: render_block({"Nope": "x"}),
           "unknown key")
    raises("render_block: refuses a multi-line value",
           lambda: render_block({"Revert": "a\nb"}), "spans lines")
    # Round-trip: what render writes, parse_block reads back identically.
    fields = {"Touches": "agents/foo.sh, docs/bar.md", "Base": "goal/12-slug", "Budget": "30",
              "Class": "build"}
    check("round-trip: parse_block(render_block(f)) == f", parse_block(render_block(fields)), fields)

    # upsert on a body with NO block: the block is prepended, the body byte-identical after it.
    plain = "## Why\n\nprose\n\nTouches: legacy.sh\n"
    out = upsert_block(plain, {"Base": "goal/9-x"})
    check("upsert_block: inserts at the top of a blockless body",
          out, "---\nBase: goal/9-x\n---\n" + plain)
    check("upsert_block: the rest of a blockless body is byte-identical",
          out[len("---\nBase: goal/9-x\n---\n"):], plain)
    check("upsert_block: a legacy line for the written key is LEFT IN PLACE (1b removes them)",
          "Touches: legacy.sh" in out, True)

    # upsert on a body WITH a block: merge, replace in place, rest untouched.
    withblock = "---\nBudget: 30\nClass: fix\n---\n\n## Why\n\nprose\n"
    out = upsert_block(withblock, {"Base": "goal/9-x", "Class": "build"})
    check("upsert_block: merges into an existing block, in GRAMMAR order",
          out, "---\nBase: goal/9-x\nBudget: 30\nClass: build\n---\n\n## Why\n\nprose\n")
    check("upsert_block: the body after the block is byte-identical",
          out.split("---\n", 2)[2], "\n## Why\n\nprose\n")
    check("upsert_block: None removes a key",
          upsert_block(withblock, {"Budget": None}), "---\nClass: fix\n---\n\n## Why\n\nprose\n")
    raises("upsert_block: refuses an unknown key", lambda: upsert_block("x", {"Nope": "1"}),
           "unknown key")

    # `--legacy agent-session` restates the launcher's `Base:` read (issue_body.py's VARIANTS
    # comment cites agent-session.sh:791: `sed -n 's/^[Bb]ase:...//p' | head -1 | tr -d
    # '[:space:]'`). Derived from that pipeline, NOT from running it:
    #   "  Base: goal/9-x"      → the sed anchor is `^[Bb]ase:` at column 0, so an INDENTED line
    #                             does not match at all ⇒ nothing (the canonical reader, which
    #                             allows leading whitespace, DOES match it — that is the divergence).
    #   "BASE: goal/9-x"        → `[Bb]ase` matches only `Base`/`base` ⇒ nothing.
    #   "Base: goal /9 x"       → `tr -d '[:space:]'` deletes every space ⇒ "goal/9x".
    check("legacy agent-session: an indented Base: is invisible to the launcher's reader",
          get("  Base: goal/9-x", "Base", variant="agent-session"), None)
    check("legacy agent-session: BASE: is invisible to the launcher's reader",
          get("BASE: goal/9-x", "Base", variant="agent-session"), None)
    check("legacy agent-session: the value has every space DELETED, not trimmed",
          get("Base: goal /9 x", "Base", variant="agent-session"), "goal/9x")
    # the canonical reader (coordinator-scan.sh:1084) is the one that differs — pinned so the
    # divergence itself is a checked fact, not a comment.
    check("legacy default: the canonical Base: reader DOES see an indented line",
          get("  Base: goal/9-x", "Base"), "goal/9-x")
    # the block wins over both, and a block value is never whitespace-squashed.
    check("block Base beats the agent-session legacy form",
          get("---\nBase: goal/9-x\n---\nBase: goal/other", "Base", variant="agent-session"),
          "goal/9-x")

    sys.stdout.write("issue_body self-test: %d checks, %d failed\n" % (checked[0], len(fails)))
    if fails:
        for label in fails:
            sys.stdout.write("  FAILED: %s\n" % label)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
