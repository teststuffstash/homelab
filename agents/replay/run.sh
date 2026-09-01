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

# Ambient-env hermeticity (2026-08-18, third sighting in one day — PR#497/#514/#526 all hit it):
# a bridge default like `PROJECT="${PROJECT:-test-project}"` silently inherits the POD's own
# `PROJECT=homelab`, and the fixture asserts against `homelab#42` locally while CI's clean env
# passes — green-in-CI, red-in-any-pod, the inverted-hermeticity shape. Unset here, at the one
# choke point every child (composed clauses, bridges, suite entrypoints, stubs) inherits from.
# A fixture that genuinely needs one of these sets it via its own `env:` field, which applies
# AFTER this line. Add newly-evidenced leaky vars here, not per-bridge.
unset PROJECT AGENT_RAIL GH_TOKEN

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

# ── mode: table ─────────────────────────────────────────────────────────────────────────────────
# The decision-table mode (cleanup move 2): ONE fixture per family = the contract prose once, one
# bridge, named/family worlds, and rows.psv — a pipe-delimited table (the platform's own testing
# doctrine, applied to the harness that enforces it). Each row synthesizes an ordinary actions
# fixture in $TMP (family parts + row env + materialized world + rendered template) and runs
# through run_actions UNCHANGED — the table is sugar over the proven machinery, not a second path.
#
# rows.psv columns:  id | world | patch | env | expect | params
#   world   names $dir/worlds/<w> (family-local) or $HERE/worlds/<w> (registry); empty = family default
#   patch   "relpath ! jq-expr" over the materialized world — MUST change the target (no-op = red;
#           base worlds are CLEAN, a row adds its condition and has to earn its delta)
#   env     space-separated K=V appended after family env
#   expect  expected/<name>.txt template; params fill {{k}} — an unfilled {{k}} is red
# Row overlay dir rows/<id>/ (whole-file deltas, non-JSON) merges over the world after the base,
# before the patch.
psv_trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
run_table() {   # run_table <fixture-dir> <family-name>   (FXY = the family fixture, already parsed)
  local dir="$1" fam="$2"
  # PR#384 review: rows reassign the global FXY; restore the FAMILY's parse on every exit, or a
  # future `expect: fail` table family has its PROBE-FAIL verdict read the last ROW's fixture.
  local FAMILY_FXY="$FXY"
  local rowsf fsrc fworld
  rowsf="$(fx_scalar rows)"; rowsf="${rowsf:-rows.psv}"
  [ -f "$dir/$rowsf" ] || { bad "$fam: rows file not found: $rowsf"; return 0; }
  fsrc="$(fx_scalar source)"; fworld="$(fx_scalar world)"
  local FPARTS FENV FSCRUB
  FPARTS="$(fx_list parts)"; FENV="$(fx_list env)"; FSCRUB="$(fx_list scrub)"
  local line rid rworld rpatch renv rexpect rparams
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    rid="$(psv_trim "$(printf '%s' "$line" | cut -d'|' -f1)")"
    rworld="$(psv_trim "$(printf '%s' "$line" | cut -d'|' -f2)")"
    rpatch="$(psv_trim "$(printf '%s' "$line" | cut -d'|' -f3)")"
    renv="$(psv_trim "$(printf '%s' "$line" | cut -d'|' -f4)")"
    rexpect="$(psv_trim "$(printf '%s' "$line" | cut -d'|' -f5)")"
    rparams="$(psv_trim "$(printf '%s' "$line" | cut -d'|' -f6)")"
    [ -n "$rid" ] || continue
    local rname="$fam/$rid" synth="$TMP/$fam.$rid.fx" w base tgt prel pexpr kv
    mkdir -p "$synth/expected" "$synth/world"
    cp "$dir"/*.sh "$synth/" 2>/dev/null || true    # family bridges keep their file: names
    w="${rworld:-$fworld}"
    if [ -n "$w" ]; then
      if   [ -d "$dir/worlds/$w"  ]; then base="$dir/worlds/$w"
      elif [ -d "$HERE/worlds/$w" ]; then base="$HERE/worlds/$w"
      else bad "$rname: world not found: $w (family worlds/ then registry)"; continue; fi
      cp -r "$base/." "$synth/world/"; rm -f "$synth/world/provenance.yaml"
    fi
    [ -d "$dir/rows/$rid" ] && cp -r "$dir/rows/$rid/." "$synth/world/"
    if [ -n "$rpatch" ]; then
      # "relpath @ patchfile.jq" — the expr lives in a named family file (raw jq in a cell would
      # collide with the psv delimiter, and a named patch reads as the condition it encodes)
      prel="$(psv_trim "${rpatch%%@*}")"; local pfile; pfile="$(psv_trim "${rpatch#*@}")"
      tgt="$synth/world/$prel"
      [ -f "$tgt" ] || { bad "$rname: patch target missing in world: $prel"; continue; }
      [ -f "$dir/$pfile" ] || { bad "$rname: patch file not found: $pfile"; continue; }
      if ! jq -f "$dir/$pfile" "$tgt" > "$tgt.new" 2>"$TMP/$fam.$rid.jqerr"; then
        bad "$rname: patch jq failed ($pfile)" "$(cat "$TMP/$fam.$rid.jqerr")"; continue
      fi
      cmp -s "$tgt" "$tgt.new" && { bad "$rname: patch is a NO-OP — a row must earn its delta"; continue; }
      mv "$tgt.new" "$tgt"
    fi
    [ -n "$rexpect" ] || { bad "$rname: empty expect column"; continue; }
    [ -f "$dir/expected/$rexpect.txt" ] || { bad "$rname: template not found: expected/$rexpect.txt"; continue; }
    cp "$dir/expected/$rexpect.txt" "$synth/expected/actions.txt"
    for kv in $rparams; do
      sed -i "s|{{${kv%%=*}}}|${kv#*=}|g" "$synth/expected/actions.txt"
    done
    if grep -q '{{' "$synth/expected/actions.txt"; then
      bad "$rname: unfilled {{param}} in expected template"; continue
    fi
    {
      printf 'name: %s\nmode: actions\n' "$rname"
      [ -n "$fsrc" ] && printf 'source: %s\n' "$fsrc"
      printf 'parts:\n'; printf '%s\n' "$FPARTS" | while IFS= read -r p; do [ -n "$p" ] && printf '  - %s\n' "$p"; done
      if [ -n "$FENV$renv" ]; then
        printf 'env:\n'
        printf '%s\n' "$FENV" | while IFS= read -r p; do [ -n "$p" ] && printf '  - %s\n' "$p"; done
        for kv in $renv; do printf '  - %s\n' "$kv"; done
      fi
      if [ -n "$FSCRUB" ]; then
        printf 'scrub:\n'; printf '%s\n' "$FSCRUB" | while IFS= read -r p; do [ -n "$p" ] && printf '  - %s\n' "$p"; done
      fi
    } > "$synth/fixture.yaml"
    FXY="$(parse_fixture "$synth/fixture.yaml")"
    run_actions "$synth" "$rname"
  done < "$dir/$rowsf"
  FXY="$FAMILY_FXY"
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
  cp "$STUBS/gh" "$STUBS/kubectl" "$STUBS/claude" "$bin/" && chmod +x "$bin/gh" "$bin/kubectl" "$bin/claude"

  src="$(fx_scalar source)"

  # ── named world (cleanup move 1) ── `world: <name>` references agents/replay/worlds/<name>;
  # the fixture's effective world is MATERIALIZED (base copied, fixture-local world/ overlaid on
  # top, fixture file wins) into $TMP, so stubs AND seam-reading bridges see one plain directory —
  # no search paths, no reader changes. A named world that does not exist is a hard fixture error.
  local wname effworld="$dir/world"
  wname="$(fx_scalar world)"
  if [ -n "$wname" ]; then
    [ -d "$HERE/worlds/$wname" ] || { bad "$name: named world not found: agents/replay/worlds/$wname"; return 0; }
    effworld="$TMP/$name.world"
    mkdir -p "$effworld"
    cp -r "$HERE/worlds/$wname/." "$effworld/"
    rm -f "$effworld/provenance.yaml"   # registry metadata, never a recording
    [ -d "$dir/world" ] && cp -r "$dir/world/." "$effworld/"
  fi

  # Every composition opens with the scan's own `set -euo pipefail`, so "this survives -e" is
  # asserted by every fixture rather than claimed once.
  printf 'set -euo pipefail\n' > "$comp"

  # Prepend the source's config-defaults block if it has one (e.g. coordinator-scan.sh's
  # >>>REPLAY:config-defaults>>> block around top-of-file VAR="${VAR:-…}" assignments).
  # This ensures extracted clause blocks see the same defaults the full scan does, even
  # under `set -u` — without duplicating the default in every fixture's env: or bridge.
  if [ -n "$src" ] && [ -f "$ROOT/$src" ]; then
    if extract "config-defaults" "$ROOT/$src" > "$TMP/$name.config-defaults" 2>/dev/null; then
      [ -s "$TMP/$name.config-defaults" ] && { cat "$TMP/$name.config-defaults" >> "$comp"; printf '\n' >> "$comp"; }
    fi
  fi

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
      REPLAY_WORLD="$effworld" REPLAY_ACTIONS="$act" REPLAY_STUB_DIR="$STUBS" \
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
  # hermeticity contract (cleanup move 6, homelab#329): default = bash/awk/jq/sed anywhere;
  # anything more is DECLARED and its absence is loud — never a silent skip, never a mystery red.
  local rt
  for rt in $(fx_list requires); do
    command -v "$rt" >/dev/null 2>&1 || {
      bad "$name: requires \`$rt\` — declared dependency absent (hermeticity contract; run under devbox)"
      return 0
    }
  done
  [ "$expect" = fail ] && { EXPECT_FAIL=1; SELFTEST_HIT=0; SELFTEST_DETAIL=''; }
  case "$mode" in
    suite)   run_suite   "$dir" "$name" ;;
    actions) run_actions "$dir" "$name" ;;
    table)   run_table   "$dir" "$name" ;;
    '')      bad "$name: fixture.yaml has no \`mode:\` (want \`suite\`, \`actions\` or \`table\`)" ;;
    *)       bad "$name: unknown mode \`$mode\` (want \`suite\`, \`actions\` or \`table\`)" ;;
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
           line=$0; sub(/.*agents\/replay\/fixtures\//,"",line); sub(/[ \t#].*/,"",line)
           if (line != "" && id != "") print line "\t" id }' "$y"
  done | sort -u > "$pins"
  printf '| fixture | mode | world | source | pinned by (FSM) |\n|---|---|---|---|---|\n'
  local d rel n mode src w ids FXY
  # layout-agnostic discovery (FU-167 move 5): a fixture dir is any dir at depth 1 OR 2 holding a
  # fixture.yaml — tables at `fixtures/<table>/`, family members at `fixtures/<family>/<fixture>/`.
  # Sorted by relpath so the `_selftest-*` probe-fails still lead the register.
  local -a rels=()
  for d in "$FIXROOT"/*/ "$FIXROOT"/*/*/; do
    [ -f "$d/fixture.yaml" ] || continue
    rels+=("${d#$FIXROOT/}")
  done
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    d="$FIXROOT/$rel"; rel="${rel%/}"
    n="$(basename "$rel")"
    # the harness's OWN parser (PR#381 review): a bespoke awk here would render a future quoted
    # `source: "…"` differently than the harness reads it — one parser, one truth. `local FXY`
    # shadows the global bash-dynamically, so fx_scalar reads this fixture, and a run_fixture
    # loop's own FXY is untouched.
    FXY="$(parse_fixture "$d/fixture.yaml" 2>/dev/null)" || FXY=""
    mode="$(fx_scalar mode)"
    src="$(fx_scalar source)"
    w="$(fx_scalar world)"
    # pins are keyed by RELPATH (e.g. arbitrate/first-tick) so two families with a shared leaf
    # name (probe-fail, both, …) never cross-wire transitions in the view
    ids="$(awk -F'\t' -v rel="$rel" '$1==rel{print $2}' "$pins" | sort -u | paste -sd' ' -)"
    [ -n "$ids" ] || ids="$(awk -F'\t' -v n="$n" '$1==n{print $2}' "$pins" | sort -u | paste -sd' ' -)"
    printf '| `%s` | %s | %s | `%s` | %s |\n' "$rel" "${mode:--}" "${w:--}" "${src:--}" "${ids:--}"
  done < <(printf '%s\n' "${rels[@]}" | sort -u)
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

