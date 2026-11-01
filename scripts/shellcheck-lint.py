#!/usr/bin/env python3
"""shellcheck-lint — ShellCheck (`-S warning`) over the tracked shell glue, ratcheted by a baseline.

    devbox run shellcheck-lint                  (lint every tracked shell file; exit 1 on a NEW finding)
    devbox run shellcheck-lint -- --update      (rewrite the baseline from the current tree)
    devbox run shellcheck-lint -- --self-test   (the ratchet's comparison + parser against fixtures)

THE RULE (ADR-113, FU-185): bash is glue, and ShellCheck at severity warning is the gate that holds
it — the shell-language defect class is disproportionately the SILENT kind (SC2318 named the exact
`local`-expansion bug that killed every model-scout tick for six days, #854).

THE RATCHET. The tree carried ~160 standing warnings when the gate landed, several of them in ADR-103
clause files that cannot change without a pinning replay fixture — so a one-PR burn-down was not
mechanical. `scripts/shellcheck-baseline.txt` records the standing count per (file, SC code); a
finding the baseline does not cover fails, a count BELOW the baseline is reported (shrink it with
`--update` in the PR that fixed the warning). Counting per (file, code) rather than per line keeps the
baseline stable under unrelated edits; the cost is that a new finding of a code a file already
carries hides behind a fixed one of the same code — acceptable for a burn-down ratchet.

SCOPE: every tracked `*.sh` / `*.bash` file, plus extensionless tracked files whose shebang names
sh/bash/dash (githooks/pre-push), MINUS `agents/replay/**` (fixtures and stubs deliberately mimic
foreign tools). Shell embedded in YAML (Argo workflows, .github/workflows) is not scanned.

MEMORY (homelab#3094). The gate runs inside 4Gi worker pods (`diff-ci` selects it on any `.sh` diff),
so it runs WITHOUT ShellCheck's dataflow analysis (`--extended-analysis=false`): with it, the one
7k-line `agents/coordinator-scan.sh` peaks at ~4.3 GiB (42 s); without it, 144 MiB (9 s). Every
worker OOMKill after this gate landed was that peak, and none happened in the two weeks before it.
Measured on the whole tree on 2026-11-01, dataflow added NO finding: both modes give the same 145
baselined findings. Parallelism follows the cgroup's CPU quota, not the host's core count (a pod on
the 40-core ride node would otherwise fan out 40 ShellChecks).
"""
import collections
import concurrent.futures
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE = os.path.join(ROOT, "scripts", "shellcheck-baseline.txt")
EXCLUDE = re.compile(r"^agents/replay/")
SHEBANG = re.compile(rb"^#!.*\b(ba|da)?sh\b")


def tracked_shell_files():
    out = subprocess.run(["git", "-C", ROOT, "ls-files", "-z"], check=True, capture_output=True).stdout
    files = []
    for f in out.decode().split("\0"):
        if not f or EXCLUDE.search(f) or not os.path.isfile(os.path.join(ROOT, f)):
            continue
        if f.endswith((".sh", ".bash")):
            files.append(f)
        elif "." not in os.path.basename(f):
            with open(os.path.join(ROOT, f), "rb") as fh:
                if SHEBANG.match(fh.readline()):
                    files.append(f)
    return sorted(files)


def _shellcheck_one(f, cwd):
    """json1 comments for one file. Exit 1 = findings (normal); anything else is the tool failing."""
    p = subprocess.run(["shellcheck", "-S", "warning", "--extended-analysis=false", "-f", "json1", f],
                       cwd=cwd, capture_output=True)
    if p.returncode not in (0, 1):
        sys.stderr.write(p.stderr.decode())
        raise SystemExit(f"shellcheck-lint: shellcheck itself failed on {f} (rc={p.returncode})")
    return json.loads(p.stdout or b'{"comments":[]}')["comments"]


