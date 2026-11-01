#!/usr/bin/env python3
"""epic_dispositions — the ADR-122 (4) TREE-MEMBER DISPOSITION STORE, one typed machine
comment per epic CONTAINER issue (a Goal or a stint parent).

THE ONE HOME of the store format. The scan's goal lane, `scripts/goal-lint.sh` and
`agents/board.sh` read through the CLI; the Goal `goal-checkpoint` play, the stint closeout
act and the scan's post-launch-bucket create write through it. Nothing else parses the shape.

    python3 agents/epic_dispositions.py read <owner/repo> <container-n>
    python3 agents/epic_dispositions.py set  <owner/repo> <container-n> <member-n | repo#n> \
        adopted|deferred --by checkpoint|closeout|bucket
    python3 agents/epic_dispositions.py list <owner/repo> <container-n>
    python3 agents/epic_dispositions.py --self-test

Shape (a single issue comment, edited in place — the findings-store shape one level up;
ADR-103: ONE machine comment per store, no per-event timeline residue):

    <!-- epic-dispositions v1 -->
    #1315 deferred 2026-09-05T12:00:00Z by=checkpoint
    #1163 adopted 2026-09-05T12:00:00Z by=checkpoint

A member with NO row is `undispositioned` — the absence IS the state, so the store never
carries a row saying so. Binding is dumb, disposition is the container's
(docs/agents/issue-authoring.md §The lineage contract, rule 9).

WHY PYTHON, WHY A MODULE. ADR-113: logic is Python from birth. Stdlib only (no `yaml`, no
`requests` — the jail python3 has neither), `gh` reached through `subprocess` the way the
repo's other Python does, so the replay harness's PATH-shim `gh` serves it unchanged. The
comments GET is `--paginate --slurp`, never bare `--paginate` — see `_parse_paginated_list`
for why the bare form breaks on exactly the containers that matter most.

WHY A BARE MEMBER IS THE CONTAINER'S REPO ONLY (homelab#2589). A store row's key is read
against the CONTAINER's repo: the scan matches `repo#number` for every member and the BARE
number only for the container's own (the `$bk` clause, FIX #1451). So a bare row for a
cross-repo member is a row NOBODY reads — the member keeps reading `undispositioned`, trigger
(c) re-fires every tick, and the ADOPTED-OPEN completion predicate undercounts it. Measured
on Goal #1640 (2026-09-16): rows `#134/#136/#138/#139` for agent-runtime members. So `set`
RESOLVES a bare member against the container's native sub-issue TREE before it writes, and
refuses (loud, rule #6) a bare member that is not the container's own-repo member — naming
the qualified form to write instead. A QUALIFIED member (`repo#n`) is taken as the caller
wrote it: the caller named the repo, so there is nothing to resolve (FIX #1451).

FAIL-CLOSED EVERYWHERE (rule #6: never fail INTO a write). The comments read has THREE
outcomes, not two — found / confirmed-absent / UNREADABLE — and the split is load-bearing for
exactly the reason `agents/goal-findings.sh` documents it: a writer that treats a blind read
as "absent" CREATES a second store comment on a transient API failure, breaking the
one-machine-comment invariant this file exists to hold. `read` exits 2 with NOTHING on stdout
on unreadable (callers hold); `set` refuses outright. The MEMBERSHIP read has the same
three-way split: a bare member whose tree cannot be read is refused, never written.

Exit codes:
    0  ok
    1  refused — a bad disposition word, a bad `by` value, a malformed argument, or a bare
       member that is not the container's own-repo member
    2  PROBE-FAIL — the container's comments or its membership are unreadable (nothing on stdout)
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime, timezone

MARK = "<!-- epic-dispositions v1 -->"

# The closed vocabularies. A disposition word outside this set is a REFUSAL, never a stored
# string: every reader switches on these three states and an unknown fourth would read as
# "undispositioned" at some readers and as "present" at others — the drift ADR-122 exists to
# subtract. `undispositioned` is deliberately NOT writable: it is the absence of a row.
DISPOSITIONS = ("adopted", "deferred")
# Who ruled it. `checkpoint` = the Goal goal-checkpoint play, `closeout` = the jail stint
# closeout act, `bucket` = the scan's deterministic post-launch-bucket create (IL-T17).
BY_VALUES = ("checkpoint", "closeout", "bucket")

# FIX #1451: accept both bare issue numbers (#1234) and qualified cross-repo keys (#repo#1234)
# The member's OWN shape — ONE regex, used by the row parser and by the writer's membership
# test, so the two can never drift. The qualifier is a REPO NAME ("agent-runtime#134"): the
# key grammar has no room for an owner, and every reader resolves the qualifier the same way
# (the repo's short name — the scan's `.repo`).
_MEMBER_RE = re.compile(r"(?:[a-z][a-z0-9-]*#)?[0-9]+")
_ROW_RE = re.compile(
    r"^#(?P<member>" + _MEMBER_RE.pattern + r")[ \t]+(?P<disposition>[a-z]+)"
    r"[ \t]+(?P<at>\S+)[ \t]+by=(?P<by>[a-z]+)[ \t]*$"
)


class Unreadable(Exception):
    """The container's comments could not be read — PROBE-FAIL, never 'absent'."""


