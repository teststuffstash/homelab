"""Transport behind a Protocol: the updater sees typed reads + `write(mutation)`, never argv.

`GhCli`    — the real thing: one `subprocess.run(["gh", …])` site, one typed `GitHubError`.
`Recorded` — serves a replay WORLD directory with agents/replay/stubs/gh's key grammar and records
             every call as the harness's `CALL gh …` action line (agents/replay/stubs/_common.sh).

Both build argv from the SAME functions below, so a recorded stream pins the live argv too.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, Protocol

from gh_types import (PrCommits, PrCommitsReviews, PullRequest, RollupEntry, WireError,
                      parse_pr_list)

# ── errors ───────────────────────────────────────────────────────────────────────────────────────


class GitHubError(Exception):
    """gh exited non-zero (rc/stderr as gh gave them)."""

    def __init__(self, argv: list[str], rc: int, stderr: str, stdout: str = ""):
        super().__init__(f"gh {' '.join(argv[:3])} … rc={rc}: {stderr.strip()[:200]}")
        self.argv, self.rc, self.stderr, self.stdout = argv, rc, stderr, stdout


class Unreadable(GitHubError):
    """gh exited 0 but the body is not the JSON shape asked for (a proxy error page, `garbage`)."""

    def __init__(self, argv: list[str], stdout: str, cause: Exception):
        super().__init__(argv, 0, "", stdout)
        self.cause = cause


# ── mutations ────────────────────────────────────────────────────────────────────────────────────

Identity = Literal["merge", "label"]  # GH_TOKEN (homelab-merge) vs UPDATER_LABEL_TOKEN (coordinator-git)


@dataclass(frozen=True, slots=True)
class UpdateBranch:
    repo: str
    number: int
    expected_head_sha: str  # "" = flag omitted (the bash's ${oid:+…})
    identity: Identity = "merge"


@dataclass(frozen=True, slots=True)
class CreateLabel:
    repo: str
    name: str
    color: str
    description: str
    identity: Identity = "label"


@dataclass(frozen=True, slots=True)
class AddLabel:
    repo: str
    number: int
    label: str
    identity: Identity = "label"


@dataclass(frozen=True, slots=True)
class RemoveLabel:
    repo: str
    number: int
    label: str
    identity: Identity = "label"


@dataclass(frozen=True, slots=True)
class PatchBody:
    repo: str
    number: int
    body: str
    identity: Identity = "merge"


Mutation = UpdateBranch | CreateLabel | AddLabel | RemoveLabel | PatchBody


@dataclass(frozen=True, slots=True)
class WriteResult:
    stdout: str
    stderr: str


# ── argv: the ONE spelling of every call (shared by GhCli and Recorded) ─────────────────────────

PR_LIST_FIELDS = ("number,createdAt,mergeStateStatus,autoMergeRequest,reviewDecision,labels,headRefOid,"
                  "latestReviews,baseRefName,reviews,author,headRefName")
CHECK_RUNS_JQ = '[.check_runs[]? | {name, conclusion: ((.conclusion // .status // "") | ascii_upcase)}]'
STATUS_JQ = '[.statuses[]? | {context, state: ((.state // "") | ascii_upcase)}]'


def argv_pr_list(repo: str) -> list[str]:
    return ["pr", "list", "--repo", repo, "--state", "open", "--limit", "100", "--json", PR_LIST_FIELDS]


def argv_pr_view(repo: str, n: int, fields: str) -> list[str]:
    return ["pr", "view", str(n), "--repo", repo, "--json", fields]


def argv_check_runs(repo: str, sha: str) -> list[str]:
    return ["api", f"repos/{repo}/commits/{sha}/check-runs?per_page=100", "--jq", CHECK_RUNS_JQ]


def argv_statuses(repo: str, sha: str) -> list[str]:
    return ["api", f"repos/{repo}/commits/{sha}/status", "--jq", STATUS_JQ]


def argv_pr_body(repo: str, n: int) -> list[str]:
    return ["api", f"repos/{repo}/pulls/{n}", "--jq", '.body // ""']


def _label_uri(s: str) -> str:
    """machine-comment.sh _gh_label_uri: % / space # ? — in that order."""
    return s.replace("%", "%25").replace("/", "%2F").replace(" ", "%20").replace("#", "%23").replace("?", "%3F")


