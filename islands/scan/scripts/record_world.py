#!/usr/bin/env python3
"""Record one GitHub world of the scan island whole (specs/worlds/README.md §Recorded worlds).

    uv run --frozen python scripts/record_world.py <world> <pr> [<pr> …] [--rest-description <commit>]

A world is the set of GitHub reads one surface makes. For each read the recorder runs the real
`gh` (on PATH) and writes its stdout to one file under `specs/worlds/<world>/`, byte for byte — no
field removed, no header kept, no token kept. `provenance.yaml` beside the files names the repo,
the items, every read (its `gh` argv and its file), the recording time and the recorder's commit.

    uv run --frozen python scripts/record_world.py goal-checkpoint <goal> <assembly-pr>

`goal-checkpoint` records the reads the trigger (b) hold makes: the Goal issue and its comments, the
open pull request list, and the assembly pull request's REST read, `gh pr view` (commits, reviews,
status check rollup) and comments. Its one write, `create-comment`, is declared like any other.

    uv run --frozen python scripts/record_world.py <world> --add pull-commits

`--add pull-commits` adds, for each item of an already recorded world, the pull-commits read
(`gh api repos/<repo>/pulls/<n>/commits?per_page=100`, which carries each commit's `parents`): it writes
each answer file and appends one entry per read to `provenance.yaml`'s `reads`, with that entry's own
`recorded_at` and `recorder_commit`; no existing line changes and no recorded read is performed again.

    uv run --frozen python scripts/record_world.py <world> --add base-ci

`--add base-ci` adds the one read of the base's head, `master`'s
(`gh api repos/<repo>/commits/heads/master/check-runs?per_page=100`): it writes the answer file and appends
one entry to `provenance.yaml`'s `reads`, with its own `recorded_at` and `recorder_commit`, as
`--add pull-commits` does; no recorded read is performed again.

The repo's visibility is read first: a repo GitHub reports as private is refused before any other
read. A read the token may not make (HTTP 403) is recorded unauthenticated over the public REST API
and marked `auth: none`.

A world's writes are never performed. The recorder only declares them in `provenance.yaml` and
extracts each one's response schemas from GitHub's published REST description (the
github/rest-api-description repo, at a named commit) into `schemas/`. The answers in `writes/` are
hand-written and are left untouched here; tests/test_world_writes.py validates them.
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

ISLAND = Path(__file__).resolve().parent.parent
WORLDS = ISLAND / "specs" / "worlds"
REPO = "teststuffstash/homelab"
DESCRIPTION_REPO = "github/rest-api-description"
# The OpenAPI 3.1 description for the REST API version gh talks when it names none (2022-11-28).
DESCRIPTION_FILE = "descriptions-next/api.github.com/api.github.com.2022-11-28.json"

# The `--json` field list the updater's `gh pr list` snapshot asks for (scan_island/updater.py).
BOARD_LIST_FIELDS = (
    "number,createdAt,mergeStateStatus,autoMergeRequest,reviewDecision,labels,headRefOid,"
    "latestReviews,baseRefName,reviews,author,headRefName"
)
# The `--json` field list of the scan's open-PR fetch (agents/coordinator-scan.sh `prsjson`) — what the (b) hold reads.
CHECKPOINT_LIST_FIELDS = "number,title,labels,reviewDecision,autoMergeRequest,mergeStateStatus,author,headRefName,body,baseRefName,headRefOid"


@dataclass(frozen=True)
class Write:
    """One write the world's surface issues: answered by hand-written files, never performed."""

    op: str
    method: str  # an HTTP method, or "gh" for a gh command that prints no JSON
    path: str  # REST path template (owner/repo filled), or the gh argv joined by spaces
    operation_id: str = ""  # the REST description's operationId ("" for a gh command)
    statuses: tuple[str, ...] = ()  # the answer statuses written by hand under writes/<op>.<status>.json
    after: str = ""  # for a read answered differently after a write: that write's op
    exit: int | None = None  # for a gh command: the exit status that is its answer


