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
#   (e) no added SHA is a pin the FU-1990 revert chain rolled back in the last REVERT_MEMORY_DAYS
#       (30): merged `revert-wf-*` PRs of THIS repo carry a `reverted-pins: <owner/repo@sha> …`
#       body line (agents/coordinator/deploy-revert-argo.yaml). Renovate re-proposes a
#       merged-then-reverted version on its next run (a MERGED PR is not a rejected one), and
#       without this the lane loops merge → fail → revert → re-propose → merge. Refusing it HERE
#       keeps the re-proposal open and red until Renovate moves it to a newer version (then it
#       greens on its own) — one home, and CI is the gate for both the mechanical and the
#       lens-reviewed lane. The repo is $PIN_ONLY_SLUG, else $GITHUB_REPOSITORY, else origin.
# A revert of a pin is itself a pin change that passes (a)–(d), so the rollback needs no bypass.
#   (f) 2026-09-28 (#1988's class row, ADR-141 amended): the FOURTH shape's memory. An `image = "<ref>"`
#       line under tofu/*.tf (what Renovate's terraform manager rewrites on a kubernetes_deployment)
#       is not a guarded file — tofu is owned and reviewed as usual — but a diff that ADDS such a
#       line naming a ref a merged `revert-img-*` PR rolled back in the last REVERT_MEMORY_DAYS is
#       refused (the `reverted-images:` body line, agents/coordinator/deploy-revert-argo.yaml
#       `tofu-image-revert`). Same reason as (e): a merged-then-reverted version is re-proposed by
#       Renovate, and without this the lane loops merge → stuck rollout → revert → re-propose.
#       Runs only when the diff touches tofu/*.tf AND adds an image line; fail-closed on the read.
#   (g) 2026-10-04 (S9 #1988): the provider-pin memory. A `.terraform.lock.hcl` diff that moves a
#       provider TO a version a merged `revert-prov-*` PR rolled back in the last REVERT_MEMORY_DAYS
#       (its `reverted-providers: <name>@<version>` body line, agents/coordinator/deploy-revert-argo.yaml
#       `tofu-provider-revert`) is refused — name = the source's last segment. Same loop as (e)/(f):
#       Renovate re-proposes a merged-then-reverted version. Fail-closed on the read.
#   (h) 2026-10-05 (FU-304's class row — the #2254 read, ADR-141's pattern on the argocd chart
#       lane): the chart-pin memory. An `argocd/platform/*.yaml` diff that ADDS a `targetRevision:`
#       line is keyed `<chart>@<version>` (chart = the head file's `spec.source.chart`; a file with
#       no `chart:` — a `path:` source — has no key; a trailing `# comment` is not part of the
#       version) and refused when a merged `revert-chart-*` PR of the last REVERT_MEMORY_DAYS names
#       that pair on its `reverted-charts: <chart>@<version> …` body line (the chart revert actor,
#       driven by `ArgoControllerSilent`, records the version it reverted AWAY from). Same loop as
#       (e)/(f)/(g): Renovate's `argocd` manager re-proposes a merged-then-reverted chart version.
#       Runs only when such a line is added; fail-closed on the read.
#   (i) 2026-10-07 (class 7 majors ARMED — docs/dependency-upgrades.md §2 Review): the lock memory.
#       A `devbox.lock` diff (any directory) is keyed per package whose resolved `version` differs
#       between base and head — `<name>@<new-version>`, base name with the `@pin` stripped, the key
#       scripts/devbox-update.sh lock_moves uses — and refused when a merged `revert-lock-*` PR of the
#       last REVERT_MEMORY_DAYS names that pair on its `reverted-locks: <name>@<version> …` body line
#       (the lock shape of `workflow-pin-revert`, agents/coordinator/deploy-revert-argo.yaml: a master
#       workflow failing within the window after a lock-only merge reverts it and records the versions
#       it removed). Same loop as (e)–(h): the weekly `devbox-update` re-resolves `@latest` to the same
#       version until nixpkgs moves on, and without this the lane loops merge → fail → revert → merge.
#       The refusal holds the WHOLE weekly PR red (one lock, all packages) — the lever out is a
#       `devbox.json` pin of the one package (docs/renovate.md §devbox). Needs jq (fail-closed without
#       it); runs only when a lock file changed.
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
REVERT_MEMORY_DAYS="${REVERT_MEMORY_DAYS:-30}"