def mutation_argv(m: Mutation) -> list[str]:
    match m:
        case UpdateBranch(repo, n, sha):
            return ["api", "-X", "PUT", f"repos/{repo}/pulls/{n}/update-branch",
                    *(["-f", f"expected_head_sha={sha}"] if sha else [])]
        case CreateLabel(repo, name, color, desc):
            return ["api", "-X", "POST", f"repos/{repo}/labels",
                    "-f", f"name={name}", "-f", f"color={color}", "-f", f"description={desc}"]
        case AddLabel(repo, n, label):
            return ["api", "-X", "POST", f"repos/{repo}/issues/{n}/labels", "-f", f"labels[]={label}"]
        case RemoveLabel(repo, n, label):
            return ["api", "-X", "DELETE", f"repos/{repo}/issues/{n}/labels/{_label_uri(label)}"]
        case PatchBody(repo, n, body):
            return ["api", "-X", "PATCH", f"repos/{repo}/pulls/{n}", "-f", f"body={body}"]
    raise TypeError(m)


# ── the Protocol ─────────────────────────────────────────────────────────────────────────────────


class GitHub(Protocol):
    def pr_list(self, repo: str) -> tuple[PullRequest, ...]: ...
    def pr_commits(self, repo: str, n: int) -> PrCommits: ...
    def pr_commits_reviews(self, repo: str, n: int) -> PrCommitsReviews: ...
    def check_runs(self, repo: str, sha: str) -> tuple[RollupEntry, ...]: ...
    def commit_statuses(self, repo: str, sha: str) -> tuple[RollupEntry, ...]: ...
    def pr_body(self, repo: str, n: int) -> str: ...
    def write(self, mutation: Mutation) -> WriteResult: ...


# ── shared read decoding over an abstract exec ───────────────────────────────────────────────────


def _cmdsub(s: str) -> str:
    """`$(…)` strips ALL trailing newlines — the bash reads every body through one."""
    return s.rstrip("\n")


class _Transport:
    def _exec(self, argv: list[str], identity: Identity = "merge") -> tuple[int, str, str]:
        raise NotImplementedError

    def _read(self, argv: list[str]) -> str:
        rc, out, err = self._exec(argv)
        if rc != 0:
            raise GitHubError(argv, rc, err, out)
        return out

    def _json(self, argv: list[str]):
        out = self._read(argv)
        try:
            return json.loads(out)
        except ValueError as e:
            raise Unreadable(argv, out, e) from e

    def _typed(self, argv, parse):
        payload = self._json(argv)
        try:
            return parse(payload)
        except WireError as e:
            raise Unreadable(argv, json.dumps(payload), e) from e

    def pr_list(self, repo: str) -> tuple[PullRequest, ...]:
        return self._typed(argv_pr_list(repo), parse_pr_list)

    def pr_commits(self, repo: str, n: int) -> PrCommits:
        return self._typed(argv_pr_view(repo, n, "commits"), PrCommits.from_wire)

    def pr_commits_reviews(self, repo: str, n: int) -> PrCommitsReviews:
        return self._typed(argv_pr_view(repo, n, "commits,reviews"), PrCommitsReviews.from_wire)

    def _rollup(self, argv, make) -> tuple[RollupEntry, ...]:
        def parse(p):
            if not isinstance(p, list):
                raise WireError(argv[1], "<root>", f"is {type(p).__name__}, want array")
            return tuple(make(x) for x in p)
        return self._typed(argv, parse)

    def check_runs(self, repo: str, sha: str) -> tuple[RollupEntry, ...]:
        return self._rollup(argv_check_runs(repo, sha), RollupEntry.check_run)

    def commit_statuses(self, repo: str, sha: str) -> tuple[RollupEntry, ...]:
        return self._rollup(argv_statuses(repo, sha), RollupEntry.status)

    def pr_body(self, repo: str, n: int) -> str:
        return _cmdsub(self._read(argv_pr_body(repo, n)))

    def write(self, mutation: Mutation) -> WriteResult:
        argv = mutation_argv(mutation)
        rc, out, err = self._exec(argv, mutation.identity)
        if rc != 0:
            raise GitHubError(argv, rc, err, out)
        return WriteResult(out, err)