families_currency_check() {   # red when families.tsv breaks alphabetical-by-fixture-dir order
  local sorted="$TMP/families.sorted" families="$ROOT/agents/replay/families.tsv"
  awk -F'\t' '!/^#/ && NF>=1 && $0 !~ /^[[:space:]]*$/ {print $1}' "$families" | sort > "$sorted"
  awk -F'\t' '!/^#/ && NF>=1 && $0 !~ /^[[:space:]]*$/ {print $1}' "$families" > "$TMP/families.current"
  if ! diff -u "$sorted" "$TMP/families.current" > "$TMP/families.diff" 2>&1; then
    FAIL=$((FAIL+1)); FAILED+=("families-currency (agents/replay/families.tsv §fixture-dir order is alphabetical)")
    printf '  \033[31m✗\033[0m families-currency — fixture-dir column is not alphabetically ordered:\n'
    sed 's/^/      /' "$TMP/families.diff" | head -15
  else
    ok "families-currency (agents/replay/families.tsv §fixture-dir entries are alphabetically ordered)"
  fi
  rm -f "$sorted" "$TMP/families.current"
}

# ── record / re-record (cleanup move 1, the maintenance half) ──────────────────────────────────
# `--record <world> <relpath> -- <cmd...>` runs the command, stores its stdout as the world file,
# and appends a machine `recorded:` block to provenance.yaml — capture and provenance are one act.
# `--rerecord <world>` replays every stamped command and DIFFS against the stored files (add
# `--write` to adopt); an upstream API change stops being invisible the day someone re-records.
do_record() {
  local w="$1" rel="$2"; shift 2
  [ "$1" = "--" ] && shift
  local wdir="$HERE/worlds/$w"
  mkdir -p "$wdir/$(dirname "$rel")"
  "$@" > "$wdir/$rel" || { echo "record: command failed, nothing stored" >&2; exit 1; }
  { echo "recorded:"; printf '  - path: %s\n    cmd: %s\n    at: %s\n' \
      "$rel" "$*" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; } >> "$wdir/provenance.yaml"
  echo "→ recorded $w/$rel (provenance stamped)"
}
do_rerecord() {
  local w="$1" write="${2:-}" wdir="$HERE/worlds/$w" drift=0
  [ -f "$wdir/provenance.yaml" ] || { echo "rerecord: no provenance.yaml under worlds/$w" >&2; exit 2; }
  # replay only MACHINE-stamped entries (path+cmd pairs); reconstructed prose is not executable
  paste -d'\t' <(awk -F': ' '/^  - path: /{print $2}' "$wdir/provenance.yaml") \
               <(awk -F': ' '/^    cmd: /{sub(/^[^:]*: /,""); print}' "$wdir/provenance.yaml") \
  | while IFS=$'\t' read -r rel cmd; do
      [ -n "$rel" ] && [ -n "$cmd" ] || continue
      echo "── $rel  ($cmd)"
      if ! sh -c "$cmd" > "$TMPDIR_RR/new" 2>&1; then echo "   PROBE-FAIL: command failed"; continue; fi
      if diff -u "$wdir/$rel" "$TMPDIR_RR/new" > "$TMPDIR_RR/diff"; then echo "   unchanged"
      else drift=1; echo "   DRIFTED:"; head -12 "$TMPDIR_RR/diff" | sed 's/^/   /'
        [ "$write" = "--write" ] && cp "$TMPDIR_RR/new" "$wdir/$rel" && echo "   → adopted (--write)"
      fi
    done
  echo "(a drifted world adopted with --write re-runs every dependent fixture next suite pass)"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -v|--verbose) VERBOSE=1; shift ;;
    --index) shift; if [ "${1:-}" = "--write" ]; then index_write; else gen_index; fi; exit 0 ;;
    --record) shift; do_record "$@"; exit 0 ;;
    --rerecord) shift; TMPDIR_RR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR_RR"' EXIT; do_rerecord "$@"; exit 0 ;;
    -h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) break ;;
  esac
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