class Refused(Exception):
    """The caller asked for something outside the store's vocabulary."""


# ── the shape: parse / serialize / upsert (pure — no I/O, the whole self-test surface) ────────

def parse(body: str) -> "dict[str, dict]":
    """Store body → {"<member>": {"disposition":…, "at":…, "by":…}}, insertion-ordered.

    A malformed row is LOUD on stderr and excluded — never a silent skip (ADR-122's own rule
    for the machine block, applied to the store one level down). It is not fatal: the rows are
    machine-written, so one bad line must not wedge every other member's disposition.
    """
    rows: "dict[str, dict]" = {}
    for line in body.splitlines():
        line = line.rstrip("\r")
        if not line.strip() or line.strip() == MARK:
            continue
        m = _ROW_RE.match(line.strip())
        if not m or m.group("disposition") not in DISPOSITIONS or m.group("by") not in BY_VALUES:
            print(f"epic-dispositions: MALFORMED-ROW (excluded): {line!r}", file=sys.stderr)
            continue
        rows[m.group("member")] = {
            "disposition": m.group("disposition"),
            "at": m.group("at"),
            "by": m.group("by"),
        }
    return rows


def serialize(rows: "dict[str, dict]") -> str:
    """{member: {...}} → the full comment body, marker first. The inverse of parse()."""
    out = [MARK]
    for member, r in rows.items():
        out.append(f"#{member} {r['disposition']} {r['at']} by={r['by']}")
    return "\n".join(out) + "\n"


def upsert(body: str, member: str, disposition: str, at: str, by: str) -> str:
    """Body in, body out — REPLACE an existing row for `member`, else append one.

    Replace-in-place (not append-and-shadow) is what keeps the store a SET of members rather
    than a timeline: a re-ruled member has one row, and every reader can key on member number
    without caring about order. The container may re-rule as often as it likes.

    FIX #1451: member can now be a bare issue number (e.g., "1234") or a qualified key for
    cross-repo members (e.g., "repo#1234" where repo is a valid repo name).
    """
    if disposition not in DISPOSITIONS:
        raise Refused(
            f"disposition {disposition!r} is not one of {'/'.join(DISPOSITIONS)} "
            "(`undispositioned` is the ABSENCE of a row — it is never written)")
    if by not in BY_VALUES:
        raise Refused(f"by={by!r} is not one of {'/'.join(BY_VALUES)}")
    # FIX #1451: accept both bare issue numbers and qualified keys (repo#number)
    if not _MEMBER_RE.fullmatch(str(member)):
        raise Refused(f"member {member!r} is not a valid issue number or qualified key (repo#number)")
    rows = parse(body)
    rows[str(member)] = {"disposition": disposition, "at": at, "by": by}
    return serialize(rows)


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ── the seam: the comments fetch (monkeypatched by the self-test; PATH-shimmed by replay) ────

def _parse_paginated_list(stdout: str) -> list:
    """THE one parse of a `gh api --paginate --slurp` JSON LIST payload → a flat list.

    Serves BOTH reads this module makes — the container's comments and its sub-issue tree —
    because the two payloads have the same shape (a JSON array of objects), so one parser
    keeps one contract.

    ⚠ `--paginate` ALONE is a trap and it bites exactly the containers this store exists for.
    Per `gh help api`, plain `--paginate` writes each page's JSON document back-to-back, so a
    container with more than 100 comments yields `[...][...]` — not one JSON document, so
    `json.loads` raises and the read reports UNREADABLE forever: trigger (c) held and every
    `set` refused, on precisely the goals whose trees grew large enough to need disposing.
    `--slurp` is the documented fix: gh "wraps the pages in an outer JSON array", giving
    `[[<page 1>], [<page 2>], …]`. So the payload is flattened ONE level when every element is
    itself a list. A single recorded page (`[{…}, {…}]`, the shape the replay worlds hold) has
    dict elements and passes through untouched, which is what lets one parser serve both.
    """
    try:
        data = json.loads(stdout or "null")
    except ValueError:
        raise Unreadable("comments payload is not JSON (a 200 that is not JSON is the "
                         "`garbage` shape — never parse it as empty)")
    if not isinstance(data, list):
        raise Unreadable(f"comments payload is {type(data).__name__}, not a list")
    if data and all(isinstance(page, list) for page in data):
        return [c for page in data for c in page]
    return data


