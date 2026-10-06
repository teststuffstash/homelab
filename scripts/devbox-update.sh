#!/usr/bin/env bash
# devbox-update.sh — bump ONE repo's devbox.lock (`devbox update`) and open an auto-merging PR.
#
# Part of the weekly `.github/workflows/devbox-update.yaml` job (FU-022). The point is ALIGNMENT: all
# repos keep `@latest` devbox pins, and one weekly pass re-resolves them together so the shared tools
# (gitleaks/kubectl/uv/gh/jq/python) land on the SAME version everywhere — which is what makes the
# in-cluster nix cache (ADR-083) and the `agent-base` baked toolchain hit instead of re-fetch. Pinning
# per-repo (the original FU-022 idea) drifts between updates; a synchronized bump doesn't.
#
# MAJOR bumps are human-gated (not pinned away): if any tool's leading version integer changed, the PR
# is labelled `major` and auto-merge is NOT armed — CI + the reviewer/coordinator pipeline still run
# (reviewer investigates the migration + comments what's needed), but a human makes the final merge
# call. Non-major bumps keep the `automerge` auto-merge path.
#
# A SECOND body section (gap register G17, ADR-141 as amended 2026-10-06) names what the major gate is
# blind to: same-major DOWNGRADES (numeric-tuple compare — openssl 3.6.0 → 3.5.8 when nixpkgs re-pointed
# the default alias to the 3.5 LTS, #2260) and compatibility-LINE moves of the LINE_PACKAGES set
# (`major.minor` moved without a major — python3 3.12 → 3.14, opentofu 1.12 → 1.13 on the same PR).
# It does NOT change the lane: the ruling is "rely on the lens" — the PR stays armed, and the migration
# lens's lock-bump read (agents/lenses/migration.md §Lock bumps) addresses every named item. A class
# un-arms only once the lens finds a downgrade/line move that mattered (graduation, ADR-141's rule).
# `DEVBOX_UPDATE_LIB=1 . scripts/devbox-update.sh` loads only `lock_moves` (the self-test's seam —
# scripts/devbox-update-test.sh runs it over #2260's recorded lock diff).
#
# Env: GH_TOKEN (contents + pull_requests write on $REPO — a homelab-renovate App token),
#      REPO (owner/name), DEVBOX_DIR (subdir holding devbox.json; default ".", agent-runtime = "agent-base").
# Needs: devbox (on PATH — the workflow sets up single-user Nix), git, gh (the workflow adds it via
#        `devbox global add gh`; gh's built-in --jq means no standalone jq).
set -euo pipefail

# Packages whose `major.minor` is a compatibility LINE (a runtime, an API client, a state-format
# owner): a line move is reported even when the leading integer stays. kubectl's minor is the
# cluster-skew window; opentofu's stamps the state version (a lock revert cannot read it back);
# python3's is the interpreter the scripts run under; openssl's is the LTS alias nixpkgs points at.
LINE_PACKAGES="${LINE_PACKAGES:-python3 opentofu kubectl openssl}"

