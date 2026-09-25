#!/usr/bin/env bash
# pin-only-lint — the deterministic gate that replaces a code owner on carved-out files.
#
#   devbox run pin-only-lint [<base-ref>]      (default: origin/master)
#   self-test: devbox run pin-only-lint-test   (scripts/pin-only-lint-test.sh)
#
# 2026-08-05: `argocd/platform/openrouter-operator.yaml` joins them. The CODEOWNERS flip made the
# CHART-deploy lane (ADR-084) wait on a human for a one-line targetRevision bump, exactly as it had
# for the runner-image lane — homelab#104 and #105 both sat BLOCKED with CI green. `agents/images.env`
# was already carved out, so the agent-base half of the same lane flowed while the chart half did
# not. Same ruling, same mechanism: ownership REPLACED by a rule, not dropped.
#
# WHY. `argocd/platform/arc-runners.yaml` and `agents/coordinator/reflexes-argo.yaml` are owned
# paths (tier 2 and tier 3), and the arc-runner auto-bump commits BOTH — so the CODEOWNERS flip
# would have made a mechanical tag bump wait for a human on every runner-image build. Operator
# ruling 2026-08-04: keep it hands-off. Un-owning the files buys that back, but reflexes-argo.yaml
# is the reflex machinery — the governor an agent must never edit unreviewed — so the ownership is
# replaced rather than dropped: via a PR these files may receive PIN BUMPS ONLY.
#
# That is strictly stronger than the human it replaces. The bump is three identical lines
#   image: ghcr.io/teststuffstash/homelab/arc-runner:<tag>
# and a regex cannot be talked past, skim a diff at 23:00, or approve a smuggled fourth line.
#
# 2026-09-25 (ADR-100 addendum, homelab#1990): a THIRD shape — `.github/workflows/<file>.y(a)ml`
# may receive ACTION PIN BUMPS via a PR (Renovate's `pinGitHubActionDigests` lane). Same doctrine,
# a stricter rule than the two above because a SHA is the one thing a human reviewer cannot read:
#   (a) every changed line is `uses: <owner>/<repo>@<40-hex sha> # <tag>` — leading YAML
#       indentation and an optional `- ` list marker allowed; the tag is `v<digits>` with up to
#       two `.<digits>` groups (`v7`, `v0.13.0`, `v46.3.1`); nothing after the tag. Reusable-
#       workflow refs (`owner/repo/.github/workflows/x.yml@…`) do NOT fit the grammar on purpose:
#       our own float at `@master` by contract and third-party ones are not a thing here;
#   (b) removed and added lines PAIR UP: the multiset of `<owner>/<repo>` removed equals the
#       multiset added — a bump never adds a step, drops one, or swaps one action for another;
#   (c) a `teststuffstash/*` ref never changes via a PR at all (first-party refs float at
#       `@master`, `.github/renovate-global.json`'s first-party rule);
#   (d) every added SHA is verified UPSTREAM: `repos/<o>/<r>/git/ref/tags/<tag>` (an annotated
#       tag is dereferenced once via `git/tags/<sha>`) must name exactly the added commit SHA.
#       One API call per added line, `gh` from $PATH (CI has GH_TOKEN; the jail gh is logged
#       in); ANY failure to resolve is a FAIL — a check that cannot see does not pass.
# A revert of a pin is itself a pin change that passes (a)–(d), so the rollback needs no bypass.
# Seams for the self-test and the reusable caller workflow (never a REPLAY_* branch):
#   PIN_ONLY_REPO   the repo root to lint (default: this script's parent dir)
#   PIN_ONLY_GH     the `gh` to call for (d) (default: `gh`)
#
# ESCAPE HATCH for a real edit: push it to master directly. That is the documented operator path
# in this repo (CLAUDE.md §"How changes land"), it is not a PR, and this check does not run on it.
# The rule constrains the AUTOMATED lane, which is the only lane that got un-gated.
set -euo pipefail
cd "${PIN_ONLY_REPO:-$(dirname "$0")/..}"
GH="${PIN_ONLY_GH:-gh}"

