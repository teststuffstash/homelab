#!/usr/bin/env bash
# recipe-lint — is this `.agents/*.yaml` recipe PARSEABLE?
#
# WHY: a missing colon-space (`requirement_ids:{ type: array }`) is not a YAML mapping, it's a
# scalar — goose dies with "Invalid recipe: mapping values are not allowed" ~30s into a ride that
# already cost a pod, a token mint and (on a paid rail) real money. That exact defect bit twice:
# sleep-tracking's research.yaml, then the copy new-stack.sh carried into circles (FU-126 fan-out,
# 4 arms dead). This is the platform-side gate so a third one fails BEFORE the pod:
#   • agent-session.sh   — every dispatch, on the recipe AND on the env-card-spliced result
#   • scripts/stack-lint.sh — REPO-03 sweep across every stack's recipes
#   • scripts/new-stack.sh  — at scaffold time, on what the donor just handed over
#
# Deliberately dependency-free: the launcher also runs inside the agent-coordinator image, which
# has python3 but NO PyYAML and NO yq (probed 2026-08-04). A real parser is used when one is on
# PATH (authoritative — catches every parse error); otherwise the built-in scanner catches the
# known-fatal shapes (missing colon-space, tab indentation), which is what recurs.
#
# Usage: bash agents/recipe-lint.sh <file>...   → 0 all parse, 1 any broken
set -u

lint_one() {
  f="$1"
  [ -f "$f" ] || { echo "recipe-lint: FAIL $f — not a file" >&2; return 1; }

  # Strong path: a real YAML parser, when the environment happens to have one.
  if command -v yq >/dev/null 2>&1; then
    if err="$(yq -e '.' "$f" 2>&1 >/dev/null)"; then return 0; fi
    echo "recipe-lint: FAIL $f — yq: ${err}" >&2; return 1
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    if err="$(python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$f" 2>&1)"; then return 0; fi
    echo "recipe-lint: FAIL $f — pyyaml: $(printf '%s' "$err" | tail -3 | tr '\n' ' ')" >&2; return 1
  fi

  # Fallback: structural scan. Block-scalar aware (prose under `instructions: |` is NOT YAML and
  # must never be linted — it is full of colons), comment- and URL-aware.
  awk -v F="$f" '
    function indent_of(s,   i) { i = 0; while (substr(s, i + 1, 1) == " ") i++; return i }
    { line = $0; sub(/\r$/, "", line)
      n = indent_of(line); rest = substr(line, n + 1)
      if (inblock) {                      # skip the body of a `key: |` / `key: >` scalar
        if (rest == "") next
        if (n > blockind) next
        inblock = 0
      }
      if (rest == "" || substr(rest, 1, 1) == "#") next
      if (substr(rest, 1, 1) == "\t") { printf "recipe-lint: FAIL %s:%d — tab in indentation (YAML forbids tabs)\n", F, NR > "/dev/stderr"; rc = 1; next }
      if (substr(rest, 1, 2) == "- ") {   # sequence item: lint the mapping that follows the dash
        k = 2; while (substr(rest, k + 1, 1) == " ") k++
        n += k; rest = substr(rest, k + 1)
      }
      if (match(rest, /^[A-Za-z_][A-Za-z0-9_.-]*:/)) {
        after = substr(rest, RLENGTH + 1)
        if (after != "" && substr(after, 1, 1) != " ") {
          if (substr(after, 1, 2) != "//") {   # not a bare URL (https://…) sitting as a scalar
            printf "recipe-lint: FAIL %s:%d — no space after \x27:\x27 (`%s`) — YAML reads this as a scalar, goose fails with \x22mapping values are not allowed\x22\n", F, NR, substr(rest, 1, RLENGTH + 1) > "/dev/stderr"
            rc = 1
          }
          next
        }
        v = after; gsub(/^ +| +$/, "", v)
        if (v ~ /^[|>][-+0-9]*$/) { inblock = 1; blockind = n }
      }
    }
    END { exit rc + 0 }
  ' "$f" || return 1
  return 0
}

RC=0
for arg in "$@"; do lint_one "$arg" || RC=1; done
exit $RC