BASE="${1:-origin/master}"
GUARDED='argocd/platform/arc-runners\.yaml|agents/coordinator/reflexes-argo\.yaml|agents/coordinator/sentinel-argo\.yaml|argocd/platform/openrouter-operator\.yaml'
# Two pin shapes, one rule. The arc-runner bump writes an `image:` line; the chart-deploy lane
# writes a `targetRevision:` line — CalVer + -g<sha> for our own OCI charts (ADR-084), plain
# SemVer (`0.14.2`, `v1.21.2`) for a third-party chart the Renovate `argocd` manager bumps
# (#2216: arc-runners.yaml rides the grouped `arc` PR with its two siblings). The two branches are
# DISJOINT: SemVer leads with 1–3 digits, CalVer with a 4-digit year, so a first-party pin that lost
# its `-g<sha>` provenance (`2026.9.25`) still fails, and the optional trailing `# comment` is
# scoped to the SemVer branch (every targetRevision in arc-runners.yaml carries one; Renovate
# rewrites the value and keeps the comment) — a CalVer pin still admits no comment. Anything else
# in a guarded file is still refused, so widening the FILE set does not widen what may be written.
# ⚠ GUARDED= and PIN_LINE= are ONE HOME: ci.yaml's ratchet exemption eval-extracts both lines and
# coordinator-scan.sh / goal-lint.sh split GUARDED on `|` — keep them single-line, single-quoted.
PIN_LINE='^[-+][[:space:]]*(image:[[:space:]]*ghcr\.io/teststuffstash/homelab/arc-runner:[A-Za-z0-9._-]+|targetRevision:[[:space:]]*([0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}-g[0-9a-f]+|v?[0-9]{1,3}\.[0-9]+\.[0-9]+([[:space:]]+#.*)?))$'
# The third shape has its own pair so the two above stay byte-for-byte (their consumers never see
# a workflow path in GUARDED, and the ratchet exemption never sees a `uses:` line as a pin).
WORKFLOW_GUARDED='^\.github/workflows/[^/]+\.ya?ml$'
WORKFLOW_PIN_LINE='^[-+][[:space:]]*(- )?uses:[[:space:]]*[A-Za-z0-9-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}[[:space:]]+#[[:space:]]+v[0-9]+(\.[0-9]+){0,2}$'
# The initial-pin case: a REMOVED line may be unpinned (`@v4` with no SHA). The grammar is the
# same as WORKFLOW_PIN_LINE but without the SHA+tag requirement — just `@<tag>` where tag is
# `v<digits>` with up to two `.<digits>` groups. Only the REMOVED sign (`-`) is allowed.
WORKFLOW_UNPINNED_LINE='^-[[:space:]]*(- )?uses:[[:space:]]*[A-Za-z0-9-]+/[A-Za-z0-9_.-]+@v[0-9]+(\.[0-9]+){0,2}$'
# The same grammar as capture groups: sign, owner/repo, sha, tag (kept next to the regex so the
# two cannot drift apart unnoticed — a line that matches WORKFLOW_PIN_LINE always extracts).
WORKFLOW_PIN_EXTRACT='s/^([-+])[[:space:]]*(- )?uses:[[:space:]]*([A-Za-z0-9-]+\/[A-Za-z0-9_.-]+)@([0-9a-f]{40})[[:space:]]+#[[:space:]]+(v[0-9]+(\.[0-9]+){0,2})$/\1 \3 \4 \5/'
# The unpinned extraction: sign, owner/repo, tag (no SHA). Only REMOVED lines fit this.
WORKFLOW_UNPINNED_EXTRACT='s/^-[[:space:]]*(- )?uses:[[:space:]]*([A-Za-z0-9-]+\/[A-Za-z0-9_.-]+)@v[0-9]+(\.[0-9]+){0,2}$/- \2 v\3/'