BASE="${1:-origin/master}"
GUARDED='argocd/platform/arc-runners\.yaml|agents/coordinator/reflexes-argo\.yaml|agents/coordinator/sentinel-argo\.yaml|argocd/platform/openrouter-operator\.yaml'
# Two pin shapes, one rule. The arc-runner bump writes an `image:` line; the chart-deploy lane
# writes a `targetRevision:` line (CalVer + -g<sha>, ADR-084). Anything else in a guarded file is
# still refused, so widening the FILE set does not widen what may be written to it.
# ⚠ GUARDED= and PIN_LINE= are ONE HOME: ci.yaml's ratchet exemption eval-extracts both lines and
# coordinator-scan.sh / goal-lint.sh split GUARDED on `|` — keep them single-line, single-quoted.
PIN_LINE='^[-+][[:space:]]*(image:[[:space:]]*ghcr\.io/teststuffstash/homelab/arc-runner:[A-Za-z0-9._-]+|targetRevision:[[:space:]]*[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}-g[0-9a-f]+)$'
# The third shape has its own pair so the two above stay byte-for-byte (their consumers never see
# a workflow path in GUARDED, and the ratchet exemption never sees a `uses:` line as a pin).
WORKFLOW_GUARDED='^\.github/workflows/[^/]+\.ya?ml$'
WORKFLOW_PIN_LINE='^[-+][[:space:]]*(- )?uses:[[:space:]]*[A-Za-z0-9-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}[[:space:]]+#[[:space:]]+v[0-9]+(\.[0-9]+){0,2}$'
# The same grammar as capture groups: sign, owner/repo, sha, tag (kept next to the regex so the
# two cannot drift apart unnoticed — a line that matches WORKFLOW_PIN_LINE always extracts).
WORKFLOW_PIN_EXTRACT='s/^([-+])[[:space:]]*(- )?uses:[[:space:]]*([A-Za-z0-9-]+\/[A-Za-z0-9_.-]+)@([0-9a-f]{40})[[:space:]]+#[[:space:]]+(v[0-9]+(\.[0-9]+){0,2})$/\1 \3 \4 \5/'

# Refuse to pass when the diff cannot be computed. A check that green-lights because it could not
# see is the failure class this repo keeps paying for (FU-125/FU-108/FU-131) — and one I shipped
# twice in labels-handoff.sh before catching it.
if ! git rev-parse --verify "$BASE" >/dev/null 2>&1; then
  echo "pin-only-lint: FAIL — base ref '$BASE' not resolvable; refusing to report success." >&2
  echo "  In CI, fetch the base first: git fetch --no-tags --depth=1 origin \$BASE_SHA  (the PR base SHA at event time — never the branch tip, homelab#1441)" >&2
  exit 2
fi

changed="$(git diff --name-only "$BASE" HEAD | grep -E "$GUARDED" || true)"
wf_changed="$(git diff --name-only "$BASE" HEAD | grep -E "$WORKFLOW_GUARDED" || true)"
if [ -z "$changed" ] && [ -z "$wf_changed" ]; then
  echo "pin-only-lint: OK — no guarded file touched."
  exit 0
fi

echo "pin-only-lint: guarded files in this diff:"
# shellcheck disable=SC2086  # word-splitting the newline list is the point
printf '  %s\n' $changed $wf_changed

rc=0
for f in $changed; do
  # Content lines only: strip the +++/--- headers, keep real additions/removals.
  offending="$(git diff -U0 "$BASE" HEAD -- "$f" \
    | grep -E '^[-+][^-+]' \
    | grep -Ev "$PIN_LINE" || true)"
  if [ -n "$offending" ]; then
    echo "pin-only-lint: FAIL — $f may only receive PIN lines via a PR (arc-runner image: / chart targetRevision:):" >&2
    printf '  %s\n' "$offending" >&2
    rc=1
  fi
done