def _gh_comments_raw(slug: str, issue: int) -> str:
    """The subprocess seam: one paginated GET, raw stdout. Raises Unreadable on ANY doubt.

    May be overridden by EPIC_DISPOSITIONS_COMMENTS env var (the goal lane folds two reads
    into one; it passes pre-fetched comments to avoid duplicate API calls, FU-084 / #1439).
    The value `-` means "the payload is on STDIN" — the form the scan uses, because an env var
    is ONE execve argument and Linux caps a single argument at 128 KiB (MAX_ARG_STRLEN):
    Goal #1640's timeline reached 175 KB on 2026-09-22 and every env-var read died E2BIG
    before Python started, which the scan could only report as "dispositions unreadable".
    """
    import os
    import sys
    cached = os.environ.get("EPIC_DISPOSITIONS_COMMENTS", "")
    if cached == "-":
        return sys.stdin.read()
    if cached:
        return cached
    try:
        p = subprocess.run(
            ["gh", "api", f"repos/{slug}/issues/{issue}/comments?per_page=100",
             "--paginate", "--slurp"],
            capture_output=True, text=True)
    except OSError as e:                        # gh absent from PATH — a probe failure, not "absent"
        raise Unreadable(f"gh could not be executed: {e}")
    if p.returncode != 0:
        raise Unreadable(f"gh api exited {p.returncode}: {p.stderr.strip()[:200]}")
    return p.stdout


def _fetch_comments(slug: str, issue: int) -> list:
    """One GET of the container's comments, flattened. Raises Unreadable on ANY doubt."""
    return _parse_paginated_list(_gh_comments_raw(slug, issue))


def find(slug: str, issue: int) -> "tuple[int | None, str]":
    """→ (comment_id, body). (None, "") = read OK, store CONFIRMED absent. Raises Unreadable.

    The three-way split, not a two-way one: see the module docstring. A caller that collapses
    absent and unreadable is a caller that will one day mint a second store comment.
    """
    for c in _fetch_comments(slug, issue):
        if isinstance(c, dict) and str(c.get("body") or "").startswith(MARK):
            return c.get("id"), str(c.get("body") or "")
    return None, ""


def _put(slug: str, issue: int, comment_id: "int | None", body: str) -> None:
    if comment_id is not None:
        args = ["gh", "api", "-X", "PATCH", f"repos/{slug}/issues/comments/{comment_id}",
                "-f", f"body={body}"]
    else:
        args = ["gh", "api", "-X", "POST", f"repos/{slug}/issues/{issue}/comments",
                "-f", f"body={body}"]
    p = subprocess.run(args, capture_output=True, text=True)
    if p.returncode != 0:
        raise Unreadable(f"store write refused (gh exited {p.returncode}): {p.stderr.strip()[:200]}")


# ── the seam: the MEMBERSHIP read (the container's native sub-issue TREE) ───────────────────────

# WHY THE WRITER READS THE TREE. A store row's key is read against the CONTAINER's repo: the
# scan matches `repo#number` for every member and the BARE number only for the container's own
# (the `$bk` clause, FIX #1451). A bare row for a cross-repo member is therefore a row NOBODY
# reads — the member keeps reading `undispositioned`, trigger (c) re-fires every tick, and the
# ADOPTED-OPEN completion predicate undercounts it (Goal #1640, 2026-09-16: rows
# `#134/#136/#138/#139` for agent-runtime members; homelab#2589).

# The walk depth — the SAME bound as the budget walk (agents/goal-budget.sh): a member can sit
# at depth 2 (a minted child is bound to its finding's ORIGIN issue, ADR-106 (2), not to the
# goal), and Goal #1640's cross-repo members sat at depths 1–4. A direct-children read would
# call a legitimate member "not a member" and refuse a legitimate ruling.
MEMBER_WALK_DEPTH = 6


def _gh_subissues_raw(slug: str, issue: int) -> str:
    """The subprocess seam: one paginated GET of a node's native sub-issues.

    `--paginate --slurp`, never bare `--paginate` — the same trap as the comments read, and
    the same fix (see `_parse_paginated_list`).
    """
    try:
        p = subprocess.run(
            ["gh", "api", f"repos/{slug}/issues/{issue}/sub_issues?per_page=100",
             "--paginate", "--slurp"],
            capture_output=True, text=True)
    except OSError as e:
        raise Unreadable(f"gh could not be executed: {e}")
    if p.returncode != 0:
        raise Unreadable(f"gh api exited {p.returncode}: {p.stderr.strip()[:200]}")
    return p.stdout


def _member_repo(item: dict) -> str:
    """The member's OWN repo ("owner/repo") — the field the cross-repo test turns on.

    `repository_url` is the issue object's own field, read the same way `agents/goal-budget.sh`
    reads it; the embedded `repository.full_name` is the fallback for a payload that carries
    only one of the two.
    """
    url = str(item.get("repository_url") or "")
    if "/repos/" in url:
        return url.split("/repos/", 1)[1].strip("/")
    repo = item.get("repository") or {}
    return str(repo.get("full_name") or "")


