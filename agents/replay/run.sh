#!/usr/bin/env bash
# agents/replay/run.sh — the clause-replay harness (ADR-103 leg 1, homelab#206).
#
#   bash agents/replay/run.sh                                  # every fixture
#   bash agents/replay/run.sh agents/replay/fixtures/state-fp   # one
#   bash agents/replay/run.sh -v <fixture>                      # keep the fixture's own output
#
# WHY THIS EXISTS. Four executed replays now gate the loop's own logic (state-fp, rail-degrade,
# reviewer-optout, the responder harness) and each hand-rolled the same three things: sentinel
# extraction out of the shipped script, PATH-shim `gh`/`kubectl` that serve recorded JSON and
# record mutations, and an assertion vocabulary. ADR-103 makes an executed replay the RATCHET for
# every changed clause — so that machinery stops being a thing you copy 300 lines of and becomes a
# thing you point a fixture directory at. The goal-lifecycle clause work (#207, #208) and the
# debounce-store move are the first callers.
#
# WHAT A FIXTURE IS. A directory with a `fixture.yaml` and, for the declarative mode, a `world/`
# of RECORDED API responses and an `expected/actions.txt`. Fixtures are committed recordings and
# never live calls: CI runs offline (the e2e-cold-cache lesson), and a replay that can reach the
# network is a replay that goes green for the wrong reason.
#
# WHAT IT ASSERTS ON. The ACTION STREAM — the calls a clause makes and the lines it emits — never
# its internal variables. A clause stays refactorable; only its observable behaviour is pinned.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
STUBS="$HERE/stubs"
FIXROOT="$HERE/fixtures"
VERBOSE=0

for t in awk sed diff jq; do
  command -v "$t" >/dev/null 2>&1 || { echo "clause-replay: needs $t (devbox run -- bash $0)"; exit 2; }
done

# ── fixture.yaml ────────────────────────────────────────────────────────────────────────────────
# A deliberately tiny YAML subset — `key: value` and `key:` followed by `- item` lines, no nesting.
# Not laziness: the harness is the thing every other gate leans on, so it depends on nothing but
# bash and awk. Anything outside the subset is a hard parse error rather than a silent skip, which
# is the failure mode a "close enough" parser has.
parse_fixture() {   # parse_fixture <file> → "S\tkey\tvalue" / "L\tkey\titem" lines
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^[A-Za-z_][A-Za-z0-9_]*:/ {
      k = $0; sub(/:.*/, "", k)
      v = $0; sub(/^[^:]*:[[:space:]]*/, "", v)
      sub(/[[:space:]]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^'"'"'.*'"'"'$/) v = substr(v, 2, length(v) - 2)
      cur = k
      if (v != "") printf "S\t%s\t%s\n", k, v
      next
    }
    /^[[:space:]]+-[[:space:]]*/ {
      v = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", v)
      sub(/[[:space:]]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^'"'"'.*'"'"'$/) v = substr(v, 2, length(v) - 2)
      if (cur == "") { printf "E\t%d\tlist item before any key\n", NR; next }
      printf "L\t%s\t%s\n", cur, v
      next
    }
    { printf "E\t%d\t%s\n", NR, $0 }
  ' "$1"
}
fx_scalar() { printf '%s\n' "$FXY" | awk -F'\t' -v k="$1" '$1=="S" && $2==k { print $3; exit }'; }
fx_list()   { printf '%s\n' "$FXY" | awk -F'\t' -v k="$1" '$1=="L" && $2==k { print $3 }'; }

# ── reporting ───────────────────────────────────────────────────────────────────────────────────
# A fixture declaring `expect: fail` is a PROBE-FAIL self-test (the check's-author rule, #168): a
# deliberately-broken fixture whose whole job is to prove the harness reds. While one runs, ok()/
# bad() are diverted into SELFTEST_* rather than the tally — so a self-test that goes green is
# itself a failure, and one that reds for the WRONG reason is caught by `expect_detail:`.
PASS=0; FAIL=0; FAILED=(); EXPECT_FAIL=0; SELFTEST_HIT=0; SELFTEST_DETAIL=''
ok()   { [ "$EXPECT_FAIL" = 1 ] && return 0
         PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; return 0; }