@dataclass
class Read:
    argv: list[str]
    file: str
    auth: str = "token"
    status: str = "ok"
    recorded_at: str = ""  # set only on a read added after the whole recording (--add)
    recorder_commit: str = ""


@dataclass
class Plan:
    reads: list[Read] = field(default_factory=list)
    writes: list[Write] = field(default_factory=list)


def file_for(argv: list[str]) -> str:
    """The answer file a read is stored in — derived from the argv, one file per read."""
    if argv[:2] == ["pr", "list"]:
        return "pr-list.json"
    if argv[:2] == ["pr", "view"]:
        return f"pr-view-{argv[2]}.{argv[argv.index('--json') + 1]}.json"
    if argv[0] == "api":
        path = argv[1].removeprefix(f"repos/{REPO}/")
        return "api." + path.replace("/", ".").replace("?", "@") + ".json"
    raise ValueError(f"no file rule for read: gh {' '.join(argv)}")


def _json(proc: subprocess.CompletedProcess[bytes], what: str) -> object:
    if proc.returncode:
        raise SystemExit(f"record_world: {what} failed: {proc.stderr.decode(errors='replace').strip()}")
    return json.loads(proc.stdout)


def gh(*argv: str) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(["gh", *argv], capture_output=True, check=False)


def pull_commits_read(n: str) -> list[str]:
    """The read that carries each commit's `parents` (glossary.md merge commit); costs no GraphQL."""
    return ["api", f"repos/{REPO}/pulls/{n}/commits?per_page=100"]


def plan_pr_handoff(prs: list[str]) -> Plan:
    """One pull request as the major handoff reads it: the PR view, the issue labels, the REST pull."""
    if len(prs) != 1:
        raise SystemExit("record_world: pr-handoff records exactly one pull request")
    n = prs[0]
    reads = [
        ["pr", "view", n, "--repo", REPO, "--json", "state,labels,reviews,commits"],
        pull_commits_read(n),
        ["api", f"repos/{REPO}/issues/{n}/labels"],
        ["api", f"repos/{REPO}/pulls/{n}"],
    ]
    base = f"repos/{REPO}/issues/{{issue_number}}/labels"
    writes = [
        Write("add-labels", "POST", base, "issues/add-labels", ("200",)),
        Write("remove-label", "DELETE", base + "/{name}", "issues/remove-label", ("200", "404")),
        Write("pr-merge-auto", "gh", f"pr merge {{pull_number}} --repo {REPO} --auto --squash", exit=0),
        Write("get-pull-after-arm", "GET", f"repos/{REPO}/pulls/{{pull_number}}", "pulls/get", ("200",), after="pr-merge-auto"),
    ]
    return Plan([Read(r, file_for(r)) for r in reads], writes)


def plan_pr_board(prs: list[str]) -> Plan:
    """The open-PR snapshot as the updater reads it, plus the per-PR reads for the named PRs."""
    if not prs:
        raise SystemExit("record_world: pr-board needs the pull requests whose per-PR reads to record")
    snapshot = ["pr", "list", "--repo", REPO, "--state", "open", "--limit", "100", "--json", BOARD_LIST_FIELDS]
    return Plan(
        [Read(snapshot, file_for(snapshot))],
        [
            Write("update-branch", "PUT", f"repos/{REPO}/pulls/{{pull_number}}/update-branch", "pulls/update-branch", ("202", "422")),
            Write("create-label", "POST", f"repos/{REPO}/labels", "issues/create-label", ("201", "422")),
            Write("add-labels", "POST", f"repos/{REPO}/issues/{{issue_number}}/labels", "issues/add-labels", ("200",)),
            Write("remove-label", "DELETE", f"repos/{REPO}/issues/{{issue_number}}/labels/{{name}}", "issues/remove-label", ("200", "404")),
            Write("update-pull", "PATCH", f"repos/{REPO}/pulls/{{pull_number}}", "pulls/update", ("200",)),
        ],
    )


