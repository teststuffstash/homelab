#!/usr/bin/env bash
# devbox-update.sh — bump ONE repo's devbox.lock (`devbox update`) and open an auto-merging PR.
#
# Part of the weekly `.github/workflows/devbox-update.yaml` job (FU-022). The point is ALIGNMENT: all
# repos keep `@latest` devbox pins, and one weekly pass re-resolves them together so the shared tools
# (gitleaks/kubectl/uv/gh/jq/python) land on the SAME version everywhere — which is what makes the
# in-cluster nix cache (ADR-083) and the `agent-base` baked toolchain hit instead of re-fetch. Pinning
# per-repo (the original FU-022 idea) drifts between updates; a synchronized bump doesn't.
#
# MAJOR bumps (any tool's leading version integer changed) are labelled `major` — the migration-lens
# marker — and, since 2026-10-07 (operator ruling, docs/dependency-upgrades.md §2 Review), ARMED the
# ADR-141 way: `major` kept, no `automerge` label, so the review reflex dispatches the reviewer with
# the migration lens and its APPROVED completes the merge. CI on the PR proves the toolchain BEFORE
# the merge (the lock self-deploys to CI); the post-merge half is the lock revert chain
# (`workflow-pin-revert`, agents/coordinator/deploy-revert-argo.yaml: a master workflow failing within
# the window after a lock-only merge reverts it, and pin-only-lint check (i) refuses the re-resolve for
# 30 days). The ONE human-lane member is the HUMAN_PACKAGES set (default: opentofu — it stamps the
# tofu state on the management box's first apply, so a lock revert cannot read it back: a one-way
# door no chain can undo): a major of such a package leaves the PR UN-ARMED, coordinator-owned,
# `major/awaiting-human` on the lens's APPROVED (agents/major-handoff.sh), a human merges. The lane is
# written on the body as a line-anchored `lock-lane:` line (mechanical | arm | human — <why>).
# Non-major bumps keep the `automerge` mechanical path.
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
# THE VERSION-SET STAMP (homelab#2014 shape (a), operator ruling 2026-10-10). In the homelab leg only
# (the clone carries `version-sets/devbox.json`), the same pass also re-resolves the VERSION SETS —
# claude-code, kind, and kubectl BOUNDED to the fleet's Kubernetes minor (`kubernetes_version` in
# tofu/variables.tf, the one home machines/machines.yaml reads it from) — into ONE file,
# `version-sets/devbox.lock`. Every first-party image that bundles those tools reads it at build time
# (a sparse fetch of homelab master) and pins its installs to it, so the worker, the coordinator +
# reviewer and the seat agree by construction; the drift belt (argocd/resources/version-sets/) checks
# that they do. The stamp rides THIS repo's PR (one PR per repo, same lane rules: its moves join the
# major/downgrade/line lists) and resolves with `--no-install` — nothing in this job runs those tools.
# `fleet_minor` + `bound_kubectl` below are the self-test's seams.
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
# Packages whose MAJOR keeps the PR on the human lane (un-armed): the state-format owner. opentofu's
# first apply after a bump stamps the state with the new version and an older binary refuses to read
# it, so the lock revert chain's `git revert` would leave the management box unable to plan — the
# one move in the lock a chain cannot undo. Line/patch moves of the same package stay armed (the G17
# ruling: the lens reads them; the box moves forward on every lock either way).
HUMAN_PACKAGES="${HUMAN_PACKAGES:-opentofu}"

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
# lock_lane <moves-json> → "arm", or "human <pkg: old → new>[; …]" when a HUMAN_PACKAGES member is among
# the majors. Only the majors list decides (a line move of opentofu is informational, G17); a
# non-major PR never asks (it is the mechanical lane).
lock_lane() {
  jq -r --arg hp "$HUMAN_PACKAGES" '
    ($hp | split(" ") | map(select(length > 0))) as $h
    | [ .majors[] | select((split(":")[0]) | IN($h[])) ]
    | if length == 0 then "arm" else "human " + join("; ") end' <<<"$1"
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
# fleet_minor <variables.tf> → "1.36" from `variable "kubernetes_version" { … default = "v1.36.1" }`;
# empty when absent/unparseable (the caller fails loud — never stamp an unbounded kubectl).
fleet_minor() {
  awk '/^variable "kubernetes_version"/ { f = 1 } f && /default/ { print; exit }' "$1" \
    | sed -nE 's/.*"v?([0-9]+)\.([0-9]+)(\.[0-9]+)?".*/\1.\2/p'
}
# bound_kubectl <devbox.json> <major.minor> → rewrites the kubectl spec to `<major.minor>` in place
# (object-form packages, homelab style); prints "moved <old> → <new>" when it changed, nothing otherwise.
bound_kubectl() {
  local cur tmp
  cur="$(jq -r '.packages.kubectl.version // empty' "$1")"
  [ "$cur" = "$2" ] && return 0
  tmp="$(mktemp)"
  jq --arg v "$2" '.packages.kubectl = {version: $v}' "$1" > "$tmp" && mv "$tmp" "$1"
  echo "moved ${cur:-<none>} → $2"
}
# merge_moves <moves-json>… → one {majors, downgrades, lines} (the stamp lock's moves join the repo lock's)
merge_moves() {
  jq -s '{majors: (map(.majors) | add), downgrades: (map(.downgrades) | add), lines: (map(.lines) | add)}' <<<"$(printf '%s\n' "$@")"
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

# The version-set stamp (header): homelab leg only — the clone carries version-sets/devbox.json.
VS_DIR=""
if [ "$DIR" = "." ] && [ -f version-sets/devbox.json ]; then
  VS_DIR="version-sets"
  MINOR="$(fleet_minor tofu/variables.tf)"
  [ -n "$MINOR" ] || { echo "::error::[$REPO] no kubernetes_version default in tofu/variables.tf — refusing to stamp an unbounded kubectl"; exit 1; }
  BOUND="$(bound_kubectl "$VS_DIR/devbox.json" "$MINOR")"
  [ -z "$BOUND" ] || echo "[$REPO] version-set kubectl bound to the fleet minor: $BOUND"
  echo "[$REPO] devbox update --no-install ($VS_DIR — the version-set stamp, kubectl@$MINOR)…"
  ( cd "$VS_DIR" && devbox update --no-install )
fi

# porcelain, not `git diff`: the stamp's lock may be NEW (untracked) on its first run
if [ -z "$(git status --porcelain -- "$DIR/devbox.lock" ${VS_DIR:+"$VS_DIR"})" ]; then
  echo "[$REPO] devbox.lock already current — nothing to do"; exit 0
fi

# The three move lists over the lock diff (lock_moves above): MAJORS decides the lane; the other two
# are the second body section the lens reads.
LOCK="devbox.lock"; [ "$DIR" = "." ] || LOCK="$DIR/devbox.lock"
OLD_LOCK="$(git show "HEAD:$LOCK" 2>/dev/null || echo '{}')"
NEW_LOCK="$(cat "$LOCK")"
MOVES="$(lock_moves "$OLD_LOCK" "$NEW_LOCK")"
if [ -n "$VS_DIR" ]; then
  MOVES="$(merge_moves "$MOVES" "$(lock_moves "$(git show "HEAD:$VS_DIR/devbox.lock" 2>/dev/null || echo '{}')" "$(cat "$VS_DIR/devbox.lock")")")"
fi
MAJORS="$(jq -r '.majors[]' <<<"$MOVES")"
DOWNGRADES="$(jq -r '.downgrades[]' <<<"$MOVES")"
LINES="$(jq -r '.lines[]' <<<"$MOVES")"

git config user.name "homelab-renovate[bot]"
git config user.email "homelab-renovate[bot]@users.noreply.github.com"
git checkout -q -B "$BRANCH"
git add "$DIR/devbox.lock" ${VS_DIR:+"$VS_DIR/devbox.lock" "$VS_DIR/devbox.json"}
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
LANE="$(lock_lane "$MOVES")"   # arm | human <pkg: old → new …>
if [ -n "$MAJORS" ] && [ "$LANE" != arm ]; then
  TITLE="chore: devbox update — MAJOR bump, human review (align toolchain lock)"
  LABELS="major,dependencies"
  BODY="$(printf '%s\n\n⚠️ **MAJOR version bump(s) — human-gated, auto-merge NOT armed:**\n\n%s\n\nA HUMAN_PACKAGES member crossed a major (%s): the state-format owner is a one-way door the lock revert chain cannot undo, so this PR stays UN-ARMED, coordinator-owned — the reviewer investigates the migration under the four headings, `agents/major-handoff.sh` parks it `major/awaiting-human` on the APPROVED, and a human merges (docs/dependency-upgrades.md §2 Review).\n\nlock-lane: human — %s\n\n%s' \
    "$BASE_BODY" "$(printf '%s\n' "$MAJORS" | sed 's/^/- /')" "${LANE#human }" "${LANE#human }" "$G17_SECTION")"
elif [ -n "$MAJORS" ]; then
  TITLE="chore: devbox update — MAJOR bump (align toolchain lock)"
  LABELS="major,dependencies"
  BODY="$(printf '%s\n\n⚠️ **MAJOR version bump(s) — the migration lens is the merge gate (ARMED, ADR-141 way):**\n\n%s\n\nAuto-merge is armed and the `major` label kept: the review reflex dispatches the reviewer with the migration lens (upstream notes, known issues, platform compatibility, evidence) and its APPROVED completes the merge; CHANGES_REQUESTED sends a worker to adapt this branch. CI on this head proves the toolchain before the merge; a master workflow failing after a lock-only merge is reverted by the lock revert chain (`workflow-pin-revert`), and pin-only-lint check (i) refuses the re-resolve for 30 days (docs/dependency-upgrades.md §2 Review, operator ruling 2026-10-07).\n\nlock-lane: arm\n\n%s' \
    "$BASE_BODY" "$(printf '%s\n' "$MAJORS" | sed 's/^/- /')" "$G17_SECTION")"
else
  TITLE="chore: devbox update (align toolchain lock)"
  LABELS="automerge,dependencies"
  BODY="$(printf '%s CI-gated; auto-merges via the automerge label.\n\nlock-lane: mechanical\n\n%s' "$BASE_BODY" "$G17_SECTION")"
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

if [ -n "$MAJORS" ] && [ "$LANE" != arm ]; then
  # The human lane: DON'T arm auto-merge — and DISARM if a re-run flipped an armed PR here (the
  # Monday run edits the open PR in place). FU-041's updater only touches auto-merge-armed PRs, so an
  # un-armed PR simply waits for a human — while CI + the reviewer/coordinator pipeline still run on it.
  gh pr merge "$PR" --repo "$REPO" --disable-auto >/dev/null 2>&1 || true
  echo "::warning::[$REPO] MAJOR bump of a HUMAN_PACKAGES member on #$PR — left for a human (auto-merge NOT armed): ${LANE#human }"
  printf '%s\n' "$MAJORS" | sed 's/^/  /'
  echo "[$REPO] devbox-update PR #${PR} (labelled major, human-gated: ${LANE#human })"
elif [ -n "$MAJORS" ]; then
  # The ARMED major (ADR-141 way): `major` kept, auto-merge armed — the reflex's reviewer runs the
  # migration lens and its APPROVED completes the merge. Same arm call as the mechanical lane below.
  gh pr merge "$PR" --repo "$REPO" --auto --squash \
    || echo "::warning::[$REPO] could not arm auto-merge on #$PR"
  echo "::notice::[$REPO] MAJOR bump on #$PR — ARMED, the migration lens is the merge gate:"
  printf '%s\n' "$MAJORS" | sed 's/^/  /'
  echo "[$REPO] devbox-update PR #${PR} (labelled major + armed)"
else
  # ARM auto-merge — REQUIRED for non-major bumps: the FU-041 updater only touches auto-merge-armed PRs
  # (require_auto_merge_enabled) and GitHub only completes an armed merge. `gh pr merge --auto` is the
  # clean way (no raw GraphQL). Harmless if already armed.
  gh pr merge "$PR" --repo "$REPO" --auto --squash \
    || echo "::warning::[$REPO] could not arm auto-merge on #$PR"
  echo "[$REPO] devbox-update PR #${PR} (labelled + armed)"
fi