# Resolve <owner/repo> <tag> upstream to the commit SHA the tag names. Prints the SHA; any failure
# (HTTP error, unparseable body, a tag object that does not dereference to a commit) is non-zero
# with the reason on stdout — the caller turns it into a FAIL.
resolve_tag_commit() {
  local or="$1" tag="$2" out type sha
  if ! out="$("$GH" api "repos/$or/git/ref/tags/$tag" --jq '.object.type + " " + .object.sha' 2>&1)"; then
    printf 'ref/tags/%s lookup failed: %s\n' "$tag" "$out"; return 1
  fi
  type="${out%% *}"; sha="${out#* }"
  if [ "$type" = tag ]; then  # annotated tag → dereference once to the commit it names
    if ! out="$("$GH" api "repos/$or/git/tags/$sha" --jq '.object.type + " " + .object.sha' 2>&1)"; then
      printf 'annotated tag %s (%s) dereference failed: %s\n' "$tag" "$sha" "$out"; return 1
    fi
    type="${out%% *}"; sha="${out#* }"
  fi
  if [ "$type" != commit ] || ! printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$'; then
    printf 'tag %s resolves to a %s object (%s), not a commit\n' "$tag" "${type:-?}" "$sha"; return 1
  fi
  printf '%s\n' "$sha"
}

for f in $wf_changed; do
  lines="$(git diff -U0 "$BASE" HEAD -- "$f" | grep -E '^[-+][^-+]' || true)"
  if [ -z "$lines" ]; then  # a rename / mode change / empty patch is not a pin bump
    echo "pin-only-lint: FAIL — $f changed without a single content line; a workflow may only receive action pin bumps via a PR." >&2
    rc=1; continue
  fi
  offending="$(printf '%s\n' "$lines" | grep -Ev "$WORKFLOW_PIN_LINE" || true)"
  if [ -n "$offending" ]; then
    echo "pin-only-lint: FAIL — $f may only receive action PIN lines via a PR (uses: <owner>/<repo>@<sha> # <tag>):" >&2
    printf '  %s\n' "$offending" >&2
    rc=1; continue
  fi
  removed_or=""; added_or=""; added_specs=""
  while read -r sign or sha tag; do
    case "$or" in
      teststuffstash/*)
        echo "pin-only-lint: FAIL — $f: a first-party ref never changes via a PR (floats at @master by contract, .github/renovate-global.json): ${sign} uses: $or@$sha # $tag" >&2
        rc=1; continue ;;
    esac
    if [ "$sign" = - ]; then removed_or="${removed_or}${or}"$'\n'
    else added_or="${added_or}${or}"$'\n'; added_specs="${added_specs}${or} ${sha} ${tag}"$'\n'; fi
  done <<< "$(printf '%s\n' "$lines" | sed -E "$WORKFLOW_PIN_EXTRACT")"
  if [ "$(printf '%s' "$removed_or" | sort)" != "$(printf '%s' "$added_or" | sort)" ]; then
    echo "pin-only-lint: FAIL — $f: removed and added uses: lines do not pair up by <owner>/<repo> (a bump never adds, drops or swaps an action):" >&2
    printf '  removed: %s\n' "$(printf '%s' "$removed_or" | sort | tr '\n' ' ')" >&2
    printf '  added:   %s\n' "$(printf '%s' "$added_or" | sort | tr '\n' ' ')" >&2
    rc=1; continue
  fi
  while read -r or sha tag; do
    [ -n "$or" ] || continue
    if ! got="$(resolve_tag_commit "$or" "$tag")"; then
      echo "pin-only-lint: FAIL — $f: cannot verify $or@$sha # $tag upstream ($got); refusing to report success." >&2
      [ "$rc" = 0 ] && rc=2; continue
    fi
    if [ "$got" != "$sha" ]; then
      echo "pin-only-lint: FAIL — $f: $or tag $tag names commit $got upstream, the PR pins $sha." >&2
      rc=1
    fi
  done <<< "$added_specs"
done

if [ "$rc" != 0 ]; then
  cat >&2 <<'EOF'

  These files are UNOWNED in CODEOWNERS so the mechanical lanes (arc-runner auto-bump, chart
  deploy-pin, Renovate action pins) stay hands-off; this rule is what stands in for the code
  owner. A legitimate edit is not blocked — push it to master directly (the operator path,
  CLAUDE.md §"How changes land"), or re-own the file in CODEOWNERS if it should need review again.
EOF
  exit "$rc"
fi
echo "pin-only-lint: OK — every change is a pin line (arc-runner image / chart targetRevision / verified action SHA)."