# ── GhCli: the live transport ────────────────────────────────────────────────────────────────────


class GhCli(_Transport):
    """`gh` on PATH. GH_TOKEN = the merge App token; label writes use UPDATER_LABEL_TOKEN when set
    (the bash's `${UPDATER_LABEL_TOKEN:-${GH_TOKEN:-}}`)."""

    def __init__(self, env: Mapping[str, str] | None = None, timeout_s: float = 60.0):
        self.env = dict(os.environ if env is None else env)
        self.timeout_s = timeout_s

    def _exec(self, argv: list[str], identity: Identity = "merge") -> tuple[int, str, str]:
        env = dict(self.env)
        if identity == "label":
            env["GH_TOKEN"] = env.get("UPDATER_LABEL_TOKEN") or env.get("GH_TOKEN", "")
        try:
            p = subprocess.run(["gh", *argv], check=True, capture_output=True, text=True,
                               timeout=self.timeout_s, env=env)
        except subprocess.CalledProcessError as e:
            return e.returncode, e.stdout or "", e.stderr or ""
        except subprocess.TimeoutExpired as e:
            return 124, "", f"gh: timed out after {self.timeout_s}s: {e}\n"
        return 0, p.stdout, p.stderr


# ── Recorded: the replay stub, in-process ───────────────────────────────────────────────────────

_VALUE_FLAGS = set("""-n --namespace -o --output --repo -R --json -q --jq -l --selector -f --filename
 -L --limit -H --header -X --method -F --field --template --kubeconfig --context --body --body-file
 --field-selector -c --container --label --search --author --base --head --add-label
 --remove-label --title --raw-field --input --hostname --cache --subresource --type -p --patch
 --owner --match""".split())
_MUTATING_VERBS = set("""comment edit close reopen merge review ready create delete rename transfer lock
unlock pin unpin sync develop checkout add remove set""".split())


def words(argv: list[str]) -> str:
    """_rp_words: the bare words — options and their values dropped."""
    out, skip = [], False
    for a in argv:
        if skip:
            skip = False
            continue
        if a.startswith("--") and "=" in a:
            continue
        if a.startswith("-"):
            skip = a in _VALUE_FLAGS
            continue
        out.append(a)
    return " ".join(out)


def slug(s: str) -> str:
    """_rp_slug: lowercase, runs of [^a-z0-9] → '-', trimmed."""
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def record_arg(a: str) -> str:
    """_rp_record's per-arg escape: `printf '%s' | sed ':a;N;$!ba;s/\\n/\\\\n/g'` inside `$(…)`.
    Embedded newlines → a literal backslash-n; ONE trailing newline is eaten as sed's line
    terminator (so `"x\\n"` records as `x`, `"x\\n\\n"` as `x\\n`)."""
    parts = a.split("\n")
    if a.endswith("\n"):
        parts = parts[:-1]
    return "\\n".join(parts)