def plan_pr_merges(prs: list[str]) -> Plan:
    """The commits of one pull request as the PR view and the pull-commits read list them. Declares no write."""
    if len(prs) != 1:
        raise SystemExit("record_world: pr-merges records exactly one pull request")
    n = prs[0]
    reads = [["pr", "view", n, "--repo", REPO, "--json", "commits"], pull_commits_read(n)]
    return Plan([Read(r, file_for(r)) for r in reads], [])


def base_ci_read() -> list[str]:
    """The read of the check runs at the head of the base branch `master` (`heads/<branch>` is a ref the REST read takes)."""
    return ["api", f"repos/{REPO}/commits/heads/master/check-runs?per_page=100"]


def board_per_pr(n: str, oid: str) -> list[list[str]]:
    return [
        ["pr", "view", n, "--repo", REPO, "--json", "commits"],
        ["pr", "view", n, "--repo", REPO, "--json", "commits,reviews"],
        pull_commits_read(n),
        ["api", f"repos/{REPO}/commits/{oid}/check-runs?per_page=100"],
        ["api", f"repos/{REPO}/commits/{oid}/status"],
        ["api", f"repos/{REPO}/pulls/{n}"],
    ]


def plan_goal_checkpoint(prs: list[str]) -> Plan:
    """A Goal and its assembly pull request as the checkpoint (b) hold reads them. Items: [goal, assembly-pr]."""
    if len(prs) != 2:
        raise SystemExit("record_world: goal-checkpoint records <goal> <assembly-pr>")
    goal, pr = prs
    open_list = ["pr", "list", "--repo", REPO, "--state", "open", "--limit", "100", "--json", CHECKPOINT_LIST_FIELDS]
    reads = [
        ["api", f"repos/{REPO}/issues/{goal}"],
        ["api", f"repos/{REPO}/issues/{goal}/comments?per_page=100"],
        open_list,
        ["api", f"repos/{REPO}/pulls/{pr}"],
        ["pr", "view", pr, "--repo", REPO, "--json", "commits,reviews,statusCheckRollup"],
        ["api", f"repos/{REPO}/issues/{pr}/comments?per_page=100"],
    ]
    writes = [Write("create-comment", "POST", f"repos/{REPO}/issues/{{issue_number}}/comments", "issues/create-comment", ("201", "403"))]
    return Plan([Read(r, file_for(r)) for r in reads], writes)


PLANS = {"pr-handoff": plan_pr_handoff, "pr-board": plan_pr_board, "pr-merges": plan_pr_merges, "goal-checkpoint": plan_goal_checkpoint}


def refuse_private(repo: str) -> str:
    """Read the repo's visibility first; a repo GitHub reports as private ends the recording."""
    meta = _json(gh("api", f"repos/{repo}"), f"the visibility read of {repo}")
    if not isinstance(meta, dict) or "private" not in meta:
        raise SystemExit(f"record_world: the visibility read of {repo} carries no `private` field — refusing")
    if meta["private"] is not False:
        raise SystemExit(f"record_world: {repo} is private — a recorded world is recorded from public repos only")
    return str(meta.get("visibility", "public"))


