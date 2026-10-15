#!/usr/bin/env bash
# governance-lint — ADR-106 (4): a WORKER-authored PR diff that touches governance paths is RED,
# mechanically. The reviewer-rubric PROSE belt failed on 3 of 12 goal-#278 merges that wrote
# governance paths outside their `Touches:` (spike goal-lane-v1.1-fu165-pilot.md finding 4); a
# regex cannot skim a diff at 23:00.
#
#   devbox run governance-lint [<base-ref>]     (default origin/master; PR_AUTHOR from env)
#
# THE SET is the fixer recipe's NEVER-TOUCH tier (.agents/fix.yaml — the doctrine home; the test
# is "does this take effect BEFORE a human approves?"): CI workflows and the scripts/devbox they
# invoke run from the PR's OWN branch, and `.agents/**` is what the next fix round reads from
# that branch. This lint is that tier as a machine check, scoped to the WORKER lane only:
#   - seat/operator PRs pass untouched (the human IS the gate there);
#   - renovate and other non-worker bots pass (renovate legitimately bumps devbox/workflow pins);
#   - the worker App's PRs go red on any governance-path write.
# ⚖ ADR-142 TRIAL (2026-09-28): the rest of scripts/ LEFT this set — workers may author the
# repo's checks; the reviewer's gate-change lens + CI's gate-drift report (master's side of each
# edit, run from the BASE commit) are the gate. mgmt/scripts/ and the three box verbs stay: the
# management box runs them from master. Revert = put `scripts/` back in GOVERNANCE.
# SELF-GATING CAVEAT, stated not hidden: this script and ci.yaml are themselves governance paths
# executed from the PR branch, so a worker PR editing them could neuter the check — which is
# exactly why the paths sit in the NEVER-TOUCH tier, why this lint reddens the edit attempt, and
# why the whole-repo CODEOWNERS human gate on this repo stays underneath (ADR-106 leaves it).
set -euo pipefail
cd "$(dirname "$0")/.."

BASE="${1:-origin/master}"
# One greppable line, the pin-only-lint/guarded-set convention: other readers eval THIS line,
# never a second copy. Anchored patterns over the diff's repo-relative paths.
GOVERNANCE='^(\.github/|\.agents/|scripts/(node-maintenance|maintenance-window|controlplane-upgrade)\.sh$|mgmt/scripts/|policy/|devbox\.json$|devbox\.lock$|CODEOWNERS$)'
# The worker App's PR-author login. Event context shows "homelab-agents-1234[bot]" (the REST
# surface; GraphQL shows "app/homelab-agents-1234" — the known [bot]-suffix mismatch), so match
# on the App NAME prefix and neither suffix shape matters. Deliberately NOT "any [bot]":
# renovate[bot] must keep its update lane. Every login shape is pinned by
# scripts/governance-lint-test.sh (FU-296) — change the pattern, run that.
WORKER_PATTERN="${WORKER_PATTERN:-^(app/)?homelab-agents}"

author="${PR_AUTHOR:-}"
if [ -z "$author" ]; then
  # Local/manual run: there is no PR author to judge. Say so rather than inventing a verdict —
  # in CI the step always provides PR_AUTHOR, and an empty one there would mean the step is
  # miswired, which the fail-closed branch below catches via CI=true.
  if [ "${CI:-}" = "true" ]; then
    echo "governance-lint: FAIL — CI run with no PR_AUTHOR in env; refusing to report success." >&2
    exit 2
  fi
  echo "governance-lint: no PR_AUTHOR — nothing to judge (meaningful only on PR CI); ok."
  exit 0
fi

if ! grep -qE "$WORKER_PATTERN" <<< "$author"; then
  echo "governance-lint: author '$author' is not the worker lane — pass."
  exit 0
fi