class Recorded(_Transport):
    """Serves `world/gh/<slug>[.json|.txt|]` (longest bare-word prefix first) and appends one
    `CALL gh …` line per invocation to `self.calls`. Env semantics are the stub's: STUB_GH (global
    fail|body404|garbage), STUB_GH_<slug_with_underscores> (per call, + `empty`), STUB_GH_GRAPHQL.
    `--jq` is evaluated with the real jq binary, exactly as the stub does."""

    FAULT_TEXT = {"fail": (1, "", "gh: Not Found (HTTP 404)\n"),
                  "empty": (0, "", ""),
                  "body404": (0, "gh: Not Found (HTTP 404)\n", ""),
                  "garbage": (0, "upstream connect error or disconnect/reset before headers\n", "")}

    def __init__(self, world: Path, env: Mapping[str, str], fields_tsv: Path, jq: str | None = None):
        self.world = Path(world)
        self.env = dict(env)
        self.calls: list[str] = []
        self.jq = jq or os.environ.get("JQ") or shutil.which("jq") or "jq"
        self.fields: dict[str, set[str]] = {}
        for line in Path(fields_tsv).read_text(encoding="utf-8").splitlines():
            if "\t" in line and not line.startswith("#"):
                cmd, flds = line.split("\t", 1)
                self.fields[cmd] = set(flds.split(","))

    def _serve(self, key: str) -> str | None:
        k = key
        while k:
            for ext in (".json", ".txt", ""):
                f = self.world / "gh" / f"{slug(k)}{ext}"
                if f.is_file():
                    return f.read_text(encoding="utf-8")
            k = k.rsplit(" ", 1)[0] if " " in k else ""
        return None

    def _die_unrecorded(self, key: str) -> tuple[int, str, str]:
        return 9, "", (f"replay-stub[gh]: no recorded world file for this READ.\n  call:  gh {key}\n")

    def _exec(self, argv: list[str], identity: Identity = "merge") -> tuple[int, str, str]:
        self.calls.append("CALL gh" + "".join(" " + record_arg(a) for a in argv))
        w = words(argv)
        if not w:
            return 9, "", "replay-stub[gh]: bare `gh` with no subcommand\n"
        # --json field validation (gh refuses unknown fields before the wire)
        jf = next((argv[i + 1] for i, a in enumerate(argv[:-1]) if a == "--json"), None)
        jf = next((a.split("=", 1)[1] for a in argv if a.startswith("--json=")), jf)
        if jf:
            cmd = " ".join(w.split()[:2])
            allowed = self.fields.get(cmd)
            if allowed is None:
                return 9, "", f"replay-stub[gh]: `gh {cmd} --json` has no field list\n"
            bad = next((f for f in jf.split(",") if f and f not in allowed), None)
            if bad:
                return 1, "", f'Unknown JSON field: "{bad}"\nAvailable fields:\n' + "".join(
                    f"  {x}\n" for x in sorted(allowed))
        s = slug(w)
        pc = self.env.get("STUB_GH_" + s.replace("-", "_"), "")
        if pc:
            if pc not in self.FAULT_TEXT:
                return 9, "", f"replay-stub[gh]: unknown per-call override value: {pc}\n"
            return self.FAULT_TEXT[pc]
        is_write = False
        if w.split()[0] == "api":
            prev = ""
            for a in argv:
                if prev in ("-X", "--method") and a != "GET":
                    is_write = True
                if a in ("-XGET", "--method=GET"):
                    pass
                elif (a.startswith("-X") and len(a) > 2) or a.startswith("--method="):
                    is_write = True
                if a in ("-f", "--field", "-F", "--raw-field", "--input"):
                    is_write = True
                prev = a
        if w == "api graphql" or w.startswith("api graphql "):
            is_write = any(a.startswith("query=") and re.sub(r"[ \t\n]", "", a[6:]).startswith("mutation")
                           for a in argv)
        verb_mut = any(x in _MUTATING_VERBS for x in w.split()[:3])
        if self.env.get("STUB_GH_GRAPHQL", "ok") == "drained":
            gql_mut = (w.startswith("api graphql") and is_write) or (w.split()[0] in ("pr", "issue") and verb_mut)
            if gql_mut:
                return 1, "", "GraphQL: API rate limit already exceeded for installation ID 142724430\n"
        if is_write or verb_mut:
            return 0, self._serve(w) or "", ""
        g = self.env.get("STUB_GH", "ok")
        if g in ("fail", "body404", "garbage"):
            return self.FAULT_TEXT[g]
        jq_expr = None
        for i, a in enumerate(argv):
            if a in ("--jq", "-q") and i + 1 < len(argv):
                jq_expr = argv[i + 1]
            elif a.startswith("--jq="):
                jq_expr = a.split("=", 1)[1]
        body = self._serve(w)
        if body is None:
            return self._die_unrecorded(w)
        if jq_expr is not None:
            # the stub: body served into a variable (`$(…)` strips trailing newlines), then
            # `printf '%s' "$body" | jq -r EXPR`
            p = subprocess.run([self.jq, "-r", jq_expr], input=_cmdsub(body), capture_output=True, text=True)
            return p.returncode, p.stdout, p.stderr
        return 0, body, ""