# Refuse to pass when the diff cannot be computed. A check that green-lights because it could not
# see is the failure class this repo keeps paying for (FU-125/FU-108/FU-131) — and one I shipped
# twice in labels-handoff.sh before catching it.
if ! git rev-parse --verify "$BASE" >/dev/null 2>&1; then
  echo "pin-only-lint: FAIL — base ref '$BASE' not resolvable; refusing to report success." >&2
  echo "  In CI, fetch the base first: git fetch --no-tags --depth=1 origin \$BASE_SHA  (the PR base SHA at event time — never the branch tip, homelab#1441)" >&2
  exit 2
fi

# homelab#1713 / #1736 — diff THREE-DOT: the branch's own changes since its fork, FROM the merge base
# TO the branch head, never two-dot from a base tip. A two-dot diff attributes to the PR every
# guarded-file change master made after the fork (a renovate PR merely BEHIND master, #1713) or in
# the event→checkout gap (#1736, PR#1699's 42 s). The sibling of governance-lint's #1441 (b) fix —
# same shape, same fail-closed rule; this lint needs the merge-base OBJECT too (the per-file -U0 and
# `git show <rev>:<file>` checks compare head against the fork point, not against the base tip), so
# in CI it asks GitHub's server-side three-dot compare for the merge base (depth-independent — the
# checkout is a depth-1 merge ref) and fetches it + the head at depth 1; locally git has the history
# and `git merge-base "$BASE" HEAD` is the same answer. (In CI the side is $BASE_REF.)
# The CI arm reads PR_HEAD_SHA/BASE_REF from env, else from the Actions event payload itself
# ($GITHUB_EVENT_PATH → .pull_request) — so no caller has to wire them: ci.yaml's step and every
# repo on pin-only.reusable.yml (which runs THIS file from homelab master) get the arm unchanged,
# and the local arm never meets a depth-1 merge ref (no merge-base there → it would fail closed).
# OUT OF SCOPE (stated, #1736's comment): a master-sync PR into goal/** genuinely carries master's
# content past its merge base, so three-dot ≡ two-dot there — that shape is not fixed here.
if [ -z "${PR_HEAD_SHA:-}" ] && [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -r "$GITHUB_EVENT_PATH" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "pin-only-lint: FAIL — jq not on PATH, cannot read the PR head from \$GITHUB_EVENT_PATH; refusing to report success." >&2; exit 2
  fi
  PR_HEAD_SHA="$(jq -r '.pull_request.head.sha // empty' "$GITHUB_EVENT_PATH" 2>/dev/null || true)"
  [ -n "${BASE_REF:-}" ] || BASE_REF="$(jq -r '.pull_request.base.ref // empty' "$GITHUB_EVENT_PATH" 2>/dev/null || true)"
fi
if [ -n "${PR_HEAD_SHA:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  if ! FROM="$("$GH" api "repos/${GITHUB_REPOSITORY}/compare/${BASE_REF:-master}...${PR_HEAD_SHA}" --jq '.merge_base_commit.sha' 2>&1)" \
     || ! grep -Eq '^[0-9a-f]{40}$' <<< "$FROM"; then
    echo "pin-only-lint: FAIL — could not read the merge base of ${BASE_REF:-master}...${PR_HEAD_SHA} from GitHub's compare (${FROM:-empty}); refusing to report success." >&2
    exit 2
  fi
  TO="$PR_HEAD_SHA"
  for rev in "$FROM" "$TO"; do
    git cat-file -e "${rev}^{commit}" 2>/dev/null && continue
    if ! git fetch -q --no-tags --depth=1 origin "$rev" 2>/dev/null || ! git cat-file -e "${rev}^{commit}" 2>/dev/null; then
      echo "pin-only-lint: FAIL — could not fetch $rev (the three-dot side) from origin; refusing to report success." >&2
      exit 2
    fi
  done
else
  if ! FROM="$(git merge-base "$BASE" HEAD 2>/dev/null)"; then
    echo "pin-only-lint: FAIL — no merge-base between '$BASE' and HEAD (shallow checkout?); refusing to report success." >&2
    exit 2
  fi
  TO=HEAD
fi
if ! all_changed="$(git diff --name-only "$FROM" "$TO")"; then
  echo "pin-only-lint: FAIL — cannot diff $FROM...$TO; refusing to report success." >&2
  exit 2
fi

changed="$(grep -E "$GUARDED" <<< "$all_changed" || true)"
wf_changed="$(grep -E "$WORKFLOW_GUARDED" <<< "$all_changed" || true)"
# (f): tofu/*.tf files are NOT guarded (owned, reviewed as usual) — only their ADDED image lines
# are checked against the reverted-image memory, and only when there are any.
tofu_changed="$(grep -E '^tofu/.*\.tf$' <<< "$all_changed" || true)"
TOFU_IMAGE_ADDED='^\+[[:space:]]*image[[:space:]]*=[[:space:]]*"[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?(@sha256:[0-9a-f]{64})?"$'
added_images=""
if [ -n "$tofu_changed" ]; then
  # shellcheck disable=SC2086  # word-splitting the newline list is the point
  added_images="$(git diff "$FROM" "$TO" -- $tofu_changed | grep -E "$TOFU_IMAGE_ADDED" | sed -E 's/^\+[[:space:]]*image[[:space:]]*=[[:space:]]*"([^"]+)"$/\1/' | sort -u || true)"
fi
# (g): the lockfiles' ADDED provider versions, as "<name>@<version>" — read from the head's file per
# provider block (a version line alone does not say whose it is), kept only where the base differs.
lock_pairs() { awk '/^provider "/ { src = $2; gsub(/"/, "", src); n = split(src, p, "/"); name = p[n] }
                    /^[[:space:]]*version[[:space:]]*=/ && name != "" { v = $3; gsub(/"/, "", v); print name "@" v; name = "" }'; }
added_providers=""
for lf in $(grep -E '(^|/)\.terraform\.lock\.hcl$' <<< "$all_changed" || true); do
  new_pairs="$(git show "$TO:$lf" 2>/dev/null | lock_pairs | sort -u || true)"
  old_pairs="$(git show "$FROM:$lf" 2>/dev/null | lock_pairs | sort -u || true)"
  added_providers="$added_providers $(comm -23 <(printf '%s\n' "$new_pairs") <(printf '%s\n' "$old_pairs") | tr '\n' ' ')"
done
added_providers="$(printf '%s\n' $added_providers | grep . | sort -u || true)"
# (h): the ADDED chart pins under argocd/platform/, one "<file> <chart>@<version>" per line — the
# version from the diff's `+ targetRevision:` lines (quotes and an optional trailing `# comment`
# dropped), the chart from the head file's first `chart:` line (one chart per Application here; the
# `sources:` form's other source is a `master` values repo). A file without a `chart:` line (a
# `path:` source) contributes nothing, so a raw-manifest Application never reads the memory.
TARGET_REVISION_ADDED='^\+[[:space:]]*targetRevision:[[:space:]]*"?([^[:space:]"#]+)"?([[:space:]]+#.*)?[[:space:]]*$'
added_charts=""
for pf in $(grep -E '^argocd/platform/[^/]+\.ya?ml$' <<< "$all_changed" || true); do
  chart="$(git show "$TO:$pf" 2>/dev/null | awk '/^[[:space:]]*chart:[[:space:]]*[^[:space:]]/ { print $2; exit }' | tr -d "\"'" || true)"
  [ -n "$chart" ] || continue
  while read -r ver; do
    [ -n "$ver" ] || continue
    added_charts="${added_charts}${pf} ${chart}@${ver}"$'\n'
  done <<< "$(git diff -U0 "$FROM" "$TO" -- "$pf" | grep -E "$TARGET_REVISION_ADDED" | sed -E "s/$TARGET_REVISION_ADDED/\1/" || true)"
done
added_charts="$(printf '%s' "$added_charts" | grep . | sort -u || true)"
# (i): the ADDED lock versions — per changed devbox.lock, "<name>@<new>" for every package whose
# resolved version moved (added/removed packages carry no pair). jq, not awk: the lock is JSON and a
# version line alone does not say whose it is (the (g) lesson).
lock_moved() {  # <old-json> <new-json> → "<name>@<new>" per line
  jq -rn --argjson o "$1" --argjson n "$2" '
    def base: sub("@[^@]*$"; "");
    def vermap($p): ($p // {}) | to_entries | map({key: (.key|base), value: .value.version}) | from_entries;
    vermap($o.packages) as $op
    | vermap($n.packages) | to_entries[]
    | select($op[.key] != null and .value != null and $op[.key] != .value)
    | "\(.key)@\(.value)"'
}
added_locks=""
for lf in $(grep -E '(^|/)devbox\.lock$' <<< "$all_changed" || true); do
  if ! command -v jq >/dev/null 2>&1; then
    echo "pin-only-lint: FAIL — jq not on PATH, cannot key the $lf diff (check (i)); refusing to report success." >&2; exit 2
  fi
  new_json="$(git show "$TO:$lf" 2>/dev/null || echo '{}')"
  old_json="$(git show "$FROM:$lf" 2>/dev/null || echo '{}')"
  if ! moved="$(lock_moved "$old_json" "$new_json" 2>&1)"; then
    echo "pin-only-lint: FAIL — cannot parse $lf at base/head (check (i)): $moved; refusing to report success." >&2; exit 2
  fi
  added_locks="$added_locks $(printf '%s\n' "$moved" | tr '\n' ' ')"
done
added_locks="$(printf '%s\n' $added_locks | grep . | sort -u || true)"
if [ -z "$changed" ] && [ -z "$wf_changed" ] && [ -z "$added_images" ] && [ -z "$added_providers" ] && [ -z "$added_charts" ] && [ -z "$added_locks" ]; then
  echo "pin-only-lint: OK — no guarded file touched."
  exit 0
fi

if [ -n "$changed" ] || [ -n "$wf_changed" ]; then
  echo "pin-only-lint: guarded files in this diff:"
  # shellcheck disable=SC2086  # word-splitting the newline list is the point
  printf '  %s\n' $changed $wf_changed
fi

rc=0
# (f) the reverted-image memory — read once, fail-closed like (e).
if [ -n "$added_images" ]; then
  slug="${PIN_ONLY_SLUG:-${GITHUB_REPOSITORY:-}}"
  [ -n "$slug" ] || slug="$(git remote get-url origin 2>/dev/null | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##' || true)"
  cutoff="$(date -u -d "-${REVERT_MEMORY_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)"
  if [ -z "$slug" ] || ! reverted_images="$("$GH" api "repos/$slug/pulls?state=closed&sort=updated&direction=desc&per_page=100" \
      --jq ".[] | select((.merged_at // \"\") >= \"$cutoff\") | select(.head.ref | startswith(\"revert-img-\")) | (.body // \"\") | split(\"\\n\")[] | select(startswith(\"reverted-images:\")) | ltrimstr(\"reverted-images:\")" 2>&1)"; then
    echo "pin-only-lint: FAIL — cannot read the merged revert-img-* PRs of ${slug:-<no repo slug>} (the reverted-image memory, check (f)): ${reverted_images:-}; refusing to report success." >&2
    rc=2; reverted_images=""
  fi
  while read -r ref; do
    [ -n "$ref" ] || continue
    # shellcheck disable=SC2086  # the memory is a whitespace-joined list by contract
    if grep -qxF "$ref" <<< "$(printf '%s\n' $reverted_images)"; then
      echo "pin-only-lint: FAIL — tofu: image = \"$ref\" is a REVERTED image — the tofu-image-revert chain rolled it back within the last ${REVERT_MEMORY_DAYS} days (a merged revert-img-* PR names it); this PR stays red until Renovate proposes a newer version." >&2
      rc=1
    fi
  done <<< "$added_images"
fi
# (g) the reverted-provider memory — read once, fail-closed like (e)/(f).
if [ -n "$added_providers" ]; then
  slug="${PIN_ONLY_SLUG:-${GITHUB_REPOSITORY:-}}"
  [ -n "$slug" ] || slug="$(git remote get-url origin 2>/dev/null | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##' || true)"
  cutoff="$(date -u -d "-${REVERT_MEMORY_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)"
  if [ -z "$slug" ] || ! reverted_providers="$("$GH" api "repos/$slug/pulls?state=closed&sort=updated&direction=desc&per_page=100" \
      --jq ".[] | select((.merged_at // \"\") >= \"$cutoff\") | select(.head.ref | startswith(\"revert-prov-\")) | (.body // \"\") | split(\"\\n\")[] | select(startswith(\"reverted-providers:\")) | ltrimstr(\"reverted-providers:\")" 2>&1)"; then
    echo "pin-only-lint: FAIL — cannot read the merged revert-prov-* PRs of ${slug:-<no repo slug>} (the reverted-provider memory, check (g)): ${reverted_providers:-}; refusing to report success." >&2
    rc=2; reverted_providers=""
  fi
  while read -r pv; do
    [ -n "$pv" ] || continue
    # shellcheck disable=SC2086  # the memory is a whitespace-joined list by contract
    if grep -qxF "$pv" <<< "$(printf '%s\n' $reverted_providers)"; then
      echo "pin-only-lint: FAIL — provider $pv is a REVERTED provider version — the tofu-provider-revert chain rolled it back within the last ${REVERT_MEMORY_DAYS} days (a merged revert-prov-* PR names it); this PR stays red until Renovate proposes a newer version." >&2
      rc=1
    fi
  done <<< "$added_providers"
fi
# (h) the reverted-chart memory — read once, fail-closed like (e)/(f)/(g).
if [ -n "$added_charts" ]; then
  slug="${PIN_ONLY_SLUG:-${GITHUB_REPOSITORY:-}}"
  [ -n "$slug" ] || slug="$(git remote get-url origin 2>/dev/null | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##' || true)"
  cutoff="$(date -u -d "-${REVERT_MEMORY_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)"
  if [ -z "$slug" ] || ! reverted_charts="$("$GH" api "repos/$slug/pulls?state=closed&sort=updated&direction=desc&per_page=100" \
      --jq ".[] | select((.merged_at // \"\") >= \"$cutoff\") | select(.head.ref | startswith(\"revert-chart-\")) | (.body // \"\") | split(\"\\n\")[] | select(startswith(\"reverted-charts:\")) | ltrimstr(\"reverted-charts:\")" 2>&1)"; then
    echo "pin-only-lint: FAIL — cannot read the merged revert-chart-* PRs of ${slug:-<no repo slug>} (the reverted-chart memory, check (h)): ${reverted_charts:-}; refusing to report success." >&2
    rc=2; reverted_charts=""
  fi
  while read -r pf cv; do
    [ -n "$cv" ] || continue
    # shellcheck disable=SC2086  # the memory is a whitespace-joined list by contract
    if grep -qxF "$cv" <<< "$(printf '%s\n' $reverted_charts)"; then
      echo "pin-only-lint: FAIL — $pf: chart $cv is a REVERTED chart version — the chart revert chain rolled it back within the last ${REVERT_MEMORY_DAYS} days (a merged revert-chart-* PR names it); this PR stays red until Renovate proposes a newer version." >&2
      rc=1
    fi
  done <<< "$added_charts"
fi
# (i) the reverted-lock memory — read once, fail-closed like (e)–(h).
if [ -n "$added_locks" ]; then
  slug="${PIN_ONLY_SLUG:-${GITHUB_REPOSITORY:-}}"
  [ -n "$slug" ] || slug="$(git remote get-url origin 2>/dev/null | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##' || true)"
  cutoff="$(date -u -d "-${REVERT_MEMORY_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)"
  if [ -z "$slug" ] || ! reverted_locks="$("$GH" api "repos/$slug/pulls?state=closed&sort=updated&direction=desc&per_page=100" \
      --jq ".[] | select((.merged_at // \"\") >= \"$cutoff\") | select(.head.ref | startswith(\"revert-lock-\")) | (.body // \"\") | split(\"\\n\")[] | select(startswith(\"reverted-locks:\")) | ltrimstr(\"reverted-locks:\")" 2>&1)"; then
    echo "pin-only-lint: FAIL — cannot read the merged revert-lock-* PRs of ${slug:-<no repo slug>} (the reverted-lock memory, check (i)): ${reverted_locks:-}; refusing to report success." >&2
    rc=2; reverted_locks=""
  fi
  while read -r lv; do
    [ -n "$lv" ] || continue
    # shellcheck disable=SC2086  # the memory is a whitespace-joined list by contract
    if grep -qxF "$lv" <<< "$(printf '%s\n' $reverted_locks)"; then
      echo "pin-only-lint: FAIL — devbox.lock: $lv is a REVERTED lock version — the lock revert chain rolled it back within the last ${REVERT_MEMORY_DAYS} days (a merged revert-lock-* PR names it); this PR stays red until nixpkgs moves that package on (or devbox.json pins it)." >&2
      rc=1
    fi
  done <<< "$added_locks"
fi
for f in $changed; do
  # Content lines only: strip the +++/--- headers, keep real additions/removals.
  offending="$(git diff -U0 "$FROM" "$TO" -- "$f" \
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
  if [ "$type" != commit ] || ! grep -Eq '^[0-9a-f]{40}$' <<< "$sha"; then
    printf 'tag %s resolves to a %s object (%s), not a commit\n' "$tag" "${type:-?}" "$sha"; return 1
  fi
  printf '%s\n' "$sha"
}

for f in $wf_changed; do
  lines="$(git diff -U0 "$FROM" "$TO" -- "$f" | grep -E '^[-+][^-+]' || true)"
  if [ -z "$lines" ]; then  # a rename / mode change / empty patch is not a pin bump
    echo "pin-only-lint: FAIL — $f changed without a single content line; a workflow may only receive action pin bumps via a PR." >&2
    rc=1; continue
  fi
  # Separate removed and added lines. Removed lines can be pinned (SHA) or unpinned (@v4);
  # added lines MUST be pinned. This allows the initial-pin scenario (unpinned→pinned).
  removed_lines="$(printf '%s\n' "$lines" | grep -E '^-' || true)"
  added_lines="$(printf '%s\n' "$lines" | grep -E '^\+' || true)"

  # Check ADDED lines: all must be pinned (SHA format).
  if [ -n "$added_lines" ]; then
    offending_added="$(printf '%s\n' "$added_lines" | grep -Ev "$WORKFLOW_PIN_LINE" || true)"
    if [ -n "$offending_added" ]; then
      echo "pin-only-lint: FAIL — $f: added lines must be pinned (uses: <owner>/<repo>@<sha> # <tag>):" >&2
      printf '  %s\n' "$offending_added" >&2
      rc=1; continue
    fi
  fi

  # Check REMOVED lines: each must be either pinned OR unpinned (the initial-pin case).
  if [ -n "$removed_lines" ]; then
    offending_removed="$(printf '%s\n' "$removed_lines" | grep -Ev "$WORKFLOW_PIN_LINE|$WORKFLOW_UNPINNED_LINE" || true)"
    if [ -n "$offending_removed" ]; then
      echo "pin-only-lint: FAIL — $f: removed lines must be either pinned or unpinned action refs:" >&2
      printf '  %s\n' "$offending_removed" >&2
      rc=1; continue
    fi
  fi

  # Extract owner/repo from both formats for pairing. Added lines always have SHA+tag; removed
  # lines may or may not. Only added lines go into added_specs for upstream verification.
  removed_or=""; added_or=""; added_specs=""
  # Process removed lines (may be pinned or unpinned).
  if [ -n "$removed_lines" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      # Try pinned format first.
      if grep -Eq "$WORKFLOW_PIN_LINE" <<< "$line"; then
        extracted="$(printf '%s' "$line" | sed -E "$WORKFLOW_PIN_EXTRACT")"
        or="$(printf '%s' "$extracted" | awk '{print $2}')"
      else
        # Unpinned format.
        extracted="$(printf '%s' "$line" | sed -E "$WORKFLOW_UNPINNED_EXTRACT")"
        or="$(printf '%s' "$extracted" | awk '{print $2}')"
      fi
      case "$or" in
        teststuffstash/*)
          echo "pin-only-lint: FAIL — $f: a first-party ref never changes via a PR (floats at @master by contract, .github/renovate-global.json): $line" >&2
          rc=1; continue ;;
      esac
      removed_or="${removed_or}${or}"$'\n'
    done <<< "$removed_lines"
  fi
  # Process added lines (always pinned).
  if [ -n "$added_lines" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      extracted="$(printf '%s' "$line" | sed -E "$WORKFLOW_PIN_EXTRACT")"
      read -r sign or sha tag <<< "$extracted"
      case "$or" in
        teststuffstash/*)
          echo "pin-only-lint: FAIL — $f: a first-party ref never changes via a PR (floats at @master by contract, .github/renovate-global.json): ${sign} uses: $or@$sha # $tag" >&2
          rc=1; continue ;;
      esac
      added_or="${added_or}${or}"$'\n'
      added_specs="${added_specs}${or} ${sha} ${tag}"$'\n'
    done <<< "$added_lines"
  fi
  if [ "$(printf '%s' "$removed_or" | sort)" != "$(printf '%s' "$added_or" | sort)" ]; then
    echo "pin-only-lint: FAIL — $f: removed and added uses: lines do not pair up by <owner>/<repo> (a bump never adds, drops or swaps an action):" >&2
    printf '  removed: %s\n' "$(printf '%s' "$removed_or" | sort | tr '\n' ' ')" >&2
    printf '  added:   %s\n' "$(printf '%s' "$added_or" | sort | tr '\n' ' ')" >&2
    rc=1; continue
  fi
  # (e) the reverted-pin memory — read once per file set, fail-closed like (d).
  if [ -z "${reverted_pins+x}" ]; then
    slug="${PIN_ONLY_SLUG:-${GITHUB_REPOSITORY:-}}"
    [ -n "$slug" ] || slug="$(git remote get-url origin 2>/dev/null | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##' || true)"
    cutoff="$(date -u -d "-${REVERT_MEMORY_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)"
    if [ -z "$slug" ] || ! reverted_pins="$("$GH" api "repos/$slug/pulls?state=closed&sort=updated&direction=desc&per_page=100" \
        --jq ".[] | select((.merged_at // \"\") >= \"$cutoff\") | select(.head.ref | startswith(\"revert-wf-\")) | (.body // \"\") | split(\"\\n\")[] | select(startswith(\"reverted-pins:\")) | ltrimstr(\"reverted-pins:\")" 2>&1)"; then
      echo "pin-only-lint: FAIL — cannot read the merged revert-wf-* PRs of ${slug:-<no repo slug>} (the reverted-pin memory, check (e)): ${reverted_pins:-}; refusing to report success." >&2
      rc=2; reverted_pins=""
    fi
  fi
  while read -r or sha tag; do
    [ -n "$or" ] || continue
    if grep -qxF "$or@$sha" <<< "$(printf '%s\n' $reverted_pins)"; then
      echo "pin-only-lint: FAIL — $f: $or@$sha # $tag is a REVERTED pin — the FU-1990 chain rolled it back within the last ${REVERT_MEMORY_DAYS} days (a merged revert-wf-* PR names it); this PR stays red until Renovate proposes a newer version." >&2
      rc=1; continue
    fi
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
echo "pin-only-lint: OK — every change is a pin line (arc-runner image / chart targetRevision / verified action SHA / tofu image, provider, chart version not in the reverted memory)."