bad()  { if [ "$EXPECT_FAIL" = 1 ]; then
           SELFTEST_HIT=1; SELFTEST_DETAIL="${SELFTEST_DETAIL}${1}
${2:-}"
           return 0
         fi
         FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  \033[31m✗\033[0m %s\n' "$1"
         [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; return 0; }

# ── the sentinel extractor, the one piece every existing replay already hand-rolls ──────────────
# Leading whitespace is trimmed before the comparison: blocks live deep inside per-repo loops, and
# a column-0 marker in the middle of an indented `if` reads as a mistake to the next editor.
extract() {   # extract <marker-name> <file> → stdout; exit 3 if either sentinel is missing
  awk -v n="$1" '
    { line = $0; sub(/^[ \t]+/, "", line) }
    line == "# >>>REPLAY:" n ">>>" { inb = 1; saw_open  = 1; next }
    line == "# <<<REPLAY:" n "<<<" { inb = 0; saw_close = 1; next }
    inb { print }
    END { if (!saw_open || !saw_close) exit 3 }
  ' "$2"
}

# ── mode: suite ─────────────────────────────────────────────────────────────────────────────────
# An existing self-asserting replay, registered so `run.sh` with no arguments is the single entry
# point for every clause pin. It keeps its own file, its own devbox script and its own required
# status — the harness runs it, it does not rewrite it.
run_suite() {   # run_suite <fixture-dir> <name>
  local dir="$1" name="$2" entry rc log
  entry="$(fx_scalar entrypoint)"
  [ -n "$entry" ] || { bad "$name: fixture.yaml has no \`entrypoint:\`"; return 0; }
  [ -f "$ROOT/$entry" ] || { bad "$name: entrypoint not found: $entry"; return 0; }
  log="$TMP/$name.log"
  ( cd "$ROOT" && bash "$entry" ) > "$log" 2>&1; rc=$?
  [ "$VERBOSE" = 1 ] && sed 's/^/    /' "$log"
  [ "$rc" = 0 ] && ok "$name (suite) — $(grep -c '✓' "$log"; true) assertions, exit 0" \
                || bad "$name (suite): exit $rc" "$(tail -40 "$log")"
  return 0
}

# ── mode: actions ───────────────────────────────────────────────────────────────────────────────
# Recorded world in, expected actions out. The clause is COMPOSED at run time from blocks extracted
# out of the shipped script by sentinel — never transcribed, because a transcribed clause pins a
# copy and goes green while the original drifts (#166).
run_actions() {   # run_actions <fixture-dir> <name>
  local dir="$1" name="$2" src part comp bin act rc detail nparts=0
  comp="$TMP/$name.clause.sh"; act="$TMP/$name.actions"; bin="$TMP/$name.bin"
  mkdir -p "$bin"
  cp "$STUBS/gh" "$STUBS/kubectl" "$bin/" && chmod +x "$bin/gh" "$bin/kubectl"

  src="$(fx_scalar source)"
  # Every composition opens with the scan's own `set -euo pipefail`, so "this survives -e" is
  # asserted by every fixture rather than claimed once.
  printf 'set -euo pipefail\n' > "$comp"
  while IFS= read -r part; do
    [ -n "$part" ] || continue
    case "$part" in
      block:*)
        [ -n "$src" ] || { bad "$name: \`block:\` part needs a \`source:\`"; return 0; }
        [ -f "$ROOT/$src" ] || { bad "$name: \`source:\` not found: $src"; return 0; }
        if ! extract "${part#block:}" "$ROOT/$src" > "$TMP/$name.block"; then
          bad "$name: sentinel >>>REPLAY:${part#block:}>>> / <<<REPLAY:${part#block:}<<< missing from $src" \
              "The block moved or the markers were deleted. Restore them around the block — this fixture pins behaviour it cannot find."
          return 0
        fi
        # A block that extracts EMPTY still composes into valid shell and still passes `bash -n`,
        # so it would assert nothing while looking green. Loud, not lenient.
        [ -s "$TMP/$name.block" ] || { bad "$name: block \`${part#block:}\` extracted EMPTY from $src"; return 0; }
        cat "$TMP/$name.block" >> "$comp" ;;
      file:*)
        [ -f "$dir/${part#file:}" ] || { bad "$name: part file not found: ${part#file:}"; return 0; }
        cat "$dir/${part#file:}" >> "$comp" ;;
      *) bad "$name: part must be \`block:<sentinel>\` or \`file:<name.sh>\`, got: $part"; return 0 ;;
    esac
    nparts=$((nparts + 1))
    printf '\n' >> "$comp"
  done <<< "$(fx_list parts)"

  [ "$nparts" -gt 0 ] || { bad "$name: fixture.yaml lists no \`parts:\` — nothing to replay"; return 0; }
  if ! bash -n "$comp" 2> "$TMP/$name.syntax"; then
    bad "$name: the composed clause is not valid shell — a block boundary is wrong" "$(cat "$TMP/$name.syntax")"
    return 0
  fi

  : > "$act"
  local -a envs=()
  while IFS= read -r e; do [ -n "$e" ] && envs+=("$e"); done <<< "$(fx_list env)"
  ( cd "$dir" && env "${envs[@]+"${envs[@]}"}" \
      REPLAY_WORLD="$dir/world" REPLAY_ACTIONS="$act" REPLAY_STUB_DIR="$STUBS" \
      REPLAY_FIXTURE="$dir" REPLAY_ROOT="$ROOT" PATH="$bin:$PATH" \
      bash "$comp" ) > "$TMP/$name.out" 2> "$TMP/$name.err"
  rc=$?

  # The action file is the CALL stream, then the clause's stdout, then its stderr, then the exit
  # code. Each stream is in its own natural order; the INTERLEAVING between them is deliberately
  # not asserted — stdio buffering makes it non-deterministic, and no clause's contract rests on
  # whether a log line landed before or after the call it describes.
  sed 's/^/OUT /' "$TMP/$name.out" >> "$act"
  sed 's/^/ERR /' "$TMP/$name.err" >> "$act"
  printf 'RC %s\n' "$rc" >> "$act"

  # Volatile substrings (mktemp paths, the checkout root) get scrubbed before the diff, or every
  # fixture reds on a machine that is not the one it was recorded on.
  local scrubbed="$TMP/$name.actions.scrubbed"
  sed -e "s#${TMP//#/\\#}#\$TMP#g" -e "s#${ROOT//#/\\#}#\$ROOT#g" "$act" > "$scrubbed"
  while IFS= read -r s; do
    [ -n "$s" ] && { sed "$s" "$scrubbed" > "$scrubbed.n" && mv "$scrubbed.n" "$scrubbed"; }
  done <<< "$(fx_list scrub)"

  if [ ! -f "$dir/expected/actions.txt" ]; then
    bad "$name: no expected/actions.txt — here is what the clause did (review it, then commit it)" \
        "$(cat "$scrubbed")"
    return 0
  fi
  detail="$(diff -u "$dir/expected/actions.txt" "$scrubbed" 2>&1)"
  [ -z "$detail" ] && ok "$name (actions) — $(grep -c . "$scrubbed") actions match" \
                   || bad "$name (actions): the action stream moved" "$detail"
  [ "$VERBOSE" = 1 ] && sed 's/^/    /' "$scrubbed"
  return 0
}