# lock_moves <old-lock-json> <new-lock-json> → one JSON object: {majors, downgrades, lines}, each a
# list of "pkg: old → new" strings over the packages present in BOTH locks (added/removed ignored).
#   majors     the leading integer changed, or the version is unparseable and changed (the LANE gate,
#              unchanged since FU-022: compare the leading integer, NOT the pin name — `awscli2` is a
#              package name, its version is 2.x; only a real 2→3 counts). Keyed by the package BASE
#              NAME (the `@pin` stripped) so a pin change like `kubernetes-helm@3` → `@latest` is still
#              a 3.x → 4.x bump, not an add+remove.
#   downgrades new < old by numeric-tuple compare (split on `.`, leading digits per component; a
#              component without digits makes the pair unparseable → never flagged, never silent
#              either: it is in `majors` if it changed)
#   lines      LINE_PACKAGES whose major.minor moved UP while the major did not (a major is already in
#              `majors`, a downward line move already in `downgrades` — one row per fact)
lock_moves() {
  jq -n --argjson old "$1" --argjson new "$2" --arg line_pkgs "$LINE_PACKAGES" '
    def base: sub("@[^@]*$"; "");                            # "kubernetes-helm@3" -> "kubernetes-helm"
    def major(v): (v // "") | if test("^[0-9]+") then capture("^(?<n>[0-9]+)").n else null end;
    # numeric tuple: every dot-component must START with digits ("3.14.7" → [3,14,7]; "1.2.3-rc1" → [1,2,3]);
    # otherwise null = unparseable (never compared)
    def tuple(v): (v // "") | split(".") | if all(test("^[0-9]+")) and length > 0
                                             then map(capture("^(?<n>[0-9]+)").n | tonumber) else null end;
    def vermap($p): ($p // {}) | to_entries | map({key: (.key|base), value: .value.version}) | from_entries;
    ($line_pkgs | split(" ") | map(select(length > 0))) as $lines
    | vermap($old.packages) as $op
    | [ vermap($new.packages) | to_entries[] | .key as $k | .value as $nv | ($op[$k]) as $ov
        | select($ov != null and $nv != null)                 # ignore added/removed packages
        | select($ov != $nv)
        | { k: $k, ov: $ov, nv: $nv, om: major($ov), nm: major($nv), ot: tuple($ov), nt: tuple($nv) } ] as $moves
    | { majors:     [ $moves[] | select(.om != .nm or (.om == null)) | "\(.k): \(.ov) → \(.nv)" ],
        downgrades: [ $moves[] | select(.ot != null and .nt != null and .nt < .ot) | "\(.k): \(.ov) → \(.nv)" ],
        lines:      [ $moves[] | select(.om == .nm and .om != null and (.k | IN($lines[])))
                               | select(.ot != null and .nt != null and (.ot[0:2] != .nt[0:2]) and .nt > .ot) | "\(.k): \(.ov) → \(.nv)" ] }
  '
}
# lock_moves_section <downgrades> <lines> → the second body section (markdown), "none" lines when empty.
lock_moves_section() {
  local d="$1" l="$2"
  printf '### Downgrades and compatibility-line moves — read by the lens, PR stays armed (G17, ADR-141 amended 2026-10-06)\n\n'
  printf 'The major gate above reads only the leading integer; these are the moves it is blind to. The migration lens reads the WHOLE lock diff and addresses each line here explicitly (`agents/lenses/migration.md` §Lock bumps). The lane does not change — a class un-arms only once a listed move turns out to have mattered.\n\n'
  printf '**Downgrades** (new version numerically lower than the old):\n'
  if [ -n "$d" ]; then printf '%s\n' "$d" | sed 's/^/- /'; else printf -- '- none\n'; fi
  printf '\n**Compatibility-line moves** (`major.minor` moved, major unchanged; set: %s):\n' "$LINE_PACKAGES"
  if [ -n "$l" ]; then printf '%s\n' "$l" | sed 's/^/- /'; else printf -- '- none\n'; fi
}
[ "${DEVBOX_UPDATE_LIB:-0}" = 1 ] && return 0

REPO="${REPO:?set REPO=owner/name}"
DIR="${DEVBOX_DIR:-.}"
: "${GH_TOKEN:?set GH_TOKEN}"
BRANCH="devbox-update"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
git clone -c "http.extraHeader=Authorization: Basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')" --quiet --depth 1 "https://github.com/${REPO}.git" "$WORK/r"
cd "$WORK/r"

echo "[$REPO] devbox update ($DIR)…"
( cd "$DIR" && devbox update )

if git diff --quiet -- "$DIR/devbox.lock"; then
  echo "[$REPO] devbox.lock already current — nothing to do"; exit 0
fi

# The three move lists over the lock diff (lock_moves above): MAJORS decides the lane; the other two
# are the second body section the lens reads.
LOCK="devbox.lock"; [ "$DIR" = "." ] || LOCK="$DIR/devbox.lock"
OLD_LOCK="$(git show "HEAD:$LOCK" 2>/dev/null || echo '{}')"
NEW_LOCK="$(cat "$LOCK")"
MOVES="$(lock_moves "$OLD_LOCK" "$NEW_LOCK")"
MAJORS="$(jq -r '.majors[]' <<<"$MOVES")"
DOWNGRADES="$(jq -r '.downgrades[]' <<<"$MOVES")"
LINES="$(jq -r '.lines[]' <<<"$MOVES")"

git config user.name "homelab-renovate[bot]"
git config user.email "homelab-renovate[bot]@users.noreply.github.com"
git checkout -q -B "$BRANCH"
git add "$DIR/devbox.lock"
git commit -q -m "chore: devbox update — align the toolchain lock (FU-022)" \
  -m "Weekly synchronized devbox.lock bump so shared tools resolve to the same version across repos (nix cache + agent-base bake hits)."
git push -q --force origin "$BRANCH"

export GH_TOKEN # gh authenticates from this

# Ensure the labels exist (idempotent) so --label can't fail on a repo Renovate hasn't touched yet.
gh label create automerge    --repo "$REPO" --color ededed --force >/dev/null 2>&1 || true
gh label create dependencies --repo "$REPO" --color ededed --force >/dev/null 2>&1 || true
gh label create major        --repo "$REPO" --color b60205 --force >/dev/null 2>&1 || true

BASE_BODY="Weekly synchronized \`devbox update\` (FU-022): keeps \`@latest\` pins but re-resolves the lock so shared tools stay on ONE version across repos → nix cache + agent-base bake hits."
# The second section rides BOTH bodies — it informs the lens, never the lane (G17).
G17_SECTION="$(lock_moves_section "$DOWNGRADES" "$LINES")"
if [ -n "$MAJORS" ]; then
  TITLE="chore: devbox update — MAJOR bump, human review (align toolchain lock)"
  LABELS="major,dependencies"
  BODY="$(printf '%s\n\n⚠️ **MAJOR version bump(s) — human-gated, auto-merge NOT armed:**\n\n%s\n\nCI + the reviewer/coordinator pipeline still run (and may fix breakage); the reviewer investigates the migration and comments what is needed, but the final merge is a human call (majors need a human — FU-022).\n\n%s' \
    "$BASE_BODY" "$(printf '%s\n' "$MAJORS" | sed 's/^/- /')" "$G17_SECTION")"
else
  TITLE="chore: devbox update (align toolchain lock)"
  LABELS="automerge,dependencies"
  BODY="$(printf '%s CI-gated; auto-merges via the automerge label.\n\n%s' "$BASE_BODY" "$G17_SECTION")"
fi

PR="$(gh pr list --repo "$REPO" --head "$BRANCH" --state open --json number --jq '.[0].number // empty')"
if [ -z "$PR" ]; then
  PR="$(gh pr create --repo "$REPO" --base master --head "$BRANCH" \
    --label "$LABELS" --title "$TITLE" --body "$BODY" | grep -oE '[0-9]+$')"
else
  gh pr edit "$PR" --repo "$REPO" --title "$TITLE" --body "$BODY" --add-label "$LABELS" >/dev/null
  # keep the gate labels consistent if a re-run flips major<->non-major
  if [ -n "$MAJORS" ]; then gh pr edit "$PR" --repo "$REPO" --remove-label automerge >/dev/null 2>&1 || true
  else                      gh pr edit "$PR" --repo "$REPO" --remove-label major     >/dev/null 2>&1 || true; fi
fi

if [ -n "$MAJORS" ]; then
  # The major gate: DON'T arm auto-merge. FU-041's updater only touches auto-merge-armed PRs, so an
  # un-armed PR simply waits for a human — while CI + the reviewer/coordinator pipeline still run on it.
  echo "::warning::[$REPO] MAJOR bump on #$PR — left for a human (auto-merge NOT armed):"
  printf '%s\n' "$MAJORS" | sed 's/^/  /'
  echo "[$REPO] devbox-update PR #${PR} (labelled major, human-gated)"
else
  # ARM auto-merge — REQUIRED for non-major bumps: the FU-041 updater only touches auto-merge-armed PRs
  # (require_auto_merge_enabled) and GitHub only completes an armed merge. `gh pr merge --auto` is the
  # clean way (no raw GraphQL). Harmless if already armed.
  gh pr merge "$PR" --repo "$REPO" --auto --squash \
    || echo "::warning::[$REPO] could not arm auto-merge on #$PR"
  echo "[$REPO] devbox-update PR #${PR} (labelled + armed)"
fi