def unauthenticated(path: str) -> bytes:
    req = urllib.request.Request(f"https://api.github.com/{path}", headers={"Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=30) as resp:  # noqa: S310 — a fixed https host
        return resp.read()


def perform(read: Read) -> bytes:
    proc = gh(*read.argv)
    if proc.returncode == 0:
        return proc.stdout
    err = proc.stderr.decode(errors="replace")
    if read.argv[0] == "api" and "(HTTP 403)" in err:
        read.auth = "none"
        try:
            return unauthenticated(read.argv[1])
        except urllib.error.URLError as e:
            raise SystemExit(f"record_world: gh {' '.join(read.argv)} answered 403 and the unauthenticated read failed: {e}") from e
    raise SystemExit(f"record_world: gh {' '.join(read.argv)} failed: {err.strip()}")


# --- the REST description: response schemas for the world's writes -------------------------------

_REF = re.compile(r"^#/components/(schemas|responses)/(.+)$")


def description_head() -> str:
    proc = gh("api", f"repos/{DESCRIPTION_REPO}/commits/main", "--jq", ".sha")
    sha = proc.stdout.decode().strip()
    if proc.returncode or not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise SystemExit(f"record_world: could not read {DESCRIPTION_REPO}'s head: {proc.stderr.decode(errors='replace').strip()}")
    return sha


def description(commit: str) -> dict:
    url = f"https://raw.githubusercontent.com/{DESCRIPTION_REPO}/{commit}/{DESCRIPTION_FILE}"
    with urllib.request.urlopen(url, timeout=120) as resp:  # noqa: S310 — a fixed https host
        return json.load(resp)


def _operation(desc: dict, operation_id: str) -> dict:
    for item in desc["paths"].values():
        for op in item.values():
            if isinstance(op, dict) and op.get("operationId") == operation_id:
                return op
    raise SystemExit(f"record_world: operationId {operation_id} not in the REST description")


def _response_schema(desc: dict, response: dict) -> dict:
    ref = response.get("$ref")
    if ref:
        m = _REF.match(ref)
        if not m or m.group(1) != "responses":
            raise SystemExit(f"record_world: unexpected response ref {ref}")
        response = desc["components"]["responses"][m.group(2)]
    return response["content"]["application/json"]["schema"]


def _nullable_ref(node: object) -> int:
    """NULLABLE_REF: the 3.1 description renders a nullable `$ref` (OpenAPI 3.0 `nullable` + `allOf`) as
    `{"allOf": [<ref>], "type": ["null"]}`, which no value satisfies — not even the `null` GitHub sends
    (a label's `archived_by`). Each such node is read as its own description says: the ref, or null.
    The one correction the extraction makes; every node it touches is counted in the schema's `$comment`."""
    count = 0
    if isinstance(node, dict):
        if node.get("type") == ["null"] and isinstance(node.get("allOf"), list):
            node["anyOf"] = [*node.pop("allOf"), {"type": "null"}]
            del node["type"]
            count += 1
        for v in node.values():
            count += _nullable_ref(v)
    elif isinstance(node, list):
        for v in node:
            count += _nullable_ref(v)
    return count


def schema_for(desc: dict, operation_id: str, status: str) -> dict:
    """The response schema of one operation and status, its component refs bundled under `$defs`."""
    op = _operation(desc, operation_id)
    if status not in op["responses"]:
        raise SystemExit(f"record_world: {operation_id} documents no {status} response")
    root = json.loads(json.dumps(_response_schema(desc, op["responses"][status])))
    defs: dict[str, dict] = {}

    def rewrite(node: object) -> None:
        if isinstance(node, dict):
            ref = node.get("$ref")
            if isinstance(ref, str):
                m = _REF.match(ref)
                if not m or m.group(1) != "schemas":
                    raise SystemExit(f"record_world: unexpected schema ref {ref}")
                name = m.group(2)
                node["$ref"] = f"#/$defs/{name}"
                if name not in defs:
                    defs[name] = json.loads(json.dumps(desc["components"]["schemas"][name]))
                    rewrite(defs[name])
            for v in node.values():
                rewrite(v)
        elif isinstance(node, list):
            for v in node:
                rewrite(v)

    rewrite(root)
    fixed = sum(_nullable_ref(n) for n in (root, *defs.values()))
    note = f"; {fixed} `allOf` + `type: [null]` node(s) read as `anyOf [<ref>, null]` (NULLABLE_REF)" if fixed else ""
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$comment": f"{operation_id} {status} — extracted from {DESCRIPTION_REPO}@{{commit}} {DESCRIPTION_FILE}{note}",
        **root,
        **({"$defs": dict(sorted(defs.items()))} if defs else {}),
    }


# --- provenance.yaml: block YAML whose every value is a JSON scalar or flow list ------------------


def _y(v: object) -> str:
    return json.dumps(v, ensure_ascii=False)


def read_lines(r: Read) -> list[str]:
    lines = [f"  - argv: {_y(r.argv)}", f"    file: {_y(r.file)}", f"    auth: {_y(r.auth)}"]
    if r.recorded_at:
        lines += [f"    recorded_at: {_y(r.recorded_at)}", f"    recorder_commit: {_y(r.recorder_commit)}"]
    return lines


def provenance_text(meta: dict, reads: list[Read], writes: list[Write]) -> str:
    out = [
        "# Written by scripts/record_world.py — re-record, never hand-edit. Every value is JSON (valid YAML).",
        *(f"{k}: {_y(v)}" for k, v in meta.items()),
        "reads:",
    ]
    for r in reads:
        out += read_lines(r)
    out.append("writes:")
    for w in writes:
        out += [f"  - op: {_y(w.op)}", f"    method: {_y(w.method)}", f"    path: {_y(w.path)}"]
        if w.operation_id:
            out.append(f"    operation_id: {_y(w.operation_id)}")
        if w.statuses:
            out.append(f"    statuses: {_y(list(w.statuses))}")
        if w.after:
            out.append(f"    after: {_y(w.after)}")
        if w.exit is not None:
            out.append(f"    exit: {_y(w.exit)}")
    return "\n".join(out) + "\n"


def recorder_commit() -> str:
    """HEAD of the recorder's checkout; `-dirty` when the recorder itself has uncommitted changes."""
    me = Path(__file__).resolve()
    head = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, cwd=ISLAND, check=True).stdout.strip()
    dirty = subprocess.run(["git", "status", "--porcelain", "--", str(me)], capture_output=True, text=True, cwd=ISLAND, check=True)
    return head + ("-dirty" if dirty.stdout.strip() else "")