# Fail-closed on an unresolvable base: a check that green-lights because it could not see is the
# FU-125/FU-108/FU-131 failure class (pin-only-lint's rule, copied deliberately).
if ! git rev-parse --verify "$BASE" >/dev/null 2>&1; then
  echo "governance-lint: FAIL — base ref '$BASE' not resolvable; refusing to report success." >&2
  echo "  In CI, fetch the base first: git fetch --no-tags --depth=1 origin \$BASE_SHA  (the PR base SHA at event time — never the branch tip, homelab#1441)" >&2
  exit 2
fi

# homelab#1441 (b) — the SECOND half of that class (PR#1699, 2026-09-14): in PR CI the checkout
# is the MERGE ref (base tip + head), so a two-dot diff from the fork-time base.sha lists every
# file master changed since the fork as if the branch wrote it — a docs-only worker PR "touched"
# ci.yaml, devbox.json and a script master had added that afternoon, ci-red twice. The branch's
# OWN files are the three-dot compare base...head, which needs the merge-base — absent in a
# depth-1 checkout — so in CI ask GitHub for it (server-side three-dot, depth-independent);
# locally git has the history and `BASE...HEAD` is the same answer. Fail closed either way.
# homelab#2412 (the THIRD shape, #1736's comment): a master-sync PR into a `goal/**` base forks
# from the GOAL tip, so three-dot ≡ two-dot there and master's own governance edits read as the
# worker's. The hits are therefore filtered to content NOT reachable from origin/master
# (MB = merge-base(master, head)) — see the block below.
if [ -n "${PR_HEAD_SHA:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  if ! changed="$(gh api "repos/${GITHUB_REPOSITORY}/compare/${BASE_REF:-master}...${PR_HEAD_SHA}" --jq '.files[].filename' 2>/dev/null)"; then
    echo "governance-lint: FAIL — could not read compare ${BASE_REF:-master}...${PR_HEAD_SHA} from GitHub; refusing to report success." >&2
    exit 2
  fi
  # homelab#2412 — the THIRD shape (#1736's comment): a master-sync PR into a `goal/**` base forks
  # from the GOAL tip, so merge-base(base, head) == goal tip and three-dot ≡ two-dot: master's own
  # governance edits are in the PR's diff and were attributed to the worker. The predicate is
  # "content NOT reachable from origin/master", so MB = merge-base(master, head) is the reference
  # and a hit whose head content is byte-identical to MB's is master's, not the PR's. `master` is
  # the repo's default branch — the same literal the BASE_REF default uses — and the read is
  # depth-independent like the one above. MB == the base for a PR based on master, so this is a
  # no-op there (the common case). The CI checkout is depth 1 (the merge ref), so fetch both sides.
  if ! mb="$(gh api "repos/${GITHUB_REPOSITORY}/compare/master...${PR_HEAD_SHA}" --jq '.merge_base_commit.sha' 2>/dev/null)" \
     || ! grep -Eq '^[0-9a-f]{40}$' <<< "$mb"; then
    echo "governance-lint: FAIL — could not read the merge base of master...${PR_HEAD_SHA} from GitHub (homelab#2412); refusing to report success." >&2
    exit 2
  fi
  # The CI checkout is depth 1 (the merge ref), so fetch both sides by SHA — the same form
  # pin-only-lint uses (a refspec fetch of a bare SHA is not the proven shape here).
  for r in "$PR_HEAD_SHA" "$mb"; do
    git cat-file -e "${r}^{commit}" 2>/dev/null && continue
    if ! git fetch -q --no-tags --depth=1 origin "$r" 2>/dev/null || ! git cat-file -e "${r}^{commit}" 2>/dev/null; then
      echo "governance-lint: FAIL — could not fetch $r (the master-reachability filter, homelab#2412); refusing to report success." >&2
      exit 2
    fi
  done
  HEAD_TREE="$PR_HEAD_SHA"
else
  if ! changed="$(git diff --name-only "$BASE"...HEAD 2>/dev/null)"; then
    echo "governance-lint: FAIL — no merge-base between '$BASE' and HEAD (shallow checkout?); refusing to report success." >&2
    exit 2
  fi
  # The local arm's master reference: origin/master when the clone has it, else the base itself —
  # the pre-#2412 behaviour (MB == the base, so the filter below is a no-op). GOVLINT_MASTER is
  # the test seam; CI never reaches this arm.
  MASTER_REF="${GOVLINT_MASTER:-origin/master}"
  git rev-parse --verify "$MASTER_REF" >/dev/null 2>&1 || MASTER_REF="$BASE"
  if ! mb="$(git merge-base "$MASTER_REF" HEAD 2>/dev/null)"; then
    echo "governance-lint: FAIL — no merge-base between '$MASTER_REF' and HEAD (shallow checkout?); refusing to report success." >&2
    exit 2
  fi
  HEAD_TREE=HEAD
fi
hits="$(printf '%s\n' "$changed" | grep -E "$GOVERNANCE" || true)"
# homelab#2412: drop every hit whose head content is byte-identical to MB's — that content is
# master's, not the PR's. A file absent at both ends compares equal (a deletion master also made).
if [ -n "$hits" ]; then
  own=""
  for h in $hits; do
    head_blob="$(git rev-parse -q --verify "$HEAD_TREE:$h" 2>/dev/null || echo -)"
    mb_blob="$(git rev-parse -q --verify "$mb:$h" 2>/dev/null || echo -)"
    [ "$head_blob" = "$mb_blob" ] || own="${own}${h}"$'\n'
  done
  hits="$(printf '%s' "$own" | grep . || true)"
fi

# ASSEMBLY-LANE ARM (homelab#1036, 2026-09-01). ADR-102's assembly PR is opened by the
# COORDINATOR, whose token is minted from the same App as the worker's — so a `goal/**` head
# aggregating a SEAT-authored governance file (the `.agents/probe.md` of #1030: fixer carve-out
# declined precisely so the seat would write it) reads as a worker diff and goes red on a step
# no lane in the loop can turn green (4 ci-red rides in ~2h, then agent/error; steps 18–32 never
# ran). The property that matters is "no WORKER-WRITTEN governance line lands before a human
# approves" — so on the assembly lane judge each hit by COMMIT authorship, not PR authorship.
# Lane test = the same strong link the scan's post-launch transition trusts: a goal/** head AND
# a line-anchored `Assembly-for: #<n>` trailer. Fails CLOSED on unreadable history.
if [ -n "$hits" ] && grep -qE '^goal/' <<< "${PR_HEAD_REF:-}" \
   && grep -qE '^[[:space:]]*Assembly-for:[[:space:]]*#[0-9]+' <<< "${PR_BODY:-}"; then
  base_sha="$(git rev-parse "$BASE")"
  # The CI checkout is depth 1 (the merge ref only) — fetch the goal branch's own history into a
  # private ref so `base..head -- <hit>` can name the committer of every governance line.
  # GOVLINT_REMOTE is a TEST seam (`.` = fetch a local branch); CI never sets it.
  if ! git fetch -q --no-tags --depth=500 "${GOVLINT_REMOTE:-origin}" "+refs/heads/${PR_HEAD_REF}:refs/govlint/head" 2>/dev/null; then
    echo "governance-lint: FAIL — assembly lane: could not fetch '${PR_HEAD_REF}' to read commit authorship; refusing to report success." >&2
    exit 2
  fi
  worker_hits=""
  for h in $hits; do
    authors="$(git log --format='%an' "${base_sha}..refs/govlint/head" -- "$h" 2>/dev/null)" || {
      echo "governance-lint: FAIL — assembly lane: git log unreadable for '$h'; refusing to report success." >&2
      exit 2; }
    if grep -qE "$WORKER_PATTERN" <<< "$authors"; then worker_hits="${worker_hits}${h}"$'\n'; fi
  done
  if [ -n "$worker_hits" ]; then
    echo "governance-lint: FAIL — assembly PR carries WORKER-authored commits on governance paths (ADR-106 (4)):" >&2
    printf '  %s\n' $worker_hits >&2
    exit 1
  fi
  echo "governance-lint: ok — assembly lane (goal/** head + Assembly-for: trailer): $(printf '%s\n' "$hits" | grep -c .) governance path(s) touched, every commit human/non-worker authored (homelab#1036)."
  exit 0
fi

# REVERT ARMS (class 7 — the 2026-10-07 ruling, homelab#2369: the lock revert chain merges its own
# reverts; docs/dependency-upgrades.md §2 Review). `workflow-pin-revert`'s shapes
# (agents/coordinator/deploy-revert-argo.yaml) are opened by the SAME App as the worker, so its
# `git revert` of a pin-only merge reads as a worker writing the reverted path — the 2026-10-10
# drill's #2480 went red here, both sentinels green, and the chain's own revert could never merge.
# A revert RESTORES, it never invents, so the arm admits exactly that and nothing else. The chain
# has THREE shapes and they are ONE predicate with a different (prefix, trailer, file set) triple:
#   revert-lock-<sha8>  reverted-locks:   (^|/)devbox\.lock$|^mgmt/nixos/flake\.lock$   (#2482)
#   revert-wf-<sha8>    reverted-pins:    ^\.github/workflows/                          (#2561)
#   revert-img-<sha8>   reverted-images:  ^tofu/.*\.tf$                                 (#2561)
#   - the head ref is `revert-<kind>-<sha8>` and the body carries the kind's line-anchored trailer;
#   - EVERY changed file is one the chain reverts (the kind's file set above) — the lock set is the
#     chain's IS_LOCK set (a `devbox.lock` in any dir, or mgmt/nixos/flake.lock; the flake is not a
#     governance path here, pin-only-lint check (j) holds its revert to the same byte-exact rule),
#     the wf set is the chain's candidate surface, the img set is its `all files tofu/*.tf` rule;
#   - <sha8> is on the base branch (master history, not a commit the branch carries itself);
#   - per file, the head is BYTE-FOR-BYTE <sha8>'s first parent (git blob identity), and the base
#     still carries <sha8>'s version (the revert undoes the LATEST change, never an older state).
# Every read fails CLOSED (exit 2). History comes from a private fetch, like the assembly arm
# (CI's checkout is depth 1); GOVLINT_REMOTE is the same test seam.
# ⚖ REACHABILITY, stated not hidden: only the lock and wf rows can fire HERE — `devbox.lock` and
# `.github/` are governance paths, `tofu/` is not (ADR-142's tier list), so an img revert has no
# `hits` and falls through to the ok line below. The img row is kept because the predicate is the
# CHAIN's shape, not this lint's: if `tofu/` ever joins GOVERNANCE the arm is already right, and a
# `revert-img-` head that smuggles a governance path is declined by the file set either way.
if [ -n "$hits" ] && [[ "${PR_HEAD_REF:-}" =~ ^revert-(lock|wf|img)-([0-9a-f]{8})$ ]]; then
  rv_kind="${BASH_REMATCH[1]}"; rv_sha8="${BASH_REMATCH[2]}"
  case "$rv_kind" in
    lock) rv_trailer='reverted-locks:';  rv_files_re='(^|/)devbox\.lock$|^mgmt/nixos/flake\.lock$' ;;
    wf)   rv_trailer='reverted-pins:';   rv_files_re='^\.github/workflows/' ;;
    img)  rv_trailer='reverted-images:'; rv_files_re='^tofu/.*\.tf$' ;;
  esac
  if grep -qE "^[[:space:]]*${rv_trailer}" <<< "${PR_BODY:-}"; then
    rv_files="$(printf '%s\n' "$changed" | grep . || true)"
    rv_other="$(printf '%s\n' "$rv_files" | grep -vE "$rv_files_re" || true)"
    if [ -n "$rv_other" ]; then
      echo "governance-lint: revert-${rv_kind} arm declined — the diff changes files outside the ${rv_kind} shape:" >&2
      printf '  %s\n' $rv_other >&2
    else
      rv_fail() { echo "governance-lint: FAIL — revert-${rv_kind} arm: $*; refusing to report success." >&2; exit 2; }
      git fetch -q --no-tags --depth=200 "${GOVLINT_REMOTE:-origin}" \
        "+refs/heads/${PR_HEAD_REF}:refs/govlint/head" "+refs/heads/${BASE_REF:-master}:refs/govlint/base" 2>/dev/null \
        || rv_fail "could not fetch '${PR_HEAD_REF}' and '${BASE_REF:-master}'"
      rv_head="$(git rev-parse refs/govlint/head)"
      if [ -n "${PR_HEAD_SHA:-}" ] && [ "$rv_head" != "$PR_HEAD_SHA" ]; then
        rv_fail "fetched head ${rv_head:0:8} is not the event's head ${PR_HEAD_SHA:0:8} (branch moved — re-run)"
      fi
      rv_full="$(git rev-parse --verify -q "${rv_sha8}^{commit}" 2>/dev/null)" || rv_fail "<sha8> ${rv_sha8} does not resolve to one commit"
      rv_parent="$(git rev-parse --verify -q "${rv_full}^1" 2>/dev/null)" || rv_fail "cannot read the first parent of ${rv_sha8}"
      rv_bad=""
      git merge-base --is-ancestor "$rv_full" refs/govlint/base 2>/dev/null \
        || rv_bad="${rv_bad}  ${rv_sha8} is not on ${BASE_REF:-master} — a revert-${rv_kind} branch reverts a MERGED commit"$'\n'
      for f in $rv_files; do
        want="$(git rev-parse --verify -q "${rv_parent}:${f}" 2>/dev/null)" || rv_fail "cannot read $f at ${rv_sha8}^"
        got="$(git rev-parse --verify -q "${rv_head}:${f}" 2>/dev/null)"    || rv_fail "cannot read $f at the PR head"
        was="$(git rev-parse --verify -q "${rv_full}:${f}" 2>/dev/null)"    || rv_fail "cannot read $f at ${rv_sha8}"
        now="$(git rev-parse --verify -q "${BASE}:${f}" 2>/dev/null)"       || rv_fail "cannot read $f at the base"
        [ "$got" = "$want" ] || rv_bad="${rv_bad}  $f is not byte-for-byte its content at ${rv_sha8}^ (head blob ${got:0:8}, want ${want:0:8})"$'\n'
        [ "$now" = "$was" ]  || rv_bad="${rv_bad}  $f moved on the base since ${rv_sha8} — the revert would undo more than that commit"$'\n'
      done
      if [ -n "$rv_bad" ]; then
        echo "governance-lint: FAIL — revert-${rv_kind} arm REFUSED (head revert-${rv_kind}-${rv_sha8}):" >&2
        printf '%s' "$rv_bad" >&2
        exit 1
      fi
      echo "governance-lint: ok — revert-${rv_kind} lane (revert-${rv_kind}-${rv_sha8}, ${rv_trailer} memory): $(printf '%s\n' "$rv_files" | grep -c .) file(s) restored byte-for-byte to ${rv_sha8}^ (class 7, #2369; FU-1990 #2561)."
      exit 0
    fi
  fi
fi

if [ -n "$hits" ]; then
  echo "governance-lint: FAIL — worker-authored diff touches governance paths (ADR-106 (4);" >&2
  echo "  the .agents/fix.yaml NEVER-TOUCH tier — these take effect before a human approves):" >&2
  printf '  %s\n' $hits >&2
  echo "  Route this change to the operator lane (an issue naming the exact lines), never a worker PR." >&2
  exit 1
fi
echo "governance-lint: ok — worker diff touches no governance path."