def _fetch_members(slug: str, issue: int, want: "int | None" = None) -> "set[tuple[str, int]]":
    """→ the container's whole TREE as {(owner/repo, number)}.

    Breadth-first over the container's NATIVE sub-issue edges — the same walk the budget gate
    does (agents/goal-budget.sh): the edges are repo-qualified, so a cross-repo member is a
    member exactly like an own-repo one and a bare number can never alias a foreign one.
    Cycle-safe by the seen-set, bounded at MEMBER_WALK_DEPTH.

    `want` (a member number) makes the walk STOP as soon as it finds that number in a FOREIGN
    repo: the cross-repo refusal is then already decided and the rest of the tree cannot change
    it. Without `want` the walk is complete.

    Raises Unreadable on ANY doubt: a half-read tree cannot say which repo a bare number lives
    in, and guessing is the defect this read exists to prevent (rule #6).
    """
    members: "set[tuple[str, int]]" = set()
    seen: "set[tuple[str, int]]" = set()
    frontier = [(slug, int(issue), 0)]
    while frontier:
        repo, num, depth = frontier.pop(0)
        if (repo, num) in seen:
            continue
        seen.add((repo, num))
        for child in _parse_paginated_list(_gh_subissues_raw(repo, num)):
            if not isinstance(child, dict):
                raise Unreadable(f"sub-issue payload under {repo}#{num} holds a non-object item")
            cnum = child.get("number")
            crepo = _member_repo(child)
            if not isinstance(cnum, int) or not crepo:
                raise Unreadable(
                    f"sub-issue payload under {repo}#{num} holds an item with no number/repo")
            members.add((crepo, cnum))
            if want is not None and cnum == want and crepo != slug:
                return members          # decisive: a foreign member with this number exists
            if depth < MEMBER_WALK_DEPTH:
                frontier.append((crepo, cnum, depth + 1))
    return members


# ── the importable API the CLI wraps ──────────────────────────────────────────────────────────

def read_store(slug: str, issue: int) -> "dict[str, dict]":
    _id, body = find(slug, issue)
    return parse(body) if body else {}


def resolve_member(slug: str, issue: int, member: str) -> str:
    """The key the store writes for `member` — a Refusal when a bare member is not the
    CONTAINER's own-repo member.

    A QUALIFIED member (`repo#n`) is taken as the caller wrote it: the caller named the repo,
    so there is nothing to resolve, and today's behaviour is kept (FIX #1451).

    A BARE member (`n`) is the container's own-repo member and nothing else, because that is
    the only member a bare row can ever mean. The tree read is fail-closed in BOTH directions
    (rule #6): a bare member that lives in another repo is refused with the qualified form to
    write instead, a bare member that is not in the tree at all is refused the same way, and
    an UNREADABLE tree is refused too — never a silent write on a half-read tree.
    """
    m = str(member)
    if not _MEMBER_RE.fullmatch(m):
        raise Refused(f"member {m!r} is not a valid issue number or qualified key (repo#number)")
    if "#" in m:
        return m                                     # qualified — the caller named the repo
    n = int(m)
    members = _fetch_members(slug, issue, want=n)   # Unreadable propagates → PROBE-FAIL, no write
    foreign = sorted(r for (r, num) in members if num == n and r != slug)
    if foreign:
        qual = f"{foreign[0].rsplit('/', 1)[-1]}#{n}"
        raise Refused(
            f"member {n} is a member of {foreign[0]}, not of {slug} — write it qualified as "
            f"{qual} (a bare number is the container's own repo only)")
    if (slug, n) not in members:
        raise Refused(
            f"member {n} is not a member of {slug}#{issue} — a bare number is the container's "
            f"own repo only; write a cross-repo member qualified as repo#{n}")
    return m


def set_disposition(slug: str, issue: int, member: str, disposition: str, by: str,
                    at: "str | None" = None) -> "dict[str, dict]":
    comment_id, body = find(slug, issue)          # Unreadable propagates — no blind create
    key = resolve_member(slug, issue, member)     # Refused / Unreadable — no write either way
    if not body:
        body = MARK + "\n"
    new = upsert(body, key, disposition, at or now_iso(), by)
    _put(slug, issue, comment_id, new)
    return parse(new)


# ── the self-test (the router-self-test pattern; `devbox run clause-replay` executes it) ─────