# ── driver ──────────────────────────────────────────────────────────────────────────────────────
run_fixture() {
  local dir name mode expect
  # Absolute, always: the fixture is run with `cd $dir`, so a relative argument would leave
  # $REPLAY_WORLD pointing at nothing and the fixture would red for the harness's reason instead
  # of the clause's — a false red is only marginally better than a false green.
  dir="$(cd "${1%/}" 2>/dev/null && pwd)" || dir=''
  [ -n "$dir" ] || { bad "$(basename "${1%/}"): not a directory: $1"; return 0; }
  [ -f "$dir/fixture.yaml" ] || { bad "$(basename "$dir"): no fixture.yaml in $dir"; return 0; }
  FXY="$(parse_fixture "$dir/fixture.yaml")"
  if printf '%s\n' "$FXY" | grep -q '^E	'; then
    bad "$(basename "$dir"): fixture.yaml has lines outside the supported subset" \
        "$(printf '%s\n' "$FXY" | awk -F'\t' '$1=="E" { printf "line %s: %s\n", $2, $3 }')"
    return 0
  fi
  name="$(fx_scalar name)"; [ -n "$name" ] || name="$(basename "$dir")"
  mode="$(fx_scalar mode)"; expect="$(fx_scalar expect)"; expect="${expect:-pass}"
  [ "$expect" = fail ] && { EXPECT_FAIL=1; SELFTEST_HIT=0; SELFTEST_DETAIL=''; }
  case "$mode" in
    suite)   run_suite   "$dir" "$name" ;;
    actions) run_actions "$dir" "$name" ;;
    '')      bad "$name: fixture.yaml has no \`mode:\` (want \`suite\` or \`actions\`)" ;;
    *)       bad "$name: unknown mode \`$mode\` (want \`suite\` or \`actions\`)" ;;
  esac
  [ "$expect" = fail ] || return 0

  # ── the PROBE-FAIL verdict ────────────────────────────────────────────────────────────────────
  EXPECT_FAIL=0
  local want; want="$(fx_scalar expect_detail)"
  if [ "$SELFTEST_HIT" != 1 ]; then
    bad "$name: PROBE-FAIL SELF-TEST DID NOT FIRE — a fixture broken on purpose went GREEN" \
        "The detector this fixture exists to prove is not working, so every other fixture's green is worth less than it looks."
  elif [ -n "$want" ] && ! printf '%s' "$SELFTEST_DETAIL" | grep -qF -- "$want"; then
    bad "$name: red-cased, but NOT for the declared reason" \
        "wanted the report to contain: $want
