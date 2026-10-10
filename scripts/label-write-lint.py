#!/usr/bin/env python3
"""label-write-lint — no `gh pr|issue edit --add-label/--remove-label` in agents/.

    devbox run label-write-lint                  (scan agents/; exit 1 + file:line on a hit)
    devbox run label-write-lint -- --self-test   (the detector against its own fixture table)
    devbox run label-write-lint -- FILE…         (scan just these files)

THE CLASS (FU-290, homelab#2476). The porcelain label flags of `gh pr edit` / `gh issue edit` are
GraphQL MUTATIONS (addLabelsToLabelable / removeLabelsFromLabelable). The homelab-agents App
installation's GraphQL pool drains under load (FU-290; drained 2026-10-10 19:00Z) while its REST
(core) pool still serves — and every porcelain label write in the loop then failed, behind call
sites that discarded gh's stderr (`>/dev/null 2>&1`) or printed a guessed cause ("token lacks
issues:write?"). #2476 sat armed + DIRTY with no merge-conflict label because of it.

THE RULE. Label writes go through the ONE REST transport, `gh_label_add` / `gh_label_rm` in
agents/machine-comment.sh (`gh api -X POST repos/<slug>/issues/<n>/labels`, `-X DELETE
…/labels/<label>`), which prints gh's real error on failure. Shell that cannot source it (a prompt
the model runs, embedded Argo shell) spells the same REST call out.

SCOPE: every tracked file under agents/ except Markdown and agents/replay/fixtures/** (recorded
expected streams of the porcelain era and fixture prose — data, not code). Backslash
continuations are joined (`gh pr edit "$n" \\` / `  --add-label x`); comment lines are skipped. A
Python argv list (`["gh", "pr", "edit", …, "--add-label", …]`) is caught too. Other gh porcelain
mutations (`pr comment`, `issue close`, `pr merge`) ride GraphQL as well and are NOT this lint's
business — this one holds the label class, the one FU-290 measured.
"""
import os
import re
import subprocess
import sys

# Files whose sites convert in their own change, with the reason. Hits there are listed, never
# fatal; an entry whose file is clean prints a STALE notice — delete it then. Shrink-only: a NEW
# file never goes here (convert it instead).
PENDING = {
    "agents/coordinator/responder-argo.yaml":
        "embedded Argo shell (cannot source machine-comment.sh); the reopen strip is a rare per-reopen "
        "write beside GraphQL `gh issue comment/close` — converts with its file's GraphQL sweep",
    "agents/coordinator/deploy-revert-argo.yaml":
        "embedded Argo shell; each label write sits between `gh pr create` and `gh pr merge --auto`, "
        "both GraphQL, so REST-ing the label alone keeps the revert lane no more drain-proof",
}

SHELL_RE = re.compile(r"\bgh\s+(?:pr|issue)\s+edit\b[^;&|]*?--(?:add|remove)-label\b")
PY_RE = re.compile(r"""["']gh["']\s*,\s*["'](?:pr|issue)["']\s*,\s*["']edit["'][^\]]*?["']--(?:add|remove)-label["']""")


def logical_lines(text):
    """[(first_lineno, joined_text)] with backslash continuations joined."""
    out, buf, start = [], "", None
    for n, raw in enumerate(text.split("\n"), 1):
        line = raw.rstrip("\r")
        if start is None:
            start = n
        s = line.rstrip()
        if s.endswith("\\") and not s.endswith("\\\\"):
            buf += s[:-1] + " "
            continue
        out.append((start, buf + line))
        buf, start = "", None
    if buf:
        out.append((start, buf))
    return out


def scan_text(text):
    hits = []
    for lineno, line in logical_lines(text):
        if line.lstrip().startswith("#"):
            continue
        if SHELL_RE.search(line) or PY_RE.search(line):
            hits.append((lineno, line.strip()))
    return hits


def in_scope(f):
    return (f.startswith("agents/") and not f.endswith(".md")
            and not f.startswith("agents/replay/fixtures/"))


FIXTURES = [
    ('gh pr edit "$u" --repo "$slug" --add-label agent/arbitrate >/dev/null 2>&1', True),
    ('if gh issue edit "$n" --repo "$s" --remove-label "agent/queued" >/dev/null 2>&1; then', True),
    ('gh pr edit "$PR" --repo "$SLUG" --add-label automerge --add-label dependencies || exit 1', True),
    ('gh pr edit "$n" --repo "$REPO" \\\n    --add-label merge-conflict', True),
    ('x=1 && gh issue edit 5 --title t --remove-label agent/error', True),
    ('  run  gh pr edit ${PR} --add-label agent/error  (your token has issues:write)', True),
    ('rc, _, err = runner.run(["gh", "pr", "edit", n, "--repo", s, "--add-label", "automerge"])', True),
    ('gh_label_add "$slug" "$u" agent/arbitrate', False),
    ('gh api -X POST "repos/$slug/issues/$n/labels" -f "labels[]=agent/error"', False),
    ('gh api -X DELETE "repos/$slug/issues/$n/labels/agent%2Ferror"', False),
    ('# gh pr edit "$u" --add-label agent/arbitrate — the old GraphQL form', False),
    ('gh pr edit "$u" --repo "$slug" --body "$b" >/dev/null 2>&1', False),
    ('gh issue edit "$n" --repo "$s" --body-file /tmp/b.md && echo "--add-label is GraphQL"', False),
    ('gh pr view "$n" --json labels  # then --add-label elsewhere', False),
]


def self_test():
    bad = 0
    for snippet, want in FIXTURES:
        got = bool(scan_text(snippet))
        if got != want:
            bad += 1
            print(f"FAIL want={want} got={got}: {snippet}")
    print(f"label-write-lint self-test: {len(FIXTURES) - bad}/{len(FIXTURES)} pass")
    return 1 if bad else 0


def main(argv):
    if argv[:1] == ["--self-test"]:
        return self_test()
    root = subprocess.check_output(["git", "rev-parse", "--show-toplevel"]).decode().strip()
    if argv:
        files = argv
    else:
        tracked = subprocess.check_output(["git", "-C", root, "ls-files", "-z", "agents/"]).decode().split("\0")
        files = sorted(f for f in tracked if f and in_scope(f) and os.path.isfile(os.path.join(root, f)))
    if not files:
        print("label-write-lint: PROBE-FAIL — zero files under agents/ (git ls-files broken?)", file=sys.stderr)
        return 2
    total = pending = 0
    for f in files:
        with open(os.path.join(root, f) if not os.path.isabs(f) else f, errors="replace") as h:
            found = scan_text(h.read())
        for lineno, line in found:
            if f in PENDING:
                pending += 1
                print(f"{f}:{lineno}: PENDING ({PENDING[f][:60]}…): {line[:140]}")
            else:
                total += 1
                print(f"{f}:{lineno}: {line[:200]}")
        if f in PENDING and not found and not argv:
            print(f"label-write-lint: STALE exemption — {f} is clean now; delete its PENDING entry")
    if total:
        print(f"label-write-lint: FAIL — {total} porcelain label write(s) (`gh pr|issue edit "
              "--add-label/--remove-label`, a GraphQL mutation — FU-290). Use gh_label_add / gh_label_rm "
              "(agents/machine-comment.sh), or spell the REST call out where it cannot be sourced. "
              "Why: scripts/label-write-lint.py docstring.", file=sys.stderr)
        return 1
    print(f"label-write-lint: ok ({len(files)} files under agents/, 0 porcelain label writes"
          + (f"; {pending} pending in {len(PENDING)} exempted file(s)" if pending else "") + ")")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