def self_test() -> int:
    """Pure-shape checks over FIXTURE STRINGS written here, plus the two refusal paths and the
    unreadable path driven through the real seams. Every expectation below is derived IN A
    COMMENT from the shape in the module docstring — never from running the code, which would
    pin this file's bugs instead of its contract."""
    global _gh_comments_raw, _gh_subissues_raw, _fetch_comments, _put
    n = 0

    def check(desc: str, got, want):
        nonlocal n
        assert got == want, f"{desc}\n  got:  {got!r}\n  want: {want!r}"
        n += 1
        print(f"  ✓ {desc}")

    # ── parse ── the docstring's own example, verbatim. Two rows ⇒ two keys; the marker line
    # and blank lines are not rows; each row's four fields split on whitespace as
    # `#<member> <disposition> <at> by=<by>`.
    body = (MARK + "\n"
            "#1315 deferred 2026-09-05T12:00:00Z by=checkpoint\n"
            "#1163 adopted 2026-09-05T12:00:00Z by=checkpoint\n")
    check("parse: two rows → two members",
          parse(body),
          {"1315": {"disposition": "deferred", "at": "2026-09-05T12:00:00Z", "by": "checkpoint"},
           "1163": {"disposition": "adopted", "at": "2026-09-05T12:00:00Z", "by": "checkpoint"}})
    # A member with no row is `undispositioned` — the absence IS the state, so a store that
    # holds only the marker parses to the EMPTY mapping (not to a mapping of nulls).
    check("parse: marker-only store → no members", parse(MARK + "\n"), {})
    check("parse: empty body → no members", parse(""), {})

    # ── serialize ── the inverse. Marker first, then one line per member in insertion order,
    # trailing newline — so serialize(parse(x)) == x for a well-formed x.
    check("serialize/parse round-trips the docstring shape", serialize(parse(body)), body)

    # ── upsert ── replace-in-place, never append-and-shadow. #1315 was `deferred by=checkpoint`
    # above; re-ruling it `adopted` must leave TWO members (not three) with #1315 first, because
    # replacement preserves the original insertion position.
    up = upsert(body, "1315", "adopted", "2026-09-06T08:00:00Z", "closeout")
    check("upsert: re-ruling a member does not add a second row", len(parse(up)), 2)
    check("upsert: the re-ruled member carries the new disposition",
          parse(up)["1315"],
          {"disposition": "adopted", "at": "2026-09-06T08:00:00Z", "by": "closeout"})
    check("upsert: the untouched member is unchanged",
          parse(up)["1163"],
          {"disposition": "adopted", "at": "2026-09-05T12:00:00Z", "by": "checkpoint"})
    check("upsert: replacement keeps insertion order (#1315 first, as in the input)",
          list(parse(up).keys()), ["1315", "1163"])
    # A member absent from the store APPENDS — the store grows by one row and the new member
    # sorts last, after the two the fixture already carried.
    add = upsert(body, "999", "deferred", "2026-09-06T09:00:00Z", "bucket")
    check("upsert: a new member appends", list(parse(add).keys()), ["1315", "1163", "999"])

    # ── refusals ── the closed vocabularies. `undispositioned` is the absence of a row, so
    # asking to WRITE it is a refusal, not a delete; likewise a `by` outside the three writers
    # and a member that is not an issue number.
    for desc, args in (
            ("an unknown disposition word", (body, "1315", "maybe", "2026-01-01T00:00:00Z", "checkpoint")),
            ("`undispositioned` as a written state", (body, "1315", "undispositioned", "2026-01-01T00:00:00Z", "checkpoint")),
            ("an unknown `by` value", (body, "1315", "adopted", "2026-01-01T00:00:00Z", "reviewer")),
            ("a member that is not an issue number", (body, "abc", "adopted", "2026-01-01T00:00:00Z", "checkpoint")),
    ):
        try:
            upsert(*args)
        except Refused:
            n += 1
            print(f"  ✓ upsert REFUSES {desc}")
        else:
            raise AssertionError(f"upsert accepted {desc} — the vocabulary is not closed")

    # ── qualified keys (FIX #1451) — cross-repo members ──
    # A qualified key is repo#number, e.g., "agent-runtime#115" for a member in agent-runtime repo.
    qbody = upsert(MARK + "\n", "agent-runtime#115", "deferred", "2026-09-08T00:00:00Z", "checkpoint")
    check("upsert: qualified key (repo#number) is accepted",
          parse(qbody),
          {"agent-runtime#115": {"disposition": "deferred", "at": "2026-09-08T00:00:00Z", "by": "checkpoint"}})
    # Mixed store with bare and qualified keys
    mixed_q = upsert(qbody, "1234", "adopted", "2026-09-08T01:00:00Z", "bucket")
    check("upsert: qualified and bare members coexist",
          list(parse(mixed_q).keys()), ["agent-runtime#115", "1234"])
    check("parse: qualified key and bare number are both readable",
          parse(mixed_q),
          {"agent-runtime#115": {"disposition": "deferred", "at": "2026-09-08T00:00:00Z", "by": "checkpoint"},
           "1234": {"disposition": "adopted", "at": "2026-09-08T01:00:00Z", "by": "bucket"}})

    # ── the malformed row ── loud, excluded, NOT fatal: the well-formed sibling still parses.
    mixed = MARK + "\n#1315 deferred 2026-09-05T12:00:00Z by=checkpoint\nthis is not a row\n"
    check("parse: a malformed row is excluded, its well-formed sibling survives",
          list(parse(mixed).keys()), ["1315"])

    # ── PAGINATION: the `--slurp` shape, through the real parse ── Expectations derived from
    # `gh help api`'s documented contract, NOT from running gh: plain `--paginate` "outputs each
    # page of results in sequence" (back-to-back JSON documents), while `--slurp` "wraps the
    # pages in an outer JSON array" — so the slurped payload is [[page1…],[page2…]] and the
    # parser owes exactly one level of flattening. Both shapes go through the SAME function the
    # subprocess path uses, so a regression here cannot hide behind the fixture recordings.
    _c = lambda i: {"id": i, "body": f"comment {i}"}          # noqa: E731 — a fixture, not production
    # Two pages of two: the outer array has 2 elements, each a LIST ⇒ flatten ⇒ 4 comments, in
    # page order (page 1's both, then page 2's both).
    two_pages = json.dumps([[_c(1), _c(2)], [_c(3), _c(4)]])
    check("--slurp: two pages flatten to one ordered list",
          [c["id"] for c in _parse_paginated_list(two_pages)], [1, 2, 3, 4])
    # ONE page, as gh returns it under --slurp: still wrapped, so [[…]] ⇒ 2 comments.
    check("--slurp: a single wrapped page flattens too",
          [c["id"] for c in _parse_paginated_list(json.dumps([[_c(1), _c(2)]]))], [1, 2])
    # The un-wrapped shape every committed replay world holds: elements are DICTS, not lists, so
    # the flatten must not fire and the list passes through untouched.
    check("un-wrapped single page (the recorded-world shape) passes through",
          [c["id"] for c in _parse_paginated_list(json.dumps([_c(1), _c(2)]))], [1, 2])
    check("--slurp: an empty payload is no comments, not a flatten error",
          _parse_paginated_list("[]"), [])
    # A 200 that is not JSON, and a JSON non-list, are both UNREADABLE — never "no comments".
    for desc, raw in (("non-JSON stdout", "upstream connect error"), ("a JSON object", '{"a":1}')):
        try:
            _parse_paginated_list(raw)
        except Unreadable:
            n += 1
            print(f"  ✓ {desc} is UNREADABLE, not empty")
        else:
            raise AssertionError(f"{desc} parsed as readable — a blind read can now create a store")
    # …and END-TO-END: the store sitting on page 2 must still be FOUND. This is the regression the
    # bare `--paginate` bug produced — a container with >100 comments could never read its own
    # store, so trigger (c) held forever and every `set` refused, on the largest trees only.
    _real_raw = _gh_comments_raw
    try:
        _gh_comments_raw = lambda slug, issue: json.dumps(          # noqa: E731
            [[_c(i) for i in range(1, 101)],
             [{"id": 999, "body": MARK + "\n#42 adopted 2026-09-05T12:00:00Z by=closeout\n"}]])
        cid, body = find("o/r", 1)
        check("a store on PAGE 2 is found (the >100-comment container)", cid, 999)
        check("…and parses to its one row", parse(body),
              {"42": {"disposition": "adopted", "at": "2026-09-05T12:00:00Z", "by": "closeout"}})
    finally:
        _gh_comments_raw = _real_raw

    # ── the STDIN form, end-to-end through a real subprocess ── the payload is deliberately
    # larger than MAX_ARG_STRLEN (128 KiB): as an env var this exact call dies E2BIG before
    # Python starts (the 2026-09-22 Goal #1640 shape); on stdin it must parse to its one row.
    import os
    import subprocess as _sp
    import sys as _sys
    _big = json.dumps([{"id": i, "body": "x" * 1500} for i in range(1, 101)]
                      + [{"id": 7, "body": MARK + "\n#42 adopted 2026-09-05T12:00:00Z by=closeout\n"}])
    check("stdin self-test payload exceeds the 128 KiB single-argument cap", len(_big) > 131072, True)
    _r = _sp.run([_sys.executable, __file__, "read", "o/r", "1"], input=_big, capture_output=True,
                 text=True, env={**os.environ, "EPIC_DISPOSITIONS_COMMENTS": "-"})
    check("EPIC_DISPOSITIONS_COMMENTS=- reads the payload from stdin (rc 0)", _r.returncode, 0)
    check("…and the store on the last page parses to its one row",
          json.loads(_r.stdout or "{}"),
          {"42": {"disposition": "adopted", "at": "2026-09-05T12:00:00Z", "by": "closeout"}})

    # ── the UNREADABLE path, through the real seam ── find() must RAISE, so that set_disposition
    # can never reach _put on a blind read (the second-store-comment failure mode). Driven by
    # replacing the fetch seam, not by re-implementing find().
    _real = _fetch_comments
    try:
        def _boom(slug, issue):
            raise Unreadable("injected")
        _fetch_comments = _boom
        try:
            find("o/r", 1)
        except Unreadable:
            n += 1
            print("  ✓ find RAISES Unreadable rather than reporting the store absent")
        else:
            raise AssertionError("find swallowed an unreadable fetch — a blind create is now possible")
        wrote = []
        _real_put = _put
        try:
            _put = lambda *a, **k: wrote.append(a)          # noqa: E731 — a probe, not production
            try:
                set_disposition("o/r", 1, "5", "adopted", "checkpoint")
            except Unreadable:
                pass
            check("set_disposition writes NOTHING when the read was unreadable", wrote, [])
        finally:
            _put = _real_put
        # …and the CONFIRMED-ABSENT read is the other half: an empty comments list is `absent`,
        # so the write goes ahead as a CREATE (comment_id None) carrying exactly one row. The
        # membership read is stubbed the same way — #5 is an own-repo member of o/r#1, so the
        # bare row keeps today's shape.
        _fetch_comments = lambda slug, issue: []
        created = []
        _real_put2 = _put
        _real_subs = _gh_subissues_raw
        try:
            _put = lambda slug, issue, cid, b: created.append((cid, b))   # noqa: E731
            _gh_subissues_raw = lambda repo, issue: json.dumps(           # noqa: E731
                [{"number": 5, "repository_url": "https://api.github.com/repos/o/r"}])
            set_disposition("o/r", 1, "5", "adopted", "checkpoint", at="2026-09-05T12:00:00Z")
        finally:
            _put = _real_put2
            _gh_subissues_raw = _real_subs
        check("a confirmed-absent store CREATES (comment id None) with one row",
              created,
              [(None, MARK + "\n#5 adopted 2026-09-05T12:00:00Z by=checkpoint\n")])
    finally:
        _fetch_comments = _real

    # ── the #1640 world: a CROSS-REPO member written BARE (homelab#2589) ──
    # The tree as the native sub-issue edges read it — the shape measured on Goal #1640 on
    # 2026-09-16, when rows `#134/#136/#138/#139` were written BARE for agent-runtime members:
    #   homelab#1640       → homelab#1939, homelab#1768, agent-runtime#134
    #   homelab#1768       → agent-runtime#136        (depth 2 — a theme's member)
    #   agent-runtime#136  → agent-runtime#138        (depth 3)
    # `agent-runtime#134` is the cross-repo member the acceptance names; `homelab#1939` is the
    # own-repo member whose bare row must keep today's shape.
    _TREE = {
        ("teststuffstash/homelab", 1640): [
            {"number": 1939,
             "repository_url": "https://api.github.com/repos/teststuffstash/homelab"},
            {"number": 1768,
             "repository_url": "https://api.github.com/repos/teststuffstash/homelab"},
            {"number": 134,
             "repository_url": "https://api.github.com/repos/teststuffstash/agent-runtime"},
        ],
        ("teststuffstash/homelab", 1768): [
            {"number": 136,
             "repository_url": "https://api.github.com/repos/teststuffstash/agent-runtime"},
        ],
        ("teststuffstash/agent-runtime", 136): [
            {"number": 138,
             "repository_url": "https://api.github.com/repos/teststuffstash/agent-runtime"},
        ],
    }

    def _fake_subs(repo, issue):
        """The recorded world's membership read — one call per node; a leaf is an empty list."""
        return json.dumps(_TREE.get((repo, issue), []))

    _real_subs = _gh_subissues_raw
    _real_fetch = _fetch_comments
    _real_put3 = _put
    try:
        _gh_subissues_raw = _fake_subs
        _fetch_comments = lambda slug, issue: []          # noqa: E731 — confirmed-absent store
        wrote = []
        _put = lambda *a, **k: wrote.append(a)            # noqa: E731 — a probe, not production
        # …the bare cross-repo member is REFUSED, and the refusal names the qualified form.
        try:
            set_disposition("teststuffstash/homelab", 1640, "134", "adopted", "checkpoint")
        except Refused as e:
            n += 1
            print("  ✓ set REFUSES a bare cross-repo member (the #1640 world)")
            refusal = str(e)
        else:
            raise AssertionError("set accepted a bare cross-repo member — the #2589 defect is back")
        check("…and the refusal names the QUALIFIED form", "agent-runtime#134" in refusal, True)
        check("…and writes NOTHING", wrote, [])
        # …a member at DEPTH 2 in another repo is refused the same way: three of the four
        # #1640 rows (`#136/#138/#139`) sat deeper than the container's own children, so a
        # direct-children read would not have found them either.
        try:
            set_disposition("teststuffstash/homelab", 1640, "136", "adopted", "checkpoint")
        except Refused as e:
            n += 1
            print("  ✓ set REFUSES a bare cross-repo member at depth 2")
            check("…and names the QUALIFIED form", "agent-runtime#136" in str(e), True)
        else:
            raise AssertionError("set accepted a bare cross-repo member at depth 2")
        check("…and still writes NOTHING", wrote, [])
        # …and the QUALIFIED form writes the row the readers match.
        rows = set_disposition("teststuffstash/homelab", 1640, "agent-runtime#134",
                               "adopted", "checkpoint", at="2026-09-16T00:00:00Z")
        check("a qualified cross-repo member writes the row", list(rows), ["agent-runtime#134"])
        check("…and the row carries the disposition",
              rows["agent-runtime#134"]["disposition"], "adopted")
        # …and an own-repo bare member keeps today's behaviour — the row is still `#1939`.
        rows = set_disposition("teststuffstash/homelab", 1640, "1939", "deferred",
                               "checkpoint", at="2026-09-16T00:00:00Z")
        check("an own-repo bare member writes the bare row (today's behaviour)",
              list(rows), ["1939"])
        # …and a number that is not in the tree at all is refused, naming the qualified form.
        try:
            set_disposition("teststuffstash/homelab", 1640, "4242", "adopted", "checkpoint")
        except Refused as e:
            n += 1
            print("  ✓ set REFUSES a bare number that is not a member of the container")
            check("…and names the qualified form", "repo#4242" in str(e), True)
        else:
            raise AssertionError("set accepted a bare number that is not a member")
        # …and an UNREADABLE membership read is a refusal too (fail loud, rule #6) — never a
        # silent write on a half-read tree.
        def _boom_subs(repo, issue):
            raise Unreadable("injected membership failure")
        _gh_subissues_raw = _boom_subs
        wrote_before = len(wrote)
        try:
            set_disposition("teststuffstash/homelab", 1640, "1939", "adopted", "checkpoint")
        except Unreadable:
            n += 1
            print("  ✓ set REFUSES on an unreadable membership read (fail loud, rule #6)")
        else:
            raise AssertionError("set wrote on an unreadable membership read")
        check("…and writes NOTHING", len(wrote), wrote_before)
    finally:
        _gh_subissues_raw = _real_subs
        _fetch_comments = _real_fetch
        _put = _real_put3

    # ── the CLI's exit code, end-to-end through a stubbed `gh` ──
    # A refused `set` must be LOUD (non-zero) and must not have posted a row: a refusal that
    # still wrote is the defect in its nastiest form. The stub answers the membership read with
    # the #1640 world's cross-repo member and logs every write call it is asked to make.
    import shutil
    import tempfile
    _td = tempfile.mkdtemp(prefix="epic-dispositions-cli-")
    try:
        _calls = os.path.join(_td, "calls.log")
        _gh = os.path.join(_td, "gh")
        with open(_gh, "w") as _f:
            _f.write(
                "#!/usr/bin/env bash\n"
                'case "$*" in\n'
                "  *sub_issues*) echo '[{\"number\": 134, \"repository_url\": "
                "\"https://api.github.com/repos/teststuffstash/agent-runtime\"}]' ;;\n"
                "  *\"-X POST\"*|*\"-X PATCH\"*) echo \"$*\" >> \"$GH_CALLS\" ;;\n"
                "  *) echo '[]' ;;\n"
                "esac\n")
        os.chmod(_gh, 0o755)
        _env = {**os.environ, "PATH": _td + os.pathsep + os.environ.get("PATH", ""),
                "GH_CALLS": _calls}
        _r = _sp.run([_sys.executable, __file__, "set", "teststuffstash/homelab", "1640",
                      "134", "adopted", "--by", "checkpoint"],
                     capture_output=True, text=True, env=_env)
        check("the CLI REFUSES a bare cross-repo member (exit 1)", _r.returncode, 1)
        check("…and names the qualified form", "agent-runtime#134" in _r.stderr, True)
        check("…and posted NO row", os.path.exists(_calls), False)
    finally:
        shutil.rmtree(_td, ignore_errors=True)

    print(f"epic-dispositions self-test: OK ({n} assertions)")
    return 0