def add_pull_commits(args: argparse.Namespace) -> int:
    """`--add pull-commits`: the pull-commits read for each recorded item; nothing already recorded is read again."""
    if args.prs:
        raise SystemExit("record_world: --add pull-commits takes no pull request: it reads the world's recorded items")
    world = Path(args.out) / args.world
    prov_path = world / "provenance.yaml"
    if not prov_path.is_file():
        raise SystemExit(f"record_world: {args.world} is not recorded — nothing to add to")
    text = prov_path.read_text("utf-8")
    items = _recorded_items(text)
    refuse_private(REPO)  # before any other read
    commit = recorder_commit()
    reads = [Read(pull_commits_read(str(n)), "") for n in items]
    for r in reads:
        r.file = file_for(r.argv)
        if (world / r.file).exists() or f"file: {_y(r.file)}" in text:
            raise SystemExit(f"record_world: {args.world} already holds {r.file}")
    answers: list[bytes] = []  # every read first: a failing read leaves the world untouched
    for r in reads:
        answers.append(perform(r))
        r.recorded_at = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
        r.recorder_commit = commit
    for r, body in zip(reads, answers, strict=True):
        (world / r.file).write_bytes(body)
    lines = text.split("\n")
    at = lines.index("writes:")  # the reads list ends where the writes list begins
    added = [line for r in reads for line in read_lines(r)]
    prov_path.write_text("\n".join([*lines[:at], *added, *lines[at:]]), "utf-8")
    print(f"record_world: {args.world} — {len(reads)} read(s) added → {world}")
    return 0


def add_base_ci(args: argparse.Namespace) -> int:
    """`--add base-ci`: the one read of `master`'s head check runs; nothing already recorded is read again."""
    if args.prs:
        raise SystemExit("record_world: --add base-ci takes no pull request: it reads master's head")
    world = Path(args.out) / args.world
    prov_path = world / "provenance.yaml"
    if not prov_path.is_file():
        raise SystemExit(f"record_world: {args.world} is not recorded — nothing to add to")
    text = prov_path.read_text("utf-8")
    refuse_private(REPO)  # before any other read
    commit = recorder_commit()
    read = Read(base_ci_read(), "")
    read.file = file_for(read.argv)
    if (world / read.file).exists() or f"file: {_y(read.file)}" in text:
        raise SystemExit(f"record_world: {args.world} already holds {read.file}")
    body = perform(read)
    read.recorded_at = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    read.recorder_commit = commit
    (world / read.file).write_bytes(body)
    lines = text.split("\n")
    at = lines.index("writes:")
    prov_path.write_text("\n".join([*lines[:at], *read_lines(read), *lines[at:]]), "utf-8")
    print(f"record_world: {args.world} — 1 read added → {world}")
    return 0