what the harness actually said:
$SELFTEST_DETAIL"
  else
    ok "$name (expect: fail) — the harness red-cased it${want:+: $want}"
  fi
  return 0
}

# ── the generated index (FU-167 cleanup move 3) ────────────────────────────────────────────────
# One derived table: fixture · mode · source · the FSM transitions that pin it (reverse-mapped
# from the three FSM yamls' `replay:` lists — the yamls stay the model home, this is a VIEW).
# The hand-appended family register was the tree's one real merge-conflict surface (PR#275);
# a generated block cannot both-sides-append. The full run checks currency, so a fixture change
# that forgets `--index --write` reds in CI instead of drifting.
INDEX_BEGIN='<!-- replay-index:begin — generated by `run.sh --index --write`; never hand-edit -->'
INDEX_END='<!-- replay-index:end -->'

gen_index() {
  local pins; pins="$(mktemp)"
  for y in "$ROOT"/docs/agents/*-fsm.yaml; do
    awk '/^  - id: /{id=$3}
         /agents\/replay\/fixtures\//{
           line=$0; sub(/.*agents\/replay\/fixtures\//,"",line); sub(/[^A-Za-z0-9_-].*/,"",line)
           if (line != "" && id != "") print line "\t" id }' "$y"
  done | sort -u > "$pins"
  printf '| fixture | mode | source | pinned by (FSM) |\n|---|---|---|---|\n'
  local d n mode src ids FXY
  for d in "$FIXROOT"/*/; do
    [ -d "$d" ] || continue
    n="$(basename "$d")"
    # the harness's OWN parser (PR#381 review): a bespoke awk here would render a future quoted
    # `source: "…"` differently than the harness reads it — one parser, one truth. `local FXY`
    # shadows the global bash-dynamically, so fx_scalar reads this fixture, and a run_fixture
    # loop's own FXY is untouched.
    FXY="$(parse_fixture "$d/fixture.yaml" 2>/dev/null)" || FXY=""
    mode="$(fx_scalar mode)"
    src="$(fx_scalar source)"
    ids="$(awk -F'\t' -v n="$n" '$1==n{print $2}' "$pins" | sort -u | paste -sd' ' -)"
    printf '| `%s` | %s | `%s` | %s |\n' "$n" "${mode:--}" "${src:--}" "${ids:--}"
  done
  rm -f "$pins"
}

index_write() {
  local idx readme="$ROOT/agents/replay/README.md"
  idx="$(mktemp)"; gen_index > "$idx"
  grep -qF "$INDEX_BEGIN" "$readme" || { echo "run.sh: README lacks the index BEGIN marker" >&2; exit 2; }
  # PR#381 review: without this, a lost END marker makes the splice's skip flag never clear and
  # it silently swallows the README from the marker to EOF — fail loud instead.
  grep -qF "$INDEX_END" "$readme" || { echo "run.sh: README lacks the index END marker" >&2; exit 2; }
  awk -v begin="$INDEX_BEGIN" -v end="$INDEX_END" -v f="$idx" '
    $0==begin {print; while ((getline l < f) > 0) print l; skip=1; next}
    $0==end {skip=0}
    !skip' "$readme" > "$idx.new"
  mv "$idx.new" "$readme"; rm -f "$idx"
  echo "→ index written into agents/replay/README.md"
}

index_check() {   # red when the committed block is stale — same ratchet spirit as the fixtures
  local idx cur readme="$ROOT/agents/replay/README.md"
  idx="$(mktemp)"; gen_index > "$idx"
  cur="$(mktemp)"
  awk -v begin="$INDEX_BEGIN" -v end="$INDEX_END" '
    $0==begin {inb=1; next} $0==end {inb=0} inb' "$readme" > "$cur"
  if ! diff -u "$cur" "$idx" > "$TMP/index.diff" 2>&1; then
    FAIL=$((FAIL+1)); FAILED+=("index-currency (README §Index is stale — run: bash agents/replay/run.sh --index --write)")
    printf '  \033[31m✗\033[0m index-currency — the generated register drifted:\n'
    sed 's/^/      /' "$TMP/index.diff" | head -15
  else
    ok "index-currency (README §Index matches the tree)"
  fi
  rm -f "$idx" "$cur"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -v|--verbose) VERBOSE=1; shift ;;
    --index) shift; if [ "${1:-}" = "--write" ]; then index_write; else gen_index; fi; exit 0 ;;
    -h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) break ;;
  esac
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

DIRS=()
if [ $# -gt 0 ]; then
  DIRS=("$@")
else
  for d in "$FIXROOT"/*/; do [ -d "$d" ] && DIRS+=("$d"); done
fi
[ ${#DIRS[@]} -gt 0 ] || { echo "clause-replay: no fixtures found under $FIXROOT" >&2; exit 2; }

printf '\033[1mclause-replay\033[0m — %s fixture(s) under %s\n' "${#DIRS[@]}" "${FIXROOT#$ROOT/}"
for d in "${DIRS[@]}"; do run_fixture "$d"; done
# index currency rides the FULL run only — a single-fixture invocation is an author's inner loop
[ $# -eq 0 ] && index_check

printf '\n  %s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\n\033[31mFAILED:\033[0m\n'; for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
  printf '\nA clause changed behaviour. If that was deliberate, update the fixture in the SAME PR\n'
  printf '(ADR-103: a changed clause ships with its replay, or it does not ship). If it was not,\n'
  printf 'the diff above is the regression, in the vocabulary the clause is contracted in.\n'
  exit 1
fi
printf '\n\033[32mEvery clause fixture holds.\033[0m\n'
