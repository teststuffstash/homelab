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
MANIFESTS = {
    "worker-r1-20260817T000000Z/manifest.json": {
        "role": "worker", "round": 1, "model": "model-a", "exit_status": "clean",
        "stats": {"ci_passed": True, "cost_usd": 0.10, "queue_wait_s": 5, "duration_s": 100,
                  "pr_url": "https://github.com/org/proj/pull/1"},
    },
    "worker-r2-20260817T010000Z/manifest.json": {
        "role": "worker", "round": 2, "model": "model-b", "exit_status": "no-artifact",
        "stats": {"ci_passed": None, "cost_usd": 0.05, "queue_wait_s": 2, "duration_s": 60,
                  "error_class": "unknown"},
    },
    "worker-r3-20260817T020000Z/manifest.json": {
        "role": "worker", "round": 3, "model": "model-a", "exit_status": "clean",
        "stats": {"ci_passed": True, "cost_usd": 0.20, "queue_wait_s": 1, "duration_s": 40},
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
        # strike-only round 4, plus a duplicate round 2 (which already has a manifest ->
        # merge_rounds must keep the manifest entry). One non-strike comment must be ignored.
        return json.dumps([
            "AGENT_STRIKE: model=model-c error_class=auth-storm round=4 session=pod4\n\n<details>struck",
            "AGENT_STRIKE: model=model-b error_class=unknown round=2 session=pod2",
            "a plain human comment — no strike line",
        ])
    raise AssertionError("fake_sh unexpected: %r" % (args,))

ledger.s5 = fake_s5
ledger.sh = fake_sh

# ── 1. summarize(): manifest rounds, round-ordered, one per worker (F4) ─────────────────────
summ = ledger.summarize("proj", 7, "rid", "rsec")
check(summ is not None, "summarize found manifests for proj#7")
want_rounds = [
    {"round": 1, "model": "model-a", "rail": "openrouter", "exit_status": "clean", "error_class": "", "ci": True},
    {"round": 2, "model": "model-b", "rail": "openrouter", "exit_status": "no-artifact", "error_class": "unknown", "ci": None},
    {"round": 3, "model": "model-a", "rail": "openrouter", "exit_status": "clean", "error_class": "", "ci": True},
]
check(summ["rounds"] == want_rounds,
      "summarize rounds are round-ordered with model/rail/exit_status/error_class/ci per manifest")
check(summ["total_cost_usd"] == 0.35, "total_cost_usd = 0.10+0.05+0.20 = 0.35")
check(summ["reviewer_rounds"] == 1, "reviewer_rounds = 1")
check(summ["wall_time_s"] == 7200, "wall_time_s spans min(r1)..max(r3) = 2h = 7200s")
check(summ["pr_url"] == "https://github.com/org/proj/pull/1", "pr_url from the worker manifest")

# ── 2. merge_rounds(): strike-only rounds folded in, manifest wins on collision (F4) ────────
strikes = [
    {"round": 4, "model": "model-c", "error_class": "auth-storm"},  # strike-only round
    {"round": 2, "model": "model-b", "error_class": "unknown"},    # duplicate -> manifest wins
]
merged = ledger.merge_rounds(summ["rounds"], strikes)
want_merged = want_rounds + [
    {"round": 4, "model": "model-c", "rail": "openrouter", "exit_status": "", "error_class": "auth-storm", "ci": False},
]
check(merged == want_merged,
      "merge_rounds: strike-only round 4 appended, round 2 keeps its manifest entry")

# ── 3. flat fields DERIVED from the merged rounds, order-preserving (F4) ────────────────────
models = [r["model"] for r in merged]
worker_exit_statuses = [r["exit_status"] for r in merged]
ci_sequence = [r["ci"] for r in merged]
check(models == ["model-a", "model-b", "model-a", "model-c"],
      "models derived order-preserving, dedup REMOVED (model-a appears twice)")
check(worker_exit_statuses == ["clean", "no-artifact", "clean", ""],
      "worker_exit_statuses aligned with rounds (strike round exit_status is empty)")
check(ci_sequence == [True, None, True, False],
      "ci_sequence aligned with rounds (strike round ci is False)")
retry_storms = sum(1 for r in merged if (r["exit_status"] or r["error_class"]) in ("auth-storm", "budget-403"))
check(retry_storms == 1, "retry_storms counts the auth-storm strike-only round")

# ── 4. is_snapshot() matrix (F5) ────────────────────────────────────────────────────────────
check(ledger.is_snapshot("open", "agent/blocked") is True,  "snapshot: issue still OPEN")
check(ledger.is_snapshot("open", "agent/done") is True,     "snapshot: done label, issue not closed yet")
check(ledger.is_snapshot("closed", "agent/done") is False,  "not a snapshot: closed + done = converged")
check(ledger.is_snapshot("closed", "agent/blocked") is False,
      "not a snapshot: closed issue (blocked label stale, but not mid-flight)")

# ── 5. main() end-to-end: the assembled row carries rounds[] + derived flat + snapshot ──────
os.environ["AGENT_TS_READER_ID"] = "rid"
os.environ["AGENT_TS_READER_SECRET"] = "rsec"
os.environ["AGENT_TS_WRITER_ID"] = "wid"
os.environ["AGENT_TS_WRITER_SECRET"] = "wsec"
ledger.terminal_issues = lambda org, repos: [("proj", 7, "agent/blocked", "open", None, "sm")]
ledger.repos_from_stacks = lambda: {"proj": "teststack"}
ledger.main()
check(len(written_ledger) == 1, "main wrote exactly one ledger line (empty prior ledger)")
row = json.loads(written_ledger[0].strip().splitlines()[0])
check(row["key"] == "proj#7" and row["terminal_label"] == "agent/blocked" and row["issue_state"] == "open",
      "row identity fields (key/terminal_label/issue_state) intact")
check(row.get("snapshot") is True, "row marked snapshot: true (issue open at emit time)")
check(row["rounds"] == want_merged, "row rounds[] = merged per-round list")
check(row["models"] == ["model-a", "model-b", "model-a", "model-c"], "row models order-preserving")
check(row["worker_exit_statuses"] == ["clean", "no-artifact", "clean", ""], "row worker_exit_statuses aligned")
check(row["ci_sequence"] == [True, None, True, False], "row ci_sequence aligned")
check(row["retry_storms"] == 1, "row retry_storms counts the strike-only auth-storm")
check(row["total_cost_usd"] == 0.35, "row total_cost_usd still the manifest-only sum")
check(row["budget_tier"] == "sm" and row["budget_cap_usd"] == 0.5, "row budget tier/cap present")
check(row["calibration_error"] == round(0.35 / 0.5, 3), "row calibration_error = 0.35/0.5")

print("\n%d checks passed" % len(PASSED))
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
