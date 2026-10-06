#!/usr/bin/env bash
# renovate-lane-lint — run Renovate ITSELF over this checkout and assert that every branch it would
# open lands in exactly one lane. The mermaid-lint shape (the real parser over the real input): the
# config validator checks syntax, this checks what the rule engine DOES with it.
#
# Why: Renovate arms a grouped branch only when EVERY member has `automerge: true`
# (lib/workers/repository/updates/generate.ts — `config.automerge = upgrades.every(u => u.automerge)`),
# while labels are the UNION of the members'. A group whose members disagree is born lane-labelled
# but un-armed, and an un-armed non-major Renovate PR has no reader: the review reflex admits armed
# PRs only, the coordinator's un-armed clause admits `major` only (gap register G15 — #2295 sat 16 h
# green and untouched; docs/dependency-upgrades.md). The static config cannot show this: matching is
# per dependency, per update type, at lookup time. Only Renovate can.
#
# How: `renovate --platform=local --dry-run=lookup` (the local platform FORCES lookup: it reads the
# cwd, writes nothing to the tree, needs no platform token) at LOG_LEVEL=trace, where
# generateBranchConfig traces the member list of every branch it computes — each member with the
# `automerge` + `labels`/`addLabels` the packageRules resolved for it. The JSON report
# (`reportType`) is NOT usable: the local platform never reaches the write phase that fills it, and
# the report strips upgrades to dashboard fields with no `automerge` anyway (checked in 41.x/44.x).
#
# Cost: ~2 min and a lookup against every datasource (Docker Hub, GitHub releases, Helm repos) —
# the FU-130 WAN class, so this is a SEAT verb run before landing a change to
# .github/renovate-global.json, not a CI check (operator, 2026-10-06). `GITHUB_COM_TOKEN` (falls
# back to `gh auth token`) keeps the github-releases lookups off the anonymous 60/h limit.
#
# Invariants (one branch = one PR):
#   mixed-arm     members disagree on `automerge`           → the branch arms false (every) — G15
#   mixed-lane    members carry different lane label sets   → one PR, two contracts
#   unarmed-lane  lane-labelled (`automerge`/`deps-review`), no `major`, yet automerge false
#   no-lane       no lane label at all — the #1988 "unlabelled class" nobody owns
#   two-lanes     one member carries both `automerge` and `deps-review`
# Majors are not asserted either way: ADR-141's armed-major rules make both states legitimate.
#
# ⚠ COMMIT FIRST: the local platform lists the tree through git, so an UNTRACKED file is invisible
# to it — the first #2348 run (2026-10-06) extracted 340 deps and showed the new CRD Application's
# group with one member; the same run on the committed tree extracted 341 and showed both.
# Usage: devbox run renovate-lane-lint            # run renovate, then assert (prints the branch table)
#        … -- --trace FILE                        # assert on an existing trace (no renovate run)
#        … -- --self-test                         # the fixture: one good group, one legit major, one of each violation
set -euo pipefail
cd "$(dirname "$0")/.."

cfg=.github/renovate-global.json
trace=''; selftest=0
while [ $# -gt 0 ]; do
  case "$1" in
    --trace) trace="$2"; shift 2 ;;
    --self-test) selftest=1; shift ;;
    *) echo "renovate-lane-lint: unknown argument $1" >&2; exit 2 ;;
  esac
done

if [ "$selftest" = 1 ]; then
  trace=scripts/renovate-lane-lint.fixture.jsonl
fi

if [ -z "$trace" ]; then
  command -v renovate >/dev/null || { echo "renovate-lane-lint: renovate not on PATH — run under devbox" >&2; exit 2; }
  trace="$(mktemp -t renovate-lane-lint.XXXXXX)"
  export GITHUB_COM_TOKEN="${GITHUB_COM_TOKEN:-${GH_TOKEN:-$(gh auth token 2>/dev/null || true)}}"
  echo "renovate-lane-lint: renovate $(renovate --version) --platform=local --dry-run=lookup over $PWD ($cfg) — ~2 min, WAN lookups" >&2
  rc=0
  LOG_LEVEL=trace LOG_FORMAT=json \
  RENOVATE_PLATFORM=local RENOVATE_DRY_RUN=lookup \
  RENOVATE_CONFIG_FILE="$PWD/$cfg" RENOVATE_REQUIRE_CONFIG=optional RENOVATE_ONBOARDING=false \
    renovate >"$trace" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ]; then
    echo "renovate-lane-lint: renovate exited $rc — last log lines:" >&2
    tail -n 5 "$trace" | cut -c1-400 >&2
    exit 1
  fi
  echo "renovate-lane-lint: trace at $trace" >&2