DIRS=()
if [ $# -gt 0 ]; then
  DIRS=("$@")
else
  # layout-agnostic discovery (FU-167 move 5): any dir at depth 1 OR 2 holding a fixture.yaml —
  # tables at `fixtures/<table>/`, family members at `fixtures/<family>/<fixture>/`. The globs
  # stay in bash's own sorted order, so the `_selftest-*` probe-fails still run first.
  for d in "$FIXROOT"/*/ "$FIXROOT"/*/*/; do
    [ -f "$d/fixture.yaml" ] && DIRS+=("$d")
  done
fi
[ ${#DIRS[@]} -gt 0 ] || { echo "clause-replay: no fixtures found under $FIXROOT" >&2; exit 2; }

printf '\033[1mclause-replay\033[0m — %s fixture(s) under %s\n' "${#DIRS[@]}" "${FIXROOT#$ROOT/}"
for d in "${DIRS[@]}"; do run_fixture "$d"; done
# index currency rides the FULL run only — a single-fixture invocation is an author's inner loop
[ $# -eq 0 ] && index_check
[ $# -eq 0 ] && families_currency_check

printf '\n  %s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\n\033[31mFAILED:\033[0m\n'; for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
  printf '\nA clause changed behaviour. If that was deliberate, update the fixture in the SAME PR\n'
  printf '(ADR-103: a changed clause ships with its replay, or it does not ship). If it was not,\n'
  printf 'the diff above is the regression, in the vocabulary the clause is contracted in.\n'
  exit 1
fi
printf '\n\033[32mEvery clause fixture holds.\033[0m\n'
