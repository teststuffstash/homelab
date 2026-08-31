#!/usr/bin/env bash
# ledger-emitter-test — the BEHAVIOUR pin for the retro-facts ledger emitter (agents/ledger.py),
# the r4 F4/F5 row-schema fixes (homelab PR#454). Registered as
# agents/replay/fixtures/ledger-emitter-rounds (mode: suite).
#
# WHAT IT PINS, against a CONSTRUCTED manifest world (never live S3/GitHub — the reflex's S3
# seam and gh seam are stubbed, the real summarize()/merge_rounds()/is_snapshot()/main() code
# runs):
#   F4  — `rounds[]` is round-ordered with strike-only entries included; `models` /
#         `worker_exit_statuses` / `ci_sequence` are DERIVED from it order-preservingly (the old
#         `models` set broke zip() joins).
#   F5  — a row stamped while the issue is still OPEN is `snapshot: true`.
#
# EVERY EXPECTED VALUE IS COMPUTED FROM THE CONSTRUCTED INPUTS + THE CONTRACT (the ledger row
# schema in ledger.py), never read back from the code under test.
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }

command -v python3 >/dev/null 2>&1 || { echo "ledger-emitter-test: needs python3 (run under devbox)" >&2; exit 2; }
[ -f agents/ledger.py ] || { echo "ledger-emitter-test: agents/ledger.py not found" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/emitter_test.py" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.path.join(os.getcwd(), "agents"))
import ledger

PASSED = []
def check(cond, label):
    if not cond:
        raise SystemExit("FAIL: %s" % label)
    PASSED.append(label)
    print("OK: " + label)

# ── the constructed manifest world (the input, not the logic under test) ────────────────────
# worker manifests: rounds 1/2/3 (r2 carries stats.error_class), plus one reviewer manifest.
# homelab#795: manifests now carry a "rail" field when available (agent-finalize folds
# AGENT_RAIL from agent-runtime#81). r1 has no rail (older manifest — tests prefix derivation
# fallback); r2 has rail="opencode-go" (tests recorded-rail branch with fold to subscription);
# r3 has no rail (tests prefix derivation for claude/ model → subscription);
# r4 has rail="openrouter" with model="claude/haiku" (tests recorded wins over prefix — the
# prefix would derive "subscription" but the recorded rail says "openrouter" → folded to
# "openrouter").
MANIFESTS = {
    "worker-r1-20260817T000000Z/manifest.json": {
        "role": "worker", "round": 1, "model": "model-a", "exit_status": "clean",
        "stats": {"ci_passed": True, "cost_usd": 0.10, "queue_wait_s": 5, "duration_s": 100,
                  "pr_url": "https://github.com/org/proj/pull/1"},
    },
    "worker-r2-20260817T010000Z/manifest.json": {
        "role": "worker", "round": 2, "model": "model-b", "exit_status": "no-artifact",
        "rail": "opencode-go",
        "stats": {"ci_passed": None, "cost_usd": 0.05, "queue_wait_s": 2, "duration_s": 60,
                  "error_class": "unknown"},
    },
    "worker-r3-20260817T020000Z/manifest.json": {
        "role": "worker", "round": 3, "model": "claude/haiku", "exit_status": "clean",
        "stats": {"ci_passed": True, "cost_usd": 0.20, "queue_wait_s": 1, "duration_s": 40},
    },
    "worker-r4-20260817T030000Z/manifest.json": {
        "role": "worker", "round": 4, "model": "claude/haiku", "exit_status": "clean",
        "rail": "openrouter",
        "stats": {"ci_passed": True, "cost_usd": 0.30, "queue_wait_s": 1, "duration_s": 45},
    },
    "reviewer-r1-20260817T003000Z/manifest.json": {
        "role": "reviewer", "round": 1, "model": "reviewer-model",
    },
}

written_ledger = []

def fake_s5(args, key_id, key_secret):
    op = args[0]
    if op == "cp":
        src, dst = args[1], args[2]
        if dst == ledger.LEDGER and not src.startswith("s3://"):
            written_ledger.append(open(src).read())   # the writer put
            return ""
        return ""  # reader get of a (possibly absent) ledger -> tolerated as empty
    if op == "ls":
        # s5cmd ls rows: <mtime> <size> <key> — the KEY column is the path relative to the
        # listed prefix (the emitter reconstructs the full key as prefix + rel), so serve the
        # relative keys here.
        rels = [k for k in MANIFESTS if k.endswith("manifest.json")]
        return "".join("2026-08-17 00:00:00 123 %s\n" % k for k in sorted(rels))
    if op == "cat":
        rel = "/".join(args[1].split("/")[-2:])
        return json.dumps(MANIFESTS[rel])
    raise AssertionError("fake_s5 unexpected: %r" % (args,))

def fake_sh(args, env=None):
    if args[0] == "gh" and args[1] == "api":
        # gh api ... --jq '[.[] | .body]' returns an array of the comment BODIES. proj#7 has a
        # strike-only round 5, plus a duplicate round 2 (which already has a manifest ->
        # merge_rounds must keep the manifest entry). One non-strike comment must be ignored.
        return json.dumps([
            "AGENT_STRIKE: model=model-c error_class=auth-storm round=5 session=pod5\n\n<details>struck",
            "AGENT_STRIKE: model=model-b error_class=unknown round=2 session=pod2",
            "a plain human comment — no strike line",
        ])
    raise AssertionError("fake_sh unexpected: %r" % (args,))

ledger.s5 = fake_s5
ledger.sh = fake_sh

# ── 1. summarize(): manifest rounds, round-ordered, one per worker (F4 + homelab#795) ────
# Changes for #795:
#   r2: rail="opencode-go" recorded → _model_rail folds to "subscription"
#   r3: model changed to "claude/haiku" → prefix derivation → "subscription"
#   r4 (new): model="claude/haiku" with rail="openrouter" → recorded wins, yields "openrouter"
summ = ledger.summarize("proj", 7, "rid", "rsec")
check(summ is not None, "summarize found manifests for proj#7")
want_rounds = [
    {"round": 1, "model": "model-a", "rail": "openrouter", "exit_status": "clean", "error_class": "", "ci": True},
    # r2: recorded rail="opencode-go" folds to "subscription" — tests recorded-wins branch
    {"round": 2, "model": "model-b", "rail": "subscription", "exit_status": "no-artifact", "error_class": "unknown", "ci": None},
    # r3: model="claude/haiku" with no rail → prefix derivation → "subscription"
    {"round": 3, "model": "claude/haiku", "rail": "subscription", "exit_status": "clean", "error_class": "", "ci": True},
    # r4: model="claude/haiku" with rail="openrouter" → recorded wins → "openrouter" (folded)
    {"round": 4, "model": "claude/haiku", "rail": "openrouter", "exit_status": "clean", "error_class": "", "ci": True},
]
check(summ["rounds"] == want_rounds,
      "summarize rounds: r1 prefix-derived openrouter, r2 recorded rail folded to subscription, r3 prefix-derived subscription, r4 recorded rail wins over prefix")
check(summ["total_cost_usd"] == 0.65, "total_cost_usd = 0.10+0.05+0.20+0.30 = 0.65")
check(summ["reviewer_rounds"] == 1, "reviewer_rounds = 1")
check(summ["wall_time_s"] == 10800, "wall_time_s spans min(r1)..max(r4) = 3h = 10800s")
check(summ["pr_url"] == "https://github.com/org/proj/pull/1", "pr_url from the worker manifest")

# ── 2. merge_rounds(): strike-only rounds folded in, manifest wins on collision (F4 + #795) ─
strikes = [
    {"round": 5, "model": "model-c", "error_class": "auth-storm"},  # strike-only round (was r4, now r5 since manifest r4 exists)
    {"round": 2, "model": "model-b", "error_class": "unknown"},    # duplicate -> manifest wins
]
merged = ledger.merge_rounds(summ["rounds"], strikes)
want_merged = want_rounds + [
    {"round": 5, "model": "model-c", "rail": "openrouter", "exit_status": "", "error_class": "auth-storm", "ci": False},
]
check(merged == want_merged,
      "merge_rounds: strike-only round 5 appended, round 2 keeps its manifest entry (recorded rail wins)")

# ── 3. flat fields DERIVED from the merged rounds, order-preserving (F4 + #795) ────────────
models = [r["model"] for r in merged]
worker_exit_statuses = [r["exit_status"] for r in merged]
ci_sequence = [r["ci"] for r in merged]
check(models == ["model-a", "model-b", "claude/haiku", "claude/haiku", "model-c"],
      "models derived order-preserving (claude/haiku appears twice — once from prefix subscription, once from recorded openrouter)")
check(worker_exit_statuses == ["clean", "no-artifact", "clean", "clean", ""],
      "worker_exit_statuses aligned with rounds (strike round exit_status is empty)")
check(ci_sequence == [True, None, True, True, False],
      "ci_sequence aligned with rounds (strike round ci is False)")
retry_storms = sum(1 for v in ((r["exit_status"] or r["error_class"]) for r in merged) if v == "auth-storm" or v.startswith("budget-403"))
check(retry_storms == 1, "retry_storms counts the auth-storm strike-only round")

# ── 4. is_snapshot() matrix (F5) ────────────────────────────────────────────────────────────
check(ledger.is_snapshot("OPEN", "agent/blocked") is True,  "snapshot: issue still OPEN")
check(ledger.is_snapshot("OPEN", "agent/done") is True,     "snapshot: done label, issue not closed yet")
check(ledger.is_snapshot("CLOSED", "agent/done") is False,  "not a snapshot: closed + done = converged")
check(ledger.is_snapshot("CLOSED", "agent/blocked") is False,
      "not a snapshot: closed issue (blocked label stale, but not mid-flight)")

# ── 5. main() end-to-end: the assembled row carries rounds[] + derived flat + snapshot ──────
os.environ["AGENT_TS_READER_ID"] = "rid"
os.environ["AGENT_TS_READER_SECRET"] = "rsec"
os.environ["AGENT_TS_WRITER_ID"] = "wid"
os.environ["AGENT_TS_WRITER_SECRET"] = "wsec"
ledger.terminal_issues = lambda org, repos: [("proj", 7, "agent/blocked", "OPEN", None, "sm")]
ledger.repos_from_stacks = lambda: {"proj": "teststack"}
ledger.main()
check(len(written_ledger) == 1, "main wrote exactly one ledger line (empty prior ledger)")
row = json.loads(written_ledger[0].strip().splitlines()[0])
check(row["key"] == "proj#7" and row["terminal_label"] == "agent/blocked" and row["issue_state"] == "OPEN",
      "row identity fields (key/terminal_label/issue_state) intact")
check(row.get("snapshot") is True, "row marked snapshot: true (issue open at emit time)")
check(row["rounds"] == want_merged, "row rounds[] = merged per-round list")
check(row["models"] == ["model-a", "model-b", "claude/haiku", "claude/haiku", "model-c"],
      "row models order-preserving (both claude/haiku entries — r3 prefix-derived subscription, r4 recorded openrouter)")
check(row["worker_exit_statuses"] == ["clean", "no-artifact", "clean", "clean", ""],
      "row worker_exit_statuses aligned (r4 clean exit adds a new clean entry)")
check(row["ci_sequence"] == [True, None, True, True, False], "row ci_sequence aligned")
check(row["retry_storms"] == 1, "row retry_storms counts the strike-only auth-storm")
check(row["total_cost_usd"] == 0.65, "row total_cost_usd = 0.10+0.05+0.20+0.30 = 0.65")
check(row["budget_tier"] == "sm" and row["budget_cap_usd"] == 0.5, "row budget tier/cap present")
check(row["calibration_error"] == round(0.65 / (0.5 * 5), 3), "row calibration_error = 0.65/(0.5*5) — per-round utilisation, not cumulative")

# ── 6. _budget_from_cr() prefix-anchoring (homelab#929 r3) ──────────────────────────────
# The prefix must be anchored with "-round-" so issue "92" does not match
# "proj-issue-929-round-1". Two CRs: proj-issue-929-round-1 (tier md) and
# proj-issue-92-round-1 (tier xs). _budget_from_cr("proj", "92") must return
# 92's tier, not 929's.
def fake_sh_budget(args, env=None):
    if args[0] == "kubectl" and args[1] == "get" and args[2] == "openrouterkeys":
        return json.dumps({
            "items": [
                {"metadata": {"name": "proj-issue-929-round-1",
                              "labels": {"budget-tier": "md", "budget-estimate-usd": "0.50"}}},
                {"metadata": {"name": "proj-issue-92-round-1",
                              "labels": {"budget-tier": "xs", "budget-estimate-usd": "0.08"}}},
            ]
        })
    raise AssertionError("fake_sh_budget unexpected: %r" % (args,))

_saved_sh = ledger.sh
ledger.sh = fake_sh_budget

cr92 = ledger._budget_from_cr("proj", "92")
check(cr92 is not None, "_budget_from_cr('proj', '92') found a CR")
check(cr92[0] == "xs", "_budget_from_cr('proj', '92') returns tier xs (not md from 929)")
check(cr92[1] == 0.25, "_budget_from_cr('proj', '92') returns cap 0.25 (xs tier)")
check(cr92[2] == 0.08, "_budget_from_cr('proj', '92') returns estimate 0.08")

cr929 = ledger._budget_from_cr("proj", "929")
check(cr929 is not None, "_budget_from_cr('proj', '929') found a CR")
check(cr929[0] == "md", "_budget_from_cr('proj', '929') returns tier md")
check(cr929[1] == 1.0, "_budget_from_cr('proj', '929') returns cap 1.0 (md tier)")
check(cr929[2] == 0.50, "_budget_from_cr('proj', '929') returns estimate 0.50")

# No matching CR for issue 1 (no CR with prefix proj-issue-1-round-)
cr1 = ledger._budget_from_cr("proj", "1")
check(cr1 is None, "_budget_from_cr('proj', '1') returns None (no matching CR)")

# ── 7. _budget_from_cr() deterministic tie-break (homelab#987) ──────────────────────────
# When multiple CRs match the same issue prefix (multiple rounds), the function must
# return the highest round number's tier/estimate deterministically, not the first in
# kubectl's arbitrary item order.
def fake_sh_tiebreak(args, env=None):
    if args[0] == "kubectl" and args[1] == "get" and args[2] == "openrouterkeys":
        # Items in REVERSE round order to catch non-deterministic first-match.
        return json.dumps({
            "items": [
                {"metadata": {"name": "proj-issue-42-round-1",
                              "labels": {"budget-tier": "xs", "budget-estimate-usd": "0.08"}}},
                {"metadata": {"name": "proj-issue-42-round-3",
                              "labels": {"budget-tier": "md", "budget-estimate-usd": "0.50"}}},
                {"metadata": {"name": "proj-issue-42-round-2",
                              "labels": {"budget-tier": "sm", "budget-estimate-usd": "0.25"}}},
            ]
        })
    raise AssertionError("fake_sh_tiebreak unexpected: %r" % (args,))

ledger.sh = fake_sh_tiebreak

cr42 = ledger._budget_from_cr("proj", "42")
check(cr42 is not None, "_budget_from_cr('proj', '42') found a CR (tie-break test)")
check(cr42[0] == "md", "_budget_from_cr('proj', '42') returns tier md (highest round 3, not xs from round 1)")
check(cr42[1] == 1.0, "_budget_from_cr('proj', '42') returns cap 1.0 (md tier)")
check(cr42[2] == 0.50, "_budget_from_cr('proj', '42') returns estimate 0.50 (from round 3)")

# ── 8. _budget_from_cr() malformed label handling (homelab#988) ──────────────────────────
# A malformed budget-estimate-usd label (e.g. "abc") must not crash the function — the
# per-item processing is wrapped in try/except so the malformed CR is skipped loudly and
# other CRs are still considered.
def fake_sh_malformed(args, env=None):
    if args[0] == "kubectl" and args[1] == "get" and args[2] == "openrouterkeys":
        return json.dumps({
            "items": [
                {"metadata": {"name": "proj-issue-99-round-1",
                              "labels": {"budget-tier": "xs", "budget-estimate-usd": "abc"}}},
                {"metadata": {"name": "proj-issue-99-round-2",
                              "labels": {"budget-tier": "sm", "budget-estimate-usd": "0.25"}}},
            ]
        })
    raise AssertionError("fake_sh_malformed unexpected: %r" % (args,))

ledger.sh = fake_sh_malformed

cr99 = ledger._budget_from_cr("proj", "99")
check(cr99 is not None, "_budget_from_cr('proj', '99') found a CR despite malformed label on round 1")
check(cr99[0] == "sm", "_budget_from_cr('proj', '99') returns tier sm (from valid round 2, not crashed by round 1)")
check(cr99[1] == 0.5, "_budget_from_cr('proj', '99') returns cap 0.5 (sm tier)")
check(cr99[2] == 0.25, "_budget_from_cr('proj', '99') returns estimate 0.25 (from valid round 2)")

# All CRs malformed — must return None, not crash
def fake_sh_all_malformed(args, env=None):
    if args[0] == "kubectl" and args[1] == "get" and args[2] == "openrouterkeys":
        return json.dumps({
            "items": [
                {"metadata": {"name": "proj-issue-100-round-1",
                              "labels": {"budget-tier": "xs", "budget-estimate-usd": "abc"}}},
                {"metadata": {"name": "proj-issue-100-round-2",
                              "labels": {"budget-tier": "sm", "budget-estimate-usd": "xyz"}}},
            ]
        })
    raise AssertionError("fake_sh_all_malformed unexpected: %r" % (args,))

ledger.sh = fake_sh_all_malformed

cr100 = ledger._budget_from_cr("proj", "100")
check(cr100 is None, "_budget_from_cr('proj', '100') returns None when all CRs have malformed labels (no crash)")

ledger.sh = _saved_sh  # restore

# ── 9. Zero-round guard: reviewer-only task must not crash (F6 denominator guard) ──────────
# A task with only reviewer manifests (no worker manifests) reaches line 378 with rounds==[].
# The old expression (total_cost_usd / cap) was safe; the new one (total_cost_usd / (cap * len(rounds)))
# would ZeroDivisionError without the `and rounds` guard. The row must be emitted with
# calibration_error=None and no exception.
REVIEWER_ONLY_MANIFESTS = {
    "reviewer-r1-20260817T000000Z/manifest.json": {
        "role": "reviewer", "round": 1, "model": "reviewer-model",
    },
}

def fake_s5_reviewer_only(args, key_id, key_secret):
    op = args[0]
    if op == "cp":
        src, dst = args[1], args[2]
        if dst == ledger.LEDGER and not src.startswith("s3://"):
            written_ledger.append(open(src).read())
            return ""
        return ""
    if op == "ls":
        rels = [k for k in REVIEWER_ONLY_MANIFESTS if k.endswith("manifest.json")]
        return "".join("2026-08-17 00:00:00 123 %s\n" % k for k in sorted(rels))
    if op == "cat":
        rel = "/".join(args[1].split("/")[-2:])
        return json.dumps(REVIEWER_ONLY_MANIFESTS[rel])
    raise AssertionError("fake_s5_reviewer_only unexpected: %r" % (args,))

def fake_sh_no_strikes(args, env=None):
    if args[0] == "gh" and args[1] == "api":
        return json.dumps([])  # no strike comments
    raise AssertionError("fake_sh_no_strikes unexpected: %r" % (args,))

# Save state, set up reviewer-only world
_saved_s5 = ledger.s5
_saved_sh2 = ledger.sh
_saved_terminal = ledger.terminal_issues
_saved_repos = ledger.repos_from_stacks
ledger.s5 = fake_s5_reviewer_only
ledger.sh = fake_sh_no_strikes
ledger.terminal_issues = lambda org, repos: [("proj", 8, "agent/done", "CLOSED", "2026-08-17T040000Z", "sm")]
ledger.repos_from_stacks = lambda: {"proj": "teststack"}
written_ledger.clear()
try:
    ledger.main()
    check(len(written_ledger) == 1, "reviewer-only main wrote exactly one ledger line (no crash)")
    row8 = json.loads(written_ledger[0].strip().splitlines()[0])
    check(row8["key"] == "proj#8", "reviewer-only row key is proj#8")
    check(row8["calibration_error"] is None, "reviewer-only row calibration_error is None (no rounds to divide by)")
    check(row8["rounds"] == [], "reviewer-only row rounds is empty list")
    check(row8["total_cost_usd"] == 0.0, "reviewer-only row total_cost_usd is 0.0")
except Exception as e:
    bad("reviewer-only main crashed (zero-round guard missing)", str(e))
finally:
    ledger.s5 = _saved_s5
    ledger.sh = _saved_sh2
    ledger.terminal_issues = _saved_terminal
    ledger.repos_from_stacks = _saved_repos
PYEOF

out="$(python3 "$TMP/emitter_test.py" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then
  n="$(printf '%s\n' "$out" | grep -c '^OK:')"
  ok "ledger emitter row composition — $n checks (rounds order + strike merge + flat derivation + snapshot)"
else
  bad "ledger emitter row composition" "$out"
fi

printf '\n  %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