# ── CLI ───────────────────────────────────────────────────────────────────────────────────────

def main(argv: "list[str]") -> int:
    ap = argparse.ArgumentParser(prog="epic_dispositions", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--self-test", action="store_true", help="run the assertion suite and exit")
    sub = ap.add_subparsers(dest="cmd")
    for name in ("read", "list"):
        s = sub.add_parser(name)
        s.add_argument("slug")
        s.add_argument("container", type=int)
    s = sub.add_parser("set")
    s.add_argument("slug")
    s.add_argument("container", type=int)
    s.add_argument("member")
    s.add_argument("disposition", choices=list(DISPOSITIONS))
    s.add_argument("--by", required=True, choices=list(BY_VALUES))
    s.add_argument("--at", default=None, help="ISO-8601 Z (default: now) — for deterministic tests")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()
    if not args.cmd:
        ap.print_usage(sys.stderr)
        return 1

    try:
        if args.cmd == "read":
            # STDOUT stays EMPTY on the unreadable path (below): a caller that reads `{}` off a
            # failed probe would count every member as undispositioned and wake a checkpoint on
            # an API blip. Nothing out, exit 2, the caller holds.
            print(json.dumps(read_store(args.slug, args.container), sort_keys=True))
            return 0
        if args.cmd == "list":
            rows = read_store(args.slug, args.container)
            if not rows:
                print(f"{args.slug}#{args.container}: no dispositions "
                      "(every tree member is `undispositioned`)")
                return 0
            print(f"{args.slug}#{args.container}: {len(rows)} disposition(s)")
            for member, r in rows.items():
                print(f"  #{member:<8} {r['disposition']:<10} {r['at']}  by={r['by']}")
            return 0
        if args.cmd == "set":
            rows = set_disposition(args.slug, args.container, args.member,
                                   args.disposition, args.by, at=args.at)
            print(f"epic-dispositions: {args.slug}#{args.container} "
                  f"#{args.member} → {args.disposition} by={args.by} ({len(rows)} row(s))")
            return 0
    except Refused as e:
        print(f"epic-dispositions: REFUSED — {e}", file=sys.stderr)
        return 1
    except Unreadable as e:
        print(f"epic-dispositions: PROBE-FAIL — {args.slug}#{args.container}: {e}", file=sys.stderr)
        return 2
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
