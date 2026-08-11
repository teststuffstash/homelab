# argv-guard.sh — the per-argv-element ceiling every base64 payload channel rides into (homelab#242).
#
# ONE implementation, two callers: `agent-session.sh` (the pod's `bash -c "<WRAPPED>"` string) and
# `retro-session.sh` (the `--run` it hands that launcher). They are the two places where a whole
# recipe or brief travels base64'd INSIDE A SINGLE argv element.
#
# THE LIMIT. Linux caps one argv/env STRING at MAX_ARG_STRLEN = 32 × PAGE_SIZE = 131072 bytes
# (fs/exec.c). It is a PER-STRING limit, independent of the much larger total ARG_MAX/RLIMIT_STACK
# budget everyone quotes and that `getconf ARG_MAX` reports — which is why the payload channel can
# be nowhere near "the argument list is too long" in aggregate and still die. Past the ceiling
# execve() returns E2BIG and the shell prints `Argument list too long`, naming nothing: not the
# payload, not the limit, not the channel. retro-session-8rvhd hit exactly that on 2026-08-11 (a
# 146KB brief → ~195KB of base64) and died BEFORE any pod existed, while both DAG cells reported
# Succeeded — the tee swallowed the status (since fixed with pipefail, 4db553e).
#
# WHAT THIS IS NOT. It does not move the payload off argv. A file channel — a ConfigMap mount, or
# chunked env vars reassembled in-pod — is the real fix and is deliberately not built here
# (homelab#242 offers it as option (b) and says the guard alone is acceptable). Nothing is near the
# cliff today: the retro lane bounds its brief to a worst-K ledger slice. What the guard removes is
# the SILENT version of the failure for the day a recipe, env card or lens append grows there.
#
# NEVER EXITS — it measures, reports and returns. Same division as goal-budget.sh: the caller
# enforces, because the two callers owe different sentences (the launcher must say no pod was
# created; the retro leg must say which brief to shrink) and a helper that exits owns neither.
#
# ONE SEAM: `ag_limit`, the ceiling in bytes. A plain function a caller may redefine, which is how
# agents/replay/fixtures/argv-payload-* replay both legs against a small stand-in ceiling instead
# of committing a 128KiB payload into a fixture.

# The kernel constant, spelled out rather than probed: no getconf key exposes MAX_ARG_STRLEN, and
# the one that looks right (ARG_MAX) answers a different question. 32 × 4096.
ag_limit() { printf '%s' 131072; }

# A payload this far up still runs — but the next append is the one that doesn't. Loud early beats
# loud late, and "it worked yesterday" is how this class of failure is discovered in production.
AG_WARN_PCT=80

argv_guard() {   # argv_guard <what> <payload> → 0 = fits (may WARN on stderr), 1 = over the ceiling
  local what="$1" payload="$2" limit n pct
  limit="$(ag_limit)"
  # BYTES, not characters: `${#var}` counts characters under a UTF-8 locale, and these payloads
  # carry non-ASCII prose (the env card's → and ⚠), so it would under-count precisely the payload
  # that is already too big for the kernel.
  n="$(printf '%s' "$payload" | wc -c | tr -d '[:space:]')"
  # execve counts the NUL terminator, so n == limit is already E2BIG.
  if [ "$n" -ge "$limit" ]; then
    printf 'FATAL: %s is %s bytes — at/over the Linux per-argument ceiling MAX_ARG_STRLEN (%s bytes).\n' "$what" "$n" "$limit" >&2
    printf '  execve() fails E2BIG here and the only symptom is `Argument list too long` — no payload, no limit, no channel named.\n' >&2
    printf '  This channel carries the whole recipe/brief as base64 (~4/3 of its source bytes) inside ONE argv element.\n' >&2
    printf '  Fix: bound what goes in (the retro lane bounds its ledger to a worst-K slice — the worked example), or\n' >&2
    printf '  move the payload to a file channel: ConfigMap mount / chunked env reassembled in-pod (homelab#242 option b).\n' >&2
    return 1
  fi
  pct=$(( n * 100 / limit ))
  if [ "$pct" -ge "$AG_WARN_PCT" ]; then
    printf '⚠ %s is %s bytes — %s%% of the MAX_ARG_STRLEN ceiling (%s bytes). It runs; the next append may not (homelab#242).\n' \
      "$what" "$n" "$pct" "$limit" >&2
  fi
  return 0
}