fi

python3 - "$trace" "$selftest" <<'PY'
import json, sys
path, selftest = sys.argv[1], sys.argv[2] == "1"
LANE = {"automerge", "deps-review", "major", "major/awaiting-human"}
branches, stats, depcount, result = [], None, None, ""
for line in open(path, encoding="utf-8", errors="replace"):
    try:
        j = json.loads(line)
    except ValueError:
        continue
    msg = j.get("msg", "")
    if msg == "generateBranchConfig" and isinstance(j.get("config"), list) and j["config"]:
        branches.append(j["config"])
    elif msg == "Dependency extraction complete":
        stats = j.get("stats") or {}
        depcount = (stats.get("total") or {}).get("depCount")
    elif msg.startswith("Repository result:"):
        result = msg

if not selftest and not depcount:
    print("renovate-lane-lint: FAIL — no 'Dependency extraction complete' stats in the trace (renovate did not run to the lookup phase)")
    sys.exit(1)
if not selftest and not branches:
    # A run that aborts between lookup and branch generation (2026-10-06: one ECONNRESET on a
    # github-releases lookup → `Repository result: external-host-error`) leaves ZERO branches and would
    # otherwise pass vacuously — the lookups succeeded, nothing was asserted. Fail loudly; re-run.
    print(f"renovate-lane-lint: FAIL — zero branches computed after {depcount} extracted dependencies; nothing was asserted ({result or 'no Repository result line'}) — a lookup aborted the run, re-run")
    sys.exit(1)

def lane(u):
    return frozenset(set((u.get("labels") or []) + (u.get("addLabels") or [])) & LANE)

rows, violations = [], []
for ups in branches:
    name = ups[0].get("branchName", "?")
    arms = [bool(u.get("automerge")) for u in ups]
    lanes = [lane(u) for u in ups]
    every = all(arms)
    union = frozenset().union(*lanes)
    members = "; ".join(
        f"{u.get('manager')}:{u.get('depName')}:{u.get('updateType')}:am={'T' if a else 'F'}:{','.join(sorted(l)) or '-'}"
        for u, a, l in zip(ups, arms, lanes))
    rows.append((name, every, union, members))
    if len(set(arms)) > 1:
        violations.append((name, "mixed-arm", "members disagree on automerge → the branch arms false (G15)"))
    if len(set(lanes)) > 1:
        violations.append((name, "mixed-lane", "members carry different lane label sets"))
    if (union & {"automerge", "deps-review"}) and "major" not in union and not every:
        violations.append((name, "unarmed-lane", "lane-labelled, no major, yet automerge false — no reader will ever pick it"))
    if not union:
        violations.append((name, "no-lane", "no lane label — the un-owned class (#1988)"))
    if any({"automerge", "deps-review"} <= l for l in lanes):
        violations.append((name, "two-lanes", "one member carries both automerge and deps-review"))

print(f"renovate-lane-lint: {len(branches)} branch(es) computed" + (f" from {depcount} extracted dependencies" if depcount else ""))
for name, every, union, members in rows:
    print(f"  {name[:48]:48} arm={'T' if every else 'F'} lane={','.join(sorted(union)) or '-':30} {members}")
if violations:
    print(f"renovate-lane-lint: FAIL — {len(violations)} violation(s):")
    for name, kind, why in violations:
        print(f"  {kind:13} {name}: {why}")
    if selftest:
        want = {"mixed-arm", "mixed-lane", "unarmed-lane", "no-lane", "two-lanes"}
        got = {k for _, k, _ in violations}
        good = {n for n, e, u, _ in rows} - {n for n, _, _ in violations}
        if got == want and good == {"renovate/good-group", "renovate/major-ok"}:
            print("renovate-lane-lint: self-test OK (every violation class fired once, the good group passed)")
            sys.exit(0)
        print(f"renovate-lane-lint: self-test FAILED — fired {sorted(got)}, clean {sorted(good)}")
    sys.exit(1)
if selftest:
    print("renovate-lane-lint: self-test FAILED — the fixture produced no violations")
    sys.exit(1)
print("renovate-lane-lint: OK — every branch sits in one lane and arms as its labels say")
PY
