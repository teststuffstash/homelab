"""A stand-in process for the sequence driver's tests — NOT a component (goal #3656 pin 3 / child 1).

    python tests/standin.py read  <owner/repo> <number>            print the bodies of the issue's comments, one JSON list
    python tests/standin.py write <owner/repo> <number> <body>     post one comment through `gh api`; exit as gh does
    python tests/standin.py list-open <owner/repo>                 print "<number> <headRefName>" per open pull request
"""

from __future__ import annotations

import json
import subprocess
import sys


def gh(*argv: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["gh", *argv], capture_output=True, text=True, check=False)


def main(argv: list[str]) -> int:
    cmd, repo = argv[0], argv[1]
    if cmd == "read":
        p = gh("api", f"repos/{repo}/issues/{argv[2]}/comments?per_page=100")
        if p.returncode:
            sys.stderr.write(p.stderr)
            return p.returncode
        print(json.dumps([c["body"] for c in json.loads(p.stdout)]))
        return 0
    if cmd == "write":
        p = gh("api", "-X", "POST", f"repos/{repo}/issues/{argv[2]}/comments", "-f", f"body={argv[3]}")
        sys.stderr.write(p.stderr)
        return p.returncode
    if cmd == "list-open":
        p = gh("pr", "list", "--repo", repo, "--state", "open", "--limit", "100", "--json",
               "number,title,labels,reviewDecision,autoMergeRequest,mergeStateStatus,author,headRefName,body,baseRefName,headRefOid")
        if p.returncode:
            sys.stderr.write(p.stderr)
            return p.returncode
        for pr in json.loads(p.stdout):
            print(pr["number"], pr["headRefName"])
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