def workers(cpu_max=None, host=None):
    """Parallelism = the cgroup v2 CPU quota (`/sys/fs/cgroup/cpu.max`: "<quota> <period>" or "max
    <period>"), rounded up, capped at the host's count; no quota or no file → the host's count."""
    host = host or os.cpu_count() or 4
    if cpu_max is None:
        try:
            with open("/sys/fs/cgroup/cpu.max") as fh:
                cpu_max = fh.read()
        except OSError:
            return host
    parts = cpu_max.split()
    if len(parts) != 2 or parts[0] == "max":
        return host
    try:
        quota, period = int(parts[0]), int(parts[1])
    except ValueError:
        return host
    if quota <= 0 or period <= 0:
        return host
    return max(1, min(host, -(-quota // period)))


def run_shellcheck(files, cwd=ROOT):
    """One process per file, in parallel: the 7k-line clause files dominate a serial run."""
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers()) as pool:
        return [c for cs in pool.map(lambda f: _shellcheck_one(f, cwd), files) for c in cs]


def count(comments):
    return collections.Counter((c["file"], f"SC{c['code']}") for c in comments)


def read_baseline(path=BASELINE):
    base = collections.Counter()
    if not os.path.exists(path):
        return base
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            f, code, n = line.split()
            base[(f, code)] = int(n)
    return base


def write_baseline(counts, path=BASELINE):
    with open(path, "w") as fh:
        fh.write("# shellcheck-lint baseline (FU-185, ADR-113): standing `-S warning` findings per file + code.\n")
        fh.write("# A count may only go DOWN — regenerate with `devbox run shellcheck-lint -- --update`.\n")
        for (f, code), n in sorted(counts.items()):
            fh.write(f"{f} {code} {n}\n")


def compare(current, base):
    """(over, under): over = (key, have, allowed) beyond the baseline; under = (key, have, allowed) below it."""
    over = [(k, n, base.get(k, 0)) for k, n in sorted(current.items()) if n > base.get(k, 0)]
    under = [(k, current.get(k, 0), n) for k, n in sorted(base.items()) if current.get(k, 0) < n]
    return over, under


def self_test():
    fails = 0

    def check(name, got, want):
        nonlocal fails
        ok = got == want
        fails += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {name}" + ("" if ok else f": got {got!r}, want {want!r}"))

    C = collections.Counter
    # compare(): expectations derived from the rule "over = current count > baseline count (absent = 0)".
    check("new file+code is over", compare(C({("a.sh", "SC2034"): 1}), C()), ([(("a.sh", "SC2034"), 1, 0)], []))
    check("equal is clean", compare(C({("a.sh", "SC2034"): 2}), C({("a.sh", "SC2034"): 2})), ([], []))
    check("growth is over", compare(C({("a.sh", "SC2034"): 3}), C({("a.sh", "SC2034"): 2})),
          ([(("a.sh", "SC2034"), 3, 2)], []))
    check("fixed is under, not over", compare(C(), C({("a.sh", "SC2034"): 2})), ([], [(("a.sh", "SC2034"), 0, 2)]))
    check("same code in another file is over", compare(C({("b.sh", "SC2034"): 1}), C({("a.sh", "SC2034"): 1})),
          ([(("b.sh", "SC2034"), 1, 0)], [(("a.sh", "SC2034"), 0, 1)]))

    # workers(): expectations from the cpu.max format (cgroup v2 docs: "$MAX $PERIOD", MAX may be
    # "max") — the ride pod's `cpu: "6"` limit renders "600000 100000" → 6 on a 40-core node.
    check("pod quota caps a 40-core host", workers("600000 100000\n", 40), 6)
    check("fractional quota rounds up", workers("50000 100000\n", 40), 1)
    check("no quota keeps the host count", workers("max 100000\n", 40), 40)
    check("quota above the host is capped", workers("1600000 100000\n", 8), 8)
    check("unparseable falls back to the host", workers("garbage", 8), 8)
    # The parser against the real tool: an unused variable is SC2034 at warning (ShellCheck wiki), a
    # missing `|| exit` after cd is SC2164 — two findings, one per code, in the one file.
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "t.sh"), "w") as fh:
            fh.write("#!/bin/bash\nunused=1\ncd /tmp\n")
        with open(os.path.join(d, "clean.sh"), "w") as fh:
            fh.write('#!/bin/bash\necho "ok"\n')
        got = count(run_shellcheck(["t.sh", "clean.sh"], cwd=d))
        check("parser counts per file+code", got, C({("t.sh", "SC2034"): 1, ("t.sh", "SC2164"): 1}))
        p = os.path.join(d, "base.txt")
        write_baseline(got, p)
        check("baseline round-trips", read_baseline(p), got)

    print(f"shellcheck-lint self-test: {'PASS' if not fails else f'{fails} FAILED'}")
    return 1 if fails else 0


def main(argv):
    if argv[:1] == ["--self-test"]:
        return self_test()
    files = tracked_shell_files()
    comments = run_shellcheck(files)
    current = count(comments)
    if argv[:1] == ["--update"]:
        write_baseline(current)
        print(f"shellcheck-lint: baseline rewritten — {sum(current.values())} findings in {len({f for f, _ in current})} files")
        return 0
    over, under = compare(current, read_baseline())
    for (f, code), have, allowed in under:
        print(f"note: {f} {code} {have} < baseline {allowed} — shrink it: devbox run shellcheck-lint -- --update")
    if over:
        keys = {k for k, _, _ in over}
        for c in sorted(comments, key=lambda c: (c["file"], c["line"])):
            if (c["file"], f"SC{c['code']}") in keys:
                print(f"{c['file']}:{c['line']}:{c['column']}: {c['level']}: {c['message']} [SC{c['code']}]")
        for (f, code), have, allowed in over:
            print(f"::error::shellcheck-lint: {f} {code} {have} > baseline {allowed}")
        print("Fix the finding (preferred) or, for a true false positive, an inline `# shellcheck disable=SCnnnn  # why`.")
        return 1
    print(f"shellcheck-lint: OK — {len(files)} files, {sum(current.values())} baselined findings")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
