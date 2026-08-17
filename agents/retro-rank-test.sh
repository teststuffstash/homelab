#!/usr/bin/env bash
# retro-rank-test — the BEHAVIOUR pin for the retro's pain-rank step (retro-argo.yaml →
# agents/retro-rank.py). Registered as agents/replay/fixtures/retro-rank-snapshot-exclusion.
#
# WHAT IT PINS (retro r4 F5, homelab PR#454): rows stamped mid-flight (`snapshot: true` — the
# issue was still OPEN at emit time) are NOT terminal facts, so the pain-rank EXCLUDES them from
# the order and from the brief, and counts the exclusion loudly instead of silently letting the
# deep-dive budget land on already-converged work. Rows without the field (every historical row)
# rank normally; the historical `rounds` INT shape and the new per-round ARRAY shape both rank by
# count (the emitter changed `rounds` int→array, and the whole ledger is read every run).
#
# THE EXPECTED VALUES ARE COMPUTED FROM THE INPUTS + THE CONTRACT (the sort key in
# retro-rank.py: blocked first, then rounds desc, then cost desc, then wall desc; KEEP=2), never
# from running the rank — an expectation derived by running the code pins the code's bugs.
set -uo pipefail
cd "$(dirname "$0")/.."

RANK="agents/retro-rank.py"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }

for t in python3 jq; do
  command -v "$t" >/dev/null 2>&1 || { echo "retro-rank-test: needs $t (run under devbox)" >&2; exit 2; }
done
[ -f "$RANK" ] || { echo "retro-rank-test: $RANK not found" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── the ranked-input world (small, constructed) ────────────────────────────────────────────────
# Row S: blocked + 3 rounds + $9.9 + 999s — WOULD be rank 1 on the contract sort, but
#         `snapshot: true` (issue still OPEN at emit time) must exclude it entirely.
# Row A: blocked, `rounds` as the HISTORICAL INT (2) — the int/list compatibility row.
# Row B: done, `rounds` as the new ARRAY (2 entries), $0.9.
# Row C: done, `rounds` array (1 entry), $0.1 — rank 3, cut by KEEP=2.
cat > "$TMP/ledger.jsonl" <<'JSONL'
{"key":"snap#1","terminal_label":"agent/blocked","rounds":[{"round":1,"model":"a","exit_status":"","error_class":"","ci":false},{"round":2,"model":"b","exit_status":"","error_class":"auth-storm","ci":false},{"round":3,"model":"c","exit_status":"","error_class":"auth-storm","ci":false}],"total_cost_usd":9.9,"wall_time_s":999,"snapshot":true}
{"key":"proj#a","terminal_label":"agent/blocked","rounds":2,"total_cost_usd":0.5,"wall_time_s":50}
{"key":"proj#b","terminal_label":"agent/done","rounds":[{"round":1,"model":"d","exit_status":"clean","error_class":"","ci":true},{"round":2,"model":"d","exit_status":"clean","error_class":"","ci":true}],"total_cost_usd":0.9,"wall_time_s":90}
{"key":"proj#c","terminal_label":"agent/done","rounds":[{"round":1,"model":"e","exit_status":"clean","error_class":"","ci":true}],"total_cost_usd":0.1,"wall_time_s":10}
JSONL

# KEEP=2 — the deep-dive slice size, shrunk so the cut lands inside this tiny world.
out="$(python3 "$RANK" "$TMP/ledger.jsonl" "$TMP/ranked.json" 2 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then
  bad "retro-rank.py exited $rc on the constructed ledger" "$out"
  printf '\n  %s passed, %s failed\n' "$PASS" "$FAIL"; exit 1
fi

# 1. the snapshot row must NOT appear anywhere in the ranked brief (not even below top-K).
if jq -e '[.[].key] | index("snap#1")' "$TMP/ranked.json" >/dev/null 2>&1; then
  bad "snapshot row snap#1 appeared in the ranked brief" \
      "r4 F5: mid-flight rows are not terminal facts — they must be excluded, not ranked."
else
  ok "snapshot row snap#1 excluded from the ranked brief"
fi

# 2. rank order + top-K cut. Contract: blocked first; within bucket, rounds desc then cost desc.
#    S excluded; A (blocked, 2 rounds) → 1; B (done, 2 rounds) → 2; C (done, 1 round) → 3, cut.
keys="$(jq -r '.[].key' "$TMP/ranked.json" | tr '\n' ' ')"
ranks="$(jq -r '.[].rank' "$TMP/ranked.json" | tr '\n' ' ')"
if [ "$keys" = "proj#a proj#b " ]; then
  ok "top-2 = [proj#a proj#b] (blocked first, then done; proj#c cut by KEEP)"
else
  bad "top-2 keys unexpected" "want 'proj#a proj#b ', got '$keys'"
fi
if [ "$ranks" = "1 2 " ]; then
  ok "ranks are dense and sequential over the rankable set (1, 2)"
else
  bad "ranks unexpected" "want '1 2 ', got '$ranks'"
fi
# the HISTORICAL int `rounds` row (proj#a) ranked first among rankable — int/list both count.
if jq -e '.[0].key == "proj#a" and .[0].rounds == 2' "$TMP/ranked.json" >/dev/null 2>&1; then
  ok "historical int-rounds row proj#a ranked by count (int/list compatibility)"
else
  bad "historical int-rounds row ranked wrong" "proj#a should be rank 1 via round_count(int)=2"
fi

# 3. the no-silent-caps log line names the exclusion count.
if printf '%s' "$out" | grep -q 'excluded 1 snapshot rows from the rank'; then
  ok "log line counts the exclusion: 'excluded 1 snapshot rows from the rank'"
else
  bad "exclusion not logged loudly" "no 'excluded 1 snapshot rows' in: $out"
fi

printf '\n  %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