def _recorded_items(text: str) -> list[int]:
    m = re.search(r"^items: (\[.*\])$", text, re.M)
    if not m:
        raise SystemExit("record_world: provenance.yaml names no items")
    return [int(n) for n in json.loads(m.group(1))]


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("world", choices=sorted(PLANS))
    ap.add_argument("prs", nargs="*")
    ap.add_argument("--add", choices=["pull-commits", "base-ci"], help="add a read to an already recorded world, for its recorded items")
    ap.add_argument("--rest-description", default="", help="github/rest-api-description commit (default: main's head)")
    ap.add_argument("--description-file", default="", help="a local copy of the description at that commit (no download)")
    ap.add_argument("--out", default=str(WORLDS), help=argparse.SUPPRESS)
    args = ap.parse_args(argv)
    if args.add == "base-ci":
        return add_base_ci(args)
    if args.add:
        return add_pull_commits(args)
    if not args.prs:
        raise SystemExit("record_world: name the pull request(s) to record")

    visibility = refuse_private(REPO)  # before any other read
    commit = recorder_commit()
    plan = PLANS[args.world](args.prs)
    answers: dict[str, bytes] = {}  # each read is performed ONCE; its bytes are the file
    if args.world == "pr-board":
        # the snapshot that names the heads is the snapshot recorded: per-PR reads follow ITS headRefOid
        answers[plan.reads[0].file] = perform(plan.reads[0])
        snapshot = json.loads(answers[plan.reads[0].file].decode())
        oids = {str(pr["number"]): pr["headRefOid"] for pr in snapshot}
        missing = [n for n in args.prs if n not in oids]
        if missing:
            raise SystemExit(f"record_world: PR(s) {', '.join(missing)} are not in the open-PR snapshot")
        plan.reads += [Read(r, file_for(r)) for n in args.prs for r in board_per_pr(n, oids[n])]

    world = Path(args.out) / args.world
    staging = world.with_name(world.name + ".recording")
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)
    for read in plan.reads:
        if read.file not in answers:
            answers[read.file] = perform(read)
        (staging / read.file).write_bytes(answers[read.file])

    desc_commit = ""
    if plan.writes:  # a plan with no write reads no REST description and writes no schemas/
        desc_commit = args.rest_description or description_head()
        if args.description_file:
            if not args.rest_description:
                raise SystemExit("record_world: --description-file needs --rest-description, the commit it is a copy of")
            desc = json.loads(Path(args.description_file).read_text("utf-8"))
        else:
            desc = description(desc_commit)
        (staging / "schemas").mkdir()
        for w in plan.writes:
            for status in w.statuses:
                schema = schema_for(desc, w.operation_id, status)
                schema["$comment"] = schema["$comment"].replace("{commit}", desc_commit)
                (staging / "schemas" / f"{w.op}.{status}.json").write_text(json.dumps(schema, indent=2, ensure_ascii=False) + "\n")

    meta = {
        "world": args.world,
        "repo": REPO,
        "visibility": visibility,
        "items": [int(n) for n in args.prs],
        "recorded_at": datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "recorder": "islands/scan/scripts/record_world.py",
        "recorder_commit": commit,
        **({"rest_description": {"repo": DESCRIPTION_REPO, "commit": desc_commit, "file": DESCRIPTION_FILE}} if plan.writes else {}),
    }
    (staging / "provenance.yaml").write_text(provenance_text(meta, plan.reads, plan.writes))
    if (world / "writes").is_dir():  # the hand-written answers survive a re-record
        shutil.copytree(world / "writes", staging / "writes")
    shutil.rmtree(world, ignore_errors=True)
    staging.rename(world)
    print(f"record_world: {args.world} — {len(plan.reads)} reads, {sum(len(w.statuses) for w in plan.writes)} schemas → {world}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
